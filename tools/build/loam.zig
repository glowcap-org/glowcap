//! Loam benches, the profile, and the portable Wasm check, over the engines registered under loam/.
const std = @import("std");
const execution = @import("execution.zig");
const Gates = @import("gates.zig").Registered;
const profile_build = @import("profile.zig");
const lmdb_build = @import("loam/lmdb.zig");
const sqlite_build = @import("loam/sqlite.zig");
const owner_lock_build = @import("loam/owner_lock.zig");
const crash_build = @import("loam/crash.zig");

/// The disk engine modules, each registered with its own test step.
pub const Engines = struct { lmdb: *std.Build.Module, sqlite: *std.Build.Module };

pub fn register(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, gates: Gates, profiles: profile_build.Profiles) Engines {
    const owner_lock = owner_lock_build.create(b, target, optimize);
    const support = b.createModule(.{ .root_source_file = b.path("test/loam/core/fixture.zig"), .target = target, .optimize = optimize });
    support.addImport("glowcap", b.modules.get("glowcap").?);
    const temp = b.createModule(.{ .root_source_file = b.path("test/loam/engines/temp.zig"), .target = target, .optimize = optimize });
    const lmdb_engine = lmdb_build.register(b, target, optimize, core, owner_lock, support, temp, gates);
    const sqlite_engine = sqlite_build.register(b, target, optimize, core, owner_lock, support, temp, gates);
    crash_build.register(b, target, optimize, core, &.{ lmdb_engine, sqlite_engine }, gates);
    @import("loam/io_fault.zig").register(b, target, optimize, core, &.{ lmdb_engine, sqlite_engine }, gates);
    const engines: Engines = .{ .lmdb = lmdb_engine.module, .sqlite = sqlite_engine.module };
    const bench = benchExecutable(b, "loam-bench", .{ .root_source_file = b.path("bench/loam_bench.zig"), .target = target, .optimize = optimize }, b.modules.get("glowcap").?, engines);
    const bench_run = execution.addArtifact(b, .benchmark, bench);
    bench_run.addPassthruArgs();
    b.step("bench-loam", "Measure Loam residency, wakeups, edits, collection interference, and the Tasks app on either disk engine").dependOn(&bench_run.step);
    const bench_smoke = execution.addArtifact(b, .{ .deterministic = 30 }, bench);
    bench_smoke.addArg("--smoke");
    gates.check_step.dependOn(&bench_smoke.step);
    // The same bench over the profiled graph, with its own engines for that target.
    const profiled_owner_lock = owner_lock_build.create(b, profiles.target, profile_build.Profiles.optimize);
    const profiled_engines: Engines = .{
        .lmdb = lmdb_build.create(b, profiles.target, profile_build.Profiles.optimize, profiles.module("loam_core"), profiled_owner_lock, false),
        .sqlite = sqlite_build.create(b, profiles.target, profile_build.Profiles.optimize, profiles.module("loam_core"), profiled_owner_lock, false),
    };
    const profiled = benchExecutable(b, "loam-profile", profiles.moduleOptions(b, "bench/loam_bench.zig"), profiles.module("glowcap"), profiled_engines);
    b.step("profile-loam", "Profile bench-loam under callgrind: self cost per file and function for each marked phase, taking bench-loam's filters after --").dependOn(profile_build.addRun(b, profiles, profiled));
    portableCheck(b, optimize, gates);
    return engines;
}

fn portableCheck(b: *std.Build, optimize: std.builtin.OptimizeMode, gates: Gates) void {
    const root = @import("../../build.zig");
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const modules = root.graphFromTable(b, target, optimize, &root.layer_table, false);
    const tests = b.createModule(.{ .root_source_file = b.path("test/loam_core_wasm.zig"), .target = target, .optimize = optimize });
    tests.addImport("loam", modules[root.layerIndex("loam")]);
    const compiled = b.addExecutable(.{ .name = "loam-core-wasm", .root_module = tests });
    compiled.entry = .disabled;
    compiled.rdynamic = true;
    const step = b.step("loam-core-wasm-check", "Compile portable Loam record and transaction calls for 32-bit Wasm without LMDB");
    step.dependOn(&compiled.step);
    gates.check_step.dependOn(step);
}

/// The Loam bench over one module graph: the bench root with its process
/// memory probe, the Tasks app's own storage so the benchmark measures the
/// app and no copy of it, and the allocation meters.
fn benchExecutable(b: *std.Build, name: []const u8, options: std.Build.Module.CreateOptions, glowcap: *std.Build.Module, engines: Engines) *std.Build.Step.Compile {
    var bench_options = options;
    bench_options.link_libc = true;
    const bench_mod = b.createModule(bench_options);
    bench_mod.addCSourceFile(.{ .file = b.path("bench/loam/process_memory.c"), .flags = &.{"-fvisibility=hidden"} });
    bench_mod.addImport("glowcap", glowcap);
    bench_mod.addImport("loam_lmdb", engines.lmdb);
    bench_mod.addImport("loam_sqlite", engines.sqlite);
    const tasks_storage = b.createModule(.{ .root_source_file = b.path("apps/tasks/zig/storage.zig"), .target = options.target, .optimize = options.optimize, .link_libc = true });
    tasks_storage.addImport("glowcap", glowcap);
    bench_mod.addImport("tasks_storage", tasks_storage);
    bench_mod.addImport("alloc_metrics", b.createModule(.{ .root_source_file = b.path("test/support/alloc_metrics.zig"), .target = options.target, .optimize = options.optimize }));
    return b.addExecutable(.{ .name = name, .root_module = bench_mod });
}
