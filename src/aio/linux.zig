const std = @import("std");
const aio = @import("../aio.zig");
const IoUring = @import("IoUring.zig");
const Posix = @import("Posix.zig");
const log = std.log.scoped(.aio_linux);

pub const IO = switch (aio.options.posix) {
    .auto => PosixSupport, // prefer IoUring, support Posix fallback during runtime
    .force => Posix, // use only the Posix backend
    .disable => IoUring, // use only the IoUring backend
};

const PosixSupport = union(enum) {
    pub const EventSource = IoUring.EventSource;
    comptime {
        std.debug.assert(EventSource == Posix.EventSource);
    }

    io_uring: IoUring,
    posix: Posix,

    var once = std.once(do_once);
    var io_uring_supported: bool = undefined;

    fn do_once() void {
        io_uring_supported = IoUring.isSupported(aio.options.required_ops);
        if (!io_uring_supported) log.warn("io_uring unsupported, using the posix backend", .{});
    }

    pub fn isSupported(operations: []const aio.Operation) bool {
        once.call();
        // io_uring currently has to support all operations or we fallback
        // so the io_uring codepath here never really gets executed
        // however, this may change in future so it's better this way
        // for example, we may want to still pick io_uring even if some
        // obscurce operation is not supported
        return if (io_uring_supported)
            IoUring.isSupported(operations)
        else
            Posix.isSupported(operations);
    }

    pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
        once.call();
        return if (io_uring_supported)
            .{ .io_uring = try IoUring.init(allocator, n) }
        else
            .{ .posix = try Posix.init(allocator, n) };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*io| io.deinit(allocator),
        }
    }

    pub fn queue(self: *@This(), pairs: anytype, handler: anytype) aio.Error!void {
        return switch (self.*) {
            inline else => |*io| io.queue(pairs, handler),
        };
    }

    pub fn complete(self: *@This(), mode: aio.CompletionMode, handler: anytype) aio.Error!aio.CompletionResult {
        return switch (self.*) {
            inline else => |*io| io.complete(mode, handler),
        };
    }

    pub fn immediate(pairs: anytype) aio.Error!u16 {
        once.call();
        return if (io_uring_supported)
            IoUring.immediate(pairs)
        else
            Posix.immediate(pairs);
    }
};
