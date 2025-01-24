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
signaled: bool = false, // some operations have signaled immediately, optimization to avoid running poll when not required

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

pub fn shutdown(self: *@This(), backend: anytype) void {
    var iter = self.ops.iterator();
    while (iter.next()) |e| {
        switch (e.v.*) {
            inline else => |*op| {
                _ = backend.uringlator_cancel(op, e.k);
            },
        }
    }
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
    switch (self.ops.nodes[id].used) {
        inline else => |*op| {
            if (op.out_id) |p_id| p_id.* = @enumFromInt(id);
            if (op.out_error) |out_error| out_error.* = error.Success;
        },
    }
    return id;
}

fn removeOp(self: *@This(), id: u16) void {
    self.next[id] = id;
    self.ops.remove(id);
}

fn queueOperation(self: *@This(), uop: Operation.Union, backend: anytype) aio.Error!u16 {
    const id = try self.addOp(uop, self.prev_id);
    switch (self.ops.nodes[id].used) {
        inline else => |*op| {
            debug("queue: {}: {}, {s} ({?})", .{ id, std.meta.activeTag(uop), @tagName(op.link), self.prev_id });
            if (op.link != .unlinked) self.prev_id = id else self.prev_id = null;
            try backend.uringlator_queue(op, id);
        },
    }
    return id;
}

pub fn queue(
    self: *@This(),
    comptime len: u16,
    uops: []Operation.Union,
    backend: anytype,
    handler: anytype,
) aio.Error!void {
    if (comptime len == 1) {
        const id = try self.queueOperation(uops[0], backend);
        if (@TypeOf(handler) != void) {
            switch (self.ops.nodes[id].used) {
                inline else => |*op| {
                    handler.aio_queue(op, @enumFromInt(id));
                },
            }
        }
    } else {
        var ids: std.BoundedArray(u16, len) = .{};
        errdefer for (ids.constSlice()) |id| self.removeOp(id);
        inline for (0..len) |i| ids.append(try self.queueOperation(uops[i], backend)) catch unreachable;
        if (@TypeOf(handler) != void) {
            for (ids.constSlice()) |id| {
                switch (self.ops.nodes[id].used) {
                    inline else => |*op| {
                        handler.aio_queue(op, @enumFromInt(id));
                    },
                }
            }
        }
    }
}

pub fn submit(self: *@This(), backend: anytype) aio.Error!bool {
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

        try self.start(@truncate(id), backend);
        self.started.set(id);

        // start linked timeout immediately as well if there's one
        if (self.next[id] != id and self.ops.nodes[self.next[id]].used == .link_timeout) {
            self.link_lock.unset(self.next[id]);
            if (!self.started.isSet(self.next[id])) {
                try self.start(self.next[id], backend);
                self.started.set(self.next[id]);
            }
        }
    }
    return true;
}

fn start(self: *@This(), id: u16, backend: anytype) aio.Error!void {
    if (self.next[id] != id) {
        debug("perform: {}: {} => {}", .{ id, std.meta.activeTag(self.ops.nodes[id].used), self.next[id] });
    } else {
        debug("perform: {}: {}", .{ id, std.meta.activeTag(self.ops.nodes[id].used) });
    }
    switch (self.ops.nodes[id].used) {
        .nop => self.finish(id, error.Success, .thread_unsafe),
        .cancel => |*op| {
            if (op.id == .invalid) @panic("trying to cancel a invalid id (id reuse bug?)");
            const cid: u16 = @intCast(@intFromEnum(op.id));
            if (self.ops.nodes[cid] != .used) {
                self.finish(id, error.NotFound, .thread_unsafe);
            } else if (self.started.isSet(cid)) {
                switch (self.ops.nodes[cid].used) {
                    inline else => |*cop| {
                        if (!backend.uringlator_cancel(cop, cid)) {
                            self.finish(id, error.InProgress, .thread_unsafe);
                        } else {
                            self.finish(id, error.Success, .thread_unsafe);
                        }
                    },
                }
            } else {
                self.finish(cid, error.Canceled, .thread_unsafe);
                self.finish(id, error.Success, .thread_unsafe);
            }
        },
        inline else => |*op| try backend.uringlator_start(op, id),
    }
}

pub fn complete(self: *@This(), backend: anytype, handler: anytype) aio.CompletionResult {
    self.signaled = false;
    var finished = self.finished.swap();
    std.mem.sortUnstable(Result, finished[0..], {}, Result.lessThan);
    var num_errors: u16 = 0;
    completion: for (finished, 0..) |res, idx| {
        // ignore raced completitions
        if (idx > 0 and res.id == finished[idx - 1].id) continue;
        switch (self.ops.nodes[res.id].used) {
            inline else => |*op| {
                var failure = res.failure;
                if ((comptime @TypeOf(op.*) == aio.LinkTimeout) and failure != error.Canceled) {
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
                                self.finish(e.k, error.Canceled, .thread_unsafe);
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

                const failed: bool = blk: {
                    if ((comptime @TypeOf(op.*) == aio.LinkTimeout) and failure == error.Canceled) {
                        break :blk false;
                    } else {
                        break :blk failure != error.Success;
                    }
                };

                if (failed) {
                    debug("complete: {}: {} [FAIL] {}", .{ res.id, comptime Operation.tagFromPayloadType(@TypeOf(op.*)), failure });
                } else {
                    debug("complete: {}: {} [OK]", .{ res.id, comptime Operation.tagFromPayloadType(@TypeOf(op.*)) });
                }

                num_errors += @intFromBool(failed);

                if (op.out_id) |id| id.* = .invalid;
                if (op.out_error) |err| err.* = @errorCast(failure);
                if (op.link != .unlinked and self.next[res.id] != res.id) {
                    if (self.ops.nodes[self.next[res.id]].used == .link_timeout) {
                        switch (op.link) {
                            .unlinked => unreachable,
                            .soft => self.finish(self.next[res.id], error.Canceled, .thread_unsafe),
                            .hard => self.finish(self.next[res.id], error.Success, .thread_unsafe),
                        }
                    } else if (failure != error.Success and op.link == .soft) {
                        self.finish(self.next[res.id], error.Canceled, .thread_unsafe);
                    } else {
                        self.link_lock.unset(self.next[res.id]);
                    }
                }

                var cpy = op.*;
                self.removeOp(res.id);
                backend.uringlator_complete(&cpy, res.id, failure);

                if (@TypeOf(handler) != void) {
                    handler.aio_complete(&cpy, @enumFromInt(res.id), failed);
                }
            },
        }
    }
    return .{ .num_completed = @truncate(finished.len), .num_errors = num_errors };
}

pub const FinishMode = enum {
    thread_safe,
    thread_unsafe,
};

pub fn finish(self: *@This(), id: u16, failure: Operation.Error, comptime mode: FinishMode) void {
    debug("finish: {} {}", .{ id, failure });
    self.finished.add(.{ .id = id, .failure = failure }) catch unreachable;
    if (mode == .thread_safe) {
        self.source.notify();
    } else {
        self.signaled = true;
    }
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) {
        std.debug.print("uringlator: " ++ fmt ++ "\n", args);
    } else {
        if (comptime !aio.options.debug) return;
        log.debug(fmt, args);
    }
}
