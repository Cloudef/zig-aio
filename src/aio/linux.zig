const std = @import("std");
const aio = @import("../aio.zig");
const Operation = @import("ops.zig").Operation;
const ErrorUnion = @import("ops.zig").ErrorUnion;

io: std.os.linux.IoUring,
ops: Pool(Operation.Union, u16),

pub fn init(allocator: std.mem.Allocator, n: u16) aio.InitError!@This() {
    const n2 = try std.math.ceilPowerOfTwo(u16, n);
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

inline fn queueOperation(self: *@This(), op: anytype) aio.QueueError!u16 {
    const n = self.ops.next() orelse return error.Overflow;
    try uring_queue(&self.io, op, n);
    const tag = @tagName(comptime Operation.tagFromPayloadType(@TypeOf(op.*)));
    return self.ops.add(@unionInit(Operation.Union, tag, op.*)) catch unreachable;
}

pub fn queue(self: *@This(), comptime len: u16, work: anytype) aio.QueueError!void {
    if (comptime len == 1) {
        _ = try self.queueOperation(&work.ops[0]);
    } else {
        var ids: std.BoundedArray(u16, len) = .{};
        errdefer for (ids.constSlice()) |id| self.ops.remove(id);
        inline for (&work.ops) |*op| ids.append(try self.queueOperation(op)) catch unreachable;
    }
}

const NOP = std.math.maxInt(usize);

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode) aio.CompletionError!aio.CompletionResult {
    if ((!self.ops.empty() or self.io.sq_ready() > 0) and mode == .nonblocking) {
        _ = self.io.nop(NOP) catch |err| return switch (err) {
            error.SubmissionQueueFull => .{},
        };
    }
    if (try uring_submit(&self.io) == 0) return .{};
    var result: aio.CompletionResult = .{};
    var cqes: [64]std.os.linux.io_uring_cqe = undefined;
    const n = try uring_copy_cqes(&self.io, &cqes, 1);
    for (cqes[0..n]) |*cqe| {
        if (cqe.user_data == NOP) continue;
        switch (self.ops.get(@intCast(cqe.user_data)).*) {
            inline else => |op| uring_handle_completion(&op, cqe) catch {
                result.num_errors += 1;
            },
        }
    }
    result.num_completed = n - @intFromBool(mode == .nonblocking);
    return result;
}

pub fn immediate(comptime len: u16, work: anytype) aio.ImmediateError!u16 {
    var io = try uring_init(try std.math.ceilPowerOfTwo(u16, len));
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

inline fn uring_init(n: u16) aio.InitError!std.os.linux.IoUring {
    return std.os.linux.IoUring.init(n, 0) catch |err| switch (err) {
        error.PermissionDenied, error.SystemResources, error.SystemOutdated => |e| e,
        error.ProcessFdQuotaExceeded => error.ProcessQuotaExceeded,
        error.SystemFdQuotaExceeded => error.SystemQuotaExceeded,
        else => error.Unexpected,
    };
}

fn convertOpenFlags(flags: std.fs.File.OpenFlags) std.posix.O {
    var os_flags: std.posix.O = .{
        .ACCMODE = switch (flags.mode) {
            .read_only => .RDONLY,
            .write_only => .WRONLY,
            .read_write => .RDWR,
        },
    };
    if (@hasField(std.posix.O, "CLOEXEC")) os_flags.CLOEXEC = true;
    if (@hasField(std.posix.O, "LARGEFILE")) os_flags.LARGEFILE = true;
    if (@hasField(std.posix.O, "NOCTTY")) os_flags.NOCTTY = !flags.allow_ctty;

    // Use the O locking flags if the os supports them to acquire the lock
    // atomically.
    const has_flock_open_flags = @hasField(std.posix.O, "EXLOCK");
    if (has_flock_open_flags) {
        // Note that the NONBLOCK flag is removed after the openat() call
        // is successful.
        switch (flags.lock) {
            .none => {},
            .shared => {
                os_flags.SHLOCK = true;
                os_flags.NONBLOCK = flags.lock_nonblocking;
            },
            .exclusive => {
                os_flags.EXLOCK = true;
                os_flags.NONBLOCK = flags.lock_nonblocking;
            },
        }
    }
    return os_flags;
}

inline fn uring_queue(io: *std.os.linux.IoUring, op: anytype, user_data: u64) aio.QueueError!void {
    const RENAME_NOREPLACE = 1 << 0;
    var sqe = switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .fsync => try io.fsync(user_data, op.file.handle, 0),
        .read => try io.read(user_data, op.file.handle, .{ .buffer = op.buffer }, op.offset),
        .write => try io.write(user_data, op.file.handle, op.buffer, op.offset),
        .accept => try io.accept(user_data, op.socket, @ptrCast(op.addr), op.inout_addrlen, 0),
        .connect => try io.connect(user_data, op.socket, @ptrCast(op.addr), op.addrlen),
        .recv => try io.recv(user_data, op.socket, .{ .buffer = op.buffer }, 0),
        .send => try io.send(user_data, op.socket, op.buffer, 0),
        .open_at => try io.openat(user_data, op.dir.fd, op.path, convertOpenFlags(op.flags), 0),
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
            if (op.out_expired) |expired| expired.* = false;
            break :blk try io.link_timeout(user_data, &ts, 0);
        },
        .cancel => try io.cancel(user_data, @intFromEnum(op.id), 0),
        .rename_at => try io.renameat(user_data, op.old_dir.fd, op.old_path, op.new_dir.fd, op.new_path, RENAME_NOREPLACE),
        .unlink_at => try io.unlinkat(user_data, op.dir.fd, op.path, 0),
        .mkdir_at => try io.mkdirat(user_data, op.dir.fd, op.path, op.mode),
        .symlink_at => try io.symlinkat(user_data, op.target, op.dir.fd, op.link_path),
        .child_exit => try io.waitid(user_data, .PID, op.child, @constCast(&op._), std.posix.W.EXITED, 0),
        .socket => try io.socket(user_data, op.domain, op.flags, op.protocol, 0),
        .close_socket => try io.close(user_data, op.socket),
    };
    if (op.link_next) sqe.flags |= std.os.linux.IOSQE_IO_LINK;
    if (@hasField(@TypeOf(op.*), "out_id")) {
        if (op.out_id) |id| id.* = @enumFromInt(user_data);
    }
    if (op.out_error) |out_error| out_error.* = error.Success;
}

inline fn uring_submit(io: *std.os.linux.IoUring) aio.CompletionError!u16 {
    while (true) {
        const n = io.submit() catch |err| switch (err) {
            error.FileDescriptorInvalid => unreachable,
            error.FileDescriptorInBadState => unreachable,
            error.BufferInvalid => unreachable,
            error.OpcodeNotSupported => unreachable,
            error.RingShuttingDown => unreachable,
            error.SignalInterrupt => continue,
            error.CompletionQueueOvercommitted, error.SubmissionQueueEntryInvalid, error.Unexpected, error.SystemResources => |e| return e,
        };
        return @intCast(n);
    }
}

inline fn uring_copy_cqes(io: *std.os.linux.IoUring, cqes: []std.os.linux.io_uring_cqe, len: u16) aio.CompletionError!u16 {
    while (true) {
        const n = io.copy_cqes(cqes, len) catch |err| switch (err) {
            error.FileDescriptorInvalid => unreachable,
            error.FileDescriptorInBadState => unreachable,
            error.BufferInvalid => unreachable,
            error.OpcodeNotSupported => unreachable,
            error.RingShuttingDown => unreachable,
            error.SignalInterrupt => continue,
            error.CompletionQueueOvercommitted, error.SubmissionQueueEntryInvalid, error.Unexpected, error.SystemResources => |e| return e,
        };
        return @intCast(n);
    }
    unreachable;
}

fn statusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
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
            .timeout => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .TIME => error.Success,
                .CANCELED => error.OperationCanceled,
                else => unreachable,
            },
            .link_timeout => switch (err) {
                .SUCCESS, .INTR, .INVAL, .AGAIN => unreachable,
                .TIME => blk: {
                    if (op.out_expired) |expired| expired.* = true;
                    break :blk error.Success;
                },
                .ALREADY => error.Success,
                .CANCELED => error.OperationCanceled,
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
        if (res != error.Success) return error.OperationFailed;
    }

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
        .timeout, .link_timeout => {},
        .cancel => {},
        .rename_at, .unlink_at, .mkdir_at, .symlink_at => {},
        .child_exit => if (op.out_term) |term| {
            term.* = statusToTerm(@intCast(op._.fields.common.second.sigchld.status));
        },
        .socket => op.out_socket.* = cqe.res,
    }
}

pub fn Pool(T: type, SZ: type) type {
    return struct {
        pub const Node = union(enum) { free: ?SZ, used: T };
        nodes: []Node,
        free: ?SZ = null,
        num_free: SZ = 0,
        num_used: SZ = 0,

        pub const Error = error{
            OutOfMemory,
        };

        pub fn init(allocator: std.mem.Allocator, n: SZ) Error!@This() {
            return .{ .nodes = try allocator.alloc(Node, n) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.nodes);
            self.* = undefined;
        }

        pub fn empty(self: *@This()) bool {
            return self.num_used == self.num_free;
        }

        pub fn next(self: *@This()) ?SZ {
            if (self.free) |fslot| return fslot;
            if (self.num_used >= self.nodes.len) return null;
            return self.num_used;
        }

        pub fn add(self: *@This(), item: T) Error!SZ {
            if (self.free) |fslot| {
                self.free = self.nodes[fslot].free;
                self.nodes[fslot] = .{ .used = item };
                self.num_free -= 1;
                return fslot;
            }
            if (self.num_used >= self.nodes.len) return error.OutOfMemory;
            self.nodes[self.num_used] = .{ .used = item };
            defer self.num_used += 1;
            return self.num_used;
        }

        pub fn remove(self: *@This(), slot: SZ) void {
            if (self.free) |fslot| {
                self.nodes[slot] = .{ .free = fslot };
            } else {
                self.nodes[slot] = .{ .free = null };
            }
            self.free = slot;
            self.num_free += 1;
        }

        pub fn get(self: *@This(), slot: SZ) *T {
            return &self.nodes[slot].used;
        }

        pub const Iterator = struct {
            items: []Node,
            index: SZ = 0,

            pub fn next(self: *@This()) *T {
                while (self.index < self.items.len) {
                    defer self.index += 1;
                    if (self.items[self.index] == .used) {
                        return &self.items[self.index].used;
                    }
                }
                return null;
            }
        };

        pub fn iterator(self: *@This()) Iterator {
            return .{ .items = self.nodes[0..self.num_used] };
        }
    };
}
