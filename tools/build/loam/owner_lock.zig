//! The owner lock module the disk engines import, with its C source.
const std = @import("std");

/// One owner lock module for a target. Each engine module imports it as
/// `loam_owner_lock`, so a binary holding two engines compiles the lock once.
pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/loam/engines/owner_lock/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .trap,
    });
    module.addCSourceFile(.{ .file = b.path("src/loam/engines/owner_lock/owner_lock.c"), .flags = &.{"-fvisibility=hidden"} });
    return module;
}
