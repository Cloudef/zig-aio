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

            try task.scheduler.io.queue(work.ops);
            task.io_counter = operations.len;
            task.scheduler.tasks_waiting_io.append(&task.io_link);
            defer task.scheduler.tasks_waiting_io.remove(&task.io_link);
            privateYield(yield_state);

            if (task.io_counter > 0) {
                // woken up for io cancelation
                var cancels: [operations.len]aio.Cancel = undefined;
                inline for (&cancels, &state) |*op, *s| op.* = .{ .id = s.id };
                try task.scheduler.io.queue(cancels);
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
    const node: *Scheduler.Tasks.Node = @ptrCast(task);
    node.data.cast().wakeup(@enumFromInt(std.meta.fields(YieldState).len + @intFromEnum(state)), mode);
}

/// Wakeups a task from IO by canceling the current IO operations for that task
pub inline fn wakeupFromIo(task: Task) void {
    const node: *Scheduler.Tasks.Node = @ptrCast(task);
    node.data.cast().wakeup(.io, .no_wait);
}

/// Wakeups a task regardless of the current yielding state
pub inline fn wakeup(task: Task) void {
    const node: *Scheduler.Tasks.Node = @ptrCast(task);
    const state = node.data.cast();
    // do not wakeup from io_cancel state as that can potentially lead to memory corruption
    if (state.yield_state == .io_cancel) return;
    // ditto for io_waiting_thread
    if (state.yield_state == .io_waiting_thread) return;
    state.wakeup(state.yield_state, .no_wait);
}

const YieldState = enum(u8) {
    not_yielding, // task is running
    waiting_for_yield, // waiting for another task to change yield state
    io, // waiting for io
    io_waiting_thread, // cannot be canceled
    io_cancel, // cannot be canceled
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
        // wake up waiters
        while (task.waiters.popFirst()) |node| {
            node.data.cast().wakeup(.waiting_for_yield, .no_wait);
        }
        debug("yielding: {}", .{task});
        Fiber.yield();
    } else {
        unreachable; // yield can only be used from a task
    }
}

const TaskState = struct {
    const Waiters = std.SinglyLinkedList(Link(TaskState, "waiter_link", .single));
    fiber: *Fiber,
    stack: ?Fiber.Stack = null,
    marked_for_reap: bool = false,
    yield_state: YieldState = .not_yielding,
    scheduler: *Scheduler,
    io_counter: u16 = 0,
    waiters: Waiters = .{},
    waiter_link: Waiters.Node = .{ .data = .{} },
    io_link: Scheduler.IoTasks.Node = .{ .data = .{} },
    link: Scheduler.Tasks.Node = .{ .data = .{} },

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        if (self.io_counter > 0) {
            try writer.print("{x}: {}, {} ops left", .{ @intFromPtr(self.fiber), self.yield_state, self.io_counter });
        } else {
            try writer.print("{x}: {}", .{ @intFromPtr(self.fiber), self.yield_state });
        }
    }

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        // we can only safely deinit the task when it is not doing IO
        // otherwise for example io_uring might write tok a invalid memory address
        debug("deinit: {}", .{self});
        std.debug.assert(self.isReapable());
        if (self.stack) |stack| allocator.free(stack);
        // stack is now gone, doing anything after this with TaskState is ub
    }

    inline fn wakeup(self: *TaskState, state: YieldState, mode: WakeupMode) void {
        if (mode == .wait) {
            debug("waiting to wake up: {} when it yields {}", .{ self, mode });
            while (self.yield_state != state and !self.marked_for_reap) {
                if (Fiber.current()) |fiber| {
                    var task: *TaskState = @ptrFromInt(fiber.getUserDataPtr().*);
                    self.waiters.prepend(&task.waiter_link);
                    privateYield(.waiting_for_yield);
                } else {
                    // Not a task, spin up the CPU
                    io.single(aio.Timeout{ .ns = 16 * std.time.ns_per_ms }) catch continue;
                }
            }
        }
        if (self.marked_for_reap) return;
        if (self.yield_state != state) return;
        debug("waking up: {}", .{self});
        self.yield_state = .not_yielding;
        self.fiber.switchTo();
    }

    inline fn isReapable(self: *TaskState) bool {
        return switch (self.yield_state) {
            .io, .io_waiting_thread, .io_cancel => false,
            else => true,
        };
    }
};

pub const Task = *Scheduler.Tasks.Node;

/// Runtime for asynchronous IO tasks
pub const Scheduler = struct {
    const Tasks = std.DoublyLinkedList(Link(TaskState, "link", .double));
    const IoTasks = std.DoublyLinkedList(Link(TaskState, "io_link", .double));
    allocator: std.mem.Allocator,
    io: aio.Dynamic,
    tasks: Tasks = .{},
    tasks_pending_reap: Tasks = .{},
    tasks_waiting_io: IoTasks = .{},

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
        while (self.tasks.pop()) |node| {
            node.data.cast().marked_for_reap = true;
            self.privateReap(node);
        }
    }

    fn privateReap(self: *@This(), node: *Tasks.Node) void {
        var task = node.data.cast();
        if (!task.isReapable()) {
            if (task.yield_state == .io) {
                debug("task is pending on io, reaping later: {}", .{task});
                task.wakeup(.io, .no_wait); // cancel io
            }
            task.marked_for_reap = true;
            self.tasks_pending_reap.append(node);
            return; // still pending
        }
        if (task.marked_for_reap) self.tasks_pending_reap.remove(node);
        task.deinit(self.allocator);
    }

    pub fn reap(self: *@This(), node: Task) void {
        self.tasks.remove(@ptrCast(node));
        self.privateReap(@ptrCast(node));
    }

    pub fn deinit(self: *@This()) void {
        // destroy io backend first to make sure we can destroy the tasks safely
        self.io.deinit(self.allocator);
        inline for (&.{ &self.tasks, &self.tasks_pending_reap }) |list| {
            while (list.pop()) |node| {
                var task = node.data.cast();
                // modify the yield state to avoid state consistency assert in deinit
                // it's okay to deinit now since the io backend is dead
                // if using thread pool, it is error to deinit scheduler before thread
                // pool is deinited, so we don't have to wait for those tasks either
                task.yield_state = .not_yielding;
                task.deinit(self.allocator);
            }
        }
        self.* = undefined;
    }

    inline fn entrypoint(self: *@This(), stack: Fiber.Stack, comptime func: anytype, args: anytype) void {
        var state: TaskState = .{
            .fiber = Fiber.current().?,
            .scheduler = self,
            .stack = stack,
        };
        state.fiber.getUserDataPtr().* = @intFromPtr(&state);
        self.tasks.append(&state.link);
        debug("spawned: {}", .{state});

        if (@typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?) == .ErrorUnion) {
            @call(.auto, func, args) catch |err| options.error_handler(err);
        } else {
            @call(.auto, func, args);
        }

        debug("finished: {}", .{state});
        self.tasks.remove(&state.link);
        if (state.stack) |_| {
            // stack is managed, it needs to be cleaned outside
            state.marked_for_reap = true;
            self.tasks_pending_reap.append(&state.link);
        }
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
        var fiber = try Fiber.init(stack, 0, entrypoint, .{ self, stack, func, args });
        fiber.switchTo();
        return self.tasks.last.?;
    }

    fn tickIo(self: *@This(), mode: aio.Dynamic.CompletionMode) !void {
        const res = try self.io.complete(mode);
        if (res.num_completed > 0) {
            var maybe_node = self.tasks_waiting_io.first;
            while (maybe_node) |node| {
                const next = node.next;
                var task = node.data.cast();
                switch (task.yield_state) {
                    .io, .io_waiting_thread, .io_cancel => if (task.io_counter == 0) {
                        task.wakeup(task.yield_state, .no_wait);
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
        var maybe_node = self.tasks_pending_reap.first;
        while (maybe_node) |node| {
            const next = node.next;
            self.privateReap(node);
            maybe_node = next;
        }
    }

    /// Run until all tasks are dead
    pub fn run(self: *@This()) !void {
        while (self.tasks.len + self.tasks_pending_reap.len > 0) {
            try self.tick(.blocking);
        }
    }
};

/// Synchronizes blocking tasks on a thread pool
pub const ThreadPool = struct {
    pool: std.Thread.Pool = undefined,
    source: aio.EventSource = undefined,

    /// Spin up the pool, `allocator` is used to allocate the tasks
    /// If `num_jobs` is zero, the thread count for the current CPU is used
    pub fn start(self: *@This(), allocator: std.mem.Allocator, num_jobs: u32) !void {
        self.* = .{ .pool = .{ .allocator = undefined, .threads = undefined }, .source = try aio.EventSource.init() };
        errdefer self.source.deinit();
        try self.pool.init(.{ .allocator = allocator, .n_jobs = if (num_jobs == 0) null else num_jobs });
    }

    pub fn deinit(self: *@This()) void {
        self.pool.deinit();
        self.source.deinit();
        self.* = undefined;
    }

    const Sync = struct {
        source: aio.EventSource,
        completed: bool = false,
    };

    inline fn entrypoint(sync: *Sync, comptime func: anytype, ret: anytype, args: anytype) void {
        ret.* = @call(.auto, func, args);
        sync.completed = true;
        sync.source.notify();
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
        var sync: Sync = .{ .source = self.source };
        var ret: @typeInfo(@TypeOf(func)).Fn.return_type.? = undefined;
        try self.pool.spawn(entrypoint, .{ &sync, func, &ret, args });
        var wait_err: aio.WaitEventSource.Error = error.Success;
        while (!sync.completed) {
            if (try io.privateComplete(.{
                aio.WaitEventSource{ .source = sync.source, .link = .soft, .out_error = &wait_err },
            }, .io_waiting_thread) > 0) {
                // it's possible to end up here if aio implementation ran out of resources
                // in case of io_uring the application managed to fill up the submission queue
                // normally this should not happen, but as to not crash the program do a blocking wait
                sync.source.wait();
            }
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

        fn task3(pool: *ThreadPool) !void {
            const ret = try pool.yieldForCompletition(blocking, .{});
            try std.testing.expectEqual(69, ret);
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
    for (0..10) |_| _ = try scheduler.spawn(Test.task3, .{&pool}, .{});
    try scheduler.run();
}

fn Link(comptime T: type, comptime field: []const u8, comptime container: enum { single, double }) type {
    return struct {
        pub fn format(self: *@This(), comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
            return self.cast().format(self, fmt, opts, writer);
        }

        inline fn cast(self: *@This()) *T {
            switch (container) {
                .single => {
                    const node: *std.SinglyLinkedList(@This()).Node = @alignCast(@fieldParentPtr("data", self));
                    return @fieldParentPtr(field, node);
                },
                .double => {
                    const node: *std.DoublyLinkedList(@This()).Node = @alignCast(@fieldParentPtr("data", self));
                    return @fieldParentPtr(field, node);
                },
            }
        }
    };
}
