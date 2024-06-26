//! Item pool that returns stable ids
//! Insertion and removal is O(1)
//! Iteration is O(n)

const std = @import("std");

pub fn ItemPool(T: type, SZ: type) type {
    return struct {
        pub const Node = union(enum) { free: ?SZ, used: T };
        nodes: []Node,
        free: ?SZ = null,
        num_free: SZ = 0,
        num_used: SZ = 0,

        pub const Error = error{OutOfMemory};

        pub fn init(allocator: std.mem.Allocator, n: SZ) Error!@This() {
            return .{ .nodes = try allocator.alloc(Node, n) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.nodes);
            self.* = undefined;
        }

        pub fn empty(self: *@This()) bool {
            return self.num_used == self.num_free;
        }

        pub fn next(self: *@This()) ?SZ {
            if (self.free) |fslot| return fslot;
            if (self.num_used >= self.nodes.len) return null;
            return self.num_used;
        }

        pub fn add(self: *@This(), item: T) Error!SZ {
            if (self.free) |fslot| {
                self.free = self.nodes[fslot].free;
                self.nodes[fslot] = .{ .used = item };
                self.num_free -= 1;
                return fslot;
            }
            if (self.num_used >= self.nodes.len) return error.OutOfMemory;
            self.nodes[self.num_used] = .{ .used = item };
            defer self.num_used += 1;
            return self.num_used;
        }

        pub fn remove(self: *@This(), slot: SZ) void {
            if (self.free) |fslot| {
                self.nodes[slot] = .{ .free = fslot };
            } else {
                self.nodes[slot] = .{ .free = null };
            }
            self.free = slot;
            self.num_free += 1;
        }

        pub fn get(self: *@This(), slot: SZ) *T {
            return &self.nodes[slot].used;
        }

        pub fn reset(self: *@This()) void {
            self.free = null;
            self.num_free = 0;
            self.num_used = 0;
        }

        pub const Iterator = struct {
            items: []Node,
            index: SZ = 0,

            pub const Entry = struct {
                k: SZ,
                v: *T,
            };

            pub fn next(self: *@This()) ?Entry {
                while (self.index < self.items.len) {
                    defer self.index += 1;
                    if (self.items[self.index] == .used) {
                        return .{ .k = self.index, .v = &self.items[self.index].used };
                    }
                }
                return null;
            }
        };

        pub fn iterator(self: *@This()) Iterator {
            return .{ .items = self.nodes[0..self.num_used] };
        }
    };
}
