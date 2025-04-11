const std = @import("std");
const aio = @import("aio");
const Frame = @import("Frame.zig");
const Task = @import("Task.zig");
const options = @import("../coro.zig").options;

allocator: std.mem.Allocator,
io: aio.Dynamic,
running: Frame.List = .{},
completed: Frame.List = .{},
state: enum { init, tear_down } = .init,

pub const InitOptions = struct {
    /// This is a hint, the implementation makes the final call
    io_queue_entries: u16 = options.io_queue_entries,
};

pub fn init(allocator: std.mem.Allocator, opts: InitOptions) aio.Error!@This() {
    return .{ .allocator = allocator, .io = try aio.Dynamic.init(allocator, opts.io_queue_entries) };
}

pub fn deinit(self: *@This()) void {
    if (self.state == .tear_down) self.state = .init;
    self.run(.cancel) catch {}; // try stop everything gracefully
    self.io.deinit(self.allocator); // if not possible shutdown IO
    // force collect all frames, this may cause the program to leak memory
    var next = self.completed.first;
    while (next) |node| {
        next = node.next;
        const frame: *Frame = @fieldParentPtr("link", node);
        frame.deinit();
    }
    while (self.running.popFirst()) |node| {
        const frame: *Frame = @fieldParentPtr("link", node);
        frame.status = .completed;
        self.completed.append(&frame.link);
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
    detached: bool = false,
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
    if (opts.detached) frame.detach();
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
/// If `mode` is `.blocking` will block until there is `IO` activity or one of the frames completes.
/// Returns the number of tasks running.
pub fn tick(self: *@This(), mode: aio.CompletionMode) aio.Error!usize {
    if (self.state == .tear_down) return error.Unexpected;
    if (self.completed.first) |first| {
        var next: ?*Frame.List.Node = first;
        while (next) |node| {
            next = node.next;
            const frame: *Frame = @fieldParentPtr("link", node);
            if (frame.detached) {
                std.debug.assert(frame.completer == null);
                frame.deinit();
            } else if (frame.completer) |completer| {
                completer.wakeup(.waiting_frame);
            }
        }
    }
    _ = try self.io.complete(mode, self);
    return self.running.len();
}

pub const CompleteMode = Frame.CompleteMode;

/// Run until all tasks are complete.
pub fn run(self: *@This(), mode: CompleteMode) aio.Error!void {
    if (mode == .cancel) {
        // start canceling tasks starting from the most recent one
        while (self.running.last) |node| {
            if (self.state == .tear_down) return error.Unexpected;
            const frame: *Frame = @fieldParentPtr("link", node);
            frame.complete(.cancel, void);
        }
    } else {
        while (self.state != .tear_down) {
            if (try self.tick(.blocking) == 0) break;
        }
    }
}

pub fn aio_queue(_: *@This(), id: aio.Id, userdata: usize) void {
    const OperationContext = @import("io.zig").OperationContext;
    std.debug.assert(userdata != 0);
    var ctx: *OperationContext = @ptrFromInt(userdata);
    ctx.id = id;
}

pub fn aio_complete(_: *@This(), _: aio.Id, userdata: usize, failed: bool) void {
    const OperationContext = @import("io.zig").OperationContext;
    std.debug.assert(userdata != 0);
    var ctx: *OperationContext = @ptrFromInt(userdata);
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
}
