//! A crate that writes `unsafe` declares where the unsafety has to be marked.
//!
//! At edition 2024 an `unsafe fn` body is no longer implicitly unsafe: each raw
//! operation inside one says so at the operation, which is the point of the
//! change, because the alternative is a blanket claim on the signature that
//! covers whatever the body grows into later. Rust only *warns* when a body has
//! not caught up, so the whole class accumulates quietly, and it accumulates
//! per target: a body behind `#[cfg(target_arch = "wasm32")]` is invisible to
//! a sweep run on the host, which is exactly how one was missed here.
//!
//! `unsafe_op_in_unsafe_fn = "deny"` in a crate's manifest turns that warning
//! into a build failure on whichever target compiles the body. This rule holds
//! every crate that writes unsafe to having declared it. The same shape holds
//! clippy's `undocumented_unsafe_blocks` for every crate that writes an unsafe
//! block or `unsafe impl`: each block carries the `// SAFETY:` comment that
//! names the handle, owner, and pointer source it relies on, and the lint,
//! not a reviewer, asks for it back when one goes missing.
//!
//! It exists because prose could not hold the line. That one declaration was
//! lost twice in consecutive changes: once resolved into `[lints.clippy]`,
//! where it named a lint that does not exist and clippy said so on every run,
//! and once dropped outright by a rebase while its rationale comment stayed
//! behind to claim it was there. Both times the comment survived and the floor
//! did not, which is the failure mode a comment is worst at catching.
//!
//! Scoped by discovery rather than by a list, so a crate added tomorrow is
//! covered without anyone remembering to enrol it. A crate with no `unsafe fn`
//! and no `unsafe extern` block is not asked for anything: the floor is for
//! crates that have something to hold.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// Where first-party Rust lives. Vendored and generated trees are skipped by
/// `interesting` below.
const roots = [_][]const u8{ "apps", "bindings", "bench", "transports" };

fn vendored(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "node_modules") != null or
        std.mem.indexOf(u8, path, "/target/") != null or
        std.mem.indexOf(u8, path, "/upstream/") != null;
}

fn isManifest(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "Cargo.toml") and !vendored(path);
}

fn isRust(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".rs") and !vendored(path);
}

/// The directory a manifest governs, as a repository-relative prefix ending in
/// `/` so prefix tests cannot match a sibling whose name merely starts the same.
fn crateDir(gpa: std.mem.Allocator, manifest: []const u8) ![]u8 {
    const cut = std.mem.lastIndexOfScalar(u8, manifest, '/') orelse return gpa.dupe(u8, "");
    return std.fmt.allocPrint(gpa, "{s}/", .{manifest[0..cut]});
}

/// The body of one TOML table, from its header to the next one. Enough for the
/// question here, which is whether a named key is declared under a named table,
/// a manifest that needs more than that is a manifest this rule should not be
/// guessing about.
fn tableBody(contents: []const u8, header: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, contents, at, header)) |found| {
        at = found + header.len;
        const line_start = if (std.mem.lastIndexOfScalar(u8, contents[0..found], '\n')) |nl| nl + 1 else 0;
        // The header has to start its own line, so `[lints.rust]` is not found
        // inside a comment that mentions it.
        if (std.mem.trim(u8, contents[line_start..found], " \t").len != 0) continue;
        var rest = contents[at..];
        var end: usize = 0;
        while (end < rest.len) {
            const nl = std.mem.indexOfScalarPos(u8, rest, end, '\n') orelse return rest;
            const next = nl + 1;
            if (next < rest.len and rest[next] == '[') return rest[0..next];
            end = next;
        }
        return rest;
    }
    return null;
}

/// `key` is declared in `body` at a level that denies. A commented-out line
/// does not count, which is the whole reason this looks at line starts.
fn deniesIn(body: []const u8, key: []const u8) bool {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        const rest = std.mem.trimStart(u8, line[key.len..], " \t");
        if (!std.mem.startsWith(u8, rest, "=")) continue;
        const value = std.mem.trimStart(u8, rest[1..], " \t");
        if (std.mem.startsWith(u8, value, "\"deny\"") or std.mem.startsWith(u8, value, "\"forbid\"")) return true;
    }
    return false;
}

/// One declaration this rule holds. A crate whose sources contain any of
/// `triggers` declares `lint` at a denying level under `table`, or takes the
/// workspace's table and the workspace declares it under `workspace_table`.
const Requirement = struct {
    triggers: []const []const u8,
    table: []const u8,
    workspace_table: []const u8,
    lint: []const u8,
    /// What the crate writes, for the violation text.
    writes: []const u8,
    /// What goes wrong without the declaration, for the violation text.
    why: []const u8,
};

const requirements = [_]Requirement{
    .{
        .triggers = &.{ "unsafe fn ", "unsafe extern " },
        .table = "[lints.rust]",
        .workspace_table = "[workspace.lints.rust]",
        .lint = "unsafe_op_in_unsafe_fn",
        .writes = "`unsafe fn` or `unsafe extern`",
        .why = "without it a body whose operations are unmarked only warns, and only on the targets that compile it",
    },
    .{
        .triggers = &.{ "unsafe {", "unsafe impl " },
        .table = "[lints.clippy]",
        .workspace_table = "[workspace.lints.clippy]",
        .lint = "undocumented_unsafe_blocks",
        .writes = "`unsafe` blocks or `unsafe impl`",
        .why = "without it a block can drop the `// SAFETY:` comment that names the handle, owner, and pointer source it relies on, and nothing asks for it back",
    },
};

/// `lint` is denied under `table` in this manifest.
fn declaresDeny(manifest: []const u8, table: []const u8, lint: []const u8) bool {
    const body = tableBody(manifest, table) orelse return false;
    return deniesIn(body, lint);
}

/// The manifest takes the workspace's lint tables (`[lints] workspace = true`).
fn inheritsWorkspaceLints(manifest: []const u8) bool {
    const body = tableBody(manifest, "[lints]") orelse return false;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "workspace")) continue;
        const rest = std.mem.trimStart(u8, line["workspace".len..], " \t");
        if (!std.mem.startsWith(u8, rest, "=")) continue;
        return std.mem.startsWith(u8, std.mem.trimStart(u8, rest[1..], " \t"), "true");
    }
    return false;
}

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var manifests: std.ArrayList([]u8) = .empty;
    defer {
        for (manifests.items) |path| gpa.free(path);
        manifests.deinit(gpa);
    }
    var sources: std.ArrayList([]u8) = .empty;
    defer {
        for (sources.items) |path| gpa.free(path);
        sources.deinit(gpa);
    }
    for (roots) |root_path| {
        if (try util.collectSourceFiles(io, gpa, root, root_path, isManifest)) |found| {
            defer gpa.free(found);
            for (found) |path| try manifests.append(gpa, path);
        }
        if (try util.collectSourceFiles(io, gpa, root, root_path, isRust)) |found| {
            defer gpa.free(found);
            for (found) |path| try sources.append(gpa, path);
        }
    }

    var dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (dirs.items) |dir| gpa.free(dir);
        dirs.deinit(gpa);
    }
    for (manifests.items) |manifest| try dirs.append(gpa, try crateDir(gpa, manifest));

    for (manifests.items, dirs.items) |manifest, dir| {
        // This crate's own sources: under its directory, and not under a nested
        // crate's. A workspace root governs no source of its own that way, which
        // is right: its members each answer for themselves.
        var writes: [requirements.len]bool = @splat(false);
        for (sources.items) |source| {
            if (!std.mem.startsWith(u8, source, dir)) continue;
            var nested = false;
            for (dirs.items) |other| {
                if (other.len <= dir.len) continue;
                if (std.mem.startsWith(u8, other, dir) and std.mem.startsWith(u8, source, other)) nested = true;
            }
            if (nested) continue;
            // A subject this cannot read is not a subject that passes: the walk
            // already said the file is there, so failing to read it means the
            // rule does not know, and saying so beats answering green.
            const contents = root.readFileAlloc(io, source, gpa, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: could not be read for the unsafe floor rule ({t})", .{ source, err });
                continue;
            };
            defer gpa.free(contents);
            for (requirements, 0..) |requirement, index| {
                if (writes[index]) continue;
                for (requirement.triggers) |trigger| {
                    if (std.mem.indexOf(u8, contents, trigger) != null) writes[index] = true;
                }
            }
            var all_seen = true;
            for (writes) |seen| all_seen = all_seen and seen;
            if (all_seen) break;
        }
        var any_seen = false;
        for (writes) |seen| any_seen = any_seen or seen;
        if (!any_seen) continue;

        const contents = root.readFileAlloc(io, manifest, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: could not be read for the unsafe floor rule ({t})", .{ manifest, err });
            continue;
        };
        defer gpa.free(contents);
        for (requirements, writes) |requirement, required| {
            if (!required) continue;
            if (declaresDeny(contents, requirement.table, requirement.lint)) continue;
            // A member that takes the workspace's tables answers through them.
            if (inheritsWorkspaceLints(contents)) {
                var inherited = false;
                for (manifests.items, dirs.items) |other_manifest, other_dir| {
                    if (other_dir.len >= dir.len or !std.mem.startsWith(u8, dir, other_dir)) continue;
                    const other = root.readFileAlloc(io, other_manifest, gpa, .limited(4 << 20)) catch |err| {
                        try appendViolation(gpa, violations, "{s}: could not be read while resolving {s}'s inherited lints ({t})", .{ other_manifest, manifest, err });
                        continue;
                    };
                    defer gpa.free(other);
                    if (declaresDeny(other, requirement.workspace_table, requirement.lint)) inherited = true;
                }
                if (inherited) continue;
            }
            try appendViolation(
                gpa,
                violations,
                "{s}: this crate writes {s}, so it must declare `{s} = \"deny\"` under `{s}` (or inherit it through `[lints] workspace = true`); {s}",
                .{ manifest, requirement.writes, requirement.lint, requirement.table, requirement.why },
            );
        }
    }
}

test "tableBody reads to the next table and ignores a mention in a comment" {
    const manifest =
        \\# see [lints.rust] below
        \\[package]
        \\name = "x"
        \\
        \\[lints.rust]
        \\dead_code = "deny"
        \\unsafe_op_in_unsafe_fn = "deny"
        \\
        \\[lints.clippy]
        \\all = { level = "deny", priority = -1 }
        \\
    ;
    const body = tableBody(manifest, "[lints.rust]").?;
    try std.testing.expect(deniesIn(body, "unsafe_op_in_unsafe_fn"));
    try std.testing.expect(!deniesIn(tableBody(manifest, "[lints.clippy]").?, "unsafe_op_in_unsafe_fn"));
}

test "deniesIn refuses a warn level and a commented declaration" {
    try std.testing.expect(!deniesIn("unsafe_op_in_unsafe_fn = \"warn\"\n", "unsafe_op_in_unsafe_fn"));
    try std.testing.expect(!deniesIn("# unsafe_op_in_unsafe_fn = \"deny\"\n", "unsafe_op_in_unsafe_fn"));
    try std.testing.expect(deniesIn("  unsafe_op_in_unsafe_fn = \"forbid\"\n", "unsafe_op_in_unsafe_fn"));
}

test "a clippy table that only denies the all group does not hold the comment floor" {
    const without =
        \\[lints.clippy]
        \\all = { level = "deny", priority = -1 }
        \\
    ;
    try std.testing.expect(!declaresDeny(without, "[lints.clippy]", "undocumented_unsafe_blocks"));
    const with =
        \\[lints.clippy]
        \\all = { level = "deny", priority = -1 }
        \\undocumented_unsafe_blocks = "deny"
        \\
    ;
    try std.testing.expect(declaresDeny(with, "[lints.clippy]", "undocumented_unsafe_blocks"));
}

test "a member takes the workspace tables only through `workspace = true`" {
    try std.testing.expect(inheritsWorkspaceLints("[lints]\nworkspace = true\n"));
    try std.testing.expect(!inheritsWorkspaceLints("[lints]\nworkspace = false\n"));
    try std.testing.expect(!inheritsWorkspaceLints("[lints.rust]\nworkspace = true\n"));
}
