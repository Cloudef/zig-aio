//! Like bounded array but the array is allocated thus bound is runtime known
//! DoubleBufferedFixedArray has thread safe insertion and removal
//! swap() lets you thread safely retieve copy of current state of the array

const std = @import("std");

pub fn FixedArrayList(T: type, SZ: type) type {
    return struct {
        items: []T,
        len: SZ = 0,

        pub const Error = error{OutOfMemory};

        pub fn init(allocator: std.mem.Allocator, n: SZ) Error!@This() {
            return .{ .items = try allocator.alloc(T, n) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.items);
            self.* = undefined;
        }

        pub fn add(self: *@This(), item: T) Error!void {
            if (self.len >= self.items.len) return error.OutOfMemory;
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn swapRemove(self: *@This(), idx: SZ) void {
            self.items[idx] = self.items[self.len - 1];
            self.len -= 1;
        }

        pub fn reset(self: *@This()) void {
            self.len = 0;
        }

        pub fn slice(self: *@This()) []T {
            return self.items[0..self.len];
        }

        pub fn constSlice(self: @This()) []const T {
            return self.items[0..self.len];
        }

        pub fn swapRemoveNeedle(self: *@This(), needle: T) error{NotFound}!void {
            for (self.constSlice(), 0..) |stack, idx| {
                if (!std.meta.eql(stack, needle)) continue;
                self.swapRemove(@intCast(idx));
                return;
            }
            return error.NotFound;
        }
    };
}

pub fn DoubleBufferedFixedArrayList(T: type, SZ: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        safe: FixedArrayList(T, SZ),
        copy: [*]T align(std.atomic.cache_line),

        pub const Error = error{OutOfMemory};

        pub fn init(allocator: std.mem.Allocator, n: SZ) Error!@This() {
            var safe = try FixedArrayList(T, SZ).init(allocator, n);
            errdefer safe.deinit(allocator);
            const copy = try allocator.alloc(T, n);
            errdefer allocator.free(copy);
            return .{ .safe = safe, .copy = copy.ptr };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.copy[0..self.safe.items.len]);
            self.safe.deinit(allocator);
            self.* = undefined;
        }

        pub fn add(self: *@This(), item: T) Error!void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.safe.add(item);
        }

        pub fn len(self: *@This()) SZ {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.safe.len;
        }

        pub fn reset(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.safe.reset();
        }

        pub fn swap(self: *@This()) []T {
            self.mutex.lock();
            defer self.mutex.unlock();
            defer self.safe.reset();
            std.mem.swap([*]T, &self.copy, &self.safe.items.ptr);
            return self.copy[0..self.safe.len];
        }
    };
}
