const std = @import("std");
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

/// Thread-safe read-write lock
pub const RwLock = struct {
    waiters: Frame.WaitList = .{},
    mutex: std.Thread.Mutex = .{},
    locked: bool = false,
    counter: usize = 0,

    // locked == true and counter == 0 means exclusive lock
    // locked == true and counter > 0 means shared lock
    // locked == false means unlock

    pub const Error = error{Canceled};

    inline fn _lock(self: *@This()) bool {
        if (self.mutex.tryLock()) {
            defer self.mutex.unlock();

            const is_locked = @atomicLoad(bool, &self.locked, .acquire);

            if (!is_locked) {
                @atomicStore(bool, &self.locked, true, .release);
                @atomicStore(usize, &self.counter, 0, .release);
                return true;
            }
        }

        return false;
    }

    inline fn _lockShared(self: *@This()) bool {
        if (self.mutex.tryLock()) {
            defer self.mutex.unlock();

            const is_locked = @atomicLoad(bool, &self.locked, .acquire);

            if (is_locked) {
                const counter = @atomicLoad(usize, &self.counter, .acquire);
                if (counter > 0) {
                    _ = @atomicRmw(usize, &self.counter, .Add, 1, .acq_rel);
                }
            } else {
                @atomicStore(bool, &self.locked, true, .release);
                @atomicStore(usize, &self.counter, 1, .release);
                return true;
            }
        }

        return false;
    }

    pub fn lock(self: *@This()) Error!void {
        if (Frame.current()) |frame| {
            if (frame.canceled) return error.Canceled;

            if (self._lock()) {
                return;
            }

            self.mutex.lock();
            self.waiters.prepend(&frame.wait_link);
            self.mutex.unlock();

            defer {
                self.mutex.lock();
                self.waiters.remove(&frame.wait_link);
                self.mutex.unlock();
            }

            while (!frame.canceled) {
                Frame.yield(.rw_lock);
                if (self._lock()) {
                    break;
                }
            }

            if (frame.canceled) return error.Canceled;
        } else unreachable; // can only be used in tasks
    }

    pub fn lockShared(self: *@This()) Error!void {
        if (Frame.current()) |frame| {
            if (frame.canceled) return error.Canceled;

            if (self._lockShared()) {
                return;
            }

            self.mutex.lock();
            self.waiters.prepend(&frame.wait_link);
            self.mutex.unlock();

            defer {
                self.mutex.lock();
                self.waiters.remove(&frame.wait_link);
                self.mutex.unlock();
            }

            while (!frame.canceled) {
                Frame.yield(.rw_lock);
                if (self._lockShared()) {
                    break;
                }
            }

            if (frame.canceled) return error.Canceled;
        } else unreachable; // can only be used in tasks
    }

    pub fn unlock(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const locked = @atomicLoad(bool, &self.locked, .acquire);
        const counter = @atomicLoad(usize, &self.counter, .acquire);

        if (locked) {
            if (counter < 2) {
                // exclusive lock and shared lock with only one locker
                @atomicStore(bool, &self.locked, false, .release);
                @atomicStore(usize, &self.counter, 0, .release);
            } else {
                // shared lock
                _ = @atomicRmw(usize, &self.counter, .Sub, 1, .acq_rel);
            }
        }
    }
};

const Scheduler = @import("Scheduler.zig");

test "RwLock" {
    const Test = struct {
        // the idea of the incremeter is to increment a value, store the current value of a value2, then increment the second value based on the stored value
        // if someone did something while the "fake workload", this will be produce rollback in the value of value2
        // also I add 1000 because it takes more than 1 byte, so it can also creates weird value if two threads edit value at the same time (which is less common with only one byte)

        fn incrementer(lock: *RwLock, value: *usize, value2: *usize) !void {
            for (0..4) |_| {
                try lock.lock();
                defer lock.unlock();

                value.* += 1000;

                const stored = value2.*;

                // simulates a "workload"
                std.Thread.sleep(std.time.ms_per_s);

                value2.* = stored + 1000;
            }
        }

        fn test_thread(lock: *RwLock, value: *usize, value2: *usize) !void {
            var scheduler = try Scheduler.init(std.testing.allocator, .{});
            defer scheduler.deinit();

            for (0..32) |_| {
                const task = try scheduler.spawn(incrementer, .{ lock, value, value2 }, .{});
                task.detach();
            }

            try scheduler.run(.wait);
        }
    };

    var lock: RwLock = .{};
    var value: usize = 0;
    var value2: usize = 0;

    var threads = std.ArrayList(std.Thread).init(std.testing.allocator);
    defer threads.deinit();

    for (0..8) |_| {
        try threads.append(try std.Thread.spawn(.{}, Test.test_thread, .{ &lock, &value, &value2 }));
    }

    for (threads.items) |thread| {
        thread.join();
    }

    std.log.debug("\n\n{}\n\n", .{value});

    std.debug.assert(value == 1024000);
    std.debug.assert(value2 == 1024000);

    // check if it has successfully returned in its initial state.
    std.debug.assert(lock.counter == 0);
    std.debug.assert(lock.locked == false);
    std.debug.assert(lock.waiters.len() == 0);

    // TODO find out a way to test lockShared without causing a "normal" infinite-lock
    // I figured out that if you do the current test but at the same time you have tasks that share lock in while(true) and check if the final value is reached
    // it will never exit the share lock, because there's always a task share locking before the shared lock is completely unlocked
}
