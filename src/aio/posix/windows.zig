const std = @import("std");
const posix = @import("../posix.zig");
const ops = @import("../ops.zig");
const log = std.log.scoped(.aio_windows);
const Link = @import("minilib").Link;
const win32 = @import("win32");

const INFINITE = win32.system.windows_programming.INFINITE;
const GetLastError = win32.foundation.GetLastError;
const CloseHandle = win32.foundation.CloseHandle;
const INVALID_HANDLE = win32.foundation.INVALID_HANDLE_VALUE;
const HANDLE = win32.foundation.HANDLE;
const threading = win32.system.threading;
const console = win32.system.console;
const win_sock = win32.networking.win_sock;
const io = win32.system.io;

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

// Light wrapper, mainly to link EventSources to this
pub const Iocp = struct {
    pub const Notification = packed struct(u32) {
        pub const Key = std.math.maxInt(usize);
        type: enum(u16) {
            shutdown,
            event_source,
        },
        id: u16,
    };

    port: HANDLE,
    num_threads: u32,

    pub fn init(num_threads: u32) !@This() {
        const port = io.CreateIoCompletionPort(INVALID_HANDLE, null, 0, num_threads).?;
        try wtry(port != INVALID_HANDLE);
        errdefer checked(CloseHandle(port));
        return .{ .port = port, .num_threads = num_threads };
    }

    pub fn notify(self: *@This(), data: Notification, ptr: ?*anyopaque) void {
        // data for notification is put into the transferred bytes, overlapped can be anything
        checked(io.PostQueuedCompletionStatus(self.port, @bitCast(data), Notification.Key, @ptrCast(@alignCast(ptr))));
    }

    pub fn deinit(self: *@This()) void {
        // docs say that GetQueuedCompletionStatus should return if IOCP port is closed
        // this doesn't seem to happen under wine though (wine bug?)
        // anyhow, wakeup the drain thread by hand
        for (0..self.num_threads) |_| self.notify(.{ .type = .shutdown, .id = 0 }, null);
        checked(CloseHandle(self.port));
        self.* = undefined;
    }

    pub fn associateHandle(self: *@This(), handle: HANDLE) !void {
        // always assiocate the handle as the key, because the key should have the life time of a handle
        const res = io.CreateIoCompletionPort(handle, self.port, @intFromPtr(handle), 0);
        if (res == null or res.? == INVALID_HANDLE) {
            // ignore 87 as it may mean that we just re-registered the handle
            if (GetLastError() == .ERROR_INVALID_PARAMETER) return;
            try wtry(0);
        }
    }

    pub fn associateSocket(self: *@This(), sock: std.posix.socket_t) !void {
        return self.associateHandle(@ptrCast(sock));
    }
};

pub const EventSource = struct {
    pub const WaitList = std.SinglyLinkedList(Link(ops.WaitEventSource.WindowsContext, "link", .single));
    fd: HANDLE,
    counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    waiters: WaitList = .{},
    mutex: std.Thread.Mutex = .{},

    pub fn init() !@This() {
        return .{ .fd = try (threading.CreateEventW(null, 1, 1, null) orelse error.SystemResources) };
    }

    pub fn deinit(self: *@This()) void {
        std.debug.assert(self.waiters.first == null); // having dangling waiters is bad
        checked(CloseHandle(self.fd));
        self.* = undefined;
    }

    pub fn notify(self: *@This()) void {
        if (self.counter.fetchAdd(1, .monotonic) == 0) {
            wtry(threading.SetEvent(self.fd)) catch @panic("EventSource.notify failed");
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.waiters.popFirst()) |w| w.data.cast().iocp.notify(.{ .type = .event_source, .id = w.data.cast().id }, self);
        }
    }

    pub fn notifyReadiness(self: *@This()) posix.Readiness {
        return .{ .fd = self.fd, .mode = .out };
    }

    pub fn wait(self: *@This()) void {
        while (self.counter.load(.acquire) == 0) {
            wtry(threading.WaitForSingleObject(self.fd, INFINITE) == 0) catch @panic("EventSource.wait failed");
        }
        if (self.counter.fetchSub(1, .release) == 1) {
            wtry(threading.ResetEvent(self.fd)) catch @panic("EventSource.wait failed");
        }
    }

    pub fn waitReadiness(self: *@This()) posix.Readiness {
        return .{ .fd = self.fd, .mode = .in };
    }

    pub fn addWaiter(self: *@This(), node: *WaitList.Node) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.waiters.prepend(node);
    }

    pub fn removeWaiter(self: *@This(), node: *WaitList.Node) void {
        blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            // safer list.remove ...
            if (self.waiters.first == node) {
                self.waiters.first = node.next;
            } else if (self.waiters.first) |first| {
                var current_elm = first;
                while (current_elm.next != node) {
                    if (current_elm.next == null) break :blk;
                    current_elm = current_elm.next.?;
                }
                current_elm.next = node.next;
            }
        }
        node.* = .{ .data = .{} };
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
    // thus this limit isn't that bad, but EventSource's are polled using this function, so you can still hit this limit
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

pub fn socket(domain: u32, socket_type: u32, protocol: u32) std.posix.SocketError!std.posix.socket_t {
    // NOTE: windows translates the SOCK.NONBLOCK/SOCK.CLOEXEC flags into
    // windows-analagous operations
    const filtered_sock_type = socket_type & ~@as(u32, std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC);
    const flags: u32 = if ((socket_type & std.posix.SOCK.CLOEXEC) != 0)
        std.os.windows.ws2_32.WSA_FLAG_NO_HANDLE_INHERIT
    else
        0;
    const rc = try std.os.windows.WSASocketW(
        @bitCast(domain),
        @bitCast(filtered_sock_type),
        @bitCast(protocol),
        null,
        0,
        flags | std.os.windows.ws2_32.WSA_FLAG_OVERLAPPED,
    );
    errdefer std.os.windows.closesocket(rc) catch unreachable;
    if ((socket_type & std.posix.SOCK.NONBLOCK) != 0) {
        var mode: c_ulong = 1; // nonblocking
        if (std.os.windows.ws2_32.SOCKET_ERROR == std.os.windows.ws2_32.ioctlsocket(rc, std.os.windows.ws2_32.FIONBIO, &mode)) {
            switch (std.os.windows.ws2_32.WSAGetLastError()) {
                // have not identified any error codes that should be handled yet
                else => unreachable,
            }
        }
    }
    return rc;
}
