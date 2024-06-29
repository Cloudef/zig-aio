const builtin = @import("builtin");
const std = @import("std");
const aio = @import("../aio.zig");
const Operation = @import("ops.zig").Operation;
const ItemPool = @import("minilib").ItemPool;
const DynamicThreadPool = @import("minilib").DynamicThreadPool;
const DoubleBufferedFixedArrayList = @import("minilib").DoubleBufferedFixedArrayList;
const Fallback = @import("Fallback.zig");
const WindowsEventSource = @import("posix/windows.zig").EventSource;
const unexpectedError = @import("posix/windows.zig").unexpectedError;
const checked = @import("posix/windows.zig").checked;
const win32 = @import("win32");
const log = std.log.scoped(.aio_windows);

// This is a slightly lighter version of the Fallback backend.
// Optimized for Windows and uses IOCP operations whenever possible.

const GetLastError = win32.foundation.GetLastError;
const INVALID_HANDLE = std.os.windows.INVALID_HANDLE_VALUE;
const HANDLE = win32.foundation.HANDLE;
const CloseHandle = win32.foundation.CloseHandle;
const io = win32.system.io;

comptime {
    if (builtin.single_threaded) {
        @compileError(
            \\Windows backend requires building with threads as otherwise it may block the whole program.
        );
    }
}

pub const IO = switch (aio.options.fallback) {
    .auto => Fallback, // Fallback until Windows backend is complete
    .force => Fallback, // use only the fallback backend
    .disable => @This(), // use only the Windows backend
};

pub const EventSource = WindowsEventSource;

const Result = struct { failure: Operation.Error, id: u16 };

port: HANDLE, // iocp completion port
ops: ItemPool(Operation.Union, u16),
prev_id: ?u16 = null, // for linking operations
next: []u16, // linked operation, points to self if none
link_lock: std.DynamicBitSetUnmanaged, // operation is waiting for linked operation to finish first
started: std.DynamicBitSetUnmanaged, // operation has started
tpool: DynamicThreadPool, // thread pool for performing non iocp operations
source: EventSource, // when operations finish, they signal it using this event source
finished: DoubleBufferedFixedArrayList(Result, u16), // operations that are finished, double buffered to be thread safe

pub fn isSupported(_: []const type) bool {
    return true; // very optimistic :D
}

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    const thread_count = aio.options.max_threads orelse @max(1, std.Thread.getCpuCount() catch 1);
    const port = io.CreateIoCompletionPort(INVALID_HANDLE, null, 0, @intCast(thread_count));
    if (port == null) return error.Unexpected;
    errdefer checked(CloseHandle(port));
    var ops = try ItemPool(Operation.Union, u16).init(allocator, n);
    errdefer ops.deinit(allocator);
    const next = try allocator.alloc(u16, n);
    errdefer allocator.free(next);
    var link_lock = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
    errdefer link_lock.deinit(allocator);
    var started = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
    errdefer started.deinit(allocator);
    var tpool = DynamicThreadPool.init(allocator, .{ .max_threads = aio.options.max_threads }) catch |err| return switch (err) {
        error.TimerUnsupported => error.SystemOutdated,
        else => |e| e,
    };
    errdefer tpool.deinit();
    var source = try EventSource.init();
    errdefer source.deinit();
    var finished = try DoubleBufferedFixedArrayList(Result, u16).init(allocator, n);
    errdefer finished.deinit(allocator);
    return .{
        .port = port.?,
        .ops = ops,
        .next = next,
        .link_lock = link_lock,
        .started = started,
        .tpool = tpool,
        .source = source,
        .finished = finished,
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.tpool.deinit();
    checked(CloseHandle(self.port));
    self.ops.deinit(allocator);
    allocator.free(self.next);
    self.link_lock.deinit(allocator);
    self.started.deinit(allocator);
    self.source.deinit();
    self.finished.deinit(allocator);
    self.* = undefined;
}

fn initOp(op: anytype, id: u16) void {
    if (op.out_id) |p_id| p_id.* = @enumFromInt(id);
    if (op.out_error) |out_error| out_error.* = error.Success;
}

fn addOp(self: *@This(), uop: Operation.Union, linked_to: ?u16) !u16 {
    const id = try self.ops.add(uop);
    if (linked_to) |ln| {
        self.next[ln] = id;
        self.link_lock.set(id);
    } else {
        self.link_lock.unset(id);
    }
    // to account a mistake where link is set without a next op
    self.next[id] = id;
    self.started.unset(id);
    uopUnwrapCall(&self.ops.nodes[id].used, initOp, .{id});
    return id;
}

fn removeOp(self: *@This(), id: u16) void {
    self.next[id] = id;
    self.ops.remove(id);
}

inline fn queueOperation(self: *@This(), op: anytype) aio.Error!u16 {
    const tag = @tagName(comptime Operation.tagFromPayloadType(@TypeOf(op.*)));
    const uop = @unionInit(Operation.Union, tag, op.*);
    const id = try self.addOp(uop, self.prev_id);
    debug("queue: {}: {}, {s} ({?})", .{ id, std.meta.activeTag(uop), @tagName(op.link), self.prev_id });
    if (op.link != .unlinked) self.prev_id = id else self.prev_id = null;
    return id;
}

pub fn queue(self: *@This(), comptime len: u16, work: anytype, cb: ?aio.Dynamic.QueueCallback) aio.Error!void {
    if (comptime len == 1) {
        const id = try self.queueOperation(&work.ops[0]);
        if (cb) |f| f(self.ops.nodes[id].used, @enumFromInt(id));
    } else {
        var ids: std.BoundedArray(u16, len) = .{};
        errdefer for (ids.constSlice()) |id| self.removeOp(id);
        inline for (&work.ops) |*op| ids.append(try self.queueOperation(op)) catch return error.SubmissionQueueFull;
        if (cb) |f| for (ids.constSlice()) |id| f(self.ops.nodes[id].used, @enumFromInt(id));
    }
}

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode, cb: ?aio.Dynamic.CompletionCallback) aio.Error!aio.CompletionResult {
    if (!try self.submit()) return .{};

    const num_finished = self.finished.len();
    if (mode == .blocking and num_finished == 0) {
        self.source.wait();
    } else if (num_finished == 0) {
        return .{};
    }

    const finished = self.finished.swap();
    var num_errors: u16 = 0;
    for (finished) |res| {
        if (res.failure != error.Success) {
            debug("complete: {}: {} [FAIL] {}", .{ res.id, std.meta.activeTag(self.ops.nodes[res.id].used), res.failure });
        } else {
            debug("complete: {}: {} [OK]", .{ res.id, std.meta.activeTag(self.ops.nodes[res.id].used) });
        }

        if (self.ops.nodes[res.id].used == .link_timeout and res.failure == error.Canceled) {
            // special case
        } else {
            num_errors += @intFromBool(res.failure != error.Success);
        }

        uopUnwrapCall(&self.ops.nodes[res.id].used, completition, .{ self, res });

        const uop = self.ops.nodes[res.id].used;
        self.removeOp(res.id);
        if (cb) |f| f(uop, @enumFromInt(res.id), res.failure != error.Success);
    }
    return .{ .num_completed = @intCast(finished.len), .num_errors = num_errors };
}

pub fn immediate(comptime len: u16, work: anytype) aio.Error!u16 {
    var sfb = std.heap.stackFallback(len * 1024, std.heap.page_allocator);
    const allocator = sfb.get();
    var wrk = try init(allocator, len);
    defer wrk.deinit(allocator);
    try wrk.queue(len, work, null);
    var n: u16 = len;
    var num_errors: u16 = 0;
    while (n > 0) {
        const res = try wrk.complete(.blocking, null);
        n -= res.num_completed;
        num_errors += res.num_errors;
    }
    return num_errors;
}

fn finish(self: *@This(), id: u16, failure: Operation.Error) void {
    debug("finish: {} {}", .{ id, failure });
    self.finished.add(.{ .id = id, .failure = failure }) catch unreachable;
    self.source.notify();
}

fn cancel(self: *@This(), id: u16) enum { in_progress, not_found, ok } {
    if (self.started.isSet(id)) return .in_progress;
    if (self.ops.nodes[id] != .used) return .not_found;
    // collect the result later
    self.finish(id, error.Canceled);
    return .ok;
}

fn onThreadPosixExecutor(self: *@This(), id: u16, uop: *Operation.Union) void {
    const posix = @import("posix.zig");
    var failure: Operation.Error = error.Success;
    uopUnwrapCall(uop, posix.perform, .{undefined}) catch |err| {
        failure = err;
    };
    self.finish(id, failure);
}

fn start(self: *@This(), id: u16) !void {
    // previous op hasn't finished yet, or already started
    if (self.link_lock.isSet(id)) return;

    self.started.set(id);
    if (self.next[id] != id) {
        debug("perform: {}: {} => {}", .{ id, std.meta.activeTag(self.ops.nodes[id].used), self.next[id] });
    } else {
        debug("perform: {}: {}", .{ id, std.meta.activeTag(self.ops.nodes[id].used) });
    }
    self.link_lock.set(id); // prevent restarting
    switch (self.ops.nodes[id].used) {
        .nop => self.finish(id, error.Success),
        // TODO: add IOCP operations here
        .cancel => |op| {
            switch (self.cancel(@intCast(@intFromEnum(op.id)))) {
                .ok => self.finish(id, error.Success),
                .in_progress => self.finish(id, error.InProgress),
                .not_found => self.finish(id, error.NotFound),
            }
        },
        .timeout => self.finish(id, error.Success),
        .link_timeout => {
            var iter = self.ops.iterator();
            const res = blk: {
                while (iter.next()) |e| {
                    if (e.k != id and self.next[e.k] == id) {
                        const res = self.cancel(e.k);
                        // invalidate child's next since we expired first
                        if (res == .ok) self.next[e.k] = e.k;
                        break :blk res;
                    }
                }
                break :blk .not_found;
            };
            if (res == .ok) {
                self.finish(id, error.Expired);
            } else {
                self.finish(id, error.Success);
            }
        },
        // can be performed here, doesn't have to be dispatched to thread
        inline .child_exit, .notify_event_source, .wait_event_source, .close_event_source => |*op| {
            const posix = @import("posix.zig");
            var failure: Operation.Error = error.Success;
            _ = posix.perform(op, undefined) catch |err| {
                failure = err;
            };
            self.finish(id, failure);
        },
        else => {
            // perform non IOCP supported operation on a thread
            self.tpool.spawn(onThreadPosixExecutor, .{ self, id, &self.ops.nodes[id].used }) catch return error.SystemResources;
        },
    }

    // we need to start linked timeout immediately as well if there's one
    if (self.next[id] != id and self.ops.nodes[self.next[id]].used == .link_timeout) {
        self.link_lock.unset(self.next[id]);
        if (!self.started.isSet(self.next[id])) {
            try self.start(self.next[id]);
        }
    }
}

fn submit(self: *@This()) !bool {
    if (self.ops.empty()) return false;
    defer self.prev_id = null;
    var iter = self.ops.iterator();
    while (iter.next()) |e| {
        if (!self.started.isSet(e.k)) {
            try self.start(e.k);
        }
    }
    return true;
}

fn completition(op: anytype, self: *@This(), res: Result) void {
    if (op.out_error) |err| err.* = @errorCast(res.failure);
    if (op.link != .unlinked and self.next[res.id] != res.id) {
        if (self.ops.nodes[self.next[res.id]].used == .link_timeout) {
            switch (op.link) {
                .unlinked => unreachable,
                .soft => std.debug.assert(self.cancel(self.next[res.id]) == .ok),
                .hard => self.finish(self.next[res.id], error.Success),
            }
        } else if (res.failure != error.Success and op.link == .soft) {
            _ = self.cancel(self.next[res.id]);
        } else {
            self.link_lock.unset(self.next[res.id]);
        }
    }
}

fn uopUnwrapCall(uop: *Operation.Union, comptime func: anytype, args: anytype) @typeInfo(@TypeOf(func)).Fn.return_type.? {
    switch (uop.*) {
        inline else => |*op| return @call(.auto, func, .{op} ++ args),
    }
    unreachable;
}

fn debug(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) {
        std.debug.print("fallback: " ++ fmt ++ "\n", args);
    } else {
        if (comptime !aio.options.debug) return;
        log.debug(fmt, args);
    }
}
