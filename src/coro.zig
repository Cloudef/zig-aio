//! Coroutines API
//! This combines the basic aio API with coroutines
//! Coroutines will yield when IO is being performed and get waken up when the IO is complete
//! This allows you to write asynchronous IO tasks with ease

const std = @import("std");
const aio = @import("aio");

const root = @import("root");
pub const options: Options = if (@hasDecl(root, "coro_options")) root.coro_options else .{};

pub const Options = struct {
    /// Enable coroutine debug logs and tracing
    debug: bool = false,
    /// Default io queue entries
    io_queue_entries: u16 = 4096,
    /// Default stack size for coroutines
    stack_size: usize = 1.049e+6, // 1 MiB
};

pub const Scheduler = @import("coro/Scheduler.zig");
pub const ThreadPool = @import("coro/ThreadPool.zig");
pub const Task = @import("coro/Task.zig");

const Sync = @import("coro/Sync.zig");
pub const Semaphore = Sync.Semaphore;
pub const ResetEvent = Sync.ResetEvent;
pub const RwLock = Sync.RwLock;

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
    pub inline fn complete(operations: anytype) Error!u16 {
        const do = @import("coro/io.zig").do;
        return do(operations, .io);
    }

    /// Completes a list of operations immediately, blocks until complete
    /// The IO operations can be cancelled by calling `wakeupFromIo`, or doing `aio.Cancel`
    /// Returns `error.SomeOperationFailed` if any operation failed
    pub inline fn multi(operations: anytype) (Error || error{SomeOperationFailed})!void {
        if (try complete(operations) > 0) return error.SomeOperationFailed;
    }

    /// Completes a single operation immediately, blocks the coroutine until complete
    /// The IO operation can be cancelled by calling `wakeupFromIo`, or doing `aio.Cancel`
    pub inline fn single(operation: anytype) (Error || @TypeOf(operation).Error)!void {
        var op: @TypeOf(operation) = operation;
        var err: @TypeOf(operation).Error = error.Success;
        op.out_error = &err;
        if (try complete(.{op}) > 0) return err;
    }
};

test {
    std.testing.refAllDecls(@This());
}
