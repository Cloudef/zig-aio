const std = @import("std");
const aio = @import("../aio.zig");
const Operation = @import("ops.zig").Operation;
const Pool = @import("common/types.zig").Pool;
const posix = @import("common/posix.zig");
const log = std.log.scoped(.io_uring);

fn debug(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) {
        std.debug.print("io_uring: " ++ fmt ++ "\n", args);
    } else {
        if (comptime !aio.options.debug) return;
        log.debug(fmt, args);
    }
}

pub const EventSource = @import("common/EventFd.zig");

io: std.os.linux.IoUring,
ops: Pool(Operation.Union, u16),

pub fn isSupported(op_types: []const type) bool {
    var buf: ProbeOpsBuffer = undefined;
    const probe = uring_probe_ops(&buf) catch return false;
    inline for (op_types) |op_type| {
        const io_uring_op = switch (Operation.tagFromPayloadType(op_type)) {
            .fsync => std.os.linux.IORING_OP.FSYNC,
            .read, .wait_event_source => std.os.linux.IORING_OP.READ,
            .write, .notify_event_source => std.os.linux.IORING_OP.WRITE,
            .accept => std.os.linux.IORING_OP.ACCEPT,
            .connect => std.os.linux.IORING_OP.CONNECT,
            .recv => std.os.linux.IORING_OP.RECV,
            .send => std.os.linux.IORING_OP.SEND,
            .open_at => std.os.linux.IORING_OP.OPENAT,
            .close_file, .close_dir, .close_socket, .close_event_source => std.os.linux.IORING_OP.CLOSE,
            .timeout => std.os.linux.IORING_OP.TIMEOUT,
            .link_timeout => std.os.linux.IORING_OP.LINK_TIMEOUT,
            .cancel => std.os.linux.IORING_OP.ASYNC_CANCEL,
            .rename_at => std.os.linux.IORING_OP.RENAMEAT,
            .unlink_at => std.os.linux.IORING_OP.UNLINKAT,
            .mkdir_at => std.os.linux.IORING_OP.MKDIRAT,
            .symlink_at => std.os.linux.IORING_OP.SYMLINKAT,
            .child_exit => std.os.linux.IORING_OP.WAITID,
            .socket => std.os.linux.IORING_OP.SOCKET,
        };
        const supported = blk: {
            if (@intFromEnum(io_uring_op) > @intFromEnum(probe.last_op)) break :blk false;
            if (probe.ops[@intFromEnum(io_uring_op)].flags & std.os.linux.IO_URING_OP_SUPPORTED == 0) break :blk false;
            break :blk true;
        };
        if (!supported) {
            log.warn("unsupported OP: {} => {s}", .{ op_type, @tagName(io_uring_op) });
            return false;
        }
    }
    return true;
}

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    const n2 = std.math.ceilPowerOfTwo(u16, n) catch unreachable;
    var io = try uring_init(n2);
    errdefer io.deinit();
    const ops = try Pool(Operation.Union, u16).init(allocator, n2);
    errdefer ops.deinit(allocator);
    return .{ .io = io, .ops = ops };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.io.deinit();
    self.ops.deinit(allocator);
    self.* = undefined;
}

inline fn queueOperation(self: *@This(), op: anytype) aio.Error!u16 {
    const n = self.ops.next() orelse return error.OutOfMemory;
    try uring_queue(&self.io, op, n);
    const tag = @tagName(comptime Operation.tagFromPayloadType(@TypeOf(op.*)));
    return self.ops.add(@unionInit(Operation.Union, tag, op.*)) catch unreachable;
}

pub fn queue(self: *@This(), comptime len: u16, work: anytype) aio.Error!void {
    if (comptime len == 1) {
        _ = try self.queueOperation(&work.ops[0]);
    } else {
        var ids: std.BoundedArray(u16, len) = .{};
        errdefer for (ids.constSlice()) |id| self.ops.remove(id);
        inline for (&work.ops) |*op| ids.append(try self.queueOperation(op)) catch unreachable;
    }
}

pub const NOP = std.math.maxInt(u64);

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode) aio.Error!aio.CompletionResult {
    if (self.ops.empty()) return .{};
    if (mode == .nonblocking) {
        _ = self.io.nop(NOP) catch |err| return switch (err) {
            error.SubmissionQueueFull => .{},
        };
    }
    _ = try uring_submit(&self.io);
    var result: aio.CompletionResult = .{};
    var cqes: [aio.options.io_uring_cqe_sz]std.os.linux.io_uring_cqe = undefined;
    const n = try uring_copy_cqes(&self.io, &cqes, 1);
    for (cqes[0..n]) |*cqe| {
        if (cqe.user_data == NOP) continue;
        defer self.ops.remove(@intCast(cqe.user_data));
        switch (self.ops.get(@intCast(cqe.user_data)).*) {
            inline else => |op| uring_handle_completion(&op, cqe) catch {
                result.num_errors += 1;
            },
        }
    }
    result.num_completed = n - @intFromBool(mode == .nonblocking);
    return result;
}

pub fn immediate(comptime len: u16, work: anytype) aio.Error!u16 {
    var io = try uring_init(std.math.ceilPowerOfTwo(u16, len) catch unreachable);
    defer io.deinit();
    inline for (&work.ops, 0..) |*op, idx| try uring_queue(&io, op, idx);
    var num = try uring_submit(&io);
    var num_errors: u16 = 0;
    var cqes: [len]std.os.linux.io_uring_cqe = undefined;
    while (num > 0) {
        const n = try uring_copy_cqes(&io, &cqes, num);
        for (cqes[0..n]) |*cqe| {
            inline for (&work.ops, 0..) |*op, idx| if (idx == cqe.user_data) {
                uring_handle_completion(op, cqe) catch {
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

inline fn uring_probe_ops(mem: *ProbeOpsBuffer) !ProbeOpsResult {
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

inline fn uring_init_inner(n: u16, flags: u32) !std.os.linux.IoUring {
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

inline fn uring_init(n: u16) aio.Error!std.os.linux.IoUring {
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

inline fn uring_queue(io: *std.os.linux.IoUring, op: anytype, user_data: u64) aio.Error!void {
    debug("queue: {}: {}", .{ user_data, comptime Operation.tagFromPayloadType(@TypeOf(op.*)) });
    const Trash = struct {
        var u_64: u64 align(1) = undefined;
    };
    var sqe = switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .fsync => try io.fsync(user_data, op.file.handle, 0),
        .read => try io.read(user_data, op.file.handle, .{ .buffer = op.buffer }, op.offset),
        .write => try io.write(user_data, op.file.handle, op.buffer, op.offset),
        .accept => try io.accept(user_data, op.socket, op.addr, op.inout_addrlen, 0),
        .connect => try io.connect(user_data, op.socket, op.addr, op.addrlen),
        .recv => try io.recv(user_data, op.socket, .{ .buffer = op.buffer }, 0),
        .send => try io.send(user_data, op.socket, op.buffer, 0),
        .open_at => try io.openat(user_data, op.dir.fd, op.path, posix.convertOpenFlags(op.flags), 0),
        .close_file => try io.close(user_data, op.file.handle),
        .close_dir => try io.close(user_data, op.dir.fd),
        .timeout => blk: {
            const ts: std.os.linux.timespec = .{
                .tv_sec = @intCast(op.ns / std.time.ns_per_s),
                .tv_nsec = @intCast(op.ns % std.time.ns_per_s),
            };
            break :blk try io.timeout(user_data, &ts, 0, 0);
        },
        .link_timeout => blk: {
            const ts: std.os.linux.timespec = .{
                .tv_sec = @intCast(op.ns / std.time.ns_per_s),
                .tv_nsec = @intCast(op.ns % std.time.ns_per_s),
            };
            break :blk try io.link_timeout(user_data, &ts, 0);
        },
        .cancel => try io.cancel(user_data, @intFromEnum(op.id), 0),
        .rename_at => try io.renameat(user_data, op.old_dir.fd, op.old_path, op.new_dir.fd, op.new_path, posix.RENAME_NOREPLACE),
        .unlink_at => try io.unlinkat(user_data, op.dir.fd, op.path, 0),
        .mkdir_at => try io.mkdirat(user_data, op.dir.fd, op.path, op.mode),
        .symlink_at => try io.symlinkat(user_data, op.target, op.dir.fd, op.link_path),
        .child_exit => try io.waitid(user_data, .PID, op.child, @constCast(&op._), std.posix.W.EXITED, 0),
        .socket => try io.socket(user_data, op.domain, op.flags, op.protocol, 0),
        .close_socket => try io.close(user_data, op.socket),
        .notify_event_source => try io.write(user_data, op.source.native.fd, &std.mem.toBytes(@as(u64, 1)), 0),
        .wait_event_source => try io.read(user_data, op.source.native.fd, .{ .buffer = std.mem.asBytes(&Trash.u_64) }, 0),
        .close_event_source => try io.close(user_data, op.source.native.fd),
    };
    switch (op.link) {
        .unlinked => {},
        .soft => sqe.flags |= std.os.linux.IOSQE_IO_LINK,
        .hard => sqe.flags |= std.os.linux.IOSQE_IO_HARDLINK,
    }
    if (@hasField(@TypeOf(op.*), "out_id")) {
        if (op.out_id) |id| id.* = @enumFromInt(user_data);
    }
    if (op.out_error) |out_error| out_error.* = error.Success;
}

inline fn uring_submit(io: *std.os.linux.IoUring) aio.Error!u16 {
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

inline fn uring_copy_cqes(io: *std.os.linux.IoUring, cqes: []std.os.linux.io_uring_cqe, len: u16) aio.Error!u16 {
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

inline fn uring_handle_completion(op: anytype, cqe: *std.os.linux.io_uring_cqe) !void {
    switch (op.counter) {
        .dec => |c| c.* -= 1,
        .inc => |c| c.* += 1,
        .nop => {},
    }

    const err = cqe.err();
    if (err != .SUCCESS) {
        const res: @TypeOf(op.*).Error = switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
            .fsync => switch (err) {
                .SUCCESS, .INTR, .INVAL, .FAULT, .AGAIN, .ROFS => unreachable,
                .BADF => unreachable, // not a file
                .CANCELED => error.OperationCanceled,
                .IO => error.InputOutput,
                .NOSPC => error.NoSpaceLeft,
                .DQUOT => error.DiskQuota,
                .PERM => error.AccessDenied,
                else => std.posix.unexpectedErrno(err),
            },
            .read => switch (err) {
                .SUCCESS, .INTR, .INVAL, .FAULT, .AGAIN, .ISDIR => unreachable,
                .CANCELED => error.OperationCanceled,
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
                .CANCELED => error.OperationCanceled,
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
                .CANCELED => error.OperationCanceled,
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
                .CANCELED => error.OperationCanceled,
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
                .CANCELED => error.OperationCanceled,
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
                .CANCELED => error.OperationCanceled,
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
            .open_at => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .CANCELED => error.OperationCanceled,
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
            .close_file, .close_dir, .close_socket => unreachable,
            .notify_event_source, .wait_event_source, .close_event_source => unreachable,
            .timeout => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .TIME => error.Success,
                .CANCELED => error.OperationCanceled,
                else => unreachable,
            },
            .link_timeout => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .TIME => error.Expired,
                .ALREADY, .CANCELED => error.OperationCanceled,
                else => unreachable,
            },
            .cancel => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .ALREADY => error.InProgress,
                .NOENT => error.NotFound,
                else => unreachable,
            },
            .rename_at => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .CANCELED => error.OperationCanceled,
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
                .CANCELED => error.OperationCanceled,
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
                .SUCCESS, .INTR, .AGAIN, .FAULT, .INVAL => unreachable,
                .CHILD => error.NotFound,
                else => std.posix.unexpectedErrno(err),
            },
            .socket => switch (err) {
                .SUCCESS, .INTR, .AGAIN, .FAULT => unreachable,
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
            if ((comptime Operation.tagFromPayloadType(@TypeOf(op.*)) == .link_timeout) and res == error.OperationCanceled) {
                // special case
            } else {
                debug("complete: {}: {} [FAIL] {}", .{ cqe.user_data, comptime Operation.tagFromPayloadType(@TypeOf(op.*)), res });
                return error.OperationFailed;
            }
        }
    }

    debug("complete: {}: {} [OK]", .{ cqe.user_data, comptime Operation.tagFromPayloadType(@TypeOf(op.*)) });

    switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .fsync => {},
        .read => op.out_read.* = @intCast(cqe.res),
        .write => if (op.out_written) |w| {
            w.* = @intCast(cqe.res);
        },
        .accept => op.out_socket.* = cqe.res,
        .connect => {},
        .recv => op.out_read.* = @intCast(cqe.res),
        .send => if (op.out_written) |w| {
            w.* = @intCast(cqe.res);
        },
        .open_at => op.out_file.handle = cqe.res,
        .close_file, .close_dir, .close_socket => {},
        .notify_event_source, .wait_event_source, .close_event_source => {},
        .timeout, .link_timeout => {},
        .cancel => {},
        .rename_at, .unlink_at, .mkdir_at, .symlink_at => {},
        .child_exit => if (op.out_term) |term| {
            term.* = posix.statusToTerm(@intCast(op._.fields.common.second.sigchld.status));
        },
        .socket => op.out_socket.* = cqe.res,
    }
}
