//! The external toolchain the in-tree gates stand on, and the sub-gates that
//! hold each build graph to it.
//!
//! Two inventories live here because they answer the same question from
//! opposite sides. `in_tree_runtimes` is what an in-tree gate may invoke, which the
//! build graph can be read against. `in_tree_capabilities` is what those programs
//! must already be able to do, which the graph cannot see at all. Both raise
//! the floor for every contributor, so both are reviewed edits.
//!
//! The analysis is in `tools/check/toolchain_check.zig` (declaration, read from
//! the graph) and `tools/check/toolchain_present.zig` (presence, read from the
//! machine). This module is the wiring and the tables.

const std = @import("std");
const toolchain_check = @import("../check/toolchain_check.zig");
const execution = @import("execution.zig");

/// What an in-tree gate may require on PATH besides Zig. Each gate is checked
/// against the inventory and only probes the rows its own graph reaches.
const in_tree_runtimes = [_]toolchain_check.Runtime{
    .{
        .program = "python3",
        .scripts = &.{ "tools/run-with-timeout.py", "tools/check/rooms_peer.py", "tools/check/glowcap_release.py", "tools/check/glowcap_release_test.py", "tools/check/glowcap_host.py", "test/loam/engines/io_fault/run.py" },
        .modules = &.{"py_compile"},
        .why = "deterministic subprocesses use the shared deadline wrapper, orchestrators bound each child they start, and the Python benchmark client is compile-checked",
    },
    .{
        .program = "bash",
        .scripts = &.{
            ".devcontainer/test/env-sync.sh",
            "tools/check/ocapnviz-build-check.sh",
            "tools/check/ocapnviz-test.sh",
            "tools/c-abi/c-abi-extract-matrix.sh",
        },
        .why = "source parity, C-ABI extraction, and visualizer harnesses are shell-owned",
    },
    .{
        .program = "sh",
        .why = "the complete-installation proof runs build-owned POSIX staging recipes, including file copying and Git revision stamping",
    },
    .{
        .program = "deno",
        .why = "checked TypeScript examples and site surfaces catch binding API drift",
    },
    .{
        .program = "cargo",
        .why = "Rust binding/application proofs and the Rooms archive executable are checked against the current ABI",
    },
    .{
        .program = "wasm-bindgen",
        .why = "Rooms web preparation packages the production Rust browser application; its generated glue must match the pinned Wasm ABI",
    },
    .{
        .program = "raco",
        .why = "the Racket benchmark clients are compiled against the current binding",
    },
};

/// One capability a declared runtime must already have, and the command that
/// reports whether it does.
///
/// The graph walk sees programs. It cannot see that `cargo` needs a compilation
/// target installed, because the target is not an argument, it is state inside
/// the toolchain. Declaring the probe argv here keeps a host-tool call reached
/// from the gate's own artifact as reviewed as a row above.
const Capability = struct {
    gates: []const Gate,
    /// The text `probe` must report. It is also how the failure names itself.
    expected: []const u8,
    /// The member that needs it, phrased the way a `Runtime.why` is.
    why: []const u8,
    probe: []const []const u8,
};

const Gate = enum { isolated, runtime };

const in_tree_capabilities = [_]Capability{
    .{
        .gates = &.{.runtime},
        .expected = "wasm32-unknown-unknown",
        .why = "the Rooms browser application compiles for it, and cargo reports its absence as a missing `core` crate from inside a dependency build",
        .probe = &.{ "rustup", "target", "list", "--installed" },
    },
};

/// Wire toolchain checks for both in-tree gates.
///
/// `check_step` is `check` itself, and the declaration walk reads it, so every
/// registrar must have added its members before this runs.
pub fn register(
    b: *std.Build,
    check_step: *std.Build.Step,
    runtime_gate: *execution.RuntimeGate,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const verdict = toolchain_check.create(b, check_step, &in_tree_runtimes);
    const step = b.step("toolchain-check", "Hold `zig build check` to the external runtimes it declares, and to their presence here");
    // Declaration first: an undeclared program is a defect in this repository,
    // and its remedy is a row or a sibling step. Asking a reader to install it
    // would answer the wrong question.
    step.dependOn(verdict.declaration);

    // Presence is environment, not configuration, so its verdict is read when
    // the gate runs rather than when it is configured. See the header of
    // tools/check/toolchain_present.zig.
    const present = b.addExecutable(.{
        .name = "glowcap-toolchain-present",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check/toolchain_present.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    const present_run = execution.addArtifact(b, .{ .deterministic = 10 }, present);
    present_run.addArg("programs");
    for (verdict.reached) |index| {
        present_run.addArg(in_tree_runtimes[index].program);
        present_run.addArg(in_tree_runtimes[index].why);
    }
    // A cached verdict is the failure this check exists to remove: it would
    // keep reporting a missing runtime after the container that installs it
    // was rebuilt, and the reader would have nothing to tell it to look again.
    present_run.has_side_effects = true;
    present_run.step.dependOn(verdict.declaration);
    step.dependOn(&present_run.step);

    // One run per capability, so a failure names the capability rather than the
    // batch it happened to travel in.
    for (in_tree_capabilities) |capability| {
        if (!containsGate(capability.gates, .isolated)) continue;
        const probe_run = execution.addArtifact(b, .{ .deterministic = 10 }, present);
        probe_run.addArgs(&.{ "capability", capability.expected, capability.why, "--" });
        probe_run.addArgs(capability.probe);
        probe_run.setCwd(b.path("."));
        probe_run.has_side_effects = true;
        probe_run.step.dependOn(verdict.declaration);
        step.dependOn(&probe_run.step);
    }

    // Like the source gate's own parsers, the toolchain gate's two analysis
    // files are build-time imports, so their `test` blocks only run when
    // something compiles them as a test artifact. One root carries both halves.
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("tools/check/toolchain_gate_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = tests_mod });
    step.dependOn(&execution.addZigTest(b, tests, .unit_test).step);
    check_step.dependOn(step);

    // The process gate gets the same graph-derived declaration and presence
    // check, but only for programs its own members reach. It runs before the
    // first process family, so a stale container fails with one toolchain
    // diagnosis instead of several unrelated spawn errors.
    const runtime_verdict = toolchain_check.create(b, runtime_gate.step, &in_tree_runtimes);
    const runtime_preflight = b.addWriteFiles();
    _ = runtime_preflight.add("runtime-toolchain-check.ok", "");
    runtime_preflight.step.dependOn(runtime_verdict.declaration);
    const runtime_present = execution.addArtifact(b, .{ .deterministic = 10 }, present);
    runtime_present.addArg("programs");
    for (runtime_verdict.reached) |index| {
        runtime_present.addArg(in_tree_runtimes[index].program);
        runtime_present.addArg(in_tree_runtimes[index].why);
    }
    runtime_present.has_side_effects = true;
    runtime_present.step.dependOn(runtime_verdict.declaration);
    runtime_preflight.step.dependOn(&runtime_present.step);
    for (in_tree_capabilities) |capability| {
        if (!containsGate(capability.gates, .runtime)) continue;
        const probe_run = execution.addArtifact(b, .{ .deterministic = 10 }, present);
        probe_run.addArgs(&.{ "capability", capability.expected, capability.why, "--" });
        probe_run.addArgs(capability.probe);
        probe_run.setCwd(b.path("."));
        probe_run.has_side_effects = true;
        probe_run.step.dependOn(runtime_verdict.declaration);
        runtime_preflight.step.dependOn(&probe_run.step);
    }
    runtime_gate.addPrerequisite(&runtime_preflight.step);
    runtime_gate.finalize(check_step);
}

fn containsGate(gates: []const Gate, expected: Gate) bool {
    for (gates) |gate| if (gate == expected) return true;
    return false;
}
