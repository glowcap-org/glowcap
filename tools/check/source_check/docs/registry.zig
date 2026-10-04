//! The living-state registry and planning-doc roles: every doc that claims
//! to describe the present is registered, every registered path exists, and
//! active plans are linked from the roadmap or upstream watch.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const living_state = @import("living_state.zig");

pub fn checkPlanningDocRoles(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // No planning docs is a valid state: the directory exists only while a
    // plan note is alive, and git does not track empty directories.
    var planning = root.openDir(io, "docs/planning", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try appendViolation(gpa, violations, "docs/planning: failed to open planning docs with {s}", .{@errorName(err)});
            return;
        },
    };
    defer planning.close(io);

    const roadmap = try root.readFileAlloc(io, "docs/roadmap.md", gpa, .limited(1 << 20));
    defer gpa.free(roadmap);
    const upstream = try root.readFileAlloc(io, "docs/upstream-watch.md", gpa, .limited(1 << 20));
    defer gpa.free(upstream);

    var walker = try planning.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const contents = planning.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "docs/planning/{s}: failed to read with {s}", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        const active = std.mem.indexOf(u8, contents, "Status: active plan") != null;
        if (!active and
            std.mem.indexOf(u8, contents, "Status: historical") == null and
            std.mem.indexOf(u8, contents, "Status: living-state") == null)
        {
            try appendViolation(gpa, violations, "docs/planning/{s}: must declare `Status: active plan`, `Status: historical ...`, or `Status: living-state ...`", .{entry.path});
        }

        if (active) {
            const link = try std.fmt.allocPrint(gpa, "](planning/{s})", .{entry.path});
            defer gpa.free(link);
            if (std.mem.indexOf(u8, roadmap, link) == null and std.mem.indexOf(u8, upstream, link) == null) {
                try appendViolation(gpa, violations, "docs/planning/{s}: active plan must have a direct link from docs/roadmap.md or docs/upstream-watch.md", .{entry.path});
            }
        }
    }
}

/// The living-state registry (`living_state.surfaces`) is held honest in both
/// directions. Forward: a registered non-glob path must exist, since an entry
/// naming a deleted file is a broken promise. Reverse: every top-level
/// `docs/*.md` file, every `docs/` subdirectory doc that declares itself a
/// living-state surface, and every `docs/planning/*.md` that declares
/// `Status: living-state` must be registered, so no doc claims a maintenance
/// discipline that no check holds.
pub fn checkLivingStateRegistry(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const rule_path = "tools/check/source_check/docs/living_state.zig";
    var registry = std.StringHashMap(void).init(gpa);
    defer registry.deinit();
    for (living_state.surfaces) |entry| try registry.put(entry, {});

    // Forward: every registered non-glob path resolves.
    var entries = registry.keyIterator();
    while (entries.next()) |entry| {
        if (std.mem.indexOfScalar(u8, entry.*, '*') != null) continue;
        root.access(io, entry.*, .{}) catch |err| {
            try appendViolation(gpa, violations, "{s}: living-state registry names missing `{s}` ({s})", .{ rule_path, entry.*, @errorName(err) });
        };
    }

    // Reverse: every top-level docs/*.md is registered.
    var docs = root.openDir(io, "docs", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "docs: failed to open for living-state registry check with {s}", .{@errorName(err)});
        return;
    };
    defer docs.close(io);
    var docs_it = docs.iterate();
    while (try docs_it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        var needle_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "docs/{s}", .{entry.name}) catch {
            try appendViolation(gpa, violations, "docs/{s}: the file name overflows the registry needle buffer; grow it", .{entry.name});
            continue;
        };
        if (!registry.contains(needle)) {
            try appendViolation(gpa, violations, "{s}: top-level doc `{s}` is not in the living-state registry", .{ rule_path, needle });
        }
    }

    // Reverse: every doc under a docs/ subdirectory that declares itself a
    // living-state surface is registered, by exact path or by a covering glob
    // (`docs/protocol-diagrams/**`). Top-level docs and planning docs are held
    // by the checks around this one; this one keeps a subdirectory corpus from
    // promising a maintenance discipline no gate holds.
    var docs_walker = try docs.walk(gpa);
    defer docs_walker.deinit();
    while (try docs_walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
        if (std.mem.indexOfScalar(u8, entry.path, '/') == null) continue;
        if (std.mem.startsWith(u8, entry.path, "planning/")) continue;
        const contents = docs.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "docs/{s}: cannot be read for the living-state registry check ({s})", .{ entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "Living-state surface") == null) continue;
        var covered_buf: [256]u8 = undefined;
        const covered_path = std.fmt.bufPrint(&covered_buf, "docs/{s}", .{entry.path}) catch {
            try appendViolation(gpa, violations, "docs/{s}: the path overflows the registry needle buffer; grow it", .{entry.path});
            continue;
        };
        if (!registryCovers(&registry, covered_path)) {
            try appendViolation(gpa, violations, "{s}: `{s}` declares itself a living-state surface but no registry entry covers it", .{ rule_path, covered_path });
        }
    }

    // Reverse: every planning doc that declares itself living-state is registered.
    var planning = root.openDir(io, "docs/planning", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            try appendViolation(gpa, violations, "docs/planning: failed to open for living-state registry check with {s}", .{@errorName(err)});
            return;
        },
    };
    defer planning.close(io);
    var planning_it = planning.iterate();
    while (try planning_it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const contents = planning.readFileAlloc(io, entry.name, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "docs/planning/{s}: cannot be read for the living-state registry check ({s})", .{ entry.name, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "Status: living-state") == null) continue;
        var needle_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "docs/planning/{s}", .{entry.name}) catch {
            try appendViolation(gpa, violations, "docs/planning/{s}: the file name overflows the registry needle buffer; grow it", .{entry.name});
            continue;
        };
        if (!registry.contains(needle)) {
            try appendViolation(gpa, violations, "{s}: planning doc `{s}` declares living-state but is not in the registry", .{ rule_path, needle });
        }
    }
}

/// Returns true when the registry names `path` exactly or carries a glob
/// entry whose fixed prefix (the text before the first `*`) covers it.
fn registryCovers(registry: *const std.StringHashMap(void), path: []const u8) bool {
    if (registry.contains(path)) return true;
    var entries = registry.keyIterator();
    while (entries.next()) |entry| {
        const star = std.mem.indexOfScalar(u8, entry.*, '*') orelse continue;
        if (star == 0) continue;
        if (std.mem.startsWith(u8, path, entry.*[0..star])) return true;
    }
    return false;
}
