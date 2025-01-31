//! Emulates io_uring execution scheduling

const std = @import("std");
const aio = @import("../aio.zig");
const Operation = @import("ops.zig").Operation;
const DoubleBufferedFixedArrayList = @import("minilib").DoubleBufferedFixedArrayList;
const FixedArrayList = @import("minilib").FixedArrayList;
const posix = @import("posix/posix.zig");
const log = std.log.scoped(.aio_uringlator);

const Result = struct {
    failure: Operation.Error,
    id: aio.Id,
};

const UringlatorOperation = struct {
    const State = union {
        nop: struct {},
        fsync: struct {
            file: std.fs.File,
        },
        poll: struct {},
        read_tty: struct {
            tty: std.fs.File,
            buffer: []u8,
        },
        read: struct {
            file: std.fs.File,
            buffer: []u8,
            offset: u64,
        },
        write: struct {
            file: std.fs.File,
            buffer: []const u8,
            offset: u64,
        },
        accept: struct {
            socket: std.posix.socket_t,
            out_addr: ?*posix.sockaddr,
            inout_addrlen: ?*posix.socklen_t,
        },
        connect: struct {
            socket: std.posix.socket_t,
            addr: *const posix.sockaddr,
            addrlen: posix.socklen_t,
        },
        recv: struct {
            socket: std.posix.socket_t,
            buffer: []u8,
        },
        send: struct {
            socket: std.posix.socket_t,
            buffer: []const u8,
        },
        recv_msg: struct {
            socket: std.posix.socket_t,
            out_msg: *posix.msghdr,
        },
        send_msg: struct {
            socket: std.posix.socket_t,
            msg: *const posix.msghdr_const,
        },
        shutdown: struct {
            socket: std.posix.socket_t,
            how: std.posix.ShutdownHow,
        },
        open_at: struct {
            dir: std.fs.Dir,
            path: [*:0]const u8,
            flags: std.fs.File.OpenFlags,
        },
        close_file: struct {
            file: std.fs.File,
        },
        close_dir: struct {
            dir: std.fs.Dir,
        },
        timeout: struct {
            ns: u128,
        },
        link_timeout: struct {
            ns: u128,
        },
        cancel: struct {
            id: aio.Id,
        },
        rename_at: struct {
            old_dir: std.fs.Dir,
            old_path: [*:0]const u8,
            new_dir: std.fs.Dir,
            new_path: [*:0]const u8,
        },
        unlink_at: struct {
            dir: std.fs.Dir,
            path: [*:0]const u8,
        },
        mkdir_at: struct {
            dir: std.fs.Dir,
            path: [*:0]const u8,
            mode: u32,
        },
        symlink_at: struct {
            dir: std.fs.Dir,
            target: [*:0]const u8,
            link_path: [*:0]const u8,
        },
        child_exit: struct {
            child: std.process.Child.Id,
        },
        socket: struct {
            domain: u32,
            flags: u32,
            protocol: u32,
        },
        close_socket: struct {
            socket: std.posix.socket_t,
        },
        notify_event_source: struct {
            source: *aio.EventSource,
        },
        wait_event_source: struct {
            source: *aio.EventSource,
        },
        close_event_source: struct {
            source: *aio.EventSource,
        },

        fn FieldType(comptime T: type, comptime name: []const u8) type {
            return @TypeOf(@field(@as(T, undefined), name));
        }

        fn init(comptime op_type: Operation, op: Operation.map.getAssertContains(op_type)) @This() {
            var v: FieldType(@This(), @tagName(op_type)) = undefined;
            inline for (std.meta.fields(@TypeOf(v))) |field| @field(v, field.name) = @field(op, field.name);
            return @unionInit(@This(), @tagName(op_type), v);
        }

        pub fn toOp(self: @This(), comptime op_type: Operation, result: *Operation.anyresult) Operation.map.getAssertContains(op_type) {
            var op: Operation.map.getAssertContains(op_type) = undefined;
            inline for (std.meta.fields(FieldType(@This(), @tagName(op_type)))) |field| {
                @field(op, field.name) = @field(@field(self, @tagName(op_type)), field.name);
            }
            result.restore(op_type, &op);
            return op;
        }
    };

    type: Operation,
    userdata: usize,
    out_id: ?*aio.Id = null,
    out_error: ?*anyerror = null,
    out_result: *Operation.anyresult,
    next: aio.Id, // linked operation, points to self if none
    prev: aio.Id, // previous operation, points to self if none (only used for link timeouts)
    link: aio.Link, // link type

    // some operations require mutable state
    state: State,
};

pub fn Uringlator(BackendOperation: type) type {
    const CombinedOperation = @Type(.{
        .Struct = .{
            .layout = .auto,
            .fields = std.meta.fields(UringlatorOperation) ++ std.meta.fields(BackendOperation),
            .decls = &.{},
            .is_tuple = false,
        },
    });

    return struct {
        const IdAllocator = aio.Id.Allocator(CombinedOperation);

        ops: IdAllocator,
        prev_id: ?aio.Id = null, // for linking operations
        link_lock: std.DynamicBitSetUnmanaged, // operation is waiting for linked operation to finish first
        started: std.DynamicBitSetUnmanaged, // operation has started
        queued: FixedArrayList(aio.Id, u16), // operation has been queued
        finished: DoubleBufferedFixedArrayList(Result, u16), // operations that are finished, double buffered to be thread safe

        pub fn init(allocator: std.mem.Allocator, n: u16) aio.Error!@This() {
            var ops = try IdAllocator.init(allocator, n);
            errdefer ops.deinit(allocator);
            var link_lock = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
            errdefer link_lock.deinit(allocator);
            var started = try std.DynamicBitSetUnmanaged.initEmpty(allocator, n);
            errdefer started.deinit(allocator);
            var queued = try FixedArrayList(aio.Id, u16).init(allocator, n);
            errdefer queued.deinit(allocator);
            var finished = try DoubleBufferedFixedArrayList(Result, u16).init(allocator, n);
            errdefer finished.deinit(allocator);
            return .{
                .ops = ops,
                .link_lock = link_lock,
                .started = started,
                .queued = queued,
                .finished = finished,
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.ops.deinit(allocator);
            self.link_lock.deinit(allocator);
            self.started.deinit(allocator);
            self.queued.deinit(allocator);
            self.finished.deinit(allocator);
            self.* = undefined;
        }

        pub fn shutdown(self: *@This(), backend: anytype) void {
            debug("shutdown", .{});
            var iter = self.ops.used.iterator(.{ .kind = .set });
            while (iter.next()) |slot| {
                const id = self.ops.unsafeIdFromSlot(@intCast(slot));
                _ = backend.uringlator_cancel(id, self.ops.getOne(.type, id), error.Canceled);
            }
        }

        fn queueOperation(self: *@This(), comptime tag: Operation, op: anytype, link: aio.Link, backend: anytype) aio.Error!aio.Id {
            const id = self.ops.next() orelse return error.OutOfMemory;
            debug("queue: {}: {}, {s} ({?})", .{ id, tag, @tagName(link), self.prev_id });

            const uop: UringlatorOperation = .{
                .type = tag,
                .userdata = op.userdata,
                .out_id = op.out_id,
                .out_error = @ptrCast(op.out_error),
                .out_result = Operation.anyresult.init(tag, op),
                .next = id,
                .prev = self.prev_id orelse id,
                .link = link,
                .state = UringlatorOperation.State.init(tag, op),
            };
            const bop: BackendOperation = try backend.uringlator_queue(id, tag, op);

            var combined: CombinedOperation = undefined;
            inline for (std.meta.fields(UringlatorOperation)) |field| {
                @field(combined, field.name) = @field(uop, field.name);
            }
            inline for (std.meta.fields(BackendOperation)) |field| {
                @field(combined, field.name) = @field(bop, field.name);
            }
            self.ops.use(id, combined) catch unreachable;

            if (self.prev_id) |prev| {
                self.ops.getOnePtr(.next, prev).* = id;
                self.link_lock.set(id.slot);
            } else {
                self.link_lock.unset(id.slot);
            }

            if (op.out_id) |out| out.* = id;
            if (op.out_error) |out| out.* = error.Success;
            if (link != .unlinked) self.prev_id = id else self.prev_id = null;
            return id;
        }

        pub fn queue(self: *@This(), pairs: anytype, backend: anytype, handler: anytype) aio.Error!void {
            if (comptime pairs.len > 1) {
                var ids: std.BoundedArray(aio.Id, pairs.len) = .{};
                errdefer inline for (ids.constSlice(), pairs) |id, pair| {
                    debug("dequeue: {}: {}, {s} ({?})", .{ id, pair.tag, @tagName(pair.link), self.prev_id });
                    backend.uringlator_dequeue(id, pair.tag, pair.op);
                    self.ops.release(id) catch unreachable;
                };
                inline for (pairs) |pair| ids.append(try self.queueOperation(pair.tag, pair.op, pair.link, backend)) catch unreachable;
                inline for (ids.constSlice()[0..pairs.len]) |id| self.queued.add(id) catch unreachable;
                if (@TypeOf(handler) != void) {
                    inline for (ids.constSlice(), pairs) |id, pair| handler.aio_queue(id, pair.op.userdata);
                }
            } else {
                inline for (pairs) |pair| {
                    const id = try self.queueOperation(pair.tag, pair.op, pair.link, backend);
                    self.queued.add(id) catch unreachable;
                    if (@TypeOf(handler) != void) {
                        handler.aio_queue(id, pair.op.userdata);
                    }
                }
            }
        }

        pub fn submit(self: *@This(), backend: anytype) aio.Error!bool {
            if (self.ops.empty()) return false;
            self.prev_id = null;
            again: while (true) {
                for (self.queued.constSlice(), 0..) |id, idx| {
                    std.debug.assert(!self.started.isSet(id.slot));

                    if (self.link_lock.isSet(id.slot)) {
                        continue;
                    }

                    const tag = self.ops.getOne(.type, id);
                    self.queued.swapRemove(@intCast(idx));
                    try self.start(tag, id, backend);

                    // start linked timeout immediately as well if there's one
                    const next = self.ops.getOne(.next, id);
                    if (!std.meta.eql(next, id) and self.ops.getOne(.type, next) == .link_timeout) {
                        self.link_lock.unset(next.slot);
                    }
                    continue :again;
                }
                break;
            }
            return true;
        }

        fn cancel(self: *@This(), id: aio.Id, err: Operation.Error, backend: anytype) error{ NotFound, InProgress }!void {
            _ = try self.ops.lookup(id);
            if (self.started.isSet(id.slot)) {
                if (!backend.uringlator_cancel(id, self.ops.getOne(.type, id), err)) {
                    return error.InProgress;
                }
            } else {
                self.queued.swapRemoveNeedle(id) catch unreachable;
                self.finish(backend, id, err, .thread_unsafe);
            }
        }

        fn start(self: *@This(), op_type: Operation, id: aio.Id, backend: anytype) aio.Error!void {
            if (!std.meta.eql(self.ops.getOne(.next, id), id)) {
                debug("perform: {}: {} => {}", .{ id, op_type, self.ops.getOne(.next, id) });
            } else {
                debug("perform: {}: {}", .{ id, op_type });
            }
            std.debug.assert(!self.started.isSet(id.slot));
            self.started.set(id.slot);
            switch (op_type) {
                .nop => self.finish(backend, id, error.Success, .thread_unsafe),
                .cancel => blk: {
                    const state = self.ops.getOne(.state, id);
                    std.debug.assert(!std.meta.eql(state.cancel.id, id));
                    self.cancel(state.cancel.id, error.Canceled, backend) catch |err| {
                        self.finish(backend, id, err, .thread_unsafe);
                        break :blk;
                    };
                    self.finish(backend, id, error.Success, .thread_unsafe);
                },
                else => |tag| try backend.uringlator_start(id, tag),
            }
        }

        pub fn complete(self: *@This(), backend: anytype, handler: anytype) aio.CompletionResult {
            const finished = self.finished.swap();

            var num_errors: u16 = 0;
            for (finished) |res| {
                _ = self.ops.lookup(res.id) catch continue; // raced
                const op_type = self.ops.getOne(.type, res.id);

                var failure = res.failure;
                if (failure != error.Canceled) {
                    std.debug.assert(self.started.isSet(res.id.slot));
                    std.debug.assert(!self.link_lock.isSet(res.id.slot));
                    switch (op_type) {
                        .link_timeout => {
                            const cid = self.ops.getOne(.prev, res.id);
                            std.debug.assert(!std.meta.eql(cid, res.id));

                            const raced = blk: {
                                for (finished) |res2| if (std.meta.eql(cid, res2.id)) break :blk true;
                                break :blk false;
                            };

                            if (raced) {
                                failure = error.Success;
                            } else {
                                const cres: enum { ok, not_found } = blk: {
                                    _ = self.ops.lookup(cid) catch break :blk .not_found;
                                    std.debug.assert(self.started.isSet(cid.slot));
                                    std.debug.assert(!self.link_lock.isSet(cid.slot));
                                    self.ops.setOne(.next, cid, cid); // sever the link
                                    self.cancel(cid, error.Canceled, backend) catch {};
                                    // ^ even if the operation is not in cancelable state anymore
                                    //   the backend will still wait for it to complete
                                    //   however, the operation chain will be severed
                                    break :blk .ok;
                                };

                                failure = switch (cres) {
                                    .ok => error.Expired,
                                    .not_found => error.Success,
                                };
                            }
                        },
                        else => {},
                    }
                }

                const failed: bool = blk: {
                    if (op_type == .link_timeout and failure == error.Canceled) {
                        break :blk false;
                    } else {
                        break :blk failure != error.Success;
                    }
                };

                if (failed) {
                    debug("complete: {}: {} [FAIL] {}", .{ res.id, op_type, failure });
                } else {
                    debug("complete: {}: {} [OK]", .{ res.id, op_type });
                }

                num_errors += @intFromBool(failed);
                if (self.ops.getOne(.out_error, res.id)) |err| err.* = @errorCast(failure);

                const next = self.ops.getOne(.next, res.id);
                if (!std.meta.eql(next, res.id)) {
                    const link = self.ops.getOne(.link, res.id);
                    const next_type = self.ops.getOne(.type, next);
                    if (next_type == .link_timeout) {
                        const raced = blk: {
                            for (finished) |res2| if (std.meta.eql(next, res2.id)) break :blk true;
                            break :blk false;
                        };
                        if (!raced) {
                            _ = self.ops.lookup(next) catch unreachable; // inconsistent state
                            std.debug.assert(self.started.isSet(next.slot));
                            std.debug.assert(!self.link_lock.isSet(next.slot));
                            _ = switch (link) {
                                .unlinked => unreachable, // inconsistent state
                                .soft => self.cancel(next, error.Success, backend) catch {},
                                .hard => self.cancel(next, error.Success, backend) catch {},
                            };
                        }
                    } else if ((link == .soft or op_type == .link_timeout) and failure != error.Success) {
                        _ = self.ops.lookup(next) catch unreachable; // inconsistent state
                        std.debug.assert(!self.started.isSet(next.slot));
                        std.debug.assert(self.link_lock.isSet(next.slot));
                        self.cancel(next, error.Canceled, backend) catch unreachable;
                    } else {
                        _ = self.ops.lookup(next) catch unreachable; // inconsistent state
                        std.debug.assert(!self.started.isSet(next.slot));
                        std.debug.assert(self.link_lock.isSet(next.slot));
                        self.link_lock.unset(next.slot);
                    }
                }

                backend.uringlator_complete(res.id, op_type, failure);
                const userdata = self.ops.getOne(.userdata, res.id);
                self.ops.release(res.id) catch unreachable; // inconsistent state
                self.started.unset(res.id.slot);

                if (@TypeOf(handler) != void) {
                    handler.aio_complete(res.id, userdata, failed);
                }
            }

            return .{ .num_completed = @truncate(finished.len), .num_errors = num_errors };
        }

        pub const Safety = enum {
            thread_safe,
            thread_unsafe,
        };

        pub fn finish(self: *@This(), backend: anytype, id: aio.Id, failure: Operation.Error, comptime safety: Safety) void {
            debug("finish: {} {}", .{ id, failure });
            self.finished.add(.{ .id = id, .failure = failure }) catch unreachable;
            backend.uringlator_notify(safety);
        }

        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            if (@import("builtin").is_test) {
                std.debug.print("uringlator: " ++ fmt ++ "\n", args);
            } else {
                if (comptime !aio.options.debug) return;
                log.debug(fmt, args);
            }
        }
    };
}
