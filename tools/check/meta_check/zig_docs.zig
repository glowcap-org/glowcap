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
//! ordinary prose: a backticked `Type.method` where `Type` is capitalized and
//! `method` is lower camelCase must have `method` declared as a function
//! somewhere under `src/`. Cross-module and standard-library spellings are
//! skipped by prefix, since their declarations are not in this tree.

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

/// A doc claim: the spelling as written, and where it was written.
const Claim = struct {
    path: []const u8,
    line: usize,
    text: []const u8,
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
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch continue;
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

    var dir = root.openDir(io, "src", .{ .iterate = true }) catch return;
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(gpa, "src/{s}", .{entry.path});
        defer gpa.free(path);
        const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch continue;
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
    // Exactly one dot, both halves plain identifiers: `Type.method`.
    const dot = std.mem.indexOfScalar(u8, span, '.') orelse return;
    const type_name = span[0..dot];
    const method = span[dot + 1 ..];
    if (type_name.len == 0 or method.len == 0) return;
    if (std.mem.indexOfScalar(u8, method, '.') != null) return;
    for (type_name) |c| if (!isIdentChar(c)) return;
    for (method) |c| if (!isIdentChar(c)) return;

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
            "{s}:{d}: doc comment names `{s}.{s}`, but no `fn {s}(` is declared under src/ — fix the name or delete the claim",
            .{ path, line_no, type_name, method, method },
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
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
