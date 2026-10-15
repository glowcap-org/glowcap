//! The SQLite engine's module, test step, and vacuum crash probe. The crash
//! probes every engine shares are in `crash.zig`.
const std = @import("std");
const execution = @import("../execution.zig");
const Gates = @import("../gates.zig").Registered;
const Engine = @import("crash.zig").Engine;

/// Registers the SQLite module with its tests and vacuum probe.
pub fn register(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, owner_lock: *std.Build.Module, support: *std.Build.Module, temp: *std.Build.Module, gates: Gates) Engine {
    const sqlite = create(b, target, optimize, core, owner_lock, true);
    const tested = configured(b, target, optimize, core, owner_lock, false, true);
    const tests = b.createModule(.{ .root_source_file = b.path("test/loam_sqlite_test.zig"), .target = target, .optimize = optimize, .link_libc = true });
    tests.addImport("loam_test_support", support);
    tests.addImport("loam_core", core);
    tests.addImport("glowcap", b.modules.get("glowcap").?);
    tests.addImport("loam_sqlite", tested);
    const engine_fixture = b.createModule(.{ .root_source_file = b.path("test/loam/sqlite/fixture.zig"), .target = target, .optimize = optimize, .link_libc = true });
    engine_fixture.addImport("loam_core", core);
    engine_fixture.addImport("loam_sqlite", tested);
    engine_fixture.addImport("loam_engine_temp", temp);
    tests.addImport("engine_fixture", engine_fixture);
    const suite = b.addTest(.{ .root_module = tests });
    const run = execution.addZigTest(b, suite, .unit_test);
    const step = b.step("loam-sqlite-test", "Run the durable Loam suite over SQLite and prove each commit refusal changed nothing");
    step.dependOn(&run.step);
    gates.check_step.dependOn(step);
    const compaction_mod = b.createModule(.{ .root_source_file = b.path("test/loam_sqlite_compaction_crash.zig"), .target = target, .optimize = optimize, .link_libc = true });
    compaction_mod.addImport("loam_core", core);
    compaction_mod.addImport("loam_sqlite", sqlite);
    const compaction_probe = b.addExecutable(.{ .name = "loam-sqlite-compaction-crash-probe", .root_module = compaction_mod });
    const compaction_crash = execution.addSystemCommand(b, .{ .deterministic = 20 }, &.{"python3"});
    compaction_crash.addFileArg(b.path("test/loam/engines/crash_test.py"));
    compaction_crash.addArtifactArg(compaction_probe);
    const compaction_step = b.step("loam-sqlite-compaction-crash-test", "Kill a SQLite vacuum mid-run and after it, then find every live row in a usable store");
    compaction_step.dependOn(&compaction_crash.step);
    gates.runtime_gate.add(compaction_step);
    return .{ .name = "sqlite", .module = sqlite, .fixture = engine_fixture };
}

/// One SQLite module for a target, wired to `core`. The profiled bench graph
/// builds its own through this, unregistered.
pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, owner_lock: *std.Build.Module, registered: bool) *std.Build.Module {
    return configured(b, target, optimize, core, owner_lock, registered, false);
}

fn configured(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, owner_lock: *std.Build.Module, registered: bool, inject: bool) *std.Build.Module {
    const options: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/loam/engines/sqlite/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Foreign linkers consume this module through the SQLite C archive.
        // Trap-mode preserves C checks without an implicit Zig UBSan runtime.
        .sanitize_c = .trap,
    };
    const sqlite = if (registered) b.addModule("glowcap_loam_sqlite", options) else b.createModule(options);
    sqlite.addImport("loam_core", core);
    sqlite.addImport("loam_owner_lock", owner_lock);
    // A fetch of the amalgamation zip strips its one top-level directory,
    // so the sources sit at the package root.
    const source = b.dependency("sqlite", .{}).path("");
    sqlite.addIncludePath(source);
    var c_flags: std.ArrayList([]const u8) = .empty;
    c_flags.appendSlice(b.allocator, &flags) catch @panic("out of memory");
    // Linux's fdatasync avoids flushing timestamps; other platforms use
    // SQLite's own synchronous flush policy.
    if (target.result.os.tag == .linux) c_flags.append(b.allocator, "-DHAVE_FDATASYNC=1") catch @panic("out of memory");
    if (inject) c_flags.append(b.allocator, "-Dsqlite3_step=loam_test_real_step") catch @panic("out of memory");
    sqlite.addCSourceFile(.{ .file = source.path(b, "sqlite3.c"), .flags = c_flags.items });
    if (inject) sqlite.addCSourceFile(.{ .file = b.path("test/loam/sqlite/commit_fault.c"), .flags = &.{} });
    return sqlite;
}

const flags = [_][]const u8{
    "-fvisibility=hidden",
    // Each connection is used by one thread at a time, so no
    // connection mutex, and memory statistics cost a mutex per call.
    "-DSQLITE_THREADSAFE=2",
    "-DSQLITE_DEFAULT_MEMSTATUS=0",
    // The engine initializes SQLite once in open and never loads
    // extensions, shares caches, or uses the deprecated interfaces.
    "-DSQLITE_OMIT_AUTOINIT",
    "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLITE_OMIT_SHARED_CACHE",
    "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_DECLTYPE",
    "-DSQLITE_OMIT_PROGRESS_CALLBACK",
    // The commit classification in src/loam/engines/sqlite/mod.zig
    // relies on no frame following the commit frame's sync.
    "-DSQLITE_POWERSAFE_OVERWRITE=1",
    "-DSQLITE_DQS=0",
    "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
    "-DSQLITE_MAX_EXPR_DEPTH=0",
    "-DSQLITE_STRICT_SUBTYPE=1",
};
