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

pub inline fn isComplete(self: @This()) bool {
    return self.cast().status == .completed;
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

pub inline fn complete(self: @This(), mode: CompleteMode, Result: type) Result {
    return self.cast().complete(mode, Result);
}

pub fn generic(self: @This(), Result: type) Generic(Result) {
    return .{ .frame = self.frame };
}

pub fn generic2(self: @This(), comptime func: anytype) Generic2(func) {
    return .{ .frame = self.frame };
}

pub fn Generic(comptime ResultType: type) type {
    return struct {
        pub const Result = ResultType;

        frame: *align(@alignOf(Frame)) anyopaque,

        fn cast(self: *@This()) *Frame {
            return @ptrCast(self.frame);
        }

        pub fn format(self: @This(), comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
            return self.any().format(fmt, opts, writer);
        }

        pub inline fn isComplete(self: @This()) bool {
            return self.any().isComplete();
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
            return self.any().complete(mode, Result);
        }

        pub inline fn any(self: @This()) Task {
            return .{ .frame = self.frame };
        }
    };
}

pub fn Generic2(comptime func: anytype) type {
    return Generic(ReturnType(func));
}
