//! Quoted code values: `gen-doc-values` rewrites the numbers docs quote from
//! code constants, and its check rides `source-check`.

const std = @import("std");
const execution = @import("execution.zig");

pub fn register(b: *std.Build, source_check_step: *std.Build.Step) void {
    const root = b.createModule(.{
        .root_source_file = b.path("tools/gen/doc_values.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    // Where docs live is owned by the doc kinds the source check holds.
    root.addImport("doc_kinds", b.createModule(.{ .root_source_file = b.path("tools/check/source_check/docs/kinds.zig") }));
    const exe = b.addExecutable(.{ .name = "gen-doc-values", .root_module = root });
    // The check reads the tree at run time, so it always runs.
    const check = execution.addLiveRun(b, .{ .deterministic = 30 }, exe);
    check.addArg("check");
    const check_step = b.step("gen-doc-values-check", "Verify every value a doc quotes from a code constant is current (fails if stale or unreadable)");
    check_step.dependOn(&check.step);
    source_check_step.dependOn(check_step);
    const write = execution.addLiveRun(b, .build_tool, exe);
    write.addArg("write");
    b.step("gen-doc-values", "Rewrite every value a doc quotes from a code constant").dependOn(&write.step);
    source_check_step.dependOn(&execution.addZigTest(b, b.addTest(.{ .root_module = root }), .unit_test).step);
}
