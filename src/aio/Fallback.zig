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

pub const EventSource = @import("common/EventFd.zig");

efd: std.posix.fd_t,
tpool: *std.Thread.Pool,
sq: Queue,
pfd: FixedArrayList(std.posix.pollfd, u32),
prev_id: ?u16 = null, // for linking operations
completion_mutex: std.Thread.Mutex = .{}, // mutex for non thread safe functions

pub fn isSupported(_: []const type) bool {
    return true; // very optimistic :D
}

pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
    const efd = try std.posix.eventfd(0, std.os.linux.EFD.NONBLOCK | std.os.linux.EFD.CLOEXEC);
    errdefer std.posix.close(efd);
    var tpool = try allocator.create(std.Thread.Pool);
    tpool.init(.{ .allocator = allocator, .n_jobs = aio.options.num_threads }) catch |err| return switch (err) {
        error.LockedMemoryLimitExceeded, error.ThreadQuotaExceeded => error.SystemResources,
        else => |e| e,
    };
    var sq = try Queue.init(allocator, n);
    errdefer sq.deinit(allocator);
    var pfd = try FixedArrayList(std.posix.pollfd, u32).init(allocator, n + 1);
    errdefer pfd.deinit(allocator);
    return .{ .efd = efd, .tpool = tpool, .sq = sq, .pfd = pfd };
}

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.tpool.deinit();
    allocator.destroy(self.tpool);
    self.sq.deinit(allocator);
    self.pfd.deinit(allocator);
    std.posix.close(self.efd);
    self.* = undefined;
}

pub fn queue(self: *@This(), comptime len: u16, work: anytype) aio.Error!void {
    self.completion_mutex.lock();
    defer self.completion_mutex.unlock();
    var ids: std.BoundedArray(u16, len) = .{};
    errdefer for (ids.constSlice()) |id| self.sq.remove(id);
    inline for (&work.ops) |*op| {
        const tag = @tagName(comptime Operation.tagFromPayloadType(@TypeOf(op.*)));
        const uop = @unionInit(Operation.Union, tag, op.*);
        const id = try self.sq.add(uop, self.prev_id, try posix.openReadiness(op));
        debug("queue: {}: {}, {s} ({?})", .{ id, std.meta.activeTag(uop), @tagName(op.link), self.prev_id });
        ids.append(id) catch unreachable;
        if (op.link != .unlinked) self.prev_id = id else self.prev_id = null;
    }
}

pub fn complete(self: *@This(), mode: aio.Dynamic.CompletionMode) aio.Error!aio.CompletionResult {
    if (!try self.submitThreadSafe()) return .{};
    defer self.pfd.reset();

    // TODO: use kqueue and epoll instead
    _ = std.posix.poll(self.pfd.items[0..self.pfd.len], if (mode == .blocking) -1 else 0) catch |err| return switch (err) {
        error.NetworkSubsystemFailed => unreachable,
        else => |e| e,
    };

    self.completion_mutex.lock();
    defer self.completion_mutex.unlock();

    var num_errors: u16 = 0;
    var num_completed: u16 = 0;
    for (self.pfd.items[0..self.pfd.len]) |pfd| {
        if (pfd.revents == 0) continue;
        std.debug.assert(pfd.revents & std.posix.POLL.NVAL == 0);
        if (pfd.fd == self.efd) {
            std.debug.assert(pfd.revents & std.posix.POLL.ERR == 0);
            std.debug.assert(pfd.revents & std.posix.POLL.HUP == 0);
            var trash: u64 align(1) = undefined;
            _ = std.posix.read(self.efd, std.mem.asBytes(&trash)) catch {};
            defer self.sq.finished.reset();
            var last_len: u16 = 0;
            while (last_len != self.sq.finished.len) {
                const start_idx = last_len;
                last_len = self.sq.finished.len;
                for (self.sq.finished.items[start_idx..self.sq.finished.len]) |res| {
                    if (res.failure != error.Success) {
                        debug("complete: {}: {} [FAIL] {}", .{ res.id, std.meta.activeTag(self.sq.ops.nodes[res.id].used), res.failure });
                    } else {
                        debug("complete: {}: {} [OK]", .{ res.id, std.meta.activeTag(self.sq.ops.nodes[res.id].used) });
                    }
                    defer self.sq.remove(res.id);
                    if (self.sq.ops.nodes[res.id].used == .link_timeout and res.failure == error.OperationCanceled) {
                        // special case
                    } else {
                        num_errors += @intFromBool(res.failure != error.Success);
                    }
                    uopUnwrapCall(&self.sq.ops.nodes[res.id].used, completitionNotThreadSafe, .{ self, res });
                }
            }
            num_completed = self.sq.finished.len;
        } else {
            var iter = self.sq.ops.iterator();
            while (iter.next()) |e| if (pfd.fd == self.sq.readiness[e.k].fd) {
                if (pfd.revents & std.posix.POLL.ERR != 0 or pfd.revents & std.posix.POLL.HUP != 0) {
                    self.finishNotThreadSafe(e.k, error.Unexpected);
                    continue;
                }
                // canceled
                if (!self.sq.pending.isSet(e.k)) continue;
                // reset started bit, the operation will spawn next cycle
                self.sq.started.unset(e.k);
            };
        }
    }

    return .{ .num_completed = num_completed, .num_errors = num_errors };
}

pub fn immediate(comptime len: u16, work: anytype) aio.Error!u16 {
    var mem: [len * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);
    var wrk = try init(fba.allocator(), len);
    defer wrk.deinit(fba.allocator());
    try wrk.queue(len, work);
    var n: u16 = len;
    var num_errors: u16 = 0;
    while (n > 0) {
        const res = try wrk.complete(.blocking);
        n -= res.num_completed;
        num_errors += res.num_errors;
    }
    return num_errors;
}

const Queue = struct {
    const Result = struct { failure: Operation.Error, id: u16 };
    ops: Pool(Operation.Union, u16),
    next: []u16,
    readiness: []posix.Readiness,
    link_lock: std.DynamicBitSetUnmanaged,
    started: std.DynamicBitSetUnmanaged,
    pending: std.DynamicBitSetUnmanaged,
    finished: FixedArrayList(Result, u16),

    pub fn init(allocator: std.mem.Allocator, n: u16) !@This() {
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
        var finished = try FixedArrayList(Result, u16).init(allocator, n);
        errdefer finished.deinit(allocator);
        return .{
            .ops = ops,
            .next = next,
            .readiness = readiness,
            .link_lock = link_lock,
            .started = started,
            .pending = pending,
            .finished = finished,
        };
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        var iter = self.ops.iterator();
        while (iter.next()) |e| uopUnwrapCall(e.v, posix.closeReadiness, .{self.readiness[e.k]});
        self.ops.deinit(allocator);
        allocator.free(self.next);
        self.link_lock.deinit(allocator);
        self.started.deinit(allocator);
        self.pending.deinit(allocator);
        allocator.free(self.readiness);
        self.finished.deinit(allocator);
        self.* = undefined;
    }

    fn initOp(op: anytype, id: u16) void {
        if (@hasField(@TypeOf(op.*), "out_id")) {
            if (op.out_id) |p_id| p_id.* = @enumFromInt(id);
        }
        if (op.out_error) |out_error| out_error.* = error.Success;
    }

    pub fn add(self: *@This(), uop: Operation.Union, linked_to: ?u16, readiness: posix.Readiness) !u16 {
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

    pub fn remove(self: *@This(), id: u16) void {
        uopUnwrapCall(&self.ops.nodes[id].used, posix.closeReadiness, .{self.readiness[id]});
        self.readiness[id] = .{};
        self.next[id] = id;
        self.ops.remove(id);
    }

    pub fn finish(self: *@This(), res: Result) void {
        for (self.finished.items[0..self.finished.len]) |*i| if (i.id == res.id) {
            i.* = res;
            return;
        };
        self.finished.add(res) catch unreachable;
    }
};

fn finishNotThreadSafe(self: *@This(), id: u16, failure: Operation.Error) void {
    self.sq.link_lock.set(id); // prevent restarting
    self.sq.started.unset(id);
    self.sq.pending.unset(id);
    self.sq.finish(.{ .id = id, .failure = failure });
    _ = std.posix.write(self.efd, &std.mem.toBytes(@as(u64, 1))) catch unreachable;
}

fn cancelNotThreadSafe(self: *@This(), id: u16) enum { in_progress, not_found, ok } {
    if (self.sq.started.isSet(id) and !self.sq.pending.isSet(id)) {
        return .in_progress;
    }
    if (self.sq.ops.nodes[id] != .used) {
        return .not_found;
    }
    // collect the result later
    self.finishNotThreadSafe(id, error.OperationCanceled);
    return .ok;
}

fn onThreadExecutor(self: *@This(), id: u16) void {
    var failure: Operation.Error = error.Success;
    uopUnwrapCall(&self.sq.ops.nodes[id].used, posix.perform, .{}) catch |err| {
        failure = err;
    };
    self.completion_mutex.lock();
    defer self.completion_mutex.unlock();
    self.finishNotThreadSafe(id, failure);
}

fn startNotThreadSafe(self: *@This(), id: u16) !void {
    if (self.sq.link_lock.isSet(id)) return; // previous op hasn't finished yet

    self.sq.started.set(id);
    if (self.sq.readiness[id].mode == .noop or self.sq.pending.isSet(id)) {
        if (self.sq.next[id] != id) {
            debug("perform: {}: {} => {}", .{ id, std.meta.activeTag(self.sq.ops.nodes[id].used), self.sq.next[id] });
        } else {
            debug("perform: {}: {}", .{ id, std.meta.activeTag(self.sq.ops.nodes[id].used) });
        }
        switch (self.sq.ops.nodes[id].used) {
            .cancel => |op| {
                switch (self.cancelNotThreadSafe(@intCast(@intFromEnum(op.id)))) {
                    .ok => self.finishNotThreadSafe(id, error.Success),
                    .in_progress => self.finishNotThreadSafe(id, error.InProgress),
                    .not_found => self.finishNotThreadSafe(id, error.NotFound),
                }
            },
            .timeout => self.finishNotThreadSafe(id, error.Success),
            .link_timeout => {
                var iter = self.sq.ops.iterator();
                const res = blk: {
                    while (iter.next()) |e| {
                        if (e.k != id and self.sq.next[e.k] == id) {
                            const res = self.cancelNotThreadSafe(e.k);
                            // invalidate child's next since we expired first
                            if (res == .ok) self.sq.next[e.k] = e.k;
                            break :blk res;
                        }
                    }
                    break :blk .not_found;
                };
                if (res == .ok) {
                    self.finishNotThreadSafe(id, error.Expired);
                } else {
                    self.finishNotThreadSafe(id, error.Success);
                }
            },
            else => {
                self.sq.pending.unset(id);
                self.tpool.spawn(onThreadExecutor, .{ self, id }) catch return error.SystemResources;
            },
        }
    } else {
        // pending for readiness, starts later
        if (self.sq.next[id] != id) {
            debug("pending: {}: {} => {}", .{ id, std.meta.activeTag(self.sq.ops.nodes[id].used), self.sq.next[id] });
        } else {
            debug("pending: {}: {}", .{ id, std.meta.activeTag(self.sq.ops.nodes[id].used) });
        }
        try uopUnwrapCall(&self.sq.ops.nodes[id].used, posix.armReadiness, .{self.sq.readiness[id]});
        self.sq.pending.set(id);
    }

    // we need to start linked timeout immediately as well if there's one
    if (self.sq.next[id] != id and self.sq.ops.nodes[self.sq.next[id]].used == .link_timeout) {
        self.sq.link_lock.unset(self.sq.next[id]);
        if (!self.sq.started.isSet(self.sq.next[id])) {
            try self.startNotThreadSafe(self.sq.next[id]);
        }
    }
}

fn submitThreadSafe(self: *@This()) !bool {
    self.completion_mutex.lock();
    defer self.completion_mutex.unlock();
    if (self.sq.ops.empty()) return false;
    defer self.prev_id = null;
    self.pfd.add(.{ .fd = self.efd, .events = std.posix.POLL.IN, .revents = 0 }) catch unreachable;
    var iter = self.sq.ops.iterator();
    while (iter.next()) |e| {
        if (!self.sq.started.isSet(e.k)) {
            try self.startNotThreadSafe(e.k);
        }
        if (self.sq.pending.isSet(e.k)) {
            std.debug.assert(self.sq.readiness[e.k].fd != 0);
            self.pfd.add(.{
                .fd = self.sq.readiness[e.k].fd,
                .events = switch (self.sq.readiness[e.k].mode) {
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

fn completitionNotThreadSafe(op: anytype, self: *@This(), res: Queue.Result) void {
    switch (op.counter) {
        .dec => |c| c.* -= 1,
        .inc => |c| c.* += 1,
        .nop => {},
    }

    if (@hasField(@TypeOf(op.*), "out_id")) {
        if (op.out_error) |err| err.* = @errorCast(res.failure);
    }

    if (op.link != .unlinked and self.sq.next[res.id] != res.id) {
        if (self.sq.ops.nodes[self.sq.next[res.id]].used == .link_timeout) {
            switch (op.link) {
                .unlinked => unreachable,
                .soft => std.debug.assert(self.cancelNotThreadSafe(self.sq.next[res.id]) == .ok),
                .hard => self.finishNotThreadSafe(self.sq.next[res.id], error.Success),
            }
        } else if (res.failure != error.Success and op.link == .soft) {
            _ = self.cancelNotThreadSafe(self.sq.next[res.id]);
        } else {
            self.sq.link_lock.unset(self.sq.next[res.id]);
        }
    }
}

fn uopUnwrapCall(uop: *Operation.Union, comptime func: anytype, args: anytype) @typeInfo(@TypeOf(func)).Fn.return_type.? {
    switch (uop.*) {
        inline else => |*op| return @call(.auto, func, .{op} ++ args),
    }
    unreachable;
}
