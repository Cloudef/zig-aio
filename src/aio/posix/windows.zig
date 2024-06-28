const std = @import("std");
const posix = @import("../posix.zig");
const ops = @import("../ops.zig");
const log = std.log.scoped(.aio_windows);

const WINAPI = std.os.windows.WINAPI;
const HANDLE = std.os.windows.HANDLE;
const CHAR = std.os.windows.CHAR;
const WCHAR = std.os.windows.WCHAR;
const BOOL = std.os.windows.BOOL;
const UINT = std.os.windows.UINT;
const WORD = std.os.windows.WORD;
const DWORD = std.os.windows.DWORD;
const LONG = std.os.windows.LONG;
const LARGE_INTEGER = packed struct(std.os.windows.LARGE_INTEGER) {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,
};
const COORD = std.os.windows.COORD;
const LPCWSTR = std.os.windows.LPCWSTR;
const INFINITE = std.os.windows.INFINITE;
const MAXIMUM_WAIT_OBJECTS = std.os.windows.MAXIMUM_WAIT_OBJECTS;
const SECURITY_ATTRIBUTES = std.os.windows.SECURITY_ATTRIBUTES;

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

pub const KEY_EVENT_RECORD = extern struct {
    bKeyDown: BOOL,
    wRepeatCount: WORD,
    wVirtualKeyCode: WORD,
    wVirtualScanCode: WORD,
    uChar: extern union {
        UnicodeChar: WCHAR,
        AsciiChar: CHAR,
    },
    dwControlKeyState: DWORD,
};

pub const MOUSE_EVENT_RECORD = extern struct {
    dwMousePosition: COORD,
    dwButtonState: DWORD,
    dwControlKeyState: DWORD,
    dwEventFlags: DWORD,
};

pub const WINDOW_BUFFER_SIZE_RECORD = extern struct {
    dwSize: COORD,
};

pub const MENU_EVENT_RECORD = extern struct {
    dwCommandId: UINT,
};

pub const FOCUS_EVENT_RECORD = extern struct {
    bSetFocus: BOOL,
};

pub const INPUT_RECORD = extern struct {
    EventType: enum(WORD) {
        key = 0x0001,
        mouse = 0x0002,
        resize = 0x0004,
        focus = 0x0010,
    },
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        MouseEvent: MOUSE_EVENT_RECORD,
        WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD,
        MenuEvent: MENU_EVENT_RECORD,
        FocusEvent: FOCUS_EVENT_RECORD,
    },
};

pub extern "kernel32" fn ReadConsoleInputW(hConsoleInput: HANDLE, lpBuffer: *INPUT_RECORD, nLength: DWORD, lpNumberOfEventsRead: *DWORD) callconv(WINAPI) BOOL;

pub fn translateTty(fd: std.posix.fd_t, buf: []u8, state: *ops.ReadTty.TranslationState) ops.ReadTty.Error!usize {
    // This code is mostly from Vaxis, but I'm undoing what Vaxis is doing :)
    var read: u32 = 0;
    var record: INPUT_RECORD = undefined;
    if (ReadConsoleInputW(fd, &record, 1, &read) == 0) {
        return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
    }

    var stream = std.io.fixedBufferStream(buf);
    switch (record.EventType) {
        .key => {
            const ev = record.Event.KeyEvent;
            const base: u21 = switch (ev.wVirtualKeyCode) {
                0x00 => 0, // escape seq
                else => 0,
            };

            var codepoint: u21 = base;
            switch (ev.uChar.UnicodeChar) {
                0x00...0x1F => {},
                else => |cp| {
                    codepoint = cp;
                    // const len = try std.unicode.utf8Encode(cp, &self.buf);
                    // text = self.buf[0..len];
                },
            }

            const press = ev.bKeyDown != 0;
            _ = press; // autofix
        },
        .mouse => {
            const ev = record.Event.MouseEvent;

            // High word of dwButtonState represents mouse wheel. Positive is wheel_up, negative
            // is wheel_down
            // Low word represents button state
            const mouse_wheel_direction: i16 = blk: {
                const wheelu32: u32 = ev.dwButtonState >> 16;
                const wheelu16: u16 = @truncate(wheelu32);
                break :blk @bitCast(wheelu16);
            };

            const buttons: u16 = @truncate(ev.dwButtonState);
            // save the current state when we are done
            defer state.last_mouse_button_press = buttons;
            const button_xor = state.last_mouse_button_press ^ buttons;

            const EventType = enum {
                press,
                drag,
                motion,
                release,
                unknown,
            };

            const Button = enum {
                none,
                wheel_up,
                wheel_down,
                left,
                right,
                middle,
                button_8,
                button_9,
                unknown,
            };

            var event_type: EventType = .press;
            const btn: Button = switch (button_xor) {
                0x0000 => blk: {
                    // Check wheel event
                    if (ev.dwEventFlags & 0x0004 > 0) {
                        if (mouse_wheel_direction > 0)
                            break :blk .wheel_up
                        else
                            break :blk .wheel_down;
                    }

                    // If we have no change but one of the buttons is still pressed we have a
                    // drag event. Find out which button is held down
                    if (buttons > 0 and ev.dwEventFlags & 0x0001 > 0) {
                        event_type = .drag;
                        if (buttons & 0x0001 > 0) break :blk .left;
                        if (buttons & 0x0002 > 0) break :blk .right;
                        if (buttons & 0x0004 > 0) break :blk .middle;
                        if (buttons & 0x0008 > 0) break :blk .button_8;
                        if (buttons & 0x0010 > 0) break :blk .button_9;
                    }

                    if (ev.dwEventFlags & 0x0001 > 0) event_type = .motion;
                    break :blk .none;
                },
                0x0001 => blk: {
                    if (buttons & 0x0001 == 0) event_type = .release;
                    break :blk .left;
                },
                0x0002 => blk: {
                    if (buttons & 0x0002 == 0) event_type = .release;
                    break :blk .right;
                },
                0x0004 => blk: {
                    if (buttons & 0x0004 == 0) event_type = .release;
                    break :blk .middle;
                },
                0x0008 => blk: {
                    if (buttons & 0x0008 == 0) event_type = .release;
                    break :blk .button_8;
                },
                0x0010 => blk: {
                    if (buttons & 0x0010 == 0) event_type = .release;
                    break :blk .button_9;
                },
                else => .unknown,
            };
            _ = btn; // autofix

            const Mods = packed struct {
                shift: bool,
                alt: bool,
                ctrl: bool,
            };

            const shift: u32 = 0x0010;
            const alt: u32 = 0x0001 | 0x0002;
            const ctrl: u32 = 0x0004 | 0x0008;
            const mods: Mods = .{
                .shift = ev.dwControlKeyState & shift > 0,
                .alt = ev.dwControlKeyState & alt > 0,
                .ctrl = ev.dwControlKeyState & ctrl > 0,
            };
            _ = mods; // autofix
        },
        .resize => {
            // NOTE: Even though the event comes with a size, it may not be accurate. We ask for
            // the size directly when we get this event
            var console_info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (std.os.windows.kernel32.GetConsoleScreenBufferInfo(state.stdout.handle, &console_info) == 0) {
                return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
            }
            const window_rect = console_info.srWindow;
            const width = window_rect.Right - window_rect.Left;
            const height = window_rect.Bottom - window_rect.Top;
            _ = try stream.writer().print(.{0x1b} ++ "[8;{};{}t", .{ width, height });
        },
        .focus => {
            const ev = record.Event.FocusEvent;
            const focus_in = ev.bSetFocus != 0;
            if (focus_in) {
                _ = try stream.write(.{0x1b} ++ "[I");
            } else {
                _ = try stream.write(.{0x1b} ++ "[0");
            }
        },
    }
    return 0;
}

pub fn readTty(fd: std.posix.fd_t, buf: []u8, mode: ops.ReadTty.Mode) ops.ReadTty.Error!usize {
    return switch (mode) {
        .direct => {
            if (buf.len < @sizeOf(INPUT_RECORD)) {
                return error.NoSpaceLeft;
            }
            var read: u32 = 0;
            const n_fits: u32 = @intCast(buf.len / @sizeOf(INPUT_RECORD));
            if (ReadConsoleInputW(fd, @ptrCast(@alignCast(buf.ptr)), n_fits, &read) == 0) {
                return std.os.windows.unexpectedError(std.os.windows.kernel32.GetLastError());
            }
            return read * @sizeOf(INPUT_RECORD);
        },
        .translation => |state| translateTty(fd, buf, state),
    };
}

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
