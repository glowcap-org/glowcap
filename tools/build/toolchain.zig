//! The external toolchain `zig build check` stands on, and the sub-gate that
//! holds the tree to it.
//!
//! Two inventories live here because they answer the same question from
//! opposite sides. `check_runtimes` is what the gate may invoke, which the
//! build graph can be read against. `check_capabilities` is what those programs
//! must already be able to do, which the graph cannot see at all. Both raise
//! the floor for every contributor, so both are reviewed edits.
//!
//! The analysis is in `tools/check/toolchain_check.zig` (declaration, read from
//! the graph) and `tools/check/toolchain_present.zig` (presence, read from the
//! machine). This module is the wiring and the tables.

const std = @import("std");
const toolchain_check = @import("../check/toolchain_check.zig");
const execution = @import("execution.zig");

/// What `zig build check` requires on PATH besides Zig. A row raises the floor
/// for every contributor, so the graph checker holds this inventory to the
/// gate's actual process dependencies.
const check_runtimes = [_]toolchain_check.Runtime{
    .{
        .program = "python3",
        .scripts = &.{"tools/run-with-timeout.py"},
        .modules = &.{"py_compile"},
        .why = "deterministic subprocesses use the shared deadline wrapper and the Python benchmark client is compile-checked",
    },
    .{
        .program = "bash",
        .scripts = &.{
            ".devcontainer/test/env-sync.sh",
            ".devcontainer/test/host-invariants.sh",
            "tools/check/ocapnviz-build-check.sh",
            "tools/check/ocapnviz-test.sh",
            "tools/c-abi/c-abi-extract-matrix.sh",
            "tools/check/worktree-integration-test.sh",
        },
        .why = "devcontainer, worktree, C-ABI extract, and visualizer harnesses are shell-owned",
    },
    .{
        .program = "deno",
        .why = "checked TypeScript examples and site surfaces catch binding API drift",
    },
    .{
        .program = "cargo",
        .why = "Rust binding/application proofs and the native Rooms archive executable are checked against the current ABI",
    },
    .{
        .program = "wasm-bindgen",
        .why = "native Rooms web preparation packages the production Rust browser application; its generated glue must match the pinned Wasm ABI",
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
    /// The text `probe` must report. It is also how the failure names itself.
    expected: []const u8,
    /// The member that needs it, phrased the way a `Runtime.why` is.
    why: []const u8,
    probe: []const []const u8,
};

const check_capabilities = [_]Capability{
    .{
        .expected = "wasm32-unknown-unknown",
        .why = "the Rooms browser application and the wasm C ABI archives compile for it, and cargo reports its absence as a missing `core` crate from inside a dependency build",
        .probe = &.{ "rustup", "target", "list", "--installed" },
    },
};

/// Wire `toolchain-check` and make `check` depend on it.
///
/// `check_step` is `check` itself, and the declaration walk reads it, so every
/// registrar must have added its members before this runs.
pub fn register(
    b: *std.Build,
    check_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const verdict = toolchain_check.create(b, check_step, &check_runtimes);
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
        present_run.addArg(check_runtimes[index].program);
        present_run.addArg(check_runtimes[index].why);
    }
    // A cached verdict is the failure this check exists to remove: it would
    // keep reporting a missing runtime after the container that installs it
    // was rebuilt, and the reader would have nothing to tell it to look again.
    present_run.has_side_effects = true;
    present_run.step.dependOn(verdict.declaration);
    step.dependOn(&present_run.step);

    // One run per capability, so a failure names the capability rather than the
    // batch it happened to travel in.
    for (check_capabilities) |capability| {
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
    step.dependOn(&execution.addZigTest(b, tests, .{ .deterministic = 3 }).step);
    check_step.dependOn(step);
}
