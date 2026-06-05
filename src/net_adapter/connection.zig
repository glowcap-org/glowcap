//! Byte-stream connection: a fold over frames welding a borrowed `*runtime.Peer`
//! to a `std.Io` byte stream.
//!
//! A CapTP transport carries a stream of self-delimiting codec frames. The
//! connection reads bytes into a buffer, hands the buffered prefix to the
//! runtime, and the *active codec's own decoder* finds the frame boundary as it
//! decodes ([`runtime.Peer.recvStreamPrefix`]) — one parse, no separate
//! boundary scanner. Decoded frames are applied immediately (borrowed-validate),
//! consumed bytes are dropped, and the peer's outbound frames are streamed back.
//!
//! This layer is the one place `std.Io` enters: the five core layers
//! (`foundation` / `model` / `codec` / `session` / `runtime`) stay sync and
//! no-I/O. The connection owns no socket abstraction of its own; it drives the
//! standard `std.Io.Reader` / `std.Io.Writer` a stream already hands out, so the
//! same code serves TCP today and TLS / in-memory pipes unchanged. The actual
//! socket lives behind [`tcp`](tcp.zig); the framing core ([`pumpOver`]) takes
//! only the type-erased reader/writer, so it is proven with `Reader.fixed` and
//! `Writer.fixed` without any socket.

const std = @import("std");

const foundation = @import("../foundation/mod.zig");
const runtime = @import("../runtime/mod.zig");
const frame_stream = @import("frame_stream.zig");

/// One unit of forward progress reported by [`pumpOver`] / [`Connection.pump`].
pub const Progress = union(enum) {
    /// A read happened but no whole frame is available yet (need more bytes).
    idle,
    /// One inbound frame of `received` bytes was framed, validated, applied,
    /// and dropped from the buffer.
    received: usize,
    /// `sent` bytes of queued outbound frames were written and flushed.
    sent: usize,
    /// The peer closed the stream cleanly *between* frames (graceful EOF).
    closed,
};

/// Why a pump could not make protocol progress. A malformed / oversize / refused
/// inbound frame is a *protocol abort*: the core has already projected the
/// outbound `op:abort` (which the pump flushes best-effort) before the matching
/// error surfaces here — the variant names what the partner did, not a transport
/// fault. `ConnectionLost` / `TruncatedFrame` are the genuine transport faults;
/// the concrete `ReadFailed` / `WriteFailed` cause is preserved on the
/// `Stream.Reader` / `Stream.Writer` for a caller (or the C boundary) to surface.
pub const PumpError = error{
    /// An underlying read or write failed (concrete cause on the stream).
    ConnectionLost,
    /// The stream closed mid-frame: bytes were buffered but no whole frame and
    /// no graceful boundary. Distinct from `closed`, which is clean EOF.
    TruncatedFrame,
    /// Inbound bytes are not a structurally valid frame (op:abort projected).
    MalformedFrame,
    /// An inbound frame would exceed `SessionLimits.max_frame_bytes`, either by
    /// its decoded length (cap-on-parse) or by filling the read buffer without
    /// completing (op:abort projected).
    FrameTooLarge,
    /// A structurally valid frame was refused by session authority (op:abort
    /// projected; the session is closing).
    ProtocolAbort,
} || std.mem.Allocator.Error;

/// A concrete byte-stream connection: a borrowed peer plus a stream's
/// reader/writer. It does not own the peer (lifetime unchanged) and owns the
/// stream only to close it on [`deinit`]. No generics, no comptime endpoint
/// concept — every byte-stream transport already funnels through
/// `std.Io.Reader` / `std.Io.Writer`.
pub const Connection = struct {
    peer: *runtime.Peer,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    io: std.Io,

    /// Weld `peer` to `stream` over the caller's `read_buf` / `write_buf`. `io`
    /// is named exactly once, here, and captured by the stream reader/writer.
    ///
    /// Slice-1 sizing: `read_buf` should be `peer.session_state.limits
    /// .max_frame_bytes` so any admissible frame fits whole (a documented
    /// loopback simplification; the small-buffer + bounded-overflow production
    /// path is the named follow-up). `write_buf` may stay small — `writeAll`
    /// streams a large frame straight through.
    pub fn initStream(
        io: std.Io,
        peer: *runtime.Peer,
        stream: std.Io.net.Stream,
        read_buf: []u8,
        write_buf: []u8,
    ) Connection {
        return .{
            .peer = peer,
            .reader = stream.reader(io, read_buf),
            .writer = stream.writer(io, write_buf),
            .io = io,
        };
    }

    /// Close the underlying stream. Does not touch the borrowed peer.
    pub fn deinit(self: *Connection) void {
        self.reader.stream.close(self.io);
    }

    /// One blocking step of progress over the stream (the whole contract). See
    /// [`pumpOver`].
    pub fn pump(self: *Connection) PumpError!Progress {
        return pumpOver(self.peer, &self.reader.interface, &self.writer.interface);
    }

    /// Pump until `pred(peer)` holds or the stream closes. The only blocking
    /// sugar; the honest primitive is [`pump`]. Returns the last `Progress`
    /// (`.closed` if the stream ended first).
    pub fn runUntil(self: *Connection, pred: *const fn (*runtime.Peer) bool) PumpError!Progress {
        if (pred(self.peer)) return .idle;
        while (true) {
            const progress = try self.pump();
            if (progress == .closed) return .closed;
            if (pred(self.peer)) return progress;
        }
    }
};

/// The framing core, decoupled from sockets: drive one step of progress over a
/// type-erased `*std.Io.Reader` / `*std.Io.Writer`. Proven with `Reader.fixed`
/// and `Writer.fixed`; `Connection.pump` is the socket-backed caller.
///
/// Order of operations (single fiber, blocking):
///   1. Encode the peer's queued sends and flush all outbound to the wire — the
///      handshake `op:start-session`, responses from a prior apply, or a
///      projected abort all leave this way.
///   2. If the buffer already holds a whole frame, frame + validate + apply it
///      (one parse) and drop its bytes; report `received`.
///   3. Otherwise read more (`fillMore`), distinguishing graceful EOF (`closed`)
///      from mid-frame EOF (`TruncatedFrame`) and guarding the buffer cap before
///      a full buffer would force an over-read (`FrameTooLarge`).
///
/// Backpressure / full-duplex is deferred by name: a single fiber that is
/// mid-`writeAll` to a slow reader can head-of-line-block. Request/response
/// traffic (handshake, fetch, deliver/resolve) is safe on one fiber; concurrent
/// streaming wants split read/write fibers above this primitive.
pub fn pumpOver(peer: *runtime.Peer, r: *std.Io.Reader, w: *std.Io.Writer) PumpError!Progress {
    // 1. Encode queued sends, then flush everything outbound.
    stepToIdle(peer) catch |err| {
        _ = drainOutbound(peer, w) catch 0;
        return classifyApplyError(err);
    };
    const sent = drainOutbound(peer, w) catch return error.ConnectionLost;

    // 2. Frame and apply one inbound message already buffered (one parse).
    if (r.bufferedLen() > 0) {
        const outcome = peer.recvStreamPrefix(r.buffered()) catch |err| {
            // The core projected an op:abort into outbound; flush it best-effort
            // so the partner sees the fail-loud close, then surface the cause.
            stepToIdle(peer) catch {};
            _ = drainOutbound(peer, w) catch 0;
            return classifyApplyError(err);
        };
        switch (outcome) {
            .consumed => |n| {
                r.toss(n);
                return .{ .received = n };
            },
            .incomplete => {},
        }
    }

    // A flush with no inbound frame is still real progress.
    if (sent > 0) return .{ .sent = sent };

    // 3. Need more bytes. The stream-edge classification (full-buffer cap,
    //    graceful vs mid-frame EOF, read fault) is the one shared with the
    //    peer-less frame transport, so the two cannot disagree on a boundary.
    return switch (try frame_stream.fillStep(r)) {
        .filled => .idle,
        .closed => .closed,
    };
}

/// Encode every queued send into outbound frames (run `step` to quiescence).
/// `step` here only drains `pending_send`; the connection never uses the
/// frame-queue `feedInbound` path.
fn stepToIdle(peer: *runtime.Peer) !void {
    while ((try peer.step()) != .idle) {}
}

/// Write and flush every outbound frame, returning the byte count. The frame is
/// owned by `takeOutbound`; this releases it after writing. `writeAll` streams a
/// frame larger than the write buffer straight through.
fn drainOutbound(peer: *runtime.Peer, w: *std.Io.Writer) std.Io.Writer.Error!usize {
    var total: usize = 0;
    while (peer.takeOutbound()) |frame_value| {
        var frame: foundation.Frame = frame_value;
        defer frame.deinit();
        const bytes = frame.bytes();
        try w.writeAll(bytes);
        total += bytes.len;
    }
    if (total > 0) try w.flush();
    return total;
}

/// Map a recv-apply / encode error onto the pump's surface. Decode verdicts
/// carry their own names; any other session authority rejection has already
/// projected an abort, so it surfaces as `ProtocolAbort`.
fn classifyApplyError(err: anyerror) PumpError {
    return switch (err) {
        error.MalformedFrame, error.InvalidFrameShape, error.MalformedView => error.MalformedFrame,
        error.FrameTooLarge => error.FrameTooLarge,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProtocolAbort,
    };
}
