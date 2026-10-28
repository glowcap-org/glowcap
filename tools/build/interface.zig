//! Executable qualification of generated interfaces against raw peers.
const std = @import("std");
const common = @import("common.zig");
const execution = @import("execution.zig");
const addInstalledSystemRun = common.addInstalledSystemRun;

pub fn registerRuntime(b: *std.Build, tasks_server: *std.Build.Step.Compile, runtime_gate: *execution.RuntimeGate) void {
    const rust_build = addInstalledSystemRun(b, .build_tool, &.{ "cargo", "build", "--manifest-path", "test/interface/rust/Cargo.toml", "--bin", "interface-conversation-proof" });
    const rust_proof = common.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "deno", "run", "--allow-read", "--allow-write", "--allow-run", "--allow-env", "test/interface/run.ts",
    });
    rust_proof.addArtifactArg(tasks_server);
    rust_proof.step.dependOn(&rust_build.step);
    rust_proof.has_side_effects = true;
    const typescript = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "deno", "run", "--allow-ffi", "--allow-read", "--allow-net=127.0.0.1", "--allow-env", "test/interface/typescript/conversation.ts",
    });
    typescript.setEnvironmentVariable("GLOWCAP_LIB_DIR", common.rootPath(b, "zig-out/lib"));
    typescript.has_side_effects = true;
    const conversation_step = b.step("interface-conversation-check", "Prove generated Tasks creation and Rust/TypeScript pending callback conversations (needs cargo + deno)");
    conversation_step.dependOn(&rust_proof.step);
    conversation_step.dependOn(&typescript.step);
    runtime_gate.add(conversation_step);
}
