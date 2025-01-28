const std = @import("std");
const coro = @import("../coro.zig");
const aio = @import("aio");
const Frame = @import("Frame.zig");

fn wakeupWaiters(list: *Frame.WaitList, status: anytype) void {
    var next = list.first;
    while (next) |node| {
        next = node.next;
        node.data.cast().wakeup(status);
    }
}

pub const Semaphore = struct {
    waiters: Frame.WaitList = .{},
    used: bool = false,

    pub const Error = error{Canceled};

    pub fn lock(self: *@This()) Error!void {
        if (Frame.current()) |frame| {
            if (frame.canceled) return error.Canceled;

            if (!self.used) {
                self.used = true;
                return;
            }

            self.waiters.prepend(&frame.wait_link);
            defer self.waiters.remove(&frame.wait_link);

            while (!frame.canceled) {
                Frame.yield(.semaphore);
                if (!self.used) {
                    self.used = true;
                    break;
                }
            }

            if (frame.canceled) return error.Canceled;
        } else unreachable; // can only be used in tasks
    }

    pub fn unlock(self: *@This()) void {
        if (!self.used) return;
        self.used = false;
        wakeupWaiters(&self.waiters, .semaphore);
    }
};

pub const ResetEvent = struct {
    waiters: Frame.WaitList = .{},
    is_set: bool = false,

    pub const Error = error{Canceled};

    pub fn wait(self: *@This()) Error!void {
        if (Frame.current()) |frame| {
            if (frame.canceled) return error.Canceled;
            if (self.is_set) return;
            self.waiters.prepend(&frame.wait_link);
            defer self.waiters.remove(&frame.wait_link);
            while (!self.is_set and !frame.canceled) Frame.yield(.reset_event);
            if (frame.canceled) return error.Canceled;
        } else unreachable; // can only be used in tasks
    }

    pub fn set(self: *@This()) void {
        self.is_set = true;
        wakeupWaiters(&self.waiters, .reset_event);
    }

    pub fn reset(self: *@This()) void {
        self.is_set = false;
    }
};

/// A thread-safe mutual exclusion between schedulers.
const Mutex = struct {
    native: std.Thread.Mutex,
    event_source: aio.EventSource,

    pub fn init() !@This() {
        return .{
            .native = .{},
            .event_source = try aio.EventSource.init(),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.event_source.deinit();
    }

    pub fn lock(self: *@This()) !void {
        if (Frame.current()) |frame| {
            if (frame.canceled) return error.Canceled;

            while (!self.native.tryLock()) {
                try coro.io.single(.wait_event_source, .{
                    .source = &self.event_source,
                });

                if (frame.canceled) return error.Canceled;
            }
        } else {
            while (!self.native.tryLock()) {
                self.event_source.wait();
            }
        }
    }

    pub fn unlock(self: *@This()) void {
        self.native.unlock();
        self.event_source.notify();
    }
};

/// A thread-safe read-write lock between schedulers.
pub const RwLock = struct {
    event_source: aio.EventSource,
    guard: std.Thread.Mutex,
    locked: bool,
    counter: usize,

    pub fn init() !@This() {
        return .{
            .event_source = try aio.EventSource.init(),
            .guard = .{},
            .locked = false,
            .counter = 0,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.event_source.deinit();
    }

    fn tryLock(self: *@This()) bool {
        self.guard.lock();
        defer self.guard.unlock();

        if (!self.locked) {
            self.locked = true;
            self.counter = 0;
            return true;
        }

        return false;
    }

    fn tryLockShared(self: *@This()) bool {
        self.guard.lock();
        defer self.guard.unlock();

        if (self.locked) {
            if (self.counter > 0) {
                self.counter += 1;
                return true;
            }
        } else {
            self.locked = true;
            self.counter = 1;
            return true;
        }

        return false;
    }

    pub fn lock(self: *@This()) !void {
        if (Frame.current()) |frame| {
            if (frame.canceled) return error.Canceled;

            while (!self.tryLock()) {
                try coro.io.single(.wait_event_source, .{
                    .source = &self.event_source,
                });

                if (frame.canceled) return error.Canceled;
            }
        } else {
            while (!self.tryLock()) {
                self.event_source.wait();
            }
        }
    }

    pub fn lockShared(self: *@This()) !void {
        if (Frame.current()) |frame| {
            if (frame.canceled) return error.Canceled;

            defer self.event_source.notify();

            while (!self.tryLockShared()) {
                try coro.io.single(.wait_event_source, .{
                    .source = &self.event_source,
                });

                if (frame.canceled) return error.Canceled;
            }
        } else {
            defer self.event_source.notify();

            while (!self.tryLockShared()) {
                self.event_source.wait();
            }
        }
    }

    pub fn unlock(self: *@This()) void {
        self.guard.lock();
        defer self.event_source.notify();
        defer self.guard.unlock();

        if (self.counter > 0) {
            self.counter -= 1;
            if (self.counter != 0) {
                return;
            }
        }

        self.locked = false;
    }
};

test "Mutex" {
    const Test = struct {
        fn incrementer(lock: *Mutex, value: *usize) !void {
            try lock.lock();
            defer lock.unlock();

            const stored = value.*;

            // simulates a "workload"
            try coro.io.single(.timeout, .{ .ns = std.time.ns_per_ms });

            value.* = stored + 1000;
        }

        fn test_thread(lock: *Mutex, value: *usize) !void {
            var scheduler = try coro.Scheduler.init(std.testing.allocator, .{});
            defer scheduler.deinit();

            for (0..128) |_| {
                _ = try scheduler.spawn(incrementer, .{ lock, value }, .{ .detached = true });
            }

            try scheduler.run(.wait);
        }
    };

    var lock = try Mutex.init();
    defer lock.deinit();

    var value: usize = 0;

    var threads: [8]std.Thread = undefined;

    for (0..8) |i| {
        threads[i] = try std.Thread.spawn(.{}, Test.test_thread, .{ &lock, &value });
    }

    for (threads) |thread| {
        thread.join();
    }

    try std.testing.expectEqual(value, 1024000);
}

test "RwLock" {
    const Test = struct {
        fn incrementer(lock: *RwLock, value: *usize, check_value: *usize) !void {
            try lock.lock();
            defer lock.unlock();

            value.* += 1000;

            const stored = check_value.*;

            // simulates a "workload" + makes coroutines to try lock
            try coro.io.single(.timeout, .{ .ns = std.time.ns_per_ms });

            check_value.* = stored + 1000;
        }

        fn checker(lock: *RwLock, value: *usize, check_value: *usize) !void {
            while (true) {
                // simulates a "workload"
                try coro.io.single(.timeout, .{ .ns = std.time.ns_per_ms });

                try lock.lockShared();
                defer lock.unlock();

                if (value.* == 1024000 and check_value.* == 1024000) break;
            }
        }

        fn test_thread(lock: *RwLock, value: *usize, check_value: *usize) !void {
            var scheduler = try coro.Scheduler.init(std.testing.allocator, .{});
            defer scheduler.deinit();

            for (0..128) |_| {
                _ = try scheduler.spawn(incrementer, .{ lock, value, check_value }, .{ .detached = true });
            }

            for (0..16) |_| {
                _ = try scheduler.spawn(checker, .{ lock, value, check_value }, .{ .detached = true });
            }

            try scheduler.run(.wait);
        }
    };

    var lock = try RwLock.init();
    defer lock.deinit();

    var value: usize = 0;
    var check_value: usize = 0;

    var threads: [8]std.Thread = undefined;

    for (0..8) |i| {
        threads[i] = try std.Thread.spawn(.{}, Test.test_thread, .{ &lock, &value, &check_value });
    }

    for (threads) |thread| {
        thread.join();
    }

    try std.testing.expectEqual(value, 1024000);
    try std.testing.expectEqual(check_value, 1024000);

    // check if it has successfully returned in its initial state.
    try std.testing.expectEqual(lock.counter, 0);
    try std.testing.expectEqual(lock.locked, false);
}

test "Mutex.Cancel" {
    const Test = struct {
        fn incrementer(lock: *Mutex, value: *usize, check_value: *usize) !void {
            while (true) {
                try lock.lock();
                defer lock.unlock();

                value.* += 1000;

                const stored = check_value.*;

                coro.io.single(.timeout, .{ .ns = std.time.ns_per_ms }) catch |err| switch (err) {
                    error.Canceled => {},
                    else => return err,
                };

                check_value.* = stored + 1000;
            }
        }

        fn cancel(canceled: *bool) !void {
            try coro.io.single(.timeout, .{ .ns = 16 * std.time.ns_per_ms });
            canceled.* = true;
        }

        fn test_thread(lock: *Mutex, value: *usize, check_value: *usize) !void {
            var scheduler = try coro.Scheduler.init(std.testing.allocator, .{});
            defer scheduler.deinit();

            for (0..128) |_| {
                _ = try scheduler.spawn(incrementer, .{ lock, value, check_value }, .{ .detached = true });
            }

            var canceled = false;
            _ = try scheduler.spawn(cancel, .{&canceled}, .{ .detached = true });

            while (!canceled) {
                _ = try scheduler.tick(.blocking);
            }

            try scheduler.run(.cancel);
        }
    };

    var lock = try Mutex.init();
    defer lock.deinit();

    var value: usize = 0;
    var check_value: usize = 0;

    var threads: [8]std.Thread = undefined;

    for (0..8) |i| {
        threads[i] = try std.Thread.spawn(.{}, Test.test_thread, .{ &lock, &value, &check_value });
    }

    for (threads) |thread| {
        thread.join();
    }

    try std.testing.expectEqual(value, check_value);
}

test "RwLock.Cancel" {
    const Test = struct {
        fn incrementer(lock: *RwLock, value: *usize, check_value: *usize) !void {
            while (true) {
                try lock.lock();
                defer lock.unlock();

                value.* += 1000;

                const stored = check_value.*;

                coro.io.single(.timeout, .{ .ns = std.time.ns_per_ms }) catch |err| switch (err) {
                    error.Canceled => {},
                    else => return err,
                };

                check_value.* = stored + 1000;
            }
        }

        fn locksharer(lock: *RwLock) !void {
            while (true) {
                // simulates a "workload"
                try coro.io.single(.timeout, .{ .ns = std.time.ns_per_ms });

                try lock.lockShared();
                defer lock.unlock();
            }
        }

        fn cancel(canceled: *bool) !void {
            try coro.io.single(.timeout, .{ .ns = 16 * std.time.ns_per_ms });
            canceled.* = true;
        }

        fn test_thread(lock: *RwLock, value: *usize, check_value: *usize) !void {
            var scheduler = try coro.Scheduler.init(std.testing.allocator, .{});
            defer scheduler.deinit();

            for (0..128) |_| {
                _ = try scheduler.spawn(incrementer, .{ lock, value, check_value }, .{ .detached = true });
            }

            for (0..16) |_| {
                _ = try scheduler.spawn(locksharer, .{lock}, .{ .detached = true });
            }

            var canceled = false;
            _ = try scheduler.spawn(cancel, .{&canceled}, .{ .detached = true });

            while (!canceled) {
                _ = try scheduler.tick(.blocking);
            }

            try scheduler.run(.cancel);
        }
    };

    var lock = try RwLock.init();
    defer lock.deinit();

    var value: usize = 0;
    var check_value: usize = 0;

    var threads: [8]std.Thread = undefined;

    for (0..8) |i| {
        threads[i] = try std.Thread.spawn(.{}, Test.test_thread, .{ &lock, &value, &check_value });
    }

    for (threads) |thread| {
        thread.join();
    }

    try std.testing.expectEqual(value, check_value);

    // check if it has successfully returned in its initial state.
    try std.testing.expectEqual(lock.counter, 0);
    try std.testing.expectEqual(lock.locked, false);
}
