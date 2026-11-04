//! Compiler-request comparison and one generated Rust call against a raw peer.
const std = @import("std");
const commands = @import("commands.zig");
const execution = @import("execution.zig");

pub fn register(b: *std.Build, checker: *std.Build.Step.Compile, interface_test: *std.Build.Step, runtime_gate: *execution.RuntimeGate) void {
    const manifest = "tools/interface/authoring/capnp/Cargo.toml";
    const proof_manifest = "tools/interface/authoring/capnp/e2e/Cargo.toml";
    const adapter = "tools/interface/authoring/capnp/target/release/interface-capnp-comparison";
    const generated = b.fmt("{s}/zig-out/interface-authoring-capnp/reader.rs", .{b.root.toString(b.allocator) catch @panic("OOM")});
    const compile = commands.addRootedSystemCommand(b, .build_tool, &.{ "cargo", "build", "--locked", "--release", "--manifest-path", manifest });
    const unit_tests = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{ "cargo", "test", "--locked", "--release", "--manifest-path", manifest });
    unit_tests.step.dependOn(&compile.step);
    interface_test.dependOn(&unit_tests.step);
    const compiler = commands.addRootedSystemCommand(b, .build_tool, &.{ "capnp", "--version" });
    const compare = commands.addRootedSystemCommand(b, .build_tool, &.{ "python3", "tools/interface/authoring/capnp/check.py", adapter, "test/interface/authoring/comparison.syrup" });
    compare.addArtifactArg(checker);
    compare.addArg(generated);
    compare.step.dependOn(&compile.step);
    compare.step.dependOn(&compiler.step);
    compare.has_side_effects = true;
    interface_test.dependOn(&compare.step);

    const proof_build = commands.addInstalledSystemRun(b, .build_tool, &.{ "cargo", "build", "--locked", "--manifest-path", proof_manifest });
    proof_build.setEnvironmentVariable("CAPNP_AUTHORING_RS", generated);
    proof_build.step.dependOn(&compare.step);
    const proof = commands.addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{"tools/interface/authoring/capnp/e2e/target/debug/interface-capnp-e2e"});
    proof.step.dependOn(&proof_build.step);
    proof.has_side_effects = true;
    const step = b.step("interface-authoring-check", "Compare authored descriptions and prove a generated Cap'n Proto frontend call (needs capnp + cargo + python3)");
    step.dependOn(&proof.step);
    step.dependOn(&unit_tests.step);
    runtime_gate.add(step);

    const lint_step = b.step("interface-authoring-lint", "Lint the compiler-request adapter and its generated-call integration (needs capnp + cargo + python3)");
    for ([_][]const u8{ manifest, proof_manifest }) |path| {
        const lint = commands.addInstalledSystemRun(b, .build_tool, &.{ "cargo", "clippy", "--locked", "--all-targets", "--all-features", "--manifest-path", path, "--", "-D", "warnings" });
        lint.setEnvironmentVariable("CAPNP_AUTHORING_RS", generated);
        lint.step.dependOn(&compare.step);
        lint_step.dependOn(&lint.step);
    }
}
