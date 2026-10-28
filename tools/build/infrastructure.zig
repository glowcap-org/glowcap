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
    const publication_workflow_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/publication_workflow_test.py" });
    publication_workflow_contracts.has_side_effects = true;
    infrastructure_check_step.dependOn(&publication_workflow_contracts.step);
    const publication_integration_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", "tools/check/publication-integration-test.sh" });
    publication_integration_contracts.has_side_effects = true;
    infrastructure_check_step.dependOn(&publication_integration_contracts.step);
    const evidence_record_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/evidence/record_test.py" });
    evidence_record_contracts.has_side_effects = true;
    infrastructure_check_step.dependOn(&evidence_record_contracts.step);
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
