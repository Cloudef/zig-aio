const std = @import("std");
const posix = @import("../posix.zig");

pub const EventSource = struct {
    fd: std.posix.fd_t,

    pub inline fn init() !@This() {
        return .{ .fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.SEMAPHORE) };
    }

    pub inline fn deinit(self: *@This()) void {
        std.posix.close(self.fd);
        self.* = undefined;
    }

    pub inline fn notify(self: *@This()) void {
        while (true) {
            _ = std.posix.write(self.fd, &std.mem.toBytes(@as(u64, 1))) catch continue;
            break;
        }
    }

    pub inline fn notifyReadiness(self: *@This()) posix.Readiness {
        return .{ .fd = self.fd, .mode = .out };
    }

    pub inline fn wait(self: *@This()) void {
        while (true) {
            var v: u64 = undefined;
            _ = std.posix.read(self.fd, std.mem.asBytes(&v)) catch continue;
            break;
        }
    }

    pub inline fn waitReadiness(self: *@This()) posix.Readiness {
        return .{ .fd = self.fd, .mode = .in };
    }
};

pub const ChildWatcher = struct {
    id: std.process.Child.Id,
    fd: std.posix.fd_t,

    pub fn init(id: std.process.Child.Id) !@This() {
        return .{ .id = id, .fd = try pidfd_open(id, .{ .NONBLOCK = true }) };
    }

    pub fn wait(self: *@This()) std.process.Child.Term {
        var siginfo: std.posix.siginfo_t = undefined;
        _ = std.os.linux.waitid(.PIDFD, self.fd, &siginfo, std.posix.W.EXITED | std.posix.W.NOHANG);
        return posix.statusToTerm(@intCast(siginfo.fields.common.second.sigchld.status));
    }

    pub fn deinit(self: *@This()) void {
        std.posix.close(self.fd);
        self.* = undefined;
    }
};

pub const Timer = struct {
    fd: std.posix.fd_t,
    clock: posix.Clock,

    pub fn init(clock: posix.Clock) !@This() {
        const fd = std.posix.timerfd_create(switch (clock) {
            .monotonic => std.posix.CLOCK.MONOTONIC,
            .boottime => std.posix.CLOCK.BOOTTIME,
            .realtime => std.posix.CLOCK.REALTIME,
        }, .{
            .CLOEXEC = true,
            .NONBLOCK = true,
        }) catch |err| return switch (err) {
            error.AccessDenied => unreachable,
            else => |e| e,
        };
        return .{ .fd = fd, .clock = clock };
    }

    pub fn set(self: *@This(), ns: u128) !void {
        const ts: std.os.linux.itimerspec = .{
            .it_value = .{
                .tv_sec = @intCast(ns / std.time.ns_per_s),
                .tv_nsec = @intCast(ns % std.time.ns_per_s),
            },
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
        };
        _ = std.posix.timerfd_settime(self.fd, .{}, &ts, null) catch |err| return switch (err) {
            error.Canceled, error.InvalidHandle => unreachable,
            error.Unexpected => |e| e,
        };
    }

    pub fn deinit(self: *@This()) void {
        std.posix.close(self.fd);
        self.* = undefined;
    }
};

pub const PidfdOpenError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    SystemResources,
    Unexpected,
};

pub fn pidfd_open(id: std.posix.fd_t, flags: std.posix.O) PidfdOpenError!std.posix.fd_t {
    while (true) {
        const res = std.os.linux.pidfd_open(id, @bitCast(flags));
        const e = std.posix.errno(res);
        if (e != .SUCCESS) return switch (e) {
            .INVAL, .SRCH => unreachable,
            .AGAIN, .INTR => continue,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NODEV => error.NoDevice,
            .NOMEM => error.SystemResources,
            else => std.posix.unexpectedErrno(e),
        };
        return @intCast(res);
    }
    unreachable;
}

pub const RENAME_NOREPLACE = 1 << 0;

pub fn renameat2(
    old_dir: std.posix.fd_t,
    old_path: [*:0]const u8,
    new_dir: std.posix.fd_t,
    new_path: [*:0]const u8,
    flags: u32,
) std.posix.RenameError!void {
    while (true) {
        const res = std.os.linux.renameat2(old_dir, old_path, new_dir, new_path, flags);
        const e = std.posix.errno(res);
        if (e != .SUCCESS) return switch (e) {
            .SUCCESS, .INVAL => unreachable,
            .INTR, .AGAIN => continue,
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
        break;
    }
}
