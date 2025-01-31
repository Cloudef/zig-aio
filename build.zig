const builtin = @import("builtin");
const std = @import("std");

const WASM_MEMORY_LIMIT: usize = 1e+9; // 1GiB

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    switch (target.query.os_tag orelse builtin.os.tag) {
        .wasi => {
            target.query.cpu_features_add.addFeature(@intFromEnum(std.Target.wasm.Feature.atomics));
            target.query.cpu_features_add.addFeature(@intFromEnum(std.Target.wasm.Feature.bulk_memory));
        },
        else => {},
    }

    const sanitize = b.option(bool, "sanitize", "use sanitizers when running examples or tests") orelse false;

    var aio_opts = b.addOptions();
    {
        const debug = b.option(bool, "aio:debug", "enable debug prints") orelse false;
        aio_opts.addOption(bool, "debug", debug);

        const PosixMode = enum { auto, force, disable };
        const posix = b.option(PosixMode, "aio:posix", "posix mode [auto, force, disable]") orelse .auto;
        aio_opts.addOption(PosixMode, "posix", posix);

        const WasiMode = enum { wasi, wasix };
        const wasi = b.option(WasiMode, "aio:wasi", "wasi mode [wasi, wasix]") orelse .wasi;
        aio_opts.addOption(WasiMode, "wasi", wasi);
    }

    var coro_opts = b.addOptions();
    {
        const debug = b.option(bool, "coro:debug", "enable debug prints") orelse false;
        coro_opts.addOption(bool, "debug", debug);
    }

    var minilib_opts = b.addOptions();
    {
        const force_foreign_timer_queue = b.option(bool, "minilib:force_foreign_timer_queue", "force the use of foreign timer queue backend") orelse false;
        minilib_opts.addOption(bool, "force_foreign_timer_queue", force_foreign_timer_queue);
    }

    const minilib = b.addModule("minilib", .{
        .root_source_file = b.path("src/minilib.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = switch (target.query.os_tag orelse builtin.os.tag) {
            .linux => null, // io_uring backend can be used without threads
            else => false,
        },
    });
    minilib.addImport("build_options", minilib_opts.createModule());

    const aio = b.addModule("aio", .{
        .root_source_file = b.path("src/aio.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = switch (target.query.os_tag orelse builtin.os.tag) {
            .windows => true,
            .freebsd, .openbsd, .dragonfly, .netbsd => true,
            else => false,
        },
        .single_threaded = minilib.single_threaded,
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
            .single_threaded = minilib.single_threaded,
            .strip = false,
        });
        exe.root_module.addImport("aio", aio);
        exe.root_module.addImport("coro", coro);
        var cmd = makeRunStep(b, target, exe, WASM_MEMORY_LIMIT, "example:" ++ @tagName(example), "Run " ++ @tagName(example) ++ " example");
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
            .single_threaded = minilib.single_threaded,
            .sanitize_thread = sanitize,
            .strip = false,
        });
        switch (mod) {
            .minilib => addImportsFrom(&tst.root_module, minilib),
            .aio => addImportsFrom(&tst.root_module, aio),
            .coro => addImportsFrom(&tst.root_module, coro),
            else => unreachable,
        }
        var cmd = makeRunStep(b, target, tst, WASM_MEMORY_LIMIT, "test:" ++ @tagName(mod), "Run " ++ @tagName(mod) ++ " tests");
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
            .single_threaded = minilib.single_threaded,
            .strip = false,
        });
        exe.root_module.addImport("aio", aio);
        exe.root_module.addImport("coro", coro);
        var cmd = makeRunStep(b, target, exe, WASM_MEMORY_LIMIT, "bug:" ++ @tagName(bug), "Check regression for #" ++ @tagName(bug));
        bug_step.dependOn(&cmd.step);
    }

    const bench_step = b.step("bench", "Run all benchmarks");
    inline for (.{
        .ping_pongs,
        .ticker,
        .flow,
    }) |bench| {
        const exe = b.addExecutable(.{
            .name = @tagName(bench),
            .root_source_file = b.path("bench/" ++ @tagName(bench) ++ ".zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .sanitize_thread = sanitize,
            .single_threaded = minilib.single_threaded,
            .strip = false,
        });
        exe.root_module.addImport("aio", aio);
        exe.root_module.addImport("coro", coro);
        var cmd = makeRunStep(b, target, exe, WASM_MEMORY_LIMIT, "bench:" ++ @tagName(bench), "Run " ++ @tagName(bench) ++ " benchmark");
        bench_step.dependOn(&cmd.step);
    }
}

fn addImportsFrom(dst: *std.Build.Module, src: *std.Build.Module) void {
    var iter = src.import_table.iterator();
    while (iter.next()) |e| dst.addImport(e.key_ptr.*, e.value_ptr.*);
}

fn makeRunStep(b: *std.Build, target: std.Build.ResolvedTarget, step: *std.Build.Step.Compile, max_memory: usize, name: []const u8, description: []const u8) *std.Build.Step.Run {
    const cmd = switch (target.query.os_tag orelse builtin.os.tag) {
        .wasi => blk: {
            step.shared_memory = true;
            step.max_memory = std.mem.alignForward(usize, max_memory, 65536);
            step.import_memory = true;
            step.export_memory = true;
            step.root_module.export_symbol_names = &.{"wasi_thread_start"};
            const wasmtime = b.addSystemCommand(&.{ "wasmtime", "-W", "trap-on-grow-failure=y", "-S", "threads=y", "--dir", "." });
            wasmtime.addArtifactArg(step);
            break :blk wasmtime;
        },
        else => b.addRunArtifact(step),
    };
    if (b.args) |args| cmd.addArgs(args);
    const run = b.step(name, description);
    run.dependOn(&cmd.step);
    return cmd;
}
