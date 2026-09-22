//! Resolve version-matched application components relative to the real CLI.
//! Releases and contributor product builds share one libexec layout. Neither
//! searches PATH, borrows another installation, or downloads components.
const std = @import("std");
const Ctx = @import("../ctx.zig").Ctx;
const log = @import("log.zig");

pub fn prefix(ctx: *Ctx) ![]u8 {
    var dir: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.process.executableDirPath(ctx.io, &dir);
    return std.fs.path.resolve(ctx.gpa, &.{ dir[0..len], ".." });
}

pub fn executable(ctx: *Ctx, name: []const u8) ![]u8 {
    const root = try prefix(ctx);
    defer ctx.gpa.free(root);
    const path = try std.fs.path.join(ctx.gpa, &.{ root, "libexec", name });
    errdefer ctx.gpa.free(path);
    std.Io.Dir.cwd().access(ctx.io, path, .{ .execute = true }) catch {
        log.err(ctx.io, "missing installed runtime {s}; reinstall the complete glowcap package", .{path});
        return error.FileNotFound;
    };
    return path;
}

pub fn exists(ctx: *Ctx, path: []const u8) bool {
    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch return false;
    return true;
}

pub fn replace(ctx: *Ctx, name: []const u8, arguments: []const []const u8) !u8 {
    const path = try executable(ctx, name);
    defer ctx.gpa.free(path);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.gpa);
    try argv.append(ctx.gpa, path);
    try argv.appendSlice(ctx.gpa, arguments);
    return std.process.replace(ctx.io, .{ .argv = argv.items, .environ_map = ctx.environ });
}
