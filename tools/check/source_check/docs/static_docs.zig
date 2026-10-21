//! Holds each doc to its kind (`kinds.zig`): a static doc uses no status
//! words, and no committed doc links a temporary local one.

const std = @import("std");
const util = @import("../util.zig");
const kinds = @import("kinds.zig");
const corpus = @import("corpus.zig");

const appendViolation = util.appendViolation;

/// Words that date a sentence to the moment it was written.
const status_words = [_][]const u8{
    "yet",
    "used to",
    "no longer",
    "previously",
    "earlier",
    "formerly",
    "legacy",
    "the old",
    "today",
    "currently",
    "for now",
    "at the moment",
    "still required",
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
        try @import("paragraphs.zig").checkRepeatedLinks(gpa, violations, entry.path, entry.text);
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
        if (static) try checkNarration(gpa, violations, path, line_no, line);
    }
}

pub fn checkNarration(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8), path: []const u8, line_no: usize, line: []const u8) !void {
    if (hasAllow(line)) return;
    if (datedAsOf(line)) try appendViolation(gpa, violations, "{s}:{d}: dates a static contract with As of Month YYYY; move run dates to living records", .{ path, line_no });
    for (status_words) |word| {
        if (findWord(line, word) != null) try appendViolation(gpa, violations, "{s}:{d}: says `{s}`; state the present contract or give an inline status-allow reason for temporal semantics", .{ path, line_no, word });
    }
}

/// An explicit reason exempts temporal ordering and quoted rule vocabulary.
fn hasAllow(line: []const u8) bool {
    const marker = "status-allow:";
    const start = std.mem.indexOf(u8, line, marker) orelse return false;
    return std.mem.trim(u8, line[start + marker.len ..], " \t->").len > 0;
}
fn datedAsOf(line: []const u8) bool {
    const start = findWord(line, "as of") orelse return false;
    var words = std.mem.tokenizeAny(u8, line[start + "as of".len ..], " \t");
    const month = words.next() orelse return false;
    const year = words.next() orelse return false;
    if (year.len < 4) return false;
    for (year[0..4]) |c| if (!std.ascii.isDigit(c)) return false;
    if (year.len > 4 and std.ascii.isAlphanumeric(year[4])) return false;
    for ([_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }) |name| {
        if (std.ascii.eqlIgnoreCase(month, name)) return true;
    }
    return false;
}

test "dated narration and reasoned inline allows" {
    try std.testing.expect(datedAsOf("As of October 2026, it works."));
    try std.testing.expect(!datedAsOf("as of the last event"));
    try std.testing.expect(!hasAllow("// status-allow: "));
    try std.testing.expect(hasAllow("// earlier event // status-allow: event ordering"));
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
        if (i > 0 and (std.ascii.isAlphabetic(line[i - 1]) or line[i - 1] == '/')) continue;
        const end = i + word.len;
        if (end < line.len and (std.ascii.isAlphabetic(line[end]) or line[end] == '/')) continue;
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
