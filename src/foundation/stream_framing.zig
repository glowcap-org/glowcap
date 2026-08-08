//! Pure framing for carrying one message over a byte stream.
//!
//! Byte-stream netlayers wrap each bare codec frame in a canonical Syrup byte
//! string: decimal body length, `:`, then exactly that many body bytes. This
//! module owns only that syntax. It imports no codec, session, engine, or I/O.

const std = @import("std");

/// Large enough for the decimal representation of any `usize`, plus `:`.
pub const prefix_buffer_bytes: usize = 32;

pub const Prefix = union(enum) {
    decoded: struct {
        body: []const u8,
        consumed: usize,
    },
    incomplete,
    malformed,
    too_large,
};

/// Parse one canonical Syrup byte string from the front of `bytes`.
/// The declared body length is bounded before its body is buffered.
pub fn parsePrefix(bytes: []const u8, max_body_bytes: usize) Prefix {
    if (bytes.len == 0) return .incomplete;
    if (bytes[0] < '0' or bytes[0] > '9') return .malformed;

    var length: usize = 0;
    for (bytes, 0..) |byte, i| {
        if (byte == ':') {
            const body_start = i + 1;
            if (bytes.len - body_start < length) return .incomplete;
            return .{ .decoded = .{
                .body = bytes[body_start..][0..length],
                .consumed = body_start + length,
            } };
        }
        if (byte < '0' or byte > '9') return .malformed;
        if (i > 0 and bytes[0] == '0') return .malformed;

        const digit: usize = byte - '0';
        if (length > max_body_bytes / 10 or
            (length == max_body_bytes / 10 and digit > max_body_bytes % 10)) return .too_large;
        length = length * 10 + digit;
    }
    return .incomplete;
}

/// Render the canonical prefix for a body of `length` bytes into caller-owned
/// storage. The returned slice remains valid while `buf` does.
pub fn renderPrefix(buf: *[prefix_buffer_bytes]u8, length: usize) []const u8 {
    return std.fmt.bufPrint(buf, "{d}:", .{length}) catch unreachable;
}
