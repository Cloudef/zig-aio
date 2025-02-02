const std = @import("std");
const posix = @import("posix.zig");

pub const EventSource = struct {
    fd: std.posix.fd_t,

    pub fn init() !@This() {
        return .{ .fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.SEMAPHORE | std.os.linux.EFD.NONBLOCK) };
    }

    pub fn deinit(self: *@This()) void {
        std.posix.close(self.fd);
        self.* = undefined;
    }

    pub fn notify(self: *@This()) void {
        _ = std.posix.write(self.fd, &std.mem.toBytes(@as(u64, 1))) catch @panic("EventSource.notify failed");
    }

    pub fn notifyReadiness(_: *@This()) posix.Readiness {
        return .{}; // can write immediately
    }

    pub fn waitNonBlocking(self: *@This()) error{WouldBlock}!void {
        var trash: u64 = undefined;
        _ = std.posix.read(self.fd, std.mem.asBytes(&trash)) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            else => @panic("EventSource.wait failed"),
        };
    }

    pub fn wait(self: *@This()) void {
        while (true) {
            self.waitNonBlocking() catch {
                var pfds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
                _ = std.posix.poll(&pfds, -1) catch {};
                continue;
            };
            break;
        }
    }

    pub fn waitReadiness(self: *@This()) posix.Readiness {
        return .{ .fd = self.fd, .events = .{ .in = true } };
    }
};

pub const ChildWatcher = struct {
    id: std.process.Child.Id,
    fd: std.posix.fd_t,

    const Error = error{
        NotFound,
        Unexpected,
    };

    pub fn init(id: std.process.Child.Id) !@This() {
        return .{ .id = id, .fd = try pidfd_open(id, .{}) };
    }

    pub fn wait(self: *@This()) Error!std.process.Child.Term {
        var siginfo: std.posix.siginfo_t = undefined;
        while (true) {
            const res = std.os.linux.waitid(.PIDFD, self.fd, &siginfo, std.posix.W.EXITED | std.posix.W.NOHANG);
            return switch (std.os.linux.E.init(res)) {
                .SUCCESS => posix.statusToTerm(@intCast(siginfo.fields.common.second.sigchld.status)),
                .INTR => continue,
                .CHILD => error.NotFound,
                .INVAL => unreachable,
                else => |e| std.posix.unexpectedErrno(e),
            };
        }
        unreachable;
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
    NotFound,
    Unexpected,
};

pub fn pidfd_open(id: std.posix.fd_t, flags: std.posix.O) PidfdOpenError!std.posix.fd_t {
    while (true) {
        const res = std.os.linux.pidfd_open(id, @bitCast(flags));
        return switch (std.os.linux.E.init(res)) {
            .SUCCESS => @intCast(res),
            .INVAL => unreachable,
            .AGAIN, .INTR => continue,
            .SRCH => error.NotFound,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NODEV => error.NoDevice,
            .NOMEM => error.SystemResources,
            else => |e| std.posix.unexpectedErrno(e),
        };
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
        const e = std.os.linux.E.init(res);
        return switch (e) {
            .SUCCESS => {},
            .INVAL => unreachable,
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
    }
    unreachable;
}
