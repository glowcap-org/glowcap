//! Moving whole frames over a `std.Io` byte stream, without a peer involved.
//!
//! A `Connection` reads frames straight into a `engine.Peer` and applies them.
//! A `FrameStream` sits one level lower: read one whole frame off the wire as an
//! owned `Frame`, or write one, and that's it. It's what the host-driven C ABI
//! endpoint is built on. There, the C host owns the peer and runs the loop itself
//! (read a frame, feed it, step, take the outbound, write it), so all this layer
//! does is frame the inbound bytes. It applies no authority of its own.
//!
//! Byte-stream netlayers carry each codec frame inside a Syrup byte string:
//! canonical decimal byte length, `:`, then the frame bytes. Intrinsically
//! message-framed transports continue to exchange bare codec frames through the
//! engine's whole-frame APIs. The outer parser and writer live here so every
//! byte-stream adapter agrees on that distinction.
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
/// never reallocates. One `completion.Loop` honors it for every backend it is
/// instantiated over, so there is no second Zig spelling to drift from. The
/// mirror that can drift is across languages: the iroh sidecar keeps its own
/// per-direction bound in Rust (`NB_STEADY_BYTES`), and `meta-check` pins the
/// two literals together, because this is a per-connection footprint number the
/// ladder's 500k-connection budget owns.
pub const steady_outbound_bytes: usize = 16 * 1024;

/// The outer frame used by byte-stream netlayers: a Syrup byte string containing
/// exactly one bare codec frame. There is no netstring trailing comma.
pub const OuterPrefix = foundation.stream_framing.Prefix;

/// Parse one outer Syrup byte string from the front of `bytes`. The declared
/// body length is bounded before the body is buffered, and canonical Syrup
/// length syntax rejects an empty digit run, non-digits, and leading zeroes.
pub fn outerPrefix(bytes: []const u8, max_frame_bytes: usize) OuterPrefix {
    return foundation.stream_framing.parsePrefix(bytes, max_frame_bytes);
}

/// Append one bare codec frame in byte-stream form without an intermediate
/// allocation. Capacity is secured for the complete outer frame before either
/// slice is appended, so allocation failure cannot leave a partial prefix.
pub fn appendFrameBytes(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bytes: []const u8,
) std.mem.Allocator.Error!usize {
    var prefix_buf: [foundation.stream_framing.prefix_buffer_bytes]u8 = undefined;
    const prefix = foundation.stream_framing.renderPrefix(&prefix_buf, bytes.len);
    const framed_len = std.math.add(usize, prefix.len, bytes.len) catch return error.OutOfMemory;
    try list.ensureUnusedCapacity(allocator, framed_len);
    list.appendSliceAssumeCapacity(prefix);
    list.appendSliceAssumeCapacity(bytes);
    return framed_len;
}

/// Write one bare codec frame in byte-stream form. The prefix uses stack
/// storage; the codec frame remains borrowed and is not copied into a wrapper.
pub fn writeFrameBytes(w: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!usize {
    var prefix_buf: [foundation.stream_framing.prefix_buffer_bytes]u8 = undefined;
    const prefix = foundation.stream_framing.renderPrefix(&prefix_buf, bytes.len);
    try w.writeAll(prefix);
    try w.writeAll(bytes);
    return prefix.len + bytes.len;
}

/// Append every encoded outbound frame `peer` holds onto `list`, freeing each
/// frame as its bytes are copied — the one take-outbound drain shape both
/// readiness loops ride. It lives here beside `steady_outbound_bytes` because
/// the bound and the drain it bounds belong together.
/// On an append failure the current frame is still freed and the remaining
/// frames stay on the peer (freed with it), so the caller only decides what
/// the failed connection does next.
pub fn queueOutboundBytes(
    peer: *engine.Peer,
    allocator: std.mem.Allocator,
    list: *std.ArrayList(u8),
) std.mem.Allocator.Error!void {
    while (peer.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        _ = try appendFrameBytes(list, allocator, frame.bytes());
    }
}

/// Reclaim a drained outbound list: burst capacity above `bound` frees (one
/// slow-reader episode must not pin its high-water bytes for the connection's
/// life, the ADR-0041/0042 posture), capacity at or under it stays so steady
/// reply traffic never reallocates. The one spelling of the drain-point
/// reclaim.
pub fn reclaimBurst(list: *std.ArrayList(u8), allocator: std.mem.Allocator, bound: usize) void {
    if (list.capacity > bound) {
        list.clearAndFree(allocator);
    } else {
        list.clearRetainingCapacity();
    }
}

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
const FillError = error{ TruncatedFrame, FrameTooLarge, ConnectionLost };

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

/// The waiting room for stream bytes that have arrived but do not yet make a
/// whole frame, shared with every other tier that reads a stream
/// (`foundation.Spill`).
///
/// At this tier it is the bounded overflow behind a small read buffer. The
/// steady state is inactive: frames that fit the read buffer decode as borrowed
/// prefixes and the spill costs nothing. When one admissible frame outgrows the
/// buffer, its bytes move here so the prefix stays contiguous while the buffer
/// keeps reading. That is rare, so the readers here drain with
/// `spill_retain_bytes` and the burst is returned outright; steady
/// per-connection memory is the read buffer again, not `max_frame_bytes`.
///
/// The spill path costs one extra bounded copy per oversize frame (read buffer
/// into spill); the fast path stays a zero-copy borrow. That copy is a named
/// design event (ADR-0041).
pub const Spill = foundation.Spill;

/// What a drained spill keeps at this tier: nothing. A stream reader spills only
/// for a frame too large for its read buffer, which is the exception rather than
/// the traffic, so the burst is freed outright and the next oversize frame pays
/// one fresh allocation. The byte-fed host tier straddles frame boundaries on
/// ordinary traffic and names a steady size instead.
pub const spill_retain_bytes: usize = 0;

/// Move every byte the reader holds into the spill (the reader is left empty,
/// free to read on). The reader-shaped half of `Spill.absorbBytes`: it lives
/// here rather than on the type because `foundation` is core and holds no
/// `std.Io`.
pub fn absorbFrom(spill: *Spill, allocator: std.mem.Allocator, r: *std.Io.Reader) std.mem.Allocator.Error!void {
    try spill.absorbBytes(allocator, r.buffered());
    r.toss(r.bufferedLen());
}

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
        try absorbFrom(spill, allocator, r);
        return .filled;
    }
    if (r.buffer.len > 0 and r.bufferedLen() == r.buffer.len) {
        try absorbFrom(spill, allocator, r);
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
    scan: *codec.framing.StreamScan,
) FrameError!foundation.Frame {
    while (true) {
        const supply = if (spill.isActive()) spill.bytes() else r.buffered();
        if (supply.len > 0) {
            switch (outerPrefix(supply, max_frame_bytes)) {
                .decoded => |outer| switch (codec.dispatch.framePrefix(codec_id, outer.body, scan, max_frame_bytes)) {
                    .complete => |consumed| {
                        // The byte-string body is one frame, not an arbitrary
                        // concatenation of otherwise valid codec values.
                        if (consumed != outer.body.len) return error.MalformedFrame;
                        // `framePrefix` above already accepted this codec, so its
                        // shape is registered; a null here would mean the two
                        // dispatchers disagree, which we classify as malformed.
                        const shape = codec.dispatch.frameShape(codec_id) orelse return error.MalformedFrame;
                        const view: foundation.FrameView = .{
                            .bytes = outer.body,
                            .shape = shape,
                        };
                        // The one shape-aware owned copy (8-aligned for `word`).
                        const frame = engine.ownedFrameFromView(allocator, view) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            // Structural framing accepted the frame, so a shape
                            // violation cannot occur; classify defensively.
                            error.InvalidFrameShape => return error.MalformedFrame,
                        };
                        if (spill.isActive()) spill.consume(allocator, outer.consumed, spill_retain_bytes) else r.toss(outer.consumed);
                        return frame;
                    },
                    // The outer byte string is complete, so its bounded body
                    // cannot become a complete inner frame by reading more.
                    .incomplete, .malformed => return error.MalformedFrame,
                    .too_large => return error.FrameTooLarge,
                },
                .incomplete => {},
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

/// Apply one outer-framed byte-stream message to `peer`. The outer length owns
/// the stream boundary; `recvBorrowed` validates the complete bounded body as
/// exactly one codec frame and preserves the engine's one-parse apply path.
pub fn recvOuterPrefix(peer: *engine.Peer, bytes: []const u8) !engine.Peer.RecvStream {
    const outer = switch (outerPrefix(bytes, peer.limits().max_frame_bytes)) {
        .incomplete => return .incomplete,
        .malformed => {
            peer.emitFailure(error.MalformedFrame);
            return error.MalformedFrame;
        },
        .too_large => {
            peer.emitFailure(error.FrameTooLarge);
            return error.FrameTooLarge;
        },
        .decoded => |decoded| decoded,
    };
    const shape = codec.dispatch.frameShape(peer.inboundCodec()) orelse {
        peer.emitFailure(error.MalformedFrame);
        return error.MalformedFrame;
    };
    try peer.recvBorrowed(.{ .bytes = outer.body, .shape = shape });
    return .{ .consumed = outer.consumed };
}

/// The verdict of draining whole frames from one received chunk.
const DrainVerdict = enum {
    /// Every whole frame applied; any partial tail is now in the spill.
    ok,
    /// The stream is unrecoverable. When the codec refused the frame, the
    /// peer has already queued an `op:abort` to flush before the connection
    /// closes, and the incomplete-at-cap refusal queues one too: it runs
    /// through `recvStreamPrefix`, which projects the same typed abort a
    /// decoder refusal does.
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
        const outcome = recvOuterPrefix(peer, supply) catch return .fail;
        switch (outcome) {
            .incomplete => break,
            .consumed => |used| {
                if (from_spill) spill.consume(allocator, used, spill_retain_bytes) else offset += used;
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
    _ = writeFrameBytes(w, bytes) catch return error.ConnectionLost;
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
    /// How far the codec has got framing the partial frame at the front of the
    /// supply, so a frame arriving over several reads is walked once rather
    /// than once per read.
    scan: codec.framing.StreamScan = .{},

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

    /// Interrupt blocked reads and writes without releasing the stream's
    /// storage. Foreign runtimes use this as the cancellation half of a split
    /// close: shutdown wakes an operation running on another OS thread, and the
    /// owner calls `deinit` only after that operation has returned.
    pub fn shutdown(self: *FrameStream) void {
        self.reader.stream.shutdown(self.io, .both) catch {};
    }

    /// Block for one whole frame as an owned `Frame` (allocated, like the spill,
    /// from the stream's own allocator); `Closed` on graceful EOF.
    pub fn readFrame(self: *FrameStream) FrameError!foundation.Frame {
        return readFrameFrom(&self.reader.interface, self.allocator, self.codec_id, self.max_frame_bytes, &self.spill, &self.scan);
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
