//! The LMDB engine's module, test step, and offline replacement probe. The
//! crash probes every engine shares are in `crash.zig`.
const std = @import("std");
const execution = @import("../execution.zig");
const Gates = @import("../gates.zig").Registered;
const Engine = @import("crash.zig").Engine;

/// Registers the LMDB module with its tests and replacement probe.
pub fn register(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, custody: *std.Build.Module, support: *std.Build.Module, temp: *std.Build.Module, gates: Gates) Engine {
    const lmdb = create(b, target, optimize, core, custody, true);
    const tested = b.createModule(moduleOptions(b, target, optimize));
    wire(b, tested, core, custody, true);
    const tests = b.createModule(.{ .root_source_file = b.path("test/loam_lmdb_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    tests.addImport("loam_test_support", support);
    tests.addImport("loam_core", core);
    tests.addImport("glowcap", b.modules.get("glowcap").?);
    tests.addImport("loam_lmdb", tested);
    tests.addImport("engine_fixture", fixture(b, target, optimize, core, tested, temp));
    const suite = b.addTest(.{ .root_module = tests });
    const run = execution.addZigTest(b, suite, .unit_test);
    const step = b.step("loam-lmdb-test", "Exercise Loam atomicity, bounded reads, and LMDB reopen recovery");
    step.dependOn(&run.step);
    gates.check_step.dependOn(step);
    const compaction_mod = b.createModule(.{ .root_source_file = b.path("test/loam_compaction_crash.zig"), .target = target, .optimize = optimize, .link_libc = true });
    compaction_mod.addImport("loam_core", core);
    compaction_mod.addImport("loam_lmdb", lmdb);
    const compaction_probe = b.addExecutable(.{ .name = "loam-lmdb-compaction-crash-probe", .root_module = compaction_mod });
    const compaction_crash = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"python3"});
    compaction_crash.addFileArg(b.path("test/loam/lmdb/compaction_crash_test.py"));
    compaction_crash.addArtifactArg(compaction_probe);
    const compaction_step = b.step("loam-lmdb-compaction-crash-test", "Interrupt offline LMDB replacement and refuse duplicate owners and incomplete copies");
    compaction_step.dependOn(&compaction_crash.step);
    gates.runtime_gate.add(compaction_step);
    return .{ .name = "lmdb", .module = lmdb, .fixture = fixture(b, target, optimize, core, lmdb, temp) };
}

fn fixture(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, lmdb: *std.Build.Module, temp: *std.Build.Module) *std.Build.Module {
    const result = b.createModule(.{ .root_source_file = b.path("test/loam/lmdb/fixture.zig"), .target = target, .optimize = optimize, .link_libc = true });
    result.addImport("loam_core", core);
    result.addImport("loam_lmdb", lmdb);
    result.addImport("loam_engine_temp", temp);
    return result;
}

/// One LMDB module for a target, wired to `core`. The profiled bench graph
/// builds its own through this, unregistered.
pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, custody: *std.Build.Module, registered: bool) *std.Build.Module {
    const options = moduleOptions(b, target, optimize);
    const lmdb = if (registered) b.addModule("glowcap_loam_lmdb", options) else b.createModule(options);
    wire(b, lmdb, core, custody, false);
    return lmdb;
}

fn moduleOptions(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) std.Build.Module.CreateOptions {
    return .{
        .root_source_file = b.path("src/loam/engines/lmdb/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Foreign linkers consume this module through the LMDB C archive.
        // Trap-mode preserves C checks without an implicit Zig UBSan runtime.
        .sanitize_c = .trap,
    };
}

fn wire(b: *std.Build, lmdb: *std.Build.Module, core: *std.Build.Module, custody: *std.Build.Module, inject: bool) void {
    lmdb.addImport("loam_core", core);
    lmdb.addImport("loam_custody", custody);
    const lmdb_source = b.dependency("lmdb", .{}).path("libraries/liblmdb");
    lmdb.addIncludePath(lmdb_source);
    const generator = b.addExecutable(.{ .name = "checked-lmdb", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/gen/checked_lmdb.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }) });
    const checked = execution.addArtifact(b, .build_tool, generator);
    checked.addFileArg(lmdb_source.path(b, "mdb.c"));
    checked.addFileArg(b.path("src/loam/engines/lmdb/page_io.h"));
    const checked_source = checked.addOutputFileArg("mdb.c");
    const common_flags = [_][]const u8{ "-fvisibility=hidden", "-pthread", "-DMDB_RPAGE_CACHE=3" };
    const flags: []const []const u8 = if (inject)
        &(common_flags ++ .{ "-Dmdb_txn_commit=loam_test_real_commit", "-Dmdb_env_sync=loam_test_real_sync", "-Dmdb_get=loam_test_real_get", "-Dmdb_cursor_get=loam_test_real_cursor_get" })
    else
        &common_flags;
    lmdb.addCSourceFile(.{ .file = checked_source, .flags = flags });
    lmdb.addCSourceFiles(.{
        .root = lmdb_source,
        .files = &.{"midl.c"},
        .flags = flags,
    });
    if (inject) {
        lmdb.addCSourceFile(.{ .file = b.path("test/loam/lmdb/commit_fault.c"), .flags = &.{} });
        lmdb.addCSourceFile(.{ .file = b.path("test/loam/lmdb/borrow_fault.c"), .flags = &.{} });
    }
    lmdb.addCSourceFile(.{ .file = b.path("src/loam/engines/lmdb/replacement.c"), .flags = &.{"-fvisibility=hidden"} });
}
