//! Executable qualification of generated interfaces against raw peers.
const std = @import("std");
const commands = @import("commands.zig");
const execution = @import("execution.zig");
const addInstalledSystemRun = commands.addInstalledSystemRun;

pub fn registerRuntime(b: *std.Build, tasks_server: *std.Build.Step.Compile, runtime_gate: *execution.RuntimeGate, check_step: *std.Build.Step) void {
    const rust_build = addInstalledSystemRun(b, .build_tool, &.{ "cargo", "build", "--manifest-path", "test/interface/rust/Cargo.toml", "--bin", "interface-conversation-proof" });
    const rust_proof = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "deno", "run", "--allow-read", "--allow-write", "--allow-run", "--allow-env", "test/interface/run.ts",
    });
    rust_proof.addArtifactArg(tasks_server);
    rust_proof.step.dependOn(&rust_build.step);
    rust_proof.has_side_effects = true;
    const typescript = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{
        "deno", "run", "--allow-ffi", "--allow-read", "--allow-net=127.0.0.1", "--allow-env", "test/interface/typescript/conversation.ts",
    });
    commands.setLibDir(typescript, .host);
    typescript.has_side_effects = true;
    const conversation_step = b.step("interface-conversation-check", "Prove generated Tasks creation and Rust/TypeScript pending callback conversations (needs cargo + deno)");
    conversation_step.dependOn(&rust_proof.step);
    conversation_step.dependOn(&typescript.step);
    runtime_gate.add(conversation_step);
    registerGoblins(b, tasks_server, check_step);
}

fn registerGoblins(b: *std.Build, tasks_server: *std.Build.Step.Compile, check_step: *std.Build.Step) void {
    const rust_build = addInstalledSystemRun(b, .build_tool, &.{ "cargo", "build", "--manifest-path", "test/interface/rust/Cargo.toml", "--bin", "interface-goblins-proof" });
    check_step.dependOn(&rust_build.step);
    const recipient = addInstalledSystemRun(b, .{ .deterministic = 30 }, &.{"test/interface/rust/target/debug/interface-goblins-proof"});
    recipient.step.dependOn(&rust_build.step);
    recipient.has_side_effects = true;
    const caller = commands.addRootedSystemCommand(b, .{ .deterministic = 30 }, &.{
        "deno", "run", "--allow-read", "--allow-write", "--allow-run", "--allow-env", "interop/goblins_interop/interface_creation_harness.ts",
    });
    caller.addArtifactArg(tasks_server);
    caller.has_side_effects = true;
    const step = b.step("interface-goblins-check", "Prove generated recipient handoff and plain Goblins calling the generated Tasks server boundary (needs cargo + racket + Goblins + deno)");
    step.dependOn(&recipient.step);
    step.dependOn(&caller.step);
    b.top_level_steps.get("check-external").?.step.dependOn(step);
}
