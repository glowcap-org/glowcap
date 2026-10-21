//! Paths a rename leaves pointing at nothing.
//!
//! `new URL("…", import.meta.url)` names a file with a string. No typechecker
//! follows it and no import graph contains it, so moving the target leaves the
//! string behind and nothing says a word. It surfaces only when that line runs,
//! and the worst shape is a test guarded by such a path: the guard misses, the
//! test skips itself, and a suite that never ran its own case reports green.
//!
//! One reorganization here left three of these, and they stood until a sweep by
//! hand went looking. The [doc-drift rule](../../../.agents/rules/doc-drift.md)
//! asks for that sweep. This asks the build instead, which is the half that
//! runs every time.
//!
//! Scoped to the trees that pass it. A tree joins `roots` in the same
//! change that empties it, the way the sibling doc and scene checks were
//! placed.
//!
//! It reads one form and only one: a literal first argument with
//! `import.meta.url` as the base. A path built by joining, as
//! `` `${ROOT}apps/…` `` does in about two dozen places here, is the same
//! defect and is not read, because resolving it means following `ROOT` to
//! whichever file exported it. `import.meta.resolve` is not read either. So a
//! green run says the `new URL` form is sound, never that every path in these
//! trees is.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// Where this holds.
const roots = [_][]const u8{ "apps/rooms", "bindings/ts" };

/// A build product rather than a source file. A clean checkout has none, so
/// demanding it would fail before the first build instead of on a real mistake.
const generated = "zig-out/";

fn isSourcePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ts") or std.mem.endsWith(u8, path, ".tsx");
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// `link` resolved against the directory holding `from_file`, both repository
/// relative, or null when it climbs past the repository root. An empty result
/// is the root itself.
fn resolve(gpa: std.mem.Allocator, from_file: []const u8, link: []const u8) !?[]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var base = std.mem.splitScalar(u8, std.fs.path.dirname(from_file) orelse "", '/');
    while (base.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        try parts.append(gpa, segment);
    }
    var walk = std.mem.splitScalar(u8, link, '/');
    while (walk.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (parts.items.len == 0) return null;
            _ = parts.pop();
            continue;
        }
        try parts.append(gpa, segment);
    }
    return try std.mem.join(gpa, "/", parts.items);
}

/// Whether this literal is a path into the repository at all. An absolute URL
/// names somewhere else entirely and a generated path may not be built yet. status-allow: pending state or quoted runtime label
fn isCheckable(literal: []const u8) bool {
    if (literal.len == 0) return false;
    if (std.mem.indexOf(u8, literal, "://") != null) return false;
    if (std.mem.startsWith(u8, literal, "data:")) return false;
    if (std.mem.indexOf(u8, literal, generated) != null) return false;
    return true;
}

fn checkFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    body: []const u8,
    violations: *std.ArrayList([]const u8),
) !void {
    const opener = "new URL(";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, body, at, opener)) |found| {
        at = found + opener.len;
        // Whitespace here spans lines, so the argument written on its own line
        // reads the same as the argument written inline. That form is the one
        // that hid a stale path from an earlier hand-written sweep. status-allow: event or source ordering
        var i = at;
        while (i < body.len and isSpace(body[i])) i += 1;
        // A computed first argument names no literal to check.
        if (i >= body.len or body[i] != '"') continue;
        const start = i + 1;
        const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse continue;
        const literal = body[start..end];
        var after = end + 1;
        while (after < body.len and (isSpace(body[after]) or body[after] == ',')) after += 1;
        // Only the `import.meta.url` base resolves against this file's own
        // directory; any other base is somebody else's arithmetic.
        if (!std.mem.startsWith(u8, body[after..], "import.meta.url")) continue;
        if (!isCheckable(literal)) continue;
        const resolved = (try resolve(gpa, path, literal)) orelse {
            try appendViolation(
                gpa,
                violations,
                "{s}: `{s}` climbs past the repository root",
                .{ path, literal },
            );
            continue;
        };
        defer gpa.free(resolved);
        if (resolved.len == 0) continue;
        root.access(io, resolved, .{}) catch {
            try appendViolation(
                gpa,
                violations,
                "{s}: `{s}` resolves to {s}, which does not exist",
                .{ path, literal, resolved },
            );
        };
    }
}

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for (roots) |root_path| {
        const files = (try util.collectSourceFiles(io, gpa, root, root_path, isSourcePath)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to open for the runtime-path check", .{root_path});
            continue;
        };
        defer {
            for (files) |path| gpa.free(path);
            gpa.free(files);
        }
        for (files) |path| {
            const body = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(body);
            try checkFile(io, gpa, root, path, body, violations);
        }
    }
}
