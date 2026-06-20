//! A connection: it runs a borrowed `*engine.Peer` over a `std.Io` byte stream.
//!
//! A CapTP transport is a stream of self-delimiting codec frames. The connection
//! reads bytes into a buffer and hands the buffered prefix to the engine, and the
//! active codec's own decoder finds the frame boundary as it decodes
//! (`engine.Peer.recvStreamPrefix`). One parse does both jobs; there's no
//! separate boundary scanner. A decoded frame is applied right away, the bytes it
//! used are dropped, and the peer's outbound frames are streamed back. The read
//! buffer sizes the steady state, not the largest admissible frame: a frame that
//! outgrows it assembles in a bounded owned spill and is freed when it drains
//! (ADR-0041).
//!
//! This is where `std.Io` enters the transport adapter. The five core layers
//! (foundation, model, codec, session, engine) stay synchronous and I/O-free;
//! the layers above `net` — `driver` and `c_abi` — also do host I/O and
//! disclose it in their own headers.
//! The connection doesn't wrap a socket of its own; it just drives
//! the plain `std.Io.Reader` and `std.Io.Writer` a stream already gives you, so
//! any stream that speaks those — the TCP socket, an in-memory pipe, a TLS
//! wrapper — drives it unchanged. The actual socket lives behind `tcp.zig`, and the framing core
//! (`pumpOver`) only ever sees a type-erased reader and writer, which is how we
//! test it with `Reader.fixed` and `Writer.fixed` and no socket at all.

const std = @import("std");

const foundation = @import("foundation");
const engine = @import("engine");
const frame_stream = @import("frame_stream.zig");

/// One unit of forward progress reported by `pumpOver` / `Connection.pump`.
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
/// fault. The variant names only the failure family; the typed cause — abort
/// kind, codec-vs-session domain, diagnostic — stays readable through
/// `engine.Peer.lastAbort` on the peer the caller already holds.
/// `ConnectionLost` / `TruncatedFrame` are the genuine transport faults;
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
    /// An inbound frame would exceed `SessionLimits.max_frame_bytes`: its
    /// scanned length crossed the cap during decode (op:abort projected), or —
    /// the defensive mirror of that codec contract — its prefix reached the cap
    /// still incomplete.
    FrameTooLarge,
    /// A structurally valid frame was refused by session authority (op:abort
    /// projected; the session is closing).
    ProtocolAbort,
} || std.mem.Allocator.Error;

/// A type-erased handle to the concrete stream behind a `Connection`. The
/// transport that produced the connection (e.g. `tcp`) owns the stream and
/// supplies these two operations: close it (and free whatever the transport
/// pinned to keep the reader/writer alive), and expose its pollable socket
/// descriptor when it has one. A userspace transport with no fd returns null
/// from `socketHandle` and multiplexes in its own loop.
pub const TransportHandle = struct {
    ctx: *anyopaque,
    close_fn: *const fn (ctx: *anyopaque) void,
    socket_handle_fn: *const fn (ctx: *anyopaque) ?std.Io.net.Socket.Handle,

    pub fn close(self: TransportHandle) void {
        self.close_fn(self.ctx);
    }
    pub fn socketHandle(self: TransportHandle) ?std.Io.net.Socket.Handle {
        return self.socket_handle_fn(self.ctx);
    }
};

/// A transport-neutral byte-stream connection: a borrowed peer plus a
/// type-erased reader/writer pair and a handle to the transport behind them.
///
/// The connection holds `*std.Io.Reader` / `*std.Io.Writer` — the interfaces
/// `pumpOver` already speaks — never a concrete socket type, so any transport
/// that yields those interfaces drives it unchanged: TCP, the in-process pipe,
/// and the iroh QUIC stream all do. The concrete stream object lives behind
/// `TransportHandle`, owned by the transport that produced it (see
/// `tcp`); the connection only borrows the interfaces and asks the handle to
/// close the stream on `deinit`. It does not own the peer (lifetime
/// unchanged).
///
/// Because the connection borrows the reader/writer interfaces rather than
/// storing them inline, the transport must keep its concrete reader/writer at a
/// stable address for the connection's life — `std.Io.Reader`'s vtable recovers
/// that concrete reader from `&interface` by field offset, so a moved-away
/// reader would dangle. The tcp transport pins its per-connection stream on the
/// peer's allocator and frees it through the handle.
pub const Connection = struct {
    peer: *engine.Peer,
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    transport: TransportHandle,
    /// The host `std.Io` this connection runs on. Kept so the driver can draw
    /// handshake entropy at the I/O boundary without reaching into the
    /// transport's private stream; it is OS randomness, not transport state.
    io: std.Io,
    /// Bounded overflow for an admissible frame larger than the read buffer
    /// (see `frame_stream.Spill`); inactive and allocation-free while frames
    /// fit the buffer. Allocates from the peer's allocator.
    spill: frame_stream.Spill = .{},

    /// Weld `peer` to a transport's already-built reader/writer interfaces and a
    /// handle that closes the underlying stream. The transport (e.g. `tcp`)
    /// owns the concrete stream behind `transport` and keeps `r` / `w` valid for
    /// the connection's life.
    pub fn init(
        io: std.Io,
        peer: *engine.Peer,
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        transport: TransportHandle,
    ) Connection {
        return .{ .peer = peer, .r = r, .w = w, .transport = transport, .io = io };
    }

    /// Close the underlying stream (via the transport handle) and free the spill.
    /// Does not touch the borrowed peer.
    pub fn deinit(self: *Connection) void {
        self.spill.deinit(self.peer.allocator);
        self.transport.close();
    }

    /// One blocking step of progress over the stream (the whole contract). See
    /// `pumpOver`.
    pub fn pump(self: *Connection) PumpError!Progress {
        return pumpOver(self.peer, self.r, self.w, &self.spill);
    }

    /// Encode the peer's queued sends and flush them, without reading. The write-only
    /// counterpart to `pump` for a caller that has just enqueued outbound work
    /// (a host orchestrating across connections) and wants it on the wire now,
    /// rather than blocking on a read that may never come.
    pub fn flush(self: *Connection) PumpError!void {
        stepToIdle(self.peer) catch |err| {
            _ = drainOutbound(self.peer, self.w) catch 0;
            return classifyApplyError(err);
        };
        _ = drainOutbound(self.peer, self.w) catch return error.ConnectionLost;
    }

    /// Whether the read buffer or the spill already holds bytes (a
    /// possibly-partial frame). A caller multiplexing reads with `poll` checks
    /// this before polling, since buffered bytes are readable progress the OS
    /// poll will not report.
    pub fn hasBufferedInbound(self: *Connection) bool {
        return self.r.bufferedLen() > 0 or self.spill.isActive();
    }

    /// The underlying socket descriptor for a host that multiplexes several
    /// connections with `poll`, or null for a transport with no pollable fd (a
    /// userspace transport multiplexes in its own loop). Provided by the
    /// transport handle.
    pub fn socketHandle(self: *const Connection) ?std.Io.net.Socket.Handle {
        return self.transport.socketHandle();
    }

    /// Pump until `pred(peer)` holds or the stream closes. The only blocking
    /// convenience; the primitive it builds on is `pump`. Returns the last `Progress`
    /// (`.closed` if the stream ended first).
    pub fn runUntil(self: *Connection, pred: *const fn (*engine.Peer) bool) PumpError!Progress {
        if (pred(self.peer)) return .idle;
        while (true) {
            const progress = try self.pump();
            if (progress == .closed) return .closed;
            if (pred(self.peer)) return progress;
        }
    }
};

/// The framing core, decoupled from sockets: drive one step of progress over a
/// type-erased `*std.Io.Reader` / `*std.Io.Writer`, with `spill` as the bounded
/// overflow for a frame larger than the read buffer. Proven with `Reader.fixed`
/// / `std.testing.Reader` and `Writer.fixed`; `Connection.pump` is the
/// socket-backed caller (its connection owns the spill).
///
/// Order of operations (single fiber, blocking):
///   1. Encode the peer's queued sends and flush all outbound to the wire, the
///      handshake `op:start-session`, responses from a prior apply, or a
///      projected abort all leave this way.
///   2. If the spill (when active) or the buffer holds a whole frame, frame +
///      validate + apply it (one parse) and drop its bytes; report `received`.
///   3. Otherwise read more, distinguishing graceful EOF (`closed`) from
///      mid-frame EOF (`TruncatedFrame`); a read buffer full of one frame's
///      prefix moves into the spill and keeps reading, bounded by
///      `max_frame_bytes` (the codec's cap-during-scan plus the defensive
///      mirror below).
///
/// One fiber is the contract, not a deferral (ADR-0053): this pump serves
/// cooperative request/response traffic (handshake, fetch, deliver/resolve),
/// where each side drains the replies its own requests caused. A partner that
/// streams without draining can head-of-line-block a fiber mid-`writeAll`;
/// that workload rides the completion loop, whose bounded outbound queue and
/// read parking (ADR-0042) exist for exactly it.
pub fn pumpOver(
    peer: *engine.Peer,
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    spill: *frame_stream.Spill,
) PumpError!Progress {
    stepToIdle(peer) catch |err| {
        _ = drainOutbound(peer, w) catch 0;
        return classifyApplyError(err);
    };
    const sent = drainOutbound(peer, w) catch return error.ConnectionLost;

    const supply = if (spill.isActive()) spill.bytes() else r.buffered();
    if (supply.len > 0) {
        const outcome = peer.recvStreamPrefix(supply) catch |err| {
            // The core projected an op:abort into outbound; flush it best-effort
            // so the partner sees the fail-loud close, then surface the cause.
            stepToIdle(peer) catch {};
            _ = drainOutbound(peer, w) catch 0;
            return classifyApplyError(err);
        };
        switch (outcome) {
            .consumed => |n| {
                if (spill.isActive()) spill.consume(peer.allocator, n) else r.toss(n);
                return .{ .received = n };
            },
            .incomplete => {
                // Defensive mirror of the codec's cap-during-scan contract
                // (ADR-0029): an incomplete prefix at or past the cap can never
                // complete within it, so a codec that failed to refuse it fails
                // closed here instead of growing the spill.
                if (supply.len >= peer.session_state.limits.max_frame_bytes)
                    return error.FrameTooLarge;
            },
        }
    }

    // A flush with no inbound frame is still real progress.
    if (sent > 0) return .{ .sent = sent };

    return switch (try frame_stream.fillThroughSpill(r, spill, peer.allocator)) {
        .filled => .idle,
        .closed => .closed,
    };
}

/// Encode every queued send into outbound frames (run `step` to quiescence).
/// `step` here only drains `pending_send`; the connection never uses the
/// frame-queue `feedInbound` path.
fn stepToIdle(peer: *engine.Peer) !void {
    while ((try peer.step()) != .idle) {}
}

/// Write and flush every outbound frame, returning the byte count. The frame is
/// owned by `takeOutbound`; this releases it after writing. `writeAll` streams a
/// frame larger than the write buffer straight through.
fn drainOutbound(peer: *engine.Peer, w: *std.Io.Writer) std.Io.Writer.Error!usize {
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
