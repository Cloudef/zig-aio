//! Coroutines API
//! This combines the basic aio API with coroutines
//! Coroutines will yield when IO is being performed and get waken up when the IO is complete
//! This allows you to write asynchronous IO tasks with ease

const std = @import("std");
const aio = @import("aio");
const Fiber = @import("coro/zefi.zig");

const root = @import("root");
pub const options: Options = if (@hasDecl(root, "aio_coro_options")) root.aio_coro_options else .{};

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
    if (comptime !options.debug) return;
    const log = std.log.scoped(.coro);
    log.debug(fmt, args);
}

pub const io = struct {
    /// Completes a list of operations immediately, blocks the coroutine until complete
    /// The IO operations can be cancelled by calling `wakeup`
    /// For error handling you must check the `out_error` field in the operation
    /// Returns the number of errors occured, 0 if there were no errors
    pub inline fn complete(operations: anytype) aio.QueueError!u16 {
        if (Fiber.current()) |fiber| {
            var task: *Scheduler.TaskState = @ptrFromInt(fiber.getUserDataPtr().*);

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
            privateYield(.io);

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
            unreachable; // this io function is only meant to be used in coroutines!
        }
    }

    /// Completes a list of operations immediately, blocks until complete
    /// The IO operations can be cancelled by calling `wakeupFromIo`, or doing `aio.Cancel`
    /// Returns `error.SomeOperationFailed` if any operation failed
    pub inline fn multi(operations: anytype) (aio.QueueError || error{SomeOperationFailed})!void {
        if (try complete(operations) > 0) return error.SomeOperationFailed;
    }

    /// Completes a single operation immediately, blocks the coroutine until complete
    /// The IO operation can be cancelled by calling `wakeupFromIo`, or doing `aio.Cancel`
    pub fn single(operation: anytype) (aio.QueueError || aio.OperationError)!void {
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

/// Wakeups a task from a yielded state, no-op if `state` does not match the current yielding state
pub inline fn wakeupFromState(task: Scheduler.Task, state: anytype) void {
    const node: *Scheduler.TaskNode = @ptrCast(task);
    if (node.data.marked_for_reap) return;
    privateWakeup(&node.data, @enumFromInt(std.meta.fields(YieldState).len + @intFromEnum(state)));
}

/// Wakeups a task from IO by canceling the current IO operations for that task
pub inline fn wakeupFromIo(task: Scheduler.Task) void {
    const node: *Scheduler.TaskNode = @ptrCast(task);
    if (node.data.marked_for_reap) return;
    privateWakeup(&node.data, .io);
}

/// Wakeups a task regardless of the current yielding state
pub inline fn wakeup(task: Scheduler.Task) void {
    const node: *Scheduler.TaskNode = @ptrCast(task);
    if (node.data.marked_for_reap) return;
    // do not wakeup from io_cancel state as that can potentially lead to memory corruption
    if (node.data.yield_state == .io_cancel) return;
    privateWakeup(&node.data, node.data.yield_state);
}

const YieldState = enum(u8) {
    not_yielding,
    io,
    io_cancel,
    _, // fields after are reserved for custom use
};

inline fn privateYield(state: YieldState) void {
    if (Fiber.current()) |fiber| {
        var task: *Scheduler.TaskState = @ptrFromInt(fiber.getUserDataPtr().*);
        std.debug.assert(task.yield_state == .not_yielding);
        task.yield_state = state;
        debug("yielding: {}", .{task});
        Fiber.yield();
    } else {
        unreachable; // yield is only meant to be used in coroutines!
    }
}

inline fn privateWakeup(task: *Scheduler.TaskState, state: YieldState) void {
    if (task.yield_state != state) return;
    debug("waking up from yield: {}", .{task});
    task.yield_state = .not_yielding;
    task.fiber.switchTo();
}

/// Runtime for asynchronous IO tasks
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    io: aio.Dynamic,
    tasks: std.DoublyLinkedList(TaskState) = .{},
    pending_for_reap: bool = false,

    const TaskState = struct {
        fiber: *Fiber,
        stack: ?Fiber.Stack = null,
        marked_for_reap: bool = false,
        io: *aio.Dynamic,
        io_counter: u16 = 0,
        yield_state: YieldState = .not_yielding,

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            if (self.io_counter > 0) {
                try writer.print("{x}: {s}, {} ops left", .{ @intFromPtr(self.fiber), @tagName(self.yield_state), self.io_counter });
            } else {
                try writer.print("{x}: {s}", .{ @intFromPtr(self.fiber), @tagName(self.yield_state) });
            }
        }

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (Fiber.current()) |_| unreachable; // do not call deinit from a task
            // we can only safely deinit the task when it is not doing IO
            // otherwise for example io_uring might write to invalid memory address
            std.debug.assert(self.yield_state != .io and self.yield_state != .io_cancel);
            if (self.stack) |stack| allocator.free(stack);
            self.* = undefined;
        }
    };

    const TaskNode = std.DoublyLinkedList(TaskState).Node;
    pub const Task = *align(@alignOf(TaskNode)) anyopaque;

    pub const InitOptions = struct {
        /// This is a hint, the implementation makes the final call
        io_queue_entries: u16 = options.io_queue_entries,
    };

    pub fn init(allocator: std.mem.Allocator, opts: InitOptions) !@This() {
        if (Fiber.current()) |_| unreachable; // do not call init from a task
        return .{
            .allocator = allocator,
            .io = try aio.Dynamic.init(allocator, opts.io_queue_entries),
        };
    }

    pub fn reapAll(self: *@This()) void {
        if (Fiber.current()) |_| unreachable; // do not call reapAll from a task
        var maybe_node = self.tasks.first;
        while (maybe_node) |node| {
            node.data.marked_for_reap = true;
            maybe_node = node.next;
        }
        self.pending_for_reap = true;
    }

    fn privateReap(self: *@This(), node: *TaskNode) bool {
        if (Fiber.current()) |_| unreachable; // do not call reap from a task
        if (node.data.yield_state == .io or node.data.yield_state == .io_cancel) {
            debug("task is pending on io, reaping later: {}", .{node.data});
            if (node.data.yield_state == .io) privateWakeup(&node.data, .io); // cancel io
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
        if (Fiber.current()) |_| unreachable; // do not call deinit from a task
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

    fn entrypoint(self: *@This(), comptime func: anytype, args: anytype) void {
        if (@typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?) == .ErrorUnion) {
            @call(.auto, func, args) catch |err| options.error_handler(err);
        } else {
            @call(.auto, func, args);
        }
        var task: *Scheduler.TaskState = @ptrFromInt(Fiber.current().?.getUserDataPtr().*);
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
        if (Fiber.current()) |_| unreachable; // do not call spawn from a task
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
                    .io, .io_cancel => if (node.data.io_counter == 0) {
                        privateWakeup(&node.data, node.data.yield_state);
                    },
                    else => {},
                }
                maybe_node = next;
            }
        }
    }

    /// Processes pending IO and reaps dead tasks
    pub fn tick(self: *@This(), mode: aio.Dynamic.CompletionMode) !void {
        if (Fiber.current()) |_| unreachable; // do not call tick from a task
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
