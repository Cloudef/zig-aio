// tests backend override

const std = @import("std");
const aio = @import("aio");
const log = std.log.scoped(.backend_override);

const CustomBackend = struct {
    pub const EventSource = struct {};

    ops: u16 = 0,

    pub fn isSupported(ops: []const aio.Operation) bool {
        for (ops) |op| if (op != .nop) return false;
        return true;
    }

    pub fn init(_: std.mem.Allocator, _: u16) !@This() {
        return .{};
    }

    pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}

    pub fn queue(self: *@This(), pairs: anytype, handler: anytype) !void {
        inline for (pairs, 0..) |pair, id| {
            std.log.warn("info: {}", .{pair.op});
            if (@TypeOf(handler) != void) {
                handler.aio_queue(aio.Id.init(id), pair.op.userdata);
            }
            self.ops += 1;
        }
    }

    pub fn complete(self: *@This(), _: aio.CompletionMode, handler: anytype) !aio.CompletionResult {
        defer self.ops = 0;
        for (0..self.ops) |id| {
            if (@TypeOf(handler) != void) {
                handler.aio_queue(aio.Id.init(id), 42);
            }
        }
        return .{ .num_completed = self.ops, .num_errors = 0 };
    }

    pub fn immediate(pairs: anytype) !u16 {
        inline for (pairs) |pair| {
            std.log.warn("info: {}", .{pair.op});
        }
        return 0;
    }
};

pub const aio_options: aio.Options = .{
    .backend_override = CustomBackend,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var dynamic = try aio.Dynamic.init(gpa.allocator(), 16);
    defer dynamic.deinit(gpa.allocator());
    const Handler = struct {
        pub fn aio_queue(_: @This(), _: aio.Id, userdata: usize) void {
            std.debug.assert(42 == userdata);
        }

        pub fn aio_complete(_: @This(), _: aio.Id, userdata: usize, failed: bool) void {
            std.debug.assert(42 == userdata);
            std.debug.assert(!failed);
        }
    };
    const handler: Handler = .{};
    try dynamic.queue(aio.op(.nop, .{ .userdata = 42 }, .unlinked), handler);
    std.debug.assert(0 == try dynamic.completeAll(handler));

    try aio.single(.nop, .{});

    std.debug.assert(aio.isSupported(&.{.nop}) == true);
    std.debug.assert(aio.isSupported(&.{.read}) == false);
}
