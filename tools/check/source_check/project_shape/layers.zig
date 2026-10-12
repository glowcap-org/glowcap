//! Layer ownership over src/: the layer table's claims held in both
//! directions, grouping directories without source of their own, and test
//! placement by authority.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const sectionBody = util.sectionBody;
const collectBulletSpans = util.collectBulletSpans;

/// The architecture rule's Layer Ownership list is the map a cold agent uses to
/// place code, so it is held to `src/` in both directions. Forward: every
/// bulleted layer resolves to a real `src/` directory. Reverse: every top-level
/// directory under `src/`, and every immediate child of a grouping directory
/// (`src/ocapn`, `src/c_abi`, see `checkGroupingChildren`), has a bullet, a
/// layer that ships unnamed is unplaceable, which is how `src/oracle` once
/// went missing from the map.
pub fn checkLayerOwnership(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const rule_path = ".agents/rules/architecture.md";
    const rule = root.readFileAlloc(io, rule_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for layer-ownership check with {s}", .{ rule_path, @errorName(err) });
        return;
    };
    defer gpa.free(rule);

    const section = sectionBody(rule, "## Layer Ownership") orelse {
        try appendViolation(gpa, violations, "{s}: missing `## Layer Ownership` section", .{rule_path});
        return;
    };

    var spans: std.ArrayList([]const u8) = .empty;
    defer spans.deinit(gpa);
    try collectBulletSpans(gpa, section, &spans);

    var named = std.StringHashMap(void).init(gpa);
    defer named.deinit();
    for (spans.items) |span| {
        const name = std.mem.trimEnd(u8, span, "/");
        try named.put(name, {});
        var path_buf: [160]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "src/{s}", .{name}) catch {
            try appendViolation(gpa, violations, "layer `{s}` overflows the ownership check path buffer; grow it", .{name});
            continue;
        };
        root.access(io, path, .{}) catch |err| {
            try appendViolation(gpa, violations, "{s}: Layer Ownership names `{s}` but `{s}` is not accessible ({s})", .{ rule_path, span, path, @errorName(err) });
        };
    }

    var src = root.openDir(io, "src", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src: failed to open for layer-ownership check with {s}", .{@errorName(err)});
        return;
    };
    defer src.close(io);
    var src_it = src.iterate();
    while (try src_it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!named.contains(entry.name)) {
            try appendViolation(gpa, violations, "{s}: `src/{s}` has no Layer Ownership bullet", .{ rule_path, entry.name });
        }
        // A grouping directory (`src/ocapn`, `src/c_abi`) holds a family of
        // layers rather than being one; hold each immediate child too.
        try checkGroupingChildren(io, gpa, root, entry.name, &named, violations, rule_path);
    }
}

/// A grouping directory under `src/`, one with no direct `.zig` file, only
/// subdirectories (`src/ocapn`, `src/c_abi`), is a family of layers, not a
/// layer itself. Each immediate child is its own layer, so it must carry a
/// `<group>/<child>` Layer Ownership bullet. An unnamed sub-layer is
/// unplaceable, exactly how `src/oracle` once went missing from the map.
/// A directory with its own `.zig` files is a layer (its files belong to it),
/// so it is skipped here. Recursion is one level: a child that is itself a
/// grouping dir (e.g. `ocapn/codec` over `syrup`/`capnp`) keeps its sub-layers
/// in `layer_table`, not in the placement map.
fn checkGroupingChildren(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    group: []const u8,
    named: *const std.StringHashMap(void),
    violations: *std.ArrayList([]const u8),
    rule_path: []const u8,
) !void {
    var path_buf: [160]u8 = undefined;
    const group_path = std.fmt.bufPrint(&path_buf, "src/{s}", .{group}) catch {
        try appendViolation(gpa, violations, "layer group `{s}` overflows the ownership check path buffer; grow it", .{group});
        return;
    };
    var dir = root.openDir(io, group_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: named in {s} but cannot be opened ({s})", .{ group_path, rule_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var subdirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (subdirs.items) |s| gpa.free(s);
        subdirs.deinit(gpa);
    }
    var has_zig = false;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            has_zig = true;
        } else if (entry.kind == .directory) {
            try subdirs.append(gpa, try gpa.dupe(u8, entry.name));
        }
    }
    if (has_zig) return;

    for (subdirs.items) |sub| {
        var needle_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "{s}/{s}", .{ group, sub }) catch {
            try appendViolation(gpa, violations, "layer subdirectory {s}/{s} overflows the ownership check needle buffer; grow it", .{ group, sub });
            continue;
        };
        if (!named.contains(needle)) {
            try appendViolation(gpa, violations, "{s}: `src/{s}/{s}` has no Layer Ownership bullet", .{ rule_path, group, sub });
        }
    }
}

/// The tests rule's Placement list routes a new test to its directory, so it is
/// held to `test/` in both directions. Forward: every `test/...` bullet
/// resolves to a real path. Reverse: every top-level directory under `test/`
/// has a bullet, so a new suite cannot land without placement guidance.
pub fn checkTestPlacement(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const rule_path = ".agents/rules/tests.md";
    const rule = root.readFileAlloc(io, rule_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for test-placement check with {s}", .{ rule_path, @errorName(err) });
        return;
    };
    defer gpa.free(rule);

    const section = sectionBody(rule, "## Placement") orelse {
        try appendViolation(gpa, violations, "{s}: missing `## Placement` section", .{rule_path});
        return;
    };

    var spans: std.ArrayList([]const u8) = .empty;
    defer spans.deinit(gpa);
    try collectBulletSpans(gpa, section, &spans);

    var named = std.StringHashMap(void).init(gpa);
    defer named.deinit();
    for (spans.items) |span| {
        if (!std.mem.startsWith(u8, span, "test/")) continue;
        try named.put(span, {});
        root.access(io, span, .{}) catch |err| {
            try appendViolation(gpa, violations, "{s}: Placement names `{s}` but it is not accessible ({s})", .{ rule_path, span, @errorName(err) });
        };
    }

    var test_dir = root.openDir(io, "test", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "test: failed to open for test-placement check with {s}", .{@errorName(err)});
        return;
    };
    defer test_dir.close(io);
    var it = test_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var needle_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "test/{s}", .{entry.name}) catch {
            try appendViolation(gpa, violations, "test/{s}: the directory name overflows the placement needle buffer; grow it", .{entry.name});
            continue;
        };
        if (!named.contains(needle)) {
            try appendViolation(gpa, violations, "{s}: `test/{s}` has no Placement bullet", .{ rule_path, entry.name });
        }
    }
}
