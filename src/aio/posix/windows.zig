const std = @import("std");
const posix = @import("../posix.zig");
const log = std.log.scoped(.aio_windows);

const HANDLE = std.os.windows.HANDLE;
const WINAPI = std.os.windows.WINAPI;
const BOOL = std.os.windows.BOOL;
const INFINITE = std.os.windows.INFINITE;
const MAXIMUM_WAIT_OBJECTS = std.os.windows.MAXIMUM_WAIT_OBJECTS;
const SECURITY_ATTRIBUTES = std.os.windows.SECURITY_ATTRIBUTES;
const LPCWSTR = std.os.windows.LPCWSTR;
const DWORD = std.os.windows.DWORD;
const LONG = std.os.windows.LONG;
const LARGE_INTEGER = packed struct(std.os.windows.LARGE_INTEGER) {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,
};

pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(WINAPI) BOOL;
pub extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(WINAPI) BOOL;

pub const TIMER_ALL_ACCESS = 0x1F0003;
pub const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = 0x00000002;
pub extern "kernel32" fn CreateWaitableTimerExW(attributes: ?*SECURITY_ATTRIBUTES, nameW: ?LPCWSTR, flags: DWORD, access: DWORD) callconv(WINAPI) HANDLE;
pub extern "kernel32" fn SetWaitableTimer(hTimer: HANDLE, due: *const LARGE_INTEGER, period: LONG, cb: ?*anyopaque, cb_arg: ?*anyopaque, restore_system: BOOL) callconv(WINAPI) BOOL;

pub const EventSource = struct {
    fd: HANDLE,
    counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub inline fn init() !@This() {
        return .{
            .fd = try std.os.windows.CreateEventExW(
                null,
                null,
                std.os.windows.CREATE_EVENT_MANUAL_RESET,
                std.os.windows.EVENT_ALL_ACCESS,
            ),
        };
    }

    pub inline fn deinit(self: *@This()) void {
        std.os.windows.CloseHandle(self.fd);
        self.* = undefined;
    }

    pub inline fn notify(self: *@This()) void {
        if (self.counter.fetchAdd(1, .monotonic) == 0) {
            std.debug.assert(SetEvent(self.fd) != 0);
        }
    }

    pub inline fn notifyReadiness(self: *@This()) posix.Readiness {
        return .{ .fd = self.fd, .mode = .out };
    }

    pub inline fn wait(self: *@This()) void {
        const v = self.counter.load(.acquire);
        if (v > 0) {
            if (self.counter.fetchSub(1, .release) == 1) {
                std.debug.assert(ResetEvent(self.fd) != 0);
            }
        } else {
            std.os.windows.WaitForSingleObject(self.fd, INFINITE) catch unreachable;
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

pub const Timer = struct {
    fd: std.posix.fd_t,
    clock: posix.Clock,

    pub fn init(clock: posix.Clock) !@This() {
        return .{ .fd = CreateWaitableTimerExW(null, null, 0, TIMER_ALL_ACCESS), .clock = clock };
    }

    pub fn set(self: *@This(), ns: u128) !void {
        const rel_time: i128 = @intCast(ns);
        const li = nanoSecondsToTimerTime(-rel_time);
        if (SetWaitableTimer(self.fd, &li, 0, null, null, 0) == 0) {
            return error.Unexpected;
        }
    }

    pub fn deinit(self: *@This()) void {
        std.os.windows.CloseHandle(self.fd);
        self.* = undefined;
    }
};

pub const pollfd = struct {
    fd: HANDLE,
    events: i16,
    revents: i16,
};

pub fn poll(pfds: []pollfd, timeout: i32) std.posix.PollError!usize {
    var outs: usize = 0;
    for (pfds) |*pfd| if (pfd.events & std.posix.POLL.OUT != 0) {
        pfd.revents = std.posix.POLL.OUT;
        outs += 1;
    };
    if (outs > 0) return outs;
    std.debug.assert(pfds.len <= MAXIMUM_WAIT_OBJECTS); // rip windows
    var handles: [MAXIMUM_WAIT_OBJECTS]HANDLE = undefined;
    for (handles[0..pfds.len], pfds[0..]) |*h, *pfd| h.* = pfd.fd;
    const idx = std.os.windows.WaitForMultipleObjectsEx(
        handles[0..pfds.len],
        false,
        if (timeout < 0) INFINITE else @intCast(timeout),
        false,
    ) catch |err| switch (err) {
        error.WaitAbandoned, error.WaitTimeOut => return 0,
        error.Unexpected => blk: {
            // find out the handle that caused the error
            // then let the Fallback perform it anyways so we can collect the real error
            for (handles[0..pfds.len], 0..) |h, idx| {
                std.os.windows.WaitForSingleObject(h, 0) catch break :blk idx;
            }
            unreachable;
        },
        else => |e| return e,
    };
    pfds[idx].revents = pfds[idx].events;
    return 1;
}

pub fn nanoSecondsToTimerTime(ns: i128) LARGE_INTEGER {
    const signed: i64 = @intCast(@divFloor(ns, 100));
    const adjusted: u64 = @bitCast(signed);
    return LARGE_INTEGER{
        .dwHighDateTime = @as(u32, @truncate(adjusted >> 32)),
        .dwLowDateTime = @as(u32, @truncate(adjusted)),
    };
}

pub const msghdr = std.os.windows.ws2_32.msghdr;
pub const msghdr_const = std.os.windows.ws2_32.msghdr_const;

pub fn sendmsg(sockfd: std.posix.socket_t, msg: *const msghdr_const, flags: u32) !usize {
    var written: u32 = 0;
    while (true) {
        const rc = std.os.windows.ws2_32.WSASendMsg(sockfd, @constCast(msg), flags, &written, null, null);
        if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
            switch (std.os.windows.ws2_32.WSAGetLastError()) {
                .WSAEWOULDBLOCK, .WSAEINTR => continue,
                .WSAEACCES => return error.AccessDenied,
                .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
                .WSAECONNRESET => return error.ConnectionResetByPeer,
                .WSAEMSGSIZE => return error.MessageTooBig,
                .WSAENOBUFS => return error.SystemResources,
                .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
                .WSAEDESTADDRREQ => unreachable, // A destination address is required.
                .WSAEFAULT => unreachable, // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent, or lpCompletionRoutine parameters are not part of the user address space, or the lpTo parameter is too small.
                .WSAEHOSTUNREACH => return error.NetworkUnreachable,
                // TODO: WSAEINPROGRESS
                .WSAEINVAL => unreachable,
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                .WSAENETRESET => return error.ConnectionResetByPeer,
                .WSAENETUNREACH => return error.NetworkUnreachable,
                .WSAENOTCONN => return error.SocketNotConnected,
                .WSAESHUTDOWN => unreachable, // The socket has been shut down; it is not possible to WSASendTo on a socket after shutdown has been invoked with how set to SD_SEND or SD_BOTH.
                .WSANOTINITIALISED => unreachable, // A successful WSAStartup call must occur before using this function.
                else => |err| return std.os.windows.unexpectedWSAError(err),
            }
        }
        break;
    }
    return @intCast(written);
}

pub fn recvmsg(sockfd: std.posix.socket_t, msg: *msghdr, _: u32) !usize {
    const DumbStuff = struct {
        var once = std.once(do_once);
        var fun: std.os.windows.ws2_32.LPFN_WSARECVMSG = undefined;
        var have_fun = false;
        fn do_once() void {
            const sock = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0) catch unreachable;
            defer std.posix.close(sock);
            var trash: DWORD = 0;
            const res = std.os.windows.ws2_32.WSAIoctl(
                sock,
                std.os.windows.ws2_32.SIO_GET_EXTENSION_FUNCTION_POINTER,
                &std.os.windows.ws2_32.WSAID_WSARECVMSG.Data4,
                std.os.windows.ws2_32.WSAID_WSARECVMSG.Data4.len,
                @ptrCast(&fun),
                @sizeOf(@TypeOf(fun)),
                &trash,
                null,
                null,
            );
            have_fun = res != std.os.windows.ws2_32.SOCKET_ERROR;
        }
    };
    DumbStuff.once.call();
    if (!DumbStuff.have_fun) return error.Unexpected;
    var read: u32 = 0;
    while (true) {
        const rc = DumbStuff.fun(sockfd, msg, &read, null, null);
        if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
            switch (std.os.windows.ws2_32.WSAGetLastError()) {
                .WSAEWOULDBLOCK, .WSAEINTR => continue,
                .WSAEACCES => return error.AccessDenied,
                .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
                .WSAECONNRESET => return error.ConnectionResetByPeer,
                .WSAEMSGSIZE => return error.MessageTooBig,
                .WSAENOBUFS => return error.SystemResources,
                .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                .WSAEAFNOSUPPORT => return error.AddressFamilyNotSupported,
                .WSAEDESTADDRREQ => unreachable, // A destination address is required.
                .WSAEFAULT => unreachable, // The lpBuffers, lpTo, lpOverlapped, lpNumberOfBytesSent, or lpCompletionRoutine parameters are not part of the user address space, or the lpTo parameter is too small.
                .WSAEHOSTUNREACH => return error.NetworkUnreachable,
                // TODO: WSAEINPROGRESS
                .WSAEINVAL => unreachable,
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                .WSAENETRESET => return error.ConnectionResetByPeer,
                .WSAENETUNREACH => return error.NetworkUnreachable,
                .WSAENOTCONN => return error.SocketNotConnected,
                .WSAESHUTDOWN => unreachable, // The socket has been shut down; it is not possible to WSASendTo on a socket after shutdown has been invoked with how set to SD_SEND or SD_BOTH.
                .WSANOTINITIALISED => unreachable, // A successful WSAStartup call must occur before using this function.
                else => |err| return std.os.windows.unexpectedWSAError(err),
            }
        }
        break;
    }
    return @intCast(read);
}
