//! Runnable prose: the README quick-start against its abridged copies, the
//! mermaid blocks that must parse, example fence indentation, and relay
//! first-calls staying on `wss://`.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

/// The README quotes the compiled noise-tcp quick-start verbatim. The front page
/// abridges the Noise TCP first-call example. Start building's tabs are held by
/// gen-site-examples-check.
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
        "const glowcap = @import(\"glowcap\");",
    };
    for (import_lines) |import_line| {
        if (std.mem.indexOf(u8, example, import_line) == null) {
            try appendViolation(gpa, violations, "{s}: missing quick-start import `{s}`", .{ example_path, import_line });
            return;
        }
        try expected.append(gpa, import_line);
    }
    try expected.append(gpa, "");

    if (!try extractIndentedBody(gpa, violations, example_path, example, "fn client(", &expected)) return;

    try compareQuickStartDoc(io, gpa, root, violations, "README.md", expected.items, false);

    const noise_path = "site/examples/dial/noise-tcp.zig";
    const noise_src = root.readFileAlloc(io, noise_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ noise_path, @errorName(err) });
        return;
    };
    defer gpa.free(noise_src);
    var noise_expected: std.ArrayList([]const u8) = .empty;
    defer noise_expected.deinit(gpa);
    if (!try extractIndentedBody(gpa, violations, noise_path, noise_src, "pub fn example(", &noise_expected)) return;
    try compareAbridgedQuickStart(io, gpa, root, violations, "site/content/index.smd", noise_expected.items);
}

/// Relay first-calls speak `wss://` with platform trust. A loopback `ws://`
/// URL in this matrix is the testing path occupying a production slot.
pub fn checkRelaySnippetsUseWss(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "site/examples", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "site/examples: failed to open for relay WSS check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.indexOf(u8, entry.path, "relay") == null) continue;
        const path = try std.fmt.allocPrint(gpa, "site/examples/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for relay WSS check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        if (std.mem.indexOf(u8, contents, "wss://") == null) {
            try appendViolation(gpa, violations, "{s}: relay first-call must speak `wss://` (platform trust, not a loopback `ws://` testing URL)", .{path});
        }
        if (containsCleartextWsUrl(contents)) {
            try appendViolation(gpa, violations, "{s}: relay first-call must not use cleartext `ws://`; the lead is `wss://`", .{path});
        }
    }
}

fn containsCleartextWsUrl(contents: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, contents, i, "ws://")) |pos| {
        if (pos == 0 or contents[pos - 1] != 's') return true;
        i = pos + 5;
    }
    return false;
}

fn extractIndentedBody(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    source: []const u8,
    signature_prefix: []const u8,
    expected: *std.ArrayList([]const u8),
) !bool {
    var in_body = false;
    var found = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (!in_body) {
            if (std.mem.startsWith(u8, line, signature_prefix)) {
                in_body = true;
                found = true;
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
            try appendViolation(gpa, violations, "{s}: `{s}` body line not indented one level: `{s}`", .{ path, signature_prefix, line });
            return false;
        }
        try expected.append(gpa, line[4..]);
    }
    if (!found or in_body) {
        try appendViolation(gpa, violations, "{s}: could not extract `{s}` body for the first-call check", .{ path, signature_prefix });
        return false;
    }
    return true;
}

/// The front page abridges the Noise TCP first-call example: it drops lines the
/// teaser does not need, so it cannot be held identical the way the README and
/// its compiled client are. Every line it keeps must be a line the example
/// carries, in the example's own order. Dropping a line stays legal and
/// rewording one does not.
fn compareAbridgedQuickStart(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    expected: []const []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the abridged quick-start check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var fence: std.ArrayList([]const u8) = .empty;
    defer fence.deinit(gpa);

    var capturing = false;
    var found = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (!capturing) {
            if (std.mem.eql(u8, line, "```zig")) capturing = true;
            continue;
        }
        if (std.mem.eql(u8, line, "```")) {
            found = true;
            break;
        }
        try fence.append(gpa, line);
    }
    if (!found) {
        try appendViolation(gpa, violations, "{s}: no ```zig fence to hold against site/examples/dial/noise-tcp.zig", .{path});
        return;
    }

    var cursor: usize = 0;
    for (fence.items) |got| {
        if (got.len == 0) continue;
        var matched = false;
        while (cursor < expected.len) : (cursor += 1) {
            if (std.mem.eql(u8, got, expected[cursor])) {
                matched = true;
                cursor += 1;
                break;
            }
        }
        if (!matched) {
            try appendViolation(gpa, violations, "{s}: abridged first-call line `{s}` is not one site/examples/dial/noise-tcp.zig carries from here on; the front page may drop lines but never reword them", .{ path, got });
            return;
        }
    }
}

/// Find the doc's quick-start fence (the one ```zig block carrying the
/// sealed-path marker comment) and hold it identical to the expected lines.
fn compareQuickStartDoc(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    expected: []const []const u8,
    blockquoted: bool,
) !void {
    const marker = "// Noise_XK seals the CapTP stream and proves the dialed key.";
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
        try appendViolation(gpa, violations, "{s}: no ```zig fence carries the quick-start marker `{s}`", .{ path, marker });
        return;
    }
    if (fence.items.len != expected.len) {
        try appendViolation(gpa, violations, "{s}: quick-start snippet is {d} lines but examples/zig/readme_quick_start.zig carries {d}; the two must match line for line", .{ path, fence.items.len, expected.len });
        return;
    }
    for (fence.items, expected, 0..) |got, want, i| {
        if (!std.mem.eql(u8, got, want)) {
            try appendViolation(gpa, violations, "{s}: quick-start drifts from examples/zig/readme_quick_start.zig at snippet line {d}: `{s}` vs `{s}`", .{ path, i + 1, got, want });
            return;
        }
    }
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

        if (std.mem.indexOfScalar(u8, line, ';') != null) {
            try appendViolation(gpa, violations, "{s}:{d}: Mermaid reads ';' as a statement separator even inside note and label text, so the rest of the line becomes a broken statement at render time. Reword without the semicolon.", .{ path, line_no });
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

/// A displayed code example is indented the way the project's formatter for
/// that language indents, so a reader who copies it gets the house style:
/// TypeScript and JavaScript use tabs (deno fmt, `useTabs`), and the
/// space-governed languages (zig fmt, ruff, shell) never start a line with a
/// tab. One tab-indented example beside space-indented siblings reads as an
/// accident, and no formatter runs inside a Markdown fence to catch it.
pub fn checkExampleFenceIndent(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const tab_langs = [_][]const u8{ "ts", "typescript", "js", "javascript" };
    const space_langs = [_][]const u8{ "zig", "python", "py", "sh", "bash", "json", "c", "rust", "rkt", "racket" };
    const dirs = [_][]const u8{ "site/content", "docs", "bindings", "examples", "apps", "tools", "bench", "interop", "conformance", "transports", ".devcontainer" };
    const top_files = [_][]const u8{ "README.md", "CONTRIBUTING.md", "SECURITY.md", "PROVENANCE.md", "AGENTS.md" };
    // `apps/ocapnviz/` is the maintainer's own viewer, carried over from the
    // pre-Zig glowcap tree and possibly headed for its own repository; its
    // docs keep their source style until that decision lands.
    const skip_fragments = [_][]const u8{ "target/", "node_modules/", "upstream/", "zig-out/", ".zig-cache/", "apps/ocapnviz/" };

    for (top_files) |path| {
        try checkFenceIndentFile(io, gpa, root, path, &tab_langs, &space_langs, violations);
    }
    for (dirs) |dir_path| {
        var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for fence-indent check with {s}", .{ dir_path, @errorName(err) });
            continue;
        };
        defer dir.close(io);

        var walker = try dir.walkSelectively(gpa);
        defer walker.deinit();
        walk: while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                try util.enterSourceDirectory(io, gpa, &walker, dir_path, entry);
                continue;
            }
            if (entry.kind != .file) continue;
            const is_doc = std.mem.endsWith(u8, entry.path, ".md") or std.mem.endsWith(u8, entry.path, ".smd");
            if (!is_doc) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
            defer gpa.free(path);
            // Match on the repo-relative path: a walked entry's own path is
            // relative to the directory being walked, which would never carry
            // a fragment that names the top-level directory.
            for (skip_fragments) |frag| {
                if (std.mem.indexOf(u8, path, frag) != null) {
                    continue :walk;
                }
            }
            try checkFenceIndentFile(io, gpa, root, path, &tab_langs, &space_langs, violations);
        }
    }
}

fn checkFenceIndentFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    tab_langs: []const []const u8,
    space_langs: []const []const u8,
    violations: *std.ArrayList([]const u8),
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for fence-indent check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 0;
    var fence_lang: ?[]const u8 = null;
    var fence_flagged = false;
    while (lines.next()) |line| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (fence_lang == null) {
                const info = std.mem.trim(u8, trimmed[3..], " \t\r");
                const end = std.mem.indexOfAny(u8, info, " \t") orelse info.len;
                fence_lang = info[0..end];
                fence_flagged = false;
            } else {
                fence_lang = null;
            }
            continue;
        }
        const lang = fence_lang orelse continue;
        if (fence_flagged or line.len == 0) continue;
        const wants_tabs = for (tab_langs) |l| {
            if (std.mem.eql(u8, lang, l)) break true;
        } else false;
        const wants_spaces = for (space_langs) |l| {
            if (std.mem.eql(u8, lang, l)) break true;
        } else false;
        if (wants_tabs and line[0] == ' ') {
            try appendViolation(gpa, violations, "{s}:{d}: space-indented line in a `{s}` example; this project's TypeScript/JavaScript style is tabs (deno fmt useTabs)", .{ path, line_no, lang });
            fence_flagged = true;
        } else if (wants_spaces and line[0] == '\t') {
            try appendViolation(gpa, violations, "{s}:{d}: tab-indented line in a `{s}` example; that language's formatter here uses spaces", .{ path, line_no, lang });
            fence_flagged = true;
        }
    }
}

test "mermaidBlockKind recognizes supported diagram heads" {
    try std.testing.expectEqual(MermaidKind.flowchart, (try mermaidBlockKind("flowchart TD\n    A --> B\n")).?);
    try std.testing.expectEqual(MermaidKind.sequence, (try mermaidBlockKind("\nsequenceDiagram\n    A->>B: hello\n")).?);
    try std.testing.expectEqual(MermaidKind.state, (try mermaidBlockKind("stateDiagram-v2\n    [*] --> Open\n")).?);
    try std.testing.expect(try mermaidBlockKind("notMermaid\n    A\n") == null);
}

test "containsCleartextWsUrl treats wss as sealed and ws as cleartext" {
    try std.testing.expect(!containsCleartextWsUrl("const relayUrl = \"wss://relay.example/relay\";"));
    try std.testing.expect(containsCleartextWsUrl("const relayUrl = \"ws://192.0.2.10/relay\";"));
    try std.testing.expect(containsCleartextWsUrl("ws://127.0.0.1:8000/relay"));
}
