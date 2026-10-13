//! `docs/dependencies.md` names every tool the pin tracker follows and every
//! Zig package a glowcap manifest declares, so adding one without saying what
//! it is for fails here.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

const doc_path = "docs/dependencies.md";
const deps_path = ".devcontainer/lib/update-pins-deps.sh";
const manifests = [_][]const u8{ "build.zig.zon", "site/build.zig.zon" };

/// Tracker names whose readable form differs from the name itself.
const readable = [_]struct { tracked: []const u8, named: []const u8 }{
    .{ .tracked = "rustup-init", .named = "rustup" },
    .{ .tracked = "devcontainer-cli", .named = "dev container cli" },
    .{ .tracked = "cursor-agent", .named = "cursor agent" },
};

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const doc = root.readFileAlloc(io, doc_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read the dependency overview ({s})", .{ doc_path, @errorName(err) });
        return;
    };
    defer gpa.free(doc);
    const lower = try std.ascii.allocLowerString(gpa, doc);
    defer gpa.free(lower);

    const deps = root.readFileAlloc(io, deps_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read the tracked dependency list ({s})", .{ deps_path, @errorName(err) });
        return;
    };
    defer gpa.free(deps);
    const tracked = trackedDeps(deps) orelse {
        try appendViolation(gpa, violations, "{s}: no closed `GLOWCAP_PINS_DEPS=\"…\"` declaration", .{deps_path});
        return;
    };
    var names = std.mem.tokenizeScalar(u8, tracked, ' ');
    while (names.next()) |name| {
        const named = readableName(name);
        if (std.mem.indexOf(u8, lower, named) == null) {
            try appendViolation(gpa, violations, "{s}: pinned dependency `{s}` is not described (expected the words \"{s}\")", .{ doc_path, name, named });
        }
    }

    for (manifests) |manifest_path| {
        const manifest = root.readFileAlloc(io, manifest_path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot read it to list its dependencies ({s})", .{ manifest_path, @errorName(err) });
            continue;
        };
        defer gpa.free(manifest);
        var keys = DependencyKeys{ .rest = dependencyBlock(manifest) orelse continue };
        while (keys.next()) |key| {
            if (std.mem.indexOf(u8, lower, key) == null) {
                try appendViolation(gpa, violations, "{s}: Zig package `{s}` from {s} is not described", .{ doc_path, key, manifest_path });
            }
        }
    }
}

fn trackedDeps(source: []const u8) ?[]const u8 {
    const prefix = "GLOWCAP_PINS_DEPS=\"";
    const start = std.mem.indexOf(u8, source, prefix) orelse return null;
    const value = source[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, value, '"') orelse return null;
    return value[0..end];
}

fn readableName(tracked: []const u8) []const u8 {
    for (readable) |row| if (std.mem.eql(u8, row.tracked, tracked)) return row.named;
    return tracked;
}

/// The text between `.dependencies = .{` and its closing brace.
fn dependencyBlock(manifest: []const u8) ?[]const u8 {
    const open = ".dependencies = .{";
    const start = (std.mem.indexOf(u8, manifest, open) orelse return null) + open.len;
    var depth: usize = 1;
    for (manifest[start..], start..) |c, i| switch (c) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return manifest[start..i];
        },
        else => {},
    };
    return null;
}

/// Each top-level `.name = .{` key in a dependency block.
const DependencyKeys = struct {
    rest: []const u8,

    fn next(self: *DependencyKeys) ?[]const u8 {
        var depth: usize = 0;
        var i: usize = 0;
        while (i < self.rest.len) : (i += 1) switch (self.rest[i]) {
            '{' => depth += 1,
            '}' => depth -|= 1,
            '/' => if (i + 1 < self.rest.len and self.rest[i + 1] == '/') {
                i = std.mem.indexOfScalarPos(u8, self.rest, i, '\n') orelse self.rest.len;
            },
            '.' => if (depth == 0) {
                var end = i + 1;
                while (end < self.rest.len and (std.ascii.isAlphanumeric(self.rest[end]) or self.rest[end] == '_')) end += 1;
                if (end > i + 1 and std.mem.startsWith(u8, std.mem.trimStart(u8, self.rest[end..], " "), "= .{")) {
                    const key = self.rest[i + 1 .. end];
                    self.rest = self.rest[end..];
                    return key;
                }
            },
            else => {},
        };
        return null;
    }
};

test "dependency keys skip comments and nested fields" {
    const block = dependencyBlock(
        \\.{
        \\    .dependencies = .{
        \\        // Lazy: .note = .{ is prose
        \\        .vaxis = .{
        \\            .url = "git+https://example/vaxis",
        \\            .lazy = true,
        \\        },
        \\        .lmdb = .{ .url = "https://example/lmdb.tar.gz" },
        \\    },
        \\}
    ).?;
    var keys = DependencyKeys{ .rest = block };
    try std.testing.expectEqualStrings("vaxis", keys.next().?);
    try std.testing.expectEqualStrings("lmdb", keys.next().?);
    try std.testing.expect(keys.next() == null);
}

test "tracked names map to their readable form" {
    try std.testing.expectEqualStrings("zig ", trackedDeps("GLOWCAP_PINS_DEPS=\"zig \"\n").?);
    try std.testing.expectEqualStrings("rustup", readableName("rustup-init"));
    try std.testing.expectEqualStrings("deno", readableName("deno"));
}
