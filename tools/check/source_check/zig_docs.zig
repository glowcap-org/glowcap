//! Zig doc comments as a checked surface.
//!
//! A `///` or `//!` comment that names a method is making a claim about the
//! code beside it, and that claim rots silently: the compiler never reads a
//! comment, so a renamed or deleted method leaves prose pointing at nothing
//! and the build stays green. Two defects of exactly this shape shipped here —
//! a module header describing a `FrameStream.drive` that never existed, and a
//! `Peer.sendWithdrawGift` doc naming a `Node.sendWithdraw` that never existed.
//! Both would have failed this check the day they were written.
//!
//! The rule is deliberately narrow, so it fires on real drift and not on
//! ordinary prose: a backticked path whose last two segments read
//! `Type.method`, with `Type` capitalized and `method` lower camelCase, must
//! have `method` declared as a function somewhere under `src/`. The leading
//! module names are ignored rather than disqualifying, because
//! `engine.Peer.sendKeyedStartSession` is how this tree usually writes the
//! claim and reading only the bare spelling left most of them unchecked.
//! Standard-library paths are skipped by their `std.` prefix, and a short list
//! of type names declared outside this tree is skipped by name, since neither
//! proves anything about `src/`.
//!
//! `checkMemoryLedgerSymbolClaims` points the same machinery at the one prose
//! surface that carries symbol names as its load-bearing content: the memory
//! rule's ledger, where each entry names the declaration that owns a cost
//! instead of restating its derivation. It accepts a wider shape there, any
//! final segment in lower camelCase, because the ledger writes `model.cloneMessage`
//! and bare `ownedFrameFromView` as readily as `Peer.sendCopying`.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// Type names whose methods are declared outside `src/`, so a doc naming one
/// proves nothing about this tree. Matched against the text before the dot.
const foreign_types = [_][]const u8{
    "Io",        "Dir",    "File",    "Reader",  "Writer",
    "Stream",    "Thread", "Mutex",   "Build",   "Step",
    "Uring",     "Timer",  "Instant", "Random",  "Allocator",
    "ArrayList", "Map",    "Value",   "Type",    "Target",
    "Ed25519",   "Sha256", "Blake3",  "Managed", "Wyhash",
};

fn isDocLine(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, t, "///") or std.mem.startsWith(u8, t, "//!");
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isForeign(type_name: []const u8) bool {
    for (foreign_types) |f| {
        if (std.mem.eql(u8, type_name, f)) return true;
    }
    return false;
}

/// Collect every `fn <name>(` declaration under `src/` into `out`.
fn collectDeclaredFns(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    out: *std.StringHashMap(void),
    violations: *std.ArrayList([]const u8),
) !void {
    var dir = root.openDir(io, "src", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src: failed to open for zig-doc claim check with {s}", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be read for the doc-symbol check ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        var rest: []const u8 = contents;
        while (std.mem.indexOf(u8, rest, "fn ")) |at| {
            // Only a real declaration: `fn ` at a token boundary.
            const before_ok = at == 0 or !isIdentChar(rest[at - 1]);
            var i = at + 3;
            const start = i;
            while (i < rest.len and isIdentChar(rest[i])) i += 1;
            if (before_ok and i > start and i < rest.len and rest[i] == '(') {
                const name = rest[start..i];
                if (!out.contains(name)) try out.put(try gpa.dupe(u8, name), {});
            }
            rest = rest[at + 3 ..];
        }
    }
}

/// Every backticked `Type.method` in a `src/` doc comment names a function this
/// tree declares.
pub fn checkZigDocSymbolClaims(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var declared: std.StringHashMap(void) = .init(gpa);
    defer {
        var it = declared.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        declared.deinit();
    }
    try collectDeclaredFns(io, gpa, root, &declared, violations);
    if (declared.count() == 0) return;

    var dir = root.openDir(io, "src", .{ .iterate = true }) catch |err| {
        try appendViolation(gpa, violations, "src: cannot be opened for the doc-symbol check ({s})", .{@errorName(err)});
        return;
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be read for the doc-symbol check ({s})", .{ path, @errorName(err) });
            continue;
        };
        defer gpa.free(contents);

        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if (!isDocLine(line)) continue;

            var rest: []const u8 = line;
            while (std.mem.indexOfScalar(u8, rest, '`')) |open| {
                const after = rest[open + 1 ..];
                const close = std.mem.indexOfScalar(u8, after, '`') orelse break;
                const span = after[0..close];
                rest = after[close + 1 ..];
                try checkSpan(gpa, violations, &declared, path, line_no, span);
            }
        }
    }
}

fn checkSpan(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    declared: *const std.StringHashMap(void),
    path: []const u8,
    line_no: usize,
    span: []const u8,
) !void {
    // A dotted path whose every segment is a plain identifier. The last two
    // segments are the claim: `Type.method`, however many module names sit in
    // front of it. Reading only the last two is what covers the spelling this
    // tree actually writes — `engine.Peer.sendKeyedStartSession` far more often
    // than the bare `Peer.sendKeyedStartSession` — and a rename that swept its
    // two-segment referrers while leaving the qualified ones behind is the
    // exact drift this check exists to catch.
    for (span) |c| if (!isIdentChar(c) and c != '.') return;
    const dot = std.mem.lastIndexOfScalar(u8, span, '.') orelse return;
    const method = span[dot + 1 ..];
    const owner_path = span[0..dot];
    if (owner_path.len == 0 or method.len == 0) return;
    const owner_dot = std.mem.lastIndexOfScalar(u8, owner_path, '.');
    const type_name = if (owner_dot) |at| owner_path[at + 1 ..] else owner_path;
    if (type_name.len == 0) return;
    // A `std.` path is declared outside this tree whatever its shape, so it
    // proves nothing about `src/` and is skipped before the type-name test.
    if (std.mem.startsWith(u8, span, "std.")) return;

    // `Type.method`: a capitalized owner and a lower camelCase function.
    if (!std.ascii.isUpper(type_name[0])) return;
    if (!std.ascii.isLower(method[0])) return;
    // An enum member or field is lower-case too; require the method to look
    // like a call target (contains an upper-case letter, or is a known verb
    // shape) before demanding it exist. This keeps `Kind.tcp` out of scope.
    if (!hasUpper(method) and !isBareVerb(method)) return;
    if (isForeign(type_name)) return;

    if (!declared.contains(method)) {
        try appendViolation(
            gpa,
            violations,
            "{s}:{d}: doc comment names `{s}`, but no `fn {s}(` is declared under src/ — fix the name or delete the claim",
            .{ path, line_no, span, method },
        );
    }
}

fn hasUpper(s: []const u8) bool {
    for (s) |c| if (std.ascii.isUpper(c)) return true;
    return false;
}

/// Single-word method names common enough to be worth checking even without an
/// interior capital.
fn isBareVerb(s: []const u8) bool {
    const verbs = [_][]const u8{
        "init",  "deinit", "send",  "call",   "fetch",    "publish", "spawn",
        "serve", "close",  "step",  "drive",  "pump",     "flush",   "tell",
        "on",    "accept", "dial",  "listen", "read",     "write",   "peek",
        "reset", "drain",  "clone", "become", "snapshot", "restore",
    };
    for (verbs) |v| if (std.mem.eql(u8, s, v)) return true;
    return false;
}

test "checkSpan flags a method no src/ file declares" {
    const gpa = std.testing.allocator;
    var declared: std.StringHashMap(void) = .init(gpa);
    defer declared.deinit();
    try declared.put("readFrame", {});

    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |m| gpa.free(m);
        violations.deinit(gpa);
    }

    try checkSpan(gpa, &violations, &declared, "src/net/connection.zig", 27, "FrameStream.drive");
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);

    try checkSpan(gpa, &violations, &declared, "src/net/connection.zig", 28, "FrameStream.readFrame");
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);

    // The qualified spelling this tree usually writes. Reading only the last
    // two segments is what makes a rename's module-qualified referrers
    // checkable; it was the shape four stale `engine.Peer.expectPartnerKey`
    // claims survived two renames in.
    try checkSpan(gpa, &violations, &declared, "src/net/connection.zig", 29, "net.FrameStream.drive");
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);

    try checkSpan(gpa, &violations, &declared, "src/net/connection.zig", 30, "glowcap.net.FrameStream.readFrame");
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
}

test "checkSpan ignores enum members, foreign types, and prose" {
    const gpa = std.testing.allocator;
    var declared: std.StringHashMap(void) = .init(gpa);
    defer declared.deinit();

    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |m| gpa.free(m);
        violations.deinit(gpa);
    }

    // Enum member, not a call target.
    try checkSpan(gpa, &violations, &declared, "p.zig", 1, "CodecId.syrup");
    // Declared outside this tree.
    try checkSpan(gpa, &violations, &declared, "p.zig", 2, "Io.readAll");
    // Not a `Type.method` shape at all.
    try checkSpan(gpa, &violations, &declared, "p.zig", 3, "op:start-session");
    try checkSpan(gpa, &violations, &declared, "p.zig", 4, "std.mem.eql");
    // A `std.` path whose last two segments *do* read `Type.method`: skipped
    // by the prefix, since it is declared outside this tree.
    try checkSpan(gpa, &violations, &declared, "p.zig", 5, "std.Uri.percentDecodeInPlace");
    // A qualified path whose tail is a constant, not a call target.
    try checkSpan(gpa, &violations, &declared, "p.zig", 6, "model.transport.hint_codec");
    // A qualified path naming a type rather than a method.
    try checkSpan(gpa, &violations, &declared, "p.zig", 7, "foundation.crypto.PeerKey");
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

/// The memory rule's ledger names, one per entry, the symbol whose declaration
/// carries the full derivation of a named allocation. That pointer is the whole
/// mechanism keeping the rule from re-growing a second copy of every argument,
/// so a name that no longer resolves silently turns the ledger back into
/// folklore. It rots exactly like a doc comment and nothing else reads it: a
/// `clonePeerLocator` the ledger cited through two rewrites had never existed
/// under any name, and the copy it described was a raw-bytes dupe with a
/// relocated designator subslice.
///
/// Scoped to the ledger's Zig sections. `### Named deferred costs` is the one
/// section that names binding-language symbols (`pointerOf`, `outBuffers`,
/// `readMemory`), which no `fn` under `src/` declares and which this check
/// would misread as drift.
pub fn checkMemoryLedgerSymbolClaims(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    for ([_][]const u8{ ".agents/skills/memory-ledger/SKILL.md", ".agents/skills/memory-ledger/references/loam.md", ".agents/skills/memory-ledger/references/rooms.md" }) |path| {
        try checkMemoryLedgerFile(io, gpa, root, violations, path);
    }
}

fn checkMemoryLedgerFile(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir, violations: *std.ArrayList([]const u8), path: []const u8) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch |err| {
        try appendViolation(gpa, violations, "{s}: failed to read for the ledger symbol check with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    const ledger_start = std.mem.indexOf(u8, contents, "\n## The ledger") orelse {
        try appendViolation(gpa, violations, "{s}: missing `## The ledger` section", .{path});
        return;
    };
    const after = contents[ledger_start..];
    const stop = std.mem.indexOf(u8, after, "\n### Named deferred costs") orelse after.len;
    const ledger = after[0..stop];

    var declared: std.StringHashMap(void) = .init(gpa);
    defer {
        var it = declared.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        declared.deinit();
    }
    try collectDeclaredFns(io, gpa, root, &declared, violations);
    if (declared.count() == 0) return;

    // Line numbers count from the top of the file, not the section.
    var line_no = std.mem.count(u8, contents[0..ledger_start], "\n") + 1;
    var lines = std.mem.splitScalar(u8, ledger, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        var rest: []const u8 = line;
        while (std.mem.indexOfScalar(u8, rest, '`')) |open| {
            const after_open = rest[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, after_open, '`') orelse break;
            const span = after_open[0..close];
            rest = after_open[close + 1 ..];
            try checkSpan(gpa, violations, &declared, path, line_no, span);
            try checkBareFnSpan(gpa, violations, &declared, path, line_no, span);
        }
    }
}

/// A backticked identifier whose final segment is lower camelCase with an
/// interior capital (`ownedFrameFromView`, `model.cloneMessage`,
/// `Node.stageDial`) reads as a function this tree declares. Only the
/// last segment is tested, so the owner may be a module or a type or absent;
/// `checkSpan` above covers the `Type.method` shape more strictly and this
/// covers the rest. Snake_case segments are fields, constants, and wire names
/// rather than call targets, and a capitalized final segment is a type, so both
/// are out of scope.
fn checkBareFnSpan(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    declared: *const std.StringHashMap(void),
    path: []const u8,
    line_no: usize,
    span: []const u8,
) !void {
    if (span.len == 0) return;
    for (span) |c| if (!isIdentChar(c) and c != '.') return;
    // A `std.` path is declared outside this tree, so it proves nothing here.
    if (std.mem.startsWith(u8, span, "std.")) return;
    const last = if (std.mem.lastIndexOfScalar(u8, span, '.')) |at| span[at + 1 ..] else span;
    if (last.len == 0) return;
    if (std.mem.indexOfScalar(u8, last, '_') != null) return;
    if (!std.ascii.isLower(last[0])) return;
    if (!hasUpper(last)) return;
    if (declared.contains(last)) return;
    try appendViolation(
        gpa,
        violations,
        "{s}:{d}: the ledger names `{s}`, but no `fn {s}(` is declared under src/ — point the entry at the symbol that owns the cost, or drop the name",
        .{ path, line_no, span, last },
    );
}
