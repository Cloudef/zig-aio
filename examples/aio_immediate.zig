const std = @import("std");
const aio = @import("aio");
const log = std.log.scoped(.aio_immediate);

pub fn main() !void {
    var f = try std.fs.cwd().openFile("flake.nix", .{});
    defer f.close();
    var buf: [4096]u8 = undefined;
    var len: usize = 0;

    var f2 = try std.fs.cwd().openFile("build.zig.zon", .{});
    defer f2.close();
    var buf2: [4096]u8 = undefined;
    var len2: usize = 0;

    const num_errors = try aio.complete(.{
        aio.op(.read, .{
            .file = f,
            .buffer = &buf,
            .out_read = &len,
        }, .unlinked),
        aio.op(.read, .{
            .file = f2,
            .buffer = &buf2,
            .out_read = &len2,
        }, .unlinked),
    });

    log.info("{s}", .{buf[0..len]});
    log.info("{s}", .{buf2[0..len2]});
    log.info("{}", .{num_errors});
}
