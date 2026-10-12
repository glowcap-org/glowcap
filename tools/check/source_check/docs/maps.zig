//! The modules page's layer stack is a hand-written map of `src/`: prose a
//! reader browses, so it stays hand-written. This check makes leaving a new
//! module family out of it a failure instead of a silent gap. (The example
//! inventory has its own check in `project_shape/examples.zig`.)

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

/// Source families the modules map leaves out. The oracle is the
/// test reference corpus, not a module an application imports.
const unmapped_families = [_][]const u8{"oracle"};

/// Every source family under `src/` (and each protocol family under
/// `src/ocapn/`) has a layer in the modules page's stack, so the map a reader
/// uses to place a module cannot quietly omit a new one.
pub fn checkModuleMapLayers(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const map_path = "site/layouts/modules.shtml";
    const map = root.readFileAlloc(io, map_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for module map check with {s}", .{ map_path, @errorName(err) });
        return;
    };
    defer gpa.free(map);
    try checkFamilies(io, gpa, root, "src", map, map_path, violations);
    try checkFamilies(io, gpa, root, "src/ocapn", map, map_path, violations);
}

fn checkFamilies(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    dir_path: []const u8,
    map: []const u8,
    map_path: []const u8,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for module map check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        // `src/ocapn` is mapped through its families, checked separately.
        if (std.mem.eql(u8, dir_path, "src") and std.mem.eql(u8, entry.name, "ocapn")) continue;
        if (isUnmapped(entry.name)) continue;
        const label = try std.fmt.allocPrint(gpa, "<strong>{s}</strong>", .{entry.name});
        defer gpa.free(label);
        if (std.mem.indexOf(u8, map, label) == null) {
            try appendViolation(gpa, violations, "{s}/{s}: no layer in {s}; add it where its imports place it", .{ dir_path, entry.name, map_path });
        }
    }
}

fn isUnmapped(name: []const u8) bool {
    for (unmapped_families) |family| {
        if (std.mem.eql(u8, family, name)) return true;
    }
    return false;
}
