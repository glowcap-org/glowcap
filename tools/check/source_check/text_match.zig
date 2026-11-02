//! Text matching over source contents: required-text and presence checks on a
//! file, whitespace-insensitive and whole-symbol matching, brace-block
//! extraction, and leading-integer parsing.

const std = @import("std");
const violation_log = @import("violation_log.zig");

pub fn expectFileContains(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    violations: *std.ArrayList([]const u8),
    path: []const u8,
    needles: []const []const u8,
) !void {
    const contents = root.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| {
        try violation_log.appendViolation(gpa, violations, "{s}: failed to read with {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(contents);

    for (needles) |needle| {
        if (std.mem.indexOf(u8, contents, needle) == null) {
            try violation_log.appendViolation(gpa, violations, "{s}: missing required text `{s}`", .{ path, needle });
        }
    }
}

pub fn fileContains(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: std.Io.Dir,
    path: []const u8,
    needle: []const u8,
) !bool {
    const contents = root.readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return false;
    defer gpa.free(contents);
    return std.mem.indexOf(u8, contents, needle) != null;
}

/// Match a source fragment while ignoring formatter-controlled ASCII
/// whitespace. Use this for declaration/call shapes whose tokens are the
/// contract and whose line wrapping is not.
pub fn containsIgnoringWhitespace(contents: []const u8, fragment: []const u8) bool {
    var start: usize = 0;
    while (start < contents.len) : (start += 1) {
        var source = start;
        var expected: usize = 0;
        while (expected < fragment.len) {
            while (expected < fragment.len and std.ascii.isWhitespace(fragment[expected])) expected += 1;
            while (source < contents.len and std.ascii.isWhitespace(contents[source])) source += 1;
            if (expected == fragment.len) return true;
            if (source == contents.len or contents[source] != fragment[expected]) break;
            source += 1;
            expected += 1;
        }
        while (expected < fragment.len and std.ascii.isWhitespace(fragment[expected])) expected += 1;
        if (expected == fragment.len) return true;
    }
    return fragment.len == 0;
}

test "containsIgnoringWhitespace follows tokens across formatter wrapping" {
    try std.testing.expect(containsIgnoringWhitespace(
        "call(\n    first,\n    second,\n);",
        "call(first, second,);",
    ));
    try std.testing.expect(!containsIgnoringWhitespace(
        "call(first, replacement);",
        "call(first, second);",
    ));
}

fn parseLeadingInt(s: []const u8) ?i64 {
    var i: usize = 0;
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    }
    const start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == start) return null;
    const mag = std.fmt.parseInt(i64, s[start..i], 10) catch return null;
    return if (neg) -mag else mag;
}

pub fn firstIntIn(s: []const u8) ?i64 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '-' or (s[i] >= '0' and s[i] <= '9')) return parseLeadingInt(s[i..]);
    }
    return null;
}

/// Find the `{ ... }` block opened by the `{`-terminated `marker`, matching
/// braces so a nested struct literal inside the block cannot close it early.
/// Returns the interior (excluding the outer braces), or `null` when the
/// marker is absent or its brace never closes.
pub fn extractBraceBlock(text: []const u8, marker: []const u8) ?[]const u8 {
    std.debug.assert(std.mem.endsWith(u8, marker, "{"));
    const start = std.mem.indexOf(u8, text, marker) orelse return null;
    const open = start + marker.len - 1;
    var depth: usize = 1;
    var i = open + 1;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return text[open + 1 .. i];
            },
            else => {},
        }
    }
    return null;
}

/// Whether `haystack` contains `needle` as a whole symbol rather than as the
/// prefix of a longer one. The bans and presence checks above name FFI symbols
/// and call spellings, so a plain substring match reads
/// `glowcap_host_session_published_ref` as a use of
/// `glowcap_host_session_publish` and refuses a sibling verb that never broke the
/// rule. A required needle has the same defect facing the other way: a longer
/// sibling would satisfy it. Boundaries are only required at an end whose own
/// character is part of an identifier, so a needle spelled with trailing
/// punctuation (`"return sendLocal("`) still matches.
///
/// A needle that begins with an identifier character no longer matches mid- status-allow: lifecycle transition
/// identifier, so `"tell_local("` is not found inside `"run_tell_local("`. Spell
/// such a needle with whatever precedes it when that is what you meant.
pub fn containsAsSymbol(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, from, needle)) |at| {
        from = at + 1;
        if (isIdentChar(needle[0]) and at > 0 and isIdentChar(haystack[at - 1])) continue;
        const end = at + needle.len;
        if (isIdentChar(needle[needle.len - 1]) and end < haystack.len and isIdentChar(haystack[end])) continue;
        return true;
    }
    return false;
}

/// Whether `byte` continues a C identifier, the boundary every symbol scan over
/// header text stops at.
pub fn isIdentChar(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}
