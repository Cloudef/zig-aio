const std = @import("std");
const aio = @import("aio");
const Frame = @import("Frame.zig");
const Task = @import("Task.zig");
const options = @import("../coro.zig").options;

allocator: std.mem.Allocator,
io: aio.Dynamic,
io_ack: u8 = 0,
frames: Frame.List = .{},
num_complete: usize = 0,
state: enum { init, tear_down } = .init,

pub const InitOptions = struct {
    /// This is a hint, the implementation makes the final call
    io_queue_entries: u16 = options.io_queue_entries,
};

pub fn init(allocator: std.mem.Allocator, opts: InitOptions) aio.Error!@This() {
    var work = try aio.Dynamic.init(allocator, opts.io_queue_entries);
    work.queue_callback = ioQueue;
    work.completion_callback = ioCompletion;
    return .{ .allocator = allocator, .io = work };
}

pub fn deinit(self: *@This()) void {
    if (self.state == .tear_down) self.state = .init;
    self.run(.cancel) catch {}; // try stop everything gracefully
    self.io.deinit(self.allocator); // if not possible shutdown IO
    var next = self.frames.first; // then force collect all the frames
    while (next) |node| { // this may cause the program to leak memory
        next = node.next;
        var frame = node.data.cast();
        frame.status = .completed;
        frame.deinit();
    }
    self.* = undefined;
}

pub const SpawnError = Frame.Error || error{Unexpected};

pub const SpawnOptions = struct {
    stack: union(enum) {
        unmanaged: Frame.Stack,
        managed: usize,
    } = .{ .managed = options.stack_size },
};

/// Spawns a new task, the task may do local IO operations which will not block the whole process using the `io` namespace functions
/// Call `task.complete` to collect the result and free the stack
/// Or alternatively `task.cancel` to cancel the task
pub fn spawnAny(self: *@This(), Result: type, comptime func: anytype, args: anytype, opts: SpawnOptions) SpawnError!Task {
    if (self.state == .tear_down) return error.Unexpected;

    const stack = switch (opts.stack) {
        .unmanaged => |buf| buf,
        .managed => |sz| try self.allocator.alignedAlloc(u8, Frame.stack_alignment, sz),
    };

    errdefer if (opts.stack == .managed) self.allocator.free(stack);
    const frame = try Frame.init(self, stack, opts.stack == .managed, Result, func, args);
    return .{ .frame = frame };
}

/// Spawns a new task, the task may do local IO operations which will not block the whole process using the `io` namespace functions
/// Call `task.complete` to collect the result and free the stack
/// Or alternatively `task.cancel` to cancel the task
pub fn spawn(self: *@This(), comptime func: anytype, args: anytype, opts: SpawnOptions) SpawnError!Task.Generic(@TypeOf(@call(.auto, func, args))) {
    const RT = @TypeOf(@call(.auto, func, args));
    var task = try self.spawnAny(RT, func, args, opts);
    return task.generic(RT);
}

/// Step the scheduler by a single step.
/// If `mode` is `.blocking` will block until there is `IO` activity.
/// Returns the number of tasks running.
pub fn tick(self: *@This(), mode: aio.Dynamic.CompletionMode) aio.Error!usize {
    if (self.state == .tear_down) return error.Unexpected;
    self.io_ack +%= 1;
    _ = try self.io.complete(mode);
    return self.frames.len - self.num_complete;
}

pub const CompleteMode = Frame.CompleteMode;

/// Run until all tasks are complete.
pub fn run(self: *@This(), mode: CompleteMode) aio.Error!void {
    if (mode == .cancel) {
        // start canceling tasks starting from the most recent one
        while (self.frames.last) |node| {
            if (self.state == .tear_down) return error.Unexpected;
            node.data.cast().complete(.cancel, void);
        }
    } else {
        while (self.state != .tear_down) {
            if (try self.tick(.blocking) == 0) break;
        }
    }
}

fn ioQueue(uop: aio.Dynamic.Uop, id: aio.Id) void {
    const OperationContext = @import("io.zig").OperationContext;
    switch (uop) {
        inline else => |*op| {
            std.debug.assert(op.userdata != 0);
            var ctx: *OperationContext = @ptrFromInt(op.userdata);
            ctx.id = id;
        },
    }
}

fn ioCompletion(uop: aio.Dynamic.Uop, _: aio.Id, failed: bool) void {
    const OperationContext = @import("io.zig").OperationContext;
    switch (uop) {
        inline else => |*op| {
            std.debug.assert(op.userdata != 0);
            var ctx: *OperationContext = @ptrFromInt(op.userdata);
            var frame: *Frame = ctx.whole.frame;
            std.debug.assert(ctx.whole.num_operations > 0);
            ctx.completed = true;
            ctx.whole.num_operations -= 1;
            ctx.whole.num_errors += @intFromBool(failed);
            if (ctx.whole.num_operations == 0) {
                switch (frame.status) {
                    .io, .io_cancel => frame.wakeup(frame.status),
                    else => unreachable,
                }
            }
        },
    }
}
