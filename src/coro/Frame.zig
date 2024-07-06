const std = @import("std");
const aio = @import("aio");
const Fiber = @import("zefi.zig");
const Scheduler = @import("Scheduler.zig");
const Link = @import("minilib").Link;
const log = std.log.scoped(.coro);

pub const List = std.DoublyLinkedList(Link(@This(), "link", .double));
pub const stack_alignment = Fiber.stack_alignment;
pub const Stack = Fiber.Stack;

pub const Status = enum(u8) {
    active, // frame is running
    io, // waiting for io
    io_cancel, // cannot be canceled
    completed, // the frame is complete and has to be collected
    waiting_frame, // waiting for another frame to complete
    semaphore, // waiting on a semaphore
    reset_event, // waiting on a reset_event
    yield, // yielded by a user code

    pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.writeAll(@tagName(self));
    }
};

pub const WaitList = std.SinglyLinkedList(Link(@This(), "wait_link", .single));

fiber: *Fiber,
stack: ?Fiber.Stack = null,
result: *anyopaque,
scheduler: *Scheduler,
canceled: bool = false,
cancelable: bool = true,
status: Status = .active,
yield_state: u8 = 0,
link: List.Node = .{ .data = .{} },
waiters: WaitList = .{},
wait_link: WaitList.Node = .{ .data = .{} },

pub fn current() ?*@This() {
    if (Fiber.current()) |fiber| {
        return @ptrFromInt(fiber.getUserDataPtr().*);
    } else {
        return null;
    }
}

pub fn format(self: @This(), comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
    try writer.print("{x}:{}", .{ @intFromPtr(self.fiber), self.status });
}

pub const Error = error{OutOfMemory} || Fiber.Error;

fn entrypoint(
    scheduler: *Scheduler,
    stack: ?Fiber.Stack,
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

pub fn init(
    scheduler: *Scheduler,
    stack: Stack,
    managed_stack: bool,
    Result: type,
    comptime func: anytype,
    args: anytype,
) Error!*@This() {
    var frame: *@This() = undefined;
    var fiber = try Fiber.init(stack, 0, entrypoint, .{
        scheduler,
        if (managed_stack) stack else null,
        Result,
        &frame,
        func,
        args,
    });
    fiber.switchTo();
    return frame;
}

fn wakeupWaiters(self: *@This()) void {
    var next = self.waiters.first;
    while (next) |node| {
        next = node.next;
        node.data.cast().wakeup(.waiting_frame);
    }
}

pub fn deinit(self: *@This()) void {
    debug("deinit: {}", .{self});
    std.debug.assert(self.status == .completed);
    self.scheduler.frames.remove(&self.link);
    self.scheduler.num_complete -= 1;
    self.wakeupWaiters();
    if (self.stack) |stack| self.scheduler.allocator.free(stack);
    // stack is now gone, doing anything after this with @This() is ub
}

pub fn signal(self: *@This()) void {
    switch (self.status) {
        .active, .io_cancel, .completed => {},
        else => |status| self.wakeup(status),
    }
}

pub fn wakeup(self: *@This(), expected_status: Status) void {
    std.debug.assert(self.status == expected_status);
    debug("waking up: {}", .{self});
    self.status = .active;
    self.fiber.switchTo();
}

pub fn yield(status: Status) void {
    if (current()) |frame| {
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
    std.debug.assert(!self.canceled);
    debug("complete: {}, {s}", .{ self, @tagName(mode) });

    if (current()) |frame| {
        while (self.status != .completed) {
            if (mode == .cancel and tryCancel(self)) break;
            self.waiters.prepend(&frame.wait_link);
            defer self.waiters.remove(&frame.wait_link);
            yield(.waiting_frame);
        }
    } else {
        var timer: ?std.time.Timer = std.time.Timer.start() catch null;
        while (self.status != .completed) {
            if (mode == .cancel) {
                if (tryCancel(self)) break;
                if (timer != null and self.status != .io_cancel and self.cancelable) {
                    if (timer.?.read() >= 5 * std.time.ns_per_s) {
                        log.err("deadlock detected, tearing down the scheduler by a force", .{});
                        self.scheduler.state = .tear_down;
                        break;
                    }
                } else if (timer != null and self.status == .io_cancel) {
                    timer.?.reset(); // don't count the possible long lasting io tasks
                }
            }
            _ = self.scheduler.tick(.blocking) catch |err| switch (err) {
                error.NoDevice => unreachable,
                error.SystemOutdated => unreachable,
                error.PermissionDenied => unreachable,
                else => |e| {
                    log.err("error: {}", .{e});
                    log.err("tick failed in a critical section, tearing down the scheduler by a force", .{});
                    self.scheduler.state = .tear_down;
                    break;
                },
            };
        }
    }

    if (comptime Result != void) {
        std.debug.assert(self.scheduler.state != .tear_down); // can only be handled if complete returns void
        std.debug.assert(self.status == .completed);
        const res: Result = @as(*Result, @ptrCast(@alignCast(self.result))).*;
        self.deinit();
        return res;
    } else {
        self.deinit();
    }
}

pub fn tryCancel(self: *@This()) bool {
    if (self.status != .completed and self.cancelable) {
        self.canceled = true;
        switch (self.status) {
            .active => {},
            .io => |status| {
                debug("cancel... pending on io: {}", .{self});
                self.wakeup(status); // cancel io
            },
            .io_cancel => {
                debug("cancel... pending on cancel: {}", .{self});
                // can't cancel
            },
            .waiting_frame => {
                debug("cancel... pending for another frame to complete: {}", .{self});
                // can't cancel
            },
            .reset_event => |status| {
                debug("cancel... reset event: {}", .{self});
                self.wakeup(status);
            },
            .semaphore => |status| {
                debug("cancel... semaphore: {}", .{self});
                self.wakeup(status);
            },
            .yield => |status| {
                debug("cancel... yield: {}", .{self});
                self.wakeup(status);
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
        log.debug(fmt, args);
    }
}
