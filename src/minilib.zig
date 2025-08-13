pub const DynamicThreadPool = @import("minilib/dynamic_thread_pool.zig").DynamicThreadPool;
pub const FixedArrayList = @import("minilib/fixed_array_list.zig").FixedArrayList;
pub const DoubleBufferedFixedArrayList = @import("minilib/fixed_array_list.zig").DoubleBufferedFixedArrayList;
pub const Id = @import("minilib/id.zig").Id;
pub const TimerQueue = @import("minilib/TimerQueue.zig");

const std = @import("std");

/// Returns the return type of a function
pub fn ReturnType(comptime func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type orelse @compileError("Return type of a generic function could not be deduced");
}

/// Returns the return type of a function with error set mixed in it.
/// The return type will be converted into a error union if it wasn't already.
pub fn ReturnTypeMixedWithErrorSet(comptime func: anytype, comptime E: type) type {
    return MixErrorUnionWithErrorSet(ReturnType(func), E);
}

/// Mix error union with a error set
pub fn MixErrorUnionWithErrorSet(comptime T: type, comptime E: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| (E || eu.error_set)!eu.payload,
        else => E!T,
    };
}

test {
    std.testing.refAllDecls(@This());
}
