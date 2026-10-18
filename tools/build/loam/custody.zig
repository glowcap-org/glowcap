//! The custody module the disk engines import, with the owner lock's C source.
const std = @import("std");

/// One custody module for a target. Each engine module imports it as
/// `loam_custody`, so a binary holding two engines compiles the lock once.
pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/loam/engines/custody/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .trap,
    });
    module.addCSourceFile(.{ .file = b.path("src/loam/engines/custody/owner_lock.c"), .flags = &.{"-fvisibility=hidden"} });
    return module;
}
