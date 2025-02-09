//! Coroutines API
//! This combines the basic aio API with coroutines
//! Coroutines will yield when IO is being performed and get waken up when the IO is complete
//! This allows you to write asynchronous IO tasks with ease

const std = @import("std");
const aio = @import("aio");
const Operation = aio.Operation;
const build_options = @import("build_options");

const root = @import("root");
pub const options: Options = if (@hasDecl(root, "coro_options")) root.coro_options else .{};

pub const Options = struct {
    /// Enable coroutine debug logs and tracing
    debug: bool = build_options.debug,
    /// Default io queue entries
    io_queue_entries: u16 = 4096,
    /// Default stack size for coroutines
    stack_size: usize = 1_048_576, // 1 MiB
};

pub const Scheduler = @import("coro/Scheduler.zig");
pub const ThreadPool = @import("coro/ThreadPool.zig");
pub const Task = @import("coro/Task.zig");

const sync = @import("coro/sync.zig");
pub const Semaphore = sync.Semaphore;
pub const ResetEvent = sync.ResetEvent;

// Aliases
pub const current = Task.current;
pub const yield = Task.yield;
pub const setCancelable = Task.setCancelable;

/// Nonblocking IO (on a task)
pub const io = struct {
    pub const Error = aio.Error || error{Canceled};

    /// Completes a list of operations immediately, blocks the coroutine until complete
    /// The IO operations can be cancelled by calling `wakeup`
    /// For error handling you must check the `out_error` field in the operation
    /// Returns the number of errors occured, 0 if there were no errors
    pub inline fn complete(pairs: anytype) Error!u16 {
        return @import("coro/io.zig").do(pairs, .io);
    }

    /// Completes a list of operations immediately, blocks until complete
    /// The IO operations can be cancelled by calling `wakeupFromIo`, or doing `aio.Cancel`
    /// Returns `error.SomeOperationFailed` if any operation failed
    pub inline fn multi(pairs: anytype) (Error || error{SomeOperationFailed})!void {
        if (try complete(pairs) > 0) return error.SomeOperationFailed;
    }

    /// Completes a single operation immediately, blocks the coroutine until complete
    /// The IO operation can be cancelled by calling `wakeupFromIo`, or doing `aio.Cancel`
    pub inline fn single(comptime op_type: Operation, values: Operation.map.getAssertContains(op_type)) (Error || @TypeOf(values).Error)!void {
        var cpy: @TypeOf(values) = values;
        var err: @TypeOf(values).Error = error.Success;
        cpy.out_error = &err;
        if (try complete(.{aio.op(op_type, cpy, .unlinked)}) > 0) return err;
    }

    /// Acquire a buffer ring from the backend
    /// Backend can fill the buffers in zero-copy fashion avoiding context switches
    /// If backend runs out of buffers operations will fail with `error.SystemResources`
    pub fn acquireBufferRing(buffers: []const []u8, writers: []?aio.Id) error{ OutOfMemory, Unexpected }!aio.BufferRingId {
        if (current()) |task| {
            return task.frame.scheduler.io.acquireBufferRing(buffers, writers);
        } else {
            unreachable; // can only be called from a task
        }
    }

    /// Release buffer ring, the id is no longer valid
    /// It is an programming error to release a buffer ring while operations are still using it
    pub fn releaseBufferRing(id: aio.BufferRingId) void {
        if (current()) |task| {
            return task.frame.scheduler.io.releaseBufferRing(id);
        } else {
            unreachable; // can only be called from a task
        }
    }

    /// Release a single buffer inside a buffer ring
    /// This notifies the backend that the buffer can be reused
    pub fn releaseBuffer(id: aio.BufferRingId, bid: u16) void {
        if (current()) |task| {
            return task.frame.scheduler.io.releaseBuffer(id, bid);
        } else {
            unreachable; // can only be called from a task
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}
