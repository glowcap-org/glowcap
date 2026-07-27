//! Shared JSON / stdout / stderr helpers for CLI fronts.
const std = @import("std");
const log = @import("operability/log.zig");

/// Write `s` as a JSON string.
///
/// Most of what lands here comes off the wire, and a partner is free to send
/// bytes that are not UTF-8 at all. JSON strings must be valid UTF-8, so
/// copying those through produced a response the client could not parse: one
/// odd byte in a remote object's reply broke the whole message rather than the
/// one field. Each invalid sequence becomes the replacement character instead,
/// which keeps the response parseable and shows the reader where it happened.
pub fn writeJsonString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c >= 0x80) {
            // A multi-byte character, or a byte that is not text at all. Either
            // way `characterLen` says how far to move.
            const len = characterLen(s[i..]);
            if (len == 1) {
                try buf.appendSlice(gpa, "\u{FFFD}");
            } else {
                try buf.appendSlice(gpa, s[i .. i + len]);
            }
            i += len;
            continue;
        }
        i += 1;
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            else => if (c < 0x20) {
                var hex: [6]u8 = undefined;
                try buf.appendSlice(gpa, try std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{c}));
            } else try buf.append(gpa, c),
        }
    }
    try buf.append(gpa, '"');
}

/// How many bytes the character starting at `rest[0]` occupies.
///
/// A byte that begins nothing valid counts as one, so a walk over bytes that
/// are not text always moves forward and picks up again at the next byte. This
/// is the CLI's one answer to "where does this character end": the JSON escaper
/// above and the transcript selection in `repl/select.zig` both ask it, and if
/// they disagreed the highlight would stop covering what the JSON says.
pub fn characterLen(rest: []const u8) usize {
    const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch return 1;
    if (len > rest.len) return 1;
    _ = std.unicode.utf8Decode(rest[0..len]) catch return 1;
    return len;
}

pub fn writeStdout(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

pub fn writeStderr(io: std.Io, bytes: []const u8) !void {
    // CapTP lab TUI diverts stderr diagnostics into the transcript.
    if (log.hasDivert()) {
        log.writeMsg(io, bytes);
        return;
    }
    try std.Io.File.stderr().writeStreamingAll(io, bytes);
}
