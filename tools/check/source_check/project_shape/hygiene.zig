//! Source hygiene rules: justified map-removal discards, path I/O copy bans,
//! and the devcontainer's bash scripts held to their contract.

const std = @import("std");
const markdown = @import("../markdown.zig");
const source_tree = @import("../source_tree.zig");
const violation_log = @import("../violation_log.zig");

const appendViolation = violation_log.appendViolation;
const sectionBody = markdown.sectionBody;
const collectBulletSpans = markdown.collectBulletSpans;

const text_extensions = [_][]const u8{
    ".c",    ".css",   ".Dockerfile", ".h",      ".html",  ".js",
    ".json", ".jsonl", ".jsx",        ".lock",   ".map",   ".md",
    ".mjs",  ".py",    ".python",     ".racket", ".rkt",   ".rs",
    ".rust", ".scm",   ".sh",         ".shtml",  ".smd",   ".svg",
    ".toml", ".ts",    ".tsx",        ".txt",    ".typed", ".yaml",
    ".yml",  ".zig",   ".ziggy",      ".zon",
};

fn isTextSource(path: []const u8) bool {
    for (text_extensions) |extension| {
        if (std.mem.endsWith(u8, path, extension)) return true;
    }
    return false;
}

/// A raw NUL makes a source file binary to ordinary search, diff, and editor
/// tooling. Runtime separators belong in escaped source text (`\u0000` or the
/// host language's equivalent), so no first-party text source needs the byte.
pub fn checkRawNuls(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for ([_][]const u8{ "src", "cli", "apps", "bindings", "examples", "tools", "docs", "site", "ui" }) |tree| {
        const files = (try source_tree.collectSourceFiles(io, gpa, root, tree, keepTextSource)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to open for raw-NUL check", .{tree});
            continue;
        };
        defer {
            for (files) |path| gpa.free(path);
            gpa.free(files);
        }
        for (files) |path| {
            const contents = root.readFileAlloc(io, path, gpa, .limited(16 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: failed to read for raw-NUL check with {s}", .{ path, @errorName(err) });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.findScalar(u8, contents, 0) != null) try appendViolation(
                gpa,
                violations,
                "{s}: first-party text source contains a raw NUL byte; write the separator as an escape",
                .{path},
            );
        }
    }
}

fn keepTextSource(path: []const u8) bool {
    return isTextSource(path);
}

/// Every registered Rooms TypeScript test names the scenario its module owns
/// before imports and setup. This keeps a cold reader from reverse-engineering
/// the file's purpose from a list of individual test names.
pub fn checkRoomsTestHeaders(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const tree = "apps/rooms/test";
    var dir = root.openDir(io, tree, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for test-header check with {s}", .{ tree, @errorName(err) });
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".ts")) continue;
        const body = dir.readFileAlloc(io, entry.path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}/{s}: failed to read for test-header check with {s}", .{ tree, entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(body);
        if (std.mem.find(u8, body, "Deno.test(") == null and std.mem.find(u8, body, "roomsTest(") == null) continue;
        var rest = body;
        var first_line = true;
        while (rest.len > 0) {
            const line_end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
            const line = std.mem.trimEnd(u8, rest[0..line_end], "\r");
            if (!((first_line and std.mem.startsWith(u8, line, "#!")) or
                std.mem.startsWith(u8, line, "/// <reference"))) break;
            rest = if (line_end < rest.len) rest[line_end + 1 ..] else "";
            first_line = false;
        }
        const header_end = std.mem.findScalar(u8, rest, '\n') orelse rest.len;
        const header = std.mem.trimEnd(u8, rest[0..header_end], "\r");
        if (!std.mem.startsWith(u8, header, "// ")) try appendViolation(
            gpa,
            violations,
            "{s}/{s}: registered test module needs a leading sentence naming the scenario it proves",
            .{ tree, entry.path },
        );
    }
}

/// A map removal that discards its presence bool, `_ = map.remove(k)` and the
/// `.fetchRemove(` / `.swapRemove(` shapes, throws away a checkable fact: a
/// logic bug that removed a key the code believed present passes unnoticed. In
/// `src/` and `cli/`, every such discard must either assert the removal
/// (`std.debug.assert(map.remove(k))`, which still runs the remove in release,
/// only adding the check in safe builds) when presence is an established
/// invariant, or carry an inline `// idempotent:` / `// tolerant:` justification
/// when presence is not guaranteed. This holds the distinction
/// mechanically for every future removal (see the allocator-discipline section
/// of `.agents/rules/memory.md`). `orderedRemove` returns the element, not a
/// presence bool, so it is not flagged.
///
/// `cli/` is in scope because the product binary keeps tables of its own, the
/// rooms peer's per-nick maps among them, and a discard there loses the same
/// fact for the same reason.
pub fn checkRemoveDiscards(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for ([_][]const u8{ "src", "cli" }) |tree| {
        const files = (try source_tree.collectSourceFiles(io, gpa, root, tree, keepZig)) orelse {
            try appendViolation(gpa, violations, "{s}: failed to open for remove-discard check", .{tree});
            continue;
        };
        defer {
            for (files) |path| gpa.free(path);
            gpa.free(files);
        }
        for (files) |path| try checkRemoveDiscardsInFile(io, gpa, root, violations, path);
    }
}

fn keepZig(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig");
}

/// True when `line` is a code (non-comment) line that discards a presence-bool
/// removal with `_ =`.
fn removeDiscardLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "//")) return false;
    if (std.mem.find(u8, line, "_ = ") == null) return false;
    return std.mem.find(u8, line, ".remove(") != null or
        std.mem.find(u8, line, ".fetchRemove(") != null or
        std.mem.find(u8, line, ".swapRemove(") != null;
}

fn hasRemoveJustification(line: []const u8) bool {
    return std.mem.find(u8, line, "idempotent:") != null or
        std.mem.find(u8, line, "tolerant:") != null;
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
/// `apps/accountability-on-glowcap/zig/path_io.zig` work around the same Zig
/// standard-library wart, and the application copies it rather than importing
/// it because its whole claim is that it reaches for nothing in this repository
/// but glowcap's own public surface. The copy earns its place on that argument
/// and on no other, so it has to stay a copy, and an identical one. A
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
    const copy_path = "apps/accountability-on-glowcap/zig/path_io.zig";
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

    const canonical_body = std.mem.find(u8, canonical, marker) orelse {
        try appendViolation(gpa, violations, "{s}: has no `{s}` line, so its body cannot be told from its header", .{ canonical_path, marker });
        return;
    };
    const copy_body = std.mem.find(u8, copy, marker) orelse {
        try appendViolation(gpa, violations, "{s}: has no `{s}` line, so its body cannot be told from its header", .{ copy_path, marker });
        return;
    };
    if (!std.mem.eql(u8, canonical[canonical_body..], copy[copy_body..])) {
        try appendViolation(gpa, violations, "{s}: below `{s}`, differs from {s}. The two are one text; edit the canonical copy and mirror it, or delete the copy and say why it is no longer needed.", .{ copy_path, marker, canonical_path });
    }
}

/// Every bash file under `.devcontainer/` is linted. `hooks/post-create.sh`
/// runs shellcheck over every `*.sh` in the tree, so those are covered wherever
/// they sit. A bash file under any other name has to be named on that command
/// line, or nothing reads it. The pane runtime's host half is the case in
/// point: zsh's own half fixes its name, and the bash half matches it.
pub fn checkDevcontainerBashScripts(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const dir_path = ".devcontainer";
    const lint_path = ".devcontainer/hooks/post-create.sh";
    const lint_source = root.readFileAlloc(io, lint_path, gpa, .limited(1 << 16)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read ({s})", .{ lint_path, @errorName(err) });
        return;
    };
    defer gpa.free(lint_source);

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
        if (std.mem.endsWith(u8, entry.path, ".sh")) continue;
        const path = try gpa.print("{s}/{s}", .{ dir_path, entry.path });
        defer gpa.free(path);
        // Only the first line decides, and the tree also holds generated shell
        // state (zsh's compiled completion dump) far larger than any script, so
        // read a head rather than a whole file: reading whole made a generated
        // blob's size look like a file this check could not inspect.
        var head: [512]u8 = undefined;
        var file = root.openFile(io, path, .{}) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to inspect ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer file.close(io);
        const head_len = file.readPositionalAll(io, &head, 0) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to inspect ({s})", .{ path, @errorName(err) });
            continue;
        };
        const contents = head[0..head_len];
        const line_end = std.mem.findScalar(u8, contents, '\n') orelse contents.len;
        const first = contents[0..line_end];
        const shebang_bash = std.mem.startsWith(u8, first, "#!") and
            std.mem.find(u8, first, "bash") != null;
        const declared_bash = std.mem.find(u8, first, "shellcheck shell=bash") != null;
        if (!shebang_bash and !declared_bash) continue;
        if (std.mem.find(u8, lint_source, entry.path) != null) continue;
        try appendViolation(
            gpa,
            violations,
            "{s}: a bash file that is not *.sh must be named in {s}, or nothing lints it",
            .{ path, lint_path },
        );
    }
}
