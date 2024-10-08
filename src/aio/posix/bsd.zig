const builtin = @import("builtin");
const std = @import("std");
const posix = @import("posix.zig");

pub const EVFILT_USER = switch (builtin.target.os.tag) {
    .openbsd => @compileError("openbsd lacks EVFILT_USER"),
    .dragonfly => -9,
    else => std.posix.system.EVFILT_USER,
};

pub const msghdr_const = switch (builtin.target.os.tag) {
    .dragonfly => extern struct {
        msg_name: ?*const anyopaque,
        msg_namelen: std.posix.socklen_t,
        msg_iov: [*]std.posix.iovec,
        msg_iovlen: c_int,
        msg_control: ?*anyopaque,
        msg_controllen: std.posix.socklen_t,
        msg_flags: c_int,
    },
    else => std.posix.system.msghdr_const,
};

pub const EventSource = switch (builtin.target.os.tag) {
    // openbsd has no EVFILT_USER
    .openbsd => posix.PipeEventSource,
    else => struct {
        fd: std.posix.fd_t,
        counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        pub fn init() !@This() {
            return .{ .fd = try std.posix.kqueue() };
        }

        pub fn deinit(self: *@This()) void {
            std.posix.close(self.fd);
            self.* = undefined;
        }

        pub fn notify(self: *@This()) void {
            _ = std.posix.kevent(self.fd, &.{.{
                .ident = self.counter.fetchAdd(1, .monotonic),
                .filter = EVFILT_USER,
                .flags = std.posix.system.EV_ADD | std.posix.system.EV_ENABLE | std.posix.system.EV_ONESHOT,
                .fflags = std.posix.system.NOTE_TRIGGER,
                .data = 0,
                .udata = 0,
            }}, &.{}, null) catch @panic("EventSource.notify failed");
        }

        pub fn notifyReadiness(_: *@This()) posix.Readiness {
            return .{};
        }

        pub fn wait(self: *@This()) void {
            var ev: [1]std.posix.Kevent = undefined;
            _ = std.posix.kevent(self.fd, &.{}, &ev, null) catch @panic("EventSource.wait failed");
        }

        pub fn waitReadiness(self: *@This()) posix.Readiness {
            return .{ .fd = self.fd, .mode = .{ .in } };
        }
    },
};

pub const ChildWatcher = struct {
    id: std.process.Child.Id,
    fd: std.posix.fd_t,

    pub fn init(id: std.process.Child.Id) !@This() {
        const fd = try std.posix.kqueue();
        _ = std.posix.kevent(fd, &.{.{
            .ident = @intCast(id),
            .filter = std.posix.system.EVFILT_PROC,
            .flags = std.posix.system.EV_ADD | std.posix.system.EV_ENABLE | std.posix.system.EV_ONESHOT,
            .fflags = std.posix.system.NOTE_EXIT,
            .data = 0,
            .udata = 0,
        }}, &.{}, null) catch |err| return switch (err) {
            error.EventNotFound => unreachable,
            error.ProcessNotFound => unreachable,
            error.AccessDenied => unreachable,
            error.SystemResources => |e| e,
            else => error.Unexpected,
        };
        return .{ .id = id, .fd = fd };
    }

    pub fn wait(self: *@This()) std.process.Child.Term {
        const res = std.posix.waitpid(self.id, std.posix.W.NOHANG);
        return posix.statusToTerm(res.status);
    }

    pub fn deinit(self: *@This()) void {
        std.posix.close(self.fd);
        self.* = undefined;
    }
};
