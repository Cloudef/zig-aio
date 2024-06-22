//! Coroutines API
//! This combines the basic aio API with coroutines
//! Coroutines will yield when IO is being performed and get waken up when the IO is complete
//! This allows you to write asynchronous IO tasks with ease

const std = @import("std");
const aio = @import("aio");
const Fiber = @import("coro/zefi.zig");

const root = @import("root");
pub const options: Options = if (@hasDecl(root, "coro_options")) root.coro_options else .{};

pub const Options = struct {
    /// Enable coroutine debug logs and tracing
    debug: bool = false,
    /// Default io queue entries
    io_queue_entries: u16 = 4096,
    /// Default stack size for coroutines
    stack_size: usize = 1.049e+6, // 1 MiB
    /// Default handler for errors for !void coroutines
    error_handler: fn (err: anyerror) void = defaultErrorHandler,
};

fn defaultErrorHandler(err: anyerror) void {
    std.debug.print("error: {s}\n", .{@errorName(err)});
    if (@errorReturnTrace()) |trace| {
        std.debug.dumpStackTrace(trace.*);
    }
}

fn debug(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) {
        std.debug.print("coro: " ++ fmt ++ "\n", args);
    } else {
        if (comptime !options.debug) return;
        const log = std.log.scoped(.coro);
        log.debug(fmt, args);
    }
}

pub const io = struct {
    inline fn privateComplete(operations: anytype, yield_state: YieldState) aio.Error!u16 {
        if (Fiber.current()) |fiber| {
            var task: *TaskState = @ptrFromInt(fiber.getUserDataPtr().*);

            const State = struct { old_err: ?*anyerror, old_id: ?*aio.Id, id: aio.Id, err: anyerror };
            var state: [operations.len]State = undefined;
            var work = struct { ops: @TypeOf(operations) }{ .ops = operations };
            inline for (&work.ops, &state) |*op, *s| {
                op.counter = .{ .dec = &task.io_counter };
                if (@hasDecl(@TypeOf(op.*), "out_id")) {
                    s.old_id = op.out_id;
                    op.out_id = &s.id;
                } else {
                    s.old_id = null;
                }
                s.old_err = op.out_error;
                op.out_error = @ptrCast(&s.err);
            }

            try task.io.queue(work.ops);
            task.io_counter = operations.len;
            privateYield(yield_state);

            if (task.io_counter > 0) {
                // woken up for io cancelation
                var cancels: [operations.len]aio.Cancel = undefined;
                inline for (&cancels, &state) |*op, *s| op.* = .{ .id = s.id };
                try task.io.queue(cancels);
                privateYield(.io_cancel);
            }

            var num_errors: u16 = 0;
            inline for (&state) |*s| {
                num_errors += @intFromBool(s.err != error.Success);
                if (s.old_err) |p| p.* = s.err;
                if (s.old_id) |p| p.* = s.id;
            }
            return num_errors;
        } else {
            return aio.complete(operations);
        }
    }

    /// Completes a list of operations immediately, blocks the coroutine until complete
    /// The IO operations can be cancelled by calling `wakeup`
    /// For error handling you must check the `out_error` field in the operation
    /// Returns the number of errors occured, 0 if there were no errors
    pub inline fn complete(operations: anytype) aio.Error!u16 {
        return privateComplete(operations, .io);
    }

    /// Completes a list of operations immediately, blocks until complete
    /// The IO operations can be cancelled by calling `wakeupFromIo`, or doing `aio.Cancel`
    /// Returns `error.SomeOperationFailed` if any operation failed
    pub inline fn multi(operations: anytype) (aio.Error || error{SomeOperationFailed})!void {
        if (try complete(operations) > 0) return error.SomeOperationFailed;
    }

    /// Completes a single operation immediately, blocks the coroutine until complete
    /// The IO operation can be cancelled by calling `wakeupFromIo`, or doing `aio.Cancel`
    pub inline fn single(operation: anytype) (aio.Error || @TypeOf(operation).Error)!void {
        var op: @TypeOf(operation) = operation;
        var err: @TypeOf(operation).Error = error.Success;
        op.out_error = &err;
        _ = try complete(.{op});
        if (err != error.Success) return err;
    }
};

/// Yields current task, can only be called from inside a task
pub inline fn yield(state: anytype) void {
    privateYield(@enumFromInt(std.meta.fields(YieldState).len + @intFromEnum(state)));
}

pub const WakeupMode = enum { no_wait, wait };

/// Wakeups a task from a yielded state, no-op if `state` does not match the current yielding state
/// `mode` lets you select whether to `wait` for the state to change before trying to wake up or not
pub inline fn wakeupFromState(task: Task, state: anytype, mode: WakeupMode) void {
    const node: *Scheduler.TaskNode = @ptrCast(task);
    privateWakeup(&node.data, @enumFromInt(std.meta.fields(YieldState).len + @intFromEnum(state)), mode);
}

/// Wakeups a task from IO by canceling the current IO operations for that task
pub inline fn wakeupFromIo(task: Task) void {
    const node: *Scheduler.TaskNode = @ptrCast(task);
    privateWakeup(&node.data, .io, .no_wait);
}

/// Wakeups a task regardless of the current yielding state
pub inline fn wakeup(task: Task) void {
    const node: *Scheduler.TaskNode = @ptrCast(task);
    // do not wakeup from io_cancel state as that can potentially lead to memory corruption
    if (node.data.yield_state == .io_cancel) return;
    // ditto for io_waiting_thread
    if (node.data.yield_state == .io_waiting_thread) return;
    privateWakeup(&node.data, node.data.yield_state, .no_wait);
}

const YieldState = enum(u8) {
    not_yielding,
    io,
    io_waiting_thread, // cannot be canceled
    io_cancel,
    _, // fields after are reserved for custom use

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (@intFromEnum(self) < std.meta.fields(@This()).len) {
            try writer.writeAll(@tagName(self));
        } else {
            try writer.print("custom {}", .{@intFromEnum(self)});
        }
    }
};

inline fn privateYield(state: YieldState) void {
    if (Fiber.current()) |fiber| {
        var task: *TaskState = @ptrFromInt(fiber.getUserDataPtr().*);
        std.debug.assert(task.yield_state == .not_yielding);
        task.yield_state = state;
        debug("yielding: {}", .{task});
        Fiber.yield();
    } else {
        unreachable; // yield can only be used from a task
    }
}

inline fn privateWakeup(task: *TaskState, state: YieldState, mode: WakeupMode) void {
    if (mode == .wait) {
        debug("waiting to wake up: {} when it yields {}", .{ task, mode });
        while (task.yield_state != state and !task.marked_for_reap) {
            // TODO: Could perhaps be better than a timer
            io.single(aio.Timeout{ .ns = 16 * std.time.ns_per_ms }) catch continue;
        }
    }
    if (task.marked_for_reap) return;
    if (task.yield_state != state) return;
    debug("waking up: {}", .{task});
    task.yield_state = .not_yielding;
    task.fiber.switchTo();
}

const TaskState = struct {
    fiber: *Fiber,
    stack: ?Fiber.Stack = null,
    marked_for_reap: bool = false,
    io: *aio.Dynamic,
    io_counter: u16 = 0,
    yield_state: YieldState = .not_yielding,

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.io_counter > 0) {
            try writer.print("{x}: {}, {} ops left", .{ @intFromPtr(self.fiber), self.yield_state, self.io_counter });
        } else {
            try writer.print("{x}: {}", .{ @intFromPtr(self.fiber), self.yield_state });
        }
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        // we can only safely deinit the task when it is not doing IO
        // otherwise for example io_uring might write to invalid memory address
        std.debug.assert(self.yield_state != .io and self.yield_state != .io_waiting_thread and self.yield_state != .io_cancel);
        if (self.stack) |stack| allocator.free(stack);
        self.* = undefined;
    }
};

pub const Task = *align(@alignOf(Scheduler.TaskNode)) anyopaque;

/// Runtime for asynchronous IO tasks
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    io: aio.Dynamic,
    tasks: std.DoublyLinkedList(TaskState) = .{},
    pending_for_reap: bool = false,

    const TaskNode = std.DoublyLinkedList(TaskState).Node;

    pub const InitOptions = struct {
        /// This is a hint, the implementation makes the final call
        io_queue_entries: u16 = options.io_queue_entries,
    };

    pub fn init(allocator: std.mem.Allocator, opts: InitOptions) !@This() {
        return .{
            .allocator = allocator,
            .io = try aio.Dynamic.init(allocator, opts.io_queue_entries),
        };
    }

    pub fn reapAll(self: *@This()) void {
        var maybe_node = self.tasks.first;
        while (maybe_node) |node| {
            node.data.marked_for_reap = true;
            maybe_node = node.next;
        }
        self.pending_for_reap = true;
    }

    fn privateReap(self: *@This(), node: *TaskNode) bool {
        if (node.data.yield_state == .io or node.data.yield_state == .io_cancel) {
            debug("task is pending on io, reaping later: {}", .{node.data});
            if (node.data.yield_state == .io) privateWakeup(&node.data, .io, .no_wait); // cancel io
            node.data.marked_for_reap = true;
            self.pending_for_reap = true;
            return false; // still pending
        }
        debug("reaping: {}", .{node.data});
        self.tasks.remove(node);
        node.data.deinit(self.allocator);
        self.allocator.destroy(node);
        return true;
    }

    pub fn reap(self: *@This(), task: Task) void {
        const node: *TaskNode = @ptrCast(task);
        _ = self.privateReap(node);
    }

    pub fn deinit(self: *@This()) void {
        // destroy io backend first to make sure we can destroy the tasks safely
        self.io.deinit(self.allocator);
        while (self.tasks.pop()) |node| {
            // modify the yield state to avoid state consistency assert in deinit
            // it's okay to deinit now since the io backend is dead
            node.data.yield_state = .not_yielding;
            node.data.deinit(self.allocator);
            self.allocator.destroy(node);
        }
        self.* = undefined;
    }

    inline fn entrypoint(self: *@This(), comptime func: anytype, args: anytype) void {
        if (@typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?) == .ErrorUnion) {
            @call(.auto, func, args) catch |err| options.error_handler(err);
        } else {
            @call(.auto, func, args);
        }
        var task: *TaskState = @ptrFromInt(Fiber.current().?.getUserDataPtr().*);
        task.marked_for_reap = true;
        self.pending_for_reap = true;
        debug("finished: {}", .{task});
    }

    pub const SpawnError = error{OutOfMemory} || Fiber.Error;

    pub const SpawnOptions = struct {
        stack: union(enum) {
            unmanaged: Fiber.Stack,
            managed: usize,
        } = .{ .managed = options.stack_size },
    };

    /// Spawns a new task, the task may do local IO operations which will not block the whole process using the `io` namespace functions
    pub fn spawn(self: *@This(), comptime func: anytype, args: anytype, opts: SpawnOptions) SpawnError!Task {
        const stack = switch (opts.stack) {
            .unmanaged => |buf| buf,
            .managed => |sz| try self.allocator.alignedAlloc(u8, Fiber.stack_alignment, sz),
        };
        errdefer if (opts.stack == .managed) self.allocator.free(stack);
        var fiber = try Fiber.init(stack, 0, entrypoint, .{ self, func, args });
        const node = try self.allocator.create(TaskNode);
        errdefer self.allocator.destroy(node);
        node.* = .{ .data = .{
            .fiber = fiber,
            .stack = if (opts.stack == .managed) stack else null,
            .io = &self.io,
        } };
        fiber.getUserDataPtr().* = @intFromPtr(&node.data);
        self.tasks.append(node);
        errdefer self.tasks.remove(node);
        debug("spawned: {}", .{node.data});
        fiber.switchTo();
        return node;
    }

    fn tickIo(self: *@This(), mode: aio.Dynamic.CompletionMode) !void {
        const res = try self.io.complete(mode);
        if (res.num_completed > 0) {
            var maybe_node = self.tasks.first;
            while (maybe_node) |node| {
                const next = node.next;
                switch (node.data.yield_state) {
                    .io, .io_waiting_thread, .io_cancel => if (node.data.io_counter == 0) {
                        privateWakeup(&node.data, node.data.yield_state, .no_wait);
                    },
                    else => {},
                }
                maybe_node = next;
            }
        }
    }

    /// Processes pending IO and reaps dead tasks
    pub fn tick(self: *@This(), mode: aio.Dynamic.CompletionMode) !void {
        try self.tickIo(mode);
        if (self.pending_for_reap) {
            var num_unreaped: usize = 0;
            var maybe_node = self.tasks.first;
            while (maybe_node) |node| {
                const next = node.next;
                if (node.data.marked_for_reap) {
                    if (!self.privateReap(node)) {
                        num_unreaped += 1;
                    }
                }
                maybe_node = next;
            }
            if (num_unreaped == 0) {
                self.pending_for_reap = false;
            }
        }
    }

    /// Run until all tasks are dead
    pub fn run(self: *@This()) !void {
        while (self.tasks.len > 0) try self.tick(.blocking);
    }
};

/// Synchronizes blocking tasks on a thread pool
pub const ThreadPool = struct {
    pool: std.Thread.Pool = undefined,

    /// Spin up the pool, `allocator` is used to allocate the tasks
    /// If `num_jobs` is zero, the thread count for the current CPU is used
    pub fn start(self: *@This(), allocator: std.mem.Allocator, num_jobs: u32) !void {
        self.* = .{ .pool = .{ .allocator = undefined, .threads = undefined } };
        try self.pool.init(.{ .allocator = allocator, .n_jobs = if (num_jobs == 0) null else num_jobs });
    }

    pub fn deinit(self: *@This()) void {
        self.pool.deinit();
        self.* = undefined;
    }

    inline fn entrypoint(source: *aio.EventSource, comptime func: anytype, ret: anytype, args: anytype) void {
        ret.* = @call(.auto, func, args);
        source.notify();
    }

    const Error = error{SomeOperationFailed} || aio.Error || aio.EventSource.Error || aio.WaitEventSource.Error;

    fn ReturnType(comptime Func: type) type {
        const base = @typeInfo(Func).Fn.return_type.?;
        return switch (@typeInfo(base)) {
            .ErrorUnion => |eu| (Error || eu.error_set)!eu.payload,
            else => Error!base,
        };
    }

    /// Yield until `func` finishes on another thread
    pub fn yieldForCompletition(self: *@This(), func: anytype, args: anytype) ReturnType(@TypeOf(func)) {
        var ret: @typeInfo(@TypeOf(func)).Fn.return_type.? = undefined;
        var source = try aio.EventSource.init();
        errdefer source.deinit();
        try self.pool.spawn(entrypoint, .{ &source, func, &ret, args });
        var wait_err: aio.WaitEventSource.Error = error.Success;
        if (try io.privateComplete(.{
            aio.WaitEventSource{ .source = source, .link = .soft, .out_error = &wait_err },
            aio.CloseEventSource{ .source = source },
        }, .io_waiting_thread) > 0) {
            if (wait_err != error.Success) {
                // it's possible to end up here if aio implementation ran out of resources
                // in case of io_uring the application managed to fill up the submission queue
                // normally this should not happen, but as to not crash the program do a blocking wait
                source.wait();
            }
            // close manually
            source.deinit();
        }
        return ret;
    }
};

test "ThreadPool" {
    const Test = struct {
        const Yield = enum {
            task2_free,
        };

        fn task1(task1_done: *bool) void {
            yield(Yield.task2_free);
            task1_done.* = true;
        }

        fn blocking() u32 {
            std.time.sleep(1 * std.time.ns_per_s);
            return 69;
        }

        fn task2(t1: Task, pool: *ThreadPool, task1_done: *bool) !void {
            const ret = try pool.yieldForCompletition(blocking, .{});
            try std.testing.expectEqual(69, ret);
            try std.testing.expectEqual(task1_done.*, false);
            wakeupFromState(t1, Yield.task2_free, .no_wait);
            try std.testing.expectEqual(task1_done.*, true);
        }
    };
    var scheduler = try Scheduler.init(std.testing.allocator, .{});
    defer scheduler.deinit();
    var pool: ThreadPool = .{};
    try pool.start(std.testing.allocator, 0);
    defer pool.deinit();
    var task1_done: bool = false;
    const task1 = try scheduler.spawn(Test.task1, .{&task1_done}, .{});
    _ = try scheduler.spawn(Test.task2, .{ task1, &pool, &task1_done }, .{});
    try scheduler.run();
}
