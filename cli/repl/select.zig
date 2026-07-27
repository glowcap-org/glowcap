//! Character-range selection math for the CapTP lab transcript (pure).
//!
//! Anchors are screen cells. Content columns are relative to the transcript
//! origin (`screen_col - origin_x`), and they count characters, not bytes. A
//! transcript line can hold anything a remote peer sent, so counting bytes put
//! the highlight in the wrong place on any line with accented text and handed
//! the clipboard a half-copied character. One column per character puts both
//! back where the reader sees them.
//!
//! A character that the terminal draws two cells wide, such as most CJK text,
//! still shifts the highlight by the extra cell. Measuring that needs the
//! terminal's own width tables, which this module deliberately does not reach
//! for; it stays pure arithmetic.
const std = @import("std");
const argv = @import("../argv.zig");

/// Where a character ends. Shared with the JSON escaper so a highlight always
/// covers exactly what a copy would produce.
const charLen = argv.characterLen;

pub const Point = struct {
    col: u16 = 0,
    row: u16 = 0,

    pub fn lessThan(a: Point, b: Point) bool {
        if (a.row != b.row) return a.row < b.row;
        return a.col < b.col;
    }
};

pub const Anchors = struct {
    a: Point = .{},
    b: Point = .{},
};

/// Gesture phase for in-app drag-select. Illegal combinations are unrepresentable.
pub const Phase = enum { idle, pressed, dragging, lingering };

pub const Selection = struct {
    phase: Phase = .idle,
    anchors: Anchors = .{},

    pub fn clear(self: *Selection) void {
        self.* = .{};
    }

    pub fn highlights(self: Selection) bool {
        return switch (self.phase) {
            .dragging, .lingering => true,
            .idle, .pressed => false,
        };
    }

    pub fn cellDist(self: Selection, col: u16, row: u16) u16 {
        const ac = self.anchors.a.col;
        const ar = self.anchors.a.row;
        const dc = if (col > ac) col - ac else ac - col;
        const dr = if (row > ar) row - ar else ar - row;
        return @max(dc, dr);
    }
};

/// Lexicographic order of the two anchors (start ≤ end).
pub fn ordered(a: Point, b: Point) struct { Point, Point } {
    if (Point.lessThan(b, a)) return .{ b, a };
    return .{ a, b };
}

/// How many characters `line` holds. This is the line's length in selection
/// columns.
pub fn charCount(line: []const u8) usize {
    var chars: usize = 0;
    var i: usize = 0;
    while (i < line.len) : (chars += 1) i += charLen(line[i..]);
    return chars;
}

/// The byte offset where character `char_index` begins, or the line's length
/// when the index is past the end.
pub fn byteAt(line: []const u8, char_index: usize) usize {
    var chars: usize = 0;
    var i: usize = 0;
    while (i < line.len and chars < char_index) : (chars += 1) i += charLen(line[i..]);
    return i;
}

fn toContent(screen_col: u16, origin_x: u16) usize {
    if (screen_col <= origin_x) return 0;
    return @as(usize, screen_col - origin_x);
}

/// Inclusive content-column span on `screen_row`, or null if that row is outside
/// the selection. `line_chars` clamps the end so a drag past EOL still copies the line.
pub fn contentSpan(
    a: Point,
    b: Point,
    screen_row: u16,
    origin_x: u16,
    line_chars: usize,
) ?struct { start: usize, end_excl: usize } {
    const lo, const hi = ordered(a, b);
    if (screen_row < lo.row or screen_row > hi.row) return null;

    var start: usize = 0;
    var end_excl: usize = line_chars;
    if (lo.row == hi.row) {
        start = toContent(lo.col, origin_x);
        end_excl = toContent(hi.col, origin_x);
        // Inclusive end cell: drag onto a character includes it.
        if (end_excl < line_chars) {
            end_excl += 1;
        } else if (end_excl == start and line_chars > 0 and toContent(hi.col, origin_x) >= line_chars) {
            end_excl = line_chars;
        }
    } else if (screen_row == lo.row) {
        start = toContent(lo.col, origin_x);
        end_excl = line_chars;
    } else if (screen_row == hi.row) {
        start = 0;
        end_excl = toContent(hi.col, origin_x);
        if (end_excl < line_chars) end_excl += 1;
    } else {
        start = 0;
        end_excl = line_chars;
    }

    if (start > line_chars) start = line_chars;
    if (end_excl > line_chars) end_excl = line_chars;
    if (end_excl <= start) return null;
    return .{ .start = start, .end_excl = end_excl };
}

/// The bytes of `line` covering selection columns `[start, end_excl)`. The
/// bounds land on character boundaries, so the result is always whole
/// characters and never a cut-off sequence.
pub fn sliceLine(line: []const u8, start: usize, end_excl: usize) []const u8 {
    if (end_excl <= start) return line[0..0];
    const s = byteAt(line, start);
    const e = byteAt(line, end_excl);
    if (e <= s) return line[0..0];
    return line[s..e];
}

/// Join selected character ranges from a view-line slice (index 0 = `origin_y`).
/// Paint and copy agree when both feed the same anchors through `contentSpan`.
pub fn appendSelected(
    a: Point,
    b: Point,
    origin_x: u16,
    origin_y: u16,
    lines: []const []const u8,
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) !void {
    const lo, const hi = ordered(a, b);
    var wrote_any = false;
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const screen_row: u16 = origin_y + @as(u16, @intCast(i));
        if (screen_row < lo.row or screen_row > hi.row) continue;
        const line = lines[i];
        const span = contentSpan(a, b, screen_row, origin_x, charCount(line)) orelse continue;
        const slice = sliceLine(line, span.start, span.end_excl);
        if (wrote_any) try buf.append(gpa, '\n');
        try buf.appendSlice(gpa, slice);
        wrote_any = true;
    }
}

test "ordered swaps backwards drag" {
    const lo, const hi = ordered(.{ .col = 10, .row = 5 }, .{ .col = 3, .row = 4 });
    try std.testing.expectEqual(@as(u16, 4), lo.row);
    try std.testing.expectEqual(@as(u16, 3), lo.col);
    try std.testing.expectEqual(@as(u16, 5), hi.row);
    try std.testing.expectEqual(@as(u16, 10), hi.col);
}

test "contentSpan single line inclusive" {
    // origin_x=2; drag screen cols 5..8 → content 3..6 inclusive → [3,7) = "defg"
    const span = contentSpan(
        .{ .col = 5, .row = 10 },
        .{ .col = 8, .row = 10 },
        10,
        2,
        20,
    ).?;
    try std.testing.expectEqual(@as(usize, 3), span.start);
    try std.testing.expectEqual(@as(usize, 7), span.end_excl);
    try std.testing.expectEqualStrings("defg", sliceLine("abcdefghij", span.start, span.end_excl));
}

test "contentSpan multi-line" {
    const a = Point{ .col = 5, .row = 10 }; // content col 3
    const b = Point{ .col = 4, .row = 12 }; // content col 2
    const first = contentSpan(a, b, 10, 2, 10).?;
    try std.testing.expectEqual(@as(usize, 3), first.start);
    try std.testing.expectEqual(@as(usize, 10), first.end_excl);
    const mid = contentSpan(a, b, 11, 2, 8).?;
    try std.testing.expectEqual(@as(usize, 0), mid.start);
    try std.testing.expectEqual(@as(usize, 8), mid.end_excl);
    const last = contentSpan(a, b, 12, 2, 10).?;
    try std.testing.expectEqual(@as(usize, 0), last.start);
    try std.testing.expectEqual(@as(usize, 3), last.end_excl);
}

test "contentSpan outside row is null" {
    try std.testing.expect(contentSpan(.{ .col = 1, .row = 1 }, .{ .col = 2, .row = 1 }, 3, 0, 5) == null);
}

test "appendSelected paint-copy agreement" {
    const lines = [_][]const u8{ "abcdefghij", "12345678", "ABCDEFGHIJ" };
    // origin (2,10); anchors content-col 3 on first → content-col 2 on third
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try appendSelected(
        .{ .col = 5, .row = 10 },
        .{ .col = 4, .row = 12 },
        2,
        10,
        &lines,
        &buf,
        std.testing.allocator,
    );
    try std.testing.expectEqualStrings("defghij\n12345678\nABC", buf.items);
}

test "Selection phase highlights only drag and linger" {
    var s = Selection{};
    try std.testing.expect(!s.highlights());
    s.phase = .pressed;
    try std.testing.expect(!s.highlights());
    s.phase = .dragging;
    try std.testing.expect(s.highlights());
    s.phase = .lingering;
    try std.testing.expect(s.highlights());
    s.clear();
    try std.testing.expect(s.phase == .idle);
}

test "selection columns count characters, so a copy is never a cut-off character" {
    // A transcript line can hold anything a remote peer sent. Counting bytes
    // put the highlight in the wrong place and handed the clipboard half a
    // character.
    const line = "café αβγ";
    try std.testing.expectEqual(@as(usize, 8), charCount(line));

    // Columns 0..4 are "café", whose "é" is two bytes.
    try std.testing.expectEqualStrings("café", sliceLine(line, 0, 4));
    try std.testing.expectEqualStrings("αβγ", sliceLine(line, 5, 8));
    try std.testing.expect(std.unicode.utf8ValidateSlice(sliceLine(line, 3, 6)));
}

test "a line of bytes that are not text still walks one column at a time" {
    // Nothing here decodes, so each byte is its own column and the walk always
    // advances.
    const line = "\xff\xfe\xfd";
    try std.testing.expectEqual(@as(usize, 3), charCount(line));
    try std.testing.expectEqualStrings("\xfe", sliceLine(line, 1, 2));
}
