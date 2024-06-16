//! Basic io-uring -like asynchronous IO API
//! It is possible to both dynamically and statically queue IO work to be executed in a asynchronous fashion
//! On linux this is a very shim wrapper around `io_uring`, on other systems there might be more overhead

const std = @import("std");

pub const InitError = error{
    Overflow,
    OutOfMemory,
    PermissionDenied,
    ProcessQuotaExceeded,
    SystemQuotaExceeded,
    SystemResources,
    SystemOutdated,
    Unexpected,
};

pub const QueueError = error{
    Overflow,
    SubmissionQueueFull,
};

pub const CompletionError = error{
    CompletionQueueOvercommitted,
    SubmissionQueueEntryInvalid,
    SystemResources,
    Unexpected,
};

pub const OperationError = ops.ErrorUnion;

pub const ImmediateError = InitError || QueueError || CompletionError;

pub const CompletionResult = struct {
    num_completed: u16 = 0,
    num_errors: u16 = 0,
};

/// Queue operations dynamically and complete them on demand
pub const Dynamic = struct {
    io: IO,

    pub inline fn init(allocator: std.mem.Allocator, n: u16) InitError!@This() {
        return .{ .io = try IO.init(allocator, n) };
    }

    pub inline fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.io.deinit(allocator);
        self.* = undefined;
    }

    /// Queue operations for future completion
    /// The call is atomic, if any of the operations fail to queue, then the given operations are reverted
    pub inline fn queue(self: *@This(), operations: anytype) QueueError!void {
        const ti = @typeInfo(@TypeOf(operations));
        if (comptime ti == .Struct and ti.Struct.is_tuple) {
            return self.io.queue(operations.len, &struct { ops: @TypeOf(operations) }{ .ops = operations });
        } else {
            return self.io.queue(1, &struct { ops: @TypeOf(.{operations}) }{ .ops = .{operations} });
        }
    }

    pub const CompletionMode = enum {
        /// Call to `complete` will block until at least one operation completes
        blocking,
        /// Call to `complete` will only complete the currently ready operations if any
        nonblocking,
    };

    /// Complete operations
    /// Returns the number of completed operations, `0` if no operations were completed
    pub inline fn complete(self: *@This(), mode: CompletionMode) CompletionError!CompletionResult {
        return self.io.complete(mode);
    }
};

/// Completes a list of operations immediately, blocks until complete
/// For error handling you must check the `out_error` field in the operation
pub inline fn batch(operations: anytype) ImmediateError!CompletionResult {
    return IO.immediate(operations.len, &struct { ops: @TypeOf(operations) }{ .ops = operations });
}

/// Completes a list of operations immediately, blocks until complete
/// Returns `error.SomeOperationFailed` if any operation failed
pub inline fn multi(operations: anytype) (ImmediateError || error{SomeOperationFailed})!void {
    const res = try batch(operations);
    if (res.num_errors > 0) return error.SomeOperationFailed;
}

/// Completes a single operation immediately, blocks until complete
pub inline fn single(operation: anytype) (ImmediateError || OperationError)!void {
    var op: @TypeOf(operation) = operation;
    var err: @TypeOf(op.out_error.?.*) = error.Success;
    op.out_error = &err;
    _ = try batch(.{op});
    if (err != error.Success) return err;
}

const ops = @import("aio/ops.zig");
pub const Id = ops.Id;
pub const Sync = ops.Sync;
pub const Read = ops.Read;
pub const Write = ops.Write;
pub const Accept = ops.Accept;
pub const Connect = ops.Connect;
pub const Recv = ops.Recv;
pub const Send = ops.Send;
pub const OpenAt = ops.OpenAt;
pub const Close = ops.Close;
pub const Timeout = ops.Timeout;
pub const TimeoutRemove = ops.TimeoutRemove;
pub const LinkTimeout = ops.LinkTimeout;
pub const Cancel = ops.Cancel;
pub const RenameAt = ops.RenameAt;
pub const UnlinkAt = ops.UnlinkAt;
pub const MkDirAt = ops.MkDirAt;
pub const SymlinkAt = ops.SymlinkAt;
pub const Socket = ops.Socket;
pub const CloseSocket = ops.CloseSocket;

const IO = switch (@import("builtin").target.os.tag) {
    .linux => @import("aio/linux.zig"),
    else => @compileError("unsupported os"),
};
