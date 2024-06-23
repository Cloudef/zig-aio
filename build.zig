const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var opts = b.addOptions();
    const fallback = b.option(bool, "fallback", "use fallback event loop") orelse false;
    opts.addOption(bool, "fallback", fallback);

    const aio = b.addModule("aio", .{
        .root_source_file = b.path("src/aio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.query.os_tag == .windows,
    });
    aio.addImport("build_options", opts.createModule());

    const coro = b.addModule("coro", .{
        .root_source_file = b.path("src/coro.zig"),
        .target = target,
        .optimize = optimize,
    });
    coro.addImport("aio", aio);

    const run_all = b.step("run", "Run all examples");
    inline for (.{
        .aio_dynamic,
        .aio_immediate,
        .coro,
    }) |example| {
        const exe = b.addExecutable(.{
            .name = @tagName(example),
            .root_source_file = b.path("examples/" ++ @tagName(example) ++ ".zig"),
            .target = target,
            .optimize = optimize,
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
    inline for (.{ .aio, .coro }) |mod| {
        const tst = b.addTest(.{
            .root_source_file = b.path("src/" ++ @tagName(mod) ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .filters = &.{test_filter},
            .link_libc = target.query.os_tag == .windows,
        });
        if (mod == .aio) tst.root_module.addImport("build_options", opts.createModule());
        if (mod == .coro) tst.root_module.addImport("aio", aio);
        const run = b.addRunArtifact(tst);
        test_step.dependOn(&run.step);
    }
}
