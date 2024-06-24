const std = @import("std");
const aio = @import("aio");
const io = @import("io.zig");
const Fiber = @import("zefi.zig");
const Scheduler = @import("Scheduler.zig");
const common = @import("common.zig");

pub const List = std.DoublyLinkedList(common.Link(@This(), "link", .double));
pub const stack_alignment = Fiber.stack_alignment;
pub const Stack = Fiber.Stack;

pub const Status = enum(u8) {
    active, // frame is running
    io, // waiting for io
    io_cancel, // cannot be canceled
    completed, // the frame is complete and has to be collected
    semaphore, // waiting on a semaphore
    reset_event, // waiting on a reset_event
    yield, // yielded by a user code

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(@tagName(self));
    }
};

pub const WaitList = std.SinglyLinkedList(common.Link(@This(), "wait_link", .single));

fiber: *Fiber,
stack: ?Fiber.Stack = null,
scheduler: *Scheduler,
canceled: bool = false,
status: Status = .active,
result: *anyopaque,
link: List.Node = .{ .data = .{} },
waiters: WaitList = .{},
wait_link: WaitList.Node = .{ .data = .{} },
yield_state: u8 = 0,

pub fn current() ?*@This() {
    if (Fiber.current()) |fiber| {
        return @ptrFromInt(fiber.getUserDataPtr().*);
    } else {
        return null;
    }
}

pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    try writer.print("{x}!{}", .{ @intFromPtr(self.fiber), self.status });
}

pub const Error = error{OutOfMemory} || Fiber.Error;

inline fn entrypoint(
    scheduler: *Scheduler,
    stack: Fiber.Stack,
    Result: type,
    out_frame: **@This(),
    comptime func: anytype,
    args: anytype,
) void {
    var res: Result = undefined;
    var frame: @This() = .{
        .fiber = Fiber.current().?,
        .stack = stack,
        .scheduler = scheduler,
        .result = &res,
    };
    frame.fiber.getUserDataPtr().* = @intFromPtr(&frame);
    scheduler.frames.append(&frame.link);
    out_frame.* = &frame;

    debug("spawned: {}", .{frame});
    res = @call(.always_inline, func, args);
    scheduler.num_complete += 1;

    // keep the stack alive, until the task is collected
    yield(.completed);
}

pub fn init(scheduler: *Scheduler, stack: Stack, Result: type, comptime func: anytype, args: anytype) Error!*@This() {
    var frame: *@This() = undefined;
    var fiber = try Fiber.init(stack, 0, entrypoint, .{ scheduler, stack, Result, &frame, func, args });
    fiber.switchTo();
    return frame;
}

pub fn deinit(self: *@This()) void {
    debug("deinit: {}", .{self});
    std.debug.assert(self.status == .completed);
    self.scheduler.frames.remove(&self.link);
    self.scheduler.num_complete -= 1;
    while (self.waiters.popFirst()) |node| node.data.cast().wakeup(.reset_event);
    if (self.stack) |stack| self.scheduler.allocator.free(stack);
    // stack is now gone, doing anything after this with @This() is ub
}

pub inline fn signal(self: *@This()) void {
    switch (self.status) {
        .active, .io_cancel, .completed => {},
        else => |status| self.wakeup(status),
    }
}

pub inline fn wakeup(self: *@This(), expected_status: Status) void {
    std.debug.assert(self.status == expected_status);
    debug("waking up: {}", .{self});
    self.status = .active;
    self.fiber.switchTo();
}

pub fn yield(status: Status) void {
    if (current()) |frame| {
        if (status != .completed and status != .io_cancel and frame.canceled) return;
        std.debug.assert(frame.status == .active);
        frame.status = status;
        debug("yielding: {}", .{frame});
        Fiber.yield();
    } else {
        unreachable; // yield can only be used from a frame
    }
}

pub const CompleteMode = enum { wait, cancel };

pub fn complete(self: *@This(), mode: CompleteMode, comptime Result: type) Result {
    if (self.canceled) return;

    debug("complete: {}, {}", .{ self, mode });

    if (current()) |frame| {
        while (self.status != .completed) {
            if (mode == .cancel and tryCancel(self)) break;
            self.waiters.prepend(&frame.wait_link);
            yield(.reset_event);
        }
    } else {
        while (self.status != .completed) {
            if (mode == .cancel and tryCancel(self)) break;
            if (self.scheduler.tick(.nonblocking) catch 0 == 0) break;
        }
    }

    const res: Result = @as(*Result, @ptrCast(@alignCast(self.result))).*;
    self.deinit();
    return res;
}

pub fn tryCancel(self: *@This()) bool {
    if (self.status != .completed) {
        self.canceled = true;
        switch (self.status) {
            .active => {},
            .io => {
                debug("cancel... pending on io: {}", .{self});
                self.wakeup(.io); // cancel io
            },
            .io_cancel => {
                debug("cancel... pending on io: {}", .{self});
            },
            .reset_event => {
                debug("cancel... reset event: {}", .{self});
                self.wakeup(.reset_event);
            },
            .semaphore => {
                debug("cancel... semaphore: {}", .{self});
                self.wakeup(.semaphore);
            },
            .yield => {
                debug("cancel... yield: {}", .{self});
                self.wakeup(.yield);
            },
            .completed => unreachable,
        }
    }
    return self.status == .completed;
}

fn debug(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) {
        std.debug.print("coro: " ++ fmt ++ "\n", args);
    } else {
        const options = @import("../coro.zig").options;
        if (comptime !options.debug) return;
        const scope = std.log.scoped(.coro);
        scope.debug(fmt, args);
    }
}
