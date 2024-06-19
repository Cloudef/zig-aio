const std = @import("std");
const aio = @import("aio");
const log = std.log.scoped(.aio_dynamic);

pub fn main() !void {
    var f = try std.fs.cwd().openFile("flake.nix", .{});
    defer f.close();
    var buf: [4096]u8 = undefined;
    var len: usize = 0;

    var f2 = try std.fs.cwd().openFile("build.zig.zon", .{});
    defer f2.close();
    var buf2: [4096]u8 = undefined;
    var len2: usize = 0;

    const allocator = std.heap.page_allocator;
    var work = try aio.Dynamic.init(allocator, 16);
    defer work.deinit(allocator);

    try work.queue(.{
        aio.Read{
            .file = f,
            .buffer = &buf,
            .out_read = &len,
        },
        aio.Read{
            .file = f2,
            .buffer = &buf2,
            .out_read = &len2,
        },
    });

    var num_work: u16 = 2;
    while (num_work > 0) {
        const ret = try work.complete(.blocking);
        num_work -= ret.num_completed;
    }

    log.info("{s}", .{buf[0..len]});
    log.info("{s}", .{buf2[0..len2]});
}
