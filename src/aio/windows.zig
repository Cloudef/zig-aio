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
const win32 = @import("win32");

const Windows = @This();

// This is a slightly lighter version of the Fallback backend.
// Optimized for Windows and uses IOCP operations whenever possible.
// <https://int64.org/2009/05/14/io-completion-ports-made-easy/>

pub const IO = switch (aio.options.fallback) {
    .auto => Fallback, // Fallback until Windows backend is complete
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

const IoContext = struct {
    overlapped: io.OVERLAPPED = undefined,
    // need to dup handles to open them in OVERLAPPED mode
    specimen: union(enum) {
        handle: HANDLE,
        none: void,
    } = .none,
    // operation specific return value
    res: usize = undefined,

    pub fn deinit(self: *@This()) void {
        switch (self.specimen) {
            .handle => |h| checked(CloseHandle(h)),
            .none => {},
        }
        self.* = undefined;
    }
};

port: HANDLE, // iocp completion port
tqueue: TimerQueue, // timer queue implementing linux -like timers
tpool: DynamicThreadPool, // thread pool for performing iocp and non iocp operations
iocp_threads_spawned: bool = false, // iocp needs own poll threads
ovls: []IoContext,
uringlator: Uringlator,
num_iocp_threads: u32,

pub fn isSupported(_: []const type) bool {
    return true; // very optimistic :D
}

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    // need at least 2 threads, 1 iocp thread and 1 non-iocp blocking task thread
    const thread_count: u32 = @max(2, aio.options.max_threads orelse @as(u32, @intCast(std.Thread.getCpuCount() catch 1)));
    const port = io.CreateIoCompletionPort(INVALID_HANDLE, null, 0, @intCast(thread_count)).?;
    try wtry(port != INVALID_HANDLE);
    errdefer checked(CloseHandle(port));
    var tqueue = try TimerQueue.init(allocator);
    errdefer tqueue.deinit();
    var tpool = DynamicThreadPool.init(allocator, .{ .max_threads = thread_count }) catch |err| return switch (err) {
        error.TimerUnsupported => error.Unsupported,
        else => |e| e,
    };
    errdefer tpool.deinit();
    const ovls = try allocator.alloc(IoContext, n);
    errdefer allocator.free(ovls);
    var uringlator = try Uringlator.init(allocator, n);
    errdefer uringlator.deinit(allocator);
    return .{
        .port = port,
        .tqueue = tqueue,
        .tpool = tpool,
        .ovls = ovls,
        .uringlator = uringlator,
        // split blocking threads and iocp threads half
        .num_iocp_threads = thread_count / 2,
    };
}

const SHUTDOWN_KEY = 0xDEADBEEF;

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    // docs say that GetQueuedCompletionStatus should return if IOCP port is closed
    // this doesn't seem to happen under wine though (wine bug?)
    // anyhow, wakeup the drain thread by hand
    for (0..self.num_iocp_threads) |_| checked(io.PostQueuedCompletionStatus(self.port, 0, SHUTDOWN_KEY, null));
    checked(CloseHandle(self.port));
    self.tqueue.deinit();
    self.tpool.deinit();
    allocator.free(self.ovls);
    self.uringlator.deinit(allocator);
    self.* = undefined;
}

fn queueCallback(_: *@This(), _: u16, _: *Operation.Union) aio.Error!void {}

pub fn queue(self: *@This(), comptime len: u16, work: anytype, cb: ?aio.Dynamic.QueueCallback) aio.Error!void {
    try self.uringlator.queue(len, work, cb, *@This(), self, queueCallback);
}

fn iocpDrainThread(self: *@This()) void {
    while (true) {
        var transferred: u32 = undefined;
        var key: usize = undefined;
        var maybe_ovl: ?*io.OVERLAPPED = null;
        const res = io.GetQueuedCompletionStatus(self.port, &transferred, &key, &maybe_ovl, INFINITE);
        if (res == 1) {
            if (key == SHUTDOWN_KEY) break;
            // work complete
            const ctx: *IoContext = @fieldParentPtr("overlapped", maybe_ovl.?);
            ctx.res = transferred;
            self.uringlator.finish(@intCast(key), error.Success);
        } else if (maybe_ovl) |_| {
            if (key == SHUTDOWN_KEY) break;
            // operation failed
            self.uringlator.finish(@intCast(key), werr(0));
        } else {
            // most likely port was closed, but check error here in future to make sure
            break;
        }
    }
}

fn spawnIocpThreads(self: *@This()) !void {
    @setCold(true);
    // use only one thread, maybe tune this if neccessary in future
    for (0..self.num_iocp_threads) |_| self.tpool.spawn(iocpDrainThread, .{self}) catch return error.SystemResources;
    self.iocp_threads_spawned = true;
}

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode, cb: ?aio.Dynamic.CompletionCallback) aio.Error!aio.CompletionResult {
    if (!try self.uringlator.submit(*@This(), self, start, cancelable)) return .{};
    if (!self.iocp_threads_spawned) try self.spawnIocpThreads();

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

fn getHandleAccessInfo(handle: HANDLE) !AccessInfo {
    var io_status_block: std.os.windows.IO_STATUS_BLOCK = undefined;
    var access: std.os.windows.FILE_ACCESS_INFORMATION = undefined;
    const rc = std.os.windows.ntdll.NtQueryInformationFile(handle, &io_status_block, &access, @sizeOf(std.os.windows.FILE_ACCESS_INFORMATION), .FileAccessInformation);
    switch (rc) {
        .SUCCESS => {},
        .INVALID_PARAMETER => unreachable,
        else => return error.Unexpected,
    }
    return .{
        .read = access.AccessFlags & std.os.windows.FILE_READ_DATA != 0,
        .write = access.AccessFlags & std.os.windows.FILE_WRITE_DATA != 0,
        .append = access.AccessFlags & std.os.windows.FILE_APPEND_DATA != 0,
    };
}

fn start(self: *@This(), id: u16, uop: *Operation.Union) !void {
    var trash: u32 = undefined;
    switch (uop.*) {
        .read => |op| {
            if (!(try getHandleAccessInfo(op.file.handle)).read) {
                self.ovls[id] = .{};
                self.uringlator.finish(id, error.NotOpenForReading);
                return;
            }
            const h = fs.ReOpenFile(op.file.handle, .{ .SYNCHRONIZE = 1, .FILE_READ_DATA = 1 }, .{ .READ = 1, .WRITE = 1 }, fs.FILE_FLAG_OVERLAPPED).?;
            checked(h != INVALID_HANDLE);
            checked(io.CreateIoCompletionPort(h, self.port, id, 0).? != INVALID_HANDLE);
            self.ovls[id] = .{ .overlapped = ovlOff(op.offset), .specimen = .{ .handle = h } };
            try wtry(fs.ReadFile(h, op.buffer.ptr, @intCast(op.buffer.len), &trash, &self.ovls[id].overlapped));
        },
        .write => |op| {
            if (!(try getHandleAccessInfo(op.file.handle)).write) {
                self.ovls[id] = .{};
                self.uringlator.finish(id, error.NotOpenForWriting);
                return;
            }
            const h = fs.ReOpenFile(op.file.handle, .{ .SYNCHRONIZE = 1, .FILE_WRITE_DATA = 1 }, .{ .READ = 1, .WRITE = 1 }, fs.FILE_FLAG_OVERLAPPED).?;
            checked(h != INVALID_HANDLE);
            checked(io.CreateIoCompletionPort(h, self.port, id, 0).? != INVALID_HANDLE);
            self.ovls[id] = .{ .overlapped = ovlOff(op.offset), .specimen = .{ .handle = h } };
            try wtry(fs.WriteFile(h, op.buffer.ptr, @intCast(op.buffer.len), &trash, &self.ovls[id].overlapped));
        },
        inline .timeout, .link_timeout => |*op| {
            const closure: TimerQueue.Closure = .{ .context = self, .callback = onThreadTimeout };
            try self.tqueue.schedule(.monotonic, op.ns, id, .{ .closure = closure });
        },
        // TODO: AcceptEx
        // TODO: WSASend
        // TODO: WSARecv
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
        else => false,
    };
}

fn completion(self: *@This(), id: u16, uop: *Operation.Union) void {
    switch (uop.*) {
        .timeout, .link_timeout => self.tqueue.disarm(.monotonic, id),
        .read => |op| {
            op.out_read.* = self.ovls[id].res;
            self.ovls[id].deinit();
        },
        .write => |op| {
            if (op.out_written) |w| w.* = self.ovls[id].res;
            self.ovls[id].deinit();
        },
        else => {},
    }
}
