pub const DynamicThreadPool = @import("minilib/DynamicThreadPool.zig");
pub const FixedArrayList = @import("minilib/fixed_array_list.zig").FixedArrayList;
pub const DoubleBufferedFixedArrayList = @import("minilib/fixed_array_list.zig").DoubleBufferedFixedArrayList;
pub const ItemPool = @import("minilib/item_pool.zig").ItemPool;

const std = @import("std");

/// Lets say you have a linked list:
/// `const List = std.SinglyLinkedList(Link(SomeStruct, "member", .single));`
/// You can now store a field `member: List.Node` in `SomeStruct` and retieve a `*SomeStruct` by calling `cast()` on `List.Node`.
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

/// Returns the return type of a function
pub fn ReturnType(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).Fn.return_type orelse @compileError("Return type of a generic function could not be deduced");
}

/// Returns the return type of a function with error set mixed in it.
/// The return type will be converted into a error union if it wasn't already.
pub fn ReturnTypeMixedWithErrorSet(comptime func: anytype, comptime E: type) type {
    return MixErrorUnionWithErrorSet(ReturnType(func), E);
}

/// Mix error union with a error set
pub fn MixErrorUnionWithErrorSet(comptime T: type, comptime E: type) type {
    return switch (@typeInfo(T)) {
        .ErrorUnion => |eu| (E || eu.error_set)!eu.payload,
        else => E!T,
    };
}
