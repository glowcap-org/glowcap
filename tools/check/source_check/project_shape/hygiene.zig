//! Source hygiene rules: justified map-removal discards, path I/O copy
//! bans, and the devcontainer's bash scripts held to their contract.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const sectionBody = util.sectionBody;
const collectBulletSpans = util.collectBulletSpans;

/// A map removal that discards its presence bool — `_ = map.remove(k)` and the
/// `.fetchRemove(` / `.swapRemove(` shapes — throws away a checkable fact: a
/// logic bug that removed a key the code believed present passes unnoticed. In
/// `src/` and `cli/`, every such discard must either assert the removal
/// (`std.debug.assert(map.remove(k))`, which still runs the remove in release,
/// only adding the check in safe builds) when presence is an established
/// invariant, or carry an inline `// idempotent:` / `// tolerant:` justification
/// when presence is genuinely not guaranteed. This holds the distinction
/// mechanically for every future removal (see the allocator-discipline section
/// of `.agents/rules/memory.md`). `orderedRemove` returns the element, not a
/// presence bool, so it is deliberately not flagged.
///
/// `cli/` is in scope because the product binary keeps tables of its own — the
/// rooms peer's per-nick maps among them — and a discard there loses the same
/// fact for the same reason.
pub fn checkRemoveDiscards(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for ([_][]const u8{ "src", "cli" }) |tree| {
        var dir = root.openDir(io, tree, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for remove-discard check with {s}", .{ tree, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ tree, entry.path });
            defer gpa.free(path);
            try checkRemoveDiscardsInFile(io, gpa, root, violations, path);
        }
    }
}

/// True when `line` is a code (non-comment) line that discards a presence-bool
/// removal with `_ =`.
fn removeDiscardLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "//")) return false;
    if (std.mem.indexOf(u8, line, "_ = ") == null) return false;
    return std.mem.indexOf(u8, line, ".remove(") != null or
        std.mem.indexOf(u8, line, ".fetchRemove(") != null or
        std.mem.indexOf(u8, line, ".swapRemove(") != null;
}

fn hasRemoveJustification(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "idempotent:") != null or
        std.mem.indexOf(u8, line, "tolerant:") != null;
}

/// A discard is justified by a marker on its own line or anywhere in the
/// contiguous `//` comment block directly above it.
fn removeDiscardJustified(lines: []const []const u8, i: usize) bool {
    if (hasRemoveJustification(lines[i])) return true;
    var j = i;
    while (j > 0) {
        j -= 1;
        const trimmed = std.mem.trimStart(u8, lines[j], " \t");
        if (!std.mem.startsWith(u8, trimmed, "//")) return false;
        if (hasRemoveJustification(lines[j])) return true;
    }
    return false;
}

fn checkRemoveDiscardsInFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for remove-discard check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| try lines.append(gpa, line);

    for (lines.items, 0..) |line, i| {
        if (!removeDiscardLine(line)) continue;
        if (removeDiscardJustified(lines.items, i)) continue;
        try appendViolation(gpa, violations, "{s}:{d}: `_ =` discards a map removal's presence bool — assert it (`std.debug.assert(map.remove(k))`, which still runs in release) when presence is an invariant, or add an inline `// idempotent:` / `// tolerant:` justification", .{ path, i + 1 });
    }
}

/// The two copies of the product I/O directory helper are one text.
///
/// `cli/operability/path_io.zig` and
/// `apps/accountability-on-pancake/zig/path_io.zig` work around the same Zig
/// standard-library wart, and the application copies it rather than importing
/// it because its whole claim is that it reaches for nothing in this repository
/// but pancake's own public surface. The copy earns its place on that argument
/// and on no other, so it has to stay a copy — and an identical one. A
/// near-version drifts: the difference that matters here is swallowing every
/// `openDir` error rather than only absence, which turns a permission failure
/// into a misleading one.
///
/// Only the bodies are compared. Each file's `//!` header explains its own
/// position, which is the one thing they should not share.
pub fn checkPathIoCopies(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const canonical_path = "cli/operability/path_io.zig";
    const copy_path = "apps/accountability-on-pancake/zig/path_io.zig";
    const marker = "const std = @import(\"std\");";

    const canonical = root.readFileAlloc(io, canonical_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read it to compare against its application copy ({s})", .{ canonical_path, @errorName(err) });
        return;
    };
    defer gpa.free(canonical);
    const copy = root.readFileAlloc(io, copy_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read the application copy of {s} ({s})", .{ copy_path, canonical_path, @errorName(err) });
        return;
    };
    defer gpa.free(copy);

    const canonical_body = std.mem.indexOf(u8, canonical, marker) orelse {
        try appendViolation(gpa, violations, "{s}: has no `{s}` line, so its body cannot be told from its header", .{ canonical_path, marker });
        return;
    };
    const copy_body = std.mem.indexOf(u8, copy, marker) orelse {
        try appendViolation(gpa, violations, "{s}: has no `{s}` line, so its body cannot be told from its header", .{ copy_path, marker });
        return;
    };
    if (!std.mem.eql(u8, canonical[canonical_body..], copy[copy_body..])) {
        try appendViolation(gpa, violations, "{s}: below `{s}`, differs from {s}. The two are one text; edit the canonical copy and mirror it, or delete the copy and say why it is no longer needed.", .{ copy_path, marker, canonical_path });
    }
}

/// Host and image scripts under `.devcontainer/` are top-level `*.sh` files so
/// `post-create.sh`'s shellcheck glob sees them. Extensionless or nested bash
/// files there are unlinted scripts.
pub fn checkDevcontainerBashScripts(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const dir_path = ".devcontainer";
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open ({s})", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.path, "patches/")) continue;
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
        defer gpa.free(path);
        if (std.mem.endsWith(u8, entry.path, ".sh")) {
            if (std.mem.indexOfScalar(u8, entry.path, '/') == null) continue;
            try appendViolation(
                gpa,
                violations,
                "{s}: bash scripts must stay at the top of .devcontainer/ so post-create.sh lints them",
                .{path},
            );
            continue;
        }
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 16)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to inspect ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        const line_end = std.mem.indexOfScalar(u8, contents, '\n') orelse contents.len;
        const first = contents[0..line_end];
        if (!std.mem.startsWith(u8, first, "#!")) continue;
        if (std.mem.indexOf(u8, first, "bash") == null) continue;
        try appendViolation(
            gpa,
            violations,
            "{s}: bash scripts in .devcontainer/ must be top-level *.sh files so post-create.sh lints them",
            .{path},
        );
    }
}
