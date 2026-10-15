//! `doc-impact`: the docs whose code a change touches (tools/check/doc_impact.zig).

const std = @import("std");
const execution = @import("execution.zig");

pub fn register(b: *std.Build, source_check_step: *std.Build.Step) void {
    const root = b.createModule(.{
        .root_source_file = b.path("tools/check/doc_impact.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    // What a doc explains is owned by the doc kinds the source check holds.
    root.addImport("doc_kinds", b.createModule(.{ .root_source_file = b.path("tools/check/source_check/docs/kinds.zig") }));
    const exe = b.addExecutable(.{ .name = "doc-impact", .root_module = root });
    const run = execution.addArtifact(b, .build_tool, exe);
    run.setCwd(b.path("."));
    run.addPassthruArgs();
    run.has_side_effects = true;
    b.step("doc-impact", "List the docs that explain code changed since the fork from dev (or `-- <base>`)").dependOn(&run.step);
    source_check_step.dependOn(&execution.addZigTest(b, b.addTest(.{ .root_module = root }), .unit_test).step);
}
