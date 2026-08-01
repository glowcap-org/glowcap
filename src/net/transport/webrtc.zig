//! WebRTC DataChannel transport: a peer-to-peer channel for keyed OCapN
//! sessions. Unlike TCP or iroh, there is no dialable address — the channel is
//! established by an SDP signaling exchange (offer, answer, ICE candidates).
//! A `Resident` owns the shared sidecar runtime and readiness fd. Callers create
//! `Peer`s from it, drive signaling directly, then run session bytes over the
//! open DataChannel through either the explicit blocking connection or try-I/O.
//!
//! The readiness path owns channel progress and non-blocking byte I/O. The
//! explicit blocking path presents the same channel as a pinned
//! `*std.Io.Reader` / `*std.Io.Writer` pair for `BlockingSession`.
//!
//! ## Usage sequence
//!
//! 1. Call `Resident.init()`, register `Resident.readinessFd`, then create a peer
//!    in one signaling role with `resident.newPeer(is_offerer)`.
//! 2. Submit offers, answers, and remote candidates outside the reactor turn;
//!    peer creation and signaling submissions are synchronous control calls.
//! 3. When the fd wakes, call `Resident.drainReady` and route each record by its
//!    stable `PeerId`. Drain local candidates on `ev_candidate`; call `checkOpen`
//!    on `ev_open` and stop on `ev_closed`. A blocking owner can use
//!    `Resident.pollReady`, which performs the same ordered drain.
//! 4. Once open, use `tryRead` / `tryWrite` from that readiness loop, or call
//!    `connection()` to present the channel as a blocking `net.Connection`.
//!
//! ## Dial posture
//!
//! A `Resident` deliberately has no `dial` or `listen`: a bare WebRTC locator
//! carries no signaling authority. The dial classifier still recognizes the
//! transport symbol and validates the key designator. `driver_core.planDial` returns
//! `DialPlan.signaling`, and `PANCAKE_DIAL_SHAPE_SIGNALING` ships in every
//! binding's constants table. The resident compiles and type-checks under
//! `zig build check` but is not a `Netlayer`. Today a caller must drive signaling
//! and adopt the resulting channel explicitly; generic Host dialing and handoff
//! redemption over WebRTC remain roadmap work.
//!
//! ## Sidecar posture
//!
//! The resident wraps the `pancake_webrtc_sidecar` C ABI (`transports/webrtc/`).
//! It compiles as its own module outside the `pancake` root namespace, so its
//! externs resolve only when the sidecar staticlib links. A hermetic object build
//! type-checks it under plain `zig build check` with no cargo.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const net = @import("net");

const Io = std.Io;
const Connection = net.Connection;
const Buffers = net.netlayer.Buffers;

/// The transport symbol this resident signs into `op:start-session`. The dial
/// classifier recognizes it; the resident is not registered as a `Netlayer`
/// (see "Dial posture" above).
pub const transport_name = model.transport.webrtc;

/// WebRTC locators name peers by keyed-session identity even though this
/// resident intentionally exposes no address-based `Netlayer` vtable.
pub const designator_scheme: net.netlayer.DesignatorScheme = .key;

/// The peer's Ed25519 designator length, the same key width keyed-tcp and iroh
/// name their peers by.
pub const designator_len = foundation.crypto.PeerKey.designator_len;

// ── Sidecar C ABI (transports/webrtc/src/lib.rs) ─────────────────────────────
// The endpoint owns the shared runtime and readiness namespace. Each peer owns
// exactly one data channel, so there is no separate connection handle.

const CPeer = opaque {};
const CEndpoint = opaque {};

extern fn pancake_webrtc_sidecar_endpoint_new() ?*CEndpoint;
extern fn pancake_webrtc_sidecar_endpoint_readiness_fd(endpoint: *const CEndpoint) i32;
extern fn pancake_webrtc_sidecar_endpoint_drain_ready(endpoint: *const CEndpoint, out: [*]ReadyEvent, out_cap: usize) isize;
extern fn pancake_webrtc_sidecar_endpoint_free(endpoint: *CEndpoint) void;
extern fn pancake_webrtc_sidecar_peer_new(endpoint: *CEndpoint, is_offerer: i32) ?*CPeer;
extern fn pancake_webrtc_sidecar_peer_create_offer(peer: *CPeer, out: [*]u8, cap: usize, out_len: *usize) i32;
extern fn pancake_webrtc_sidecar_peer_create_answer(peer: *CPeer, out: [*]u8, cap: usize, out_len: *usize) i32;
extern fn pancake_webrtc_sidecar_peer_set_remote(peer: *CPeer, sdp: [*]const u8, sdp_len: usize, is_offer: i32) i32;
extern fn pancake_webrtc_sidecar_peer_add_remote_candidate(peer: *CPeer, cand: [*]const u8, cand_len: usize) i32;
extern fn pancake_webrtc_sidecar_peer_next_local_candidate(peer: *CPeer, out: [*]u8, cap: usize, out_len: *usize) i32;
extern fn pancake_webrtc_sidecar_peer_id(peer: *const CPeer) usize;
extern fn pancake_webrtc_sidecar_peer_is_open(peer: *const CPeer) i32;
extern fn pancake_webrtc_sidecar_conn_read(peer: *CPeer, buf: [*]u8, len: usize) isize;
extern fn pancake_webrtc_sidecar_conn_write(peer: *CPeer, buf: [*]const u8, len: usize) isize;
extern fn pancake_webrtc_sidecar_conn_try_read(peer: *CPeer, buf: [*]u8, len: usize) isize;
extern fn pancake_webrtc_sidecar_conn_try_write(peer: *CPeer, buf: [*]const u8, len: usize) isize;
extern fn pancake_webrtc_sidecar_conn_close(peer: *CPeer) void;
extern fn pancake_webrtc_sidecar_peer_free(peer: *CPeer) void;

/// Sidecar return codes, kept in lockstep with the constants in
/// `transports/webrtc/src/lib.rs`.
const rc_ok: i32 = 0;
const rc_would_block: i32 = -2;
const rc_buffer_too_small: i32 = -3;

pub const ev_open: u32 = 1;
pub const ev_candidate: u32 = 2;
pub const ev_readable: u32 = 4;
pub const ev_writable: u32 = 8;
pub const ev_closed: u32 = 16;

/// One resident readiness record. `subject` is a stable, nonzero `PeerId`
/// minted by that resident and never reused during its lifetime.
pub const ReadyEvent = extern struct {
    subject: usize,
    events: u32,
};

pub const PeerId = enum(usize) {
    _,
};

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

/// One WebRTC peer: the sidecar handle for its connection and single data
/// channel. The caller creates a `Peer`, drives the signaling exchange to bring
/// the channel up, then uses try-I/O or turns it into a blocking `Connection`.
pub const Peer = struct {
    peer: *CPeer,

    pub const InitError = error{PeerCreateFailed};

    /// Create a peer in one of the two signaling roles. The offerer creates the
    /// data channel and produces the SDP offer; the answerer receives the
    /// channel and produces the answer. The readiness path reads and writes
    /// session bytes with `tryRead` / `tryWrite`; a blocking `net.Connection`
    /// consumer passes its `std.Io` to `connection`.
    fn init(resident: *Resident, is_offerer: bool) InitError!Peer {
        const peer = pancake_webrtc_sidecar_peer_new(resident.endpoint, @intFromBool(is_offerer)) orelse return error.PeerCreateFailed;
        return .{ .peer = peer };
    }

    /// Stable resident-scoped identity carried by `ReadyEvent.subject`.
    pub fn id(self: *const Peer) PeerId {
        const raw = pancake_webrtc_sidecar_peer_id(self.peer);
        std.debug.assert(raw != 0);
        return @enumFromInt(raw);
    }

    /// Close the data channel and connection without freeing the handle,
    /// waking any parked reader with end of stream. Idempotent; the shutdown
    /// lever for a host whose read parks on another thread. `deinit` still frees.
    pub fn close(self: *Peer) void {
        pancake_webrtc_sidecar_conn_close(self.peer);
    }

    /// Free the sidecar peer and release its reference to the resident's shared
    /// runtime. Call after the `Connection` this peer minted is closed.
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

    /// Non-blocking channel-open check. A false result means wait for an
    /// `ev_open` or `ev_closed` readiness record and retry.
    pub const OpenError = error{ WouldBlock, Closed };

    pub fn checkOpen(self: *const Peer) OpenError!void {
        return switch (pancake_webrtc_sidecar_peer_is_open(self.peer)) {
            rc_ok => {},
            rc_would_block => error.WouldBlock,
            else => error.Closed,
        };
    }

    /// Present the open data channel as a `Connection` a keyed session runs over,
    /// reading and writing through `io`, with `bufs` sizing its reader and
    /// writer. Call after `checkOpen` succeeds. The connection borrows this
    /// peer's handle and must close before `deinit`.
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

    pub const TryByteError = error{ WouldBlock, Closed, Failed };

    /// Non-blocking read for readiness owners. `WouldBlock` means re-arm on
    /// `ev_readable`; `Closed` is clean end of stream.
    pub fn tryRead(self: *Peer, buf: []u8) TryByteError!usize {
        const n = pancake_webrtc_sidecar_conn_try_read(self.peer, buf.ptr, buf.len);
        if (n == 0) return error.Closed;
        if (n == rc_would_block) return error.WouldBlock;
        if (n < 0) return error.Failed;
        return @intCast(n);
    }

    /// Copy a prefix into the bounded sidecar send queue and return immediately.
    /// Advance by the returned count. `WouldBlock` means re-arm on `ev_writable`
    /// and retry the remaining slice.
    pub fn tryWrite(self: *Peer, bytes: []const u8) TryByteError!usize {
        const n = pancake_webrtc_sidecar_conn_try_write(self.peer, bytes.ptr, bytes.len);
        if (n == rc_would_block) return error.WouldBlock;
        if (n < 0) return error.Failed;
        return @intCast(n);
    }
};

/// The WebRTC netlayer resident: one shared sidecar runtime, readiness fd, and
/// stable peer-id namespace. It intentionally exposes no `Netlayer`: a bare
/// `webrtc` locator carries no signaling authority, so generic address-based
/// dial and listen methods would be false APIs. The host's dial classifier still
/// identifies the signaling shape; a signaling owner creates peers here.
pub const Resident = struct {
    endpoint: *CEndpoint,

    pub const InitError = error{EndpointCreateFailed};

    pub fn init() InitError!Resident {
        return .{
            .endpoint = pancake_webrtc_sidecar_endpoint_new() orelse return error.EndpointCreateFailed,
        };
    }

    pub fn deinit(self: *Resident) void {
        pancake_webrtc_sidecar_endpoint_free(self.endpoint);
        self.* = undefined;
    }

    pub fn newPeer(self: *Resident, is_offerer: bool) Peer.InitError!Peer {
        return Peer.init(self, is_offerer);
    }

    /// Borrowed, read-only OS readiness fd. Register it once and call
    /// `drainReady` whenever it wakes; the resident owns it until `deinit`.
    pub fn readinessFd(self: *const Resident) i32 {
        return pancake_webrtc_sidecar_endpoint_readiness_fd(self.endpoint);
    }

    /// Clear the fd's coalesced wake bytes, then drain stable peer-id records.
    /// Owning that order here makes a lost-wakeup ordering error unavailable to
    /// callers. A concurrent signal either joins this drain or leaves its wake
    /// byte for the next poll.
    pub fn drainReady(self: *const Resident, out: []ReadyEvent) error{ReadinessFailed}!usize {
        const count = pancake_webrtc_sidecar_endpoint_drain_ready(self.endpoint, out.ptr, out.len);
        if (count < 0) return error.ReadinessFailed;
        return @intCast(count);
    }

    /// Park on the readiness fd for at most `timeout_ms`, then perform the same
    /// ordered wake-byte and record drain as `drainReady`. This is the blocking
    /// embedding helper; reactors register `readinessFd` and call `drainReady`
    /// from their own poller instead.
    pub fn pollReady(self: *const Resident, out: []ReadyEvent, timeout_ms: i32) error{ReadinessFailed}!usize {
        const fd = self.readinessFd();
        if (fd < 0) return error.ReadinessFailed;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, timeout_ms) catch return error.ReadinessFailed;
        if (ready == 0) return 0;
        if (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP) == 0) return error.ReadinessFailed;
        return self.drainReady(out);
    }
};
