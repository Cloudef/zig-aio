const std = @import("std");
const posix = @import("../posix.zig");
const ops = @import("../ops.zig");
const log = std.log.scoped(.aio_windows);
const win32 = @import("win32");

const INFINITE = win32.system.windows_programming.INFINITE;
const GetLastError = win32.foundation.GetLastError;
const CloseHandle = win32.foundation.CloseHandle;
const threading = win32.system.threading;
const console = win32.system.console;
const win_sock = win32.networking.win_sock;

pub fn unexpectedError(err: win32.foundation.WIN32_ERROR) error{Unexpected} {
    return std.os.windows.unexpectedError(@enumFromInt(@intFromEnum(err)));
}

pub fn unexpectedWSAError(err: win32.networking.win_sock.WSA_ERROR) error{Unexpected} {
    return std.os.windows.unexpectedWSAError(@enumFromInt(@intFromEnum(err)));
}

pub fn wtry(ret: anytype) !void {
    const wbool: win32.foundation.BOOL = if (@TypeOf(ret) == bool)
        @intFromBool(ret)
    else
        ret;
    if (wbool == 0) return switch (GetLastError()) {
        .ERROR_IO_PENDING => {}, // not error
        else => |r| unexpectedError(r),
    };
}

pub fn werr(ret: anytype) ops.Operation.Error {
    wtry(ret) catch |err| return err;
    return error.Success;
}

pub fn checked(ret: anytype) void {
    wtry(ret) catch unreachable;
}

pub const EventSource = struct {
    fd: std.posix.fd_t,
    counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub inline fn init() !@This() {
        return .{
            .fd = try (threading.CreateEventW(null, 1, 1, null) orelse error.SystemResources),
        };
    }

    pub inline fn deinit(self: *@This()) void {
        checked(CloseHandle(self.fd));
        self.* = undefined;
    }

    pub inline fn notify(self: *@This()) void {
        if (self.counter.fetchAdd(1, .monotonic) == 0) {
            checked(threading.SetEvent(self.fd));
        }
    }

    pub inline fn notifyReadiness(self: *@This()) posix.Readiness {
        return .{ .fd = self.fd, .mode = .out };
    }

    pub inline fn wait(self: *@This()) void {
        const v = self.counter.load(.acquire);
        if (v > 0) {
            if (self.counter.fetchSub(1, .release) == 1) {
                checked(threading.ResetEvent(self.fd));
            }
        } else {
            _ = threading.WaitForSingleObject(self.fd, INFINITE);
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
        if (true) @panic("fixme");
        return .{ .id = id, .fd = 0 };
    }

    pub fn wait(_: *@This()) std.process.Child.Term {
        if (true) @panic("fixme");
    }

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }
};

pub fn translateTty(_: std.posix.fd_t, _: []u8, _: *ops.ReadTty.TranslationState) ops.ReadTty.Error!usize {
    if (true) @panic("TODO");
    return 0;
}

pub fn readTty(fd: std.posix.fd_t, buf: []u8, mode: ops.ReadTty.Mode) ops.ReadTty.Error!usize {
    return switch (mode) {
        .direct => {
            if (buf.len < @sizeOf(console.INPUT_RECORD)) {
                return error.NoSpaceLeft;
            }
            var read: u32 = 0;
            const n_fits: u32 = @intCast(buf.len / @sizeOf(console.INPUT_RECORD));
            if (console.ReadConsoleInputW(fd, @ptrCast(@alignCast(buf.ptr)), n_fits, &read) == 0) {
                return unexpectedError(GetLastError());
            }
            return read * @sizeOf(console.INPUT_RECORD);
        },
        .translation => |state| translateTty(fd, buf, state),
    };
}

pub const pollfd = struct {
    fd: std.posix.fd_t,
    events: i16,
    revents: i16,
};

pub fn poll(pfds: []pollfd, timeout: i32) std.posix.PollError!usize {
    var outs: usize = 0;
    for (pfds) |*pfd| {
        pfd.revents = 0;
        if (pfd.events & std.posix.POLL.OUT != 0) {
            pfd.revents = std.posix.POLL.OUT;
            outs += 1;
        }
    }
    if (outs > 0) return outs;
    // rip windows
    // this is only used by fallback backend, on fallback backend all file and socket operations are thread pooled
    // thus this limit isn't that bad, but Timer and EventSource are polled using this function, so you can still
    // hit this limit
    std.debug.assert(pfds.len <= win32.system.system_services.MAXIMUM_WAIT_OBJECTS);
    var handles: [win32.system.system_services.MAXIMUM_WAIT_OBJECTS]std.posix.fd_t = undefined;
    for (handles[0..pfds.len], pfds[0..]) |*h, *pfd| h.* = pfd.fd;
    // std.os has nicer api for this
    const idx = std.os.windows.WaitForMultipleObjectsEx(
        handles[0..pfds.len],
        false,
        if (timeout < 0) INFINITE else @intCast(timeout),
        false,
    ) catch |err| switch (err) {
        error.WaitAbandoned, error.WaitTimeOut => return 0,
        error.Unexpected => blk: {
            for (handles[0..pfds.len], 0..) |h, idx| {
                if (threading.WaitForSingleObject(h, 0) == 0) {
                    pfds[idx].events |= std.posix.POLL.NVAL;
                    break :blk idx;
                }
            }
            unreachable;
        },
        else => |e| return e,
    };
    pfds[idx].revents = pfds[idx].events;
    return 1;
}

pub const msghdr = win_sock.WSAMSG;
pub const msghdr_const = win_sock.WSAMSG;

pub fn sendmsg(sockfd: std.posix.socket_t, msg: *const msghdr_const, flags: u32) !usize {
    var written: u32 = 0;
    while (true) {
        const rc = win_sock.WSASendMsg(sockfd, @constCast(msg), flags, &written, null, null);
        if (rc == win_sock.SOCKET_ERROR) {
            switch (win_sock.WSAGetLastError()) {
                .EWOULDBLOCK, .EINTR, .EINPROGRESS => continue,
                .EACCES => return error.AccessDenied,
                .EADDRNOTAVAIL => return error.AddressNotAvailable,
                .ECONNRESET => return error.ConnectionResetByPeer,
                .EMSGSIZE => return error.MessageTooBig,
                .ENOBUFS => return error.SystemResources,
                .ENOTSOCK => return error.FileDescriptorNotASocket,
                .EAFNOSUPPORT => return error.AddressFamilyNotSupported,
                .EDESTADDRREQ => unreachable, // A destination address is required.
                .EFAULT => unreachable, // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent, or lpCompletionRoutine parameters are not part of the user address space, or the lpTo parameter is too small.
                .EHOSTUNREACH => return error.NetworkUnreachable,
                .EINVAL => unreachable,
                .ENETDOWN => return error.NetworkSubsystemFailed,
                .ENETRESET => return error.ConnectionResetByPeer,
                .ENETUNREACH => return error.NetworkUnreachable,
                .ENOTCONN => return error.SocketNotConnected,
                .ESHUTDOWN => unreachable, // The socket has been shut down; it is not possible to WSASendTo on a socket after shutdown has been invoked with how set to SD_SEND or SD_BOTH.
                .NOTINITIALISED => unreachable, // A successful WSAStartup call must occur before using this function.
                else => |err| return unexpectedWSAError(err),
            }
        }
        break;
    }
    return @intCast(written);
}

pub fn recvmsg(sockfd: std.posix.socket_t, msg: *msghdr, _: u32) !usize {
    const DumbStuff = struct {
        var once = std.once(do_once);
        var fun: win_sock.LPFN_WSARECVMSG = undefined;
        var have_fun = false;
        fn do_once() void {
            const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch unreachable;
            defer std.posix.close(sock);
            var trash: u32 = 0;
            const res = win_sock.WSAIoctl(
                sock,
                win_sock.SIO_GET_EXTENSION_FUNCTION_POINTER,
                // not in zigwin32
                @constCast(@ptrCast(&std.os.windows.ws2_32.WSAID_WSARECVMSG.Data4)),
                std.os.windows.ws2_32.WSAID_WSARECVMSG.Data4.len,
                @ptrCast(&fun),
                @sizeOf(@TypeOf(fun)),
                &trash,
                null,
                null,
            );
            have_fun = res != win_sock.SOCKET_ERROR;
        }
    };
    DumbStuff.once.call();
    if (!DumbStuff.have_fun) return error.Unexpected;
    var read: u32 = 0;
    while (true) {
        const rc = DumbStuff.fun(sockfd, msg, &read, null, null);
        if (rc == win_sock.SOCKET_ERROR) {
            switch (win_sock.WSAGetLastError()) {
                .EWOULDBLOCK, .EINTR, .EINPROGRESS => continue,
                .EACCES => return error.AccessDenied,
                .EADDRNOTAVAIL => return error.AddressNotAvailable,
                .ECONNRESET => return error.ConnectionResetByPeer,
                .EMSGSIZE => return error.MessageTooBig,
                .ENOBUFS => return error.SystemResources,
                .ENOTSOCK => return error.FileDescriptorNotASocket,
                .EAFNOSUPPORT => return error.AddressFamilyNotSupported,
                .EDESTADDRREQ => unreachable, // A destination address is required.
                .EFAULT => unreachable, // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent, or lpCompletionRoutine parameters are not part of the user address space, or the lpTo parameter is too small.
                .EHOSTUNREACH => return error.NetworkUnreachable,
                .EINVAL => unreachable,
                .ENETDOWN => return error.NetworkSubsystemFailed,
                .ENETRESET => return error.ConnectionResetByPeer,
                .ENETUNREACH => return error.NetworkUnreachable,
                .ENOTCONN => return error.SocketNotConnected,
                .ESHUTDOWN => unreachable, // The socket has been shut down; it is not possible to WSASendTo on a socket after shutdown has been invoked with how set to SD_SEND or SD_BOTH.
                .NOTINITIALISED => unreachable, // A successful WSAStartup call must occur before using this function.
                else => |err| return unexpectedWSAError(err),
            }
        }
        break;
    }
    return @intCast(read);
}
