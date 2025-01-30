const std = @import("std");
const aio = @import("aio");
const coro = @import("../coro.zig");
const Frame = @import("Frame.zig");

fn wakeupWaiters(list: *Frame.WaitList, status: anytype) void {
    var next = list.first;
    while (next) |node| {
        next = node.next;
        node.data.cast().wakeup(status);
    }
}

/// Cooperatively scheduled thread unsafe Semaphore
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

/// Cooperatively scheduled thread unsafe ResetEvent
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

/// A thread-safe Mutex implemented on top of aio.EventSource
/// When the mutex is locked other tasks can still run
const Mutex = struct {
    native: std.Thread.Mutex = .{},
    semaphore: aio.EventSource,

    pub fn init() !@This() {
        return .{ .semaphore = try aio.EventSource.init() };
    }

    pub fn deinit(self: *@This()) void {
        self.semaphore.deinit();
    }

    pub fn tryLock(self: *@This()) bool {
        return self.native.tryLock();
    }

    pub fn lock(self: *@This()) !void {
        if (Frame.current()) |frame| {
            if (frame.canceled) return error.Canceled;
            while (!self.tryLock()) {
                try coro.io.single(.wait_event_source, .{
                    .source = &self.semaphore,
                });
            }
        } else {
            while (!self.tryLock()) {
                self.semaphore.wait();
            }
        }
    }

    pub fn unlock(self: *@This()) void {
        self.native.unlock();
        self.semaphore.notify();
    }
};

/// A thread-safe RwLock implemented on top of coro.Mutex
/// When the RwLock is locked other tasks can still run
pub const RwLock = struct {
    state: usize = 0,
    mutex: Mutex,
    semaphore: aio.EventSource,
    locking_thread: std.atomic.Value(std.Thread.Id) = std.atomic.Value(std.Thread.Id).init(0),

    pub fn init() !@This() {
        return .{
            .mutex = try Mutex.init(),
            .semaphore = try aio.EventSource.init(),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.mutex.deinit();
        self.semaphore.deinit();
    }

    const IS_WRITING: usize = 1;
    const WRITER: usize = 1 << 1;
    const READER: usize = 1 << (1 + @bitSizeOf(Count));
    const WRITER_MASK: usize = std.math.maxInt(Count) << @ctz(WRITER);
    const READER_MASK: usize = std.math.maxInt(Count) << @ctz(READER);
    const Count = std.meta.Int(.unsigned, @divFloor(@bitSizeOf(usize) - 1, 2));

    pub fn lock(rwl: *@This()) !void {
        _ = @atomicRmw(usize, &rwl.state, .Add, WRITER, .seq_cst);
        try rwl.mutex.lock();
        rwl.locking_thread.store(std.Thread.getCurrentId(), .unordered);
        var state = @atomicRmw(usize, &rwl.state, .Add, IS_WRITING -% WRITER, .seq_cst);
        while (true) {
            if (state & READER_MASK == 0) break;
            try coro.io.single(.wait_event_source, .{
                .source = &rwl.semaphore,
            });
            state = @atomicLoad(usize, &rwl.state, .seq_cst);
        }
    }

    pub fn unlock(rwl: *@This()) void {
        _ = @atomicRmw(usize, &rwl.state, .And, ~IS_WRITING, .seq_cst);
        rwl.locking_thread.store(0, .unordered);
        rwl.mutex.unlock();
    }

    pub fn lockShared(rwl: *@This()) !void {
        // a coroutine may yield while holding a lock and then try lockShared on some other task
        while (rwl.locking_thread.load(.unordered) == std.Thread.getCurrentId()) {
            try rwl.mutex.lock();
            rwl.mutex.unlock();
        }

        var state = @atomicLoad(usize, &rwl.state, .seq_cst);
        while (state & (IS_WRITING | WRITER_MASK) == 0) {
            state = @cmpxchgWeak(
                usize,
                &rwl.state,
                state,
                state + READER,
                .seq_cst,
                .seq_cst,
            ) orelse return;
        }

        try rwl.mutex.lock();
        _ = @atomicRmw(usize, &rwl.state, .Add, READER, .seq_cst);
        rwl.mutex.unlock();
    }

    pub fn unlockShared(rwl: *@This()) void {
        const state = @atomicRmw(usize, &rwl.state, .Sub, READER, .seq_cst);
        if ((state & READER_MASK == READER) and (state & IS_WRITING != 0))
            rwl.semaphore.notify();
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
                try coro.io.single(.timeout, .{ .ns = 16 * std.time.ns_per_ms });

                try lock.lockShared();
                defer lock.unlockShared();

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
                try lock.lockShared();
                defer lock.unlockShared();

                // simulates a "workload"
                try coro.io.single(.timeout, .{ .ns = 16 * std.time.ns_per_ms });
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
}
