//! Source hygiene rules: justified map-removal discards, justified
//! discarded errors, path I/O copy bans, and the devcontainer's bash
//! scripts held to their contract.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;
const sectionBody = util.sectionBody;
const collectBulletSpans = util.collectBulletSpans;

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
        var dir = root.openDir(io, tree, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for raw-NUL check with {s}", .{
                tree,
                @errorName(err),
            });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !isTextSource(entry.path) or vendoredOrGenerated(entry.path)) continue;
            const contents = dir.readFileAlloc(io, entry.path, gpa, .limited(16 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}/{s}: failed to read for raw-NUL check with {s}", .{
                    tree,
                    entry.path,
                    @errorName(err),
                });
                continue;
            };
            defer gpa.free(contents);
            if (std.mem.indexOfScalar(u8, contents, 0) != null) try appendViolation(
                gpa,
                violations,
                "{s}/{s}: first-party text source contains a raw NUL byte; write the separator as an escape",
                .{ tree, entry.path },
            );
        }
    }
}

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

/// The discard forms this check flags, written split so its own source (and
/// any checker that later joins the scanned trees) cannot match them.
const discard_forms = [_][]const u8{
    "catch " ++ "{}",
    "catch |_| " ++ "{}",
    "catch " ++ "return;",
    "catch " ++ "continue;",
    "catch " ++ "break;",
};

/// A discarded error — an empty `catch` body, or a bare `catch` that only
/// returns, continues, or breaks — erases a failure's cause at the site that
/// saw it. Project values give every failure an owner, so the discard is
/// legitimate only where the loss is genuinely bounded: a diagnostic line
/// that cannot be reported because reporting is what failed, a cosmetic
/// interface update, a step the next wake or maintain call already retries.
/// Such a site must say so with an inline `// best-effort:` or `// tolerant:`
/// justification naming what is lost and why the loss is bounded — the
/// "explicit bounded loss" discipline. The bare-return form inside a fallible
/// function is the sharpest case, because it converts the failure into
/// reported success; unjustified, it is indistinguishable from a bug.
///
/// `tools/` is in scope because a checker that discards an error skips work
/// it claims to have done, which is a false green. Vendored packages and
/// generated trees are not first-party and are skipped.
pub fn checkDiscardedErrors(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for ([_][]const u8{ "src", "cli", "apps", "examples", "tools" }) |tree| {
        var dir = root.openDir(io, tree, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: failed to open for discarded-error check with {s}", .{ tree, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            if (vendoredOrGenerated(entry.path)) continue;
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ tree, entry.path });
            defer gpa.free(path);
            try checkDiscardedErrorsInFile(io, gpa, root, violations, path);
        }
    }
}

/// Trees no first-party rule governs: extracted Zig packages, npm state, and
/// build output that may sit under a scanned root.
fn vendoredOrGenerated(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "zig-pkg/") != null or
        std.mem.indexOf(u8, path, "node_modules/") != null or
        std.mem.indexOf(u8, path, ".zig-cache/") != null or
        std.mem.indexOf(u8, path, "zig-out/") != null;
}

/// True when `line` is a code (non-comment) line carrying one of the discard
/// forms outside string or character literals — the ban tables in this very
/// tree hold discard-shaped needles as data, and data is not a discard.
fn discardedErrorLine(line: []const u8) bool {
    var raw_hit = false;
    for (discard_forms) |form| {
        if (std.mem.indexOf(u8, line, form) != null) raw_hit = true;
    }
    if (!raw_hit) return false;
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "//")) return false;
    if (std.mem.startsWith(u8, trimmed, "\\\\")) return false;
    var buf: [4096]u8 = undefined;
    if (line.len > buf.len) return true;
    const code = blankLiterals(line, &buf);
    for (discard_forms) |form| {
        if (std.mem.indexOf(u8, code, form) != null) return true;
    }
    return false;
}

/// `line` with string and character literal contents blanked and any line
/// comment removed, so pattern scans see only code. Quotes themselves stay,
/// which keeps a literal from splicing into a pattern across its edges.
fn blankLiterals(line: []const u8, buf: []u8) []const u8 {
    const out = buf[0..line.len];
    @memcpy(out, line);
    var i: usize = 0;
    while (i < out.len) {
        const c = out[i];
        if (c == '/' and i + 1 < out.len and out[i + 1] == '/') return out[0..i];
        if (c == '"' or c == '\'') {
            i += 1;
            while (i < out.len and out[i] != c) {
                const escaped = out[i] == '\\';
                out[i] = ' ';
                i += 1;
                if (escaped and i < out.len) {
                    out[i] = ' ';
                    i += 1;
                }
            }
            if (i < out.len) i += 1;
            continue;
        }
        i += 1;
    }
    return out;
}

fn hasDiscardJustification(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "best-effort:") != null or
        std.mem.indexOf(u8, line, "tolerant:") != null;
}

/// A discard is justified by a marker on its own line or anywhere in the
/// contiguous `//` comment block directly above it. The walk also steps over
/// adjacent discard lines, so one block can cover a run — a pair of unwind
/// joins is one decision, and its justification reads best written once.
fn discardedErrorJustified(lines: []const []const u8, i: usize) bool {
    if (hasDiscardJustification(lines[i])) return true;
    var j = i;
    while (j > 0) {
        j -= 1;
        if (discardedErrorLine(lines[j])) continue;
        const trimmed = std.mem.trimStart(u8, lines[j], " \t");
        if (!std.mem.startsWith(u8, trimmed, "//")) return false;
        if (hasDiscardJustification(lines[j])) return true;
    }
    return false;
}

fn checkDiscardedErrorsInFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for discarded-error check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| try lines.append(gpa, line);

    for (lines.items, 0..) |line, i| {
        if (!discardedErrorLine(line)) continue;
        if (discardedErrorJustified(lines.items, i)) continue;
        try appendViolation(gpa, violations, "{s}:{d}: a discarded error (`catch` with an empty body or a bare return/continue/break) needs an inline `// best-effort:` or `// tolerant:` justification naming what is lost and why the loss is bounded — or the failure needs an owner", .{ path, i + 1 });
    }
}

/// The two copies of the product I/O directory helper are one text.
///
/// `cli/operability/path_io.zig` and
/// `apps/accountability-on-glowcap/zig/path_io.zig` work around the same Zig
/// standard-library wart, and the application copies it rather than importing
/// it because its whole claim is that it reaches for nothing in this repository
/// but glowcap's own public surface. The copy earns its place on that argument
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

/// Every bash file under `.devcontainer/` is linted. `hooks/post-create.sh`
/// runs shellcheck over every `*.sh` in the tree, so those are covered wherever
/// they sit; a bash file under any other name has to be named on that command
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
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.path });
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
        const line_end = std.mem.indexOfScalar(u8, contents, '\n') orelse contents.len;
        const first = contents[0..line_end];
        const shebang_bash = std.mem.startsWith(u8, first, "#!") and
            std.mem.indexOf(u8, first, "bash") != null;
        const declared_bash = std.mem.indexOf(u8, first, "shellcheck shell=bash") != null;
        if (!shebang_bash and !declared_bash) continue;
        if (std.mem.indexOf(u8, lint_source, entry.path) != null) continue;
        try appendViolation(
            gpa,
            violations,
            "{s}: a bash file that is not *.sh must be named in {s}, or nothing lints it",
            .{ path, lint_path },
        );
    }
}
