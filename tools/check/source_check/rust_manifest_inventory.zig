//! Every first-party Rust crate is formatted and linted.
//!
//! `bindings_steps.zig` holds the manifests `bindings-fmt-check` and
//! `rust-lint` run over in `rust_manifests`. A crate missing from that list
//! is formatted and linted by nobody, while its manifest still declares the
//! lint floor it is never held to. This rule finds each manifest the tree
//! carries and requires the list to name it, unless a workspace manifest above
//! it already covers it as a member.

const std = @import("std");
const util = @import("util.zig");

const list_file = "tools/build/bindings_steps.zig";
const list_marker = "const rust_manifests = [_][]const u8{";
/// Where first-party Rust lives.
const roots = [_][]const u8{ "apps", "bindings", "bench", "transports", "test" };

fn isManifest(path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(path), "Cargo.toml") and
        std.mem.indexOf(u8, path, "/upstream/") == null;
}

/// The manifests in `manifests` that `list` must name: each one no workspace
/// manifest above it covers. `workspaces[i]` says whether `manifests[i]`
/// declares a workspace.
fn uncovered(manifest: []const u8, manifests: []const []const u8, workspaces: []const bool) bool {
    const dir = std.fs.path.dirname(manifest) orelse "";
    for (manifests, workspaces) |other, workspace| {
        if (!workspace or std.mem.eql(u8, other, manifest)) continue;
        const above = std.fs.path.dirname(other) orelse "";
        if (dir.len > above.len and std.mem.startsWith(u8, dir, above) and dir[above.len] == '/') return false;
    }
    return true;
}

fn listed(list: []const u8, manifest: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, list, at, manifest)) |hit| {
        at = hit + manifest.len;
        if (hit > 0 and list[hit - 1] == '"' and at < list.len and list[at] == '"') return true;
    }
    return false;
}

pub fn check(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir, violations: *std.ArrayList([]const u8)) !void {
    const source = root.readFileAlloc(io, list_file, gpa, .limited(1 << 20)) catch |err| {
        try util.appendViolation(gpa, violations, "{s}: cannot read it ({s})", .{ list_file, @errorName(err) });
        return;
    };
    defer gpa.free(source);
    const list = util.extractBraceBlock(source, list_marker) orelse {
        try util.appendViolation(gpa, violations, "{s}: has no `{s}` list", .{ list_file, list_marker });
        return;
    };
    var manifests: std.ArrayList([]u8) = .empty;
    defer {
        for (manifests.items) |path| gpa.free(path);
        manifests.deinit(gpa);
    }
    for (roots) |root_path| {
        const found = try util.collectSourceFiles(io, gpa, root, root_path, isManifest) orelse continue;
        defer gpa.free(found);
        try manifests.appendSlice(gpa, found);
    }
    const workspaces = try gpa.alloc(bool, manifests.items.len);
    defer gpa.free(workspaces);
    for (manifests.items, workspaces) |manifest, *workspace| {
        const contents = root.readFileAlloc(io, manifest, gpa, .limited(1 << 20)) catch |err| {
            try util.appendViolation(gpa, violations, "{s}: cannot read it ({s})", .{ manifest, @errorName(err) });
            workspace.* = false;
            continue;
        };
        defer gpa.free(contents);
        workspace.* = std.mem.startsWith(u8, contents, "[workspace]") or std.mem.indexOf(u8, contents, "\n[workspace]") != null;
    }
    for (manifests.items) |manifest| {
        if (!uncovered(manifest, manifests.items, workspaces) or listed(list, manifest)) continue;
        try util.appendViolation(gpa, violations, "{s}: no format or lint check covers this crate; add it to `rust_manifests` in {s}", .{ manifest, list_file });
    }
}

test "a workspace covers its members and nothing beside it" {
    const manifests = [_][]const u8{ "apps/rooms/rust/Cargo.toml", "apps/rooms/rust/runtime/Cargo.toml", "apps/rooms/rustic/Cargo.toml", "bindings/rust/relay/Cargo.toml" };
    const workspaces = [_]bool{ true, false, false, false };
    try std.testing.expect(uncovered(manifests[0], &manifests, &workspaces));
    try std.testing.expect(!uncovered(manifests[1], &manifests, &workspaces));
    try std.testing.expect(uncovered(manifests[2], &manifests, &workspaces));
    try std.testing.expect(uncovered(manifests[3], &manifests, &workspaces));
}

test "only a quoted path is listed" {
    const list = "\"apps/tasks/rust/Cargo.toml\",\n// apps/tools/rust/Cargo.toml\n";
    try std.testing.expect(listed(list, "apps/tasks/rust/Cargo.toml"));
    try std.testing.expect(!listed(list, "apps/tools/rust/Cargo.toml"));
    try std.testing.expect(!listed(list, "tasks/rust/Cargo.toml"));
}
