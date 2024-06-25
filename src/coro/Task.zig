const std = @import("std");
const aio = @import("aio");
const ReturnType = @import("common.zig").ReturnType;
const ReturnTypeWithError = @import("common.zig").ReturnTypeWithError;
const Frame = @import("Frame.zig");

const Task = @This();

frame: *align(@alignOf(Frame)) anyopaque,

fn cast(self: @This()) *Frame {
    return @ptrCast(self.frame);
}

pub fn format(self: @This(), comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
    return self.cast().format(fmt, opts, writer);
}

/// Get the current task, or null if not inside a task
pub inline fn current() ?@This() {
    if (Frame.current()) |frame| {
        return .{ .frame = frame };
    } else {
        return null;
    }
}

pub inline fn signal(self: @This()) void {
    self.cast().signal();
}

pub inline fn state(self: @This(), T: type) T {
    return @enumFromInt(self.cast().yield_state);
}

pub const YieldError = error{Canceled};

pub inline fn yield(yield_state: anytype) YieldError!void {
    if (Frame.current()) |frame| {
        frame.yield_state = @intFromEnum(yield_state);
        if (frame.yield_state == 0) @panic("yield_state `0` is reserved");
        Frame.yield(.yield);
        if (frame.canceled) return error.Canceled;
    } else {
        unreachable;
    }
}

pub inline fn wakeup(self: @This()) void {
    self.cast().yield_state = 0;
    self.cast().wakeup(.yield);
}

pub inline fn wakeupIf(self: @This(), yield_state: anytype) void {
    if (self.state(@TypeOf(yield_state)) == yield_state) {
        self.cast().wakeup(.yield);
    }
}

pub const CompleteMode = Frame.CompleteMode;

pub inline fn complete(self: @This(), mode: CompleteMode, comptime func: anytype) ReturnType(func) {
    return self.cast().complete(mode, ReturnType(func));
}

pub fn generic(self: @This(), comptime func: anytype) Generic(func) {
    return .{ .node = self.node };
}

pub fn Generic(comptime func: anytype) type {
    return struct {
        pub const Result = ReturnType(func);
        pub const Fn = @TypeOf(func);

        frame: *align(@alignOf(Frame)) anyopaque,
        comptime entry: Fn = func,

        fn cast(self: *@This()) *Frame {
            return @ptrCast(self.frame);
        }

        pub fn format(self: @This(), comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
            return self.any().format(fmt, opts, writer);
        }

        pub inline fn signal(self: @This()) void {
            self.any().signal();
        }

        pub inline fn state(self: @This(), T: type) T {
            return self.any().state(T);
        }

        pub inline fn wakeup(self: @This()) void {
            self.any().wakeup();
        }

        pub inline fn wakeupIf(self: @This(), yield_state: anytype) void {
            self.any().wakeupIf(yield_state);
        }

        pub inline fn complete(self: @This(), mode: CompleteMode) Result {
            return self.any().complete(mode, func);
        }

        pub inline fn any(self: @This()) Task {
            return .{ .frame = self.frame };
        }
    };
}
