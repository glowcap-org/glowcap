//! Deadline-guarded waits for multi-thread driver tests.
//!
//! An undeadlined `while (!flag.load) sleep(2ms)` is a silent hang: a wedged
//! accept or a malformed give leaves the suite parked with no location and
//! no failure. Every wait here fails loud with `error.WaitTimedOut` past a
//! generous wall-clock deadline so a real hang surfaces in seconds, not as a
//! ten-minute `/proc/wchan` investigation.

const std = @import("std");

pub const Error = error{WaitTimedOut};

/// Generous default for multi-thread driver tests: slow CI stays quiet; a
/// real hang fails within low tens of seconds with a located error.
pub const default_deadline_ms: u64 = 15_000;

/// Spin until `pred(ctx)` is true, or fail with `error.WaitTimedOut`.
pub fn until(
    io: std.Io,
    deadline_ms: u64,
    ctx: anytype,
    comptime pred: *const fn (@TypeOf(ctx)) bool,
) Error!void {
    const deadline = deadlineAfter(io, deadline_ms);
    while (!pred(ctx)) {
        if (expired(io, deadline)) return error.WaitTimedOut;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
    }
}

/// Convenience for the common `while (!flag.load(.acquire)) sleep` shape.
pub fn untilFlag(io: std.Io, deadline_ms: u64, flag: *const std.atomic.Value(bool)) Error!void {
    try until(io, deadline_ms, flag, struct {
        fn pred(f: *const std.atomic.Value(bool)) bool {
            return f.load(.acquire);
        }
    }.pred);
}

/// Wall-clock deadline for a pump loop that already blocks briefly on I/O:
/// stamp once, then check `expired` between pumps.
pub fn deadlineAfter(io: std.Io, deadline_ms: u64) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromMilliseconds(@intCast(deadline_ms)),
        .clock = .real,
    });
}

pub fn expired(io: std.Io, deadline: std.Io.Clock.Timestamp) bool {
    return std.Io.Clock.Timestamp.now(io, .real).compare(.gte, deadline);
}

/// Atomic flag with a deadline-guarded wait.
pub const Signal = struct {
    flag: std.atomic.Value(bool) = .init(false),

    pub fn set(self: *Signal) void {
        self.flag.store(true, .release);
    }

    pub fn isSet(self: *const Signal) bool {
        return self.flag.load(.acquire);
    }

    pub fn wait(self: *const Signal, io: std.Io, deadline_ms: u64) Error!void {
        try untilFlag(io, deadline_ms, &self.flag);
    }
};

/// One published bound address, written once by its owner and spin-read
/// (with acquire/release ordering) by whoever needs it. Replaces the
/// hand-rolled copies that previously lived in each multi-thread driver test.
pub const PublishedAddr = struct {
    buf: [80]u8 = undefined,
    len: std.atomic.Value(usize) = .init(0),

    pub fn publish(self: *PublishedAddr, text: []const u8) void {
        std.debug.assert(text.len <= self.buf.len);
        @memcpy(self.buf[0..text.len], text);
        self.len.store(text.len, .release);
    }

    pub fn get(self: *const PublishedAddr) ?[]const u8 {
        const n = self.len.load(.acquire);
        if (n == 0) return null;
        return self.buf[0..n];
    }

    pub fn await_(self: *const PublishedAddr, io: std.Io, deadline_ms: u64) Error![]const u8 {
        try until(io, deadline_ms, self, struct {
            fn pred(s: *const PublishedAddr) bool {
                return s.get() != null;
            }
        }.pred);
        return self.get().?;
    }
};
