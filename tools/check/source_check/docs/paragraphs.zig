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

/// One link per destination in a prose paragraph. Reference definitions and
/// optional titles affect presentation, not destination identity.
pub fn checkRepeatedLinks(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8), path: []const u8, contents: []const u8) !void {
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    var references: std.StringHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var fence = false;
    while (lines.next()) |line| {
        const rest = std.mem.trim(u8, line, " \t\r");
        if (fenceLine(rest)) {
            fence = !fence;
            continue;
        }
        if (!fence) if (definition(rest)) |ref| try references.put(arena, try label(arena, ref.name), ref.target);
    }
    lines.reset();
    fence = false;
    var header = std.mem.startsWith(u8, contents, "---\n");
    var number: usize = 0;
    var paragraph: std.ArrayList(u8) = .empty;
    while (lines.next()) |line| {
        number += 1;
        const rest = std.mem.trim(u8, line, " \t\r");
        if (header) {
            if (number > 1 and std.mem.eql(u8, rest, "---")) header = false;
            continue;
        }
        if (fenceLine(rest) or rest.len == 0 or rest[0] == '#' or rest[0] == '|' or isListItem(rest)) {
            try paragraphLinks(arena, gpa, violations, path, number, paragraph.items, references);
            paragraph.clearRetainingCapacity();
        }
        if (fenceLine(rest)) {
            fence = !fence;
            continue;
        }
        if (fence or definition(rest) != null) continue;
        try paragraph.appendSlice(arena, rest);
        try paragraph.append(arena, ' ');
    }
    try paragraphLinks(arena, gpa, violations, path, number, paragraph.items, references);
}
fn fenceLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~");
}
fn definition(line: []const u8) ?struct { name: []const u8, target: []const u8 } {
    if (!std.mem.startsWith(u8, line, "[")) return null;
    const end = std.mem.indexOf(u8, line, "]:") orelse return null;
    const target = destination(std.mem.trimStart(u8, line[end + 2 ..], " \t"));
    if (target.len == 0) return null;
    return .{ .name = line[1..end], .target = target };
}
fn destination(text: []const u8) []const u8 {
    if (std.mem.startsWith(u8, text, "<")) return text[1 .. std.mem.indexOfScalar(u8, text, '>') orelse text.len];
    var depth: usize = 0;
    var end: usize = 0;
    while (end < text.len) : (end += 1) {
        if (text[end] == '\\' and end + 1 < text.len) {
            end += 1;
            continue;
        }
        if (text[end] == '(') depth += 1;
        if (text[end] == ')') {
            if (depth == 0) break;
            depth -= 1;
        }
        if (depth == 0 and std.ascii.isWhitespace(text[end])) break;
    }
    return text[0..end];
}
fn label(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (tokens.next()) |token| {
        if (out.items.len > 0) try out.append(arena, ' ');
        for (token) |c| try out.append(arena, std.ascii.toLower(c));
    }
    return out.toOwnedSlice(arena);
}
fn paragraphLinks(arena: std.mem.Allocator, gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8), path: []const u8, number: usize, text: []const u8, references: std.StringHashMapUnmanaged([]const u8)) !void {
    var targets: std.StringHashMapUnmanaged(void) = .empty;
    var at: usize = 0;
    while (at < text.len) {
        const c = text[at];
        if (c == '\\') {
            at += @min(@as(usize, 2), text.len - at);
            continue;
        }
        if (c == '`') {
            var end = at;
            while (end < text.len and text[end] == '`') : (end += 1) {}
            const marker = text[at..end];
            at = if (std.mem.indexOfPos(u8, text, end, marker)) |close| close + marker.len else end;
            continue;
        }
        if (c != '[' or (at > 0 and text[at - 1] == '!')) {
            at += 1;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, text, at + 1, ']') orelse break;
        const name = text[at + 1 .. close];
        at = close + 1;
        var target: ?[]const u8 = null;
        if (at < text.len and text[at] == '(') {
            const rest = std.mem.trimStart(u8, text[at + 1 ..], " \t");
            target = destination(rest);
            var depth: usize = 1;
            var quote: ?u8 = null;
            at += 1;
            while (at < text.len and depth > 0) : (at += 1) {
                if (text[at] == '\\' and at + 1 < text.len) {
                    at += 1;
                    continue;
                }
                if (quote) |q| {
                    if (text[at] == q) quote = null;
                    continue;
                }
                if (text[at] == '"' or text[at] == '\'') {
                    quote = text[at];
                    continue;
                }
                if (text[at] == '(') depth += 1;
                if (text[at] == ')') depth -= 1;
            }
        } else {
            var ref = name;
            if (at < text.len and text[at] == '[') {
                const end = std.mem.indexOfScalarPos(u8, text, at + 1, ']') orelse break;
                if (end > at + 1) ref = text[at + 1 .. end];
                at = end + 1;
            }
            target = references.get(try label(arena, ref));
        }
        if (target) |url| {
            const entry = try targets.getOrPut(arena, url);
            if (entry.found_existing) try appendViolation(gpa, violations, "{s}:near {d}: paragraph links `{s}` twice; link its first mention (doc-drift)", .{ path, number, url });
        }
    }
}

test "repeated links share a paragraph across wrapped lines, including site expressions" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    try checkRepeatedLinks(gpa, &violations, "a.md", "[one](a.md) and\n[two](a.md).\n\n[three](a.md)\n\n```\n[x](b) [y](b)\n```\n[a]($link.page('start')) [b]($link.page('start'))");
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
    try checkRepeatedLinks(gpa, &violations, "a.md", "- [one](a)\n- [two](a)\n");
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
}

test "link destinations ignore titles and inline code and resolve references" {
    const gpa = std.testing.allocator;
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    try checkRepeatedLinks(gpa, &violations, "x.md", "[a](x \"one\") [b](x \"two\")");
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try checkRepeatedLinks(gpa, &violations, "x.md", "`[a](x) [b](x)`");
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try checkRepeatedLinks(gpa, &violations, "x.md", "[a][ref] [REF][] [ref]\n\n[ref]: <x> \"title\"\n");
    try std.testing.expectEqual(@as(usize, 3), violations.items.len);
}
