const std = @import("std");
const aio = @import("aio");
const io = @import("io.zig");
const Frame = @import("Frame.zig");
const Task = @import("Task.zig");
const common = @import("common.zig");
const options = @import("../coro.zig").options;

allocator: std.mem.Allocator,
io: aio.Dynamic,
io_ack: u8 = 0,
frames: Frame.List = .{},
num_complete: usize = 0,
helper: *Frame = undefined,
state: enum { init, helper_spawned, tear_down } = .init,

pub const InitOptions = struct {
    /// This is a hint, the implementation makes the final call
    io_queue_entries: u16 = options.io_queue_entries,
};

pub fn init(allocator: std.mem.Allocator, opts: InitOptions) aio.Error!@This() {
    var work = try aio.Dynamic.init(allocator, opts.io_queue_entries);
    work.queue_callback = ioQueue;
    work.completion_callback = ioCompletition;
    return .{ .allocator = allocator, .io = work };
}

pub fn deinit(self: *@This()) void {
    self.run(.cancel) catch @panic("unrecovable");
    var next = self.frames.first;
    while (next) |node| {
        next = node.next;
        var frame = node.data.cast();
        frame.deinit();
    }
    if (self.state != .init) self.helper.deinit();
    self.io.deinit(self.allocator);
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
/// Call `frame.complete` to collect the result and free the stack
pub fn spawn(self: *@This(), comptime func: anytype, args: anytype, opts: SpawnOptions) SpawnError!Task.Generic(func) {
    if (self.state == .tear_down) return error.Unexpected;

    if (self.state == .init) {
        self.state = .helper_spawned;
        const stack = try self.allocator.alignedAlloc(u8, Frame.stack_alignment, 4096);
        errdefer self.allocator.free(stack);
        self.helper = try Frame.init(self, stack, true, Task.Generic(helper).Result, false, helper, .{self});
    }

    const stack = switch (opts.stack) {
        .unmanaged => |buf| buf,
        .managed => |sz| try self.allocator.alignedAlloc(u8, Frame.stack_alignment, sz),
    };

    errdefer if (opts.stack == .managed) self.allocator.free(stack);
    const frame = try Frame.init(self, stack, opts.stack == .managed, Task.Generic(func).Result, true, func, args);
    return .{ .frame = frame };
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
    while (self.state != .tear_down) {
        if (mode == .cancel) {
            var next = self.frames.first;
            while (next) |node| {
                next = node.next;
                _ = node.data.cast().tryCancel();
            }
        }
        if (try self.tick(.blocking) == 0) break;
    }
}

// Helper task when we have to spin the loop, for example when collecting results
// This is a critical section, and if it fails there's not much we can do
// TODO: add deadlock detection
//       if some frame keeps yielding the same state and never finishes do a panic
fn helper(self: *@This()) void {
    Frame.yield(.reset_event);
    const scope = std.log.scoped(.coro);
    while (self.state != .tear_down) {
        _ = self.tick(.blocking) catch |err| switch (err) {
            error.NoDevice => unreachable,
            error.SystemOutdated => unreachable,
            error.PermissionDenied => unreachable,
            error.SubmissionQueueFull => continue,
            else => |e| {
                scope.err("error: {}", .{e});
                scope.err("self.tick failed in a critical section, tearing down the scheduler by a force", .{});
                self.state = .tear_down;
            },
        };
        Frame.yield(.reset_event);
    }
}

fn ioQueue(uop: aio.Dynamic.Uop, id: aio.Id) void {
    switch (uop) {
        inline else => |*op| {
            if (@TypeOf(op.*) == aio.Nop and op.domain == .coro) {
                // reserved
            } else {
                std.debug.assert(op.userdata != 0);
                var ctx: *common.OperationContext = @ptrFromInt(op.userdata);
                ctx.id = id;
            }
        },
    }
}

fn ioCompletition(uop: aio.Dynamic.Uop, _: aio.Id, failed: bool) void {
    switch (uop) {
        inline else => |*op| {
            if (@TypeOf(op.*) == aio.Nop and op.domain == .coro) {
                // reserved
            } else {
                std.debug.assert(op.userdata != 0);
                var ctx: *common.OperationContext = @ptrFromInt(op.userdata);
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
        },
    }
}
