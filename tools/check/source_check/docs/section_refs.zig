//! Named section references must navigate to the heading they name.
const std = @import("std");
const corpus = @import("corpus.zig");
const util = @import("../util.zig");

pub fn check(io: std.Io, gpa: std.mem.Allocator, root: std.Io.Dir, violations: *std.ArrayList([]const u8)) !void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = try corpus.load(io, arena, root, violations, gpa);
    var headings: std.StringHashMapUnmanaged(void) = .empty;
    for (entries) |entry| {
        var lines = std.mem.splitScalar(u8, entry.text, '\n');
        var fence = false;
        while (lines.next()) |line| {
            const s = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, s, "```") or std.mem.startsWith(u8, s, "~~~")) {
                fence = !fence;
                continue;
            }
            if (fence or !std.mem.startsWith(u8, s, "#")) continue;
            // Markdown H1 names the page; SMD page titles live in frontmatter.
            if (std.mem.startsWith(u8, s, "# ") and !std.mem.endsWith(u8, entry.path, ".smd")) continue;
            var title = std.mem.trim(u8, s, "# \t");
            if (std.mem.startsWith(u8, title, "[")) title = title[1 .. std.mem.indexOfScalar(u8, title, ']') orelse continue];
            try headings.put(arena, title, {});
        }
    }
    for (entries) |entry| {
        var lines = std.mem.splitScalar(u8, entry.text, '\n');
        var fence = false;
        var paragraph: std.ArrayList(u8) = .empty;
        var number: usize = 0;
        while (lines.next()) |line| {
            number += 1;
            const s = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, s, "```") or std.mem.startsWith(u8, s, "~~~")) {
                fence = !fence;
                continue;
            }
            if (fence or std.mem.startsWith(u8, s, "#")) continue;
            if (s.len == 0) {
                try checkParagraph(gpa, violations, entry.path, number, paragraph.items, headings);
                paragraph.clearRetainingCapacity();
            } else {
                try paragraph.appendSlice(arena, s);
                try paragraph.append(arena, ' ');
            }
        }
        try checkParagraph(gpa, violations, entry.path, number, paragraph.items, headings);
    }
}
fn checkParagraph(gpa: std.mem.Allocator, violations: *std.ArrayList([]const u8), path: []const u8, line: usize, text: []const u8, headings: std.StringHashMapUnmanaged(void)) !void {
    const prose = try gpa.dupe(u8, text);
    defer gpa.free(prose);
    // Inline code and linked labels are not unlinked prose references.
    var at: usize = 0;
    while (at < prose.len) : (at += 1) {
        if (prose[at] == '`' or prose[at] == '[') {
            const closing: u8 = if (prose[at] == '`') '`' else ']';
            const end = std.mem.indexOfScalarPos(u8, prose, at + 1, closing) orelse continue;
            @memset(prose[at .. end + 1], ' ');
            at = end;
        }
    }
    var titles = headings.keyIterator();
    while (titles.next()) |title| {
        if (title.*.len == 0) continue;
        at = 0;
        while (std.mem.indexOfPos(u8, prose, at, title.*)) |start| {
            at = start + title.*.len;
            if (start > 0 and std.ascii.isAlphanumeric(prose[start - 1])) continue;
            if (at < prose.len and std.ascii.isAlphanumeric(prose[at])) continue;
            // A possessive names the subject, not a destination heading.
            if (std.mem.startsWith(u8, prose[at..], "'") or std.mem.startsWith(u8, prose[at..], "’")) continue;
            const before = std.mem.trimEnd(u8, prose[0..start], " \t\"“”");
            const after = std.mem.trimStart(u8, prose[at..], " \t\"“”");
            const quoted = std.mem.endsWith(u8, prose[0..start], "\"") or std.mem.endsWith(u8, prose[0..start], "“");
            const prefix_ref = referencePrefix(before) and (quoted or !std.mem.endsWith(u8, before, "in"));
            if (!prefix_ref and !std.mem.startsWith(u8, after, "section")) continue;
            try util.appendViolation(gpa, violations, "{s}:near {d}: link the section heading `{s}`", .{ path, line, title.* });
        }
    }
}
fn referencePrefix(text: []const u8) bool {
    const prefix = std.mem.trimEnd(u8, text, " \t");
    for ([_][]const u8{ "under", "see", "section", "in", "See", "Under" }) |word| {
        if (!std.mem.endsWith(u8, prefix, word)) continue;
        const start = prefix.len - word.len;
        if (start == 0 or !std.ascii.isAlphabetic(prefix[start - 1])) return true;
    }
    return false;
}
test "section references are distinguished from incidental quotation" {
    try std.testing.expect(referencePrefix("listed under "));
    try std.testing.expect(referencePrefix("See "));
    try std.testing.expect(!referencePrefix("the program prints "));
    const gpa = std.testing.allocator;
    var headings: std.StringHashMapUnmanaged(void) = .empty;
    defer headings.deinit(gpa);
    try headings.put(gpa, "Everyday checks", {});
    try headings.put(gpa, "Rooms", {});
    var violations: std.ArrayList([]const u8) = .empty;
    defer {
        for (violations.items) |v| gpa.free(v);
        violations.deinit(gpa);
    }
    try checkParagraph(gpa, &violations, "x.md", 1, "See \"Everyday checks\".", headings);
    try checkParagraph(gpa, &violations, "x.md", 2, "See [Everyday checks](#everyday-checks).", headings);
    try checkParagraph(gpa, &violations, "x.md", 3, "See Everyday checks below.", headings);
    try checkParagraph(gpa, &violations, "x.md", 4, "See “Everyday checks”.", headings);
    try checkParagraph(gpa, &violations, "x.md", 5, "See `Everyday checks`.", headings);
    try checkParagraph(gpa, &violations, "x.md", 6, "Conversations in Rooms use capabilities.", headings);
    try checkParagraph(gpa, &violations, "x.md", 7, "Behavior under Rooms' contract and under Rooms’s rules.", headings);
    try std.testing.expectEqual(@as(usize, 3), violations.items.len);
}
