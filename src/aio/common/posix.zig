const std = @import("std");
const Operation = @import("../ops.zig").Operation;

pub const RENAME_NOREPLACE = 1 << 0;

pub fn convertOpenFlags(flags: std.fs.File.OpenFlags) std.posix.O {
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

pub inline fn statusToTerm(status: u32) std.process.Child.Term {
    return if (std.posix.W.IFEXITED(status))
        .{ .Exited = std.posix.W.EXITSTATUS(status) }
    else if (std.posix.W.IFSIGNALED(status))
        .{ .Signal = std.posix.W.TERMSIG(status) }
    else if (std.posix.W.IFSTOPPED(status))
        .{ .Stopped = std.posix.W.STOPSIG(status) }
    else
        .{ .Unknown = status };
}

pub inline fn perform(op: anytype) Operation.Error!void {
    var u_64: u64 align(1) = undefined;
    switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .fsync => _ = try std.posix.fsync(op.file.handle),
        .read => op.out_read.* = try std.posix.pread(op.file.handle, op.buffer, op.offset),
        .write => {
            const written = try std.posix.pwrite(op.file.handle, op.buffer, op.offset);
            if (op.out_written) |w| w.* = written;
        },
        .accept => op.out_socket.* = try std.posix.accept(op.socket, op.addr, op.inout_addrlen, 0),
        .connect => _ = try std.posix.connect(op.socket, op.addr, op.addrlen),
        .recv => op.out_read.* = try std.posix.recv(op.socket, op.buffer, 0),
        .send => {
            const written = try std.posix.send(op.socket, op.buffer, 0);
            if (op.out_written) |w| w.* = written;
        },
        .open_at => op.out_file.handle = try std.posix.openatZ(op.dir.fd, op.path, convertOpenFlags(op.flags), 0),
        .close_file => std.posix.close(op.file.handle),
        .close_dir => std.posix.close(op.dir.fd),
        .rename_at => {
            const res = std.os.linux.renameat2(op.old_dir.fd, op.old_path, op.new_dir.fd, op.new_path, RENAME_NOREPLACE);
            const e = std.posix.errno(res);
            if (e != .SUCCESS) return switch (e) {
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
                else => std.posix.unexpectedErrno(e),
            };
        },
        .unlink_at => _ = try std.posix.unlinkatZ(op.dir.fd, op.path, 0),
        .mkdir_at => _ = try std.posix.mkdiratZ(op.dir.fd, op.path, op.mode),
        .symlink_at => _ = try std.posix.symlinkatZ(op.target, op.dir.fd, op.link_path),
        .child_exit => {
            _ = std.posix.system.waitid(.PID, op.child, @constCast(&op._), std.posix.W.EXITED);
            if (op.out_term) |term| {
                term.* = statusToTerm(@intCast(op._.fields.common.second.sigchld.status));
            }
        },
        .socket => op.out_socket.* = try std.posix.socket(op.domain, op.flags, op.protocol),
        .close_socket => std.posix.close(op.socket),
        .notify_event_source => _ = std.posix.write(op.source.native.fd, &std.mem.toBytes(@as(u64, 1))) catch unreachable,
        .wait_event_source => _ = std.posix.read(op.source.native.fd, std.mem.asBytes(&u_64)) catch unreachable,
        .close_event_source => std.posix.close(op.source.native.fd),
        // this function is meant for execution on a thread, it makes no sense to execute these on a thread
        .timeout, .link_timeout, .cancel => unreachable,
    }
}

pub const Readiness = struct {
    fd: std.posix.fd_t = 0,
    mode: enum { noop, in, out } = .noop,
};

pub const OpenReadinessError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    SystemResources,
    Unexpected,
};

pub inline fn openReadiness(op: anytype) OpenReadinessError!Readiness {
    return switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .fsync => .{},
        .write => .{ .fd = op.file.handle, .mode = .out },
        .read => .{ .fd = op.file.handle, .mode = .in },
        .accept, .recv => .{ .fd = op.socket, .mode = .in },
        .socket, .connect => .{},
        .send => .{ .fd = op.socket, .mode = .out },
        .open_at, .close_file, .close_dir, .close_socket => .{},
        .timeout, .link_timeout => blk: {
            const fd = std.posix.timerfd_create(std.posix.CLOCK.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true }) catch |err| return switch (err) {
                error.AccessDenied => unreachable,
                else => |e| e,
            };
            break :blk .{ .fd = fd, .mode = .in };
        },
        .cancel, .rename_at, .unlink_at, .mkdir_at, .symlink_at => .{},
        .child_exit => blk: {
            const res = std.posix.system.pidfd_open(op.child, @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK")));
            const e = std.posix.errno(res);
            if (e != .SUCCESS) return switch (e) {
                .INVAL, .SRCH => unreachable,
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NODEV => error.NoDevice,
                .NOMEM => error.SystemResources,
                else => std.posix.unexpectedErrno(e),
            };
            break :blk .{ .fd = @intCast(res), .mode = .in };
        },
        .wait_event_source => .{ .fd = op.source.native.fd, .mode = .in },
        .notify_event_source => .{ .fd = op.source.native.fd, .mode = .out },
        .close_event_source => .{},
    };
}

pub inline fn armReadiness(op: anytype, readiness: Readiness) error{Unexpected}!void {
    switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .timeout, .link_timeout => {
            const ts: std.os.linux.itimerspec = .{
                .it_value = .{
                    .tv_sec = @intCast(op.ns / std.time.ns_per_s),
                    .tv_nsec = @intCast(op.ns % std.time.ns_per_s),
                },
                .it_interval = .{
                    .tv_sec = 0,
                    .tv_nsec = 0,
                },
            };
            _ = std.posix.timerfd_settime(readiness.fd, .{}, &ts, null) catch |err| return switch (err) {
                error.Canceled, error.InvalidHandle => unreachable,
                error.Unexpected => |e| e,
            };
        },
        .fsync, .read, .write => {},
        .socket, .accept, .connect, .recv, .send => {},
        .open_at, .close_file, .close_dir, .close_socket => {},
        .cancel, .rename_at, .unlink_at, .mkdir_at, .symlink_at => {},
        .notify_event_source, .wait_event_source, .close_event_source => {},
        .child_exit => {},
    }
}

pub inline fn closeReadiness(op: anytype, readiness: Readiness) void {
    const needs_close = switch (comptime Operation.tagFromPayloadType(@TypeOf(op.*))) {
        .timeout, .link_timeout, .child_exit => true,
        .fsync, .read, .write => false,
        .socket, .accept, .connect, .recv, .send => false,
        .open_at, .close_file, .close_dir, .close_socket => false,
        .cancel, .rename_at, .unlink_at, .mkdir_at, .symlink_at => false,
        .notify_event_source, .wait_event_source, .close_event_source => false,
    };
    if (needs_close) std.posix.close(readiness.fd);
}
