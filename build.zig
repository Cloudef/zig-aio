const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sanitize = b.option(bool, "sanitize", "use sanitizers when running examples or tests") orelse false;
    const single_threaded = b.option(bool, "single-threaded", "use only a single thread") orelse null;

    var aio_opts = b.addOptions();
    {
        const debug = b.option(bool, "aio:debug", "enable debug prints") orelse false;
        aio_opts.addOption(bool, "debug", debug);

        const PosixMode = enum { auto, force, disable };
        const posix = b.option(PosixMode, "aio:posix", "posix mode") orelse .auto;
        aio_opts.addOption(PosixMode, "posix", posix);

        const WasiMode = enum { wasi, wasix };
        const wasi = b.option(WasiMode, "aio:wasi", "wasi mode") orelse .wasi;
        aio_opts.addOption(WasiMode, "wasi", wasi);
    }

    var coro_opts = b.addOptions();
    {
        const debug = b.option(bool, "coro:debug", "enable debug prints") orelse false;
        coro_opts.addOption(bool, "debug", debug);
    }

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
    });
    aio.addImport("minilib", minilib);
    aio.addImport("build_options", aio_opts.createModule());

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
    coro.addImport("build_options", coro_opts.createModule());

    const run_all = b.step("example", "Run all examples");
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
            .sanitize_thread = sanitize,
            .single_threaded = if (example == .coro_wttr) false else single_threaded,
            .strip = false,
        });
        exe.root_module.addImport("aio", aio);
        exe.root_module.addImport("coro", coro);
        const install = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "example" } } });
        b.getInstallStep().dependOn(&install.step);
        var cmd = makeRunStep(b, target, exe, "example:" ++ @tagName(example), "Run " ++ @tagName(example) ++ " example", .{});
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
            .sanitize_thread = sanitize,
            .single_threaded = single_threaded,
            .strip = false,
        });
        switch (mod) {
            .minilib => addImportsFrom(&tst.root_module, minilib),
            .aio => addImportsFrom(&tst.root_module, aio),
            .coro => addImportsFrom(&tst.root_module, coro),
            else => unreachable,
        }
        var cmd = makeRunStep(b, target, tst, "test:" ++ @tagName(mod), "Run " ++ @tagName(mod) ++ " tests", .{});
        test_step.dependOn(&cmd.step);
    }

    const bug_step = b.step("bug", "Run regression tests");
    inline for (.{
        .@"22",
        .@"31",
        .@"33",
    }) |bug| {
        const exe = b.addExecutable(.{
            .name = @tagName(bug),
            .root_source_file = b.path("bugs/" ++ @tagName(bug) ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize,
            .single_threaded = single_threaded,
            .strip = false,
        });
        exe.root_module.addImport("aio", aio);
        exe.root_module.addImport("coro", coro);
        var cmd = makeRunStep(b, target, exe, "bug:" ++ @tagName(bug), "Check regression for #" ++ @tagName(bug), .{});
        bug_step.dependOn(&cmd.step);
    }

    const bench_step = b.step("bench", "Run all benchmarks");
    inline for (.{
        .ping_pongs,
        .ticker,
        .flow,
        .aio_nops,
        .coro_nops,
    }) |bench| {
        const exe = b.addExecutable(.{
            .name = @tagName(bench),
            .root_source_file = b.path("bench/" ++ @tagName(bench) ++ ".zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .sanitize_thread = sanitize,
            .single_threaded = if (bench == .ticker) false else single_threaded,
            .strip = false,
        });
        exe.root_module.addImport("aio", aio);
        exe.root_module.addImport("coro", coro);
        const install = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "bench" } } });
        b.getInstallStep().dependOn(&install.step);
        var cmd = makeRunStep(b, target, exe, "bench:" ++ @tagName(bench), "Run " ++ @tagName(bench) ++ " benchmark", .{});
        bench_step.dependOn(&cmd.step);
    }
}

fn addImportsFrom(dst: *std.Build.Module, src: *std.Build.Module) void {
    var iter = src.import_table.iterator();
    while (iter.next()) |e| dst.addImport(e.key_ptr.*, e.value_ptr.*);
}

const RunStepOptions = struct {
    wasm_max_memory: usize = 1e+9, // 1GiB
};

fn runArtifactForStep(b: *std.Build, target: std.Build.ResolvedTarget, step: *std.Build.Step.Compile, opts: RunStepOptions) *std.Build.Step.Run {
    return switch (target.query.os_tag orelse builtin.os.tag) {
        .wasi => blk: {
            step.max_memory = std.mem.alignForward(usize, opts.wasm_max_memory, 65536);
            const wasmtime = b.addSystemCommand(&.{ "wasmtime", "-W", "trap-on-grow-failure=y", "--dir", "." });
            wasmtime.addArtifactArg(step);
            break :blk wasmtime;
        },
        else => b.addRunArtifact(step),
    };
}

fn makeRunStep(b: *std.Build, target: std.Build.ResolvedTarget, step: *std.Build.Step.Compile, name: []const u8, description: []const u8, opts: RunStepOptions) *std.Build.Step.Run {
    const cmd = runArtifactForStep(b, target, step, opts);
    if (b.args) |args| cmd.addArgs(args);
    const run = b.step(name, description);
    run.dependOn(&cmd.step);
    return cmd;
}
