//! A connection: it runs a borrowed `*engine.Peer` over a `std.Io` byte stream.
//!
//! A byte-stream CapTP transport wraps each bare codec frame in a Syrup byte
//! string. The connection reads that canonical length prefix and bounded body,
//! applies the body as one whole frame, and streams outbound frames through the
//! same outer envelope. Intrinsically message-framed transports drive the
//! engine's whole-frame APIs directly and do not use this layer. The read
//! buffer sizes the steady state, not the largest admissible frame: a frame that
//! outgrows it assembles in a bounded owned spill and is freed when it drains
//! (ADR-0041).
//!
//! This is where `std.Io` enters the transport adapter. The five core layers
//! (foundation, model, codec, session, engine) stay synchronous and I/O-free.
//! The layers above `net`, `driver` and `c_abi`, also do host I/O and
//! disclose it in their own headers.
//!
//! ## Connection vs FrameStream
//!
//! A `Connection` owns the `Spill` and a `TransportHandle` for its close-and-free
//! lifecycle, and carries the pump verbs (`pump`, `flush`, `runUntil`). Use
//! `Connection` when you have a peer and want blocking pump-over-wire.
//!
//! A `FrameStream` (`frame_stream.zig`) is the frame-boundary primitive without a
//! peer: the host owns the peer lifecycle and only needs raw frame delimiters.
//! The C ABI and binding byte-fed paths drive a `FrameStream` instead. The two
//! paths share the frame delimiters in `frame_stream.zig` and nothing else:
//! `pumpOver` below is the peer-driven pump, reached only through
//! `Connection.pump`, while `FrameStream.readFrame` and `writeFrame` read and
//! write one frame with no peer in sight.
//!
//! The connection borrows a type-erased `*std.Io.Reader` and `*std.Io.Writer`, it
//! does not own the stream object. It owns only the close capability (the
//! `TransportHandle`), so a transport that produces a connection pins its concrete
//! reader and writer at a stable address for the connection's life. The framing
//! core (`pumpOver`) only ever sees the type-erased interfaces, which is how we
//! test it with `Reader.fixed` and `Writer.fixed` and no socket at all.

const std = @import("std");

const foundation = @import("foundation");
const engine = @import("engine");
const frame_stream = @import("frame_stream.zig");
const poll = @import("poll.zig");
const clock = @import("clock.zig");

pub const CloseProgress = enum { complete, wait_read, wait_write, failed };
pub const WaitInterest = enum { read, write };

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
/// outbound `op:abort` before the matching error surfaces here. A successful
/// terminal-frame write returns the protocol family. A refused write returns
/// `AbortFlushFailed`, while the original typed cause remains on
/// `engine.Peer.lastAbort`. The protocol variants name what the partner did,
/// not a transport fault. They name only the failure family. The typed cause, abort
/// kind, codec-vs-session domain, diagnostic, stays readable through
/// `engine.Peer.lastAbort` on the peer the caller already holds.
/// `ConnectionLost` / `TruncatedFrame` are the genuine transport faults.
/// The concrete `ReadFailed` / `WriteFailed` cause is preserved on the
/// `Stream.Reader` / `Stream.Writer` for a caller (or the C boundary) to surface.
/// To distinguish a transport fault from a protocol abort at runtime: `PumpError`
/// variants catch the category, and `Peer.lastAbort` gives the typed abort reason
/// (domain, kind, diagnostic) when the variant is `ProtocolAbort`.
pub const PumpError = error{
    /// An underlying read or write failed (concrete cause on the stream).
    ConnectionLost,
    /// The stream closed mid-frame: bytes were buffered but no whole frame and
    /// no graceful boundary. Distinct from `closed`, which is clean EOF.
    TruncatedFrame,
    /// Inbound bytes are not a structurally valid frame (op:abort projected).
    MalformedFrame,
    /// An inbound frame would exceed `SessionLimits.max_frame_bytes`: its
    /// scanned length crossed the cap during decode (op:abort projected), or,
    /// the defensive mirror of that codec contract, its prefix reached the cap
    /// still incomplete.
    FrameTooLarge,
    /// A structurally valid frame was refused by session authority (op:abort
    /// projected. The session is closing).
    ProtocolAbort,
    /// The peer projected a terminal `op:abort`, but the stream refused its
    /// delivery. `Peer.lastAbort` retains the original protocol cause and the
    /// writer retains the concrete transport error.
    AbortFlushFailed,
} || std.mem.Allocator.Error;

/// A type-erased handle to the concrete stream behind a `Connection`. The
/// transport that produced the connection (e.g. `tcp`) owns the stream and
/// supplies these two operations: close it (and free whatever the transport
/// pinned to keep the reader/writer alive), and expose its pollable socket
/// descriptor when it has one. A userspace transport with no fd returns null
/// from `socketHandle` and multiplexes in its own loop.
const TransportHandle = struct {
    ctx: *anyopaque,
    close_fn: *const fn (ctx: *anyopaque) void,
    try_close_fn: ?*const fn (ctx: *anyopaque) CloseProgress = null,
    socket_handle_fn: *const fn (ctx: *anyopaque) ?std.Io.net.Socket.Handle,
    take_failure_fn: ?*const fn (ctx: *anyopaque) ?foundation.FailureChain = null,

    pub fn close(self: TransportHandle) void {
        self.close_fn(self.ctx);
    }
    pub fn tryClose(self: TransportHandle) CloseProgress {
        const advance = self.try_close_fn orelse return .complete;
        return advance(self.ctx);
    }
    pub fn socketHandle(self: TransportHandle) ?std.Io.net.Socket.Handle {
        return self.socket_handle_fn(self.ctx);
    }
    pub fn takeFailure(self: TransportHandle) ?foundation.FailureChain {
        const take = self.take_failure_fn orelse return null;
        return take(self.ctx);
    }
};

/// A transport-neutral byte-stream connection: a borrowed peer plus a
/// type-erased reader/writer pair and a handle to the transport behind them.
///
/// The connection holds `*std.Io.Reader` / `*std.Io.Writer`, the interfaces
/// `pumpOver` already speaks, never a concrete socket type, so any transport
/// that yields those interfaces drives it unchanged: TCP, the in-process pipe,
/// and the iroh QUIC stream all do. The concrete stream object lives behind
/// `TransportHandle`, owned by the transport that produced it (see
/// `tcp`). The connection only borrows the interfaces and asks the handle to
/// close the stream on `deinit`. It does not own the peer (lifetime
/// unchanged).
///
/// Because the connection borrows the reader/writer interfaces rather than
/// storing them inline, the transport must keep its concrete reader/writer at a
/// stable address for the connection's life, `std.Io.Reader`'s vtable recovers
/// that concrete reader from `&interface` by field offset, so a moved-away
/// reader would dangle. The tcp transport pins its per-connection stream on the
/// peer's allocator and frees it through the handle.
pub const Connection = struct {
    peer: *engine.Peer,
    /// The spill's allocator outlives the borrowed peer: a Host may consume
    /// protocol state before this connection's carrier finishes closing.
    allocator: std.mem.Allocator,
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    transport: TransportHandle,
    /// The host `std.Io` this connection runs on. Kept so the driver can draw
    /// handshake entropy at the I/O boundary without reaching into the
    /// transport's private stream. It is OS randomness, not transport state.
    io: std.Io,
    /// Bounded overflow for an admissible frame larger than the read buffer
    /// (see `frame_stream.Spill`). Inactive and allocation-free while frames
    /// fit the buffer. Allocates from the peer's allocator.
    ///
    /// The scan that walks this spill's frame is not here: it rides on the peer
    /// (`engine.Peer.stream_scan`), which documents why. One connection pumps
    /// one peer, so the two still name one stream.
    spill: frame_stream.Spill = .{},

    /// The close/readiness handle behind this connection's reader and writer.
    /// Public so resident transports can construct a connection without
    /// exporting the private vtable name as their own concept.
    pub const Transport = TransportHandle;

    pub fn init(
        io: std.Io,
        peer: *engine.Peer,
        r: *std.Io.Reader,
        w: *std.Io.Writer,
        transport: TransportHandle,
    ) Connection {
        return .{
            .peer = peer,
            .allocator = peer.allocator,
            .r = r,
            .w = w,
            .transport = transport,
            .io = io,
        };
    }

    /// Close the underlying stream (via the transport handle) and free the spill.
    /// Does not touch the borrowed peer.
    pub fn deinit(self: *Connection) void {
        self.spill.deinit(self.allocator);
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
        _ = try encodeAndFlush(self.peer, self.w);
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

    /// Claim the exact transport failure retained by the connection owner.
    /// A clean EOF or a transport without richer failure data returns null.
    /// A claimed failure cannot reappear.
    pub fn takeFailure(self: *Connection) ?foundation.FailureChain {
        return self.transport.takeFailure();
    }

    /// Advance, but never park in, the transport-level close transaction.
    /// The owning runtime uses the returned interest in its aggregate wait.
    pub fn advanceClose(self: *Connection) CloseProgress {
        return self.transport.tryClose();
    }

    /// Join an optional transport-level close transaction. Ordinary byte
    /// streams have no protocol below CapTP and complete immediately. Framed
    /// carriers such as WebSocket advance without allocation, waiting only on
    /// their one pollable descriptor and one caller-owned deadline.
    pub fn closeGracefully(self: *Connection, timeout_ms: i32) ?foundation.FailureChain {
        std.debug.assert(timeout_ms >= 0);
        const deadline = clock.nowMs(self.io) +| timeout_ms;
        while (true) {
            switch (self.transport.tryClose()) {
                .complete => return null,
                .failed => return self.takeFailure() orelse .init(error.TransportCloseFailed),
                .wait_read, .wait_write => |progress| {
                    const now = clock.nowMs(self.io);
                    if (now >= deadline) return .init(error.CloseTimedOut);
                    const remaining: i32 = @intCast(@min(
                        @as(i64, std.math.maxInt(i32)),
                        deadline - now,
                    ));
                    const ready = switch (progress) {
                        .wait_read => self.waitReadable(remaining),
                        .wait_write => self.waitWritable(remaining),
                        else => unreachable,
                    } catch return self.takeFailure() orelse .init(error.ConnectionLost);
                    if (!ready) return .init(error.CloseTimedOut);
                },
            }
        }
    }

    /// Whether a read would make progress within `timeout_ms` for an fd-backed
    /// transport: true when bytes are already buffered or the fd polls readable,
    /// false only on a poll timeout. A poll failure means the transport is gone.
    ///
    /// A transport with no pollable fd returns true after the buffer check. That
    /// is not a deadline guarantee. It is the blocking-stream fallback for
    /// userspace transports. Deadline-sensitive multiplexers reject fd-less
    /// connections before they call this.
    pub fn waitReadable(self: *Connection, timeout_ms: i32) error{ConnectionLost}!bool {
        if (self.hasBufferedInbound()) return true;
        const handle = self.socketHandle() orelse return true;
        var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = poll.wait(&fds, timeout_ms) catch return error.ConnectionLost;
        if (fds[0].revents & std.posix.POLL.NVAL != 0) return error.ConnectionLost;
        return ready != 0;
    }

    /// Whether a write would make progress within `timeout_ms` for an
    /// fd-backed transport. This is a readiness probe, not a whole-frame
    /// delivery guarantee: the writer can still report the concrete failure.
    /// A transport with no pollable fd returns true, matching `waitReadable`'s
    /// blocking-stream fallback.
    pub fn waitWritable(self: *Connection, timeout_ms: i32) error{ConnectionLost}!bool {
        const handle = self.socketHandle() orelse return true;
        var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.OUT, .revents = 0 }};
        const ready = poll.wait(&fds, timeout_ms) catch return error.ConnectionLost;
        if (fds[0].revents & std.posix.POLL.NVAL != 0) return error.ConnectionLost;
        return ready != 0 and (fds[0].revents & (std.posix.POLL.OUT | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0;
    }

    /// Whether a raw read on this connection's reader would make progress
    /// right now: bytes already buffered on the reader. The byte-fed owning
    /// host checks this before polling, because buffered bytes are progress
    /// the OS poll cannot report. Distinct from `hasBufferedInbound`, which
    /// also consults the parse spill this face never activates.
    pub fn hasBufferedRaw(self: *const Connection) bool {
        return self.r.bufferedLen() > 0;
    }

    /// Pump until `pred(peer)` holds or the stream closes. The only blocking
    /// convenience. The primitive it builds on is `pump`. Returns the last
    /// `Progress` (`.closed` if the stream ended first).
    ///
    /// `timeout_ms` is the per-read deadline, the bounded-read hook on an
    /// untrusted partner (ADR-0081). A timeout of 0 means each read blocks
    /// indefinitely. The caller accepts the risk of an unbounded block against
    /// a silent partner. A positive value flushes queued outbound first (the
    /// partner cannot answer a request still queued on our side, so waiting
    /// before flushing would deadlock), then waits up to `timeout_ms` for the
    /// read to make progress, returning `error.Timeout` on a poll timeout
    /// instead of parking the fiber for the connection's life. The deadline
    /// value is the caller's, policy lives above the net layer, but exposing
    /// the bound is the net layer's job. A transport with no pollable fd (a
    /// userspace stream that multiplexes in its own loop) is unbounded even with
    /// a deadline, exactly as `waitReadable` reports: the timeout binds fd-backed
    /// transports (tcp, keyed-tcp).
    pub fn runUntil(
        self: *Connection,
        pred: *const fn (*engine.Peer) bool,
        timeout_ms: i32,
    ) (PumpError || error{Timeout})!Progress {
        if (pred(self.peer)) return .idle;
        while (true) {
            if (timeout_ms != 0) {
                try self.flush();
                if (!try self.waitReadable(timeout_ms)) return error.Timeout;
            }
            const progress = try self.pump();
            if (progress == .closed) return .closed;
            if (pred(self.peer)) return progress;
        }
    }
};

/// The index of a connection in `conns` with readable progress: reader-buffered
/// bytes now, or the first fd the OS poll reports readable (or hung up, which a
/// read will surface as closure) within `timeout_ms`. Null only on a poll
/// timeout. The multi-connection wait a byte-fed owning host blocks through.
/// `waitReadable` above is its one-connection sibling.
///
/// It reports the *first* ready index, so a caller multiplexing connections
/// that must not starve each other rotates the slice it passes between waits:
/// a partner that keeps its socket readable holds a fixed low index forever.
///
/// Every connection must have a pollable fd. The caller refused fd-less
/// transports at open, because a blocking multiplex cannot wait on a stream
/// that reports no readiness, and `pollfds` is caller-owned scratch at least
/// `conns.len + extra_fds.len` long, so the wait itself allocates nothing. A
/// negative `timeout_ms` waits forever (the OS poll convention). The caller's
/// budget arithmetic keeps an expired deadline from reaching here.
pub fn waitAnyReadable(
    conns: []const *Connection,
    pollfds: []std.posix.pollfd,
    timeout_ms: i32,
    extra_fds: []const std.posix.fd_t,
) error{ConnectionLost}!?usize {
    return waitAny(conns, &.{}, pollfds, timeout_ms, extra_fds, &.{}, 0);
}

/// Wait for caller-selected read/write interest on each connection and extra
/// descriptor. Empty interest slices mean readable for every corresponding
/// row, preserving the ordinary pump contract without a second implementation.
///
/// `start` is where the scan for a ready connection begins, wrapping around,
/// so a caller that reports the first ready row can rotate fairness by
/// advancing one index per wait instead of rotating the rows themselves.
/// Extra descriptors always scan after every connection.
pub fn waitAny(
    conns: []const *Connection,
    conn_interests: []const WaitInterest,
    pollfds: []std.posix.pollfd,
    timeout_ms: i32,
    extra_fds: []const std.posix.fd_t,
    extra_interests: []const WaitInterest,
    start: usize,
) error{ConnectionLost}!?usize {
    std.debug.assert(conn_interests.len == 0 or conn_interests.len == conns.len);
    std.debug.assert(extra_interests.len == 0 or extra_interests.len == extra_fds.len);
    std.debug.assert(conns.len == 0 or start < conns.len);
    const rows = conns.len + extra_fds.len;
    std.debug.assert(pollfds.len >= rows);
    for (0..conns.len) |k| {
        const i = (start + k) % conns.len;
        const conn = conns[i];
        const interest = if (conn_interests.len == 0) WaitInterest.read else conn_interests[i];
        if (interest == .read and conn.hasBufferedRaw()) return i;
        const handle = conn.socketHandle() orelse unreachable;
        pollfds[i] = .{
            .fd = handle,
            .events = if (interest == .read) std.posix.POLL.IN else std.posix.POLL.OUT,
            .revents = 0,
        };
    }
    // The caller's out-of-band descriptors, multiplexed-resident readiness and
    // the settle-mailbox wake (ADR-0102), poll as trailing rows and report
    // as `conns.len + i`, indexes no connection occupies.
    for (extra_fds, 0..) |fd, i| {
        const interest = if (extra_interests.len == 0) WaitInterest.read else extra_interests[i];
        pollfds[conns.len + i] = .{
            .fd = fd,
            .events = if (interest == .read) std.posix.POLL.IN else std.posix.POLL.OUT,
            .revents = 0,
        };
    }
    if (rows == 0) return null;
    const ready = poll.wait(pollfds[0..rows], timeout_ms) catch return error.ConnectionLost;
    if (ready == 0) return null;
    for (0..rows) |k| {
        const i = if (k < conns.len) (start + k) % conns.len else k;
        const fd = pollfds[i];
        if (fd.revents & std.posix.POLL.NVAL != 0) return error.ConnectionLost;
        if (fd.revents & (std.posix.POLL.IN | std.posix.POLL.OUT | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) return i;
    }
    return null;
}

/// The framing core, decoupled from sockets: drive one step of progress over a
/// type-erased `*std.Io.Reader` / `*std.Io.Writer`, with `spill` as the bounded
/// overflow for a frame larger than the read buffer. Proven with `Reader.fixed`
/// / `std.testing.Reader` and `Writer.fixed`. `Connection.pump` is the
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
/// streams without draining can head-of-line-block a fiber mid-`writeAll`.
/// That workload rides the completion loop, whose bounded outbound queue and
/// read parking (ADR-0042) exist for exactly it.
pub fn pumpOver(
    peer: *engine.Peer,
    r: *std.Io.Reader,
    w: *std.Io.Writer,
    spill: *frame_stream.Spill,
) PumpError!Progress {
    const sent = try encodeAndFlush(peer, w);

    const supply = if (spill.isActive()) spill.bytes() else r.buffered();
    if (supply.len > 0) {
        const outcome = frame_stream.recvOuterPrefix(peer, supply) catch |err| {
            // Dispatch projected the terminal frame directly onto outbound.
            // Preserve a refused delivery as its own pump outcome; the peer's
            // lastAbort still carries this original apply cause.
            return flushProjectedAbort(peer, w, err);
        };
        switch (outcome) {
            .consumed => |n| {
                if (spill.isActive()) spill.consume(peer.allocator, n, frame_stream.spill_retain_bytes) else r.toss(n);
                return .{ .received = n };
            },
            .incomplete => {},
        }
    }

    // A flush with no inbound frame is still real progress.
    if (sent > 0) return .{ .sent = sent };

    return switch (try frame_stream.fillThroughSpill(r, spill, peer.allocator)) {
        .filled => .idle,
        .closed => .closed,
    };
}

/// Write and flush every outbound frame, returning the byte count. The frame is
/// owned by `takeOutbound`. This releases it after writing. `writeAll` streams a
/// frame larger than the write buffer straight through.
fn drainOutbound(peer: *engine.Peer, w: *std.Io.Writer) std.Io.Writer.Error!usize {
    var total: usize = 0;
    while (peer.takeOutbound()) |frame_value| {
        var frame: foundation.Frame = frame_value;
        defer frame.deinit();
        const bytes = frame.bytes();
        total += try frame_stream.writeFrameBytes(w, bytes);
    }
    if (total > 0) try w.flush();
    return total;
}

/// Map a recv-apply / encode error onto the pump's surface. Decode verdicts
/// carry their own names. Any other session authority rejection has already
/// projected an abort, so it surfaces as `ProtocolAbort`. The parameter stays
/// `anyerror`: the callers catch five different inferred error
/// sets (`Peer.stepToIdle`, `recvOuterPrefix`, `feedBytes`,
/// `feedTransportPacket`, `resumeFeed`), which the toolchain coerces only to
/// `anyerror`, so no named set can receive all of them and the `else` arm
/// remains the classification.
pub fn classifyApplyError(err: anyerror) PumpError {
    return switch (err) {
        error.MalformedFrame, error.InvalidFrameShape, error.MalformedView => error.MalformedFrame,
        error.FrameTooLarge => error.FrameTooLarge,
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProtocolAbort,
    };
}

/// Encode the peer's queued sends and write them to `w`, returning the bytes
/// written. The write-half `Connection.flush` and `pumpOver` (and `pump`) both
/// ride: `flush` discards the count, the pumps carry it as their sent tally.
/// The abort-flush contract is the point of the shared spine. When
/// `stepToIdle` fails it has already projected the fail-loud `op:abort` frame
/// onto outbound. A successful drain returns that cause classified onto the
/// pump surface. A refused terminal-frame write returns `AbortFlushFailed`,
/// with the original cause still readable through `Peer.lastAbort`. A drain
/// failure on the success path is ordinary `ConnectionLost`.
fn encodeAndFlush(peer: *engine.Peer, w: *std.Io.Writer) PumpError!usize {
    peer.stepToIdle() catch |err| {
        return flushProjectedAbort(peer, w, err);
    };
    return drainOutbound(peer, w) catch return error.ConnectionLost;
}

fn flushProjectedAbort(peer: *engine.Peer, w: *std.Io.Writer, primary: anyerror) PumpError {
    _ = drainOutbound(peer, w) catch return error.AbortFlushFailed;
    return classifyApplyError(primary);
}
