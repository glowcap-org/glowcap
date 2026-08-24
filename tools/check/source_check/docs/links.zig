//! Markdown link integrity across the owned docs, the dangling
//! reference-style links a renderer would silently swallow, and the
//! repository's own GitHub blob links resolving to real tree paths.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const paths = @import("paths.zig");

pub fn checkMarkdownLinks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // The first-read living-state surfaces that carry relative links: the root
    // contracts, the bindings READMEs (every language), and the examples index.
    // `site/content` is `.smd`, whose link syntax this `.md` walker does not
    // parse; `checkSiteContentLinks` gates those references instead.
    const files = [_][]const u8{
        "AGENTS.md",
        "README.md",
        "CONTRIBUTING.md",
        // The two first-read pages a reviewer opens before any code. They are
        // registered living-state; they should be the best-gated, not the least.
        "PROVENANCE.md",
        "SECURITY.md",
        "bindings/README.md",
        "bindings/DEVELOPING.md",
        "bindings/PACKAGING.md",
        "bindings/rust/README.md",
        "bindings/ts/README.md",
        "bindings/python/README.md",
        "bindings/racket/README.md",
        "examples/README.md",
    };
    for (files) |path| {
        try checkMarkdownLinksInFile(io, gpa, root, violations, path);
    }
    try checkMarkdownLinksUnder(io, gpa, root, violations, ".agents");
    try checkMarkdownLinksUnder(io, gpa, root, violations, ".devcontainer");
    try checkMarkdownLinksUnder(io, gpa, root, violations, "docs");
}

fn checkMarkdownLinksUnder(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    dir_path: []const u8,
) !void {
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for Markdown link check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
        defer gpa.free(path);
        try checkMarkdownLinksInFile(io, gpa, root, violations, path);
    }
}

fn checkMarkdownLinksInFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for Markdown link check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var line_no: usize = 1;
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;

        var rest = line;
        while (std.mem.indexOf(u8, rest, "](")) |start| {
            const after = rest[start + "](".len ..];
            const end = std.mem.indexOfScalar(u8, after, ')') orelse break;
            const raw_target = after[0..end];
            rest = after[end + 1 ..];

            const resolved = (try paths.resolveMarkdownTarget(gpa, path, raw_target)) orelse continue;
            defer gpa.free(resolved);
            root.access(io, resolved, .{}) catch |err| {
                try appendViolation(gpa, violations, "{s}:{d}: Markdown link `{s}` resolves to missing `{s}` ({s})", .{
                    path,
                    line_no,
                    raw_target,
                    resolved,
                    @errorName(err),
                });
            };
        }
    }
}

/// A `github.com/jimisaacs/pancake/blob/main/<path>` link is a claim the path
/// exists in this tree, and it is the one external-link class a network-free
/// check can hold: a rename that leaves the link behind 404s every page that
/// carries it, and no compiler or renderer notices. Walk the owned prose
/// surfaces (root contracts, docs, site content, apps, bindings, bench,
/// examples) and resolve each blob or tree link against the repository.
pub fn checkRepoBlobLinks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const files = [_][]const u8{
        "AGENTS.md",
        "README.md",
        "CONTRIBUTING.md",
        "PROVENANCE.md",
        "SECURITY.md",
    };
    for (files) |path| {
        try checkRepoBlobLinksInFile(io, gpa, root, violations, path);
    }
    const trees = [_][]const u8{ "docs", "site/content", "apps", "bindings", "bench", "examples" };
    for (trees) |dir_path| {
        try checkRepoBlobLinksUnder(io, gpa, root, violations, dir_path);
    }
}

fn checkRepoBlobLinksUnder(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    dir_path: []const u8,
) !void {
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for blob link check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const is_prose = std.mem.endsWith(u8, entry.path, ".md") or
            std.mem.endsWith(u8, entry.path, ".smd");
        if (!is_prose) continue;
        // Vendored trees and dependency caches are not ours to fix.
        if (std.mem.indexOf(u8, entry.path, "node_modules/") != null) continue;
        if (std.mem.indexOf(u8, entry.path, "upstream/") != null) continue;

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
        defer gpa.free(path);
        try checkRepoBlobLinksInFile(io, gpa, root, violations, path);
    }
}

const blob_link_prefix = "github.com/jimisaacs/pancake/";

fn checkRepoBlobLinksInFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for blob link check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, contents, i, blob_link_prefix)) |at| {
        const after = contents[at + blob_link_prefix.len ..];
        i = at + blob_link_prefix.len;
        const ref: []const u8 = for ([_][]const u8{ "blob/main/", "tree/main/" }) |candidate| {
            if (std.mem.startsWith(u8, after, candidate)) break candidate;
        } else continue;
        const target = blobLinkTarget(after[ref.len..]) orelse continue;
        root.access(io, target, .{}) catch |err| {
            try appendViolation(gpa, violations, "{s}:{d}: GitHub link names missing tree path `{s}` ({s})", .{
                path,
                lineNumberAt(contents, at),
                target,
                @errorName(err),
            });
        };
    }
}

/// The linked tree path: everything to the first URL delimiter, with a
/// fragment, query, and sentence punctuation trimmed. Null when nothing
/// remains, as in a bare link to the repository root.
fn blobLinkTarget(rest: []const u8) ?[]const u8 {
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        const c = rest[end];
        if (c == ')' or c == '"' or c == '\'' or c == '`' or c == '#' or c == '?' or
            c == '<' or c == ']' or c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
    }
    var target = rest[0..end];
    while (target.len > 0) {
        const last = target[target.len - 1];
        if (last == '.' or last == ',' or last == ';' or last == ':' or last == '/') {
            target = target[0 .. target.len - 1];
        } else break;
    }
    if (target.len == 0) return null;
    return target;
}

fn lineNumberAt(contents: []const u8, at: usize) usize {
    var n: usize = 1;
    for (contents[0..@min(at, contents.len)]) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// The Markdown surfaces and Zig comment lines this repository owns must not
/// carry dangling bracketed code spans (see `danglingReferenceColumn`).
/// `bindings/rust` is deliberately exempt: rustdoc resolves the form there, so
/// in Rust doc comments it is a real link. Vendored trees under `upstream/`
/// are not ours to fix and are skipped.
pub fn checkDanglingReferenceLinks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    // `bindings/rust/README.md` is excluded: rustdoc resolves the bracketed
    // code-span form, so it is a real link there (see the doc-voice rule).
    const markdown_files = [_][]const u8{ "AGENTS.md", "README.md", "CONTRIBUTING.md", "bindings/README.md", "bindings/DEVELOPING.md", "bindings/PACKAGING.md", "bindings/ts/README.md", "bindings/python/README.md", "bindings/racket/README.md" };
    for (markdown_files) |path| {
        try checkDanglingRefsInMarkdownFile(io, gpa, root, violations, path);
    }

    const markdown_trees = [_][]const u8{ ".agents", "docs", "examples" };
    for (markdown_trees) |dir_path| {
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for dangling-reference check with {s}", .{ dir_path, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
            defer gpa.free(path);
            try checkDanglingRefsInMarkdownFile(io, gpa, root, violations, path);
        }
    }

    const zig_trees = [_][]const u8{ "src", "test", "bench", "examples", "tools", "conformance", "interop" };
    for (zig_trees) |dir_path| {
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for dangling-reference check with {s}", .{ dir_path, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            if (std.mem.indexOf(u8, entry.path, "upstream/") != null) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
            defer gpa.free(path);
            try checkDanglingRefsInZigFile(io, gpa, root, violations, path);
        }
    }
}

fn checkDanglingRefsInMarkdownFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for dangling-reference check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var line_no: usize = 1;
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        if (danglingReferenceColumn(line) != null) {
            try appendViolation(gpa, violations, "{s}:{d}: bracketed code span links nowhere, write a plain code span, or a real Markdown link with a target", .{ path, line_no });
        }
    }
}

fn checkDanglingRefsInZigFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for dangling-reference check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var line_no: usize = 1;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "//")) continue;
        if (danglingReferenceColumn(line) != null) {
            try appendViolation(gpa, violations, "{s}:{d}: bracketed code span in a comment is rustdoc link syntax that Zig docs do not resolve, write a plain code span", .{ path, line_no });
        }
    }
}

/// Returns the column of the first dangling bracketed code span on `line`, or
/// null. The shape — a square bracket opening directly onto a backtick span and
/// closing right after it, with no link target, reference definition, or
/// reference label following — is rustdoc's intra-doc link syntax, which
/// nothing in this repository resolves: GitHub renders it as literal brackets
/// and Zig doc comments render it as dead text. A backtick directly before the
/// opening bracket means the bracket is itself inside a code span (a literal
/// bracket character), not a reference, so it is skipped.
fn danglingReferenceColumn(line: []const u8) ?usize {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, line, search_from, "[`")) |start| {
        search_from = start + 1;
        if (start != 0 and line[start - 1] == '`') continue;
        const inner_start = start + 2;
        const close = std.mem.indexOfPos(u8, line, inner_start, "`]") orelse return null;
        const inner = line[inner_start..close];
        if (inner.len == 0) continue;
        if (std.mem.indexOfAny(u8, inner, "`]") != null) continue;
        const after = close + 2;
        if (after < line.len and (line[after] == '(' or line[after] == ':' or line[after] == '[')) continue;
        return start;
    }
    return null;
}

test "danglingReferenceColumn flags rustdoc-style references, never resolvable links or literal brackets" {
    // A bracketed code span with nothing after it resolves nowhere.
    try std.testing.expectEqual(@as(?usize, 4), danglingReferenceColumn("see [`Peer.step`] for the drain"));
    try std.testing.expectEqual(@as(?usize, 0), danglingReferenceColumn("[`core`] holds the shared types"));
    // A real inline link, a reference definition, and a reference label all resolve.
    try std.testing.expect(danglingReferenceColumn("see [`Peer`](../engine/mod.zig)") == null);
    try std.testing.expect(danglingReferenceColumn("[`Peer`]: ../engine/mod.zig") == null);
    try std.testing.expect(danglingReferenceColumn("see [`Peer`][engine-peer]") == null);
    // A bracket character inside a code span is a literal, not a reference.
    try std.testing.expect(danglingReferenceColumn("a byte equal to `<`, `>`, `[`, `]`, or a digit") == null);
    // An unclosed or backtick-laden candidate is not a reference shape.
    try std.testing.expect(danglingReferenceColumn("an open [`span with no close") == null);
}
