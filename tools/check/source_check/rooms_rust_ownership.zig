//! Rust owns the Rooms application. Retired TypeScript owners stay absent.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

const retired = [_][]const u8{
    "apps/rooms/server",
    "apps/rooms/irc/bridge",
    "apps/rooms/irc/registration.ts",
    "apps/rooms/irc/socket_writer.ts",
};

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (retired) |path| {
        _ = root.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                try appendViolation(gpa, violations, "{s}: Rust-ownership absence check failed with {s}", .{ path, @errorName(err) });
                continue;
            },
        };
        try appendViolation(
            gpa,
            violations,
            "{s}: retired TypeScript Rooms owner must not return; application state and effects belong to the Rust implementation",
            .{path},
        );
    }
}

test "retired TypeScript Rooms owners cannot return" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "apps/rooms/server");
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |message| gpa.free(message);
        violations.deinit(gpa);
    }
    try check(std.testing.io, gpa, tmp.dir, &violations);
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expect(std.mem.startsWith(u8, violations.items[0], "apps/rooms/server:"));
}
