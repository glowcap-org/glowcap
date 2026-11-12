//! Holds each doc to its kind (`kinds.zig`): a static doc uses none of the
//! history phrases, and no committed doc links a temporary local one.

const std = @import("std");
const source_tree = @import("../source_tree.zig");
const violation_log = @import("../violation_log.zig");
const kinds = @import("kinds.zig");
const corpus = @import("corpus.zig");

const appendViolation = violation_log.appendViolation;

/// Phrases that date a sentence to the day it was written, wherever they
/// appear. A word that also names running state or order ("no longer",
/// "earlier", "the old", "yet", "used to", "currently", "today") reads true
/// in a present contract, so the list leaves it to review.
const history_phrases = [_][]const u8{
    "formerly",
    "for now",
    "not yet implemented",
    "not implemented yet",
    "not yet supported",
    "not supported yet",
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
    const examples = try source_tree.collectSourceFiles(io, arena, root, "site/examples", &isAny) orelse return;
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

/// Hold one line of a static doc, or one first-party source comment, to the
/// history phrases and the dated-contract form.
pub fn checkNarration(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8), path: []const u8, line_no: usize, line: []const u8) !void {
    if (datedAsOf(line)) try appendViolation(gpa, violations, "{s}:{d}: dates a static contract with As of Month YYYY; move run dates to living records", .{ path, line_no });
    for (history_phrases) |phrase| {
        if (findWord(line, phrase) != null) try appendViolation(gpa, violations, "{s}:{d}: says `{s}`; state the present contract", .{ path, line_no, phrase });
    }
}

fn count(line: []const u8) !usize {
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |item| std.testing.allocator.free(item);
        violations.deinit(std.testing.allocator);
    }
    try checkNarration(std.testing.allocator, &violations, "a.md", 1, line);
    return violations.items.len;
}

test "running order passes and a phrase that dates the sentence is refused" {
    for ([_][]const u8{
        "// a frame not yet consumed waits in the tail",
        "// an earlier frame of the same run",
        "// release the old slot after the swap",
        "// an edited event no longer hashes to its name",
        "// the seed used to derive the designator",
        "// release a block previously returned by alloc",
        "// the state at the moment the answer settled",
        "// a signature is still required after rotation",
        "// the room currently selected keeps its draft",
        "// group lines under the Today heading",
        "The build adds no legacy bundle.",
    }) |line| try std.testing.expectEqual(@as(usize, 0), try count(line));
    for ([_][]const u8{
        "// formerly a separate archive",
        "The Host prints nothing for now.",
        "// onion listeners are not yet implemented",
        "// onion listeners are not implemented yet",
        "// keyed relay is not yet supported",
        "// keyed relay is not supported yet",
        "As of October 2026, it works.",
    }) |line| try std.testing.expectEqual(@as(usize, 1), try count(line));
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

test "a run date is told from an ordering phrase" {
    try std.testing.expect(datedAsOf("As of October 2026, it works."));
    try std.testing.expect(!datedAsOf("as of the last event"));
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
