//! A throwaway downstream package that depends on glowcap exactly the way the
//! README tells a consumer to, so the README's first instruction is a checked
//! claim rather than an assertion.
//!
//! What it proves: `b.dependency("glowcap", …)` resolves; `.module("glowcap")`
//! imports, and so do the two optional modules the site's Zig tabs name,
//! `glowcap_iroh` (which links the cargo-built sidecar) and
//! `glowcap_native_relay` (which builds Mbed TLS from source); and a program
//! over all three compiles and links. Driven by `zig build consumer-check`
//! from the repository root.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const glowcap = b.dependency("glowcap", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "glowcap-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("glowcap", glowcap.module("glowcap"));
    exe.root_module.addImport("iroh", glowcap.module("glowcap_iroh"));
    exe.root_module.addImport("native_relay", glowcap.module("glowcap_native_relay"));
    b.installArtifact(exe);
    b.getInstallStep().dependOn(&exe.step);
}
