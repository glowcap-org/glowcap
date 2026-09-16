//! Shared npm packages move together across Deno configuration scopes.

const std = @import("std");
const util = @import("../util.zig");
const packages = @import("packages.zig");

const appendViolation = util.appendViolation;

/// Deno config inheritance does not merge import maps. Application scopes must
/// repeat shared packages, so this check makes each required copy move as one
/// pin.
pub fn checkSharedNpmPins(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const root_path = "deno.json";
    const rooms_path = "apps/rooms/web/deno.json";
    const ocapnviz_path = "apps/ocapnviz/deno.json";
    const root_config = try readConfig(io, gpa, root, violations, root_path) orelse return;
    defer root_config.deinit();
    const rooms = try readConfig(io, gpa, root, violations, rooms_path) orelse return;
    defer rooms.deinit();
    const ocapnviz = try readConfig(io, gpa, root, violations, ocapnviz_path) orelse return;
    defer ocapnviz.deinit();

    try checkPinParity(gpa, violations, root_path, root_config.value, rooms_path, rooms.value);
    try checkPinParity(gpa, violations, root_path, root_config.value, ocapnviz_path, ocapnviz.value);
    try checkPinParity(gpa, violations, ocapnviz_path, ocapnviz.value, rooms_path, rooms.value);
}

fn readConfig(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !?std.json.Parsed(std.json.Value) {
    const source = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot be read for shared npm pin parity ({s})", .{ path, @errorName(err) });
        return null;
    };
    defer gpa.free(source);
    const normalized = packages.jsonWithoutComments(gpa, source) catch |err| {
        try appendViolation(gpa, violations, "{s}: invalid JSONC ({s})", .{ path, @errorName(err) });
        return null;
    };
    defer gpa.free(normalized);
    return std.json.parseFromSlice(std.json.Value, gpa, normalized, .{}) catch |err| {
        try appendViolation(gpa, violations, "{s}: invalid JSONC ({s})", .{ path, @errorName(err) });
        return null;
    };
}

fn checkPinParity(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    authority_path: []const u8,
    authority: std.json.Value,
    consumer_path: []const u8,
    consumer: std.json.Value,
) !void {
    const authority_imports = try importMap(gpa, violations, authority_path, authority) orelse return;
    const consumer_imports = try importMap(gpa, violations, consumer_path, consumer) orelse return;
    var entries = authority_imports.iterator();
    while (entries.next()) |entry| {
        const authority_value = stringValue(entry.value_ptr.*) orelse continue;
        const consumer_value = stringValue(consumer_imports.get(entry.key_ptr.*) orelse continue) orelse continue;
        if (!std.mem.startsWith(u8, authority_value, "npm:") and !std.mem.startsWith(u8, consumer_value, "npm:")) continue;
        if (!std.mem.eql(u8, authority_value, consumer_value)) {
            try appendViolation(gpa, violations, "{s}: `{s}` maps to `{s}`, but {s} maps it to `{s}`. Shared packages move as one pin", .{ consumer_path, entry.key_ptr.*, consumer_value, authority_path, authority_value });
        }
    }
}

fn importMap(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    config: std.json.Value,
) !?std.json.ObjectMap {
    const root = switch (config) {
        .object => |object| object,
        else => {
            try appendViolation(gpa, violations, "{s}: Deno configuration root must be an object", .{path});
            return null;
        },
    };
    return switch (root.get("imports") orelse .null) {
        .object => |imports| imports,
        else => {
            try appendViolation(gpa, violations, "{s}: `imports` must be an object for shared npm pin parity", .{path});
            return null;
        },
    };
}

fn stringValue(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

test "shared npm pin parity follows import-map keys" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |item| gpa.free(item);
        violations.deinit(gpa);
    }
    const authority =
        \\{
        \\  "imports": {
        \\    "react": "npm:react@19.3.0"
        \\  }
        \\}
    ;
    const consumer =
        \\{
        \\  "compilerOptions": { "jsxImportSource": "react" },
        \\  "imports": {
        \\    "react": "npm:react@19.3.1"
        \\  }
        \\}
    ;

    const parsed_authority = try std.json.parseFromSlice(std.json.Value, gpa, authority, .{});
    defer parsed_authority.deinit();
    const parsed_consumer = try std.json.parseFromSlice(std.json.Value, gpa, consumer, .{});
    defer parsed_consumer.deinit();
    try checkPinParity(gpa, &violations, "root", parsed_authority.value, "app", parsed_consumer.value);
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "19.3.1") != null);
}
