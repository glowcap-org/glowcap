//! The WebRTC DataChannel netlayer resident (ADR-0089, phase 2).
//!
//! This wraps the `pancake_webrtc_sidecar` C ABI (`transports/webrtc/`) so a
//! keyed OCapN session runs byte-for-byte over a reliable, ordered
//! `RTCDataChannel`. The byte path mirrors the iroh resident (ADR-0055): the
//! sidecar connection is presented as the same `*std.Io.Reader` /
//! `*std.Io.Writer` pair every transport hands the engine, pinned so the vtable
//! can recover the concrete reader and writer by field offset.
//!
//! WebRTC differs from iroh in how a channel comes up. A peer has no dialable
//! address, so there is no `connect(locator)` here yet. The channel is
//! established by an out-of-band signaling exchange the caller drives: the
//! offerer produces an SDP offer, the answerer an SDP answer, and both trickle
//! ICE candidates until the channel opens. Phase 2 carries those strings through
//! a test harness; phase 4 routes a `webrtc` locator through the netlayer
//! dispatch, and phase 5 carries signaling over an OCapN capability (ADR-0089).
//! Until then this resident is compiled and type-checked but not registered as a
//! `Netlayer`, exactly as the ADR sequences the phases.
//!
//! The resident compiles as its own module outside the `pancake` root namespace,
//! so its externs resolve only when the sidecar staticlib links. A hermetic
//! object build type-checks it under plain `zig build check` with no cargo.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const net = @import("net");

const Io = std.Io;
const Connection = net.Connection;
const Buffers = net.netlayer.Buffers;
const Netlayer = net.netlayer.Netlayer;

/// The transport symbol this resident registers under once phase 4 wires it into
/// the netlayer dispatch, and signs into `op:start-session`.
pub const transport_name = model.transport.webrtc;

/// The peer's Ed25519 designator length, the same key width keyed-tcp and iroh
/// name their peers by.
pub const designator_len = foundation.crypto.PeerKey.designator_len;

// ── Sidecar C ABI (transports/webrtc/src/lib.rs) ─────────────────────────────
// One opaque handle is both endpoint and connection: a WebRTC peer owns exactly
// one data channel, so there is no separate connection type.

const CPeer = opaque {};

extern fn pancake_webrtc_sidecar_peer_new(is_offerer: i32) ?*CPeer;
extern fn pancake_webrtc_sidecar_peer_create_offer(peer: *CPeer, out: [*]u8, cap: usize, out_len: *usize) i32;
extern fn pancake_webrtc_sidecar_peer_create_answer(peer: *CPeer, out: [*]u8, cap: usize, out_len: *usize) i32;
extern fn pancake_webrtc_sidecar_peer_set_remote(peer: *CPeer, sdp: [*]const u8, sdp_len: usize, is_offer: i32) i32;
extern fn pancake_webrtc_sidecar_peer_add_remote_candidate(peer: *CPeer, cand: [*]const u8, cand_len: usize) i32;
extern fn pancake_webrtc_sidecar_peer_next_local_candidate(peer: *CPeer, out: [*]u8, cap: usize, out_len: *usize) i32;
extern fn pancake_webrtc_sidecar_peer_wait_open(peer: *CPeer, timeout_ms: u64) i32;
extern fn pancake_webrtc_sidecar_conn_read(peer: *CPeer, buf: [*]u8, len: usize) isize;
extern fn pancake_webrtc_sidecar_conn_write(peer: *CPeer, buf: [*]const u8, len: usize) isize;
extern fn pancake_webrtc_sidecar_conn_close(peer: *CPeer) void;
extern fn pancake_webrtc_sidecar_peer_free(peer: *CPeer) void;

/// Sidecar return codes, kept in lockstep with the constants in
/// `transports/webrtc/src/lib.rs`.
const rc_ok: i32 = 0;
const rc_would_block: i32 = -2;
const rc_buffer_too_small: i32 = -3;

// ── The byte path: sidecar connection as a pinned Reader/Writer ───────────────

/// The blocking read/write source over one sidecar peer's data channel. A read
/// parks the calling thread until bytes arrive or the channel closes; a write
/// sends eagerly, so `flush` only reports a channel that died under the write.
const ConnSource = struct {
    peer: *CPeer,

    pub fn readSome(self: ConnSource, dest: []u8) Io.Reader.Error!usize {
        const n = pancake_webrtc_sidecar_conn_read(self.peer, dest.ptr, dest.len);
        if (n == 0) return error.EndOfStream;
        if (n < 0) return error.ReadFailed;
        return @intCast(n);
    }

    pub fn writeAll(self: ConnSource, bytes: []const u8) Io.Writer.Error!void {
        if (pancake_webrtc_sidecar_conn_write(self.peer, bytes.ptr, bytes.len) < 0) return error.WriteFailed;
    }

    pub fn flush(self: ConnSource) Io.Writer.Error!void {
        // Writes reach SCTP eagerly; there is no buffered send to drain.
        _ = self;
    }
};

/// Closing the stream finishes the data channel (the partner reads a clean end
/// of stream) but does not free the sidecar peer: the `Peer` owns that handle
/// and frees it in `deinit`, after the connection is closed.
const StreamContext = struct {
    peer: *CPeer,

    pub fn closeStream(self: StreamContext) void {
        pancake_webrtc_sidecar_conn_close(self.peer);
    }
};

const WebrtcStream = net.netlayer.PinnedStream(ConnSource, StreamContext);

// ── The resident ─────────────────────────────────────────────────────────────

/// A signaling call that could not complete. `BufferTooSmall` names an SDP or
/// candidate too large for the caller's buffer; the caller retries with a larger
/// one. `SignalFailed` is any other sidecar refusal.
pub const SignalError = error{ SignalFailed, BufferTooSmall };

/// One WebRTC peer: the sidecar handle for its connection and its single data
/// channel, plus the `std.Io` the connection reads and writes through. The
/// caller creates a `Peer`, drives the signaling exchange to bring the channel
/// up, then turns it into a `Connection` a keyed session runs over.
pub const Peer = struct {
    peer: *CPeer,

    pub const InitError = error{PeerCreateFailed};

    /// Create a peer in one of the two signaling roles. The offerer creates the
    /// data channel and produces the SDP offer; the answerer receives the
    /// channel and produces the answer. The byte-fed path (the C ABI and
    /// bindings) reads and writes session bytes directly with `read` / `write`;
    /// a `net.Connection` consumer passes its `std.Io` to `connection`.
    pub fn init(is_offerer: bool) InitError!Peer {
        const peer = pancake_webrtc_sidecar_peer_new(@intFromBool(is_offerer)) orelse return error.PeerCreateFailed;
        return .{ .peer = peer };
    }

    /// Close the data channel and connection without freeing the handle,
    /// waking any parked reader with end of stream. Idempotent; the shutdown
    /// lever for a host whose read parks on another thread. `deinit` still frees.
    pub fn close(self: *Peer) void {
        pancake_webrtc_sidecar_conn_close(self.peer);
    }

    /// Free the sidecar peer, closing the channel and shutting down its runtime.
    /// Call after the `Connection` this peer minted is closed.
    pub fn deinit(self: *Peer) void {
        pancake_webrtc_sidecar_peer_free(self.peer);
        self.* = undefined;
    }

    /// Produce this peer's SDP offer into `out` and set it as the local
    /// description, writing the SDP length to `out_len` and returning it as a
    /// slice of `out`. On `error.BufferTooSmall` the required length is still
    /// written to `out_len`, so the caller retries with a buffer that size.
    /// Offerer only.
    pub fn createOffer(self: *Peer, out: []u8, out_len: *usize) SignalError![]const u8 {
        return switch (pancake_webrtc_sidecar_peer_create_offer(self.peer, out.ptr, out.len, out_len)) {
            rc_ok => out[0..out_len.*],
            rc_buffer_too_small => error.BufferTooSmall,
            else => error.SignalFailed,
        };
    }

    /// Produce this peer's SDP answer into `out` and set it as the local
    /// description, writing the SDP length to `out_len`. Answerer only, after
    /// `setRemoteOffer`. `error.BufferTooSmall` still writes the required length.
    pub fn createAnswer(self: *Peer, out: []u8, out_len: *usize) SignalError![]const u8 {
        return switch (pancake_webrtc_sidecar_peer_create_answer(self.peer, out.ptr, out.len, out_len)) {
            rc_ok => out[0..out_len.*],
            rc_buffer_too_small => error.BufferTooSmall,
            else => error.SignalFailed,
        };
    }

    /// Set the far offerer's SDP offer as the remote description. Answerer side.
    pub fn setRemoteOffer(self: *Peer, sdp: []const u8) SignalError!void {
        if (pancake_webrtc_sidecar_peer_set_remote(self.peer, sdp.ptr, sdp.len, 1) != rc_ok) return error.SignalFailed;
    }

    /// Set the far answerer's SDP answer as the remote description. Offerer side.
    pub fn setRemoteAnswer(self: *Peer, sdp: []const u8) SignalError!void {
        if (pancake_webrtc_sidecar_peer_set_remote(self.peer, sdp.ptr, sdp.len, 0) != rc_ok) return error.SignalFailed;
    }

    /// Add one ICE candidate the far peer gathered, as the JSON its
    /// `nextLocalCandidate` produced.
    pub fn addRemoteCandidate(self: *Peer, candidate: []const u8) SignalError!void {
        if (pancake_webrtc_sidecar_peer_add_remote_candidate(self.peer, candidate.ptr, candidate.len) != rc_ok) return error.SignalFailed;
    }

    /// Drain the next locally gathered ICE candidate into `out` as JSON, writing
    /// its length to `out_len`, or null when none is pending yet. The caller
    /// ferries each to the far peer. `error.BufferTooSmall` still writes the
    /// required length to `out_len`.
    pub fn nextLocalCandidate(self: *Peer, out: []u8, out_len: *usize) SignalError!?[]const u8 {
        return switch (pancake_webrtc_sidecar_peer_next_local_candidate(self.peer, out.ptr, out.len, out_len)) {
            rc_ok => out[0..out_len.*],
            rc_would_block => null,
            rc_buffer_too_small => error.BufferTooSmall,
            else => error.SignalFailed,
        };
    }

    /// Block until the data channel opens, or `timeout_ms` elapses. Returns true
    /// once open.
    pub fn waitOpen(self: *Peer, timeout_ms: u64) bool {
        return pancake_webrtc_sidecar_peer_wait_open(self.peer, timeout_ms) == rc_ok;
    }

    /// Present the open data channel as a `Connection` a keyed session runs over,
    /// reading and writing through `io`, with `bufs` sizing its reader and
    /// writer. Call after `waitOpen` reports the channel open. The returned
    /// connection borrows this peer's handle; it must be closed before `deinit`.
    pub fn connection(self: *Peer, io: Io, engine_peer: *engine.Peer, bufs: Buffers) std.mem.Allocator.Error!Connection {
        const stream = try WebrtcStream.create(
            engine_peer.allocator,
            .{ .peer = self.peer },
            .{ .peer = self.peer },
            bufs,
            .{ .peer = self.peer },
        );
        return stream.intoConnection(io, engine_peer);
    }

    /// A byte-fed transport error: `Closed` is a clean end of stream, `Failed`
    /// any other refusal from the sidecar.
    /// A read observes both a clean end of stream (`Closed`, a zero-length
    /// sidecar read) and a fault (`Failed`); a write only ever faults.
    pub const ByteError = error{ Closed, Failed };
    pub const WriteError = error{Failed};

    /// Blocking read of session bytes into `buf`, returning the count read. The
    /// byte-fed path the C ABI and bindings drive, without a `net.Connection`.
    pub fn read(self: *Peer, buf: []u8) ByteError!usize {
        const n = pancake_webrtc_sidecar_conn_read(self.peer, buf.ptr, buf.len);
        if (n == 0) return error.Closed;
        if (n < 0) return error.Failed;
        return @intCast(n);
    }

    /// Write session bytes, returning the count written (all of `bytes` on
    /// success, since the sidecar sends the whole slice). The sidecar write
    /// returns the length or a fault, never a partial or a zero, so a write
    /// cannot report `Closed`.
    pub fn write(self: *Peer, bytes: []const u8) WriteError!usize {
        const n = pancake_webrtc_sidecar_conn_write(self.peer, bytes.ptr, bytes.len);
        if (n < 0) return error.Failed;
        return @intCast(n);
    }
};

// ── Netlayer designator scheme (ADR-0089 phase 4 scaffolding) ────────────────
// A webrtc peer is named by its Ed25519 key, so its designator scheme is `key`,
// the same as keyed-tcp and iroh. This vtable declares that fact, which is what
// arms the driver's dial-side identity pin and what the designator-scheme sync
// checks against the byte-fed `driver_core.vocab` table. Dialing a `webrtc`
// locator through the plain netlayer is not wired yet: a channel comes up
// through a signaling exchange (offer, answer, ICE), not a synchronous dial of a
// dialable address, so `dial` and `listen` fail closed until the signaling
// capability lands (ADR-0089 phase 5). The live phase-2 path drives a `Peer` and
// its signaling methods directly, above this seam.

const netlayer_vtable = Netlayer.VTable{
    .transport_name = transport_name,
    .designator_scheme = .key,
    .dial = residentDial,
    .listen = residentListen,
};

fn residentDial(ctx: *anyopaque, peer: *engine.Peer, locator: model.PeerLocator, bufs: Buffers) net.netlayer.DialError!Connection {
    _ = .{ ctx, peer, locator, bufs };
    // A webrtc locator carries no dialable address; the channel is established
    // by the signaling exchange, not a synchronous dial (ADR-0089 phase 5).
    return error.InvalidAddress;
}

fn residentListen(ctx: *anyopaque, allocator: std.mem.Allocator, config: net.netlayer.ListenConfig) net.netlayer.ListenError!net.netlayer.Listener {
    _ = .{ ctx, allocator, config };
    // A webrtc peer opens no listening socket; it is reached through signaling.
    return error.InvalidAddress;
}

/// The webrtc netlayer resident. It holds no shared endpoint state today: a
/// webrtc channel is per-peer and comes up through signaling, not a bound
/// endpoint. A host that registers it (`netlayer()`) gains locator dispatch for
/// the `webrtc` transport with the `.key` designator scheme declared above, so a
/// `webrtc` locator routes here and fails closed with a clear address error
/// rather than reading as an unknown transport. The actual channel-open is the
/// signaling exchange (ADR-0089 phase 5); the live phase-2 path drives a `Peer`
/// directly, above this seam.
pub const Resident = struct {
    pub fn netlayer(self: *Resident) Netlayer {
        return .{ .ctx = self, .vtable = &netlayer_vtable };
    }
};
