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
threads: []DynamicThread,
run_queue: RunQueue = .{},
timeout: u64,
active_threads: u16 = 0,

const RunQueue = std.SinglyLinkedList(Runnable);
const Runnable = struct { runFn: RunProto };
const RunProto = *const fn (*Runnable) void;

pub const Options = struct {
    // Use the cpu core count by default
    num_threads: ?u32 = null,
    // Inactivity timeout when the thread will be joined
    timeout: u64 = 5 * std.time.ns_per_s,
};

pub const InitError = error{OutOfMemory} || std.time.Timer.Error;

pub fn init(self: *@This(), allocator: std.mem.Allocator, options: Options) InitError!void {
    self.* = .{
        .allocator = allocator,
        .threads = &[_]DynamicThread{},
        .timeout = options.timeout,
    };

    if (builtin.single_threaded) {
        return;
    }

    _ = try std.time.Timer.start(); // check that we have a timer
    const thread_count = options.num_threads orelse @max(1, std.Thread.getCpuCount() catch 1);
    self.threads = try allocator.alloc(DynamicThread, thread_count);
    for (self.threads) |*dthread| dthread.* = .{};
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
        pool: *Outer,
        run_node: RunQueue.Node = .{ .data = .{ .runFn = runFn } },

        fn runFn(runnable: *Runnable) void {
            const run_node: *RunQueue.Node = @fieldParentPtr("data", runnable);
            const closure: *@This() = @alignCast(@fieldParentPtr("run_node", run_node));
            @call(.auto, func, closure.arguments);
            // The thread pool's allocator is protected by the mutex.
            const mutex = &closure.pool.mutex;
            mutex.lock();
            defer mutex.unlock();
            closure.pool.allocator.destroy(closure);
        }
    };

    {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Activate a new thread if the run queue is running hot
        if (self.run_queue.first != null or self.active_threads == 0) {
            for (self.threads) |*dthread| {
                if (!dthread.active and dthread.thread == null) {
                    dthread.active = true;
                    self.active_threads += 1;
                    dthread.thread = try std.Thread.spawn(.{}, worker, .{ self, dthread });
                    break;
                }
            }
        }

        const closure = try self.allocator.create(Closure);
        closure.* = .{ .arguments = args, .pool = self };
        self.run_queue.prepend(&closure.run_node);
    }

    // Notify waiting threads outside the lock to try and keep the critical section small.
    self.cond.signal();
}

fn worker(self: *@This(), thread: *DynamicThread) void {
    var timer = std.time.Timer.start() catch unreachable;
    while (thread.active) {
        while (thread.active) {
            // TODO: should serialize the acqusation order here so that
            //       threads will always pop the run queue in order
            //       this would make the busy threads always be at the beginning
            //       of the array, while less busy or dead threads are at the end
            const node = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.run_queue.popFirst();
            };
            if (node) |run_node| {
                const runFn = run_node.data.runFn;
                runFn(&run_node.data);
                timer.reset();
            } else break;
        }
        if (thread.active) {
            self.mutex.lock();
            defer self.mutex.unlock();
            const now = timer.read();
            if (now >= self.timeout) {
                thread.active = false;
            } else {
                self.cond.timedWait(&self.mutex, self.timeout - now) catch {
                    thread.active = false;
                };
            }
        }
    }

    self.mutex.lock();
    defer self.mutex.unlock();
    self.active_threads -= 1;

    if (thread.active) {
        thread.active = false;
        // the thread cleans up itself from here on
        thread.thread.?.detach();
        thread.thread = null;
    }
}
