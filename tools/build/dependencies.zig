//! The dependencies page: `gen-dependencies` writes `docs/dependencies.md`
//! from the `dep` comments in every manifest, and its check rides
//! `source-check`.

const std = @import("std");
const execution = @import("execution.zig");

pub fn register(b: *std.Build, source_check_step: *std.Build.Step) void {
    // The check reads the tree at run time, so it always runs.
    const dependencies_exe = b.addExecutable(.{
        .name = "gen-dependencies",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen/dependencies.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const dependencies_check = execution.addArtifact(b, .{ .deterministic = 30 }, dependencies_exe);
    dependencies_check.setCwd(b.path("."));
    dependencies_check.addArg("check");
    dependencies_check.has_side_effects = true;
    const dependencies_check_step = b.step("gen-dependencies-check", "Verify docs/dependencies.md matches the dep comments in every manifest (fails if stale or a dependency has no comment)");
    dependencies_check_step.dependOn(&dependencies_check.step);
    source_check_step.dependOn(dependencies_check_step);
    const dependencies_write = execution.addArtifact(b, .build_tool, dependencies_exe);
    dependencies_write.setCwd(b.path("."));
    dependencies_write.addArg("write");
    dependencies_write.has_side_effects = true;
    b.step("gen-dependencies", "Regenerate docs/dependencies.md from the dep comments in every manifest").dependOn(&dependencies_write.step);
    const dependencies_tests = b.addTest(.{ .root_module = dependencies_exe.root_module });
    source_check_step.dependOn(&execution.addZigTest(b, dependencies_tests, .unit_test).step);
}
