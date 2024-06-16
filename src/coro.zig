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
    pub inline fn batch(operations: anytype) aio.QueueError!u16 {
        if (Fiber.current()) |fiber| {
            var task: *Scheduler.TaskState = @ptrFromInt(fiber.getUserDataPtr().*);

            const State = struct { old_err: ?*anyerror, old_id: ?*aio.Id, id: aio.Id, err: anyerror };
            var state: [operations.len]State = undefined;
            var work = struct { ops: @TypeOf(operations) }{ .ops = operations };
            inline for (&work.ops, &state) |*op, *s| {
                op.counter = .{ .dec = &task.io_counter };
                s.old_id = op.out_id;
                op.out_id = &s.id;
                s.old_err = op.out_error;
                op.out_error = @ptrCast(&s.err);
            }

            try task.io.queue(work.ops);
            task.io_counter = operations.len;
            task.status = .doing_io;
            debug("yielding for io: {}", .{task});
            Fiber.yield();

            if (task.io_counter > 0) {
                // wakeup() was called, try cancel the io
                inline for (&state) |*s| try task.io.queue(aio.Cancel{ .id = s.id });
                task.status = .cancelling_io;
                debug("yielding for io cancellation: {}", .{task});
                Fiber.yield();
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
    /// The IO operations can be cancelled by calling `wakeup`
    /// Returns `error.SomeOperationFailed` if any operation failed
    pub inline fn multi(operations: anytype) (aio.QueueError || error{SomeOperationFailed})!void {
        if (try batch(operations) > 0) return error.SomeOperationFailed;
    }

    /// Completes a single operation immediately, blocks the coroutine until complete
    /// The IO operation can be cancelled by calling `wakeup`
    pub fn single(operation: anytype) (aio.QueueError || aio.OperationError)!void {
        if (Fiber.current()) |fiber| {
            var task: *Scheduler.TaskState = @ptrFromInt(fiber.getUserDataPtr().*);

            var op: @TypeOf(operation) = operation;
            var err: @TypeOf(op.out_error.?.*) = error.Success;
            var id: aio.Id = undefined;
            op.counter = .{ .dec = &task.io_counter };
            op.out_id = &id;
            op.out_error = &err;
            try task.io.queue(op);
            task.io_counter = 1;
            task.status = .doing_io;
            debug("yielding for io: {}", .{task});
            Fiber.yield();

            if (task.io_counter > 0) {
                // wakeup() was called, try cancel the io
                try task.io.queue(aio.Cancel{ .id = id });
                task.status = .cancelling_io;
                debug("yielding for io cancellation: {}", .{task});
                Fiber.yield();
            }

            if (err != error.Success) return err;
        } else {
            unreachable; // this io function is only meant to be used in coroutines!
        }
    }
};

/// Yields current task, can only be called from inside a task
pub inline fn yield() void {
    if (Fiber.current()) |fiber| {
        var task: *Scheduler.TaskState = @ptrFromInt(fiber.getUserDataPtr().*);
        if (task.status == .dead) unreachable; // race condition
        if (task.status == .yield) unreachable; // race condition
        task.status = .yield;
        debug("yielding: {}", .{task});
        Fiber.yield();
    } else {
        unreachable; // yield is only meant to be used in coroutines!
    }
}

/// Wakeups a task by either cancelling the io its doing or switching back to it from yielded state
pub inline fn wakeup(task: Scheduler.Task) void {
    const node: *Scheduler.TaskNode = @ptrCast(task);
    if (node.data.status == .dead) unreachable; // race condition
    if (node.data.status == .running) return; // already awake
    if (node.data.status == .cancelling_io) return; // can't wake up when cancelling
    debug("waking up from yield: {}", .{node.data});
    node.data.status = .running;
    node.data.fiber.switchTo();
}

/// Runtime for asynchronous IO tasks
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    io: aio.Dynamic,
    tasks: std.DoublyLinkedList(TaskState) = .{},
    num_dead: usize = 0,

    const TaskState = struct {
        fiber: *Fiber,
        status: enum {
            running,
            doing_io,
            cancelling_io,
            yield,
            dead,
        } = .running,
        stack: ?Fiber.Stack = null,
        io: *aio.Dynamic,
        io_counter: u16 = 0,

        pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            if (self.status == .doing_io) {
                try writer.print("{x}: {s}, {} ops left", .{ @intFromPtr(self.fiber), @tagName(self.status), self.io_counter });
            } else {
                try writer.print("{x}: {s}", .{ @intFromPtr(self.fiber), @tagName(self.status) });
            }
        }

        fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (Fiber.current()) |_| unreachable; // do not call deinit from a task
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
        while (self.tasks.pop()) |node| {
            debug("reaping: {}", .{node.data});
            node.data.deinit(self.allocator);
            self.allocator.destroy(node);
        }
    }

    pub fn reap(self: *@This(), task: Task) void {
        if (Fiber.current()) |_| unreachable; // do not call reap from a task
        const node: *TaskNode = @ptrCast(task);
        debug("reaping: {}", .{node.data});
        self.tasks.remove(node);
        node.data.deinit(self.allocator);
        self.allocator.destroy(node);
    }

    pub fn deinit(self: *@This()) void {
        if (Fiber.current()) |_| unreachable; // do not call deinit from a task
        self.reapAll();
        self.io.deinit(self.allocator);
        self.* = undefined;
    }

    fn entrypoint(self: *@This(), comptime func: anytype, args: anytype) void {
        if (@typeInfo(@typeInfo(@TypeOf(func)).Fn.return_type.?) == .ErrorUnion) {
            @call(.auto, func, args) catch |err| options.error_handler(err);
        } else {
            @call(.auto, func, args);
        }
        var task: *Scheduler.TaskState = @ptrFromInt(Fiber.current().?.getUserDataPtr().*);
        task.status = .dead;
        self.num_dead += 1;
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

    /// Processes pending IO and reaps dead tasks
    pub fn tick(self: *@This(), mode: aio.Dynamic.CompletionMode) !void {
        if (Fiber.current()) |_| unreachable; // do not call tick from a task
        const res = try self.io.complete(mode);
        if (res.num_completed > 0) {
            var maybe_node = self.tasks.first;
            while (maybe_node) |node| {
                const next = node.next;
                switch (node.data.status) {
                    .running, .dead, .yield => {},
                    .doing_io, .cancelling_io => if (node.data.io_counter == 0) {
                        debug("waking up from io: {}", .{node.data});
                        node.data.status = .running;
                        node.data.fiber.switchTo();
                    },
                }
                maybe_node = next;
            }
        }
        while (self.num_dead > 0) {
            var maybe_node = self.tasks.first;
            while (maybe_node) |node| {
                const next = node.next;
                switch (node.data.status) {
                    .running, .doing_io, .cancelling_io, .yield => {},
                    .dead => {
                        debug("reaping: {}", .{node.data});
                        node.data.deinit(self.allocator);
                        self.tasks.remove(node);
                        self.allocator.destroy(node);
                        self.num_dead -= 1;
                    },
                }
                maybe_node = next;
            }
        }
    }

    /// Run until all tasks are dead
    pub fn run(self: *@This()) !void {
        while (self.tasks.len > 0) try self.tick(.blocking);
    }
};
