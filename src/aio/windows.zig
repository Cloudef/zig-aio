const builtin = @import("builtin");
const std = @import("std");
const aio = @import("../aio.zig");
const Operation = @import("ops.zig").Operation;
const ItemPool = @import("minilib").ItemPool;
const DynamicThreadPool = @import("minilib").DynamicThreadPool;
const DoubleBufferedFixedArrayList = @import("minilib").DoubleBufferedFixedArrayList;
const Fallback = @import("Fallback.zig");
const Uringlator = @import("Uringlator.zig");
const unexpectedError = @import("posix/windows.zig").unexpectedError;
const checked = @import("posix/windows.zig").checked;
const win32 = @import("win32");

// This is a slightly lighter version of the Fallback backend.
// Optimized for Windows and uses IOCP operations whenever possible.

const GetLastError = win32.foundation.GetLastError;
const INVALID_HANDLE = std.os.windows.INVALID_HANDLE_VALUE;
const HANDLE = win32.foundation.HANDLE;
const CloseHandle = win32.foundation.CloseHandle;
const io = win32.system.io;

comptime {
    if (builtin.single_threaded) {
        @compileError(
            \\Windows backend requires building with threads as otherwise it may block the whole program.
        );
    }
}

pub const IO = switch (aio.options.fallback) {
    .auto => Fallback, // Fallback until Windows backend is complete
    .force => Fallback, // use only the fallback backend
    .disable => @This(), // use only the Windows backend
};

pub const EventSource = Uringlator.EventSource;

const Result = struct { failure: Operation.Error, id: u16 };

port: HANDLE, // iocp completion port
tpool: DynamicThreadPool, // thread pool for performing non iocp operations
uringlator: Uringlator,

pub fn isSupported(_: []const type) bool {
    return true; // very optimistic :D
}

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    const thread_count = aio.options.max_threads orelse @max(1, std.Thread.getCpuCount() catch 1);
    const port = io.CreateIoCompletionPort(INVALID_HANDLE, null, 0, @intCast(thread_count));
    if (port == null) return error.Unexpected;
    errdefer checked(CloseHandle(port));
    var tpool = DynamicThreadPool.init(allocator, .{ .max_threads = aio.options.max_threads }) catch |err| return switch (err) {
        error.TimerUnsupported => error.SystemOutdated,
        else => |e| e,
    };
    errdefer tpool.deinit();
    var uringlator = try Uringlator.init(allocator, n);
    errdefer uringlator.deinit(allocator);
    return .{
        .port = port.?,
        .tpool = tpool,
        .uringlator = uringlator,
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.tpool.deinit();
    checked(CloseHandle(self.port));
    self.uringlator.deinit(allocator);
    self.* = undefined;
}

fn queueCallback(_: *@This(), _: u16, _: *Operation.Union) aio.Error!void {}

pub fn queue(self: *@This(), comptime len: u16, work: anytype, cb: ?aio.Dynamic.QueueCallback) aio.Error!void {
    try self.uringlator.queue(len, work, cb, *@This(), self, queueCallback);
}

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode, cb: ?aio.Dynamic.CompletionCallback) aio.Error!aio.CompletionResult {
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

fn start(self: *@This(), id: u16, uop: *Operation.Union) !void {
    switch (uop.*) {
        // TODO: handle IOCP operations here
        else => {
            // perform non IOCP supported operation on a thread
            self.tpool.spawn(onThreadPosixExecutor, .{ self, id, uop }) catch return error.SystemResources;
        },
    }
}

fn cancelable(_: *@This(), _: u16, _: *Operation.Union) bool {
    return false;
}

fn completion(_: *@This(), _: u16, _: *Operation.Union) void {}
