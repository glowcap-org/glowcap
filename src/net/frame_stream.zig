//! Moving whole frames over a `std.Io` byte stream, without a peer involved.
//!
//! A `Connection` reads frames straight into a `engine.Peer` and applies them.
//! A `FrameStream` sits one level lower: read one whole frame off the wire as an
//! owned `Frame`, or write one, and that's it. It's what the host-driven C ABI
//! endpoint is built on. There, the C host owns the peer and runs the loop itself
//! (read a frame, feed it, step, take the outbound, write it), so all this layer
//! does is frame the inbound bytes. It applies no authority of its own.
//!
//! The framing is still the one parser: the active codec's decoder marks where a
//! frame ends (`codec.dispatch.decodePrefix`). And the edge cases the codec can't
//! decide on its own — a clean EOF versus one in the middle of a frame, and a
//! frame that outgrows the read buffer — are settled in a single place
//! (`fillStep` / `fillThroughSpill` / `Spill`), which the `Connection` pump
//! shares too so the two can't drift apart. The read buffer stays small; an
//! admissible frame larger than it accumulates once in the bounded `Spill` and
//! decodes from there, so per-connection memory does not scale with
//! `max_frame_bytes`.
//!
//! The frame operations themselves are free functions over a type-erased reader
//! and writer (`readFrameFrom` / `writeFrameTo`), so we test them with
//! `Reader.fixed` and `Writer.fixed` across both codecs without a socket.
//! `FrameStream` is just the thin socket-backed binding on top.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const codec = @import("codec");
const engine = @import("engine");

const Stream = std.Io.net.Stream;

/// The per-connection outbound-queue capacity a drained queue retains (ADR-0042).
/// Capacity past this is burst from a slow-reader episode and frees on drain, so
/// one episode never pins its high-water bytes for the connection's life;
/// capacity at or under it is steady reply traffic and stays, so the steady state
/// never reallocates. Both readiness loops — the TCP completion `Loop` and the
/// iroh `LoopHost` — honor the same bound, so it lives here in one place: it is a
/// per-connection footprint number the ladder's 500k-connection budget owns, and
/// a divergence between the two loops would silently split that budget.
pub const steady_outbound_bytes: usize = 16 * 1024;

/// Outcome of reading one frame off the stream. A malformed / oversize frame is
/// a transport-fatal condition here (there is no session to project an abort
/// onto — that is the host peer's job once the frame is fed in); the concrete
/// `ReadFailed` cause is preserved on the stream reader.
pub const FrameError = error{
    /// Clean EOF on a frame boundary — the peer closed gracefully.
    Closed,
    /// EOF arrived mid-frame.
    TruncatedFrame,
    /// The bytes are not a structurally valid frame.
    MalformedFrame,
    /// A frame would exceed `max_frame_bytes` (cap-on-parse or buffer-full).
    FrameTooLarge,
    /// The underlying read or write failed.
    ConnectionLost,
} || std.mem.Allocator.Error;

/// The stream-edge conditions a single blocking read can hit, independent of the
/// codec's verdict over the bytes it produces. Shared by `readFrameFrom` and
/// the `Connection` pump.
pub const FillError = error{ TruncatedFrame, FrameTooLarge, ConnectionLost };

pub const Fill = enum { filled, closed };

/// One blocking read into `r`, deciding only the conditions the codec does not:
/// a full buffer that still holds no frame cannot fit one (`FrameTooLarge`); a
/// clean EOF on a frame boundary is `.closed`; an EOF with bytes still buffered
/// is a mid-frame truncation; a read fault is `ConnectionLost`. The codec
/// verdict over `r.buffered()` is the caller's; this owns only the byte-supply
/// edge, so frame-boundary truth lives in one parser and stream-edge truth lives
/// in one function.
///
/// The full-buffer refusal is the spill-less floor; `fillThroughSpill` turns
/// that same condition into a bounded owned accumulation instead, and is what
/// the frame readers drive.
fn fillStep(r: *std.Io.Reader) FillError!Fill {
    if (r.buffer.len > 0 and r.bufferedLen() == r.buffer.len) return error.FrameTooLarge;

    r.fillMore() catch |err| switch (err) {
        error.EndOfStream => return if (r.bufferedLen() == 0) .closed else error.TruncatedFrame,
        error.ReadFailed => return error.ConnectionLost,
    };
    return .filled;
}

/// The bounded owned accumulation behind a small read buffer. The steady state
/// is inactive: frames that fit the read buffer decode as borrowed prefixes and
/// the spill costs nothing. When one admissible frame outgrows the buffer, its
/// bytes move here so the prefix stays contiguous while the buffer keeps
/// reading; the frame decodes from the spill, and the spill frees itself the
/// moment it drains, steady per-connection memory is the read buffer again,
/// not `max_frame_bytes`.
///
/// Boundedness is the codec's cap-during-scan verdict (ADR-0029): a frame whose
/// scanned length crosses `max_frame_bytes` is refused `too_large` while it is
/// still arriving, so an `incomplete` verdict implies the scanned prefix is
/// under the cap and the spill never holds more than `max_frame_bytes` plus one
/// read buffer of not-yet-scanned tail. The frame readers keep a defensive
/// mirror of that contract (`incomplete` at or past the cap fails as
/// `FrameTooLarge`) so a codec regression fails closed here instead of growing
/// the spill.
///
/// The spill path costs one extra bounded copy per oversize frame (read buffer
/// into spill); the fast path stays a zero-copy borrow. That copy is a named
/// design event (ADR-0041).
pub const Spill = struct {
    buf: []u8 = &.{},
    len: usize = 0,

    /// Whether a frame is currently accumulating here. While active, the spill
    /// (not the read buffer) is the prefix the one parser decodes.
    pub fn isActive(self: *const Spill) bool {
        return self.len > 0;
    }

    /// The contiguous buffered prefix awaiting the one parser.
    pub fn bytes(self: *const Spill) []const u8 {
        return self.buf[0..self.len];
    }

    /// Move every byte the reader holds into the spill (the reader is left
    /// empty, free to read on). Grows geometrically; the caller's
    /// incomplete-at-cap check is what bounds the growth.
    pub fn absorb(self: *Spill, allocator: std.mem.Allocator, r: *std.Io.Reader) std.mem.Allocator.Error!void {
        try self.absorbBytes(allocator, r.buffered());
        r.toss(r.bufferedLen());
    }

    /// As `absorb`, for a caller that manages a raw receive buffer instead of
    /// a `std.Io.Reader` (the completion loop). `incoming` is borrowed for the
    /// call; the caller resets its own buffer after.
    pub fn absorbBytes(self: *Spill, allocator: std.mem.Allocator, incoming: []const u8) std.mem.Allocator.Error!void {
        if (incoming.len == 0) return;
        if (self.buf.len < self.len + incoming.len) {
            var new_cap: usize = @max(self.buf.len, 4096);
            while (new_cap < self.len + incoming.len) new_cap *= 2;
            self.buf = try allocator.realloc(self.buf, new_cap);
        }
        @memcpy(self.buf[self.len..][0..incoming.len], incoming);
        self.len += incoming.len;
    }

    /// Drop `n` consumed bytes (one decoded frame) off the front. Leftover bytes
    /// — the start of the next frame — compact forward and keep the spill
    /// active; a drained spill frees its storage so the steady state returns to
    /// the read buffer alone.
    pub fn consume(self: *Spill, allocator: std.mem.Allocator, n: usize) void {
        std.debug.assert(n <= self.len);
        const remaining = self.len - n;
        if (remaining == 0) {
            allocator.free(self.buf);
            self.buf = &.{};
            self.len = 0;
            return;
        }
        std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[n .. n + remaining]);
        self.len = remaining;
    }

    pub fn deinit(self: *Spill, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
        self.* = .{};
    }
};

/// Get more inbound bytes for the one parser, spilling instead of refusing when
/// the read buffer is the only limit: with the spill inactive and the buffer not
/// full this is one `fillStep`; a full buffer (or an already-active spill)
/// moves the buffered bytes into the spill so the in-flight frame's prefix stays
/// contiguous while the buffer keeps reading. A clean EOF while a frame is
/// accumulating in the spill is a mid-frame truncation, not a graceful close.
pub fn fillThroughSpill(
    r: *std.Io.Reader,
    spill: *Spill,
    allocator: std.mem.Allocator,
) (FillError || std.mem.Allocator.Error)!Fill {
    if (spill.isActive()) {
        if (r.bufferedLen() == 0) {
            switch (try fillStep(r)) {
                .filled => {},
                .closed => return error.TruncatedFrame,
            }
        }
        try spill.absorb(allocator, r);
        return .filled;
    }
    if (r.buffer.len > 0 and r.bufferedLen() == r.buffer.len) {
        try spill.absorb(allocator, r);
        return .filled;
    }
    return fillStep(r);
}

/// Block until one whole `codec_id` frame is available on `r`, returning it as an
/// owned `Frame` (a shape-correct copy lifted out of the read buffer, so the
/// buffer is free to advance). `Closed` is returned on a graceful boundary EOF.
/// A frame larger than the read buffer (but within `max_frame_bytes`)
/// accumulates in the caller's `spill` and decodes from there.
pub fn readFrameFrom(
    r: *std.Io.Reader,
    allocator: std.mem.Allocator,
    codec_id: model.CodecId,
    max_frame_bytes: usize,
    spill: *Spill,
) FrameError!foundation.Frame {
    while (true) {
        const supply = if (spill.isActive()) spill.bytes() else r.buffered();
        if (supply.len > 0) {
            switch (codec.dispatch.decodePrefix(codec_id, supply, max_frame_bytes)) {
                .decoded => |decoded| {
                    // `decodePrefix` above already accepted this codec, so its
                    // shape is registered; a null here would mean the two
                    // dispatchers disagree, which we classify as malformed.
                    const shape = codec.dispatch.frameShape(codec_id) orelse return error.MalformedFrame;
                    const view: foundation.FrameView = .{
                        .bytes = supply[0..decoded.consumed],
                        .shape = shape,
                    };
                    // The one shape-aware owned copy (8-aligned for `word`).
                    const frame = engine.ownedFrameFromView(allocator, view) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        // decodePrefix already accepted the frame, so a shape
                        // violation cannot occur; classify defensively.
                        error.InvalidFrameShape => return error.MalformedFrame,
                    };
                    if (spill.isActive()) spill.consume(allocator, decoded.consumed) else r.toss(decoded.consumed);
                    return frame;
                },
                .incomplete => {
                    // Defensive mirror of the codec's cap-during-scan contract
                    // (ADR-0029): an incomplete prefix at or past the cap can
                    // never complete within it, so a codec that failed to refuse
                    // it fails closed here instead of growing the spill.
                    if (supply.len >= max_frame_bytes) return error.FrameTooLarge;
                },
                .malformed => return error.MalformedFrame,
                .too_large => return error.FrameTooLarge,
            }
        }

        switch (try fillThroughSpill(r, spill, allocator)) {
            .filled => {},
            .closed => return error.Closed,
        }
    }
}

/// The verdict of draining whole frames from one received chunk.
pub const DrainVerdict = enum {
    /// Every whole frame applied; any partial tail is now in the spill.
    ok,
    /// A frame was malformed or oversize. The peer has already queued an
    /// `op:abort` to flush before the connection closes.
    fail,
    /// A spill allocation failed; close the connection.
    close,
};

/// Apply every whole frame in `chunk` to `peer`, carrying a partial frame tail
/// into `spill` so the next chunk continues it. This is the one inbound drain
/// both readiness loops run — the TCP completion loop over recycled pool buffers
/// and the iroh loop over sidecar `try_read` chunks — so the frame-boundary,
/// cap-mirror, and spill handling live in a single place and cannot drift.
///
/// A frame already accumulating in the spill absorbs `chunk` and stays the decode
/// prefix; otherwise whole frames apply straight from the borrowed `chunk` and
/// only a trailing partial frame copies into the spill (the one bounded copy a
/// frame split across chunk boundaries pays, ADR-0054). The cap is read from the
/// peer's own `max_frame_bytes` — the same authority the codec scans against — so
/// neither loop can pass a divergent cap.
pub fn drainWholeFrames(
    peer: *engine.Peer,
    spill: *Spill,
    chunk: []const u8,
    allocator: std.mem.Allocator,
) DrainVerdict {
    // A frame already in the spill owns every newly received byte: extend it so
    // the prefix stays contiguous. The supply then stays the spill for this whole
    // call even if it drains mid-loop, `chunk` has been absorbed and must not be
    // re-read.
    const from_spill = spill.isActive();
    if (from_spill) spill.absorbBytes(allocator, chunk) catch return .close;
    var offset: usize = 0;
    while (true) {
        const supply = if (from_spill) spill.bytes() else chunk[offset..];
        if (supply.len == 0) break;
        const outcome = peer.recvStreamPrefix(supply) catch return .fail;
        switch (outcome) {
            .incomplete => {
                // Defensive mirror of the codec's cap-during-scan contract
                // (ADR-0029): an incomplete prefix at or past the cap can never
                // complete within it, so a codec that failed to refuse it fails
                // closed here instead of growing the spill.
                if (supply.len >= peer.session_state.limits.max_frame_bytes) return .fail;
                break;
            },
            .consumed => |used| {
                if (from_spill) spill.consume(allocator, used) else offset += used;
            },
        }
    }
    // A partial frame tail cannot stay in the caller's buffer (a pool buffer is
    // recycled the moment the completion returns; a `try_read` chunk is
    // transient), so it absorbs into the bounded spill and waits for the next
    // chunk.
    if (!from_spill and offset < chunk.len) {
        spill.absorbBytes(allocator, chunk[offset..]) catch return .close;
    }
    return .ok;
}

/// Write one frame's bytes and flush. `bytes` are borrowed for the call.
pub fn writeFrameTo(w: *std.Io.Writer, bytes: []const u8) FrameError!void {
    w.writeAll(bytes) catch return error.ConnectionLost;
    w.flush() catch return error.ConnectionLost;
}

/// The thin socket-backed binding of the frame operations above: a stream's
/// reader/writer plus the codec that delimits its frames.
pub const FrameStream = struct {
    reader: Stream.Reader,
    writer: Stream.Writer,
    io: std.Io,
    /// The codec whose grammar delimits frames on this stream.
    codec_id: model.CodecId,
    /// Cap on an accepted frame. Independent of the read buffer size: an
    /// admissible frame larger than the read buffer accumulates in the spill.
    max_frame_bytes: usize,
    /// Allocates the spill; the read/write buffers stay caller-owned.
    allocator: std.mem.Allocator,
    /// Bounded overflow for frames larger than the read buffer; inactive (and
    /// allocation-free) while frames fit the buffer.
    spill: Spill = .{},

    pub fn initStream(
        io: std.Io,
        allocator: std.mem.Allocator,
        stream: Stream,
        codec_id: model.CodecId,
        max_frame_bytes: usize,
        read_buf: []u8,
        write_buf: []u8,
    ) FrameStream {
        return .{
            .reader = stream.reader(io, read_buf),
            .writer = stream.writer(io, write_buf),
            .io = io,
            .codec_id = codec_id,
            .max_frame_bytes = max_frame_bytes,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FrameStream) void {
        self.spill.deinit(self.allocator);
        self.reader.stream.close(self.io);
    }

    /// Block for one whole frame as an owned `Frame` (allocated, like the spill,
    /// from the stream's own allocator); `Closed` on graceful EOF.
    pub fn readFrame(self: *FrameStream) FrameError!foundation.Frame {
        return readFrameFrom(&self.reader.interface, self.allocator, self.codec_id, self.max_frame_bytes, &self.spill);
    }

    /// Write one frame's borrowed bytes and flush.
    pub fn writeFrame(self: *FrameStream, bytes: []const u8) FrameError!void {
        return writeFrameTo(&self.writer.interface, bytes);
    }

    /// The concrete read failure behind the last `ConnectionLost`, if any. The C
    /// boundary surfaces this via `pancake_last_error`.
    pub fn lastReadError(self: *const FrameStream) ?Stream.Reader.Error {
        return self.reader.err;
    }

    pub fn lastWriteError(self: *const FrameStream) ?Stream.Writer.Error {
        return self.writer.err;
    }
};
