//! The `profile-*` steps: one bench under callgrind, built ReleaseFast for the
//! baseline CPU with valgrind client requests on. The bench's phase marks
//! (`bench/support/profile.zig`) choose what is collected, callgrind writes one
//! part per marked phase, and `tools/profile/report.zig` ranks self cost per
//! file and per function for each part.

const std = @import("std");
const root = @import("../../build.zig");
const execution = @import("execution.zig");

/// The profiled module graph and the report tool, built once for every
/// `profile-*` step.
pub const Profiles = struct {
    target: std.Build.ResolvedTarget,
    mods: []*std.Build.Module,
    report: *std.Build.Step.Compile,

    /// ReleaseFast, as every absolute figure is. A profile of Debug code ranks
    /// safety checks and missed inlining, not the product.
    pub const optimize: std.builtin.OptimizeMode = .ReleaseFast;

    pub fn module(self: Profiles, comptime name: []const u8) *std.Build.Module {
        return self.mods[root.layerIndex(name)];
    }

    /// A bench root module that profiles: the baseline CPU, because valgrind
    /// executes no extension the host alone enables, and client requests on
    /// so the marks reach callgrind.
    pub fn moduleOptions(self: Profiles, b: *std.Build, root_source: []const u8) std.Build.Module.CreateOptions {
        return .{ .root_source_file = b.path(root_source), .target = self.target, .optimize = optimize, .valgrind = true };
    }
};

pub fn register(b: *std.Build, check_step: *std.Build.Step) Profiles {
    const target = b.resolveTargetQuery(.{ .cpu_model = .baseline });
    const mods = root.graphFromTable(b, target, Profiles.optimize, &root.layer_table, false);
    const report_mod = b.createModule(.{ .root_source_file = b.path("tools/profile/report.zig"), .target = b.graph.host, .optimize = .Debug });
    const report = b.addExecutable(.{ .name = "profile-report", .root_module = report_mod });
    const tests = b.addTest(.{ .root_module = report_mod });
    const run_tests = execution.addZigTest(b, tests, .unit_test);
    b.step("profile-report-test", "Unit-test the callgrind part reader behind the profile-* reports").dependOn(&run_tests.step);
    check_step.dependOn(&run_tests.step);
    return .{ .target = target, .mods = mods, .report = report };
}

/// Run `exe` under callgrind with the bench's own arguments after `--`, then
/// write the report beside the parts. The caller names the step.
pub fn addRun(b: *std.Build, profiles: Profiles, exe: *std.Build.Step.Compile) *std.Build.Step {
    const reports = execution.addSystemCommand(b, .build_tool, &.{ "mkdir", "-p", execution.report_dir });
    const run = execution.addArtifact(b, .{ .profile = 1800 }, exe);
    run.step.dependOn(&reports.step);
    run.addPassthruArgs();
    const report = execution.addArtifact(b, .build_tool, profiles.report);
    report.addArg(execution.profileOutput(b, exe.name));
    report.step.dependOn(&run.step);
    return &report.step;
}
