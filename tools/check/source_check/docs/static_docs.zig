//! Holds each doc to its kind (`kinds.zig`): a static doc uses no status
//! words, and no committed doc links a temporary local one.

const std = @import("std");
const util = @import("../util.zig");
const kinds = @import("kinds.zig");
const corpus = @import("corpus.zig");

const appendViolation = util.appendViolation;

/// Words that date a sentence to the moment it was written.
const status_words = [_][]const u8{
    "not yet",
    "today",
    "currently",
    "for now",
    "at the moment",
    "still required",
    "yet to",
};

pub fn check(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (try corpus.load(io, arena, root, violations, gpa)) |entry| {
        try checkText(gpa, violations, entry.path, entry.text, entry.doc.kind == .static);
    }
    // The site renders every example source into a page, comments included.
    const examples = try util.collectSourceFiles(io, arena, root, "site/examples", &isAny) orelse return;
    for (examples) |path| {
        const text = root.readFileAlloc(io, path, arena, .limited(4 << 20)) catch |err| {
            try appendViolation(gpa, violations, "{s}: cannot read it to check it against its kind ({s})", .{ path, @errorName(err) });
            continue;
        };
        try checkText(gpa, violations, path, text, true);
    }
}

fn checkText(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
    static: bool,
) !void {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        if (linksLocal(line)) {
            try appendViolation(gpa, violations, "{s}:{d}: links into `{s}`, which git ignores; no other checkout has that doc", .{ path, line_no, kinds.local_home });
        }
        if (!static) continue;
        for (status_words) |word| {
            if (findWord(line, word) != null) {
                try appendViolation(gpa, violations, "{s}:{d}: says `{s}`; a static doc states the present contract, and status belongs on a living page", .{ path, line_no, word });
            }
        }
    }
}

fn isAny(_: []const u8) bool {
    return true;
}

/// True when a Markdown link target on `line` points into the local home.
fn linksLocal(line: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, line, at, "](")) |open| {
        const start = open + "](".len;
        const end = std.mem.indexOfScalarPos(u8, line, start, ')') orelse line.len;
        if (std.mem.indexOf(u8, line[start..end], kinds.local_home) != null) return true;
        at = end;
    }
    return false;
}

/// Case-insensitive search for `word` with no letter on either side.
fn findWord(line: []const u8, word: []const u8) ?usize {
    if (line.len < word.len) return null;
    var i: usize = 0;
    while (i + word.len <= line.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(line[i .. i + word.len], word)) continue;
        if (i > 0 and std.ascii.isAlphabetic(line[i - 1])) continue;
        const end = i + word.len;
        if (end < line.len and std.ascii.isAlphabetic(line[end])) continue;
        return i;
    }
    return null;
}

test "findWord respects word edges and case" {
    try std.testing.expect(findWord("What ships Today.", "today") != null);
    try std.testing.expect(findWord("today's code", "today") != null);
    try std.testing.expect(findWord("todays", "today") == null);
    try std.testing.expect(findWord("not yetis", "not yet") == null);
}

test "linksLocal finds only link targets" {
    try std.testing.expect(linksLocal("see [notes](../.local/notes.md)"));
    try std.testing.expect(!linksLocal("scratch lives in `.local/` [x](a.md)"));
}
