//! Cell-range selection math for the CapTP lab transcript (pure).
//!
//! Anchors are screen cells, and content columns are cells too, relative to the
//! transcript origin (`screen_col - origin_x`). A transcript line can hold
//! anything a remote peer sent, so a column is neither a byte nor a character:
//! it is one cell of what the terminal drew, and a character the terminal draws
//! two cells wide, such as most CJK text, spends two columns.
//!
//! This module measures nothing itself. How wide a character is drawn is the
//! terminal's answer, so the caller passes a `CellWidth`: the REPL's render
//! layer hands over the same measurement vaxis places cells with, and a test
//! hands over a table. That keeps the arithmetic here pure.
//!
//! Span bounds land on character boundaries. A bound that falls inside a
//! character takes the whole character, so a highlight covers the glyphs the
//! reader sees and a copy is never half a character.
const std = @import("std");
const argv = @import("../argv.zig");

/// Where a character ends. Shared with the JSON escaper so a highlight always
/// covers exactly what a copy would produce.
const charLen = argv.characterLen;

/// How many cells the terminal draws a character in.
///
/// `ctx` is whatever the measurement needs (the live screen whose width method
/// vaxis honors, or a test's fixed table) and is null for a measurement that
/// needs nothing.
pub const CellWidth = struct {
    ctx: ?*const anyopaque = null,
    measure: *const fn (ctx: ?*const anyopaque, character: []const u8) u16,

    pub fn of(self: CellWidth, character: []const u8) usize {
        return self.measure(self.ctx, character);
    }
};

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

/// How many cells `line` occupies. This is the line's length in selection
/// columns.
pub fn cellCount(line: []const u8, width: CellWidth) usize {
    var cells: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const n = charLen(line[i..]);
        cells += width.of(line[i..][0..n]);
        i += n;
    }
    return cells;
}

/// A drag that crosses a row whole has no end column of its own. The line's own
/// end stops it.
const to_line_end = std.math.maxInt(usize);

/// What a column range covers, in bytes for a copy and in cells for a paint.
const Covered = struct {
    start_byte: usize,
    end_byte: usize,
    start_cell: usize,
    end_cell: usize,
};

/// The characters of `line` whose cells overlap `[start, end_excl)`, or null
/// when the range covers no character of it.
fn covered(line: []const u8, start: usize, end_excl: usize, width: CellWidth) ?Covered {
    if (end_excl <= start) return null;
    var found: ?Covered = null;
    var cell: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        const n = charLen(line[i..]);
        const next_cell = cell + width.of(line[i..][0..n]);
        // A character is in or out whole, so a bound inside a wide character
        // takes the character.
        if (cell < end_excl and next_cell > start) {
            if (found) |*c| {
                c.end_byte = i + n;
                c.end_cell = next_cell;
            } else {
                found = .{
                    .start_byte = i,
                    .end_byte = i + n,
                    .start_cell = cell,
                    .end_cell = next_cell,
                };
            }
        }
        cell = next_cell;
        i += n;
    }
    var c = found orelse return null;
    // A combining mark spends no cell of its own, so it rides with the
    // character it follows. Stopping short of one hands the clipboard a base
    // character with its accent stripped.
    while (c.end_byte < line.len) {
        const n = charLen(line[c.end_byte..]);
        if (width.of(line[c.end_byte..][0..n]) != 0) break;
        c.end_byte += n;
    }
    return c;
}

fn toContent(screen_col: u16, origin_x: u16) usize {
    if (screen_col <= origin_x) return 0;
    return @as(usize, screen_col - origin_x);
}

/// Content-column span on `screen_row`, or null if that row is outside the
/// selection or the drag covered no character of it. The returned columns are
/// snapped to character boundaries, and a drag past the end of a line stops at
/// the line's own end.
pub fn contentSpan(
    a: Point,
    b: Point,
    screen_row: u16,
    origin_x: u16,
    line: []const u8,
    width: CellWidth,
) ?struct { start: usize, end_excl: usize } {
    const lo, const hi = ordered(a, b);
    if (screen_row < lo.row or screen_row > hi.row) return null;

    var start: usize = 0;
    var end_excl: usize = to_line_end;
    if (lo.row == hi.row) {
        start = toContent(lo.col, origin_x);
        // Inclusive end cell: drag onto a character includes it.
        end_excl = toContent(hi.col, origin_x) + 1;
    } else if (screen_row == lo.row) {
        start = toContent(lo.col, origin_x);
    } else if (screen_row == hi.row) {
        end_excl = toContent(hi.col, origin_x) + 1;
    }

    const c = covered(line, start, end_excl, width) orelse return null;
    return .{ .start = c.start_cell, .end_excl = c.end_cell };
}

/// Where the character `line` draws at column `col` begins, or null when that
/// column is past the end of the line.
///
/// Anything that has to line a screen column up with an offset into the line
/// (hit-testing the link the paint underlined) reads the column through here, so
/// the pointer lands on the character the reader sees under it.
pub fn byteAtCell(line: []const u8, col: usize, width: CellWidth) ?usize {
    const c = covered(line, col, col + 1, width) orelse return null;
    return c.start_byte;
}

/// The bytes of `line` drawn in selection columns `[start, end_excl)`. The
/// bounds land on character boundaries, so the result is always whole
/// characters and never a cut-off sequence.
pub fn sliceLine(line: []const u8, start: usize, end_excl: usize, width: CellWidth) []const u8 {
    const c = covered(line, start, end_excl, width) orelse return line[0..0];
    return line[c.start_byte..c.end_byte];
}

/// Join the selected text from a view-line slice (index 0 = `origin_y`).
/// Paint and copy agree when both feed the same anchors and the same
/// `CellWidth` through `contentSpan`.
pub fn appendSelected(
    a: Point,
    b: Point,
    origin_x: u16,
    origin_y: u16,
    lines: []const []const u8,
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    width: CellWidth,
) !void {
    const lo, const hi = ordered(a, b);
    var wrote_any = false;
    var i: usize = 0;
    while (i < lines.len) : (i += 1) {
        const screen_row: u16 = origin_y + @as(u16, @intCast(i));
        if (screen_row < lo.row or screen_row > hi.row) continue;
        const line = lines[i];
        const span = contentSpan(a, b, screen_row, origin_x, line, width) orelse continue;
        const slice = sliceLine(line, span.start, span.end_excl, width);
        if (wrote_any) try buf.append(gpa, '\n');
        try buf.appendSlice(gpa, slice);
        wrote_any = true;
    }
}

/// Every character one cell, the shape a terminal draws plain Latin text in.
fn oneCell(_: ?*const anyopaque, _: []const u8) u16 {
    return 1;
}

const mono = CellWidth{ .measure = oneCell };

/// Stand-in for the terminal's width tables: the graphemes these tests draw
/// wide, and a combining mark that draws no cell of its own.
fn tabled(_: ?*const anyopaque, character: []const u8) u16 {
    const wide = [_][]const u8{ "漢", "字", "🙂" };
    for (wide) |g| {
        if (std.mem.eql(u8, g, character)) return 2;
    }
    if (std.mem.eql(u8, "\u{0301}", character)) return 0;
    return 1;
}

const table = CellWidth{ .measure = tabled };

test "ordered swaps backwards drag" {
    const lo, const hi = ordered(.{ .col = 10, .row = 5 }, .{ .col = 3, .row = 4 });
    try std.testing.expectEqual(@as(u16, 4), lo.row);
    try std.testing.expectEqual(@as(u16, 3), lo.col);
    try std.testing.expectEqual(@as(u16, 5), hi.row);
    try std.testing.expectEqual(@as(u16, 10), hi.col);
}

test "contentSpan single line inclusive" {
    // origin_x=2; drag screen cols 5..8 → content 3..6 inclusive → [3,7) = "defg"
    const line = "abcdefghij";
    const span = contentSpan(
        .{ .col = 5, .row = 10 },
        .{ .col = 8, .row = 10 },
        10,
        2,
        line,
        mono,
    ).?;
    try std.testing.expectEqual(@as(usize, 3), span.start);
    try std.testing.expectEqual(@as(usize, 7), span.end_excl);
    try std.testing.expectEqualStrings("defg", sliceLine(line, span.start, span.end_excl, mono));
}

test "contentSpan multi-line" {
    const a = Point{ .col = 5, .row = 10 }; // content col 3
    const b = Point{ .col = 4, .row = 12 }; // content col 2
    const first = contentSpan(a, b, 10, 2, "abcdefghij", mono).?;
    try std.testing.expectEqual(@as(usize, 3), first.start);
    try std.testing.expectEqual(@as(usize, 10), first.end_excl);
    const mid = contentSpan(a, b, 11, 2, "12345678", mono).?;
    try std.testing.expectEqual(@as(usize, 0), mid.start);
    try std.testing.expectEqual(@as(usize, 8), mid.end_excl);
    const last = contentSpan(a, b, 12, 2, "ABCDEFGHIJ", mono).?;
    try std.testing.expectEqual(@as(usize, 0), last.start);
    try std.testing.expectEqual(@as(usize, 3), last.end_excl);
}

test "contentSpan outside row is null" {
    try std.testing.expect(contentSpan(.{ .col = 1, .row = 1 }, .{ .col = 2, .row = 1 }, 3, 0, "abcde", mono) == null);
}

test "contentSpan past the end of a line stops at the line" {
    const span = contentSpan(
        .{ .col = 2, .row = 4 },
        .{ .col = 40, .row = 4 },
        4,
        2,
        "abc",
        mono,
    ).?;
    try std.testing.expectEqual(@as(usize, 0), span.start);
    try std.testing.expectEqual(@as(usize, 3), span.end_excl);
    // A drag that starts past the end selects nothing on that line.
    try std.testing.expect(contentSpan(
        .{ .col = 20, .row = 4 },
        .{ .col = 40, .row = 4 },
        4,
        2,
        "abc",
        mono,
    ) == null);
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
        mono,
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

test "selection bounds land on characters, so a copy is never a cut-off character" {
    // A transcript line can hold anything a remote peer sent. Counting bytes
    // put the highlight in the wrong place and handed the clipboard half a
    // character.
    const line = "café αβγ";
    try std.testing.expectEqual(@as(usize, 8), cellCount(line, mono));

    // Columns 0..4 are "café", whose "é" is two bytes.
    try std.testing.expectEqualStrings("café", sliceLine(line, 0, 4, mono));
    try std.testing.expectEqualStrings("αβγ", sliceLine(line, 5, 8, mono));
    try std.testing.expect(std.unicode.utf8ValidateSlice(sliceLine(line, 3, 6, mono)));
}

test "a line of bytes that are not text still walks one character at a time" {
    // Nothing here decodes, so each byte is its own character and the walk
    // always advances.
    const line = "\xff\xfe\xfd";
    try std.testing.expectEqual(@as(usize, 3), cellCount(line, mono));
    try std.testing.expectEqualStrings("\xfe", sliceLine(line, 1, 2, mono));
}

test "a character the terminal draws wide spends two columns" {
    const line = "a漢字b";
    try std.testing.expectEqual(@as(usize, 6), cellCount(line, table));
    // Columns: a=0, 漢=1..3, 字=3..5, b=5.
    try std.testing.expectEqualStrings("a", sliceLine(line, 0, 1, table));
    try std.testing.expectEqualStrings("漢", sliceLine(line, 1, 3, table));
    try std.testing.expectEqualStrings("b", sliceLine(line, 5, 6, table));
    // Column 3 is the second cell of 字; measured one column per character it
    // would be "b", which slides the highlight left of the glyph.
    try std.testing.expectEqualStrings("字", sliceLine(line, 3, 4, table));
    try std.testing.expectEqualStrings("b", sliceLine(line, 3, 4, mono));
}

test "a drag landing inside a wide character takes the whole glyph" {
    const line = "a漢b";
    // origin_x=2; press and release on the second cell of 漢 (screen col 4).
    const span = contentSpan(
        .{ .col = 4, .row = 7 },
        .{ .col = 4, .row = 7 },
        7,
        2,
        line,
        table,
    ).?;
    // The highlight starts where the glyph starts, not where the pointer did.
    try std.testing.expectEqual(@as(usize, 1), span.start);
    try std.testing.expectEqual(@as(usize, 3), span.end_excl);
    try std.testing.expectEqualStrings("漢", sliceLine(line, span.start, span.end_excl, table));
}

test "a drag over wide text copies the glyphs the reader highlighted" {
    const lines = [_][]const u8{ "漢字🙂", "abc" };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    // origin (0,3); from the first cell of 字 through the second cell of "b".
    try appendSelected(
        .{ .col = 2, .row = 3 },
        .{ .col = 1, .row = 4 },
        0,
        3,
        &lines,
        &buf,
        std.testing.allocator,
        table,
    );
    try std.testing.expectEqualStrings("字🙂\nab", buf.items);
}

test "a combining mark rides with the character it follows" {
    // The mark draws no cell of its own, so the accented "e" is one column, and
    // a copy of that column keeps the accent.
    const line = "e\u{0301}f";
    try std.testing.expectEqual(@as(usize, 2), cellCount(line, table));
    try std.testing.expectEqualStrings("e\u{0301}", sliceLine(line, 0, 1, table));
    try std.testing.expectEqualStrings("f", sliceLine(line, 1, 2, table));
}
