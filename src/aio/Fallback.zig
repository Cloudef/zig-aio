const std = @import("std");
const aio = @import("../aio.zig");
const Operation = @import("ops.zig").Operation;
const Pool = @import("common/types.zig").Pool;
const FixedArrayList = @import("common/types.zig").FixedArrayList;
const posix = @import("common/posix.zig");

// This mess of a code just shows how much io_uring was needed

fn debug(comptime fmt: []const u8, args: anytype) void {
    if (@import("builtin").is_test) {
        std.debug.print("fallback: " ++ fmt ++ "\n", args);
    } else {
        if (comptime !aio.options.debug) return;
        const log = std.log.scoped(.fallback);
        log.debug(fmt, args);
    }
}

pub const EventSource = posix.EventSource;

const Result = struct { failure: Operation.Error, id: u16 };

source: EventSource,
tpool: *std.Thread.Pool,
ops: Pool(Operation.Union, u16),
next: []u16,
readiness: []posix.Readiness,
link_lock: std.DynamicBitSetUnmanaged,
started: std.DynamicBitSetUnmanaged,
pending: std.DynamicBitSetUnmanaged,
pfd: FixedArrayList(posix.pollfd, u32),
prev_id: ?u16 = null, // for linking operations
finished: FixedArrayList(Result, u16),
finished_mutex: std.Thread.Mutex = .{},
// copied on completition
finished_copy: FixedArrayList(Result, u16),

pub fn isSupported(_: []const type) bool {
    return true; // very optimistic :D
}

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    var source = try EventSource.init();
    errdefer source.deinit();
    var tpool = try allocator.create(std.Thread.Pool);
    tpool.init(.{ .allocator = allocator, .n_jobs = aio.options.num_threads }) catch |err| return switch (err) {
        error.LockedMemoryLimitExceeded, error.ThreadQuotaExceeded => error.SystemResources,
        else => |e| e,
    };
    var ops = try Pool(Operation.Union, u16).init(allocator, n);
    errdefer ops.deinit(allocator);
    const next = try allocator.alloc(u16, n);
    errdefer allocator.free(next);
    const readiness = try allocator.alloc(posix.Readiness, n);
    errdefer allocator.free(readiness);
    var link_lock = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
    errdefer link_lock.deinit(allocator);
    var started = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
    errdefer started.deinit(allocator);
    var pending = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
    errdefer pending.deinit(allocator);
    var pfd = try FixedArrayList(posix.pollfd, u32).init(allocator, n + 1);
    errdefer pfd.deinit(allocator);
    var finished = try FixedArrayList(Result, u16).init(allocator, n);
    errdefer finished.deinit(allocator);
    var finished_copy = try FixedArrayList(Result, u16).init(allocator, n);
    errdefer finished_copy.deinit(allocator);
    return .{
        .source = source,
        .tpool = tpool,
        .ops = ops,
        .next = next,
        .readiness = readiness,
        .link_lock = link_lock,
        .started = started,
        .pending = pending,
        .pfd = pfd,
        .finished = finished,
        .finished_copy = finished_copy,
    };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.tpool.deinit();
    allocator.destroy(self.tpool);
    var iter = self.ops.iterator();
    while (iter.next()) |e| uopUnwrapCall(e.v, posix.closeReadiness, .{self.readiness[e.k]});
    self.ops.deinit(allocator);
    allocator.free(self.next);
    self.link_lock.deinit(allocator);
    self.started.deinit(allocator);
    self.pending.deinit(allocator);
    allocator.free(self.readiness);
    self.pfd.deinit(allocator);
    self.finished.deinit(allocator);
    self.finished_copy.deinit(allocator);
    self.source.deinit();
    self.* = undefined;
}

fn initOp(op: anytype, id: u16) void {
    if (comptime @hasField(@TypeOf(op.*), "out_id")) {
        if (op.out_id) |p_id| p_id.* = @enumFromInt(id);
    }
    if (comptime @hasField(@TypeOf(op.*), "out_error")) {
        if (op.out_error) |out_error| out_error.* = error.Success;
    }
}

fn addOp(self: *@This(), uop: Operation.Union, linked_to: ?u16, readiness: posix.Readiness) !u16 {
    const id = try self.ops.add(uop);
    if (linked_to) |ln| {
        self.next[ln] = id;
        self.link_lock.set(id);
    } else {
        self.link_lock.unset(id);
    }
    // to account a mistake where link is set without a next op
    self.next[id] = id;
    self.readiness[id] = readiness;
    self.started.unset(id);
    self.pending.unset(id);
    uopUnwrapCall(&self.ops.nodes[id].used, initOp, .{id});
    return id;
}

fn removeOp(self: *@This(), id: u16) void {
    uopUnwrapCall(&self.ops.nodes[id].used, posix.closeReadiness, .{self.readiness[id]});
    self.readiness[id] = .{};
    self.next[id] = id;
    self.ops.remove(id);
}

inline fn queueOperation(self: *@This(), op: anytype) aio.Error!u16 {
    const tag = @tagName(comptime Operation.tagFromPayloadType(@TypeOf(op.*)));
    const uop = @unionInit(Operation.Union, tag, op.*);
    const id = try self.addOp(uop, self.prev_id, try posix.openReadiness(op));
    debug("queue: {}: {}, {s} ({?})", .{ id, std.meta.activeTag(uop), @tagName(op.link), self.prev_id });
    if (op.link != .unlinked) self.prev_id = id else self.prev_id = null;
    return id;
}

pub fn queue(self: *@This(), comptime len: u16, work: anytype) aio.Error!void {
    if (comptime len == 1) {
        _ = try self.queueOperation(&work.ops[0]);
    } else {
        var ids: std.BoundedArray(u16, len) = .{};
        errdefer for (ids.constSlice()) |id| self.removeOp(id);
        inline for (&work.ops) |*op| {
            ids.append(try self.queueOperation(op)) catch unreachable;
        }
    }
}

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode, cb: ?aio.Dynamic.Callback) aio.Error!aio.CompletionResult {
    if (!try self.submit()) return .{};
    defer self.pfd.reset();

    // I was thinking if we should use epoll/kqueue if available
    // The pros is that we don't have to iterate the self.pfd.items
    // However, the self.pfd.items changes frequently so we have to keep re-registering fds anyways
    // Poll is pretty much anywhere, so poll it is. This is fallback backend anyways.
    const n = posix.poll(self.pfd.items[0..self.pfd.len], if (mode == .blocking) -1 else 0) catch |err| return switch (err) {
        error.NetworkSubsystemFailed => unreachable,
        else => |e| e,
    };
    if (n == 0) return .{};

    var res: aio.CompletionResult = .{};
    for (self.pfd.items[0..self.pfd.len]) |pfd| {
        if (pfd.revents == 0) continue;
        std.debug.assert(pfd.revents & std.posix.POLL.NVAL == 0);
        if (pfd.fd == self.source.fd) {
            std.debug.assert(pfd.revents & std.posix.POLL.ERR == 0);
            std.debug.assert(pfd.revents & std.posix.POLL.HUP == 0);
            self.source.wait();
            res = self.handleFinished(cb);
        } else {
            var iter = self.ops.iterator();
            while (iter.next()) |e| if (pfd.fd == self.readiness[e.k].fd) {
                if (pfd.revents & std.posix.POLL.ERR != 0 or pfd.revents & std.posix.POLL.HUP != 0) {
                    self.finish(e.k, error.Unexpected);
                    continue;
                }
                // canceled
                if (!self.pending.isSet(e.k)) continue;
                // reset started bit, the operation will spawn next cycle
                self.started.unset(e.k);
            };
        }
    }

    return res;
}

pub fn immediate(comptime len: u16, work: anytype) aio.Error!u16 {
    var sfb = std.heap.stackFallback(len * 1024, std.heap.page_allocator);
    const allocator = sfb.get();
    var wrk = try init(allocator, len);
    defer wrk.deinit(allocator);
    try wrk.queue(len, work);
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
    defer self.source.notify();
    self.finished_mutex.lock();
    defer self.finished_mutex.unlock();
    debug("finish: {} {}", .{ id, failure });
    for (self.finished.items[0..self.finished.len]) |*i| if (i.id == id) {
        i.* = .{ .id = id, .failure = failure };
        return;
    };
    self.finished.add(.{ .id = id, .failure = failure }) catch unreachable;
}

fn cancel(self: *@This(), id: u16) enum { in_progress, not_found, ok } {
    if (self.started.isSet(id) and !self.pending.isSet(id)) {
        return .in_progress;
    }
    if (self.ops.nodes[id] != .used) {
        return .not_found;
    }
    // collect the result later
    self.finish(id, error.OperationCanceled);
    return .ok;
}

fn onThreadExecutor(self: *@This(), id: u16, uop: *Operation.Union, readiness: posix.Readiness) void {
    var failure: Operation.Error = error.Success;
    uopUnwrapCall(uop, posix.perform, .{readiness}) catch |err| {
        failure = err;
    };
    self.finish(id, failure);
}

fn start(self: *@This(), id: u16) !void {
    if (self.link_lock.isSet(id)) return; // previous op hasn't finished yet

    self.started.set(id);
    if (self.readiness[id].mode == .noop or self.pending.isSet(id)) {
        if (self.next[id] != id) {
            debug("perform: {}: {} => {}", .{ id, std.meta.activeTag(self.ops.nodes[id].used), self.next[id] });
        } else {
            debug("perform: {}: {}", .{ id, std.meta.activeTag(self.ops.nodes[id].used) });
        }
        switch (self.ops.nodes[id].used) {
            .nop => self.finish(id, error.Success),
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
            else => {
                self.pending.unset(id);
                self.started.unset(id);
                self.link_lock.set(id); // prevent restarting
                self.tpool.spawn(onThreadExecutor, .{ self, id, &self.ops.nodes[id].used, self.readiness[id] }) catch return error.SystemResources;
            },
        }
    } else {
        // pending for readiness, starts later
        if (self.next[id] != id) {
            debug("pending: {}: {} => {}", .{ id, std.meta.activeTag(self.ops.nodes[id].used), self.next[id] });
        } else {
            debug("pending: {}: {}", .{ id, std.meta.activeTag(self.ops.nodes[id].used) });
        }
        try uopUnwrapCall(&self.ops.nodes[id].used, posix.armReadiness, .{self.readiness[id]});
        self.pending.set(id);
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
    self.pfd.add(.{ .fd = self.source.fd, .events = std.posix.POLL.IN, .revents = 0 }) catch unreachable;
    var iter = self.ops.iterator();
    while (iter.next()) |e| {
        if (!self.started.isSet(e.k)) {
            try self.start(e.k);
        }
        if (self.pending.isSet(e.k)) {
            std.debug.assert(self.readiness[e.k].fd != posix.invalid_fd);
            self.pfd.add(.{
                .fd = self.readiness[e.k].fd,
                .events = switch (self.readiness[e.k].mode) {
                    .noop => unreachable,
                    .in => std.posix.POLL.IN,
                    .out => std.posix.POLL.OUT,
                },
                .revents = 0,
            }) catch unreachable;
        }
    }
    return true;
}

fn completition(op: anytype, self: *@This(), res: Result) void {
    if (comptime @hasField(@TypeOf(op.*), "out_error")) {
        if (op.out_error) |err| err.* = @errorCast(res.failure);
    }

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

fn handleFinished(self: *@This(), cb: ?aio.Dynamic.Callback) aio.CompletionResult {
    {
        self.finished_mutex.lock();
        defer self.finished_mutex.unlock();
        @memcpy(self.finished_copy.items[0..self.finished.items.len], self.finished.items[0..self.finished.items.len]);
        self.finished_copy.len = self.finished.len;
        self.finished.reset();
    }

    var num_errors: u16 = 0;
    for (self.finished_copy.items[0..self.finished_copy.len]) |res| {
        if (res.failure != error.Success) {
            debug("complete: {}: {} [FAIL] {}", .{ res.id, std.meta.activeTag(self.ops.nodes[res.id].used), res.failure });
        } else {
            debug("complete: {}: {} [OK]", .{ res.id, std.meta.activeTag(self.ops.nodes[res.id].used) });
        }
        defer self.removeOp(res.id);
        if (self.ops.nodes[res.id].used == .link_timeout and res.failure == error.OperationCanceled) {
            // special case
        } else {
            num_errors += @intFromBool(res.failure != error.Success);
        }
        uopUnwrapCall(&self.ops.nodes[res.id].used, completition, .{ self, res });
        if (cb) |f| f(self.ops.nodes[res.id].used);
    }

    return .{ .num_completed = self.finished_copy.len, .num_errors = num_errors };
}

fn uopUnwrapCall(uop: *Operation.Union, comptime func: anytype, args: anytype) @typeInfo(@TypeOf(func)).Fn.return_type.? {
    switch (uop.*) {
        inline else => |*op| return @call(.auto, func, .{op} ++ args),
    }
    unreachable;
}
