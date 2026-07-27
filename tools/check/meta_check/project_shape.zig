//! The project-shape checks.
//!
//! Repository structure held to the declared shape: layer ownership and
//! grouping directories, test placement and suite wiring, the oracle corpus
//! registry, the protocol cheat-sheet wire tokens, generated-state ignores,
//! the example index and build wiring, documented-build-step parity in both
//! directions, the archive tables, and the map-removal discard rule. Wired by
//! the meta-check driver (`tools/check/meta_check.zig`).

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;
const sectionBody = util.sectionBody;
const collectBulletSpans = util.collectBulletSpans;

/// Command-citing surfaces that live outside the walked `docs/**` and
/// `.agents/**` trees. Everything inside those trees is discovered by walking,
/// so a new doc or rule is gated the moment it lands, no hand-maintained list
/// to fall out of sync (which is exactly how `docs/vision.md` and
/// `docs/ladder.md` once slipped past the command check).
const fixed_command_docs = [_][]const u8{
    "README.md",
    "CONTRIBUTING.md",
    "AGENTS.md",
    "bindings/README.md",
    ".cursor/README.md",
    ".claude/README.md",
    ".serena/project.yml",
};

/// Command-invoking CI surfaces. These are workflow YAML and shell, not
/// Markdown, so the whole file is command context, and one invocation may
/// name several steps (`zig build fmt-check arch-check …`). Scanned forward
/// only: a `zig build <step>` here must name a real step and a `bash <script>`
/// must resolve, but a CI invocation is not discoverability documentation, so
/// it never satisfies the reverse every-step-is-documented direction.
const ci_command_dirs = [_][]const u8{".github/workflows"};
const ci_command_files = [_][]const u8{"ci/gates.sh"};

/// A map removal that discards its presence bool — `_ = map.remove(k)` and the
/// `.fetchRemove(` / `.swapRemove(` shapes — throws away a checkable fact: a
/// logic bug that removed a key the code believed present passes unnoticed. In
/// `src/`, every such discard must either assert the removal
/// (`std.debug.assert(map.remove(k))`, which still runs the remove in release,
/// only adding the check in safe builds) when presence is an established
/// invariant, or carry an inline `// idempotent:` / `// tolerant:` justification
/// when presence is genuinely not guaranteed. This holds the distinction
/// mechanically for every future removal (see the allocator-discipline section
/// of `.agents/rules/memory.md`). `orderedRemove` returns the element, not a
/// presence bool, so it is deliberately not flagged.
pub fn checkRemoveDiscards(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "src", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src: failed to open for remove-discard check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        try checkRemoveDiscardsInFile(io, gpa, root, violations, path);
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

/// The architecture rule's Layer Ownership list is the map a cold agent uses to
/// place code, so it is held to `src/` in both directions. Forward: every
/// bulleted layer resolves to a real `src/` directory. Reverse: every top-level
/// directory under `src/`, and every immediate child of a grouping directory
/// (`src/ocapn`, `src/c_abi` — see `checkGroupingChildren`), has a bullet — a
/// layer that ships unnamed is unplaceable, which is how `src/oracle` once
/// went missing from the map.
pub fn checkLayerOwnership(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const rule_path = ".agents/rules/architecture.md";
    const rule = root.readFileAlloc(io, rule_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for layer-ownership check with {s}", .{ rule_path, @errorName(err) });
        return;
    };
    defer gpa.free(rule);

    const section = sectionBody(rule, "## Layer Ownership") orelse {
        try appendViolation(gpa, violations, "{s}: missing `## Layer Ownership` section", .{rule_path});
        return;
    };

    var spans: std.ArrayList([]const u8) = .empty;
    defer spans.deinit(gpa);
    try collectBulletSpans(gpa, section, &spans);

    var named = std.StringHashMap(void).init(gpa);
    defer named.deinit();
    for (spans.items) |span| {
        const name = std.mem.trimEnd(u8, span, "/");
        try named.put(name, {});
        var path_buf: [160]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "src/{s}", .{name}) catch continue;
        root.access(io, path, .{}) catch |err| {
            try appendViolation(gpa, violations, "{s}: Layer Ownership names `{s}` but `{s}` is not accessible ({s})", .{ rule_path, span, path, @errorName(err) });
        };
    }

    var src = root.openDir(io, "src", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src: failed to open for layer-ownership check with {s}", .{@errorName(err)});
        return;
    };
    defer src.close(io);
    var src_it = src.iterate();
    while (try src_it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!named.contains(entry.name)) {
            try appendViolation(gpa, violations, "{s}: `src/{s}` has no Layer Ownership bullet", .{ rule_path, entry.name });
        }
        // A grouping directory (`src/ocapn`, `src/c_abi`) holds a family of
        // layers rather than being one; hold each immediate child too.
        try checkGroupingChildren(io, gpa, root, entry.name, &named, violations, rule_path);
    }
}

/// A grouping directory under `src/` — one with no direct `.zig` file, only
/// subdirectories (`src/ocapn`, `src/c_abi`) — is a family of layers, not a
/// layer itself. Each immediate child is its own layer, so it must carry a
/// `<group>/<child>` Layer Ownership bullet; an unnamed sub-layer is
/// unplaceable, exactly how `src/oracle` once went missing from the map.
/// A directory with its own `.zig` files is a layer (its files belong to it),
/// so it is skipped here. Recursion is one level: a child that is itself a
/// grouping dir (e.g. `ocapn/codec` over `syrup`/`capnp`) keeps its sub-layers
/// in `layer_table`, not in the placement map.
fn checkGroupingChildren(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    group: []const u8,
    named: *const std.StringHashMap(void),
    violations: *std.ArrayList([]const u8),
    rule_path: []const u8,
) !void {
    var path_buf: [160]u8 = undefined;
    const group_path = std.fmt.bufPrint(&path_buf, "src/{s}", .{group}) catch return;
    var dir = root.openDir(io, group_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var subdirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (subdirs.items) |s| gpa.free(s);
        subdirs.deinit(gpa);
    }
    var has_zig = false;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            has_zig = true;
        } else if (entry.kind == .directory) {
            try subdirs.append(gpa, try gpa.dupe(u8, entry.name));
        }
    }
    if (has_zig) return;

    for (subdirs.items) |sub| {
        var needle_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "{s}/{s}", .{ group, sub }) catch continue;
        if (!named.contains(needle)) {
            try appendViolation(gpa, violations, "{s}: `src/{s}/{s}` has no Layer Ownership bullet", .{ rule_path, group, sub });
        }
    }
}

/// The tests rule's Placement list routes a new test to its directory, so it is
/// held to `test/` in both directions. Forward: every `test/...` bullet
/// resolves to a real path. Reverse: every top-level directory under `test/`
/// has a bullet, so a new suite cannot land without placement guidance.
pub fn checkTestPlacement(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const rule_path = ".agents/rules/tests.md";
    const rule = root.readFileAlloc(io, rule_path, gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for test-placement check with {s}", .{ rule_path, @errorName(err) });
        return;
    };
    defer gpa.free(rule);

    const section = sectionBody(rule, "## Placement") orelse {
        try appendViolation(gpa, violations, "{s}: missing `## Placement` section", .{rule_path});
        return;
    };

    var spans: std.ArrayList([]const u8) = .empty;
    defer spans.deinit(gpa);
    try collectBulletSpans(gpa, section, &spans);

    var named = std.StringHashMap(void).init(gpa);
    defer named.deinit();
    for (spans.items) |span| {
        if (!std.mem.startsWith(u8, span, "test/")) continue;
        try named.put(span, {});
        root.access(io, span, .{}) catch |err| {
            try appendViolation(gpa, violations, "{s}: Placement names `{s}` but it is not accessible ({s})", .{ rule_path, span, @errorName(err) });
        };
    }

    var test_dir = root.openDir(io, "test", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "test: failed to open for test-placement check with {s}", .{@errorName(err)});
        return;
    };
    defer test_dir.close(io);
    var it = test_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        var needle_buf: [160]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "test/{s}", .{entry.name}) catch continue;
        if (!named.contains(needle)) {
            try appendViolation(gpa, violations, "{s}: `test/{s}` has no Placement bullet", .{ rule_path, entry.name });
        }
    }
}

/// The test-suite roots that `zig build test` and `zig build oracle-check`
/// compile. Both are hand-maintained comptime import lists.
const test_suite_roots = [_][]const u8{ "test/all_test.zig", "test/oracle_check.zig" };

/// `zig build test` compiles the single root `test/all_test.zig`, and
/// `zig build oracle-check` compiles `test/oracle_check.zig`. A `*_test.zig`
/// file that neither root imports compiles nowhere and runs zero tests while
/// the gate stays green, the same silently-unloaded failure mode the rule
/// overlay check kills. Forward: every `test/**/*_test.zig` appears as an
/// `@import` in one of the roots. Reverse: every `*_test.zig` import in the
/// roots resolves to a real file, so a stale import line fails here with a
/// named path.
pub fn checkTestSuiteWiring(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var root_contents: [test_suite_roots.len][]const u8 = undefined;
    var loaded: usize = 0;
    defer for (root_contents[0..loaded]) |contents| gpa.free(contents);
    for (test_suite_roots, 0..) |path, i| {
        root_contents[i] = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for test-suite wiring check with {s}", .{ path, @errorName(err) });
            return;
        };
        loaded = i + 1;
    }

    // Forward: every test file under test/ is imported by a suite root.
    var test_dir = root.openDir(io, "test", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "test: failed to open for test-suite wiring check with {s}", .{@errorName(err)});
        return;
    };
    defer test_dir.close(io);
    var walker = try test_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, "_test.zig")) continue;
        // The suite roots themselves are compile roots, not imports.
        if (std.mem.eql(u8, entry.path, "all_test.zig")) continue;

        var needle_buf: [192]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "@import(\"{s}\")", .{entry.path}) catch {
            try appendViolation(gpa, violations, "test/{s}: path too long for test-suite wiring check", .{entry.path});
            continue;
        };
        var imported = false;
        for (root_contents) |contents| {
            if (std.mem.indexOf(u8, contents, needle) != null) imported = true;
        }
        if (!imported) {
            try appendViolation(gpa, violations, "test/{s}: not imported by test/all_test.zig or test/oracle_check.zig, its tests silently never run", .{entry.path});
        }
    }

    // Reverse: every `*_test.zig` import in a suite root resolves on disk.
    for (test_suite_roots, root_contents) |path, contents| {
        var rest = contents;
        while (std.mem.indexOf(u8, rest, "@import(\"")) |start| {
            const after = rest[start + "@import(\"".len ..];
            const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
            const target = after[0..end];
            rest = after[end..];
            if (!std.mem.endsWith(u8, target, "_test.zig")) continue;

            var target_buf: [192]u8 = undefined;
            const target_path = std.fmt.bufPrint(&target_buf, "test/{s}", .{target}) catch continue;
            root.access(io, target_path, .{}) catch |err| {
                try appendViolation(gpa, violations, "{s}: imports `{s}` but `{s}` is not accessible ({s})", .{ path, target, target_path, @errorName(err) });
            };
        }
    }
}

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
            const needle = std.fmt.bufPrint(&needle_buf, "/{s}", .{stem}) catch continue;
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

/// Gate that every numbered Zig example chapter (`examples/zig/NN_*.zig`) and
/// every C example source (`examples/c/*.c`) the build compiles has an index row
/// in `examples/README.md`, and every numbered chapter also appears on the site
/// examples page. A new chapter or C program can otherwise ship undiscoverable;
/// the index, the site, and the directories must agree. (The C arm is what would
/// have caught `compose_transports.c` shipping unindexed.)
pub fn checkExampleIndex(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const index = root.readFileAlloc(io, "examples/README.md", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "examples/README.md: failed to read for example-index check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(index);

    const site = root.readFileAlloc(io, "site/content/examples.smd", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "site/content/examples.smd: failed to read for example-index check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(site);

    var dir = root.openDir(io, "examples/zig", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "examples/zig: failed to open with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        // Numbered chapters only: a leading digit. Helpers like `frame_view.zig`
        // are linked from the lower-level section, not the chapter table.
        if (entry.name.len == 0 or !std.ascii.isDigit(entry.name[0])) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        var needle_buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "zig/{s}", .{entry.name}) catch continue;
        if (std.mem.indexOf(u8, index, needle) == null) {
            try appendViolation(gpa, violations, "examples/README.md: missing index row for example chapter `{s}`", .{entry.name});
        }

        var site_needle_buf: [160]u8 = undefined;
        const site_needle = std.fmt.bufPrint(&site_needle_buf, "examples/zig/{s}", .{entry.name}) catch continue;
        if (std.mem.indexOf(u8, site, site_needle) == null) {
            try appendViolation(gpa, violations, "site/content/examples.smd: missing row for example chapter `{s}`", .{entry.name});
        }
    }

    // Every C example source is a first-class built program (`build.zig` compiles
    // and runs each under `zig build examples`), so each must be discoverable from
    // the index too.
    var c_dir = root.openDir(io, "examples/c", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "examples/c: failed to open with {s}", .{@errorName(err)});
        return;
    };
    defer c_dir.close(io);

    var c_it = c_dir.iterate();
    while (try c_it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".c")) continue;

        var needle_buf: [128]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "c/{s}", .{entry.name}) catch continue;
        if (std.mem.indexOf(u8, index, needle) == null) {
            try appendViolation(gpa, violations, "examples/README.md: missing index row for C example `{s}`", .{entry.name});
        }
    }
}

/// `zig build examples` compiles every row of the hand-maintained `zig_examples`
/// and `c_examples` tables in `build.zig`. An example dropped from a table still
/// on disk never runs under `check`; a stale table row points at a missing file
/// and fails at compile time with a less actionable error. Forward: every
/// `examples/zig/*.zig` and `examples/c/*.c` basename appears as a `.path` in
/// the matching table. Reverse: every table `.path` resolves on disk.
pub fn checkExampleWiring(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const build_zig = root.readFileAlloc(io, "build.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "build.zig: failed to read for example-wiring check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(build_zig);

    var table_paths = std.StringHashMap(void).init(gpa);
    defer table_paths.deinit();
    try collectBuildExamplePaths(build_zig, &table_paths);

    // Forward: every on-disk example source is listed in build.zig's tables.
    for (example_source_dirs) |spec| {
        var dir = root.openDir(io, spec.dir, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for example-wiring check with {s}", .{ spec.dir, @errorName(err) });
            continue;
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, spec.ext)) continue;

            var path_buf: [192]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ spec.dir, entry.name }) catch {
                try appendViolation(gpa, violations, "{s}/{s}: path too long for example-wiring check", .{ spec.dir, entry.name });
                continue;
            };
            if (!table_paths.contains(path)) {
                try appendViolation(gpa, violations, "{s}: not listed in build.zig's {s} table, it silently never runs under `zig build examples`", .{ path, spec.table_name });
            }
        }
    }

    // Reverse: every table path resolves on disk.
    var it = table_paths.keyIterator();
    while (it.next()) |path| {
        root.access(io, path.*, .{}) catch |err| {
            try appendViolation(gpa, violations, "build.zig: {s} table lists `{s}` but it is not accessible ({s})", .{
                if (std.mem.startsWith(u8, path.*, "examples/zig/")) "zig_examples" else "c_examples",
                path.*,
                @errorName(err),
            });
        };
    }
}

const example_source_dirs = [_]struct { dir: []const u8, ext: []const u8, table_name: []const u8 }{
    .{ .dir = "examples/zig", .ext = ".zig", .table_name = "zig_examples" },
    .{ .dir = "examples/c", .ext = ".c", .table_name = "c_examples" },
};

fn collectBuildExamplePaths(build_zig: []const u8, out: *std.StringHashMap(void)) !void {
    var rest = build_zig;
    while (std.mem.indexOf(u8, rest, ".path = \"")) |start| {
        const after = rest[start + ".path = \"".len ..];
        const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
        const path = after[0..end];
        rest = after[end..];
        if (!std.mem.startsWith(u8, path, "examples/zig/") and !std.mem.startsWith(u8, path, "examples/c/")) continue;
        try out.put(path, {});
    }
}

/// Appends each command-context region of a Markdown document to `out`: every
/// line inside a fenced code block, and the text of every inline backtick span
/// elsewhere. Regions are slices into `contents`, so they share its lifetime.
/// Text outside both — ordinary prose — is never yielded, so a phrase like
/// "the zig build system" cannot be mistaken for a command citation.
fn collectCommandRegions(gpa: std.mem.Allocator, contents: []const u8, out: *std.ArrayList([]const u8)) !void {
    var in_fence = false;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed_line = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed_line, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) {
            try out.append(gpa, line);
            continue;
        }
        var rest = line;
        while (std.mem.indexOfScalar(u8, rest, '`')) |open| {
            const after_open = rest[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, after_open, '`') orelse break;
            try out.append(gpa, after_open[0..close]);
            rest = after_open[close + 1 ..];
        }
    }
}

/// Scans one command-context region (a fenced line or an inline backtick span)
/// for `zig build <step>` and `bash <script>` citations, recording each step in
/// the documented set and flagging any that does not resolve.
const CommandScan = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    steps: *const std.StringHashMap(void),
    documented: *std.StringHashMap(void),
    documented_arena: std.mem.Allocator,
    path: []const u8,
    /// CI invocations resolve forward only; they are not documentation, so
    /// they never feed the reverse every-step-is-documented direction.
    record_documented: bool = true,
    /// A CI `zig build a b c` names several steps in one invocation; docs
    /// cite one step per span, so token consumption stays single there.
    multi_step: bool = false,

    fn region(self: CommandScan, text: []const u8) !void {
        var rest = text;
        while (std.mem.indexOf(u8, rest, "zig build")) |start| {
            const after = rest[start + "zig build".len ..];
            rest = after;

            var span = std.mem.trimStart(u8, after, " \t");
            if (span.len == 0 or isCommandTerminator(span[0])) continue;

            while (true) {
                const token_end = firstCommandTokenEnd(span);
                const documented_step = std.mem.trim(u8, span[0..token_end], "`'\".,);]");
                if (documented_step.len == 0) break;
                if (std.mem.startsWith(u8, documented_step, "-")) break;

                if (self.record_documented) {
                    try self.documented.put(try self.documented_arena.dupe(u8, documented_step), {});
                }
                if (!self.steps.contains(documented_step)) {
                    try appendViolation(self.gpa, self.violations, "{s}: documents `zig build {s}`, but build.zig has no step named `{s}`", .{
                        self.path,
                        documented_step,
                        documented_step,
                    });
                }
                if (!self.multi_step) break;
                const next = std.mem.trimStart(u8, span[token_end..], " \t");
                if (next.len == 0 or isCommandTerminator(next[0])) break;
                span = next;
            }
        }

        rest = text;
        while (std.mem.indexOf(u8, rest, "bash ")) |start| {
            const after = rest[start + "bash ".len ..];
            rest = after;

            const trimmed = std.mem.trimStart(u8, after, " \t");
            if (trimmed.len == 0 or isCommandTerminator(trimmed[0])) continue;

            const script_path = std.mem.trim(u8, trimmed[0..firstCommandTokenEnd(trimmed)], "`'\",);]");
            if (script_path.len == 0) continue;
            if (std.mem.startsWith(u8, script_path, "-")) continue;
            if (std.mem.indexOfScalar(u8, script_path, '/') == null) continue;

            self.root.access(self.io, script_path, .{}) catch |err| {
                try appendViolation(self.gpa, self.violations, "{s}: documents `bash {s}`, but script `{s}` is not accessible ({s})", .{
                    self.path,
                    script_path,
                    script_path,
                    @errorName(err),
                });
            };
        }
    }
};

pub fn checkDocumentedBuildSteps(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const build_zig = root.readFileAlloc(io, "build.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "build.zig: failed to read with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(build_zig);

    var steps = std.StringHashMap(void).init(gpa);
    defer steps.deinit();
    try steps.put("build", {});
    try collectBuildSteps(gpa, build_zig, &steps);

    // The command-citing corpus: the fixed surfaces outside the walked trees,
    // plus every Markdown file under `docs/**` and `.agents/**`, plus every
    // SuperMD page under `site/content/**` (the site cites the same
    // `zig build` steps and drifts the same way). Paths are duped into an
    // arena so they outlive the directory walkers.
    var docs_arena = std.heap.ArenaAllocator.init(gpa);
    defer docs_arena.deinit();
    var command_docs: std.ArrayList([]const u8) = .empty;
    defer command_docs.deinit(gpa);
    for (fixed_command_docs) |path| try command_docs.append(gpa, path);
    try collectCommandDocsUnder(io, gpa, docs_arena.allocator(), root, &command_docs, violations, "docs", ".md");
    try collectCommandDocsUnder(io, gpa, docs_arena.allocator(), root, &command_docs, violations, ".agents", ".md");
    try collectCommandDocsUnder(io, gpa, docs_arena.allocator(), root, &command_docs, violations, "site/content", ".smd");

    // Every `zig build <token>` token found across the corpus. Used both
    // forward (each documented token must name a real step) and in reverse
    // (each real step must be documented somewhere). Keys are duped into an
    // arena because each doc's `contents` is freed before the next iteration.
    var documented_arena = std.heap.ArenaAllocator.init(gpa);
    defer documented_arena.deinit();
    var documented = std.StringHashMap(void).init(gpa);
    defer documented.deinit();

    for (command_docs.items) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for build-command check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        const scan = CommandScan{
            .io = io,
            .gpa = gpa,
            .root = root,
            .violations = violations,
            .steps = &steps,
            .documented = &documented,
            .documented_arena = documented_arena.allocator(),
            .path = path,
        };

        // A `zig build`/`bash` citation is a command claim only inside command
        // context: a fenced code block, or an inline backtick span. Prose like
        // "the zig build system" is neither, so it is never mistaken for a step.
        var regions: std.ArrayList([]const u8) = .empty;
        defer regions.deinit(gpa);
        try collectCommandRegions(gpa, contents, &regions);
        for (regions.items) |text| try scan.region(text);
    }

    // The CI surfaces: every workflow on either forge plus the gate script,
    // scanned whole-file so a renamed build step or moved install script
    // cannot ship a broken CI run the local gate never sees.
    var ci_files: std.ArrayList([]const u8) = .empty;
    defer ci_files.deinit(gpa);
    for (ci_command_files) |path| try ci_files.append(gpa, path);
    for (ci_command_dirs) |dir_path| {
        try collectCommandDocsUnder(io, gpa, docs_arena.allocator(), root, &ci_files, violations, dir_path, ".yml");
    }
    for (ci_files.items) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for build-command check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        const scan = CommandScan{
            .io = io,
            .gpa = gpa,
            .root = root,
            .violations = violations,
            .steps = &steps,
            .documented = &documented,
            .documented_arena = documented_arena.allocator(),
            .path = path,
            .record_documented = false,
            .multi_step = true,
        };
        try scan.region(contents);
    }

    // Reverse direction: every build.zig step must be documented as
    // `zig build <name>` in at least one checked doc, so a new step cannot ship
    // undiscoverable. `build` is the implicit default alias and is exempt.
    var it = steps.keyIterator();
    while (it.next()) |name| {
        if (std.mem.eql(u8, name.*, "build")) continue;
        if (!documented.contains(name.*)) {
            try appendViolation(gpa, violations, "build.zig: step `{s}` is not documented as `zig build {s}` in any checked doc", .{ name.*, name.* });
        }
    }
}

fn collectCommandDocsUnder(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    root: std.Io.Dir,
    out: *std.ArrayList([]const u8),
    violations: *std.ArrayList([]const u8),
    dir_path: []const u8,
    ext: []const u8,
) !void {
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to open for command check with {s}", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ext)) continue;
        try out.append(gpa, try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, entry.path }));
    }
}

fn collectBuildSteps(gpa: std.mem.Allocator, build_zig: []const u8, steps: *std.StringHashMap(void)) !void {
    // Steps are declared as `b.step("name", …)`, table-driven `.step_name = "name"`
    // rows, header-gen `.check_step_name` / `.write_step_name` pairs, and
    // binding-family `.aggregate_name = "name"` rows passed to `addBindingFamily`.
    const patterns = [_][]const u8{
        "b.step(\"",
        ".step_name = \"",
        ".check_step_name = \"",
        ".write_step_name = \"",
        ".aggregate_name = \"",
    };
    for (patterns) |pattern| {
        var rest = build_zig;
        while (std.mem.indexOf(u8, rest, pattern)) |start| {
            const after = rest[start + pattern.len ..];
            const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
            const name = after[0..end];
            try steps.put(name, {});
            rest = after[end..];
        }
    }
    _ = gpa;
}

fn firstCommandTokenEnd(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (isCommandTerminator(text[i])) return i;
    }
    return text.len;
}

fn isCommandTerminator(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', '\r', '`', '$', '#', '|', '&', ';', ')' => true,
        else => false,
    };
}

const c_abi_archive_docs = [_][]const u8{
    "docs/architecture.md",
    "docs/consuming-from-c.md",
    "site/content/reference/index.smd",
};

/// Every composable C ABI archive named in the build must appear in the
/// first-read archive tables, so a new archive cannot land without a doc row.
/// The archive set is read from `build.zig`'s `archive_table` rows, not kept
/// as a second list here, so a new `.artifact` row is demanded in the docs the
/// moment it exists.
pub fn checkArchiveTables(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const build_zig = root.readFileAlloc(io, "build.zig", gpa, .limited(1 << 20)) catch |err| {
        try appendViolation(gpa, violations, "build.zig: failed to read for archive-table check with {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(build_zig);

    var artifacts: std.ArrayList([]const u8) = .empty;
    defer artifacts.deinit(gpa);
    const marker = ".artifact = \"";
    var rest = build_zig;
    while (std.mem.indexOf(u8, rest, marker)) |start| {
        const after = rest[start + marker.len ..];
        const end = std.mem.indexOfScalar(u8, after, '"') orelse break;
        try artifacts.append(gpa, after[0..end]);
        rest = after[end..];
    }
    if (artifacts.items.len == 0) {
        try appendViolation(gpa, violations, "build.zig: no `.artifact = \"...\"` archive rows found (archive-table check)", .{});
        return;
    }

    for (c_abi_archive_docs) |path| {
        const contents = root.readFileAlloc(io, path, gpa, .limited(2 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to read for archive-table check with {s}", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        for (artifacts.items) |artifact| {
            var name_buf: [128]u8 = undefined;
            const archive = std.fmt.bufPrint(&name_buf, "lib{s}", .{artifact}) catch {
                try appendViolation(gpa, violations, "build.zig: artifact name `{s}` too long for archive-table check", .{artifact});
                continue;
            };
            if (std.mem.indexOf(u8, contents, archive) == null) {
                try appendViolation(gpa, violations, "{s}: missing archive name `{s}` (archive-table check)", .{ path, archive });
            }
        }
    }
}

test "collectCommandRegions yields only fenced and inline-code text" {
    const gpa = std.testing.allocator;
    var regions: std.ArrayList([]const u8) = .empty;
    defer regions.deinit(gpa);

    const md =
        "Prose naming the zig build system must be ignored.\n" ++
        "Run `zig build check` and `bash setup.sh` inline.\n" ++
        "```sh\n" ++
        "zig build meta-check\n" ++
        "```\n" ++
        "Trailing prose zig build nonsense stays prose.\n";
    try collectCommandRegions(gpa, md, &regions);

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (regions.items) |r| {
        try joined.appendSlice(gpa, r);
        try joined.append(gpa, '\n');
    }
    const seen = joined.items;

    // Command context is captured.
    try std.testing.expect(std.mem.indexOf(u8, seen, "zig build check") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "bash setup.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "zig build meta-check") != null);
    // Prose is not, so its trailing tokens can never be read as a step.
    try std.testing.expect(std.mem.indexOf(u8, seen, "system") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "nonsense") == null);
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

/// The per-connection slot overhead is one number, stated in three places.
///
/// `conn_slot_overhead_bytes` is the constant a `comptime` equality holds the
/// real `Conn` to. `docs/ladder.md` step 2 and `bench/peer_scaling_bench.zig`
/// both quote it, because both are where someone goes to find out what a
/// connection costs. The constant moved once and the two quotes did not, so for
/// a while all three disagreed and nothing noticed — the prose said 112 while
/// the build asserted 128. The number is derived from the source of truth here
/// rather than written down a fourth time.
pub fn checkConnOverheadQuotes(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    const loop_path = "src/net/completion/loop.zig";
    const decl = "const conn_slot_overhead_bytes: usize = ";

    const loop_src = root.readFileAlloc(io, loop_path, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: cannot read it to derive the slot-overhead number ({s})", .{ loop_path, @errorName(err) });
        return;
    };
    defer gpa.free(loop_src);

    const at = std.mem.indexOf(u8, loop_src, decl) orelse {
        try appendViolation(gpa, violations, "{s}: `{s}…` is gone, so nothing derives the slot-overhead number the docs quote", .{ loop_path, decl });
        return;
    };
    const rest = loop_src[at + decl.len ..];
    var digits: usize = 0;
    while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
    if (digits == 0) {
        try appendViolation(gpa, violations, "{s}: `{s}` is not followed by a decimal literal", .{ loop_path, decl });
        return;
    }
    const number = rest[0..digits];

    // Every surface that states the number, with the phrase that makes the
    // claim. Anchoring matters: a bare search for "<n> bytes" anywhere in the
    // file is satisfied by any incidental mention of the same number, so the
    // quote could read 112 while an unrelated line said 128 and this would
    // pass — which is precisely the drift it exists to catch.
    const Quote = struct { path: []const u8, anchor: []const u8 };
    const quoting = [_]Quote{
        .{ .path = "docs/ladder.md", .anchor = "comes to **" },
        .{ .path = "bench/peer_scaling_bench.zig", .anchor = "(`Conn`) adds " },
    };
    for (quoting) |quote| {
        const path = quote.path;
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot read it to check the slot-overhead number ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);
        const claim = std.mem.indexOf(u8, contents, quote.anchor) orelse {
            try appendViolation(gpa, violations, "{s}: has no `{s}…` phrase stating the per-connection slot overhead, so nothing here is anchored to {s}", .{ path, quote.anchor, loop_path });
            continue;
        };
        const stated = contents[claim + quote.anchor.len ..];
        const needle = try std.fmt.allocPrint(gpa, "{s} bytes", .{number});
        defer gpa.free(needle);
        if (!std.mem.startsWith(u8, stated, needle)) {
            const shown = stated[0..@min(stated.len, 20)];
            try appendViolation(gpa, violations, "{s}: states the per-connection slot overhead as `{s}…`, but {s} asserts `{s} bytes`", .{ path, shown, loop_path, number });
        }
    }
}
