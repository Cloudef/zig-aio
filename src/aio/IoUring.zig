const std = @import("std");
const aio = @import("../aio.zig");
const Operation = @import("ops.zig").Operation;
const posix = @import("posix/posix.zig");
const linux = @import("posix/linux.zig");
const log = std.log.scoped(.aio_io_uring);

const Supported = struct {
    var once = std.once(do_once);
    var waitid: bool = false;

    fn do_once() void {
        waitid = uring_is_supported(&.{.WAITID});
        if (!waitid) log.warn("aio.ChildExit: fallback with pidfd", .{});
    }

    pub fn query() void {
        once.call();
    }
};

// TODO: Support IOSQE_FIXED_FILE
// TODO: Support IOSQE_BUFFER_SELECT
// TODO: Support IOSQE_IO_DRAIN
// TODO: Support IOSQE_ASYNC

// Could also make io_uring based event source with `IORING_OP_MSG_RING`
// However I've read some claims that passing messages to other ring has more
// latency than actually using eventfd. Eventfd is simple and reliable.
pub const EventSource = linux.EventSource;

const UringOperation = struct {
    const State = union {
        child_exit: struct {
            child: std.process.Child.Id,
            state: union {
                // only required for converting IORING_OP_WAITID result
                siginfo: std.posix.siginfo_t,
                // soft-fallback when IORING_OP_WAITID is not available (requires kernel 6.5)
                fd: std.posix.fd_t,
            },
        },
        // TODO: avoid storing this
        timeout: std.os.linux.kernel_timespec,

        fn init(comptime op_type: Operation, op: op_type.Type()) @This() {
            return switch (op_type) {
                .child_exit => .{
                    .child_exit = .{
                        .child = op.child,
                        .state = switch (Supported.waitid) {
                            true => .{ .siginfo = undefined },
                            false => .{ .fd = posix.invalid_fd },
                        },
                    },
                },
                .timeout, .link_timeout => .{
                    .timeout = .{
                        .sec = @intCast(op.ns / std.time.ns_per_s),
                        .nsec = @intCast(op.ns % std.time.ns_per_s),
                    },
                },
                else => undefined,
            };
        }
    };

    type: Operation,
    userdata: usize,
    out_id: ?*aio.Id = null,
    out_error: ?*Operation.Error = null,
    out_result: *Operation.anyresult,

    // some pairs require mutable state
    // TODO: store this out of band (state is very big)
    state: State,
};

const IdAllocator = aio.Id.Allocator(UringOperation);
const special_cqe = std.math.maxInt(usize);

io: std.os.linux.IoUring,
ops: IdAllocator,
cqes: [*]std.os.linux.io_uring_cqe,

pub fn isSupported(op_types: []const Operation) bool {
    var ops: [Operation.map.count()]IORING_OP = undefined;
    for (op_types, ops[0..op_types.len]) |op_type, *op| {
        op.* = switch (op_type) {
            .nop => .NOP, // 5.1
            .fsync => .FSYNC, // 5.1
            .poll, .child_exit => .POLL_ADD, // 5.1 (child_exit uses waitid if available 6.5)
            .read_tty, .read, .wait_event_source => .READ, // 5.6
            .write, .notify_event_source => .WRITE, // 5.6
            .readv => .READV, // 5.6
            .writev => .WRITEV, // 5.6
            .accept => .ACCEPT, // 5.5
            .connect => .CONNECT, // 5.5
            .recv => .RECV, // 5.6
            .send => .SEND, // 5.6
            .recv_msg => .RECVMSG, // 5.3
            .send_msg => .SENDMSG, // 5.3
            .shutdown => .SHUTDOWN, // 5.11
            .open_at => .OPENAT, // 5.15
            .close_file, .close_dir, .close_socket, .close_event_source => .CLOSE, // 5.15
            .timeout => .TIMEOUT, // 5.4
            .link_timeout => .LINK_TIMEOUT, // 5.5
            .cancel => .ASYNC_CANCEL, // 5.5
            .rename_at => .RENAMEAT, // 5.11
            .unlink_at => .UNLINKAT, // 5.11
            .mkdir_at => .MKDIRAT, // 5.15
            .symlink_at => .SYMLINKAT, // 5.15
            .socket => .SOCKET, // 5.19
            .splice => .SPLICE, // 5.7
            .bind => .BIND, // 6.11
            .listen => .LISTEN, // 6.11
        };
    }
    return uring_is_supported(ops[0..op_types.len]);
}

/// TODO: give options perhaps? More customization?
pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    Supported.query();
    // TODO: give backends ability to return the actual chosen queue size
    const n2 = std.math.ceilPowerOfTwo(u16, n) catch n;
    var io = try uring_init(n2);
    errdefer io.deinit();
    var ops = try IdAllocator.init(allocator, @intCast(io.sq.sqes.len));
    errdefer ops.deinit(allocator);
    const cqes = try allocator.alloc(std.os.linux.io_uring_cqe, @intCast(io.cq.cqes.len));
    errdefer allocator.free(cqes);
    return .{ .io = io, .ops = ops, .cqes = cqes.ptr };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.io.deinit();
    self.ops.deinit(allocator);
    allocator.free(self.cqes[0..self.io.cq.cqes.len]);
    self.* = undefined;
}

fn queueOperation(self: *@This(), comptime tag: Operation, op: anytype, link: aio.Link) aio.Error!aio.Id {
    const id = self.ops.next() orelse return error.OutOfMemory;
    self.ops.use(id, .{
        .type = tag,
        .userdata = op.userdata,
        .out_id = op.out_id,
        .out_error = @ptrCast(op.out_error),
        .out_result = Operation.anyresult.init(tag, op),
        .state = UringOperation.State.init(tag, op),
    }) catch unreachable;
    errdefer self.ops.release(id) catch unreachable;
    try uring_queue(&self.io, tag, op, link, id.cast(u64), self.ops.getOnePtr(.state, id));
    return id;
}

pub fn queue(self: *@This(), pairs: anytype, handler: anytype) aio.Error!void {
    const saved_sq = self.io.sq;
    errdefer self.io.sq = saved_sq;
    if (comptime pairs.len > 1) {
        var ids: std.BoundedArray(aio.Id, pairs.len) = .{};
        errdefer inline for (ids.constSlice(), pairs) |id, pair| {
            debug("dequeue: {}: {}, {s}", .{ id, pair.tag, @tagName(pair.link) });
            self.ops.release(id) catch unreachable;
        };
        inline for (pairs) |pair| ids.append(try self.queueOperation(pair.tag, pair.op, pair.link)) catch unreachable;
        if (@TypeOf(handler) != void) {
            inline for (ids.constSlice(), pairs) |id, pair| {
                handler.aio_queue(id, pair.op.userdata);
            }
        }
    } else {
        inline for (pairs) |pair| {
            const id = try self.queueOperation(pair.tag, pair.op, pair.link);
            if (@TypeOf(handler) != void) {
                handler.aio_queue(id, pair.op.userdata);
            }
        }
    }
}

/// TODO: give options perhaps? More customization?
pub fn complete(self: *@This(), mode: aio.CompletionMode, handler: anytype) aio.Error!aio.CompletionResult {
    if (self.ops.empty()) return .{};
    _ = try uring_submit(&self.io);

    const n = try uring_copy_cqes(&self.io, self.cqes[0..self.io.cq.cqes.len], switch (mode) {
        .nonblocking => 0,
        .blocking => 1,
    });

    var result: aio.CompletionResult = .{};
    for (self.cqes[0..n]) |*cqe| {
        // XXX: relevant to zero-copy ops, not handled yet
        std.debug.assert(cqe.flags & std.os.linux.IORING_CQE_F_MORE == 0);
        std.debug.assert(cqe.flags & std.os.linux.IORING_CQE_F_NOTIF == 0);

        if (cqe.user_data == special_cqe) {
            // used when posting hidden sqe's which completation we don't care about
            // unfortunately while io_uring has IOSQE_CQE_SKIP_SUCCESS
            // there is no IOSQE_CQE_SKIP
            // currently only used to do `cancel` on socket fds on close
            // the cancel may fail if there are no other operations on going for the socket
            continue;
        }

        const id = aio.Id.init(cqe.user_data);
        const op_type = self.ops.getOne(.type, id);

        var failed: bool = false;
        _ = switch (op_type) {
            .child_exit => blk: {
                const state = self.ops.getOnePtr(.state, id);
                break :blk uring_handle_completion(.child_exit, .{
                    .child = state.child_exit.child,
                    .out_id = self.ops.getOne(.out_id, id),
                    .out_error = @ptrCast(self.ops.getOne(.out_error, id)),
                    .out_term = self.ops.getOne(.out_result, id).cast(?*std.process.Child.Term),
                }, state, cqe);
            },
            inline .socket, .accept => |tag| blk: {
                var op: tag.Type() = undefined;
                op.out_id = self.ops.getOne(.out_id, id);
                op.out_error = @ptrCast(self.ops.getOne(.out_error, id));
                op.out_socket = self.ops.getOne(.out_result, id).cast(*std.posix.socket_t);
                break :blk uring_handle_completion(tag, op, undefined, cqe);
            },
            inline .read, .readv, .read_tty, .recv, .recv_msg => |tag| blk: {
                var op: tag.Type() = undefined;
                op.out_id = self.ops.getOne(.out_id, id);
                op.out_error = @ptrCast(self.ops.getOne(.out_error, id));
                op.out_read = self.ops.getOne(.out_result, id).cast(*usize);
                break :blk uring_handle_completion(tag, op, undefined, cqe);
            },
            inline .write, .writev, .send, .send_msg, .splice => |tag| blk: {
                var op: tag.Type() = undefined;
                op.out_id = self.ops.getOne(.out_id, id);
                op.out_error = @ptrCast(self.ops.getOne(.out_error, id));
                op.out_written = self.ops.getOne(.out_result, id).cast(?*usize);
                break :blk uring_handle_completion(tag, op, undefined, cqe);
            },
            inline .open_at => |tag| blk: {
                var op: tag.Type() = undefined;
                op.out_id = self.ops.getOne(.out_id, id);
                op.out_error = @ptrCast(self.ops.getOne(.out_error, id));
                op.out_file = self.ops.getOne(.out_result, id).cast(*std.fs.File);
                break :blk uring_handle_completion(tag, op, undefined, cqe);
            },
            inline .nop,
            .fsync,
            .poll,
            .connect,
            .bind,
            .listen,
            .shutdown,
            .close_file,
            .close_dir,
            .timeout,
            .link_timeout,
            .cancel,
            .rename_at,
            .unlink_at,
            .mkdir_at,
            .symlink_at,
            .close_socket,
            .notify_event_source,
            .wait_event_source,
            .close_event_source,
            => |tag| blk: {
                var op: tag.Type() = undefined;
                op.out_id = self.ops.getOne(.out_id, id);
                op.out_error = @ptrCast(self.ops.getOne(.out_error, id));
                break :blk uring_handle_completion(tag, op, undefined, cqe);
            },
        } catch {
            result.num_errors += 1;
            failed = true;
        };

        const userdata = self.ops.getOne(.userdata, id);
        self.ops.release(id) catch unreachable;
        result.num_completed += 1;

        if (@TypeOf(handler) != void) {
            handler.aio_complete(id, userdata, failed);
        }
    }

    return result;
}

pub fn immediate(pairs: anytype) aio.Error!u16 {
    Supported.query();

    var io = try uring_init(std.math.ceilPowerOfTwo(u16, pairs.len * 2) catch unreachable);
    defer io.deinit();

    var state: [pairs.len]UringOperation.State = undefined;
    inline for (pairs, 0..) |pair, idx| {
        state[idx] = UringOperation.State.init(pair.tag, pair.op);
        try uring_queue(&io, pair.tag, pair.op, pair.link, idx, &state[idx]);
    }

    const submitted = try uring_submit(&io);
    std.debug.assert(submitted >= pairs.len);

    var num_errors: u16 = 0;
    var num_completed: u16 = 0;
    var cqes: [pairs.len]std.os.linux.io_uring_cqe = undefined;
    while (num_completed < pairs.len) {
        const n = try uring_copy_cqes(&io, &cqes, submitted);
        for (cqes[0..n]) |*cqe| {
            // XXX: relevant to zero-copy ops, not handled yet
            std.debug.assert(cqe.flags & std.os.linux.IORING_CQE_F_MORE == 0);
            std.debug.assert(cqe.flags & std.os.linux.IORING_CQE_F_NOTIF == 0);
            if (cqe.user_data == special_cqe) continue;
            @setEvalBranchQuota(1000 * pairs.len);
            inline for (pairs, 0..) |pair, idx| if (idx == cqe.user_data) {
                uring_handle_completion(pair.tag, pair.op, &state[idx], cqe) catch {
                    num_errors += 1;
                };
            };
            num_completed += 1;
        }
    }

    return num_errors;
}

const ProbeOpsResult = struct {
    last_op: IORING_OP,
    ops: []align(1) std.os.linux.io_uring_probe_op,
};

const io_uring_probe = extern struct {
    /// Last opcode supported
    last_op: IORING_OP,
    /// Length of ops[] array below
    ops_len: u8,
    resv: u16,
    resv2: [3]u32,
    ops: [256]std.os.linux.io_uring_probe_op,

    const empty = std.mem.zeroInit(@This(), .{});
};

fn uring_probe_ops(probe: *io_uring_probe) !ProbeOpsResult {
    var io = try uring_init(2);
    defer io.deinit();
    const res = std.os.linux.io_uring_register(io.fd, .REGISTER_PROBE, probe, probe.ops.len);
    if (std.os.linux.E.init(res) != .SUCCESS) return error.Unexpected;
    return .{ .last_op = probe.last_op, .ops = probe.ops[0..probe.ops_len] };
}

fn uring_is_supported(ops: []const IORING_OP) bool {
    var buf = io_uring_probe.empty;
    const probe = uring_probe_ops(&buf) catch return false;
    for (ops) |op| {
        const supported = blk: {
            if (@intFromEnum(op) > @intFromEnum(probe.last_op)) break :blk false;
            if (@intFromEnum(op) > probe.ops.len) break :blk false;
            break :blk probe.ops[@intFromEnum(op)].flags & std.os.linux.IO_URING_OP_SUPPORTED != 0;
        };
        if (!supported) {
            log.warn("unsupported OP: {s}", .{@tagName(op)});
            return false;
        }
    }
    return true;
}

const Features = packed struct(u32) {
    single_mmap: bool,
    nodrop: bool,
    submit_stable: bool,
    rw_cur_pos: bool,
    cur_personality: bool,
    fast_poll: bool,
    poll_32bits: bool,
    sqpoll_nonfixed: bool,
    ext_arg: bool,
    native_workers: bool,
    rsrc_tags: bool,
    cqe_skip: bool,
    linked_file: bool,
    reg_reg_ring: bool,
    recvsend_bundle: bool,
    min_timeout: bool,
    rw_attr: bool,
    _: u15 = 0,
};

fn uring_init_inner(n: u16, flags: u32) !std.os.linux.IoUring {
    var params = std.mem.zeroInit(std.os.linux.io_uring_params, .{
        .flags = flags,
        .sq_thread_idle = 1000,
    });
    const ret = std.os.linux.IoUring.init_params(n, &params) catch |err| switch (err) {
        error.PermissionDenied,
        error.SystemResources,
        error.SystemOutdated,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => |e| e,
        error.ArgumentsInvalid => error.ArgumentsInvalid,
        else => error.Unexpected,
    };

    const wanted_features: []const std.meta.FieldEnum(Features) = &.{
        .nodrop,
        .submit_stable,
        .rw_cur_pos,
        .fast_poll,
        .sqpoll_nonfixed,
        .cqe_skip,
        .linked_file,
    };

    const feat: Features = @bitCast(params.features);
    inline for (wanted_features) |tag| {
        if (!@field(feat, @tagName(tag))) {
            log.warn("missing feature: {s}", .{@tagName(tag)});
            return error.SystemOutdated;
        }
    }

    return ret;
}

fn uring_init(n: u16) aio.Error!std.os.linux.IoUring {
    const flags: []const u32 = &.{
        // Disabled for now, this seems to increase syscalls a bit
        // However, it may still be beneficial from latency perspective
        // I need to play this with more later, and if there's no single answer
        // then it might be better to be exposed as a tunable.
        // std.os.linux.IORING_SETUP_SINGLE_ISSUER | std.os.linux.IORING_SETUP_DEFER_TASKRUN, // 6.1
        std.os.linux.IORING_SETUP_SINGLE_ISSUER | std.os.linux.IORING_SETUP_COOP_TASKRUN, // 6.0
        std.os.linux.IORING_SETUP_COOP_TASKRUN, // 5.9
        0, // 5.4
    };
    for (flags) |f| {
        return uring_init_inner(n, f | std.os.linux.IORING_SETUP_CLAMP) catch |err| switch (err) {
            error.ArgumentsInvalid => continue,
            else => |e| return e,
        };
    }
    return error.SystemOutdated;
}

fn uring_queue(io: *std.os.linux.IoUring, comptime op_type: Operation, op: op_type.Type(), link: aio.Link, user_data: u64, state: *UringOperation.State) aio.Error!void {
    debug("queue: {}: {}", .{ aio.Id.init(user_data), op_type });
    const Trash = struct {
        var u_64: u64 align(1) = undefined;
    };
    var sqe = switch (op_type) {
        .nop => try io.nop(user_data),
        .poll => try io.poll_add(user_data, op.fd, @intCast(@as(u16, @bitCast(op.events)))),
        .fsync => try io.fsync(user_data, op.file.handle, 0),
        .read_tty => try io.read(user_data, op.tty.handle, .{ .buffer = op.buffer }, 0),
        .read => try io.read(user_data, op.file.handle, .{ .buffer = op.buffer }, op.offset),
        .write => try io.write(user_data, op.file.handle, op.buffer, op.offset),
        .readv => blk: {
            const sqe = try io.get_sqe();
            sqe.prep_readv(op.file.handle, op.iov, op.offset);
            sqe.user_data = user_data;
            break :blk sqe;
        },
        .writev => try io.writev(user_data, op.file.handle, op.iov, op.offset),
        .accept => try io.accept(user_data, op.socket, op.out_addr, op.inout_addrlen, 0),
        .connect => try io.connect(user_data, op.socket, op.addr, op.addrlen),
        .bind => blk: {
            const sqe = try io.get_sqe();
            sqe.prep_rw(IORING_OP.BIND.toStd(), op.socket, @intFromPtr(op.addr), 0, op.addrlen);
            sqe.user_data = user_data;
            break :blk sqe;
        },
        .listen => blk: {
            const sqe = try io.get_sqe();
            sqe.prep_rw(IORING_OP.LISTEN.toStd(), op.socket, 0, op.backlog, 0);
            sqe.user_data = user_data;
            break :blk sqe;
        },
        .recv => try io.recv(user_data, op.socket, .{ .buffer = op.buffer }, 0),
        .send => try io.send(user_data, op.socket, op.buffer, 0),
        .recv_msg => try io.recvmsg(user_data, op.socket, op.out_msg, 0),
        .send_msg => try io.sendmsg(user_data, op.socket, op.msg, 0),
        .shutdown => try io.shutdown(user_data, op.socket, switch (op.how) {
            .recv => std.posix.SHUT.RD,
            .send => std.posix.SHUT.WR,
            .both => std.posix.SHUT.RDWR,
        }),
        .open_at => try io.openat(user_data, op.dir.fd, op.path, posix.convertOpenFlags(op.flags), 0),
        .close_file => try io.close(user_data, op.file.handle),
        .close_dir => try io.close(user_data, op.dir.fd),
        .timeout => try io.timeout(user_data, &state.timeout, 0, std.os.linux.IORING_TIMEOUT_ETIME_SUCCESS),
        .link_timeout => try io.link_timeout(user_data, &state.timeout, 0),
        .cancel => try io.cancel(user_data, op.id.cast(u64), 0),
        .rename_at => try io.renameat(user_data, op.old_dir.fd, op.old_path, op.new_dir.fd, op.new_path, linux.RENAME_NOREPLACE),
        .unlink_at => try io.unlinkat(user_data, op.dir.fd, op.path, 0),
        .mkdir_at => try io.mkdirat(user_data, op.dir.fd, op.path, op.mode),
        .symlink_at => try io.symlinkat(user_data, op.target, op.dir.fd, op.link_path),
        .child_exit => blk: {
            if (Supported.waitid) {
                break :blk try io.waitid(user_data, .PID, op.child, &state.child_exit.state.siginfo, std.posix.W.EXITED, 0);
            } else {
                const fd = fdblk: {
                    // Will propagate as BADF if the init fails
                    const cw = posix.ChildWatcher.init(op.child) catch break :fdblk posix.invalid_fd;
                    break :fdblk cw.fd;
                };
                state.child_exit.state.fd = fd;
                break :blk try io.poll_add(user_data, fd, std.posix.POLL.IN);
            }
        },
        .socket => try io.socket(user_data, op.domain, op.flags, op.protocol, 0),
        .close_socket => blk: {
            var sqe = try io.cancel(special_cqe, 0, std.os.linux.IORING_ASYNC_CANCEL_ALL | std.os.linux.IORING_ASYNC_CANCEL_FD);
            sqe.fd = op.socket;
            sqe.flags |= std.os.linux.IOSQE_IO_HARDLINK | std.os.linux.IOSQE_CQE_SKIP_SUCCESS;
            break :blk try io.close(user_data, op.socket);
        },
        .notify_event_source => try io.write(user_data, op.source.native.fd, &std.mem.toBytes(@as(u64, 1)), 0),
        .wait_event_source => try io.read(user_data, op.source.native.fd, .{ .buffer = std.mem.asBytes(&Trash.u_64) }, 0),
        .close_event_source => try io.close(user_data, op.source.native.fd),
        .splice => blk: {
            const Fd = struct { fd: std.posix.fd_t, off: u64 };
            const in: Fd = switch (op.in) {
                .pipe => |fd| .{ .fd = fd, .off = std.math.maxInt(u64) },
                .other => |other| .{ .fd = other.fd, .off = other.offset },
            };
            const out: Fd = switch (op.out) {
                .pipe => |fd| .{ .fd = fd, .off = std.math.maxInt(u64) },
                .other => |other| .{ .fd = other.fd, .off = other.offset },
            };
            var sqe = try io.splice(user_data, in.fd, in.off, out.fd, out.off, op.len);
            sqe.rw_flags |= @bitCast(op.flags);
            break :blk sqe;
        },
    };
    switch (link) {
        .unlinked => {},
        .soft => sqe.flags |= std.os.linux.IOSQE_IO_LINK,
        .hard => sqe.flags |= std.os.linux.IOSQE_IO_HARDLINK,
    }
    if (op.out_id) |id| id.* = aio.Id.init(user_data);
    if (op.out_error) |out_error| out_error.* = error.Success;
}

fn uring_submit(io: *std.os.linux.IoUring) aio.Error!u16 {
    while (true) {
        const n = io.submit() catch |err| switch (err) {
            error.FileDescriptorInvalid => unreachable,
            error.FileDescriptorInBadState => unreachable,
            error.BufferInvalid => unreachable,
            error.OpcodeNotSupported => unreachable,
            error.RingShuttingDown => unreachable,
            error.SubmissionQueueEntryInvalid => unreachable,
            error.SignalInterrupt => continue,
            error.CompletionQueueOvercommitted, error.Unexpected, error.SystemResources => |e| return e,
        };
        return @intCast(n);
    }
}

fn uring_copy_cqes(io: *std.os.linux.IoUring, cqes: []std.os.linux.io_uring_cqe, len: u16) aio.Error!u16 {
    while (true) {
        const n = io.copy_cqes(cqes, len) catch |err| switch (err) {
            error.FileDescriptorInvalid => unreachable,
            error.FileDescriptorInBadState => unreachable,
            error.BufferInvalid => unreachable,
            error.OpcodeNotSupported => unreachable,
            error.RingShuttingDown => unreachable,
            error.SubmissionQueueEntryInvalid => unreachable,
            error.SignalInterrupt => continue,
            error.CompletionQueueOvercommitted, error.Unexpected, error.SystemResources => |e| return e,
        };
        return @intCast(n);
    }
    unreachable;
}

fn uring_handle_completion(comptime op_type: Operation, op: op_type.Type(), state: *UringOperation.State, cqe: *std.os.linux.io_uring_cqe) !void {
    defer if (op_type == .child_exit and !Supported.waitid) {
        var watcher: posix.ChildWatcher = .{ .id = op.child, .fd = state.child_exit.state.fd };
        watcher.deinit();
    };

    const err = cqe.err();
    if (err != .SUCCESS) {
        const res: @TypeOf(op).Error = switch (op_type) {
            .nop => switch (err) {
                .CANCELED => error.Canceled,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .fsync => switch (err) {
                .SUCCESS, .INTR, .INVAL, .FAULT, .AGAIN, .ROFS => unreachable,
                .BADF => unreachable, // not a file
                .CANCELED => error.Canceled,
                .IO => error.InputOutput,
                .NOSPC => error.NoSpaceLeft,
                .DQUOT => error.DiskQuota,
                .PERM => error.AccessDenied,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .poll => switch (err) {
                .SUCCESS, .INTR, .AGAIN, .FAULT, .INVAL => unreachable,
                .CANCELED => error.Canceled,
                else => std.posix.unexpectedErrno(err),
            },
            .read_tty, .read, .readv => switch (err) {
                .SUCCESS, .INTR, .INVAL, .FAULT, .AGAIN, .ISDIR => unreachable,
                .CANCELED => error.Canceled,
                .BADF => error.NotOpenForReading,
                .IO => error.InputOutput,
                .PERM => error.AccessDenied,
                .PIPE => error.BrokenPipe,
                .NOBUFS => error.SystemResources,
                .NOMEM => error.SystemResources,
                .NOTCONN => error.SocketNotConnected,
                .CONNRESET => error.ConnectionResetByPeer,
                .TIMEDOUT => error.ConnectionTimedOut,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .write, .writev => switch (err) {
                .SUCCESS, .INTR, .INVAL, .FAULT, .AGAIN, .DESTADDRREQ => unreachable,
                .CANCELED => error.Canceled,
                .DQUOT => error.DiskQuota,
                .FBIG => error.FileTooBig,
                .BADF => error.NotOpenForWriting,
                .IO => error.InputOutput,
                .NOSPC => error.NoSpaceLeft,
                .PERM => error.AccessDenied,
                .PIPE => error.BrokenPipe,
                .NOBUFS => error.SystemResources,
                .NOMEM => error.SystemResources,
                .CONNRESET => error.ConnectionResetByPeer,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .accept => switch (err) {
                .SUCCESS, .INTR, .FAULT, .AGAIN, .DESTADDRREQ => unreachable,
                .CANCELED => error.Canceled,
                .BADF => unreachable, // always a race condition
                .CONNABORTED => error.ConnectionAborted,
                .INVAL => error.SocketNotListening,
                .NOTSOCK => unreachable,
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOBUFS => error.SystemResources,
                .NOMEM => error.SystemResources,
                .PROTO => error.ProtocolFailure,
                .PERM => error.BlockedByFirewall,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .connect => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN, .DESTADDRREQ, .INPROGRESS => unreachable,
                .CANCELED => error.Canceled,
                .ACCES => error.PermissionDenied,
                .PERM => error.PermissionDenied,
                .ADDRINUSE => error.AddressInUse,
                .ADDRNOTAVAIL => error.AddressNotAvailable,
                .AFNOSUPPORT => error.AddressFamilyNotSupported,
                .ALREADY => error.ConnectionPending,
                .BADF => unreachable, // sockfd is not a valid open file descriptor.
                .CONNREFUSED => error.ConnectionRefused,
                .CONNRESET => error.ConnectionResetByPeer,
                .FAULT => unreachable, // The socket structure address is outside the user's address space.
                .ISCONN => unreachable, // The socket is already connected.
                .HOSTUNREACH => error.NetworkUnreachable,
                .NETUNREACH => error.NetworkUnreachable,
                .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
                .PROTOTYPE => unreachable, // The socket type does not support the requested communications protocol.
                .TIMEDOUT => error.ConnectionTimedOut,
                .NOENT => error.FileNotFound, // Returned when socket is AF.UNIX and the given path does not exist.
                .CONNABORTED => unreachable, // Tried to reuse socket that previously received error.ConnectionRefused.
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .bind => switch (err) {
                .SUCCESS => unreachable,
                .CANCELED => error.Canceled,
                .ACCES, .PERM => return error.AccessDenied,
                .ADDRINUSE => return error.AddressInUse,
                .BADF => unreachable, // always a race condition if this error is returned
                .INVAL => unreachable, // invalid parameters
                .NOTSOCK => unreachable, // invalid `sockfd`
                .AFNOSUPPORT => return error.AddressFamilyNotSupported,
                .ADDRNOTAVAIL => return error.AddressNotAvailable,
                .FAULT => unreachable, // invalid `addr` pointer
                .LOOP => return error.SymLinkLoop,
                .NAMETOOLONG => return error.NameTooLong,
                .NOENT => return error.FileNotFound,
                .NOMEM => return error.SystemResources,
                .NOTDIR => return error.NotDir,
                .ROFS => return error.ReadOnlyFileSystem,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .listen => switch (err) {
                .SUCCESS => unreachable,
                .INVAL => unreachable,
                .CANCELED => error.Canceled,
                .ADDRINUSE => return error.AddressInUse,
                .BADF => unreachable,
                .NOTSOCK => return error.FileDescriptorNotASocket,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .recv => switch (err) {
                .SUCCESS, .INTR, .INVAL, .FAULT, .AGAIN => unreachable,
                .CANCELED => error.Canceled,
                .BADF => unreachable, // always a race condition
                .NOTCONN => error.SocketNotConnected,
                .NOTSOCK => unreachable,
                .NOMEM => error.SystemResources,
                .CONNREFUSED => error.ConnectionRefused,
                .CONNRESET => error.ConnectionResetByPeer,
                .TIMEDOUT => error.ConnectionTimedOut,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .send => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .CANCELED => error.Canceled,
                .ACCES => error.AccessDenied,
                .ALREADY => error.FastOpenAlreadyInProgress,
                .BADF => unreachable, // always a race condition
                .CONNRESET => error.ConnectionResetByPeer,
                .DESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
                .FAULT => unreachable, // An invalid user space address was specified for an argument.
                .ISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
                .MSGSIZE => error.MessageTooBig,
                .NOBUFS => error.SystemResources,
                .NOMEM => error.SystemResources,
                .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
                .PIPE => error.BrokenPipe,
                .HOSTUNREACH => error.NetworkUnreachable,
                .NETUNREACH => error.NetworkUnreachable,
                .NETDOWN => error.NetworkSubsystemFailed,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .recv_msg => switch (err) {
                .SUCCESS, .INTR, .INVAL, .FAULT, .AGAIN => unreachable,
                .CANCELED => error.Canceled,
                .BADF => unreachable, // always a race condition
                .NOTCONN => error.SocketNotConnected,
                .NOTSOCK => unreachable,
                .NOMEM => error.SystemResources,
                .CONNREFUSED => error.ConnectionRefused,
                .CONNRESET => error.ConnectionResetByPeer,
                .TIMEDOUT => error.ConnectionTimedOut,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .send_msg => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .CANCELED => error.Canceled,
                .ACCES => error.AccessDenied,
                .ALREADY => error.FastOpenAlreadyInProgress,
                .BADF => unreachable, // always a race condition
                .CONNRESET => error.ConnectionResetByPeer,
                .DESTADDRREQ => unreachable, // The socket is not connection-mode, and no peer address is set.
                .FAULT => unreachable, // An invalid user space address was specified for an argument.
                .ISCONN => unreachable, // connection-mode socket was connected already but a recipient was specified
                .MSGSIZE => error.MessageTooBig,
                .NOBUFS => error.SystemResources,
                .NOMEM => error.SystemResources,
                .NOTSOCK => unreachable, // The file descriptor sockfd does not refer to a socket.
                .PIPE => error.BrokenPipe,
                .HOSTUNREACH => error.NetworkUnreachable,
                .NETUNREACH => error.NetworkUnreachable,
                .NETDOWN => error.NetworkSubsystemFailed,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .shutdown => switch (err) {
                .SUCCESS, .BADF, .INVAL => unreachable,
                .NOTCONN => error.SocketNotConnected,
                .NOTSOCK => unreachable,
                .NOBUFS => error.SystemResources,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .open_at => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .CANCELED => error.Canceled,
                .ACCES => error.AccessDenied,
                .FBIG => error.FileTooBig,
                .OVERFLOW => error.FileTooBig,
                .ISDIR => error.IsDir,
                .LOOP => error.SymLinkLoop,
                .MFILE => error.ProcessFdQuotaExceeded,
                .NAMETOOLONG => error.NameTooLong,
                .NFILE => error.SystemFdQuotaExceeded,
                .NODEV => error.NoDevice,
                .NOENT => error.FileNotFound,
                .NOMEM => error.SystemResources,
                .NOSPC => error.NoSpaceLeft,
                .NOTDIR => error.NotDir,
                .PERM => error.AccessDenied,
                .EXIST => error.PathAlreadyExists,
                .BUSY => error.DeviceBusy,
                .ILSEQ => error.InvalidUtf8,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .close_file, .close_dir, .close_socket => switch (err) {
                .CANCELED => error.Canceled,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err) catch unreachable,
            },
            .notify_event_source => switch (err) {
                .CANCELED => error.Canceled,
                .OPNOTSUPP => error.OperationNotSupported,
                else => @panic("EventSource.notify failed"),
            },
            .wait_event_source => switch (err) {
                .CANCELED => error.Canceled,
                // XXX: Weird that eventfd gives us EAGAIN, should not happen
                //      This does not happen if EFD is not set to O_NONBLOCK
                // <https://github.com/axboe/liburing/issues/364>
                .AGAIN => error.Success, // ignore and hope that things are okay
                .OPNOTSUPP => error.OperationNotSupported,
                else => @panic("EventSource.wait failed"),
            },
            .close_event_source => switch (err) {
                .CANCELED => error.Canceled,
                .OPNOTSUPP => error.OperationNotSupported,
                else => unreachable,
            },
            .timeout => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .TIME => error.Success,
                .CANCELED => error.Canceled,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .link_timeout => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .TIME => error.Expired,
                .ALREADY, .CANCELED, .NOENT => error.Canceled,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .cancel => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .ALREADY => error.InProgress,
                .NOENT => error.NotFound,
                .CANCELED => error.Canceled,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .rename_at => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .CANCELED => error.Canceled,
                .ACCES => error.AccessDenied,
                .PERM => error.AccessDenied,
                .BUSY => error.FileBusy,
                .DQUOT => error.DiskQuota,
                .FAULT => unreachable,
                .ISDIR => error.IsDir,
                .LOOP => error.SymLinkLoop,
                .MLINK => error.LinkQuotaExceeded,
                .NAMETOOLONG => error.NameTooLong,
                .NOENT => error.FileNotFound,
                .NOTDIR => error.NotDir,
                .NOMEM => error.SystemResources,
                .NOSPC => error.NoSpaceLeft,
                .EXIST => error.PathAlreadyExists,
                .NOTEMPTY => error.PathAlreadyExists,
                .ROFS => error.ReadOnlyFileSystem,
                .XDEV => error.RenameAcrossMountPoints,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .unlink_at => switch (err) {
                .SUCCESS, .INTR, .AGAIN => unreachable,
                .CANCELED => error.Canceled,
                .ACCES => error.AccessDenied,
                .PERM => error.AccessDenied,
                .BUSY => error.FileBusy,
                .FAULT => unreachable,
                .IO => error.FileSystem,
                .ISDIR => error.IsDir,
                .LOOP => error.SymLinkLoop,
                .NAMETOOLONG => error.NameTooLong,
                .NOENT => error.FileNotFound,
                .NOTDIR => error.NotDir,
                .NOMEM => error.SystemResources,
                .ROFS => error.ReadOnlyFileSystem,
                .EXIST => error.DirNotEmpty,
                .NOTEMPTY => error.DirNotEmpty,
                .INVAL => unreachable, // invalid flags, or pathname has . as last component
                .BADF => unreachable, // always a race condition
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .mkdir_at => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .CANCELED => error.Canceled,
                .ACCES => error.AccessDenied,
                .BADF => unreachable,
                .PERM => error.AccessDenied,
                .DQUOT => error.DiskQuota,
                .EXIST => error.PathAlreadyExists,
                .FAULT => unreachable,
                .LOOP => error.SymLinkLoop,
                .MLINK => error.LinkQuotaExceeded,
                .NAMETOOLONG => error.NameTooLong,
                .NOENT => error.FileNotFound,
                .NOMEM => error.SystemResources,
                .NOSPC => error.NoSpaceLeft,
                .NOTDIR => error.NotDir,
                .ROFS => error.ReadOnlyFileSystem,
                // dragonfly: when dir_fd is unlinked from filesystem
                .NOTCONN => error.FileNotFound,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .symlink_at => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN, .FAULT => unreachable,
                .CANCELED => error.Canceled,
                .ACCES => error.AccessDenied,
                .PERM => error.AccessDenied,
                .DQUOT => error.DiskQuota,
                .EXIST => error.PathAlreadyExists,
                .IO => error.FileSystem,
                .LOOP => error.SymLinkLoop,
                .NAMETOOLONG => error.NameTooLong,
                .NOENT => error.FileNotFound,
                .NOTDIR => error.NotDir,
                .NOMEM => error.SystemResources,
                .NOSPC => error.NoSpaceLeft,
                .ROFS => error.ReadOnlyFileSystem,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .child_exit => switch (err) {
                .SUCCESS, .INTR, .AGAIN, .FAULT => unreachable,
                .CANCELED => error.Canceled,
                .CHILD, .INVAL => error.NotFound, // inval if child_exit is emulated with poll
                else => std.posix.unexpectedErrno(err),
            },
            .socket => switch (err) {
                .SUCCESS, .INTR, .AGAIN, .FAULT => unreachable,
                .CANCELED => error.Canceled,
                .ACCES => error.PermissionDenied,
                .AFNOSUPPORT => error.AddressFamilyNotSupported,
                .INVAL => error.ProtocolFamilyNotAvailable,
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOBUFS => error.SystemResources,
                .NOMEM => error.SystemResources,
                .PROTONOSUPPORT => error.ProtocolNotSupported,
                .PROTOTYPE => error.SocketTypeNotSupported,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
            .splice => switch (err) {
                .SUCCESS, .INTR, .AGAIN, .INVAL, .BADF, .SPIPE => unreachable,
                .CANCELED => error.Canceled,
                .NOMEM => error.SystemResources,
                .OPNOTSUPP => error.OperationNotSupported,
                else => std.posix.unexpectedErrno(err),
            },
        };

        if (op.out_error) |out_error| out_error.* = res;

        if (res != error.Success) {
            if (op_type == .link_timeout and res == error.Canceled) {
                // special case
            } else {
                debug("complete: {}: {} [FAIL] {}", .{ aio.Id.init(cqe.user_data), op_type, res });
                return error.OperationFailed;
            }
        }
    }

    debug("complete: {}: {} [OK]", .{ aio.Id.init(cqe.user_data), op_type });

    switch (op_type) {
        .nop => {},
        .fsync => {},
        .poll => {},
        .accept => op.out_socket.* = cqe.res,
        .connect, .bind, .listen => {},
        .read_tty, .read, .readv, .recv, .recv_msg => op.out_read.* = @intCast(cqe.res),
        .write, .writev, .send, .send_msg, .splice => if (op.out_written) |w| {
            w.* = @intCast(cqe.res);
        },
        .shutdown => {},
        .open_at => op.out_file.handle = cqe.res,
        .close_file, .close_dir, .close_socket => {},
        .notify_event_source, .wait_event_source, .close_event_source => {},
        .timeout, .link_timeout => {},
        .cancel => {},
        .rename_at, .unlink_at, .mkdir_at, .symlink_at => {},
        .child_exit => {
            if (Supported.waitid) {
                if (op.out_term) |term| {
                    term.* = posix.statusToTerm(@intCast(state.child_exit.state.siginfo.fields.common.second.sigchld.status));
                }
            } else {
                try posix.perform(.child_exit, op, .{ .fd = state.child_exit.state.fd, .events = .{ .in = true } });
            }
        },
        .socket => op.out_socket.* = cqe.res,
    }
}

fn debug(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) {
        std.debug.print("io_uring: " ++ fmt ++ "\n", args);
    } else {
        if (comptime !aio.options.debug) return;
        log.debug(fmt, args);
    }
}

// std is not in sync
const IORING_OP = enum(u8) {
    NOP, // 5.1
    READV, // 5.1
    WRITEV, // 5.1
    FSYNC, // 5.1
    READ_FIXED, // 5.1
    WRITE_FIXED, // 5.1
    POLL_ADD, // 5.1
    POLL_REMOVE, // 5.1
    SYNC_FILE_RANGE, // 5.2
    SENDMSG, // 5.3
    RECVMSG, // 5.3
    TIMEOUT, // 5.4
    TIMEOUT_REMOVE, // 5.4
    ACCEPT, // 5.5
    ASYNC_CANCEL, // 5.5
    LINK_TIMEOUT, // 5.5
    CONNECT, // 5.5
    FALLOCATE, // 5.6
    OPENAT, // 5.15
    CLOSE, // 5.15
    FILES_UPDATE, // 5.6
    STATX, // 5.6
    READ, // 5.6
    WRITE, // 5.6
    FADVISE, // 5.6
    MADVISE, // 5.6
    SEND, // 5.6
    RECV, // 5.6
    OPENAT2, // 5.15
    EPOLL_CTL, // 5.6
    SPLICE, // 5.7
    PROVIDE_BUFFERS, // 5.7
    REMOVE_BUFFERS, // 5.7
    TEE, // 5.8
    SHUTDOWN, // 5.11
    RENAMEAT, // 5.11
    UNLINKAT, // 5.11
    MKDIRAT, // 5.15
    SYMLINKAT, // 5.15
    LINKAT, // 5.15
    MSG_RING, // 5.18
    FSETXATTR, // 5.19
    SETXATTR, // 5.19
    FGETXATTR, // 5.19
    GETXATTR, // 5.19
    SOCKET, // 5.19
    URING_CMD, // 5.19
    SEND_ZC, // 6.0
    SENDMSG_ZC, // 6.1
    READ_MULTISHOT, // 6.7
    WAITID, // 6.5
    FUTEX_WAIT, // 6.7
    FUTEX_WAKE, // 6.7
    FUTEX_WAITV, // 6.7
    FIXED_FD_INSTALL, // 6.8
    FTRUNCATE, // 6.9
    BIND, // 6.11
    LISTEN, // 6.11
    _,

    pub fn fromStd(op: std.os.linux.IORING_OP) @This() {
        return @enumFromInt(@intFromEnum(op));
    }

    pub fn toStd(self: @This()) std.os.linux.IORING_OP {
        return @enumFromInt(@intFromEnum(self));
    }
};
