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

pub const Error = aio.Error || error{Canceled};

pub inline fn do(pairs: anytype, status: Frame.Status) Error!u16 {
    aio.sanityCheck(pairs);

    // .io_cancel status means the io operation must complete and cannot be canceled
    // that is, the frame is put in `io_cancel` state rather than normal `io` state.
    std.debug.assert(status == .io or status == .io_cancel);
    if (Frame.current()) |frame| {
        if (status != .io_cancel and frame.canceled) return error.Canceled;

        var whole: WholeContext = .{ .num_operations = pairs.len, .frame = frame };
        var ctx_list: [pairs.len]OperationContext = undefined;

        var cpy_pairs: @TypeOf(pairs) = undefined;
        inline for (pairs, &cpy_pairs, &ctx_list) |pair, *cpy, *ctx| {
            ctx.* = .{ .whole = &whole };
            cpy.* = pair;
            cpy.op.userdata = @intFromPtr(ctx);
        }
        try frame.scheduler.io.queue(cpy_pairs, frame.scheduler);

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
                    frame.scheduler.io.queue(
                        aio.op(.cancel, .{ .id = ctx.id.?, .userdata = @intFromPtr(ctx) }, .unlinked),
                        frame.scheduler,
                    ) catch @panic("coro: could not safely cancel io");
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
        return aio.complete(pairs);
    }
}
