//! The agent index: `gen-agent-index` writes the tables in `.agents/README.md`
//! from each rule, skill and hook, and its check rides `source-check`.

const std = @import("std");
const execution = @import("execution.zig");

pub fn register(b: *std.Build, source_check_step: *std.Build.Step) void {
    // The check reads the tree at run time, so it always runs.
    const agent_index_exe = b.addExecutable(.{
        .name = "gen-agent-index",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen/agent_index.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const agent_index_check = execution.addLiveRun(b, .{ .deterministic = 30 }, agent_index_exe);
    agent_index_check.addArg("check");
    const agent_index_check_step = b.step("gen-agent-index-check", "Verify the agent scaffolding index matches each rule, skill and hook (fails if stale or a file states no purpose)");
    agent_index_check_step.dependOn(&agent_index_check.step);
    source_check_step.dependOn(agent_index_check_step);
    const agent_index_write = execution.addLiveRun(b, .build_tool, agent_index_exe);
    agent_index_write.addArg("write");
    b.step("gen-agent-index", "Regenerate the agent scaffolding index from each rule, skill and hook").dependOn(&agent_index_write.step);
    const agent_index_tests = b.addTest(.{ .root_module = agent_index_exe.root_module });
    source_check_step.dependOn(&execution.addZigTest(b, agent_index_tests, .unit_test).step);
}
