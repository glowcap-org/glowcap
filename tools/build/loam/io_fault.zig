//! Linux write, sync and read fault probes for both production disk engines.
const std = @import("std");
const execution = @import("../execution.zig");
const Gates = @import("../gates.zig").Registered;
const Engine = @import("crash.zig").Engine;

pub fn register(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, core: *std.Build.Module, engines: []const Engine, gates: Gates) void {
    const step = b.step("loam-io-fault-test", "Fail Linux writes, syncs and reads, and cut data files short, on both disk engines (needs python3)");
    // The syscall interposer is Linux-specific. An explicitly requested step
    // on another target fails compilation instead of reporting empty success.
    if (target.result.os.tag == .linux) gates.runtime_gate.add(step);
    for (engines) |engine| {
        const root = b.createModule(.{ .root_source_file = b.path("test/loam_io_fault.zig"), .target = target, .optimize = optimize, .link_libc = true });
        root.addImport("loam_core", core);
        root.addImport("glowcap", b.modules.get("glowcap").?);
        root.addImport("engine_fixture", engine.fixture);
        root.addCSourceFile(.{ .file = b.path("test/loam/engines/io_fault/syscalls.c"), .flags = &.{} });
        root.linkSystemLibrary("dl", .{});
        const probe = b.addExecutable(.{ .name = b.fmt("loam-io-fault-{s}", .{engine.name}), .root_module = root });
        const run = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{"python3"});
        run.addFileArg(b.path("test/loam/engines/io_fault/run.py"));
        run.addArtifactArg(probe);
        run.addArg(engine.name);
        step.dependOn(&run.step);
    }
}
