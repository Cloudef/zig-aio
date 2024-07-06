const builtin = @import("builtin");
const std = @import("std");
const aio = @import("../aio.zig");
const Operation = @import("ops.zig").Operation;
const ItemPool = @import("minilib").ItemPool;
const DynamicThreadPool = @import("minilib").DynamicThreadPool;
const DoubleBufferedFixedArrayList = @import("minilib").DoubleBufferedFixedArrayList;
const TimerQueue = @import("minilib").TimerQueue;
const Fallback = @import("Fallback.zig");
const Uringlator = @import("Uringlator.zig");
const unexpectedError = @import("posix/windows.zig").unexpectedError;
const werr = @import("posix/windows.zig").werr;
const wtry = @import("posix/windows.zig").wtry;
const checked = @import("posix/windows.zig").checked;
const Iocp = @import("posix/windows.zig").Iocp;
const win32 = @import("win32");

const Windows = @This();

// This is a slightly lighter version of the Fallback backend.
// Optimized for Windows and uses IOCP operations whenever possible.
// <https://int64.org/2009/05/14/io-completion-ports-made-easy/>

pub const IO = switch (aio.options.fallback) {
    .auto => Windows, // Fallback until Windows backend is complete
    .force => Fallback, // use only the fallback backend
    .disable => Windows, // use only the Windows backend
};

pub const EventSource = Uringlator.EventSource;

comptime {
    if (builtin.single_threaded) {
        @compileError(
            \\Windows backend requires building with threads as otherwise it may block the whole program.
        );
    }
}

const GetLastError = win32.foundation.GetLastError;
const INVALID_HANDLE = std.os.windows.INVALID_HANDLE_VALUE;
const HANDLE = win32.foundation.HANDLE;
const CloseHandle = win32.foundation.CloseHandle;
const INFINITE = win32.system.windows_programming.INFINITE;
const io = win32.system.io;
const fs = win32.storage.file_system;
const win_sock = win32.networking.win_sock;
const INVALID_SOCKET = win_sock.INVALID_SOCKET;
const threading = win32.system.threading;

const IoContext = struct {
    overlapped: io.OVERLAPPED = undefined,

    // needs to be cleaned up
    owned: union(enum) {
        handle: HANDLE,
        none: void,
    } = .none,

    // operation specific return value
    res: usize = 0,

    pub fn deinit(self: *@This()) void {
        switch (self.owned) {
            .handle => |h| checked(CloseHandle(h)),
            .none => {},
        }
        self.* = undefined;
    }
};

iocp: Iocp,
tqueue: TimerQueue, // timer queue implementing linux -like timers
tpool: DynamicThreadPool, // thread pool for performing iocp and non iocp operations
iocp_threads_spawned: bool = false, // iocp needs own poll threads
ovls: []IoContext,
uringlator: Uringlator,

pub fn isSupported(_: []const type) bool {
    return true; // very optimistic :D
}

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    // need at least 2 threads, 1 iocp thread and 1 non-iocp blocking task thread
    const num_threads: u32 = @max(2, aio.options.max_threads orelse @as(u32, @intCast(std.Thread.getCpuCount() catch 1)));
    var iocp = try Iocp.init(num_threads / 2);
    errdefer iocp.deinit();
    var tqueue = try TimerQueue.init(allocator);
    errdefer tqueue.deinit();
    var tpool = DynamicThreadPool.init(allocator, .{ .max_threads = num_threads }) catch |err| return switch (err) {
        error.TimerUnsupported => error.Unsupported,
        else => |e| e,
    };
    errdefer tpool.deinit();
    const ovls = try allocator.alloc(IoContext, n);
    errdefer allocator.free(ovls);
    var uringlator = try Uringlator.init(allocator, n);
    errdefer uringlator.deinit(allocator);
    return .{
        .iocp = iocp,
        .tqueue = tqueue,
        .tpool = tpool,
        .ovls = ovls,
        .uringlator = uringlator,
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.uringlator.shutdown(*@This(), self, cancelable, completion);
    self.iocp.deinit();
    self.tqueue.deinit();
    self.tpool.deinit();
    allocator.free(self.ovls);
    self.uringlator.deinit(allocator);
    self.* = undefined;
}

fn queueCallback(self: *@This(), id: u16, uop: *Operation.Union) aio.Error!void {
    self.ovls[id] = .{};
    switch (uop.*) {
        .wait_event_source => |*op| op._ = .{ .id = id, .iocp = &self.iocp },
        .accept => |*op| op.out_socket.* = INVALID_SOCKET,
        inline .recv, .send => |*op| op._ = .{.{ .buf = @constCast(@ptrCast(op.buffer.ptr)), .len = @intCast(op.buffer.len) }},
        else => {},
    }
}

pub fn queue(self: *@This(), comptime len: u16, work: anytype, cb: ?aio.Dynamic.QueueCallback) aio.Error!void {
    try self.uringlator.queue(len, work, cb, *@This(), self, queueCallback);
}

fn iocpDrainThread(self: *@This()) void {
    while (true) {
        var transferred: u32 = undefined;
        var key: usize = undefined;
        var maybe_ovl: ?*io.OVERLAPPED = null;
        const res = io.GetQueuedCompletionStatus(self.iocp.port, &transferred, &key, &maybe_ovl, INFINITE);
        if (res == 1) {
            if (key == Iocp.Notification.Key) {
                const note: Iocp.Notification = @bitCast(transferred);
                switch (note.type) {
                    .shutdown => break,
                    .event_source => {
                        const source: *EventSource = @ptrCast(@alignCast(maybe_ovl.?));
                        source.wait();
                        self.uringlator.finish(note.id, error.Success);
                    },
                }
            } else {
                const ctx: *IoContext = @fieldParentPtr("overlapped", maybe_ovl.?);
                ctx.res = transferred;
                const id: u16 = @intCast((@intFromPtr(ctx) - @intFromPtr(self.ovls.ptr)) / @sizeOf(IoContext));
                self.uringlator.finish(id, error.Success);
            }
        } else if (maybe_ovl) |_| {
            std.debug.assert(key != Iocp.Notification.Key);
            const ctx: *IoContext = @fieldParentPtr("overlapped", maybe_ovl.?);
            const id: u16 = @intCast((@intFromPtr(ctx) - @intFromPtr(self.ovls.ptr)) / @sizeOf(IoContext));
            self.uringlator.finish(id, werr(0));
        } else {
            // most likely port was closed, but check error here in future to make sure
            break;
        }
    }
}

fn spawnIocpThreads(self: *@This()) !void {
    @setCold(true);
    for (0..self.iocp.num_threads) |_| self.tpool.spawn(iocpDrainThread, .{self}) catch return error.SystemResources;
    self.iocp_threads_spawned = true;
}

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode, cb: ?aio.Dynamic.CompletionCallback) aio.Error!aio.CompletionResult {
    if (!self.iocp_threads_spawned) try self.spawnIocpThreads(); // iocp threads must be first
    if (!try self.uringlator.submit(*@This(), self, start, cancelable)) return .{};

    const num_finished = self.uringlator.finished.len();
    if (mode == .blocking and num_finished == 0) {
        self.uringlator.source.wait();
    } else if (num_finished == 0) {
        return .{};
    }

    return self.uringlator.complete(cb, *@This(), self, completion);
}

pub fn immediate(comptime len: u16, work: anytype) aio.Error!u16 {
    var sfb = std.heap.stackFallback(len * 1024, std.heap.page_allocator);
    const allocator = sfb.get();
    var wrk = try init(allocator, len);
    defer wrk.deinit(allocator);
    try wrk.queue(len, work, null);
    var n: u16 = len;
    var num_errors: u16 = 0;
    while (n > 0) {
        const res = try wrk.complete(.blocking, null);
        n -= res.num_completed;
        num_errors += res.num_errors;
    }
    return num_errors;
}

fn onThreadPosixExecutor(self: *@This(), id: u16, uop: *Operation.Union) void {
    const posix = @import("posix.zig");
    var failure: Operation.Error = error.Success;
    Uringlator.uopUnwrapCall(uop, posix.perform, .{undefined}) catch |err| {
        failure = err;
    };
    self.uringlator.finish(id, failure);
}

fn onThreadTimeout(ctx: *anyopaque, user_data: usize) void {
    var self: *@This() = @ptrCast(@alignCast(ctx));
    self.uringlator.finish(@intCast(user_data), error.Success);
}

fn ovlOff(offset: u64) io.OVERLAPPED {
    return .{
        .Internal = undefined,
        .InternalHigh = undefined,
        .Anonymous = .{ .Anonymous = @bitCast(offset) },
        .hEvent = undefined,
    };
}

const AccessInfo = packed struct {
    read: bool,
    write: bool,
    append: bool,
};

fn getHandleAccessInfo(handle: HANDLE) !fs.FILE_ACCESS_FLAGS {
    var io_status_block: std.os.windows.IO_STATUS_BLOCK = undefined;
    var access: std.os.windows.FILE_ACCESS_INFORMATION = undefined;
    const rc = std.os.windows.ntdll.NtQueryInformationFile(handle, &io_status_block, &access, @sizeOf(std.os.windows.FILE_ACCESS_INFORMATION), .FileAccessInformation);
    switch (rc) {
        .SUCCESS => {},
        .INVALID_PARAMETER => unreachable,
        else => return error.Unexpected,
    }
    return @bitCast(access.AccessFlags);
}

fn start(self: *@This(), id: u16, uop: *Operation.Union) !void {
    var trash: u32 = undefined;
    switch (uop.*) {
        .read => |*op| {
            const flags = try getHandleAccessInfo(op.file.handle);
            if (flags.FILE_READ_DATA != 1) {
                self.uringlator.finish(id, error.NotOpenForReading);
                return;
            }
            const h = fs.ReOpenFile(op.file.handle, flags, .{ .READ = 1, .WRITE = 1 }, fs.FILE_FLAG_OVERLAPPED).?;
            wtry(h != INVALID_HANDLE) catch |err| return self.uringlator.finish(id, err);
            self.iocp.associateHandle(h) catch |err| return self.uringlator.finish(id, err);
            self.ovls[id] = .{ .overlapped = ovlOff(op.offset), .owned = .{ .handle = h } };
            wtry(fs.ReadFile(h, op.buffer.ptr, @intCast(op.buffer.len), &trash, &self.ovls[id].overlapped)) catch |err| return self.uringlator.finish(id, err);
        },
        .write => |*op| {
            const flags = try getHandleAccessInfo(op.file.handle);
            if (flags.FILE_WRITE_DATA != 1) {
                self.uringlator.finish(id, error.NotOpenForWriting);
                return;
            }
            const h = fs.ReOpenFile(op.file.handle, flags, .{ .READ = 1, .WRITE = 1 }, fs.FILE_FLAG_OVERLAPPED).?;
            wtry(h != INVALID_HANDLE) catch |err| return self.uringlator.finish(id, err);
            self.iocp.associateHandle(h) catch |err| return self.uringlator.finish(id, err);
            self.ovls[id] = .{ .overlapped = ovlOff(op.offset), .owned = .{ .handle = h } };
            wtry(fs.WriteFile(h, op.buffer.ptr, @intCast(op.buffer.len), &trash, &self.ovls[id].overlapped)) catch |err| return self.uringlator.finish(id, err);
        },
        inline .timeout, .link_timeout => |*op| {
            const closure: TimerQueue.Closure = .{ .context = self, .callback = onThreadTimeout };
            self.tqueue.schedule(.monotonic, op.ns, id, .{ .closure = closure }) catch self.uringlator.finish(id, error.Unexpected);
        },
        .wait_event_source => |*op| op.source.native.addWaiter(&op._.link),
        .notify_event_source => |*op| op.source.notify(),
        .close_event_source => |*op| op.source.deinit(),
        .accept => |*op| {
            self.iocp.associateSocket(op.socket) catch |err| return self.uringlator.finish(id, err);
            op.out_socket.* = aio.socket(std.posix.AF.INET, 0, 0) catch |err| return self.uringlator.finish(id, err);
            wtry(win_sock.AcceptEx(op.socket, op.out_socket.*, &op._, 0, @sizeOf(std.posix.sockaddr) + 16, @sizeOf(std.posix.sockaddr) + 16, &trash, &self.ovls[id].overlapped) == 1) catch |err| return self.uringlator.finish(id, err);
        },
        .recv => |*op| {
            var flags: u32 = 0;
            self.iocp.associateSocket(op.socket) catch |err| return self.uringlator.finish(id, err);
            wtry(win_sock.WSARecv(op.socket, &op._, 1, null, &flags, &self.ovls[id].overlapped, null) == 0) catch |err| return self.uringlator.finish(id, err);
        },
        .send => |*op| {
            self.iocp.associateSocket(op.socket) catch |err| return self.uringlator.finish(id, err);
            wtry(win_sock.WSASend(op.socket, &op._, 1, null, 0, &self.ovls[id].overlapped, null) == 0) catch |err| return self.uringlator.finish(id, err);
        },
        // TODO: WSASendMsg
        // TODO: WSARecvMsg
        else => {
            // perform non IOCP supported operation on a thread
            self.tpool.spawn(onThreadPosixExecutor, .{ self, id, uop }) catch return error.SystemResources;
        },
    }
}

fn cancelable(_: *@This(), _: u16, uop: *Operation.Union) bool {
    return switch (uop.*) {
        .timeout, .link_timeout => true,
        .wait_event_source => true,
        else => false,
    };
}

fn completion(self: *@This(), id: u16, uop: *Operation.Union, failure: Operation.Error) void {
    defer self.ovls[id].deinit();
    if (failure == error.Success) {
        switch (uop.*) {
            .timeout, .link_timeout => self.tqueue.disarm(.monotonic, id),
            .wait_event_source => |*op| op.source.native.removeWaiter(&op._.link),
            .accept => |*op| {
                if (op.out_addr) |a| @memcpy(std.mem.asBytes(a), op._[@sizeOf(std.posix.sockaddr) + 16 .. @sizeOf(std.posix.sockaddr) * 2 + 16]);
            },
            inline .read, .recv => |*op| op.out_read.* = self.ovls[id].res,
            inline .write, .send => |*op| {
                if (op.out_written) |w| w.* = self.ovls[id].res;
            },
            else => {},
        }
    } else {
        switch (uop.*) {
            .timeout, .link_timeout => self.tqueue.disarm(.monotonic, id),
            .wait_event_source => |*op| op.source.native.removeWaiter(&op._.link),
            .accept => |*op| if (op.out_socket.* != INVALID_SOCKET) checked(CloseHandle(op.out_socket.*)),
            else => {},
        }
    }
}
