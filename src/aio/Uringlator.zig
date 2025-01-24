//! Emulates io_uring execution scheduling

const std = @import("std");
const aio = @import("../aio.zig");
const Operation = @import("ops.zig").Operation;
const ItemPool = @import("minilib").ItemPool;
const DoubleBufferedFixedArrayList = @import("minilib").DoubleBufferedFixedArrayList;
const log = std.log.scoped(.aio_uringlator);

pub const EventSource = @import("posix/posix.zig").EventSource;

const Result = struct {
    failure: Operation.Error,
    id: u16,

    pub fn lessThan(_: void, a: @This(), b: @This()) bool {
        return a.id < b.id;
    }
};

ops: ItemPool(Operation.Union, u16),
prev_id: ?u16 = null, // for linking operations
next: []u16, // linked operation, points to self if none
link_lock: std.DynamicBitSetUnmanaged, // operation is waiting for linked operation to finish first
started: std.DynamicBitSetUnmanaged, // operation has started
finished: DoubleBufferedFixedArrayList(Result, u16), // operations that are finished, double buffered to be thread safe
source: EventSource, // when operations finish, they signal it using this event source

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    var ops = try ItemPool(Operation.Union, u16).init(allocator, n);
    errdefer ops.deinit(allocator);
    const next = try allocator.alloc(u16, n);
    errdefer allocator.free(next);
    var link_lock = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
    errdefer link_lock.deinit(allocator);
    var started = try std.DynamicBitSetUnmanaged.initFull(allocator, n);
    errdefer started.deinit(allocator);
    var finished = try DoubleBufferedFixedArrayList(Result, u16).init(allocator, n);
    errdefer finished.deinit(allocator);
    var source = try EventSource.init();
    errdefer source.deinit();
    return .{
        .ops = ops,
        .next = next,
        .link_lock = link_lock,
        .started = started,
        .finished = finished,
        .source = source,
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.source.deinit();
    self.ops.deinit(allocator);
    allocator.free(self.next);
    self.link_lock.deinit(allocator);
    self.started.deinit(allocator);
    self.finished.deinit(allocator);
    self.* = undefined;
}

pub fn shutdown(
    self: *@This(),
    Ctx: type,
    ctx: Ctx,
    request_cancel_cb: fn (ctx: Ctx, id: u16, uop: *Operation.Union) bool,
) void {
    var iter = self.ops.iterator();
    while (iter.next()) |e| _ = request_cancel_cb(ctx, e.k, e.v);
}

inline fn initOp(op: anytype, id: u16) void {
    if (op.out_id) |p_id| p_id.* = @enumFromInt(id);
    if (op.out_error) |out_error| out_error.* = error.Success;
}

fn addOp(self: *@This(), uop: Operation.Union, linked_to: ?u16) aio.Error!u16 {
    const id = self.ops.add(uop) catch return error.SubmissionQueueFull;
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

fn queueOperation(
    self: *@This(),
    uop: Operation.Union,
    Ctx: type,
    ctx: Ctx,
    queue_cb: fn (ctx: Ctx, id: u16, uop: *Operation.Union) aio.Error!void,
) aio.Error!u16 {
    const id = try self.addOp(uop, self.prev_id);
    switch (uop) {
        inline else => |*op| {
            debug("queue: {}: {}, {s} ({?})", .{ id, std.meta.activeTag(uop), @tagName(op.link), self.prev_id });
            if (@TypeOf(op.*) == aio.LinkTimeout and self.prev_id == null) {
                @panic("aio.LinkTimeout not linked to any operation");
            }
            if (op.link != .unlinked) self.prev_id = id else self.prev_id = null;
        },
    }
    try queue_cb(ctx, id, &self.ops.nodes[id].used);
    return id;
}

pub fn queue(
    self: *@This(),
    comptime len: u16,
    uops: []Operation.Union,
    cb: ?aio.Dynamic.QueueCallback,
    Ctx: type,
    ctx: Ctx,
    queue_cb: fn (ctx: Ctx, id: u16, uop: *Operation.Union) aio.Error!void,
) aio.Error!void {
    if (comptime len == 1) {
        const id = try self.queueOperation(uops[0], Ctx, ctx, queue_cb);
        if (cb) |f| f(self.ops.nodes[id].used, @enumFromInt(id));
    } else {
        var ids: std.BoundedArray(u16, len) = .{};
        errdefer for (ids.constSlice()) |id| self.removeOp(id);
        inline for (0..len) |i| ids.append(try self.queueOperation(uops[i], Ctx, ctx, queue_cb)) catch unreachable;
        if (cb) |f| for (ids.constSlice()) |id| f(self.ops.nodes[id].used, @enumFromInt(id));
    }
}

pub fn submit(
    self: *@This(),
    Ctx: type,
    ctx: Ctx,
    start_cb: fn (ctx: Ctx, id: u16, uop: *Operation.Union) aio.Error!void,
    request_cancel_cb: fn (ctx: Ctx, id: u16, uop: *Operation.Union) bool,
) aio.Error!bool {
    if (self.ops.empty()) return false;
    self.prev_id = null;
    var iter = self.started.iterator(.{ .kind = .unset });
    while (iter.next()) |id| {
        if (id >= self.ops.num_used) {
            break;
        }

        if (self.link_lock.isSet(id) or self.started.isSet(id)) {
            continue;
        }

        try self.start(@truncate(id), Ctx, ctx, start_cb, request_cancel_cb);
        self.started.set(id);

        // start linked timeout immediately as well if there's one
        if (self.next[id] != id and self.ops.nodes[self.next[id]].used == .link_timeout) {
            self.link_lock.unset(self.next[id]);
            if (!self.started.isSet(self.next[id])) {
                try self.start(self.next[id], Ctx, ctx, start_cb, request_cancel_cb);
                self.started.set(self.next[id]);
            }
        }
    }
    return true;
}

fn start(
    self: *@This(),
    id: u16,
    Ctx: type,
    ctx: Ctx,
    start_cb: fn (ctx: Ctx, id: u16, uop: *Operation.Union) aio.Error!void,
    request_cancel_cb: fn (ctx: Ctx, id: u16, uop: *Operation.Union) bool,
) aio.Error!void {
    if (self.next[id] != id) {
        debug("perform: {}: {} => {}", .{ id, std.meta.activeTag(self.ops.nodes[id].used), self.next[id] });
    } else {
        debug("perform: {}: {}", .{ id, std.meta.activeTag(self.ops.nodes[id].used) });
    }
    switch (self.ops.nodes[id].used) {
        .nop => self.finish(id, error.Success),
        .cancel => |op| {
            if (op.id == .invalid) @panic("trying to cancel a invalid id (id reuse bug?)");
            const cid: u16 = @intCast(@intFromEnum(op.id));
            if (self.ops.nodes[cid] != .used) {
                self.finish(id, error.NotFound);
            } else if (self.started.isSet(cid)) {
                if (!request_cancel_cb(ctx, cid, &self.ops.nodes[cid].used)) {
                    self.finish(id, error.InProgress);
                } else {
                    self.finish(id, error.Success);
                }
            } else {
                self.finish(cid, error.Canceled);
                self.finish(id, error.Success);
            }
        },
        else => try start_cb(ctx, id, &self.ops.nodes[id].used),
    }
}

pub fn complete(
    self: *@This(),
    cb: ?aio.Dynamic.CompletionCallback,
    Ctx: type,
    ctx: Ctx,
    completion_cb: fn (ctx: Ctx, id: u16, uop: *Operation.Union, failure: Operation.Error) void,
) aio.CompletionResult {
    var finished = self.finished.swap();
    std.mem.sortUnstable(Result, finished[0..], {}, Result.lessThan);
    var num_errors: u16 = 0;
    completion: for (finished, 0..) |res, idx| {
        // ignore raced completitions
        if (idx > 0 and res.id == finished[idx - 1].id) continue;

        var failure = res.failure;
        if (self.ops.nodes[res.id].used == .link_timeout and failure != error.Canceled) {
            for (finished) |res2| {
                if (res2.id != res.id and self.next[res2.id] == res.id) {
                    // timeout raced with the linked operation
                    // the linked operation will finish this timeout instead
                    continue :completion;
                }
            }
            var iter = self.ops.iterator();
            const cres: enum { ok, not_found } = blk: {
                while (iter.next()) |e| {
                    if (e.k != res.id and self.next[e.k] == res.id) {
                        self.finish(e.k, error.Canceled);
                        self.next[e.k] = e.k;
                        break :blk .ok;
                    }
                }
                break :blk .not_found;
            };
            if (cres == .ok) {
                failure = error.Expired;
            } else {
                failure = error.Success;
            }
        }

        if (failure != error.Success) {
            debug("complete: {}: {} [FAIL] {}", .{ res.id, std.meta.activeTag(self.ops.nodes[res.id].used), failure });
        } else {
            debug("complete: {}: {} [OK]", .{ res.id, std.meta.activeTag(self.ops.nodes[res.id].used) });
        }

        if (self.ops.nodes[res.id].used == .link_timeout and failure == error.Canceled) {
            // special case
        } else {
            num_errors += @intFromBool(failure != error.Success);
        }

        uopUnwrapCall(&self.ops.nodes[res.id].used, completion, .{ self, .{ .id = res.id, .failure = failure } });

        var uop = self.ops.nodes[res.id].used;
        self.removeOp(res.id);
        completion_cb(ctx, res.id, &uop, failure);
        if (cb) |f| f(uop, @enumFromInt(res.id), failure != error.Success);
    }
    return .{ .num_completed = @truncate(finished.len), .num_errors = num_errors };
}

inline fn completion(op: anytype, self: *@This(), res: Result) void {
    if (op.out_id) |id| id.* = .invalid;
    if (op.out_error) |err| err.* = @errorCast(res.failure);
    if (op.link != .unlinked and self.next[res.id] != res.id) {
        if (self.ops.nodes[self.next[res.id]].used == .link_timeout) {
            switch (op.link) {
                .unlinked => unreachable,
                .soft => self.finish(self.next[res.id], error.Canceled),
                .hard => self.finish(self.next[res.id], error.Success),
            }
        } else if (res.failure != error.Success and op.link == .soft) {
            self.finish(self.next[res.id], error.Canceled);
        } else {
            self.link_lock.unset(self.next[res.id]);
        }
    }
}

pub fn finish(self: *@This(), id: u16, failure: Operation.Error) void {
    debug("finish: {} {}", .{ id, failure });
    self.finished.add(.{ .id = id, .failure = failure }) catch unreachable;
    self.source.notify();
}

fn UopUnwrapCallArgsType(func: anytype) type {
    const params = @typeInfo(@TypeOf(func)).@"fn".params;
    comptime var fields: [params.len - 1]std.builtin.Type.StructField = undefined;
    for (&fields, params.ptr + 1, 0..) |*f, p, i| {
        if (@hasField(std.builtin.Type.StructField, "default_value_ptr")) {
            f.* = .{
                .name = std.fmt.comptimePrint("{}", .{i}),
                .default_value_ptr = null,
                .type = p.type orelse unreachable,
                .is_comptime = false,
                .alignment = 0,
            };
        } else {
            // XXX: support older zig-0.14 dev builds for a while
            f.* = .{
                .name = std.fmt.comptimePrint("{}", .{i}),
                .default_value = null,
                .type = p.type orelse unreachable,
                .is_comptime = false,
                .alignment = 0,
            };
        }
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = true,
    } });
}

pub fn uopUnwrapCall(uop: *Operation.Union, comptime func: anytype, args: UopUnwrapCallArgsType(func)) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
    switch (uop.*) {
        inline else => |*op| return @call(.auto, func, .{op} ++ args),
    }
    unreachable;
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) {
        std.debug.print("uringlator: " ++ fmt ++ "\n", args);
    } else {
        if (comptime !aio.options.debug) return;
        log.debug(fmt, args);
    }
}
