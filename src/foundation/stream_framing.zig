//! Pure framing for carrying one message over a byte stream.
//!
//! Byte-stream netlayers wrap each bare codec frame in a canonical Syrup byte
//! string: decimal body length, `:`, then exactly that many body bytes. This
//! module owns only that syntax, and the one question a spill asks of it: what
//! bytes of a chunk complete the frame waiting. It imports no codec, session,
//! engine, or I/O.

const std = @import("std");
const decimal = @import("decimal.zig");
const Spill = @import("spill.zig").Spill;

/// Room for the widest decimal length and its `:`.
pub const prefix_buffer_bytes: usize = decimal.max_width + 1;

pub const Prefix = union(enum) {
    decoded: struct {
        body: []const u8,
        consumed: usize,
    },
    incomplete,
    malformed,
    too_large,
};

/// The one scan of a length prefix. `parsePrefix` and `completeFirstFrame` read
/// it two ways.
const Scan = union(enum) {
    prefix,
    malformed,
    too_large,
    colon: struct { body_start: usize, length: usize },
};

/// Inline so `parsePrefix`, which every frame passes through, builds its
/// answer straight from the scan with no `Scan` value between them.
inline fn scanPrefix(bytes: []const u8, max_body_bytes: usize) Scan {
    if (bytes.len == 0) return .prefix;
    if (bytes[0] < '0' or bytes[0] > '9') return .malformed;

    var length: usize = 0;
    for (bytes, 0..) |byte, i| {
        if (byte == ':') return .{ .colon = .{ .body_start = i + 1, .length = length } };
        if (byte < '0' or byte > '9') return .malformed;
        if (i > 0 and bytes[0] == '0') return .malformed;

        const digit: usize = byte - '0';
        if (length > max_body_bytes / 10 or
            (length == max_body_bytes / 10 and digit > max_body_bytes % 10)) return .too_large;
        length = length * 10 + digit;
    }
    return .prefix;
}

/// Parse one canonical Syrup byte string from the front of `bytes`.
/// The declared body length is bounded before its body is buffered.
pub fn parsePrefix(bytes: []const u8, max_body_bytes: usize) Prefix {
    return switch (scanPrefix(bytes, max_body_bytes)) {
        .prefix => .incomplete,
        .malformed => .malformed,
        .too_large => .too_large,
        .colon => |c| {
            if (bytes.len - c.body_start < c.length) return .incomplete;
            return .{ .decoded = .{
                .body = bytes[c.body_start..][0..c.length],
                .consumed = c.body_start + c.length,
            } };
        },
    };
}

/// How far a chunk completes the frame a spill holds the front of.
pub const Completed = union(enum) {
    /// Every byte of the chunk was absorbed and the frame is still incomplete.
    waiting,
    /// The frame is whole and the first `used` bytes of the chunk belong to
    /// it. `body` borrows the chunk when the spill held the bare prefix and
    /// the chunk carried the whole body, and the spill otherwise, so it is
    /// valid until either changes.
    frame: struct { body: []const u8, used: usize },
    /// The caller's ordinary parse of the spill decides: it already started
    /// with a whole frame, or its prefix is malformed or over the cap. The
    /// payload counts the chunk bytes the spill absorbed finding that out.
    parse: usize,
};

/// Take from `chunk` only the bytes that complete the frame `spill` holds the
/// front of. The spill never absorbs a byte behind that frame, and it absorbs
/// no body byte when it holds the bare prefix and the chunk carries the whole
/// body. An allocation refusal leaves the spill's bytes as they were on entry.
/// The caller records `spill.len` before the call to roll back a later refusal
/// with `Spill.truncate`.
pub fn completeFirstFrame(
    spill: *Spill,
    allocator: std.mem.Allocator,
    chunk: []const u8,
    max_body_bytes: usize,
) std.mem.Allocator.Error!Completed {
    const mark = spill.len;
    errdefer spill.truncate(mark);
    var used: usize = 0;
    var scan = scanPrefix(spill.bytes(), max_body_bytes);
    if (scan == .prefix) {
        if (chunk.len == 0) return .waiting;
        // The scan answers `.prefix` only for a run of digits, and refuses a
        // longer run as over the cap, so `spill.len` is below
        // `prefix_buffer_bytes` here and one reservation holds every prefix
        // byte this call absorbs.
        if (spill.buf.len < prefix_buffer_bytes)
            try spill.ensureUnusedCapacityPrecise(allocator, prefix_buffer_bytes - spill.len);
        while (scan == .prefix) {
            if (used == chunk.len) return .waiting;
            spill.absorbBytesAssumeCapacity(chunk[used..][0..1]);
            used += 1;
            scan = scanPrefix(spill.bytes(), max_body_bytes);
        }
    }
    switch (scan) {
        .prefix => unreachable,
        .malformed, .too_large => return .{ .parse = used },
        .colon => |c| {
            const lacking = c.length -| (spill.len - c.body_start);
            // A whole frame on entry is the caller's to parse. One the chunk
            // just completed has an empty body.
            if (lacking == 0 and used == 0) return .{ .parse = 0 };
            const room = chunk.len - used;
            if (spill.len == c.body_start and room >= lacking) {
                return .{ .frame = .{ .body = chunk[used..][0..lacking], .used = used + lacking } };
            }
            const take = @min(lacking, room);
            // The final size is known once the frame completes, so that growth
            // is exact. A frame still arriving doubles, so one spread over many
            // chunks does not reallocate on each.
            if (take == lacking) {
                try spill.absorbBytesPrecise(allocator, chunk[used..][0..take]);
            } else {
                try spill.absorbBytes(allocator, chunk[used..][0..take]);
            }
            used += take;
            if (take < lacking) return .waiting;
            return .{ .frame = .{ .body = spill.bytes()[c.body_start..], .used = used } };
        },
    }
}

/// Render the canonical prefix for a body of `length` bytes into caller-owned
/// storage. The returned slice remains valid while `buf` does.
pub fn renderPrefix(buf: *[prefix_buffer_bytes]u8, length: usize) []const u8 {
    const digits = decimal.width(length);
    decimal.fill(buf[0..digits], length);
    buf[digits] = ':';
    return buf[0 .. digits + 1];
}
