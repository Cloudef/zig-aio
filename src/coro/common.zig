const std = @import("std");
const aio = @import("aio");
const Frame = @import("Frame.zig");

pub const WholeContext = struct {
    num_operations: u16,
    num_errors: u16 = 0,
    frame: *Frame,
};

pub const OperationContext = struct {
    whole: *WholeContext,
    id: ?aio.Id = null,
    completed: bool = false,
};

pub fn Link(comptime T: type, comptime field: []const u8, comptime container: enum { single, double }) type {
    return struct {
        pub inline fn cast(self: *@This()) *T {
            switch (container) {
                .single => {
                    const node: *std.SinglyLinkedList(@This()).Node = @alignCast(@fieldParentPtr("data", self));
                    return @fieldParentPtr(field, node);
                },
                .double => {
                    const node: *std.DoublyLinkedList(@This()).Node = @alignCast(@fieldParentPtr("data", self));
                    return @fieldParentPtr(field, node);
                },
            }
        }
    };
}

pub fn ReturnType(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).Fn.return_type.?;
}

pub fn ReturnTypeWithError(comptime func: anytype, comptime E: type) type {
    return MixErrorUnion(ReturnType(func), E);
}

pub fn MixErrorUnion(comptime T: type, comptime E: type) type {
    return switch (@typeInfo(T)) {
        .ErrorUnion => |eu| (E || eu.error_set)!eu.payload,
        else => E!T,
    };
}
