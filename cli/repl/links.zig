//! Link scanning for CapTP lab transcript (ocapn:// and https?://).
const std = @import("std");

pub const Kind = enum { ocapn, https };

pub const Span = struct {
    start: usize,
    len: usize,
    kind: Kind,

    pub fn slice(self: Span, line: []const u8) []const u8 {
        return line[self.start .. self.start + self.len];
    }
};

/// The link covering byte `offset` of `line`, if any.
///
/// Offsets, not screen columns: a scanned span is a byte range, and a caller
/// holding a pointer position converts it first (`select.byteAtCell`). Naming
/// the unit here is what keeps a cell from being compared against a byte.
pub fn atByte(line: []const u8, offset: usize, out: []Span) ?Span {
    const n = scan(line, out);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (offset >= out[i].start and offset < out[i].start + out[i].len) return out[i];
    }
    return null;
}

/// Scan one line for up to `out.len` links. Returns count.
pub fn scan(line: []const u8, out: []Span) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < out.len) {
        if (matchAt(line, i, "ocapn://")) {
            const end = tokenEnd(line, i);
            out[n] = .{ .start = i, .len = end - i, .kind = .ocapn };
            n += 1;
            i = end;
            continue;
        }
        if (matchAt(line, i, "https://") or matchAt(line, i, "http://")) {
            const end = tokenEnd(line, i);
            out[n] = .{ .start = i, .len = end - i, .kind = .https };
            n += 1;
            i = end;
            continue;
        }
        i += 1;
    }
    return n;
}

fn matchAt(line: []const u8, i: usize, prefix: []const u8) bool {
    if (i + prefix.len > line.len) return false;
    return std.mem.eql(u8, line[i .. i + prefix.len], prefix);
}

fn tokenEnd(line: []const u8, start: usize) usize {
    var j = start;
    while (j < line.len) : (j += 1) {
        const c = line[j];
        if (c == ' ' or c == '\t' or c == '\n' or c == '"' or c == '\'' or c == ')' or c == ']' or c == '>') break;
    }
    return j;
}

test "scan ocapn and https" {
    var spans: [4]Span = undefined;
    const n = scan("dial ocapn://tcp.localhost/x see https://example.com/a", &spans);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(spans[0].kind == .ocapn);
    try std.testing.expect(spans[1].kind == .https);
}

test "atByte picks the link under the offset" {
    var spans: [4]Span = undefined;
    const line = "dial ocapn://tcp.localhost/x see https://example.com/a";
    try std.testing.expect(atByte(line, 0, &spans) == null);
    const a = atByte(line, 5, &spans) orelse return error.TestUnexpectedResult;
    try std.testing.expect(a.kind == .ocapn);
    const b = atByte(line, 40, &spans) orelse return error.TestUnexpectedResult;
    try std.testing.expect(b.kind == .https);
}
