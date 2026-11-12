//! `infrastructure-check` and `timeout-runner-test`: the executable behaviour
//! of the devcontainer, worktrees, agent hooks, every Python program under
//! `ci/` and `tools/`, the content-stable library install, and the CI deadline
//! wrapper. Static path and pin parity stay in `source-check`. These steps
//! clone repositories, rewrite temporary Git histories, and wait on real
//! deadlines, so a focused source edit never pays for them.

const std = @import("std");
const archives = @import("archives.zig");
const execution = @import("execution.zig");
const listing = @import("listing.zig");

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
    const git_hooks_test = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/git_hooks_test.py" });
    git_hooks_test.has_side_effects = true;
    infrastructure_check_step.dependOn(&git_hooks_test.step);
    // Each subject owns its deadline: one process per test file, so unrelated
    // tests never compete for the same 30 seconds on a slow host. A test sits
    // beside its subject, so these directories are the inventory. tools/check
    // tests are registered below by name, because some take arguments their
    // owning step supplies. The ci tests read the workflows with PyYAML, which
    // ci/uv.lock supplies.
    for ([_][]const u8{ "ci", "tools", "tools/gen" }) |directory| {
        const in_project = std.mem.eql(u8, directory, "ci");
        for (pythonTests(b, directory)) |name| {
            const unittest = [_][]const u8{ "python3", "-m", "unittest", "discover", "-s", directory, "-p", name };
            const contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, if (in_project)
                &([_][]const u8{ "uv", "run", "--project", "ci", "--locked" } ++ unittest)
            else
                &unittest);
            contracts.setName(b.fmt("{s}/{s}", .{ directory, name }));
            contracts.has_side_effects = true;
            infrastructure_check_step.dependOn(&contracts.step);
        }
    }
    const publication_integration_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "bash", "tools/check/publication-integration-test.sh" });
    publication_integration_contracts.has_side_effects = true;
    infrastructure_check_step.dependOn(&publication_integration_contracts.step);
    const tls_fixture_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/relay_tls_server_test.py" });
    tls_fixture_contracts.has_side_effects = true;
    infrastructure_check_step.dependOn(&tls_fixture_contracts.step);
    const rooms_peer_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/rooms_peer_test.py" });
    rooms_peer_contracts.has_side_effects = true;
    infrastructure_check_step.dependOn(&rooms_peer_contracts.step);
    const ocapnviz_check_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/ocapnviz_test.py" });
    ocapnviz_check_contracts.has_side_effects = true;
    infrastructure_check_step.dependOn(&ocapnviz_check_contracts.step);
    const installer_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/install_test.py" });
    installer_contracts.has_side_effects = true;
    infrastructure_check_step.dependOn(&installer_contracts.step);
    const version_lockstep_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/version_lockstep_test.py" });
    version_lockstep_contracts.has_side_effects = true;
    infrastructure_check_step.dependOn(&version_lockstep_contracts.step);
    const binding_package_contracts = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/check/binding_packages_test.py" });
    binding_package_contracts.has_side_effects = true;
    infrastructure_check_step.dependOn(&binding_package_contracts.step);
    const install_if_changed_tests = b.addTest(.{ .name = "install-if-changed", .root_module = archives.installIfChangedExe(b).root_module });
    infrastructure_check_step.dependOn(&execution.addZigTest(b, install_if_changed_tests, .unit_test).step);

    // The deadline wrapper every CI gate runs under, held by its behaviour
    // rather than by its source text: a check that greps the file for
    // `return 124` proves the string is present, not that a timed-out child
    // reports 124. Not a member of `check` or `infrastructure-check`: it
    // spends seconds on real deadline waits, and the infrastructure phase in
    // `ci/groups.py` runs it before `infrastructure-check`, because the
    // wrapper has to be proven before the gates under it.
    const timeout_runner_test = execution.addSystemCommand(b, .{ .deterministic = 30 }, &.{ "python3", "tools/run_with_timeout_test.py" });
    timeout_runner_test.has_side_effects = true;
    const timeout_runner_step = b.step("timeout-runner-test", "Black-box the CI deadline wrapper: exit codes, relayed signal, no survivors (needs python3)");
    timeout_runner_step.dependOn(&timeout_runner_test.step);
}

/// The `*_test.py` files of one directory, sorted: compile-shard ownership
/// walks the graph in registration order, so the order must not depend on
/// the file system.
fn pythonTests(b: *std.Build, directory: []const u8) []const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (listing.sortedFiles(b, directory)) |name| {
        if (std.mem.endsWith(u8, name, "_test.py")) names.append(b.allocator, name) catch @panic("OOM");
    }
    return names.items;
}
