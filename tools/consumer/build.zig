//! A throwaway downstream package that depends on pancake exactly the way the
//! README tells a consumer to, so the README's first instruction is a checked
//! claim rather than an assertion.
//!
//! What it proves: `b.dependency("pancake", …)` resolves, `.module("pancake")`
//! imports, and a program that links only the library compiles — without
//! fetching anything the library does not itself need. Driven by
//! `zig build consumer-check` from the repository root.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pancake = b.dependency("pancake", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "pancake-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("pancake", pancake.module("pancake"));
    b.installArtifact(exe);
    b.getInstallStep().dependOn(&exe.step);
}
