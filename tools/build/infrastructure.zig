//! `infrastructure-check` and `timeout-runner-test`: the executable behaviour
//! of the devcontainer, worktrees, agent hooks, publication workflow, the
//! evidence record, the content-stable library install, and the CI deadline
//! wrapper. Static path and pin parity stay in `source-check`; these steps
//! clone repositories, rewrite temporary Git histories, and wait on real
//! deadlines, so a focused source edit never pays for them.

const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");

pub fn register(b: *std.Build) void {
    const infrastructure_check_step = b.step("infrastructure-check", "Run devcontainer, worktree, and agent hook behavior checks (needs bash, git, python3, jq, rustfmt, and deno)");
    const build_front_behaviour = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", ".devcontainer/test/build-front.sh" });
    build_front_behaviour.has_side_effects = true;
    const devcontainer_behaviour = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", ".devcontainer/test/host-invariants.sh" });
    devcontainer_behaviour.has_side_effects = true;
    // The managed-tool lifecycle proof needs flock and GNU coreutils, so it
    // runs in the Linux devcontainer; on other hosts it prints a visible skip
    // and exits 0 (see the file's header).
    const tool_runtime_behaviour = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", ".devcontainer/test/tool-runtime.sh" });
    tool_runtime_behaviour.has_side_effects = true;
    devcontainer_behaviour.step.dependOn(&build_front_behaviour.step);
    infrastructure_check_step.dependOn(&devcontainer_behaviour.step);
    infrastructure_check_step.dependOn(&tool_runtime_behaviour.step);
    const worktree_integration_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", "tools/check/worktree-integration-test.sh" });
    worktree_integration_contracts.has_side_effects = true;
    worktree_integration_contracts.step.dependOn(&devcontainer_behaviour.step);
    infrastructure_check_step.dependOn(&worktree_integration_contracts.step);
    const agent_hooks_test = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/agent_hooks_test.py" });
    agent_hooks_test.has_side_effects = true;
    infrastructure_check_step.dependOn(&agent_hooks_test.step);
    // Each subject owns its deadline. One timer for the growing collection
    // makes unrelated tests compete for the same 30 seconds on slow hosts.
    b.dependOnDirectoryContents(b.path("ci/test"));
    const io = b.graph.io;
    var ci_tests = b.root.root_dir.handle.openDir(io, "ci/test", .{ .iterate = true }) catch |err|
        std.debug.panic("CI test directory: {s}", .{@errorName(err)});
    defer ci_tests.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var entries = ci_tests.iterate();
    while (entries.next(io) catch |err|
        std.debug.panic("CI test discovery: {s}", .{@errorName(err)})) |entry|
    {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, "_test.py")) continue;
        names.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    // Compile-shard ownership walks the graph in registration order.
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);
    for (names.items) |pattern| {
        const contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "-m", "unittest", "discover", "-s", "ci/test", "-p", pattern });
        contracts.setName(b.fmt("CI {s}", .{pattern}));
        contracts.has_side_effects = true;
        infrastructure_check_step.dependOn(&contracts.step);
    }
    const publication_integration_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", "tools/check/publication-integration-test.sh" });
    publication_integration_contracts.has_side_effects = true;
    infrastructure_check_step.dependOn(&publication_integration_contracts.step);
    const evidence_record_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/evidence/record_test.py" });
    evidence_record_contracts.has_side_effects = true;
    infrastructure_check_step.dependOn(&evidence_record_contracts.step);
    const tls_fixture_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/relay_tls_server_test.py" });
    tls_fixture_contracts.has_side_effects = true;
    infrastructure_check_step.dependOn(&tls_fixture_contracts.step);
    const rooms_peer_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/rooms_peer_test.py" });
    rooms_peer_contracts.has_side_effects = true;
    infrastructure_check_step.dependOn(&rooms_peer_contracts.step);
    const install_if_changed_tests = b.addTest(.{ .name = "install-if-changed", .root_module = common.installIfChangedExe(b).root_module });
    infrastructure_check_step.dependOn(&execution.addZigTest(b, install_if_changed_tests, .unit_test).step);

    // The deadline wrapper every CI gate runs under, held by its behaviour
    // rather than by its source text: a check that greps the file for
    // `return 124` proves the string is present, not that a timed-out child
    // reports 124. Not a member of `check` or `infrastructure-check`: it
    // spends seconds on real deadline waits, and `ci/gates.sh` runs it first
    // because the wrapper has to be proven before the sequence under it.
    const timeout_runner_test = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", "tools/run-with-timeout-test.sh" });
    timeout_runner_test.has_side_effects = true;
    const timeout_runner_step = b.step("timeout-runner-test", "Black-box the CI deadline wrapper: exit codes, relayed signal, no survivors (needs python3)");
    timeout_runner_step.dependOn(&timeout_runner_test.step);
}
