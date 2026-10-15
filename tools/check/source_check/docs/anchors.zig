//! Heading anchors in repository Markdown, named the way GitHub names them,
//! so a link to `doc.md#a-heading` is held to a heading that exists.

const std = @import("std");

/// Whether `fragment` names a heading of `contents` or an explicit
/// `id`/`name` anchor in it. A repeated heading's later anchors carry `-1`,
/// `-2` and so on.
pub fn has(contents: []const u8, fragment: []const u8) bool {
    if (fragment.len == 0) return true;
    if (explicitAnchor(contents, fragment)) return true;
    var buf: [256]u8 = undefined;
    var in_fence = false;
    var in_header = std.mem.startsWith(u8, contents, "---\n");
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (in_header) {
            if (line_no > 1 and std.mem.eql(u8, trimmed, "---")) in_header = false;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = !in_fence;
            continue;
        }
        if (in_fence) continue;
        const text = headingText(trimmed) orelse continue;
        const s = slug(text, &buf);
        if (std.mem.eql(u8, s, fragment)) return true;
        // A later twin of an earlier heading: GitHub appends `-<n>`.
        if (std.mem.startsWith(u8, fragment, s) and fragment.len > s.len + 1 and fragment[s.len] == '-') {
            // tolerant: a non-numeric suffix names no twin of this heading, and the scan moves on to the next heading.
            if (std.fmt.parseInt(usize, fragment[s.len + 1 ..], 10)) |_| return true else |_| {}
        }
    }
    return false;
}

fn headingText(line: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < line.len and line[i] == '#') i += 1;
    if (i == 0 or i > 6 or i >= line.len or line[i] != ' ') return null;
    return std.mem.trim(u8, line[i + 1 ..], " \t#");
}

/// GitHub's heading slug: lowercase, spaces to `-`, and every character that
/// is not a letter, digit, `-` or `_` dropped. Markdown link targets and code
/// marks drop with it, and their text stays.
fn slug(text: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < buf.len) : (i += 1) {
        const c = text[i];
        if (c == ']' and i + 1 < text.len and text[i + 1] == '(') {
            i = std.mem.indexOfScalarPos(u8, text, i, ')') orelse text.len;
            continue;
        }
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            buf[n] = std.ascii.toLower(c);
            n += 1;
        } else if (c == ' ') {
            buf[n] = '-';
            n += 1;
        } else if (c >= 0x80) {
            buf[n] = c;
            n += 1;
        }
    }
    return buf[0..n];
}

fn explicitAnchor(contents: []const u8, fragment: []const u8) bool {
    inline for (.{ "id=\"", "name=\"" }) |attr| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, contents, at, attr)) |i| {
            const start = i + attr.len;
            const end = std.mem.indexOfScalarPos(u8, contents, start, '"') orelse break;
            if (std.mem.eql(u8, contents[start..end], fragment)) return true;
            at = end;
        }
    }
    return false;
}

test "a fragment names a heading the way GitHub slugs it" {
    const doc =
        \\---
        \\description: # Not a heading
        \\---
        \\# The `Host` API, in short
        \\## Errors climb to the tier that can act
        \\## Notes
        \\## Notes
        \\```
        \\## Fenced
        \\```
        \\## See [ADR-0115](decisions/adr/x.md)
        \\<a id="kept-anchor"></a>
        \\
    ;
    try std.testing.expect(has(doc, "the-host-api-in-short"));
    try std.testing.expect(has(doc, "errors-climb-to-the-tier-that-can-act"));
    try std.testing.expect(has(doc, "notes-1"));
    try std.testing.expect(has(doc, "see-adr-0115"));
    try std.testing.expect(has(doc, "kept-anchor"));
    try std.testing.expect(!has(doc, "fenced"));
    try std.testing.expect(!has(doc, "not-a-heading"));
    try std.testing.expect(!has(doc, "errors"));
}
