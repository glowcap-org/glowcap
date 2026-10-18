//! Separate modules pin frame type identity when qualified type names agree.

const std = @import("std");

pub fn addFixtures(b: *std.Build, root: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    for ([_][]const u8{ "left", "right" }) |side| {
        root.addImport(b.fmt("frame_identity_{s}", .{side}), b.createModule(.{
            .root_source_file = b.path(b.fmt("test/support/frame_identity/{s}/types.zig", .{side})),
            .target = target,
            .optimize = optimize,
        }));
    }
}
