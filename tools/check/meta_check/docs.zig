//! The documentation checks.
//!
//! What keeps the doc corpus honest and readable as a surface: markdown and
//! site link resolution, the README quick-start snippet parity, dangling
//! rustdoc-style references, Mermaid block hygiene, planning-doc role
//! declarations, the doc-drift living-state registry, the human doc-voice
//! regressions, and the site SVG ASCII guard. Wired by the meta-check driver
//! (`tools/check/meta_check.zig`).

const std = @import("std");
const bans = @import("bans.zig");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

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
        "bindings/README.md",
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

            const resolved = (try resolveMarkdownTarget(gpa, path, raw_target)) orelse continue;
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

/// The site content pages are `.smd` (Zine), whose intra-site links use
/// `$link.page('id')` and asset references use `$image.siteAsset('name')` rather
/// than Markdown `](path)`. Zine resolves them when `zig build site` runs, but
/// that is a sibling step; this gate holds the same references in the hermetic
/// `check`. A `$link.page('id')` resolves to `site/content/id.smd` or
/// `site/content/id/index.smd`; a `$image.siteAsset('name')` resolves to
/// `site/assets/name`. (Absolute `https://` links carry their own Markdown
/// `](url)` form and are not this gate's concern.)
pub fn checkSiteContentLinks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "site/content", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "site/content: failed to open for site link check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".smd")) continue;
        const path = try std.fmt.allocPrint(gpa, "site/content/{s}", .{entry.path});
        defer gpa.free(path);
        try checkSiteContentLinksInFile(io, gpa, root, violations, path);
    }
}

fn checkSiteContentLinksInFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for site link check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var rest = contents;
    while (std.mem.indexOf(u8, rest, "$link.page('")) |start| {
        const after = rest[start + "$link.page('".len ..];
        const end = std.mem.indexOfScalar(u8, after, '\'') orelse break;
        const id = after[0..end];
        rest = after[end + 1 ..];
        if (id.len == 0) continue;

        const as_page = try std.fmt.allocPrint(gpa, "site/content/{s}.smd", .{id});
        defer gpa.free(as_page);
        const as_index = try std.fmt.allocPrint(gpa, "site/content/{s}/index.smd", .{id});
        defer gpa.free(as_index);
        if (!fileExists(io, root, as_page) and !fileExists(io, root, as_index)) {
            try appendViolation(gpa, violations, "{s}: $link.page('{s}') resolves to neither `{s}` nor `{s}`", .{ path, id, as_page, as_index });
        }
    }

    rest = contents;
    while (std.mem.indexOf(u8, rest, "$image.siteAsset('")) |start| {
        const after = rest[start + "$image.siteAsset('".len ..];
        const end = std.mem.indexOfScalar(u8, after, '\'') orelse break;
        const name = after[0..end];
        rest = after[end + 1 ..];
        if (name.len == 0) continue;

        const asset = try std.fmt.allocPrint(gpa, "site/assets/{s}", .{name});
        defer gpa.free(asset);
        if (!fileExists(io, root, asset)) {
            try appendViolation(gpa, violations, "{s}: $image.siteAsset('{s}') resolves to missing `{s}`", .{ path, name, asset });
        }
    }
}

/// The README and the start page both quote the tcp quick-start snippet and
/// claim `examples/zig/readme_quick_start.zig` carries it verbatim. This makes
/// the claim mechanical: each doc's fenced block must equal the example's
/// import pair plus the dedented `client` fn body, line for line.
pub fn checkQuickStartSnippet(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const example_path = "examples/zig/readme_quick_start.zig";
    const example = root.readFileAlloc(io, example_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ example_path, @errorName(err) });
        return;
    };
    defer gpa.free(example);

    var expected: std.ArrayList([]const u8) = .empty;
    defer expected.deinit(gpa);
    const import_lines = [_][]const u8{
        "const std = @import(\"std\");",
        "const pancake = @import(\"pancake\");",
    };
    for (import_lines) |import_line| {
        if (std.mem.indexOf(u8, example, import_line) == null) {
            try appendViolation(gpa, violations, "{s}: missing quick-start import `{s}`", .{ example_path, import_line });
            return;
        }
        try expected.append(gpa, import_line);
    }
    try expected.append(gpa, "");

    var in_body = false;
    var found_client = false;
    var lines = std.mem.splitScalar(u8, example, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (!in_body) {
            if (std.mem.startsWith(u8, line, "fn client(")) {
                in_body = true;
                found_client = true;
            }
            continue;
        }
        if (std.mem.eql(u8, line, "}")) {
            in_body = false;
            break;
        }
        if (line.len == 0) {
            try expected.append(gpa, line);
            continue;
        }
        if (!std.mem.startsWith(u8, line, "    ")) {
            try appendViolation(gpa, violations, "{s}: `fn client` body line not indented one level: `{s}`", .{ example_path, line });
            return;
        }
        try expected.append(gpa, line[4..]);
    }
    if (!found_client or in_body) {
        try appendViolation(gpa, violations, "{s}: could not extract the `fn client` body for the quick-start check", .{example_path});
        return;
    }

    try compareQuickStartDoc(io, gpa, root, violations, "README.md", expected.items, false);
    try compareQuickStartDoc(io, gpa, root, violations, "site/content/start.smd", expected.items, true);
}

/// Find the doc's tcp quick-start fence (the one ```zig block carrying the
/// tcp marker comment) and hold it identical to the expected lines.
fn compareQuickStartDoc(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    expected: []const []const u8,
    blockquoted: bool,
) !void {
    const marker = "// tcp: the peer is a place";
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the quick-start check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var fence: std.ArrayList([]const u8) = .empty;
    defer fence.deinit(gpa);

    var capturing = false;
    var found = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, " \t\r");
        if (blockquoted) {
            if (std.mem.startsWith(u8, line, "> ")) {
                line = line[2..];
            } else if (std.mem.eql(u8, line, ">")) {
                line = "";
            }
        }
        if (!capturing) {
            if (std.mem.eql(u8, line, "```zig")) {
                capturing = true;
                fence.clearRetainingCapacity();
            }
            continue;
        }
        if (std.mem.eql(u8, line, "```")) {
            capturing = false;
            var has_marker = false;
            for (fence.items) |l| {
                if (std.mem.indexOf(u8, l, marker) != null) has_marker = true;
            }
            if (has_marker) {
                found = true;
                break;
            }
            continue;
        }
        try fence.append(gpa, line);
    }
    if (!found) {
        try appendViolation(gpa, violations, "{s}: no ```zig fence carries the tcp quick-start marker `{s}`", .{ path, marker });
        return;
    }
    if (fence.items.len != expected.len) {
        try appendViolation(gpa, violations, "{s}: tcp quick-start snippet is {d} lines but examples/zig/readme_quick_start.zig carries {d}; the two must match line for line", .{ path, fence.items.len, expected.len });
        return;
    }
    for (fence.items, expected, 0..) |got, want, i| {
        if (!std.mem.eql(u8, got, want)) {
            try appendViolation(gpa, violations, "{s}: tcp quick-start drifts from examples/zig/readme_quick_start.zig at snippet line {d}: `{s}` vs `{s}`", .{ path, i + 1, got, want });
            return;
        }
    }
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
    const markdown_files = [_][]const u8{ "AGENTS.md", "README.md", "CONTRIBUTING.md", "bindings/README.md", "bindings/ts/README.md", "bindings/python/README.md", "bindings/racket/README.md" };
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

const MermaidKind = enum { flowchart, sequence, state };

pub fn checkMermaidBlocks(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var docs = root.openDir(io, "docs", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "docs: failed to open for Mermaid check with {s}", .{@errorName(err)});
        return;
    };
    defer docs.close(io);

    var walker = try docs.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".md")) continue;

        const path = try std.fmt.allocPrint(gpa, "docs/{s}", .{entry.path});
        defer gpa.free(path);
        try checkMermaidBlocksInFile(io, gpa, root, violations, path);
    }
}

fn checkMermaidBlocksInFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for Mermaid check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var line_no: usize = 1;
    var block_start: usize = 0;
    var in_mermaid = false;
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(gpa);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!in_mermaid) {
            if (std.mem.startsWith(u8, trimmed, "```mermaid")) {
                in_mermaid = true;
                block_start = line_no;
                block.clearRetainingCapacity();
            }
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "```")) {
            if ((try mermaidBlockKind(block.items)) == null) {
                try appendViolation(gpa, violations, "{s}:{d}: Mermaid block must start with flowchart, sequenceDiagram, or stateDiagram-v2", .{ path, block_start });
            }
            in_mermaid = false;
            continue;
        }

        try block.appendSlice(gpa, line);
        try block.append(gpa, '\n');
    }

    if (in_mermaid) {
        try appendViolation(gpa, violations, "{s}:{d}: Mermaid block is not closed", .{ path, block_start });
    }
}

fn mermaidBlockKind(block: []const u8) !?MermaidKind {
    var lines = std.mem.splitScalar(u8, block, '\n');
    while (lines.next()) |line| {
        const first = std.mem.trim(u8, line, " \t\r");
        if (first.len == 0) continue;
        if (std.mem.startsWith(u8, first, "flowchart ")) {
            const direction = std.mem.trim(u8, first["flowchart ".len..], " \t\r");
            inline for (&.{ "TB", "TD", "BT", "RL", "LR" }) |allowed| {
                if (std.mem.eql(u8, direction, allowed)) return .flowchart;
            }
            return null;
        }
        if (std.mem.eql(u8, first, "sequenceDiagram")) return .sequence;
        if (std.mem.eql(u8, first, "stateDiagram-v2")) return .state;
        return null;
    }
    return null;
}

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

        if (std.mem.indexOf(u8, contents, "Status: active plan") == null and
            std.mem.indexOf(u8, contents, "Status: historical") == null and
            std.mem.indexOf(u8, contents, "Status: living-state") == null)
        {
            try appendViolation(gpa, violations, "docs/planning/{s}: must declare `Status: active plan`, `Status: historical ...`, or `Status: living-state ...`", .{entry.path});
        }
    }
}

/// The doc-drift living-state registry is itself a living-state surface, so it
/// is held honest in both directions. Forward: a registered non-glob path must
/// exist — an entry naming a deleted file is a broken promise. Reverse: every
/// top-level `docs/*.md` file, and every `docs/planning/*.md` that declares
/// `Status: living-state`, must appear in the registry — a doc that claims
/// living-state but is registered nowhere is ungoverned, which is exactly how
/// `docs/roadmap.md` once shipped outside the table.
pub fn checkLivingStateRegistry(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const rule_path = ".agents/rules/doc-drift.md";
    const rule = root.readFileAlloc(io, rule_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for living-state registry check with {s}", .{ rule_path, @errorName(err) });
        return;
    };
    defer gpa.free(rule);

    var registry = std.StringHashMap(void).init(gpa);
    defer registry.deinit();
    _ = (try collectLivingStateRegistry(rule, &registry)) orelse {
        try appendViolation(gpa, violations, "{s}: missing `## Living-State Surfaces` section", .{rule_path});
        return;
    };

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
        const needle = std.fmt.bufPrint(&needle_buf, "docs/{s}", .{entry.name}) catch continue;
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
        const contents = docs.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "Living-state surface") == null) continue;
        var covered_buf: [256]u8 = undefined;
        const covered_path = std.fmt.bufPrint(&covered_buf, "docs/{s}", .{entry.path}) catch continue;
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
        const contents = planning.readFileAlloc(io, entry.name, gpa, .limited(1 << 20)) catch continue;
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "Status: living-state") == null) continue;
        var needle_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "docs/planning/{s}", .{entry.name}) catch continue;
        if (!registry.contains(needle)) {
            try appendViolation(gpa, violations, "{s}: planning doc `{s}` declares living-state but is not in the registry", .{ rule_path, needle });
        }
    }
}

/// Collects every backtick span on the bullet lines of doc-drift's
/// "Living-State Surfaces" section, the living-state registry. Spans are
/// slices into `rule`, so they share its lifetime.
fn collectLivingStateRegistry(rule: []const u8, out: *std.StringHashMap(void)) !?void {
    const heading = "## Living-State Surfaces";
    const section_start = std.mem.indexOf(u8, rule, heading) orelse return null;
    const after_heading = rule[section_start + heading.len ..];
    const section_end = std.mem.indexOf(u8, after_heading, "\n## ") orelse after_heading.len;
    const section = after_heading[0..section_end];

    var lines = std.mem.splitScalar(u8, section, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "- ")) continue;
        var rest = trimmed;
        while (std.mem.indexOfScalar(u8, rest, '`')) |open| {
            const after_open = rest[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, after_open, '`') orelse break;
            try out.put(after_open[0..close], {});
            rest = after_open[close + 1 ..];
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

/// The human-doc-voice phrase and `.agents/` link bans live in
/// `meta_check/bans.zig` (`human_doc_voice`), driven by
/// `bans.human_doc_voice_scopes`. This walks those same scopes and holds the
/// one doc-voice ban that needs line and fence structure: the
/// connective-arrow check.
pub fn checkHumanDocVoice(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (bans.human_doc_voice_scopes) |scope| {
        var files: std.ArrayList([]const u8) = .empty;
        defer files.deinit(arena);
        // An unopenable tree already violates through the ban rows; do not
        // report it a second time here.
        bans.collectFiles(io, arena, root, scope.where, &files) catch continue;
        for (files.items) |path| {
            // A read failure is either an optional file or already reported
            // by the ban rows; the arrow check stays silent on it.
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch continue;
            try banConnectiveArrowOutsideFences(gpa, violations, path, contents);
        }
    }
}

/// Arrow connective tissue in running prose (`miss→break`, `N→1`) is a doc-voice
/// tell. Fenced code and ASCII `->` diagrams may keep arrows; Unicode `→`/`⇒`
/// stay inside fences on human first-read paths.
fn banConnectiveArrowOutsideFences(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
) !void {
    var in_fence = false;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= contents.len) : (i += 1) {
        const at_end = i == contents.len;
        const at_nl = !at_end and contents[i] == '\n';
        if (!at_end and !at_nl) continue;
        const line = contents[line_start..i];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
        } else if (!in_fence) {
            if (std.mem.indexOf(u8, line, "→") != null or std.mem.indexOf(u8, line, "⇒") != null) {
                try appendViolation(gpa, violations, "{s}: connective arrow in prose — write a verb (`becomes`, `then`, `to`) instead of `→`/`⇒` (doc-voice)", .{path});
                return;
            }
        }
        line_start = i + 1;
    }
}

/// Owned site SVGs must be ASCII-only. A non-ASCII byte in one of these files is
/// almost always a literal typographic glyph — an em-dash, a middot — that
/// should have been a numeric entity (`&#8212;`, `&#183;`); saved raw it
/// corrupts the XML and the diagram silently stops rendering, which bit this
/// project more than once. Enforcing ASCII (entities for any non-ASCII glyph)
/// makes that failure mode unrepresentable. Only `.svg` is checked: PNGs and
/// other binaries under `site/assets` are not text we own.
pub fn checkSiteSvgAscii(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const dir_path = "site/assets";
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for SVG ASCII check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".svg")) continue;

        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
        defer gpa.free(path);

        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for SVG ASCII check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        var line_no: usize = 1;
        var col: usize = 1;
        for (contents) |byte| {
            if (byte == '\n') {
                line_no += 1;
                col = 1;
                continue;
            }
            if (byte > 0x7f) {
                try appendViolation(gpa, violations, "{s}:{d}:{d}: non-ASCII byte 0x{x:0>2} in SVG; use a numeric entity (e.g. &#8212; em-dash, &#183; middot) so the XML stays valid", .{ path, line_no, col, byte });
                break;
            }
            col += 1;
        }
    }
}

fn fileExists(io: std.Io, root: std.Io.Dir, path: []const u8) bool {
    root.access(io, path, .{}) catch return false;
    return true;
}

fn resolveMarkdownTarget(gpa: std.mem.Allocator, source_path: []const u8, raw_target: []const u8) !?[]u8 {
    var target = std.mem.trim(u8, raw_target, " \t\r\n");
    if (target.len == 0) return null;
    if (target[0] == '<' and target[target.len - 1] == '>') target = target[1 .. target.len - 1];
    if (target.len == 0 or target[0] == '#') return null;
    if (std.mem.indexOf(u8, target, "://") != null) return null;
    inline for (&.{ "mailto:", "tel:", "data:" }) |scheme| {
        if (std.mem.startsWith(u8, target, scheme)) return null;
    }
    if (std.mem.startsWith(u8, target, "/")) return null;

    const path_end = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    const target_path = target[0..path_end];
    if (target_path.len == 0) return null;

    const source_dir = std.fs.path.dirname(source_path) orelse ".";
    const joined = try std.fs.path.join(gpa, &.{ source_dir, target_path });
    defer gpa.free(joined);
    return try normalizeRelativePath(gpa, joined);
}

fn normalizeRelativePath(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len != 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                parts.items.len -= 1;
            } else {
                try parts.append(gpa, part);
            }
            continue;
        }
        try parts.append(gpa, part);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (parts.items, 0..) |part, i| {
        if (i != 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, part);
    }
    if (out.items.len == 0) try out.append(gpa, '.');
    return out.toOwnedSlice(gpa);
}

test "resolveMarkdownTarget normalizes local relative links" {
    const allocator = std.testing.allocator;

    const resolved = (try resolveMarkdownTarget(allocator, ".agents/rules/cli.md", "../../.devcontainer/pins.sh#versions")).?;
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(".devcontainer/pins.sh", resolved);

    try std.testing.expect(try resolveMarkdownTarget(allocator, "AGENTS.md", "https://example.invalid/docs") == null);
    try std.testing.expect(try resolveMarkdownTarget(allocator, "AGENTS.md", "#first-principles") == null);
}

test "collectLivingStateRegistry reads bullet spans only, prose spans never" {
    const gpa = std.testing.allocator;
    var registry = std.StringHashMap(void).init(gpa);
    defer registry.deinit();

    const rule =
        "## Living-State Surfaces\n\n" ++
        "- `README.md`\n" ++
        "- `.cursor/README.md`, `.cursor/*.json`\n" ++
        "- living-state when they are a first-read contract;\n\n" ++
        "`zig build meta-check` holds this registry honest.\n\n" ++
        "## Discipline\n\n" ++
        "- `not-in-the-registry.md`\n";
    _ = (try collectLivingStateRegistry(rule, &registry)).?;

    // Bullet spans inside the section are the registry.
    try std.testing.expect(registry.contains("README.md"));
    try std.testing.expect(registry.contains(".cursor/README.md"));
    try std.testing.expect(registry.contains(".cursor/*.json"));
    // A span in prose is a sentence, not a registration; a span in another
    // section is out of scope.
    try std.testing.expect(!registry.contains("zig build meta-check"));
    try std.testing.expect(!registry.contains("not-in-the-registry.md"));

    // A rule with no registry section reports null rather than an empty set.
    var empty = std.StringHashMap(void).init(gpa);
    defer empty.deinit();
    try std.testing.expect((try collectLivingStateRegistry("# no section here\n", &empty)) == null);
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

test "mermaidBlockKind recognizes supported diagram heads" {
    try std.testing.expectEqual(MermaidKind.flowchart, (try mermaidBlockKind("flowchart TD\n    A --> B\n")).?);
    try std.testing.expectEqual(MermaidKind.sequence, (try mermaidBlockKind("\nsequenceDiagram\n    A->>B: hello\n")).?);
    try std.testing.expectEqual(MermaidKind.state, (try mermaidBlockKind("stateDiagram-v2\n    [*] --> Open\n")).?);
    try std.testing.expect(try mermaidBlockKind("notMermaid\n    A\n") == null);
}
