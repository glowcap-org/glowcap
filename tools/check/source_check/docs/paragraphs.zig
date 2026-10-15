//! The paragraph ceiling: a prose paragraph or list item in a doc holds one
//! idea, so it stops at `max_paragraph_sentences` sentences. Past that it is
//! two ideas, or steps and rules that read better as a list.

const std = @import("std");
const util = @import("../util.zig");

const appendViolation = util.appendViolation;

/// The most sentences one paragraph or list item may hold.
pub const max_paragraph_sentences = 6;

/// Abbreviations whose period ends no sentence.
const abbreviations = [_][]const u8{ "e.g.", "i.e.", "etc.", "vs.", "cf." };

pub fn checkIn(
    gpa: std.mem.Allocator,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    contents: []const u8,
) !void {
    var in_fence = false;
    var in_header = std.mem.startsWith(u8, contents, "---\n");
    var line_no: usize = 0;
    var count: usize = 0;
    var start: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (in_header) {
            if (line_no > 1 and std.mem.eql(u8, trimmed, "---")) in_header = false;
            continue;
        }
        var rest = trimmed;
        while (std.mem.startsWith(u8, rest, ">")) rest = std.mem.trimStart(u8, rest[1..], " \t");
        const opens_item = isListItem(rest);
        const breaks = std.mem.startsWith(u8, rest, "```") or in_fence or rest.len == 0 or
            rest[0] == '#' or rest[0] == '|' or opens_item or std.mem.startsWith(u8, rest, "<!--");
        if (breaks) {
            try report(gpa, violations, path, start, count);
            count = 0;
            start = line_no;
            if (std.mem.startsWith(u8, rest, "```")) in_fence = !in_fence;
            if (!opens_item or in_fence) continue;
        }
        if (count == 0) start = line_no;
        count += sentenceEnds(rest);
    }
    try report(gpa, violations, path, start, count);
}

fn report(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8), path: []const u8, line: usize, count: usize) !void {
    if (count <= max_paragraph_sentences) return;
    try appendViolation(gpa, violations, "{s}:{d}: a paragraph of {d} sentences; doc-voice keeps one idea to a paragraph. Split it by idea, or make its steps or rules a list.", .{ path, line, count });
}

/// Sentence ends on one line, outside code spans: `.`, `!`, or `?` before a
/// space or the line's end, not closing an abbreviation.
fn sentenceEnds(line: []const u8) usize {
    var n: usize = 0;
    var in_code = false;
    for (line, 0..) |c, i| {
        if (c == '`') in_code = !in_code;
        if (in_code or (c != '.' and c != '!' and c != '?')) continue;
        if (i + 1 < line.len and line[i + 1] != ' ') continue;
        if (endsAbbreviation(line[0 .. i + 1])) continue;
        n += 1;
    }
    return n;
}

fn endsAbbreviation(prefix: []const u8) bool {
    for (abbreviations) |a| if (std.mem.endsWith(u8, prefix, a)) return true;
    return false;
}

fn isListItem(trimmed: []const u8) bool {
    if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) return true;
    var i: usize = 0;
    while (i < trimmed.len and std.ascii.isDigit(trimmed[i])) i += 1;
    if (i == 0 or i + 1 >= trimmed.len) return false;
    return (trimmed[i] == '.' or trimmed[i] == ')') and trimmed[i + 1] == ' ';
}

test "a paragraph past the ceiling is named at its first line" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    const ok =
        \\---
        \\description: One. Two. Three. Four. Five. Six. Seven.
        \\---
        \\# Title
        \\
        \\One. Two, e.g. this. Three `a. b. c.` here.
        \\Four. Five. Six.
        \\
        \\- One. Two. Three. Four.
        \\- Five. Six. Seven.
        \\
        \\```
        \\One. Two. Three. Four. Five. Six. Seven.
        \\```
        \\
    ;
    try checkIn(gpa, &violations, "a.md", ok);
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    try checkIn(gpa, &violations, "a.md", "Intro.\n\nOne. Two. Three.\nFour. Five. Six. Seven.\n");
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expect(std.mem.indexOf(u8, violations.items[0], "a.md:3:") != null);
}
