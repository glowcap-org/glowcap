//! The paired Rust interface benchmark and generator process measurement.
const std = @import("std");
const commands = @import("commands.zig");
const execution = @import("execution.zig");
const profile = @import("profile.zig");

pub fn register(b: *std.Build, optimize: std.builtin.OptimizeMode, runtime_gate: *execution.RuntimeGate, profiles: profile.Profiles) void {
    const marks_module = b.createModule(.{
        .root_source_file = b.path("bench/interface/marks.zig"),
        .target = profiles.target,
        .optimize = .ReleaseFast,
        .valgrind = true,
    });
    marks_module.addImport("profile", b.createModule(profiles.moduleOptions(b, "bench/support/profile.zig")));
    const marks = b.addLibrary(.{ .name = "interface_bench_marks", .linkage = .static, .root_module = marks_module });
    const build = commands.addInstalledSystemRun(b, .build_tool, &.{"env"});
    build.addFileArg2(marks.getEmittedBin(), .{ .prefix = "GLOWCAP_INTERFACE_MARKS=", .make_absolute = true });
    build.addArgs(&.{ "cargo", "build", "--locked", "--release", "--manifest-path", "bench/interface/Cargo.toml" });
    const metrics_build = commands.addInstalledSystemRun(b, .build_tool, &.{"env"});
    metrics_build.addFileArg2(marks.getEmittedBin(), .{ .prefix = "GLOWCAP_INTERFACE_MARKS=", .make_absolute = true });
    metrics_build.addArgs(&.{ "cargo", "build", "--locked", "--release", "--manifest-path", "bench/interface/Cargo.toml", "--features", "allocation-metrics", "--target-dir", "zig-out/interface-allocation" });
    const binary = "bench/interface/target/release/interface-bench";
    const run = commands.addRootedSystemCommand(b, .benchmark, &.{ "python3", "bench/interface/measure.py", "--latency", binary });
    run.setEnvironmentVariable("GLOWCAP_BENCH_ZIG_OPTIMIZE", @tagName(optimize));
    run.step.dependOn(&build.step);
    run.addPassthruArgs();
    run.has_side_effects = true;
    b.step("bench-interface", "Compare raw and generated Rust calls over the same TCP workflow (needs cargo)").dependOn(&run.step);
    const diagnostics = commands.addRootedSystemCommand(b, .benchmark, &.{ "python3", "bench/interface/measure.py", "--diagnostics", "zig-out/interface-allocation/release/interface-bench" });
    diagnostics.setEnvironmentVariable("GLOWCAP_BENCH_ZIG_OPTIMIZE", @tagName(optimize));
    diagnostics.step.dependOn(&metrics_build.step);
    diagnostics.addPassthruArgs();
    diagnostics.has_side_effects = true;
    b.step("bench-interface-diagnostics", "Measure paired Rust interface allocation traffic and wire messages separately from latency (needs cargo)").dependOn(&diagnostics.step);
    const smoke = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "bench/interface/measure.py", "--smoke", "zig-out/interface-allocation/release/interface-bench" });
    smoke.step.dependOn(&metrics_build.step);
    const measurement_test = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "-m", "unittest", "discover", "-s", "bench/interface", "-p", "measure_test.py" });
    smoke.step.dependOn(&measurement_test.step);
    const lint = commands.addInstalledSystemRun(b, .build_tool, &.{"env"});
    lint.addFileArg2(marks.getEmittedBin(), .{ .prefix = "GLOWCAP_INTERFACE_MARKS=", .make_absolute = true });
    lint.addArgs(&.{ "cargo", "clippy", "--locked", "--release", "--manifest-path", "bench/interface/Cargo.toml", "--all-targets", "--all-features", "--target-dir", "zig-out/interface-allocation", "--", "-D", "warnings" });
    const lint_step = b.step("interface-bench-lint", "Lint the paired interface benchmark and its diagnostic allocation feature (needs cargo)");
    lint_step.dependOn(&lint.step);
    smoke.step.dependOn(lint_step);
    const compile_cost = commands.addInstalledSystemRun(b, .benchmark, &.{ "python3", "bench/interface/compile.py", "--marks" });
    compile_cost.addFileArg2(marks.getEmittedBin(), .{ .make_absolute = true });
    compile_cost.setEnvironmentVariable("GLOWCAP_BENCH_ZIG_OPTIMIZE", @tagName(optimize));
    compile_cost.addPassthruArgs();
    b.step("bench-interface-builds", "Compare fresh raw and generated Rust client compilation with warm dependencies (needs cargo + python3)").dependOn(&compile_cost.step);
    const compile_smoke = commands.addInstalledSystemRun(b, .build_tool, &.{ "python3", "bench/interface/compile.py", "--smoke", "--marks" });
    compile_smoke.addFileArg2(marks.getEmittedBin(), .{ .make_absolute = true });
    compile_smoke.setEnvironmentVariable("GLOWCAP_BENCH_ZIG_OPTIMIZE", @tagName(optimize));
    smoke.step.dependOn(&compile_smoke.step);
    smoke.has_side_effects = true;
    const smoke_step = b.step("interface-bench-smoke", "Check paired interface benchmark effects, traffic parity, and diagnostic output (needs cargo + python3)");
    smoke_step.dependOn(&smoke.step);
    runtime_gate.add(smoke_step);
    const output = "zig-out/bench-reports/interface-profile.callgrind";
    const attributed = commands.addRootedSystemCommand(b, .child_bounded, &.{ "python3", "bench/interface/measure.py", "--profile", binary, "--output", output });
    attributed.step.dependOn(&build.step);
    attributed.has_side_effects = true;
    const report = execution.addArtifact(b, .build_tool, profiles.report);
    report.addArg(output);
    report.step.dependOn(&attributed.step);
    b.step("profile-interface", "Attribute paired Rust interface operation phases under callgrind (needs cargo + valgrind + python3)").dependOn(&report.step);
}

pub fn registerGeneration(b: *std.Build, generator: *std.Build.Step.Compile, optimize: std.builtin.OptimizeMode) void {
    const run = commands.addRootedSystemCommand(b, .benchmark, &.{ "python3", "bench/interface/measure.py", "--generator" });
    run.addArtifactArg(generator);
    run.setEnvironmentVariable("GLOWCAP_BENCH_ZIG_OPTIMIZE", @tagName(optimize));
    run.addPassthruArgs();
    run.has_side_effects = true;
    b.step("bench-interface-generation", "Measure warm interface generation process time, peak RSS, and nonblank compiler source inventory (needs python3)").dependOn(&run.step);
}
