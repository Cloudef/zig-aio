//! Basically `std.Thread.Pool` but supports timeout
//! That is, if threads have been inactive for specific timeout the pool will release the threads
//! The `num_threads` are also the maximum count of worker threads, but if there's not much activity
//! less threads are used.

const builtin = @import("builtin");
const std = @import("std");

const DynamicThread = struct {
    active: bool = false,
    thread: ?std.Thread = null,
};

allocator: std.mem.Allocator,
mutex: std.Thread.Mutex = .{},
cond: std.Thread.Condition = .{},
threads: []DynamicThread = &.{},
run_queue: RunQueue = .{},
idling_threads: u32 = 0,
active_threads: u32 = 0,
timeout: u64,
// used to serialize the acquisition order
serial: std.DynamicBitSetUnmanaged align(std.atomic.cache_line) = undefined,

const RunQueue = std.SinglyLinkedList(Runnable);
const Runnable = struct { runFn: RunProto };
const RunProto = *const fn (*@This(), *Runnable) void;

pub const Options = struct {
    // Use the cpu core count by default
    max_threads: ?u32 = null,
    // Inactivity timeout when the thread will be joined
    timeout: u64 = 5 * std.time.ns_per_s,
};

pub const InitError = error{OutOfMemory} || std.time.Timer.Error;

pub fn init(self: *@This(), allocator: std.mem.Allocator, options: Options) InitError!void {
    self.* = .{
        .allocator = allocator,
        .timeout = options.timeout,
    };

    if (builtin.single_threaded) {
        return;
    }

    _ = try std.time.Timer.start(); // check that we have a timer

    const thread_count = options.max_threads orelse @max(1, std.Thread.getCpuCount() catch 1);
    self.serial = try std.DynamicBitSetUnmanaged.initEmpty(allocator, thread_count);
    errdefer self.serial.deinit(allocator);
    self.threads = try allocator.alloc(DynamicThread, thread_count);
    errdefer allocator.free(self.threads);
    @memset(self.threads, .{});
}

pub fn deinit(self: *@This()) void {
    if (!builtin.single_threaded) {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.threads) |*dthread| dthread.active = false;
        }
        self.cond.broadcast();
        for (self.threads) |*dthread| if (dthread.thread) |thrd| thrd.join();
        self.allocator.free(self.threads);
        self.serial.deinit(self.allocator);
    }
    self.* = undefined;
}

pub const SpawnError = error{
    OutOfMemory,
    SystemResources,
    LockedMemoryLimitExceeded,
    ThreadQuotaExceeded,
    Unexpected,
};

pub fn spawn(self: *@This(), comptime func: anytype, args: anytype) SpawnError!void {
    if (builtin.single_threaded) {
        @call(.auto, func, args);
        return;
    }

    const Args = @TypeOf(args);
    const Outer = @This();
    const Closure = struct {
        arguments: Args,
        run_node: RunQueue.Node = .{ .data = .{ .runFn = runFn } },

        fn runFn(pool: *Outer, runnable: *Runnable) void {
            const run_node: *RunQueue.Node = @fieldParentPtr("data", runnable);
            const closure: *@This() = @alignCast(@fieldParentPtr("run_node", run_node));
            @call(.auto, func, closure.arguments);
            // The thread pool's allocator is protected by the mutex.
            pool.mutex.lock();
            defer pool.mutex.unlock();
            pool.allocator.destroy(closure);
        }
    };

    {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Activate a new thread if the run queue is running hot
        if (self.idling_threads == 0 and self.active_threads < self.threads.len) {
            for (self.threads[self.active_threads..], 0..) |*dthread, id| {
                if (!dthread.active and dthread.thread == null) {
                    dthread.active = true;
                    self.serial.unset(id);
                    self.active_threads += 1;
                    dthread.thread = try std.Thread.spawn(.{}, worker, .{ self, dthread, @as(u32, @intCast(id)), self.timeout });
                    break;
                }
            }
        }

        const closure = try self.allocator.create(Closure);
        closure.* = .{ .arguments = args };
        self.run_queue.prepend(&closure.run_node);
    }

    // Notify waiting threads outside the lock to try and keep the critical section small.
    // Wake up all the threads so they can figure out their acquisition order
    // Threads that don't seem to get much work will die out by itself
    self.cond.broadcast();
}

fn worker(self: *@This(), thread: *DynamicThread, id: u32, timeout: u64) void {
    var timer = std.time.Timer.start() catch unreachable;
    main: while (thread.active) {
        // Serialize the acquisition order here so that threads will always pop the run queue in order
        // this makes the busy threads always be at the beginning of the array,
        // while less busy or dead threads are at the end
        // If a thread keeps getting out done by the earlier threads, it will time out
        const can_work: bool = blk: {
            outer: while (id > 0 and thread.active) {
                {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    if (self.run_queue.first == null) {
                        // We were outraced, go back to sleep
                        break :blk false;
                    }
                }
                if (timer.read() >= timeout) break :main;
                for (0..id) |idx| if (!self.serial.isSet(idx)) {
                    std.Thread.yield() catch {};
                    continue :outer;
                };
                break :outer;
            }
            break :blk true;
        };

        if (can_work) {
            self.serial.set(id);
            defer self.serial.unset(id);
            while (thread.active) {
                // Get the node
                const node = blk: {
                    self.mutex.lock();
                    defer self.mutex.unlock();
                    break :blk self.run_queue.popFirst();
                };

                // Do the work
                if (node) |run_node| {
                    const runFn = run_node.data.runFn;
                    runFn(self, &run_node.data);
                    timer.reset();
                } else break;
            }
        }

        if (thread.active) {
            const now = timer.read();
            if (now >= timeout) break :main;
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.run_queue.first == null) {
                self.idling_threads += 1;
                defer self.idling_threads -= 1;
                self.cond.timedWait(&self.mutex, timeout - now) catch break :main;
            }
        }
    }

    self.mutex.lock();
    defer self.mutex.unlock();
    self.active_threads -= 1;

    // This thread won't partipicate in the acquisition order anymore
    // In case there are threads further in the queue don't block them if there's a burst of work
    self.serial.set(id);

    if (thread.active) {
        // timed out
        thread.active = false;
        // the thread cleans up itself from here on
        thread.thread.?.detach();
        thread.thread = null;
    }
}
