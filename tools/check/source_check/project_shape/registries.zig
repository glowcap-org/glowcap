//! Registered inventories: the oracle corpus, the protocol cheatsheet's
//! wire tokens, generated-state ignores, and the one repository URL.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const sectionBody = util.sectionBody;
const collectBulletSpans = util.collectBulletSpans;

/// The Syrup byte corpus is the oracle the codec is checked against, and
/// `test/oracle/protocol_oracle.zig` is its registry. A `.bin` dropped into
/// `test/oracle/corpus/` without a `fixture("…")` row is embedded
/// nowhere and pressures nothing, silently. Forward: every registered name
/// has its file on disk (a clearer failure than the `@embedFile` compile
/// error). Reverse: every `.bin` on disk has a registry row.
pub fn checkOracleCorpusRegistry(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const registry_path = "test/oracle/protocol_oracle.zig";
    const corpus_path = "test/oracle/corpus";

    const registry_src = root.readFileAlloc(io, registry_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for fixture-registry check with {s}", .{ registry_path, @errorName(err) });
        return;
    };
    defer gpa.free(registry_src);

    // Registered names: every `fixture("<name>")` call in the registry array.
    var registered = std.StringHashMap(void).init(gpa);
    defer registered.deinit();
    var rest = registry_src;
    while (std.mem.indexOf(u8, rest, "fixture(\"")) |start| {
        const after = rest[start + "fixture(\"".len ..];
        const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
        try registered.put(after[0..end], {});
        rest = after[end..];
    }

    var corpus = root.openDir(io, corpus_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for fixture-registry check with {s}", .{ corpus_path, @errorName(err) });
        return;
    };
    defer corpus.close(io);

    // Reverse: every fixture on disk is registered.
    var on_disk = std.StringHashMap(void).init(gpa);
    defer on_disk.deinit();
    var names_arena = std.heap.ArenaAllocator.init(gpa);
    defer names_arena.deinit();
    var it = corpus.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".bin")) continue;
        try on_disk.put(try names_arena.allocator().dupe(u8, entry.name), {});
        if (!registered.contains(entry.name)) {
            try appendViolation(gpa, violations, "{s}/{s}: fixture is not registered in {s}; it is embedded nowhere and pressures nothing", .{ corpus_path, entry.name, registry_path });
        }
    }

    // Forward: every registered name resolves to a fixture on disk.
    var names = registered.keyIterator();
    while (names.next()) |name| {
        if (!on_disk.contains(name.*)) {
            try appendViolation(gpa, violations, "{s}: registers fixture `{s}` but {s}/{s} does not exist", .{ registry_path, name.*, corpus_path, name.* });
        }
    }
}

/// The site's protocol cheatsheet (`site/content/protocol.smd`) is a living-state
/// surface: it names every wire label pancake speaks — the `op:` messages, the
/// `desc:` reference descriptors, and the `ocapn-` locator records that address a
/// peer. The Syrup codec is the authority for that vocabulary — OCapN settles the
/// wire as Syrup, so every such record label appears there as a string literal.
/// This check pins the page to the codec both ways: a label documented on the page
/// that the codec does not speak is a stale or invented claim, and a label the
/// codec speaks that the page omits is an undocumented part of the surface. Either
/// fails the gate, so the cheatsheet cannot drift from the protocol it describes.
pub fn checkProtocolCheatsheet(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const page_path = "site/content/protocol.smd";
    const codec_dir_path = "src/ocapn/codec/syrup";

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Authority: every quoted `op:`/`desc:` literal the Syrup codec reads or writes.
    var known = std.StringHashMap(void).init(gpa);
    defer known.deinit();

    var codec_dir = root.openDir(io, codec_dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for protocol-cheatsheet check with {s}", .{ codec_dir_path, @errorName(err) });
        return;
    };
    defer codec_dir.close(io);

    var walker = try codec_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const src = codec_dir.readFileAlloc(io, entry.path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}/{s}: failed to read for protocol-cheatsheet check with {s}", .{ codec_dir_path, entry.path, @errorName(err) });
            continue;
        };
        defer gpa.free(src);
        try collectWireTokens(arena, &known, src, true);
    }

    if (known.count() == 0) {
        try appendViolation(gpa, violations, "{s}: found no wire tokens; protocol-cheatsheet check cannot anchor to the codec", .{codec_dir_path});
        return;
    }

    // The page must present exactly that set: no invented token, none missing.
    const page = root.readFileAlloc(io, page_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for protocol-cheatsheet check with {s}", .{ page_path, @errorName(err) });
        return;
    };
    defer gpa.free(page);

    var on_page = std.StringHashMap(void).init(gpa);
    defer on_page.deinit();
    try collectWireTokens(arena, &on_page, page, false);

    var page_it = on_page.keyIterator();
    while (page_it.next()) |tok| {
        if (!known.contains(tok.*)) {
            try appendViolation(gpa, violations, "{s}: documents wire token `{s}` that the Syrup codec ({s}) does not speak", .{ page_path, tok.*, codec_dir_path });
        }
    }
    var known_it = known.keyIterator();
    while (known_it.next()) |tok| {
        if (!on_page.contains(tok.*)) {
            try appendViolation(gpa, violations, "{s}: Syrup codec speaks `{s}` but the cheatsheet does not list it", .{ page_path, tok.* });
        }
    }
}

/// Collect `op:<body>` / `desc:<body>` / `ocapn-<body>` tokens from `text` into
/// `out` (deduped, arena-owned). When `quoted_only` is set, the token must be a
/// string literal — wrapped in double quotes — so codec source counts only real
/// wire labels, not tokens mentioned in comments; the cheatsheet carries its
/// tokens in Markdown backticks, so it scans unquoted. The `ocapn-` prefix matches
/// the location records (`ocapn-peer`, `ocapn-sturdyref`) and never the `ocapn://`
/// URI scheme, whose `:` is not a wire-token char.
fn collectWireTokens(
    arena: std.mem.Allocator,
    out: *std.StringHashMap(void),
    text: []const u8,
    quoted_only: bool,
) !void {
    const prefixes = [_][]const u8{ "op:", "desc:", "ocapn-" };
    for (prefixes) |prefix| {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, prefix)) |pos| {
            var end = pos + prefix.len;
            while (end < text.len and isWireTokenChar(text[end])) end += 1;
            const has_body = end > pos + prefix.len;
            const quoted = pos > 0 and text[pos - 1] == '"' and end < text.len and text[end] == '"';
            if (has_body and (!quoted_only or quoted)) {
                try out.put(try arena.dupe(u8, text[pos..end]), {});
            }
            i = pos + prefix.len;
        }
    }
}

fn isWireTokenChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or c == '-';
}

/// Hold the gate sequence to the exit codes it must recognize.
///
/// `tools/run-with-timeout.py` bounds every gate, and `ci/gates.sh` branches on
/// what it returns to tell a wedged socket from an ordinary failure. The two
/// files never import each other, so nothing but this connects them.
///
/// The cli rule's Generated State list registers paths that must never be
/// committed. Each registered path must be matched by a committed ignore rule —
/// `.serena/...` entries by `.serena/.gitignore`, everything else by the root
/// `.gitignore` — so "fix .gitignore rather than manual cleanup" is enforced
/// instead of remembered. The git index is held to the same registry: a
/// registered path that `git ls-files` reports as tracked is committed
/// generated state, which an ignore rule alone cannot fix.
pub fn checkGeneratedStateIgnores(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    root_path: []const u8,
) !void {
    const rule_path = ".agents/rules/cli.md";
    const rule = root.readFileAlloc(io, rule_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for generated-state check with {s}", .{ rule_path, @errorName(err) });
        return;
    };
    defer gpa.free(rule);

    const section = sectionBody(rule, "## Generated State") orelse {
        try appendViolation(gpa, violations, "{s}: missing `## Generated State` section", .{rule_path});
        return;
    };

    const root_ignore = root.readFileAlloc(io, ".gitignore", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, ".gitignore: failed to read for generated-state check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(root_ignore);
    const serena_ignore = root.readFileAlloc(io, ".serena/.gitignore", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, ".serena/.gitignore: failed to read for generated-state check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(serena_ignore);

    var spans: std.ArrayList([]const u8) = .empty;
    defer spans.deinit(gpa);
    try collectBulletSpans(gpa, section, &spans);

    for (spans.items) |span| {
        if (std.mem.startsWith(u8, span, ".serena/")) {
            var needle_buf: [160]u8 = undefined;
            const stem = std.mem.trimEnd(u8, span[".serena/".len..], "/");
            const needle = std.fmt.bufPrint(&needle_buf, "/{s}", .{stem}) catch {
                try appendViolation(gpa, violations, ".serena span `{s}` overflows the registry needle buffer; grow it", .{stem});
                continue;
            };
            if (std.mem.indexOf(u8, serena_ignore, needle) == null) {
                try appendViolation(gpa, violations, "{s}: generated-state entry `{s}` has no matching rule in .serena/.gitignore", .{ rule_path, span });
            }
        } else if (std.mem.indexOf(u8, root_ignore, span) == null) {
            try appendViolation(gpa, violations, "{s}: generated-state entry `{s}` has no matching rule in .gitignore", .{ rule_path, span });
        }
    }

    // The index itself: no registered generated-state path may be tracked.
    // Read-only git is sanctioned by the cli rule; one `ls-files` call covers
    // every entry. A failure to run git is a violation, not a silent skip —
    // the check either holds or says it cannot.
    const ls_files = std.process.run(gpa, io, .{
        .argv = &.{ "git", "-C", root_path, "ls-files", "-z" },
        .stdout_limit = .limited(64 << 20),
    }) catch |err| {
        try appendViolation(gpa, violations, "git ls-files: failed to run for generated-state check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(ls_files.stdout);
    defer gpa.free(ls_files.stderr);
    switch (ls_files.term) {
        .exited => |code| if (code != 0) {
            try appendViolation(gpa, violations, "git ls-files: exited with code {d} during generated-state check", .{code});
            return;
        },
        else => {
            try appendViolation(gpa, violations, "git ls-files: terminated abnormally during generated-state check", .{});
            return;
        },
    }
    for (spans.items) |span| {
        const is_dir = std.mem.endsWith(u8, span, "/");
        var tracked_it = std.mem.splitScalar(u8, ls_files.stdout, 0);
        while (tracked_it.next()) |tracked| {
            if (tracked.len == 0) continue;
            const hit = if (is_dir)
                std.mem.startsWith(u8, tracked, span)
            else
                std.mem.eql(u8, tracked, span);
            if (hit) {
                try appendViolation(gpa, violations, "{s}: generated-state entry `{s}` is tracked by git (`{s}`) — untrack it; an ignore rule alone cannot fix a committed path", .{ rule_path, span, tracked });
                break;
            }
        }
    }
}

/// The one URL that names this repository. Everything that links to pancake —
/// the fetch line, the issue tracker, a deep link into a source file, an OCI
/// image label — starts with this.
///
/// It is declared once because it is one fact written across dozens of files,
/// and because the project has already decided it may move again: pancake is on
/// GitHub deliberately (see `PROVENANCE.md`), and whether it stays is open. A
/// move that lands in twenty-eight files and misses two leaves a reader
/// following a dead link on the page that argues the project is careful, which
/// is the worst possible place to be sloppy. Change this constant and the check
/// below names every straggler.
const repo_url = "https://github.com/jimisaacs/pancake";

/// Forge-specific deep-link syntax, which does not survive a move. Forgejo and
/// Gitea spell a path into a branch `/src/branch/main/x`; GitHub spells it
/// `/blob/main/x`. A URL carrying the wrong one resolves to nothing even when
/// the host is right, so the form is checked alongside the host rather than
/// left for a reader to discover.
const foreign_deep_link = "/src/branch/";

/// The declared host's own deep-link prefix, the form a link into a file takes.
const deep_link_prefix = "/blob/main/";

/// Where a URL stops inside prose: whitespace, Markdown and HTML punctuation.
fn isUrlTerminator(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '"', '\'', '<', '>', ')', ']', '`', '|' => true,
        else => false,
    };
}

/// Gate that every link to this repository names the declared URL, in the
/// declared form.
///
/// Two failures this catches, both of which have a public cost. A half-landed
/// forge move: the tree says the project lives in one place and a straggler
/// points somewhere it no longer is. And a hand-typed variant — a different
/// owner spelling, an old host, a deep link in another forge's path syntax —
/// which no compiler sees because it is prose.
pub fn checkRepositoryUrl(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    root_path: []const u8,
) !void {
    // Read-only git, sanctioned by the cli rule: one call enumerates exactly
    // the files a reader could ever see, and skips build output and caches
    // without a hand-maintained ignore list.
    const ls_files = std.process.run(gpa, io, .{
        .argv = &.{ "git", "-C", root_path, "ls-files", "-z" },
        .stdout_limit = .limited(64 << 20),
    }) catch |err| {
        try appendViolation(gpa, violations, "git ls-files: failed to run for repository-url check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(ls_files.stdout);
    defer gpa.free(ls_files.stderr);
    switch (ls_files.term) {
        .exited => |code| if (code != 0) {
            try appendViolation(gpa, violations, "git ls-files: exited with code {d} during repository-url check", .{code});
            return;
        },
        else => {
            try appendViolation(gpa, violations, "git ls-files: terminated abnormally during repository-url check", .{});
            return;
        },
    }

    // The repository's own name, without a host, is what a stray URL still has
    // to contain. Matching on it rather than on a host finds a link to any
    // forge, including one nobody has thought of.
    const slug = repo_url["https://".len..];
    const bare = slug[std.mem.indexOfScalar(u8, slug, '/').?..];

    var tracked_it = std.mem.splitScalar(u8, ls_files.stdout, 0);
    while (tracked_it.next()) |path| {
        if (path.len == 0) continue;
        // The upstream submodules carry their own projects' links, and this
        // file declares the constant it is checking.
        if (std.mem.startsWith(u8, path, "conformance/")) continue;
        if (std.mem.endsWith(u8, path, "project_shape.zig")) continue;

        const body = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            // Tolerant: overlay rows may name a directory symlink, and Git's
            // index still names a tracked file deliberately deleted in this
            // working tree. Neither has a body left for this content scan.
            if (err == error.IsDir or err == error.FileNotFound) continue;
            try appendViolation(gpa, violations, "{s}: cannot be read for the constant-parity check ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(body);

        var at: usize = 0;
        while (std.mem.indexOfPos(u8, body, at, bare)) |hit| {
            at = hit + bare.len;
            // Walk back to the scheme so the whole URL can be judged, not the
            // slug that every candidate shares.
            const line_start = if (std.mem.lastIndexOfScalar(u8, body[0..hit], '\n')) |nl| nl + 1 else 0;
            const scheme = std.mem.lastIndexOf(u8, body[line_start..hit], "https://") orelse continue;
            const url_start = line_start + scheme;
            if (!std.mem.startsWith(u8, body[url_start..], repo_url)) {
                const end = @min(url_start + repo_url.len + 16, body.len);
                try appendViolation(gpa, violations, "{s}: links to this repository as `{s}…`, but the declared URL is `{s}` (tools/check/source_check/project_shape.zig)", .{ path, body[url_start..end], repo_url });
                continue;
            }
            const rest = body[url_start + repo_url.len ..];
            if (std.mem.startsWith(u8, rest, foreign_deep_link)) {
                try appendViolation(gpa, violations, "{s}: deep link uses another forge's `{s}` path syntax, which resolves to nothing on the declared host", .{ path, foreign_deep_link });
                continue;
            }
            // A deep link names a file, and a rename makes it a 404 on a page
            // the public reads. The compiler never sees these, and neither
            // does the Markdown link checker, which only resolves relative
            // paths.
            if (std.mem.startsWith(u8, rest, deep_link_prefix)) {
                const tail = rest[deep_link_prefix.len..];
                var stop: usize = 0;
                while (stop < tail.len and !isUrlTerminator(tail[stop])) stop += 1;
                var target = std.mem.trimEnd(u8, tail[0..stop], ".,;:)");
                if (std.mem.indexOfScalar(u8, target, '#')) |frag| target = target[0..frag];
                if (target.len == 0) continue;
                const clean = std.mem.trimEnd(u8, target, "/");
                if (clean.len == 0) continue;
                root.access(io, clean, .{}) catch {
                    try appendViolation(gpa, violations, "{s}: deep link names `{s}`, which is not in the repository — it would 404 for every reader", .{ path, clean });
                };
            }
        }
    }
}
