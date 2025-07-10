const std = @import("std");
const posix = @import("posix.zig");
const BoundedArray = @import("minilib").BoundedArray;
const options = @import("../../aio.zig").options;
const log = std.log.scoped(.aio_wasi);

// wasix has fd_event, but the only runtime that implements wasix (wasmer)
// does not seem to like zig's WasiThreadImpl for whatever reason
// so not implementing that until something there changes
pub const EventSource = struct {
    fd: std.posix.fd_t,
    wfd: std.posix.fd_t,

    pub fn init() !@This() {
        const fds = try pipe();
        return .{ .fd = fds[0], .wfd = fds[1] };
    }

    pub fn deinit(self: *@This()) void {
        std.posix.close(self.fd);
        std.posix.close(self.wfd);
        self.* = undefined;
    }

    pub fn notify(self: *@This()) void {
        _ = std.posix.write(self.wfd, &.{0}) catch @panic("EventSource.notify failed");
    }

    pub fn notifyReadiness(_: *@This()) posix.Readiness {
        return .{};
    }

    pub fn waitNonBlocking(self: *@This()) error{WouldBlock}!void {
        // TODO: actually blocks
        var trash: [1]u8 = undefined;
        _ = std.posix.read(self.fd, &trash) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            else => @panic("EventSource.wait failed"),
        };
    }

    pub fn wait(self: *@This()) void {
        while (true) {
            self.waitNonBlocking() catch {
                var pfds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
                _ = poll(&pfds, -1) catch {};
                continue;
            };
            break;
        }
    }

    pub fn waitReadiness(self: *@This()) posix.Readiness {
        return .{ .fd = self.fd, .events = .{ .in = true } };
    }
};

pub const BIGGEST_ALIGNMENT = 16;

pub const sa_family_t = u16;

pub const sockaddr = extern struct {
    sa_family: sa_family_t align(BIGGEST_ALIGNMENT),
    sa_data: [*]u8,
};

pub const socklen_t = u32;

pub const msghdr = extern struct {
    name: *anyopaque,
    namelen: socklen_t,
    iov: [*]std.posix.iovec,
    iovlen: i32,
    control: *anyopaque,
    controllen: socklen_t,
    flags: i32,
};

pub const msghdr_const = extern struct {
    name: *const anyopaque,
    namelen: socklen_t,
    iov: [*]const std.posix.iovec_const,
    iovlen: i32,
    control: *anyopaque,
    controllen: socklen_t,
    flags: i32,
};

pub fn socket(_: u32, _: u32, _: u32) std.posix.SocketError!std.posix.socket_t {
    @panic("fixme");
}

pub fn recvmsg(_: std.posix.socket_t, _: *msghdr, _: u32) posix.RecvMsgError!usize {
    @panic("fixme");
}

pub fn sendmsg(_: std.posix.socket_t, _: *const msghdr_const, _: u32) std.posix.SendMsgError!usize {
    @panic("fixme");
}

pub fn accept(_: std.posix.socket_t, _: ?*sockaddr, _: ?*socklen_t, _: u32) std.posix.AcceptError!std.posix.socket_t {
    @panic("fixme");
}

pub fn connect(_: std.posix.socket_t, _: *const sockaddr, _: socklen_t) std.posix.ConnectError!void {
    @panic("fixme");
}

pub fn bind(_: std.posix.socket_t, _: *const sockaddr, _: socklen_t) std.posix.BindError!void {
    @panic("fixme");
}

pub fn listen(_: std.posix.socket_t, _: u32) std.posix.ListenError!void {
    @panic("fixme");
}

pub fn recv(_: std.posix.socket_t, _: []u8, _: u32) std.posix.RecvFromError!usize {
    @panic("fixme");
}

pub fn send(_: std.posix.socket_t, _: []const u8, _: u32) std.posix.SendError!usize {
    @panic("fixme");
}

pub fn shutdown(_: std.posix.socket_t, _: std.posix.ShutdownHow) std.posix.ShutdownError!void {
    @panic("fixme");
}

pub fn fsync(fd: std.posix.fd_t) std.posix.SyncError!void {
    return switch (std.os.wasi.fd_sync(fd)) {
        .SUCCESS => {},
        .BADF, .INVAL, .ROFS => unreachable,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .DQUOT => error.DiskQuota,
        else => error.Unexpected,
    };
}

pub fn pipe() std.posix.PipeError![2]std.posix.fd_t {
    switch (options.wasi) {
        .wasi => {
            const encoder = std.base64.standard_no_pad.Encoder;
            const cwd = std.fs.cwd().fd;
            var bytes: [8]u8 = undefined;
            std.crypto.random.bytes(&bytes);
            var name: [encoder.calcSize(bytes.len) + 1]u8 = undefined;
            _ = encoder.encode(name[1..name.len], &bytes);
            std.mem.replaceScalar(u8, name[1..name.len], '/', '_');
            name[0] = '_';
            const fd = std.posix.openatWasi(
                cwd,
                &name,
                .{ .SYMLINK_FOLLOW = false },
                .{ .CREAT = true, .EXCL = true },
                .{},
                .{
                    .FD_READ = true,
                    .FD_WRITE = true,
                    .POLL_FD_READWRITE = true,
                },
                .{},
            ) catch |err| {
                log.err("pipe: openat: {s} {}", .{ name, err });
                return error.Unexpected;
            };
            std.posix.unlinkatWasi(cwd, &name, 0) catch |err| {
                log.err("pipe: unlink: {s} {}", .{ name, err });
                return error.Unexpected;
            };
            return .{ fd, fd };
        },
        .wasix => {
            const wasix = struct {
                pub extern "wasix_32v1" fn fd_pipe(fd1: *std.os.wasi.fd_t, fd2: *std.os.wasi.fd_t) std.os.wasi.errno_t;
            };
            var fds: [2]std.os.wasi.fd_t = undefined;
            return switch (wasix.fd_pipe(&fds[0], &fds[1])) {
                .SUCCESS => fds,
                .INVAL => unreachable, // Invalid parameters to pipe()
                .FAULT => unreachable, // Invalid fds pointer
                .NFILE => error.SystemFdQuotaExceeded,
                .MFILE => error.ProcessFdQuotaExceeded,
                else => error.Unexpected,
            };
        },
    }
    unreachable;
}

fn clock(userdata: usize, timeout: i32) std.os.wasi.subscription_t {
    return .{
        .userdata = userdata,
        .u = .{
            .tag = .CLOCK,
            .u = .{
                .clock = .{
                    .id = .MONOTONIC,
                    .timeout = @intCast(timeout * std.time.ns_per_ms),
                    .precision = 0,
                    .flags = 0,
                },
            },
        },
    };
}

pub fn poll(fds: []std.posix.pollfd, timeout: i32) std.posix.PollError!usize {
    // TODO: maybe use thread local arena instead?
    const MAX_POLL_FDS = 4096;
    var subs: BoundedArray(std.os.wasi.subscription_t, MAX_POLL_FDS) = .{};
    for (fds) |*pfd| {
        pfd.revents = 0;
        if (pfd.events & std.posix.POLL.IN != 0) {
            subs.append(.{
                .userdata = @intFromPtr(pfd),
                .u = .{
                    .tag = .FD_READ,
                    .u = .{ .fd_read = .{ .fd = pfd.fd } },
                },
            }) catch return error.SystemResources;
        }
        if (pfd.events & std.posix.POLL.OUT != 0) {
            subs.append(.{
                .userdata = @intFromPtr(pfd),
                .u = .{
                    .tag = .FD_WRITE,
                    .u = .{ .fd_write = .{ .fd = pfd.fd } },
                },
            }) catch return error.SystemResources;
        }
    }

    if (fds.len > 0 and subs.len == 0) {
        return error.Unexpected;
    }

    if (timeout >= 0) {
        subs.append(clock(0, timeout)) catch return error.SystemResources;
    }

    var n: usize = 0;
    var events: [MAX_POLL_FDS]std.os.wasi.event_t = undefined;
    switch (std.os.wasi.poll_oneoff(@ptrCast(subs.constSlice().ptr), @ptrCast(events[0..subs.len].ptr), subs.len, &n)) {
        .SUCCESS => {},
        else => |e| {
            log.err("poll: {}", .{e});
            return error.Unexpected;
        },
    }

    var nres: usize = 0;
    for (events[0..n]) |*ev| {
        if (ev.userdata == 0) continue; // timeout
        var pfd: *std.posix.pollfd = @ptrFromInt(@as(usize, @intCast(ev.userdata)));
        switch (ev.@"error") {
            .SUCCESS => switch (ev.type) {
                .FD_READ => {
                    pfd.revents = std.posix.POLL.IN;
                    if (ev.fd_readwrite.flags & std.os.wasi.EVENT_FD_READWRITE_HANGUP != 0) {
                        pfd.revents |= std.posix.POLL.HUP;
                    }
                },
                .FD_WRITE => {
                    pfd.revents = std.posix.POLL.OUT;
                    if (ev.fd_readwrite.flags & std.os.wasi.EVENT_FD_READWRITE_HANGUP != 0) {
                        pfd.revents |= std.posix.POLL.HUP;
                    }
                },
                .CLOCK => unreachable,
            },
            .BADF => pfd.revents |= std.posix.POLL.NVAL,
            .PIPE => pfd.revents |= std.posix.POLL.HUP,
            else => pfd.revents |= std.posix.POLL.ERR,
        }
        nres += 1;
    }

    return nres;
}
