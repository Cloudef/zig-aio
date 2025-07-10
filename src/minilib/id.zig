const std = @import("std");

pub fn Id(IndexBits: type, EntropyBits: type) type {
    const BackingInt = std.meta.Int(.unsigned, @bitSizeOf(IndexBits) + @bitSizeOf(EntropyBits));
    return packed struct(BackingInt) {
        const IdType = @This();
        slot: IndexBits,
        generation: EntropyBits,

        pub fn init(raw: anytype) @This() {
            return @bitCast(@as(BackingInt, @intCast(raw)));
        }

        pub fn cast(self: @This(), T: type) T {
            return @intCast(@as(BackingInt, @bitCast(self)));
        }

        pub fn format(self: @This(), writer: anytype) !void {
            return writer.print("{}!{}", .{ self.slot, self.generation });
        }

        pub fn Allocator(SoALayout: type) type {
            const SoAStruct = blk: {
                var fields: []const std.builtin.Type.StructField = &.{};
                for (std.meta.fields(SoALayout)) |field| {
                    fields = fields ++ .{std.builtin.Type.StructField{
                        .type = [*]field.type,
                        .name = field.name,
                        .alignment = @alignOf([*]field.type),
                        .default_value_ptr = null,
                        .is_comptime = false,
                    }};
                }
                break :blk @Type(.{
                    .@"struct" = .{
                        .layout = .auto,
                        .fields = fields,
                        .decls = &.{},
                        .is_tuple = false,
                    },
                });
            };

            const FieldEnum = blk: {
                var fields: []const std.builtin.Type.EnumField = &.{};
                for (std.meta.fields(SoALayout), 0..) |field, idx| {
                    fields = fields ++ .{std.builtin.Type.EnumField{
                        .value = idx,
                        .name = field.name,
                    }};
                }
                break :blk @Type(.{
                    .@"enum" = .{
                        .tag_type = std.math.IntFittingRange(0, fields.len),
                        .fields = fields,
                        .decls = &.{},
                        .is_exhaustive = true,
                    },
                });
            };

            return struct {
                cursor: IndexBits = 0,
                in_use: IndexBits = 0,
                slots: [*]EntropyBits,
                used: std.DynamicBitSetUnmanaged,
                soa: SoAStruct,

                pub const Error = error{OutOfMemory};

                pub fn init(allocator: std.mem.Allocator, n: IndexBits) Error!@This() {
                    var used = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
                    errdefer used.deinit(allocator);
                    const slots = try allocator.alloc(EntropyBits, n);
                    errdefer allocator.free(slots);
                    @memset(slots, 0);
                    comptime var idx: usize = 0;
                    var soa: SoAStruct = undefined;
                    errdefer inline for (std.meta.fields(SoALayout)[0..idx]) |field| allocator.free(@field(soa, field.name)[0..n]);
                    inline for (std.meta.fields(SoALayout)) |field| {
                        const tmp = try allocator.alloc(field.type, n);
                        idx += 1;
                        @field(soa, field.name) = tmp.ptr;
                    }
                    return .{ .slots = slots.ptr, .used = used, .soa = soa };
                }

                pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                    allocator.free(self.slots[0..self.used.bit_length]);
                    inline for (std.meta.fields(SoALayout)) |field| allocator.free(@field(self.soa, field.name)[0..self.used.bit_length]);
                    self.used.deinit(allocator);
                    self.* = undefined;
                }

                pub fn empty(self: *@This()) bool {
                    return self.in_use == 0;
                }

                pub fn next(self: *@This()) ?IdType {
                    if (self.in_use == self.used.bit_length) return null;
                    const n: IndexBits = @intCast(self.used.bit_length);
                    defer self.cursor = (self.cursor +| 1) % n;
                    while (self.used.isSet(self.cursor)) self.cursor = (self.cursor +| 1) % n;
                    return .{ .slot = self.cursor, .generation = self.slots[self.cursor] };
                }

                pub fn unsafeIdFromSlot(self: *@This(), slot: IndexBits) IdType {
                    return .{ .slot = slot, .generation = self.slots[slot] };
                }

                pub fn lookup(self: *@This(), id: IdType) error{NotFound}!void {
                    if (self.slots[id.slot] != id.generation) return error.NotFound;
                    if (!self.used.isSet(id.slot)) return error.NotFound;
                }

                pub fn use(self: *@This(), id: IdType, initial: SoALayout) error{AlreadyInUse}!void {
                    if (self.slots[id.slot] != id.generation) return error.AlreadyInUse;
                    if (self.used.isSet(id.slot)) return error.AlreadyInUse;
                    self.used.set(id.slot);
                    self.set(id, initial);
                    self.in_use += 1;
                }

                pub fn release(self: *@This(), id: IdType) error{NotFound}!void {
                    try self.lookup(id);
                    self.slots[id.slot] +%= 1;
                    self.used.unset(id.slot);
                    self.in_use -= 1;
                }

                pub fn get(self: *@This(), id: IdType) SoALayout {
                    self.lookup(id) catch unreachable;
                    var v: SoALayout = undefined;
                    inline for (std.meta.fields(SoALayout)) |field| {
                        @field(v, field.name) = @field(self.soa, field.name)[id.slot];
                    }
                    return v;
                }

                pub fn getOne(self: *@This(), comptime field: FieldEnum, id: IdType) @FieldType(SoALayout, @tagName(field)) {
                    self.lookup(id) catch unreachable;
                    return @field(self.soa, @tagName(field))[id.slot];
                }

                pub fn getOnePtr(self: *@This(), comptime field: FieldEnum, id: IdType) *@FieldType(SoALayout, @tagName(field)) {
                    self.lookup(id) catch unreachable;
                    return &@field(self.soa, @tagName(field))[id.slot];
                }

                pub fn set(self: *@This(), id: IdType, v: SoALayout) void {
                    self.lookup(id) catch unreachable;
                    inline for (std.meta.fields(SoALayout)) |field| {
                        @field(self.soa, field.name)[id.slot] = @field(v, field.name);
                    }
                }

                pub fn setOne(self: *@This(), comptime field: FieldEnum, id: IdType, v: @FieldType(SoALayout, @tagName(field))) void {
                    self.lookup(id) catch unreachable;
                    @field(self.soa, @tagName(field))[id.slot] = v;
                }
            };
        }
    };
}
