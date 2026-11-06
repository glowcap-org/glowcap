//! Package manifests name glowcap's Apache-2.0 license at the surface package tools
//! and registries read. Discovery holds new first-party manifests to the same
//! declaration without enrolling each one by hand.

const std = @import("std");
const source_tree = @import("../source_tree.zig");
const violation_log = @import("../violation_log.zig");
const packages = @import("packages.zig");

const appendViolation = violation_log.appendViolation;
const expected = "Apache-2.0";
const roots = [_][]const u8{ "apps", "bench", "bindings", "transports" };

fn cargoManifest(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "Cargo.toml");
}

fn denoManifest(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "deno.json");
}

fn npmManifest(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "package.json");
}

fn racketManifest(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "info.rkt");
}

fn packageManifest(path: []const u8) bool {
    return cargoManifest(path) or denoManifest(path) or npmManifest(path) or racketManifest(path);
}

fn hasLine(contents: []const u8, wanted: []const u8) bool {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), wanted)) return true;
    }
    return false;
}

fn checkCargo(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read license metadata with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);
    const direct = hasLine(contents, "license = \"" ++ expected ++ "\"");
    const workspace_member = (std.mem.startsWith(u8, path, "transports/") and !std.mem.eql(u8, path, "transports/Cargo.toml")) or
        (std.mem.startsWith(u8, path, "apps/rooms/rust/") and !std.mem.eql(u8, path, "apps/rooms/rust/Cargo.toml"));
    const inherited = workspace_member and hasLine(contents, "license.workspace = true");
    if (!direct and !inherited) {
        try appendViolation(gpa, violations, "{s}: Cargo package must declare `license = \"{s}\"`; Rooms and transport workspace members may inherit it with `license.workspace = true`", .{ path, expected });
    }
}

fn checkJson(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read license metadata with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);
    const normalized = packages.jsonWithoutComments(gpa, contents) catch |err| {
        try appendViolation(gpa, violations, "{s}: could not normalize JSONC license metadata ({s})", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(normalized);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, normalized, .{}) catch |err| {
        try appendViolation(gpa, violations, "{s}: invalid JSON while reading license metadata ({s})", .{ path, @errorName(err) });
        return;
    };
    defer parsed.deinit();
    const actual = switch (parsed.value) {
        .object => |object| switch (object.get("license") orelse .null) {
            .string => |value| value,
            else => "",
        },
        else => "",
    };
    if (!std.mem.eql(u8, actual, expected)) {
        try appendViolation(gpa, violations, "{s}: JSON manifest license is `{s}`, expected `{s}`", .{ path, if (actual.len == 0) "missing" else actual, expected });
    }
}

fn checkRacket(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read license metadata with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);
    if (!hasLine(contents, "(define license 'Apache-2.0)")) {
        try appendViolation(gpa, violations, "{s}: Racket package must declare `(define license 'Apache-2.0)`", .{path});
    }
}

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    try checkJson(io, gpa, root, violations, "deno.json");
    for (roots) |root_path| {
        if (try source_tree.collectSourceFiles(io, gpa, root, root_path, packageManifest)) |found| {
            defer {
                for (found) |path| gpa.free(path);
                gpa.free(found);
            }
            for (found) |path| {
                if (cargoManifest(path)) {
                    try checkCargo(io, gpa, root, violations, path);
                } else if (denoManifest(path) or npmManifest(path)) {
                    try checkJson(io, gpa, root, violations, path);
                } else if (std.mem.eql(u8, root_path, "bindings") and racketManifest(path)) {
                    try checkRacket(io, gpa, root, violations, path);
                }
            }
        }
    }
}
