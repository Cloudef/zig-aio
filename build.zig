const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var opts = b.addOptions();
    const FallbackMode = enum { auto, force, disable };
    const fallback = b.option(FallbackMode, "fallback", "fallback mode [auto, force, disable]") orelse .auto;
    opts.addOption(FallbackMode, "fallback", fallback);

    const minilib = b.addModule("minilib", .{
        .root_source_file = b.path("src/minilib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const aio = b.addModule("aio", .{
        .root_source_file = b.path("src/aio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = switch (target.query.os_tag orelse builtin.os.tag) {
            .windows => true,
            .freebsd, .openbsd, .dragonfly, .netbsd => true,
            else => false,
        },
        .single_threaded = switch (target.query.os_tag orelse builtin.os.tag) {
            .linux => null, // io_uring backend can be used without threads
            else => false,
        },
    });
    aio.addImport("minilib", minilib);
    aio.addImport("build_options", opts.createModule());

    if (target.query.os_tag orelse builtin.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |zigwin32| {
            aio.addImport("win32", zigwin32.module("zigwin32"));
        }
    }

    const coro = b.addModule("coro", .{
        .root_source_file = b.path("src/coro.zig"),
        .target = target,
        .optimize = optimize,
    });
    coro.addImport("minilib", minilib);
    coro.addImport("aio", aio);

    const run_all = b.step("run", "Run all examples");
    inline for (.{
        .aio_dynamic,
        .aio_immediate,
        .coro,
        .coro_wttr,
    }) |example| {
        const exe = b.addExecutable(.{
            .name = @tagName(example),
            .root_source_file = b.path("examples/" ++ @tagName(example) ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = true,
        });
        exe.root_module.addImport("aio", aio);
        exe.root_module.addImport("coro", coro);
        const cmd = b.addRunArtifact(exe);
        cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| cmd.addArgs(args);
        const run = b.step(@tagName(example), "Run " ++ @tagName(example) ++ " example");
        run.dependOn(&cmd.step);
        run_all.dependOn(&cmd.step);
    }

    const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match any filter") orelse "";
    const test_step = b.step("test", "Run unit tests");
    inline for (.{ .minilib, .aio, .coro }) |mod| {
        const tst = b.addTest(.{
            .root_source_file = b.path("src/" ++ @tagName(mod) ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .filters = &.{test_filter},
            .link_libc = aio.link_libc,
            .single_threaded = aio.single_threaded,
            .sanitize_thread = true,
        });
        if (mod != .minilib) tst.root_module.addImport("minilib", minilib);
        if (mod == .aio) tst.root_module.addImport("build_options", opts.createModule());
        if (mod == .coro) tst.root_module.addImport("aio", aio);
        const run = b.addRunArtifact(tst);
        test_step.dependOn(&run.step);
    }
}
