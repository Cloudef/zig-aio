const std = @import("std");
const aio = @import("aio");
const Scheduler = @import("Scheduler.zig");
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

pub const Error = aio.Error || error{Canceled};

pub fn do(operations: anytype, status: Frame.Status) Error!u16 {
    // .io_cancel status means the io operation must complete and cannot be canceled
    // that is, the frame is put in `io_cancel` state rather than normal `io` state.
    std.debug.assert(status == .io or status == .io_cancel);
    if (Frame.current()) |frame| {
        if (frame.canceled) return error.Canceled;

        var whole: WholeContext = .{ .num_operations = operations.len, .frame = frame };
        var ctx_list: [operations.len]OperationContext = undefined;

        const ti = @typeInfo(@TypeOf(operations));
        if (comptime (ti == .@"struct" and ti.@"struct".is_tuple) or ti == .array) {
            if (comptime operations.len == 0) @compileError("no work to be done");
            var uops: [operations.len]aio.Dynamic.Uop = undefined;
            inline for (operations, &uops, &ctx_list, 0..) |op, *uop, *ctx, idx| {
                ctx.* = .{ .whole = &whole };
                var cpy = op;
                cpy.userdata = @intFromPtr(ctx);
                // coro io operations get merged into one, having .link on last operation is always a mistake
                if (idx == operations.len - 1) cpy.link = .unlinked;
                uop.* = aio.Operation.uopFromOp(cpy);
            }
            try frame.scheduler.io.io.queue(operations.len, &uops, frame.scheduler.io.queue_callback);
        } else {
            var cpy = operations;
            cpy.userdata = @intFromPtr(&ctx_list[0]);
            cpy.link = .unlinked;
            var uops: [1]aio.Dynamic.Uop = .{aio.Operation.uopFromOp(cpy)};
            try frame.scheduler.io.io.queue(1, &uops, frame.scheduler.io.queue_callback);
        }

        // wait until scheduler actually submits our work
        Frame.yield(status);

        // check if this was a cancel
        if (whole.num_operations > 0) {
            // this branch should not ever be executed if status == .io_cancel
            std.debug.assert(status != .io_cancel);

            var num_cancels: u16 = 0;
            inline for (&ctx_list) |*ctx| {
                if (!ctx.completed and ctx.id != null) {
                    // reuse the same ctx, we don't care about completation status anymore
                    try frame.scheduler.io.queue(aio.Cancel{ .id = ctx.id.?, .userdata = @intFromPtr(ctx) });
                    num_cancels += 1;
                }
            }

            std.debug.assert(num_cancels > 0);
            whole.num_operations += num_cancels;

            // it's not possible to cancel the `io_cancel` state, so we don't have to
            // wait for confirmation that scheduler has submitted our cancelation
            Frame.yield(.io_cancel);
            return error.Canceled;
        }

        return whole.num_errors;
    } else {
        return aio.complete(operations);
    }
}
