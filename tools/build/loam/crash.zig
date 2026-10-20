//! The process crash probes every disk engine runs. Each probe step builds
//! one probe per engine from the same source and kills each at the same
//! boundaries, so a step's name says what is interrupted, never which engine.
const std = @import("std");
const execution = @import("../execution.zig");
const Gates = @import("../gates.zig").Registered;

/// A registered disk engine: its module and the `engine_fixture` module its
/// tests and probes open stores through.
pub const Engine = struct { name: []const u8, module: *std.Build.Module, fixture: *std.Build.Module };

/// What one probe runs: its source, deadline, and the scenarios and extra
/// boundaries the driver kills it at.
const Probe = struct {
    source: []const u8,
    deadline: u8,
    scenarios: []const []const u8 = &.{},
    boundaries: []const []const u8 = &.{},
};

/// One `loam-<probe>-crash-test` step per probe, each running that probe
/// over every engine in `engines`, all under the runtime gate.
pub fn register(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, engines: []const Engine, gates: Gates) void {
    const Run = struct {
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        core: *std.Build.Module,
        engines: []const Engine,

        fn add(self: @This(), step: *std.Build.Step, name: []const u8, probe: Probe) void {
            for (self.engines) |engine| {
                const root = self.b.createModule(.{ .root_source_file = self.b.path(probe.source), .target = self.target, .optimize = self.optimize, .link_libc = true });
                root.addImport("loam_core", self.core);
                root.addImport("glowcap", self.b.modules.get("glowcap").?);
                root.addImport("engine_fixture", engine.fixture);
                const executable = self.b.addExecutable(.{ .name = self.b.fmt("loam-{s}-crash-probe-{s}", .{ name, engine.name }), .root_module = root });
                const run = execution.addSystemCommand(self.b, .{ .deterministic = probe.deadline }, &.{"python3"});
                run.addFileArg(self.b.path("test/loam/engines/crash_test.py"));
                run.addArtifactArg(executable);
                for (probe.scenarios) |scenario| run.addArgs(&.{ "--scenario", scenario });
                for (probe.boundaries) |boundary| run.addArgs(&.{ "--boundary", boundary });
                step.dependOn(&run.step);
            }
        }
    };
    const runs: Run = .{ .b = b, .target = target, .optimize = optimize, .core = core, .engines = engines };

    const storage_step = b.step("loam-storage-crash-test", "Kill Loam writers before commit and after commit before local installation, on every disk engine (needs python3)");
    runs.add(storage_step, "storage", .{ .source = "test/loam_storage_crash.zig", .deadline = 20 });
    gates.runtime_gate.add(storage_step);

    const actors_step = b.step("loam-actors-crash-test", "Kill a CapTP actor turn around commit and restore callable cyclic capabilities, on every disk engine");
    runs.add(actors_step, "actors", .{ .source = "test/loam_actors_crash.zig", .deadline = 20 });
    gates.runtime_gate.add(actors_step);

    const managed_step = b.step("loam-managed-crash-test", "Kill managed CapTP mutations around commit, installation, and reply delivery, on every disk engine");
    runs.add(managed_step, "managed", .{
        .source = "test/loam_managed_crash.zig",
        .deadline = 30,
        .scenarios = &.{ "derive", "managed", "attenuate", "revoke", "add", "remove", "move", "delete", "observe", "cancel", "retire", "cleanup" },
        .boundaries = &.{ "before", "after", "installed", "published" },
    });
    gates.runtime_gate.add(managed_step);

    const references_step = b.step("loam-references-crash-test", "Kill checked foreign reference writes and restore exact authority roles in fresh vats, on every disk engine");
    runs.add(references_step, "references", .{
        .source = "test/loam_references_crash.zig",
        .deadline = 30,
        .scenarios = &.{ "original", "use", "control" },
        .boundaries = &.{ "before", "after", "installed" },
    });
    gates.runtime_gate.add(references_step);

    const collection_step = b.step("loam-collection-crash-test", "Kill a tracing collection pass around commit and safely restart collection, on every disk engine");
    runs.add(collection_step, "collection", .{ .source = "test/loam_collection_crash.zig", .deadline = 20 });
    gates.runtime_gate.add(collection_step);
}
