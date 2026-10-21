//! The unconsumed bytes of one inbound stream.
//!
//! A CapTP stream arrives in chunks that do not line up with frame boundaries,
//! so at any moment a reader may hold the front of a frame whose rest has not
//! arrived. Those bytes have to wait somewhere contiguous, because the one
//! parser decodes a prefix and needs it whole. That waiting room is a `Spill`.
//!
//! It lives in `foundation` because every tier that reads a stream needs one and
//! the tiers cannot reach each other: `net` folds a parser over a live byte
//! stream, while `driver_core` is byte-fed and imports no transport at all.
//! Each would otherwise keep its own copy of this buffer, and the two would
//! drift. This is the one copy, and being bytes and nothing else (no reader, no codec, no
//! session) is what lets both tiers share it.
//!
//! What it costs is named in ADR-0012: the steady state is inactive and
//! allocation-free, and a stream that straddles a boundary pays one bounded copy
//! into the spill and decodes from there, so per-connection memory tracks the
//! caller's read size rather than `max_frame_bytes`.

const std = @import("std");

/// A contiguous, growable holding area for stream bytes that have arrived but
/// not yet been consumed as a whole frame. status-allow: pending state or quoted runtime label
///
/// The lifecycle is: `absorbBytes` what could not be consumed, read the waiting
/// prefix back with `bytes`, and `consume` the frames the parser delimits out of
/// it. A caller holding its own borrowed bytes uses the spill only while a frame
/// straddles: `isActive` is how it decides which of the two is the prefix to
/// parse, and the spill absorbs the borrowed bytes when it takes over, so the
/// prefix stays contiguous (moving the bytes does not move the front of the
/// frame).
///
/// Boundedness is not this type's to enforce. It grows to hold what it is
/// given, and the caller bounds that: the envelope's declared length is
/// checked against `max_frame_bytes` before its body is allowed to accumulate
/// (ADR-0012), so a prefix that is still incomplete is under the cap.
pub const Spill = struct {
    buf: []u8 = &.{},
    len: usize = 0,

    /// Whether bytes are waiting here. While active, the spill, not the
    /// caller's own buffer, is the prefix the one parser decodes.
    pub fn isActive(self: *const Spill) bool {
        return self.len > 0;
    }

    /// The contiguous waiting prefix.
    pub fn bytes(self: *const Spill) []const u8 {
        return self.buf[0..self.len];
    }

    /// Copy `incoming` onto the end of what is waiting. `incoming` is borrowed
    /// for the call, so a caller may hand over a recycled pool buffer or a
    /// transient chunk. Grows geometrically. The caller's own cap check is what
    /// bounds the growth.
    pub fn absorbBytes(self: *Spill, allocator: std.mem.Allocator, incoming: []const u8) std.mem.Allocator.Error!void {
        if (incoming.len == 0) return;
        const needed = std.math.add(usize, self.len, incoming.len) catch return error.OutOfMemory;
        if (self.buf.len < needed) {
            // Double, or take exactly what is asked when that is larger. No
            // fixed floor: the tiers arrive with very different first absorbs.
            // A stream reader hands over a whole read buffer at once and lands
            // large on the first try, while a byte-fed host straddles a chunk
            // boundary by a handful of bytes and would otherwise pay a
            // kilobyte-scale floor on every connection that ever straddled,
            // which is most of them, on that tier.
            self.buf = try allocator.realloc(self.buf, @max(self.buf.len *| 2, needed));
        }
        self.absorbBytesAssumeCapacity(incoming);
    }

    /// The exact-growth sibling for a caller whose retained bytes are a hard
    /// per-connection budget. Exact growth keeps allocator capacity from
    /// silently exceeding the logical ceiling through geometric doubling.
    pub fn absorbBytesPrecise(self: *Spill, allocator: std.mem.Allocator, incoming: []const u8) std.mem.Allocator.Error!void {
        if (incoming.len == 0) return;
        try self.ensureUnusedCapacityPrecise(allocator, incoming.len);
        self.absorbBytesAssumeCapacity(incoming);
    }

    /// Reserve exact room for one borrowed append without committing any of
    /// its bytes. A caller with another fallible preflight can reserve both
    /// resources first, then use `absorbBytesAssumeCapacity` as one atomic
    /// ownership transfer.
    pub fn ensureUnusedCapacityPrecise(self: *Spill, allocator: std.mem.Allocator, incoming_len: usize) std.mem.Allocator.Error!void {
        const needed = std.math.add(usize, self.len, incoming_len) catch return error.OutOfMemory;
        if (self.buf.len < needed) self.buf = try allocator.realloc(self.buf, needed);
    }

    /// Commit bytes after `ensureUnusedCapacityPrecise` succeeds.
    pub fn absorbBytesAssumeCapacity(self: *Spill, incoming: []const u8) void {
        std.debug.assert(incoming.len <= self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..incoming.len], incoming);
        self.len += incoming.len;
    }

    /// Drop `n` consumed bytes (one decoded frame) off the front. Leftover bytes
    /// (the start of the next frame), compact forward and keep the spill
    /// active. Consuming zero bytes from an active spill leaves it untouched.
    ///
    /// `retain` is how much capacity a fully drained spill keeps, and it is the
    /// one place the two tiers legitimately differ. A reader whose spill
    /// activates only for a frame too large for its read buffer passes `0`: that
    /// is rare, so freeing outright returns the burst and the next one pays a
    /// fresh allocation. A byte-fed consumer straddles a boundary on ordinary
    /// traffic, so it names a steady size and keeps that much, and only a burst
    /// above it is returned. Passing the wrong one is a footprint decision, not
    /// a correctness one, which is why it is a per-call number rather than a
    /// field every connection would carry.
    pub fn consume(self: *Spill, allocator: std.mem.Allocator, n: usize, retain: usize) void {
        std.debug.assert(n <= self.len);
        const remaining = self.len - n;
        if (remaining > 0) {
            // An incomplete frame consumes nothing. Copying that prefix onto
            // itself on every fragment makes assembly quadratic in its size.
            if (n == 0) return;
            std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[n..][0..remaining]);
            self.len = remaining;
            return;
        }
        self.len = 0;
        if (self.buf.len <= retain) return;
        if (retain == 0) {
            allocator.free(self.buf);
            self.buf = &.{};
            return;
        }
        if (allocator.realloc(self.buf, retain)) |shrunk| {
            self.buf = shrunk;
        } else |_| {
            // tolerant: the larger buffer stays valid, so the failed shrink loses only memory the next full drain returns.
        }
    }

    pub fn deinit(self: *Spill, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
        self.* = .{};
    }
};
