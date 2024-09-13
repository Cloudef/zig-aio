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

        var work = struct { ops: @TypeOf(operations) }{ .ops = operations };
        var whole: WholeContext = .{ .num_operations = operations.len, .frame = frame };
        var ctx_list: [operations.len]OperationContext = undefined;

        inline for (&work.ops, &ctx_list) |*op, *ctx| {
            ctx.* = .{ .whole = &whole };
            op.userdata = @intFromPtr(ctx);
        }

        // coro io operations get merged into one, having .link on last operation is always a mistake
        work.ops[operations.len - 1].link = .unlinked;

        try frame.scheduler.io.queue(work.ops);
        // wait until scheduler actually submits our work
        const ack = frame.scheduler.io_ack;
        while (ack == frame.scheduler.io_ack) {
            Frame.yield(status);
        }

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
