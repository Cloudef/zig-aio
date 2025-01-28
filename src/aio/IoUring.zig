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
        waitid = uring_is_supported(&.{std.os.linux.IORING_OP.WAITID});
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
        nop: usize,
        child_exit: struct {
            child: std.process.Child.Id,
            state: union {
                // only required for converting IORING_OP_WAITID result
                siginfo: std.posix.siginfo_t,
                // soft-fallback when IORING_OP_WAITID is not available (requires kernel 6.5)
                fd: std.posix.fd_t,
            },
        },
        timeout: std.os.linux.kernel_timespec,

        fn init(comptime op_type: Operation, op: Operation.map.getAssertContains(op_type)) @This() {
            return switch (op_type) {
                .nop => .{ .nop = op.ident },
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
    out_error: ?*anyerror = null,
    out_result: *Operation.anyresult,

    // some pairs require mutable state
    state: State,
};

const IdAllocator = aio.Id.Allocator(UringOperation);

io: std.os.linux.IoUring,
ops: IdAllocator,
cqes: []std.os.linux.io_uring_cqe,

pub fn isSupported(op_types: []const Operation) bool {
    var ops: [Operation.map.count()]std.os.linux.IORING_OP = undefined;
    for (op_types, ops[0..op_types.len]) |op_type, *op| {
        op.* = switch (op_type) {
            .nop => std.os.linux.IORING_OP.NOP, // 5.1
            .fsync => std.os.linux.IORING_OP.FSYNC, // 5.1
            .poll, .child_exit => std.os.linux.IORING_OP.POLL_ADD, // 5.1 (child_exit uses waitid if available 6.5)
            .read_tty, .read, .wait_event_source => std.os.linux.IORING_OP.READ, // 5.6
            .write, .notify_event_source => std.os.linux.IORING_OP.WRITE, // 5.6
            .accept => std.os.linux.IORING_OP.ACCEPT, // 5.5
            .connect => std.os.linux.IORING_OP.CONNECT, // 5.5
            .recv => std.os.linux.IORING_OP.RECV, // 5.6
            .send => std.os.linux.IORING_OP.SEND, // 5.6
            .recv_msg => std.os.linux.IORING_OP.RECVMSG, // 5.3
            .send_msg => std.os.linux.IORING_OP.SENDMSG, // 5.3
            .shutdown => std.os.linux.IORING_OP.SHUTDOWN, // 5.11
            .open_at => std.os.linux.IORING_OP.OPENAT, // 5.15
            .close_file, .close_dir, .close_socket, .close_event_source => std.os.linux.IORING_OP.CLOSE, // 5.15
            .timeout => std.os.linux.IORING_OP.TIMEOUT, // 5.4
            .link_timeout => std.os.linux.IORING_OP.LINK_TIMEOUT, // 5.5
            .cancel => std.os.linux.IORING_OP.ASYNC_CANCEL, // 5.5
            .rename_at => std.os.linux.IORING_OP.RENAMEAT, // 5.11
            .unlink_at => std.os.linux.IORING_OP.UNLINKAT, // 5.11
            .mkdir_at => std.os.linux.IORING_OP.MKDIRAT, // 5.15
            .symlink_at => std.os.linux.IORING_OP.SYMLINKAT, // 5.15
            .socket => std.os.linux.IORING_OP.SOCKET, // 5.19
        };
    }
    return uring_is_supported(ops[0..op_types.len]);
}

/// TODO: give options perhaps? More customization?
pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    Supported.query();
    const n2 = std.math.ceilPowerOfTwo(u16, n) catch unreachable;
    var io = try uring_init(n2);
    errdefer io.deinit();
    var ops = try IdAllocator.init(allocator, @intCast(io.sq.sqes.len));
    errdefer ops.deinit(allocator);
    const cqes = try allocator.alloc(std.os.linux.io_uring_cqe, @intCast(io.cq.cqes.len));
    errdefer allocator.free(cqes);
    return .{ .io = io, .ops = ops, .cqes = cqes };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.io.deinit();
    self.ops.deinit(allocator);
    allocator.free(self.cqes);
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
pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode, handler: anytype) aio.Error!aio.CompletionResult {
    if (self.ops.empty()) return .{};
    _ = try uring_submit(&self.io);

    var result: aio.CompletionResult = .{};
    const n = try uring_copy_cqes(&self.io, self.cqes, if (mode == .nonblocking) 0 else 1);
    for (self.cqes[0..n]) |*cqe| {
        const id = aio.Id.init(cqe.user_data);
        defer self.ops.release(id) catch unreachable;
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
                var op: Operation.map.getAssertContains(tag) = undefined;
                op.out_id = self.ops.getOne(.out_id, id);
                op.out_error = @ptrCast(self.ops.getOne(.out_error, id));
                op.out_socket = self.ops.getOne(.out_result, id).cast(*std.posix.socket_t);
                break :blk uring_handle_completion(tag, op, undefined, cqe);
            },
            inline .read, .read_tty, .recv, .recv_msg => |tag| blk: {
                var op: Operation.map.getAssertContains(tag) = undefined;
                op.out_id = self.ops.getOne(.out_id, id);
                op.out_error = @ptrCast(self.ops.getOne(.out_error, id));
                op.out_read = self.ops.getOne(.out_result, id).cast(*usize);
                break :blk uring_handle_completion(tag, op, undefined, cqe);
            },
            inline .write, .send, .send_msg => |tag| blk: {
                var op: Operation.map.getAssertContains(tag) = undefined;
                op.out_id = self.ops.getOne(.out_id, id);
                op.out_error = @ptrCast(self.ops.getOne(.out_error, id));
                op.out_written = self.ops.getOne(.out_result, id).cast(?*usize);
                break :blk uring_handle_completion(tag, op, undefined, cqe);
            },
            inline .open_at => |tag| blk: {
                var op: Operation.map.getAssertContains(tag) = undefined;
                op.out_id = self.ops.getOne(.out_id, id);
                op.out_error = @ptrCast(self.ops.getOne(.out_error, id));
                op.out_file = self.ops.getOne(.out_result, id).cast(*std.fs.File);
                break :blk uring_handle_completion(tag, op, undefined, cqe);
            },
            inline .nop,
            .fsync,
            .poll,
            .connect,
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
                var op: Operation.map.getAssertContains(tag) = undefined;
                op.out_id = self.ops.getOne(.out_id, id);
                op.out_error = @ptrCast(self.ops.getOne(.out_error, id));
                break :blk uring_handle_completion(tag, op, undefined, cqe);
            },
        } catch {
            result.num_errors += 1;
            failed = true;
        };
        if (@TypeOf(handler) != void) {
            handler.aio_complete(id, self.ops.getOne(.userdata, id), failed);
        }
    }

    result.num_completed = n;
    return result;
}

pub fn immediate(pairs: anytype) aio.Error!u16 {
    Supported.query();

    var io = try uring_init(std.math.ceilPowerOfTwo(u16, pairs.len) catch unreachable);
    defer io.deinit();

    var state: [pairs.len]UringOperation.State = undefined;
    inline for (pairs, 0..) |pair, idx| {
        state[idx] = UringOperation.State.init(pair.tag, pair.op);
        try uring_queue(&io, pair.tag, pair.op, pair.link, idx, &state[idx]);
    }

    var num = try uring_submit(&io);
    std.debug.assert(num == pairs.len);

    var num_errors: u16 = 0;
    var cqes: [pairs.len]std.os.linux.io_uring_cqe = undefined;
    while (num > 0) {
        const n = try uring_copy_cqes(&io, &cqes, num);
        for (cqes[0..n]) |*cqe| {
            @setEvalBranchQuota(1000 * pairs.len);
            inline for (pairs, 0..) |pair, idx| if (idx == cqe.user_data) {
                uring_handle_completion(pair.tag, pair.op, &state[idx], cqe) catch {
                    num_errors += 1;
                };
            };
        }
        num -= n;
    }

    return num_errors;
}

const ProbeOpsBuffer = [@sizeOf(std.os.linux.io_uring_probe) + 256 * @sizeOf(std.os.linux.io_uring_probe_op)]u8;

const ProbeOpsResult = struct {
    last_op: std.os.linux.IORING_OP,
    ops: []align(1) std.os.linux.io_uring_probe_op,
};

fn uring_probe_ops(mem: *ProbeOpsBuffer) !ProbeOpsResult {
    var io = try uring_init(2);
    defer io.deinit();
    var fba = std.heap.FixedBufferAllocator.init(mem);
    var pbuf = fba.allocator().alloc(u8, @sizeOf(std.os.linux.io_uring_probe) + 256 * @sizeOf(std.os.linux.io_uring_probe_op)) catch unreachable;
    @memset(pbuf, 0);
    const res = std.os.linux.io_uring_register(io.fd, .REGISTER_PROBE, pbuf.ptr, 256);
    if (std.os.linux.E.init(res) != .SUCCESS) return error.Unexpected;
    const probe = std.mem.bytesAsValue(std.os.linux.io_uring_probe, pbuf[0..@sizeOf(std.os.linux.io_uring_probe)]);
    const ops = std.mem.bytesAsSlice(std.os.linux.io_uring_probe_op, pbuf[@sizeOf(std.os.linux.io_uring_probe)..]);
    return .{ .last_op = probe.last_op, .ops = ops[0..probe.ops_len] };
}

fn uring_is_supported(ops: []const std.os.linux.IORING_OP) bool {
    var buf: ProbeOpsBuffer = undefined;
    const probe = uring_probe_ops(&buf) catch return false;
    for (ops) |op| {
        const supported = blk: {
            if (@intFromEnum(op) > @intFromEnum(probe.last_op)) break :blk false;
            if (probe.ops[@intFromEnum(op)].flags & std.os.linux.IO_URING_OP_SUPPORTED == 0) break :blk false;
            break :blk true;
        };
        if (!supported) {
            log.warn("unsupported OP: {s}", .{@tagName(op)});
            return false;
        }
    }
    return true;
}

fn uring_init_inner(n: u16, flags: u32) !std.os.linux.IoUring {
    return std.os.linux.IoUring.init(n, flags) catch |err| switch (err) {
        error.PermissionDenied,
        error.SystemResources,
        error.SystemOutdated,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        => |e| e,
        error.ArgumentsInvalid => error.ArgumentsInvalid,
        else => error.Unexpected,
    };
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
        return uring_init_inner(n, f) catch |err| switch (err) {
            error.ArgumentsInvalid => continue,
            else => |e| return e,
        };
    }
    return error.SystemOutdated;
}

fn uring_queue(io: *std.os.linux.IoUring, comptime op_type: Operation, op: Operation.map.getAssertContains(op_type), link: aio.Link, user_data: u64, state: *UringOperation.State) aio.Error!void {
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
        .accept => try io.accept(user_data, op.socket, op.out_addr, op.inout_addrlen, 0),
        .connect => try io.connect(user_data, op.socket, op.addr, op.addrlen),
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
        .timeout => try io.timeout(user_data, &state.timeout, 0, 0),
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
        .close_socket => try io.close(user_data, op.socket),
        .notify_event_source => try io.write(user_data, op.source.native.fd, &std.mem.toBytes(@as(u64, 1)), 0),
        .wait_event_source => try io.read(user_data, op.source.native.fd, .{ .buffer = std.mem.asBytes(&Trash.u_64) }, 0),
        .close_event_source => try io.close(user_data, op.source.native.fd),
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

fn uring_handle_completion(comptime op_type: Operation, op: Operation.map.getAssertContains(op_type), state: *UringOperation.State, cqe: *std.os.linux.io_uring_cqe) !void {
    defer if (op_type == .child_exit and !Supported.waitid) {
        var watcher: posix.ChildWatcher = .{ .id = op.child, .fd = state.child_exit.state.fd };
        watcher.deinit();
    };

    const err = cqe.err();
    if (err != .SUCCESS) {
        const res: @TypeOf(op).Error = switch (op_type) {
            .nop => switch (err) {
                .CANCELED => error.Canceled,
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
                else => std.posix.unexpectedErrno(err),
            },
            .poll => switch (err) {
                .SUCCESS, .INTR, .AGAIN, .FAULT, .INVAL => unreachable,
                .CANCELED => error.Canceled,
                else => std.posix.unexpectedErrno(err),
            },
            .read_tty, .read => switch (err) {
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
                else => std.posix.unexpectedErrno(err),
            },
            .write => switch (err) {
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
                .OPNOTSUPP => unreachable,
                .PROTO => error.ProtocolFailure,
                .PERM => error.BlockedByFirewall,
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
                .OPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
                .PIPE => error.BrokenPipe,
                .HOSTUNREACH => error.NetworkUnreachable,
                .NETUNREACH => error.NetworkUnreachable,
                .NETDOWN => error.NetworkSubsystemFailed,
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
                .OPNOTSUPP => unreachable, // Some bit in the flags argument is inappropriate for the socket type.
                .PIPE => error.BrokenPipe,
                .HOSTUNREACH => error.NetworkUnreachable,
                .NETUNREACH => error.NetworkUnreachable,
                .NETDOWN => error.NetworkSubsystemFailed,
                else => std.posix.unexpectedErrno(err),
            },
            .shutdown => switch (err) {
                .SUCCESS, .BADF, .INVAL => unreachable,
                .NOTCONN => error.SocketNotConnected,
                .NOTSOCK => unreachable,
                .NOBUFS => error.SystemResources,
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
                else => std.posix.unexpectedErrno(err),
            },
            .close_file, .close_dir, .close_socket => switch (err) {
                .CANCELED => error.Canceled,
                else => std.posix.unexpectedErrno(err) catch unreachable,
            },
            .notify_event_source, .wait_event_source, .close_event_source => switch (err) {
                .CANCELED => error.Canceled,
                else => std.posix.unexpectedErrno(err),
            },
            .timeout => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .TIME => error.Success,
                .CANCELED => error.Canceled,
                else => std.posix.unexpectedErrno(err),
            },
            .link_timeout => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .TIME => error.Expired,
                .ALREADY, .CANCELED => error.Canceled,
                else => std.posix.unexpectedErrno(err),
            },
            .cancel => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .ALREADY => error.InProgress,
                .NOENT => error.NotFound,
                .CANCELED => error.Canceled,
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
        .read_tty, .read => op.out_read.* = @intCast(cqe.res),
        .write => if (op.out_written) |w| {
            w.* = @intCast(cqe.res);
        },
        .accept => op.out_socket.* = cqe.res,
        .connect => {},
        .recv, .recv_msg => op.out_read.* = @intCast(cqe.res),
        .send, .send_msg => if (op.out_written) |w| {
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
