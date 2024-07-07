const std = @import("std");
const posix = @import("posix.zig");
const options = @import("../../aio.zig").options;
const log = std.log.scoped(.aio_wasi);

// wasix has fd_event, but the only runtime that implements wasix (wasmer)
// does not seem to like zig's WasiThreadImpl for whatever reason
// so not implementing that until something there changes
pub const EventSource = posix.PipeEventSource;

pub const ChildWatcher = struct {
    id: std.process.Child.Id,
    fd: std.posix.fd_t,

    pub fn init(id: std.process.Child.Id) !@This() {
        if (true) @panic("unavailable on the wasi platform");
        return .{ .id = id, .fd = 0 };
    }

    pub fn wait(_: *@This()) std.process.Child.Term {
        if (true) @panic("unavailable on the wasi platform");
    }

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
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
    msg_name: *anyopaque,
    msg_namelen: socklen_t,
    msg_iov: std.posix.iovec,
    msg_iovlen: i32,
    msg_control: *anyopaque,
    msg_controllen: socklen_t,
    msg_flags: i32,
};

pub const msghdr_const = extern struct {
    msg_name: *const anyopaque,
    msg_namelen: socklen_t,
    msg_iov: std.posix.iovec,
    msg_iovlen: i32,
    msg_control: *anyopaque,
    msg_controllen: socklen_t,
    msg_flags: i32,
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
            var name: [encoder.calcSize(bytes.len) + 2]u8 = undefined;
            _ = encoder.encode(name[1 .. name.len - 1], &bytes);
            std.mem.replaceScalar(u8, name[1 .. name.len - 1], '/', '_');
            name[0] = '_';
            name[name.len - 1] = '1';
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

pub fn poll(fds: []std.posix.pollfd, timeout: i32) std.posix.PollError!usize {
    // TODO: maybe use thread local arena instead?
    const MAX_POLL_FDS = 4096;
    const sub_len = fds.len + @intFromBool(timeout >= 0);
    std.debug.assert(sub_len <= MAX_POLL_FDS);
    var subs: [MAX_POLL_FDS]std.os.wasi.subscription_t = undefined;
    for (fds, subs[0..fds.len]) |*pfd, *sub| {
        pfd.revents = 0;
        sub.userdata = @intFromPtr(pfd);
        const mask = std.posix.POLL.IN | std.posix.POLL.OUT;
        if (pfd.events & mask == mask) return error.Unexpected;
        if (pfd.events & std.posix.POLL.IN != 0) {
            sub.u = .{
                .tag = .FD_READ,
                .u = .{ .fd_read = .{ .fd = pfd.fd } },
            };
        } else if (pfd.events & std.posix.POLL.OUT != 0) {
            sub.u = .{
                .tag = .FD_WRITE,
                .u = .{ .fd_write = .{ .fd = pfd.fd } },
            };
        }
    }

    if (timeout >= 0) {
        subs[fds.len] = .{
            .userdata = 0,
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

    var n: usize = 0;
    var events: [MAX_POLL_FDS]std.os.wasi.event_t = undefined;
    switch (std.os.wasi.poll_oneoff(@ptrCast(subs[0..sub_len].ptr), @ptrCast(events[0..sub_len].ptr), sub_len, &n)) {
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
