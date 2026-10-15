//! Bare function names in Zig doc comments as a checked surface.
//!
//! `checkZigDocSymbolClaims` holds `Type.method`. A doc comment just as often
//! names a function bare (`settleSentAnswer`), and a rename leaves that name
//! pointing at nothing while the build stays green. The rule: a backticked
//! lower camelCase name in a `src/` doc comment appears in the code (not the
//! comments) of `src/`, `test/` or `tools/`. Names declared outside this tree
//! (std, a wire spec) sit in `foreign_names`.

const std = @import("std");
const util = @import("util.zig");

const appendViolation = util.appendViolation;

/// Names a `src/` doc comment may cite that no first-party code spells.
const foreign_names = [_][]const u8{
    "unexpectedErrno", // std.posix
    "traversalLimitInWords", // the Cap'n Proto encoding spec
};

const code_trees = [_][]const u8{ "src", "test", "tools" };

pub fn checkZigDocBareNames(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var words: std.StringHashMap(void) = .init(arena);
    var docs: std.ArrayList(struct { path: []const u8, contents: []const u8 }) = .empty;
    for (code_trees) |tree| {
        var dir = root.openDir(io, tree, .{ .iterate = true }) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot be opened for the doc-name check ({s})", .{ tree, @errorName(err) });
            continue;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ tree, entry.path });
            const contents = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch |err| {
                try appendViolation(gpa, violations, "{s}: cannot be read for the doc-name check ({s})", .{ path, @errorName(err) });
                continue;
            };
            try collectCodeWords(&words, contents);
            if (std.mem.eql(u8, tree, "src")) try docs.append(arena, .{ .path = path, .contents = contents });
        }
    }
    for (docs.items) |doc| try checkFile(gpa, violations, &words, doc.path, doc.contents);
}

/// Every identifier outside a `//` comment. A `//` inside a string literal
/// cuts its line short, which only drops words and never invents one.
fn collectCodeWords(words: *std.StringHashMap(void), contents: []const u8) !void {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const code = line[0 .. std.mem.indexOf(u8, line, "//") orelse line.len];
        var i: usize = 0;
        while (i < code.len) {
            if (!isIdentStart(code[i])) {
                i += 1;
                continue;
            }
            const start = i;
            while (i < code.len and isIdentChar(code[i])) i += 1;
            try words.put(code[start..i], {});
        }
    }
}

fn checkFile(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    words: *const std.StringHashMap(void),
    path: []const u8,
    contents: []const u8,
) !void {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const t = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, t, "///") and !std.mem.startsWith(u8, t, "//!")) continue;
        var rest: []const u8 = t;
        while (std.mem.indexOfScalar(u8, rest, '`')) |open| {
            const after = rest[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, after, '`') orelse break;
            rest = after[close + 1 ..];
            const name = bareName(after[0..close]) orelse continue;
            if (words.contains(name) or isForeign(name)) continue;
            try appendViolation(
                gpa,
                violations,
                "{s}:{d}: doc comment names `{s}`, but no code under src/, test/ or tools/ spells it (fix the name or delete the claim)",
                .{ path, line_no, name },
            );
        }
    }
}

/// A lower camelCase identifier, optionally written as a call `name()`.
fn bareName(span: []const u8) ?[]const u8 {
    const name = if (std.mem.endsWith(u8, span, "()")) span[0 .. span.len - 2] else span;
    if (name.len == 0 or !std.ascii.isLower(name[0])) return null;
    var upper = false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c)) return null;
        if (std.ascii.isUpper(c)) upper = true;
    }
    return if (upper) name else null;
}

fn isForeign(name: []const u8) bool {
    for (foreign_names) |f| if (std.mem.eql(u8, name, f)) return true;
    return false;
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "a bare doc name must be spelled in code, not only in comments" {
    const gpa = std.testing.allocator;
    var words: std.StringHashMap(void) = .init(gpa);
    defer words.deinit();
    try collectCodeWords(&words, "pub fn settleSentAnswer() void {} // settleSentResolve\n");

    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |m| gpa.free(m);
        violations.deinit(gpa);
    }
    try checkFile(gpa, &violations, &words, "src/a.zig", "/// Calls `settleSentAnswer()` and `unexpectedErrno`.\n/// Not `snake_case`, `Type`, or `two words`.\n");
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    try checkFile(gpa, &violations, &words, "src/a.zig", "//! See `settleSentResolve`.\n");
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "src/a.zig:1:") != null);
}
