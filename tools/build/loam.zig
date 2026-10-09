//! Optional LMDB Loam backend and its persistence evidence.
const std = @import("std");
const execution = @import("execution.zig");
const Gates = @import("gates.zig").Registered;

pub fn register(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, gates: Gates) *std.Build.Module {
    const lmdb = b.addModule("glowcap_loam_lmdb", .{
        .root_source_file = b.path("src/loam/backends/lmdb/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Foreign linkers consume this module through the LMDB C archive.
        // Trap-mode preserves C checks without an implicit Zig UBSan runtime.
        .sanitize_c = .trap,
    });
    lmdb.addImport("loam_core", core);
    lmdb.addIncludePath(b.path("third_party/lmdb"));
    lmdb.addCSourceFiles(.{
        .root = b.path("third_party/lmdb"),
        .files = &.{ "mdb.c", "midl.c" },
        .flags = &.{ "-fvisibility=hidden", "-pthread" },
    });
    lmdb.addCSourceFile(.{ .file = b.path("src/loam/backends/lmdb/lock.c"), .flags = &.{"-fvisibility=hidden"} });
    lmdb.addCSourceFile(.{ .file = b.path("src/loam/backends/lmdb/replacement.c"), .flags = &.{"-fvisibility=hidden"} });
    const bench_mod = b.createModule(.{ .root_source_file = b.path("bench/loam_bench.zig"), .target = target, .optimize = optimize, .link_libc = true });
    bench_mod.addCSourceFile(.{ .file = b.path("bench/loam/process_memory.c"), .flags = &.{"-fvisibility=hidden"} });
    bench_mod.addImport("glowcap", b.modules.get("glowcap").?);
    bench_mod.addImport("loam_lmdb", lmdb);
    bench_mod.addImport("alloc_metrics", b.createModule(.{ .root_source_file = b.path("test/support/alloc_metrics.zig"), .target = target, .optimize = optimize }));
    const bench = b.addExecutable(.{ .name = "loam-bench", .root_module = bench_mod });
    const bench_run = execution.addArtifact(b, .benchmark, bench);
    bench_run.addPassthruArgs();
    b.step("bench-loam", "Measure LMDB-backed Loam residency, wakeups, edits, and collection interference").dependOn(&bench_run.step);
    const bench_smoke = execution.addArtifact(b, .{ .deterministic = 30 }, bench);
    bench_smoke.addArg("--smoke");
    gates.check_step.dependOn(&bench_smoke.step);
    const tests = b.createModule(.{ .root_source_file = b.path("test/loam_lmdb_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const support = b.createModule(.{ .root_source_file = b.path("test/loam/core/fixture.zig"), .target = target, .optimize = optimize });
    support.addImport("glowcap", b.modules.get("glowcap").?);
    tests.addImport("loam_test_support", support);
    tests.addImport("loam_core", core);
    tests.addImport("glowcap", b.modules.get("glowcap").?);
    tests.addImport("loam_lmdb", lmdb);
    const suite = b.addTest(.{ .root_module = tests });
    const run = execution.addZigTest(b, suite, .unit_test);
    const step = b.step("loam-lmdb-test", "Exercise Loam atomicity, bounded reads, and LMDB reopen recovery");
    step.dependOn(&run.step);
    gates.check_step.dependOn(step);
    portableCheck(b, optimize, gates);
    const probe_mod = b.createModule(.{ .root_source_file = b.path("test/loam_lmdb_crash.zig"), .target = target, .optimize = optimize, .link_libc = true });
    probe_mod.addImport("loam_core", core);
    probe_mod.addImport("loam_lmdb", lmdb);
    probe_mod.addImport("glowcap", b.modules.get("glowcap").?);
    const probe = b.addExecutable(.{ .name = "loam-lmdb-crash-probe", .root_module = probe_mod });
    const crash = execution.addSystemCommand(b, .{ .deterministic = 20 }, &.{"python3"});
    crash.addFileArg(b.path("test/loam/lmdb/crash_test.py"));
    crash.addArtifactArg(probe);
    const crash_step = b.step("loam-lmdb-crash-test", "Kill Loam writers before commit and after commit before local installation");
    crash_step.dependOn(&crash.step);
    gates.runtime_gate.add(crash_step);
    const actor_mod = b.createModule(.{ .root_source_file = b.path("test/loam_actors_crash.zig"), .target = target, .optimize = optimize, .link_libc = true });
    actor_mod.addImport("loam_lmdb", lmdb);
    actor_mod.addImport("glowcap", b.modules.get("glowcap").?);
    const actor_probe = b.addExecutable(.{ .name = "loam-actors-crash-probe", .root_module = actor_mod });
    const actor_crash = execution.addSystemCommand(b, .{ .deterministic = 20 }, &.{"python3"});
    actor_crash.addFileArg(b.path("test/loam/lmdb/crash_test.py"));
    actor_crash.addArtifactArg(actor_probe);
    const actor_step = b.step("loam-actors-crash-test", "Kill a CapTP actor turn around LMDB commit and restore callable cyclic capabilities");
    actor_step.dependOn(&actor_crash.step);
    gates.runtime_gate.add(actor_step);
    const managed_mod = b.createModule(.{ .root_source_file = b.path("test/loam_managed_crash.zig"), .target = target, .optimize = optimize, .link_libc = true });
    managed_mod.addImport("loam_lmdb", lmdb);
    managed_mod.addImport("glowcap", b.modules.get("glowcap").?);
    const managed_probe = b.addExecutable(.{ .name = "loam-managed-crash-probe", .root_module = managed_mod });
    const managed_crash = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"python3"});
    managed_crash.addFileArg(b.path("test/loam/lmdb/crash_test.py"));
    managed_crash.addArtifactArg(managed_probe);
    for ([_][]const u8{ "derive", "managed", "attenuate", "revoke", "add", "remove", "move", "delete", "observe", "cancel", "retire", "cleanup" }) |scenario| managed_crash.addArgs(&.{ "--scenario", scenario });
    for ([_][]const u8{ "before", "after", "installed", "published" }) |boundary| managed_crash.addArgs(&.{ "--boundary", boundary });
    const managed_step = b.step("loam-managed-crash-test", "Kill managed CapTP mutations around commit, installation, and reply delivery");
    managed_step.dependOn(&managed_crash.step);
    gates.runtime_gate.add(managed_step);
    const reference_mod = b.createModule(.{ .root_source_file = b.path("test/loam_references_crash.zig"), .target = target, .optimize = optimize, .link_libc = true });
    reference_mod.addImport("loam_lmdb", lmdb);
    reference_mod.addImport("glowcap", b.modules.get("glowcap").?);
    const reference_probe = b.addExecutable(.{ .name = "loam-references-crash-probe", .root_module = reference_mod });
    const reference_crash = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"python3"});
    reference_crash.addFileArg(b.path("test/loam/lmdb/crash_test.py"));
    reference_crash.addArtifactArg(reference_probe);
    for ([_][]const u8{ "original", "use", "control" }) |scenario| reference_crash.addArgs(&.{ "--scenario", scenario });
    for ([_][]const u8{ "before", "after", "installed" }) |boundary| reference_crash.addArgs(&.{ "--boundary", boundary });
    const reference_step = b.step("loam-references-crash-test", "Kill checked foreign reference writes and restore exact authority roles in fresh vats");
    reference_step.dependOn(&reference_crash.step);
    gates.runtime_gate.add(reference_step);
    const collection_mod = b.createModule(.{ .root_source_file = b.path("test/loam_collection_crash.zig"), .target = target, .optimize = optimize, .link_libc = true });
    collection_mod.addImport("loam_core", core);
    collection_mod.addImport("loam_lmdb", lmdb);
    collection_mod.addImport("glowcap", b.modules.get("glowcap").?);
    const collection_probe = b.addExecutable(.{ .name = "loam-collection-crash-probe", .root_module = collection_mod });
    const collection_crash = execution.addSystemCommand(b, .{ .deterministic = 20 }, &.{"python3"});
    collection_crash.addFileArg(b.path("test/loam/lmdb/crash_test.py"));
    collection_crash.addArtifactArg(collection_probe);
    const collection_step = b.step("loam-collection-crash-test", "Kill a tracing sweep around LMDB commit and safely restart collection");
    collection_step.dependOn(&collection_crash.step);
    gates.runtime_gate.add(collection_step);
    const compaction_mod = b.createModule(.{ .root_source_file = b.path("test/loam_compaction_crash.zig"), .target = target, .optimize = optimize, .link_libc = true });
    compaction_mod.addImport("loam_core", core);
    compaction_mod.addImport("loam_lmdb", lmdb);
    const compaction_probe = b.addExecutable(.{ .name = "loam-compaction-crash-probe", .root_module = compaction_mod });
    const compaction_crash = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"python3"});
    compaction_crash.addFileArg(b.path("test/loam/lmdb/compaction_crash_test.py"));
    compaction_crash.addArtifactArg(compaction_probe);
    const compaction_step = b.step("loam-compaction-crash-test", "Interrupt offline LMDB replacement and refuse duplicate owners and incomplete copies");
    compaction_step.dependOn(&compaction_crash.step);
    gates.runtime_gate.add(compaction_step);
    return lmdb;
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
