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
//! 1. Call `Resident.init`, register `Resident.readinessFd`, then create a peer
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
//! `zig build check` but is not a `Netlayer`. Generic Host integration is the
//! completion `Backend` below: `completion.Loop(Backend, DialResolver)` under
//! `driver.Bridge` serves adopted answerers and drives offerer dials through a
//! configured `SignalingAuthority` (`zig build webrtc-loop`; the three-party
//! redeem over a bare webrtc give is `zig build webrtc-bridge-redeem`). A
//! blocking caller may still drive signaling and adopt the channel
//! explicitly.
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
const known_transport = model.transport.Known.webrtc;
pub const transport_name = known_transport.metadata().symbol;

/// WebRTC locators name peers by keyed-session identity even though this
/// resident intentionally exposes no address-based `Netlayer` vtable.
pub const designator_scheme: net.netlayer.DesignatorScheme = known_transport.metadata().designator_scheme;

/// The peer's Ed25519 designator length, the same key width keyed-tcp and iroh
/// name their peers by.
pub const designator_len = foundation.crypto.PeerKey.designator_len;

/// Build the hint-free locator for a WebRTC peer's keyed identity. Signaling
/// authority belongs to the dialing Host, not to the locator.
pub fn locator(designator: []const u8) model.PeerLocator {
    return .{
        .transport = transport_name,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    };
}

// ── Sidecar C ABI (transports/webrtc/src/lib.rs) ─────────────────────────────
// The endpoint owns the shared runtime and readiness namespace. Each peer owns
// exactly one data channel, so there is no separate connection handle.

const CPeer = opaque {};
const CEndpoint = opaque {};

/// The sidecar's endpoint config, field-for-field with its `#[repr(C)]`
/// counterpart. Passed by pointer so a new setting is a field here rather than a
/// wider signature every caller has to agree on.
const CEndpointConfig = extern struct {
    ice_servers: ?[*]const u8,
    ice_servers_len: usize,
    include_loopback_candidates: u32,
    worker_threads: u32,
};

extern fn pancake_webrtc_sidecar_endpoint_new(config: *const CEndpointConfig) ?*CEndpoint;
extern fn pancake_webrtc_sidecar_endpoint_readiness_fd(endpoint: *const CEndpoint) i32;
extern fn pancake_webrtc_sidecar_endpoint_drain_ready(endpoint: *const CEndpoint, out: [*]ReadyEvent, out_cap: usize) isize;
extern fn pancake_webrtc_sidecar_endpoint_driver_readiness_fd(endpoint: *const CEndpoint) i32;
extern fn pancake_webrtc_sidecar_endpoint_drain_driver_ready(endpoint: *const CEndpoint, out: [*]ReadyEvent, out_cap: usize) isize;
extern fn pancake_webrtc_sidecar_endpoint_free(endpoint: *CEndpoint) i32;
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
    /// The capability-authorized remote identity (ADR-0105): the Ed25519 key
    /// the signaling exchange was scoped to, recorded by `authorizeRemote`
    /// before the channel carries CapTP bytes. Null when the signaling layer
    /// named no peer identity.
    authorized_remote: ?foundation.crypto.PeerKey = null,

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

    /// Record the peer identity this channel's signaling was authorized for
    /// (ADR-0105). WebRTC's DTLS handshake binds the channel to the SDP
    /// fingerprints the signaling capability ferried, so the identity that
    /// capability was scoped to is the durable claim this channel may carry.
    /// `connection` hands it to the engine as this realizer's assertion
    /// (`engine.Peer.bindVerifiedChannelKey`), on offer and answer legs alike.
    /// Call before `connection`.
    ///
    /// What the resident asserts here is the signaling capability's scope, not
    /// a sidecar proof: binding a cryptographic fingerprint directly to the
    /// durable identity remains adapter work. A caller that cannot name a peer
    /// leaves this unset, and the session reports no authenticated identity.
    pub fn authorizeRemote(self: *Peer, key: foundation.crypto.PeerKey) void {
        self.authorized_remote = key;
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
    pub fn connection(
        self: *Peer,
        io: Io,
        engine_peer: *engine.Peer,
        bufs: Buffers,
    ) std.mem.Allocator.Error!Connection {
        // The capability-authorized proof (ADR-0105), installed before any
        // byte feeds. Only the signaling owner's named identity is evidence,
        // so a leg whose signaling named nobody asserts nothing here.
        if (self.authorized_remote) |key| engine_peer.bindVerifiedChannelKey(key);
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

    /// Hand a bounded prefix to the sidecar's outbound staging buffer and return
    /// immediately.
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

    /// One endpoint's configuration; the C ABI's `PancakeWebrtcConfig` is the
    /// authority on what each setting means. A single config so a future
    /// endpoint setting rides it without growing the constructor's arity.
    ///
    /// `include_loopback_candidates` defaults to false, so a peer offers
    /// loopback only where a caller says it wants it. Two peers in one process
    /// or on one host need it and say so; a deployment neither needs it nor
    /// wants to advertise addresses a partner can never use.
    pub const Config = struct {
        ice_servers: []const u8 = "",
        include_loopback_candidates: bool = false,
        worker_threads: u32 = 0,
    };

    pub fn init(config: Config) InitError!Resident {
        const c_config: CEndpointConfig = .{
            .ice_servers = if (config.ice_servers.len == 0) null else config.ice_servers.ptr,
            .ice_servers_len = config.ice_servers.len,
            .include_loopback_candidates = @intFromBool(config.include_loopback_candidates),
            .worker_threads = config.worker_threads,
        };
        return .{
            .endpoint = pancake_webrtc_sidecar_endpoint_new(&c_config) orelse return error.EndpointCreateFailed,
        };
    }

    pub fn deinit(self: *Resident) error{SidecarTeardownFailed}!void {
        if (pancake_webrtc_sidecar_endpoint_free(self.endpoint) != 0) return error.SidecarTeardownFailed;
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

    /// Borrow the generic driver's independent subscription. Calling this
    /// lazily creates the second sidecar queue; raw signaling continues to use
    /// `readinessFd`/`drainReady` and cannot lose events to the driver.
    pub fn driverReadinessFd(self: *const Resident) i32 {
        return pancake_webrtc_sidecar_endpoint_driver_readiness_fd(self.endpoint);
    }

    pub fn drainDriverReady(self: *const Resident, out: []ReadyEvent) error{ReadinessFailed}!usize {
        const count = pancake_webrtc_sidecar_endpoint_drain_driver_ready(self.endpoint, out.ptr, out.len);
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
        const ready = net.poll.wait(&fds, timeout_ms) catch return error.ReadinessFailed;
        if (ready == 0) return 0;
        if (fds[0].revents & (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP) == 0) return error.ReadinessFailed;
        return self.drainReady(out);
    }
};

// ── Completion backend: many WebRTC peers on one `completion.Loop` ────────────

const completion = net.completion;
const BufferPool = completion.BufferPool;
const crypto = foundation.crypto;

/// The largest SDP or ICE payload the backend's signaling scratch admits, the
/// same bound the in-tree signaling scenarios hold (`interop/webrtc_common.zig`).
const signal_frame_cap: usize = 16 * 1024;

/// Cross-thread signaling bytes cannot use the caller's allocator: a Zig
/// allocator may be single-threaded even when the API carrying the bytes is
/// thread-safe. Allocate one fixed endpoint-level transfer store during
/// `initBound`, then copy answers and candidates into an exclusively held slot
/// before publishing their queue row. The loop returns the slot after applying
/// the row. This keeps allocator calls on the owner thread and puts a hard
/// 4 MiB ceiling on signaling bytes, independent of session count.
const max_signal_payloads = 256;
const SignalPayloadPool = struct {
    storage: [][signal_frame_cap]u8,
    free_slots: [max_signal_payloads]u8 = undefined,
    free_len: usize = max_signal_payloads,

    fn init(allocator: std.mem.Allocator) !SignalPayloadPool {
        const storage = try allocator.alloc([signal_frame_cap]u8, max_signal_payloads);
        var pool: SignalPayloadPool = .{ .storage = storage };
        for (&pool.free_slots, 0..) |*slot, i| slot.* = @intCast(i);
        return pool;
    }

    fn deinit(self: *SignalPayloadPool, allocator: std.mem.Allocator) void {
        std.debug.assert(self.free_len == max_signal_payloads);
        allocator.free(self.storage);
        self.* = undefined;
    }

    /// The caller serializes pool access with `Backend.signal_mutex`.
    fn acquire(self: *SignalPayloadPool) ?u8 {
        if (self.free_len == 0) return null;
        self.free_len -= 1;
        return self.free_slots[self.free_len];
    }

    /// The caller serializes pool access with `Backend.signal_mutex`.
    fn release(self: *SignalPayloadPool, slot: u8) void {
        std.debug.assert(self.free_len < max_signal_payloads);
        self.free_slots[self.free_len] = slot;
        self.free_len += 1;
    }

    fn bytes(self: *SignalPayloadPool, slot: u8, len: usize) []u8 {
        std.debug.assert(len <= signal_frame_cap);
        return self.storage[slot][0..len];
    }
};

const backend_connect_target = struct {
    designator: []const u8,
};

/// OCapN locator mapped to a WebRTC `ConnectTarget` for `completion.Loop`. A
/// `webrtc` locator names a key designator and nothing else (the dial
/// classifier's `signaling` shape); a malformed designator is refused here,
/// before any peer or signaling exchange exists. The direct-addresses hint is
/// ignored, exactly as the core planner ignores it.
pub const DialResolver = struct {
    pub fn resolve(
        partner: model.PeerLocator,
    ) !backend_connect_target {
        if (!std.mem.eql(u8, partner.transport, model.transport.webrtc)) return error.UnknownTransport;
        if (crypto.PeerKey.fromDesignator(partner.designator) == null) return error.InvalidAddress;
        return .{ .designator = partner.designator };
    }
};

/// How the backend's dials signal out (ADR-0089): the native face of the
/// signaling capability the application holds, the vtable sibling of the
/// TypeScript stack's host-configured signaling authority. The backend calls both on its loop
/// thread; an authority bridging to another thread owns its own locking. The
/// synthetic fd is the exchange token: the authority routes every message for
/// one bring-up under the fd `sendOffer` introduced, and answers back through
/// `Backend.provideAnswer` / `Backend.provideRemoteCandidate` with the same fd.
pub const SignalingAuthority = struct {
    ctx: *anyopaque,
    sendOffer: *const fn (ctx: *anyopaque, fd: i32, designator: []const u8, sdp: []const u8) anyerror!void,
    sendCandidate: *const fn (ctx: *anyopaque, fd: i32, ice: []const u8) anyerror!void,
};

/// The WebRTC completion `Backend` for `net.completion.Loop`: the resident's
/// one readiness fd and non-blocking try-I/O adapted to the completion-shaped
/// interface the socket and iroh backends provide, so CapTP fan-out rides
/// `driver.Bridge` + `driver_core.Host` (ADR-0076 convergence, ADR-0089's
/// generic Host adoption).
///
/// Construct with `initBound` over a `Resident` and a `SignalingAuthority`,
/// then `completion.Loop(Backend, DialResolver).initWithBackend`. Two shapes
/// have no socket precedent, and both hang off signaling:
///
/// - An outbound dial (`startDial`) creates the offerer peer and sends its
///   offer through the authority; the answer and the far candidates come back
///   through `provideAnswer` / `provideRemoteCandidate`, and the dial's
///   connect completion fires on the channel's `ev_open`.
/// - There is no accept substrate: an answerer peer exists because a signaling
///   owner created it against an inbound offer and handed it to
///   `adoptAnswerer`. The backend parks it until `ev_open`, then surfaces it
///   through the ordinary accept completion, so `driver.Bridge` adopts it like
///   any accepted connection.
///
/// `adoptAnswerer`, `provideAnswer`, and `provideRemoteCandidate` are the
/// three thread-safe entries, queued under one mutex, nudged through an
/// ordinary wake fd, and applied at the head of the next harvest; everything
/// else is loop-thread state. `wake` is only the stopper half of that same fd:
/// it records no work and exists because this userspace backend's `poll` owns
/// its fd set directly, unlike socket backends that can use `Loop.armWake`.
/// The resident must outlive the backend and be drained by no other consumer
/// (`Resident.pollReady` and the backend cannot share one resident). Threads
/// that can call the thread-safe entries or `wake` must stop before `deinit`
/// closes the wake fd.
pub const Backend = struct {
    pub const Fd = i32;
    pub const ConnectTarget = backend_connect_target;
    pub const ListenerAddress = void;

    /// Sentinel listen handle: not an OS fd; there is nothing to arm because
    /// reachability is a registered signaling inbox, not a socket.
    pub const listen_fd: Fd = 0;

    const Pending = struct {
        read_ud: ?u64 = null,
        write_ud: ?u64 = null,
        write_bytes: ?[]const u8 = null,
        readable_hint: bool = false,
        writable_hint: bool = false,
    };

    const ConnEntry = struct {
        peer: Peer,
        pending: Pending = .{},
        /// A signaling or sidecar failure discovered while the channel was
        /// open. The next pending operation reports the original cause; if an
        /// operation is already parked, discovery completes it immediately.
        terminal_failure: ?anyerror = null,
    };

    /// An offerer bring-up in flight: the connect completion's user data, the
    /// peer driving the exchange, and the dialed designator (owned) the
    /// authority routes by.
    const DialRow = struct {
        user_data: u64,
        peer: Peer,
        designator: []u8,
    };

    /// An adopted answerer waiting for its channel to open.
    const AdoptRow = struct {
        peer: Peer,
    };

    const Accepted = struct { fd: Fd, peer: Peer };
    const AcceptOutcome = union(enum) {
        connected: Accepted,
        failed: anyerror,
    };

    /// One queued thread-safe entry, applied on the loop thread.
    const SignalIn = union(enum) {
        adopt: struct { fd: Fd, peer: Peer },
        answer: struct { fd: Fd, slot: u8, len: u16 },
        candidate: struct { fd: Fd, slot: u8, len: u16 },
    };
    const max_accept_stash = 128;
    const max_signal_in = 256;

    allocator: std.mem.Allocator,
    /// Borrowed; must outlive the backend.
    resident: *Resident,
    signaling: SignalingAuthority,
    readiness_fd: i32,
    /// Completions that need no further readiness, drained before blocking.
    ready: completion.ReadyQueue = .{},
    /// Adopted-answer outcomes waiting for a `submitAccept` to claim them.
    /// Failures belong here too: an inbound exchange must not disappear just
    /// because it failed before the owner had an accept parked.
    accept_stash: std.ArrayList(AcceptOutcome) = .empty,
    accept_ud: ?u64 = null,
    /// Synthetic fd to open connection. Fd 0 is the listen sentinel.
    conns: std.AutoHashMap(Fd, ConnEntry),
    /// Resident peer id to synthetic fd, for readiness records — pre-open rows
    /// included, because candidates and the open edge route by peer id.
    by_id: std.AutoHashMap(usize, Fd),
    /// Offerer bring-ups in flight, by their reserved fd (the exchange token).
    pending_dials: std.AutoHashMap(Fd, DialRow),
    /// Adopted answerers not yet open, by their reserved fd.
    adopting: std.AutoHashMap(Fd, AdoptRow),
    /// Guards `next_fd` and `signal_in`: the three thread-safe entries mint
    /// fds and queue rows from outside the loop thread. No `std.Io` token
    /// crosses this foreign-thread signaling seam, so this stays a spinlock;
    /// reserve signal queue capacity before taking it so the critical section is
    /// only integer and slice-header mutation.
    signal_mutex: net.sync.SpinLock = .{},
    signal_in: std.ArrayList(SignalIn) = .empty,
    /// Queue seats claimed while a producer copies into its exclusive payload
    /// slot. A row is not visible until the copy is complete, while this count
    /// prevents other producers or adoptions from oversubscribing the inbox.
    signal_reservations: usize = 0,
    signal_payloads: SignalPayloadPool,
    /// Wake fd for `signal_in`: the loop polls it beside the sidecar readiness
    /// fd, so cross-thread answers, candidates, and adopted peers are events
    /// rather than a timeout-polled side channel.
    signal_wake: net.wake_channel.WakeChannel,
    signal_wake_failure: net.wake_channel.FailureLatch = .{},
    /// Loop-thread work queue swapped with `signal_in` during a drain. Keeping
    /// a second pre-reserved list preserves the thread-safe inbox capacity
    /// without allocating or deallocating at each wake.
    signal_work: std.ArrayList(SignalIn) = .empty,
    next_fd: Fd = 1,
    buffer_pool: BufferPool,

    /// Bind a backend to `resident` and the signaling authority its dials
    /// speak through. The readiness fd is latched here, not in `openListener`:
    /// a WebRTC loop is typically dial-and-adopt only, with no listen row.
    pub fn initBound(
        allocator: std.mem.Allocator,
        resident: *Resident,
        signaling: SignalingAuthority,
        read_buffers: u16,
        read_buffer_bytes: u32,
    ) !Backend {
        const signal_wake = try net.wake_channel.WakeChannel.open();
        errdefer signal_wake.deinit();
        var buffer_pool = try BufferPool.init(allocator, read_buffers, read_buffer_bytes);
        errdefer buffer_pool.deinit();
        var signal_in = std.ArrayList(SignalIn).empty;
        errdefer signal_in.deinit(allocator);
        try signal_in.ensureTotalCapacity(allocator, max_signal_in);
        var signal_work = std.ArrayList(SignalIn).empty;
        errdefer signal_work.deinit(allocator);
        try signal_work.ensureTotalCapacity(allocator, max_signal_in);
        var accept_stash = std.ArrayList(AcceptOutcome).empty;
        errdefer accept_stash.deinit(allocator);
        try accept_stash.ensureTotalCapacity(allocator, max_accept_stash);
        var signal_payloads = try SignalPayloadPool.init(allocator);
        errdefer signal_payloads.deinit(allocator);
        const fd = resident.readinessFd();
        if (fd < 0) return error.ListenFailed;
        return .{
            .allocator = allocator,
            .resident = resident,
            .signaling = signaling,
            .readiness_fd = fd,
            .conns = std.AutoHashMap(Fd, ConnEntry).init(allocator),
            .by_id = std.AutoHashMap(usize, Fd).init(allocator),
            .pending_dials = std.AutoHashMap(Fd, DialRow).init(allocator),
            .adopting = std.AutoHashMap(Fd, AdoptRow).init(allocator),
            .signal_in = signal_in,
            .signal_payloads = signal_payloads,
            .signal_wake = signal_wake,
            .signal_work = signal_work,
            .accept_stash = accept_stash,
            .buffer_pool = buffer_pool,
        };
    }

    pub fn deinit(self: *Backend) void {
        var dial_it = self.pending_dials.valueIterator();
        while (dial_it.next()) |row| {
            var peer = row.peer;
            peer.deinit();
            self.allocator.free(row.designator);
        }
        self.pending_dials.deinit();
        var adopt_it = self.adopting.valueIterator();
        while (adopt_it.next()) |row| {
            var peer = row.peer;
            peer.deinit();
        }
        self.adopting.deinit();
        var it = self.conns.valueIterator();
        while (it.next()) |entry| {
            var peer = entry.peer;
            peer.deinit();
        }
        self.conns.deinit();
        self.by_id.deinit();
        for (self.accept_stash.items) |*outcome| switch (outcome.*) {
            .connected => |*held| held.peer.deinit(),
            .failed => {},
        };
        self.accept_stash.deinit(self.allocator);
        for (self.signal_in.items) |queued| self.freeQueued(queued);
        self.signal_in.deinit(self.allocator);
        for (self.signal_work.items) |queued| self.freeQueued(queued);
        self.signal_work.deinit(self.allocator);
        std.debug.assert(self.signal_reservations == 0);
        self.signal_payloads.deinit(self.allocator);
        self.signal_wake.deinit();
        self.ready.deinit(self.allocator);
        self.buffer_pool.deinit();
    }

    fn freeQueued(self: *Backend, queued: SignalIn) void {
        switch (queued) {
            .adopt => |a| {
                var peer = a.peer;
                peer.deinit();
            },
            .answer => |a| self.releaseSignalPayload(a.slot),
            .candidate => |c| self.releaseSignalPayload(c.slot),
        }
    }

    fn releaseSignalPayload(self: *Backend, slot: u8) void {
        self.signal_mutex.lock();
        defer self.signal_mutex.unlock();
        self.signal_payloads.release(slot);
    }

    /// Nothing to arm: reachability is a registered signaling inbox. The
    /// sentinel keeps the Loop's listen plumbing total.
    pub fn openListener(self: *Backend, port: u16) !Fd {
        _ = self;
        _ = port;
        return listen_fd;
    }

    pub fn listenerAddress(_: *Backend, fd: Fd) !ListenerAddress {
        if (fd != listen_fd) return error.InvalidListener;
    }

    pub fn listenerPort(_: ListenerAddress) ?u16 {
        return null;
    }

    fn reserveFdLocked(self: *Backend) !Fd {
        self.signal_mutex.lock();
        defer self.signal_mutex.unlock();
        const fd = self.next_fd;
        if (fd == std.math.maxInt(Fd)) return error.OutOfFds;
        self.next_fd += 1;
        return fd;
    }

    fn reserveSignalPayload(self: *Backend) !u8 {
        self.signal_mutex.lock();
        defer self.signal_mutex.unlock();
        if (self.signal_in.items.len + self.signal_reservations >= max_signal_in) return error.WouldBlock;
        const slot = self.signal_payloads.acquire() orelse return error.WouldBlock;
        self.signal_reservations += 1;
        return slot;
    }

    fn publishSignalPayload(self: *Backend, item: SignalIn) error{WakeNudgeFailed}!void {
        self.signal_mutex.lock();
        defer self.signal_mutex.unlock();
        std.debug.assert(self.signal_reservations > 0);
        std.debug.assert(self.signal_in.items.len < max_signal_in);
        self.signal_reservations -= 1;
        _ = self.signal_wake.nudge() catch |err| {
            const slot = switch (item) {
                .answer => |value| value.slot,
                .candidate => |value| value.slot,
                .adopt => unreachable,
            };
            self.signal_payloads.release(slot);
            self.signal_wake_failure.record(err);
            return err;
        };
        self.signal_in.appendAssumeCapacity(item);
    }

    /// Start an offerer bring-up: create the peer, produce its offer, and hand
    /// it to the signaling authority under the reserved fd. The connect
    /// completion fires when the channel opens; the answer and far candidates
    /// arrive through `provideAnswer` / `provideRemoteCandidate`.
    pub fn startDial(self: *Backend, user_data: u64, target: backend_connect_target) !Fd {
        const fd = try self.reserveFdLocked();
        var peer = self.resident.newPeer(true) catch return error.ConnectFailed;
        errdefer peer.deinit();
        // The dialed designator is the identity this channel's signaling is
        // scoped to (ADR-0105), which is what the bridge reads back through
        // `verifiedChannelKey` and asserts to the engine.
        peer.authorizeRemote(crypto.PeerKey.fromDesignator(target.designator) orelse
            return error.ConnectFailed);
        var sdp_buf: [signal_frame_cap]u8 = undefined;
        var sdp_len: usize = 0;
        const sdp = peer.createOffer(&sdp_buf, &sdp_len) catch return error.ConnectFailed;
        const designator = try self.allocator.dupe(u8, target.designator);
        errdefer self.allocator.free(designator);
        try self.pending_dials.put(fd, .{ .user_data = user_data, .peer = peer, .designator = designator });
        errdefer std.debug.assert(self.pending_dials.remove(fd));
        try self.by_id.put(@intFromEnum(peer.id()), fd);
        errdefer std.debug.assert(self.by_id.remove(@intFromEnum(peer.id())));
        self.signaling.sendOffer(self.signaling.ctx, fd, designator, sdp) catch
            return error.ConnectFailed;
        return fd;
    }

    /// Adopt an answerer peer a signaling owner brought up against an inbound
    /// offer. Thread-safe. Returns the exchange fd: route the offerer's later
    /// candidates to it with `provideRemoteCandidate`, and expect the
    /// backend's own `sendCandidate` calls under it. Ownership of `peer`
    /// transfers to the backend on entry, including failure: overload or fd
    /// exhaustion closes it here rather than returning a half-owned sidecar
    /// peer to the signaling layer.
    pub fn adoptAnswerer(self: *Backend, peer: Peer) !Fd {
        var owned = peer;
        self.signal_wake_failure.check() catch |err| {
            owned.deinit();
            return err;
        };
        self.signal_mutex.lock();
        const fd = self.next_fd;
        if (fd == std.math.maxInt(Fd)) {
            self.signal_mutex.unlock();
            owned.deinit();
            return error.OutOfFds;
        }
        if (self.signal_in.items.len + self.signal_reservations >= max_signal_in) {
            self.signal_mutex.unlock();
            owned.deinit();
            return error.WouldBlock;
        }
        self.next_fd += 1;
        _ = self.signal_wake.nudge() catch |err| {
            self.signal_wake_failure.record(err);
            self.signal_mutex.unlock();
            owned.deinit();
            return err;
        };
        self.signal_in.appendAssumeCapacity(.{ .adopt = .{ .fd = fd, .peer = owned } });
        self.signal_mutex.unlock();
        return fd;
    }

    /// Deliver the far answerer's SDP for the exchange `fd` names. Thread-safe.
    pub fn provideAnswer(self: *Backend, fd: Fd, sdp: []const u8) !void {
        try self.signal_wake_failure.check();
        if (sdp.len > signal_frame_cap) return error.SignalTooLarge;
        const slot = try self.reserveSignalPayload();
        @memcpy(self.signal_payloads.bytes(slot, sdp.len), sdp);
        try self.publishSignalPayload(.{ .answer = .{ .fd = fd, .slot = slot, .len = @intCast(sdp.len) } });
    }

    /// Deliver one far ICE candidate for the exchange `fd` names. Thread-safe.
    pub fn provideRemoteCandidate(self: *Backend, fd: Fd, ice: []const u8) !void {
        try self.signal_wake_failure.check();
        if (ice.len > signal_frame_cap) return error.SignalTooLarge;
        const slot = try self.reserveSignalPayload();
        @memcpy(self.signal_payloads.bytes(slot, ice.len), ice);
        try self.publishSignalPayload(.{ .candidate = .{ .fd = fd, .slot = slot, .len = @intCast(ice.len) } });
    }

    /// Wake a parked `poll` so an owner-thread stop flag can be observed without
    /// timeout polling. Carries no authority and records no work; the next
    /// harvest drains the nudge and then finds the normal state the caller
    /// already changed.
    pub fn wake(self: *Backend) net.wake_channel.Failure!void {
        try self.signal_wake_failure.check();
        _ = self.signal_wake.nudge() catch |err| {
            self.signal_wake_failure.record(err);
            return err;
        };
    }

    pub fn applyKeepalive(_: *Backend, _: Fd, _: completion.Keepalive) !void {
        return error.OperationUnsupported;
    }

    pub fn closeFd(self: *Backend, fd: Fd) void {
        if (fd == listen_fd) return;
        if (self.pending_dials.fetchRemove(fd)) |kv| {
            var row = kv.value;
            std.debug.assert(self.by_id.remove(@intFromEnum(row.peer.id())));
            row.peer.deinit();
            self.allocator.free(row.designator);
            return;
        }
        if (self.adopting.fetchRemove(fd)) |kv| {
            var row = kv.value;
            std.debug.assert(self.by_id.remove(@intFromEnum(row.peer.id())));
            row.peer.deinit();
            return;
        }
        if (self.conns.fetchRemove(fd)) |kv| {
            var entry = kv.value;
            std.debug.assert(self.by_id.remove(@intFromEnum(entry.peer.id())));
            entry.peer.deinit();
        }
    }

    /// Required Backend contract; WebRTC has no OS recv to unblock.
    pub fn shutdownFd(self: *Backend, fd: Fd) void {
        _ = self;
        _ = fd;
    }

    pub fn recycleBorrowed(self: *Backend, comp: completion.Completion) void {
        self.buffer_pool.release(@intCast(comp.borrowed.token));
    }

    /// The signaling-authorized remote identity for `fd`'s connection
    /// (ADR-0105): the key the exchange was scoped to, which is the dialed
    /// designator on the offer leg and the adopted peer's `authorizeRemote` on
    /// the answer leg. Null when the signaling owner named no identity.
    pub fn verifiedChannelKey(self: *Backend, fd: Fd) ?[crypto.PEER_KEY_BYTES]u8 {
        const entry = self.conns.getPtr(fd) orelse return null;
        const key = entry.peer.authorized_remote orelse return null;
        return key.bytes;
    }

    pub fn submitAccept(self: *Backend, user_data: u64, listen: Fd) !void {
        if (listen != listen_fd) return error.InvalidListenFd;
        if (self.accept_ud != null) return error.AlreadyAccepting;
        try self.ready.ensureUnusedCapacity(self.allocator, 1);
        self.accept_ud = user_data;
        self.takeAccept();
    }

    /// Requires one unused ready-queue seat when an accept is stashed.
    fn takeAccept(self: *Backend) void {
        const ud = self.accept_ud orelse return;
        if (self.accept_stash.items.len == 0) return;
        const outcome = self.accept_stash.orderedRemove(0);
        switch (outcome) {
            .connected => |held| {
                self.conns.put(held.fd, .{ .peer = held.peer, .pending = .{ .writable_hint = true } }) catch |err| {
                    var peer = held.peer;
                    std.debug.assert(self.by_id.remove(@intFromEnum(peer.id())));
                    peer.deinit();
                    self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1, .failure = err });
                    self.accept_ud = null;
                    return;
                };
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = held.fd });
            },
            .failed => |err| self.ready.appendAssumeCapacity(.{
                .user_data = ud,
                .result = -1,
                .failure = err,
            }),
        }
        self.accept_ud = null;
    }

    fn entryPtr(self: *Backend, fd: Fd) !*ConnEntry {
        return self.conns.getPtr(fd) orelse error.InvalidFd;
    }

    /// Requires one unused ready-queue seat. A would-block attempt consumes no
    /// seat and keeps the caller's read pending.
    fn completeRecv(self: *Backend, entry: *ConnEntry) void {
        const ud = entry.pending.read_ud orelse return;
        var comp: completion.Completion = .{ .user_data = ud, .result = -1 };
        if (entry.terminal_failure) |err| {
            comp.failure = err;
            entry.pending.read_ud = null;
            self.ready.appendAssumeCapacity(comp);
            return;
        }
        if (self.buffer_pool.acquire()) |idx| {
            const buf = self.buffer_pool.buffer(idx);
            if (entry.peer.tryRead(buf)) |n| {
                comp.result = @intCast(n);
                comp.borrowed = .recv(buf[0..n], idx);
                // More may still be buffered: leave the hint so the next
                // submitRecv completes without waiting for another edge.
                entry.pending.readable_hint = true;
            } else |err| switch (err) {
                error.WouldBlock => {
                    // Edge spent without bytes: keep the pending recv; a later
                    // readable will retry.
                    self.buffer_pool.release(idx);
                    entry.pending.readable_hint = false;
                    return;
                },
                error.Closed => {
                    comp.result = 0;
                    self.buffer_pool.release(idx);
                    entry.pending.readable_hint = false;
                },
                error.Failed => {
                    self.buffer_pool.release(idx);
                    entry.pending.readable_hint = false;
                    comp.failure = error.WebRtcReadFailed;
                },
            }
        } else {
            comp.recv_no_buffer = true;
            // Keep the hint: the loop re-arms once a buffer recycles.
        }
        entry.pending.read_ud = null;
        self.ready.appendAssumeCapacity(comp);
    }

    /// Requires one unused ready-queue seat. A would-block attempt consumes no
    /// seat and keeps the caller's write pending.
    fn completeSend(self: *Backend, entry: *ConnEntry) void {
        const ud = entry.pending.write_ud orelse return;
        const bytes = entry.pending.write_bytes orelse return;
        if (entry.terminal_failure) |err| {
            entry.pending.write_ud = null;
            entry.pending.write_bytes = null;
            self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1, .failure = err });
            return;
        }
        var result: i32 = -1;
        var failure: ?anyerror = null;
        if (entry.peer.tryWrite(bytes)) |n| {
            result = @intCast(n);
            entry.pending.writable_hint = true;
        } else |err| switch (err) {
            error.WouldBlock => {
                entry.pending.writable_hint = false;
                return;
            },
            error.Closed, error.Failed => {
                entry.pending.writable_hint = false;
                failure = error.WebRtcWriteFailed;
            },
        }
        entry.pending.write_ud = null;
        entry.pending.write_bytes = null;
        self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = result, .failure = failure });
    }

    pub fn submitRecv(self: *Backend, user_data: u64, fd: Fd) !void {
        const entry = try self.entryPtr(fd);
        if (entry.pending.read_ud != null) return error.AlreadyReading;
        try self.ready.ensureUnusedCapacity(self.allocator, 1);
        entry.pending.read_ud = user_data;
        if (entry.pending.readable_hint or entry.terminal_failure != null) self.completeRecv(entry);
    }

    pub fn submitSend(self: *Backend, user_data: u64, fd: Fd, bytes: []const u8) !void {
        const entry = try self.entryPtr(fd);
        if (entry.pending.write_ud != null) return error.AlreadyWriting;
        try self.ready.ensureUnusedCapacity(self.allocator, 1);
        entry.pending.write_ud = user_data;
        entry.pending.write_bytes = bytes;
        // Always attempt once: a seeded writable_hint or a live edge may
        // already allow the write; would_block parks until the next edge.
        self.completeSend(entry);
    }

    pub fn submitCancel(
        self: *Backend,
        cancel_user_data: u64,
        target_user_data: u64,
        fd: Fd,
    ) !void {
        const entry = try self.entryPtr(fd);
        const target_pending = if (entry.pending.read_ud) |ud| blk: {
            if (ud != target_user_data) return error.InvalidCancelTarget;
            break :blk true;
        } else false;
        try self.ready.ensureUnusedCapacity(
            self.allocator,
            1 + @as(usize, @intFromBool(target_pending)),
        );
        if (target_pending) {
            entry.pending.read_ud = null;
            self.ready.appendAssumeCapacity(.{ .user_data = target_user_data, .result = -1 });
        }
        // With no pending row, completeRecv already queued the target.
        self.ready.appendAssumeCapacity(.{ .user_data = cancel_user_data, .result = 0 });
    }

    pub fn submitClose(self: *Backend, user_data: u64, fd: Fd) !void {
        try self.ready.ensureUnusedCapacity(self.allocator, 3);
        if (fd == listen_fd) {
            // Cancel a pending accept so Loop.closeAndDrain cannot hang on an
            // idle acceptor; the listen sentinel is not a real conn entry.
            if (self.accept_ud) |ud| {
                self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
                self.accept_ud = null;
            }
            for (self.accept_stash.items) |*outcome| switch (outcome.*) {
                .connected => |*held| {
                    std.debug.assert(self.by_id.remove(@intFromEnum(held.peer.id())));
                    held.peer.deinit();
                },
                .failed => {},
            };
            self.accept_stash.clearRetainingCapacity();
            self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
            return;
        }
        if (self.pending_dials.fetchRemove(fd)) |kv| {
            var row = kv.value;
            std.debug.assert(self.by_id.remove(@intFromEnum(row.peer.id())));
            row.peer.deinit();
            self.allocator.free(row.designator);
            self.ready.appendAssumeCapacity(.{ .user_data = row.user_data, .result = -1 });
            self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
            return;
        }
        if (self.adopting.fetchRemove(fd)) |kv| {
            var row = kv.value;
            std.debug.assert(self.by_id.remove(@intFromEnum(row.peer.id())));
            row.peer.deinit();
            self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
            return;
        }
        if (self.conns.getPtr(fd)) |entry| {
            if (entry.pending.read_ud) |ud| self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
            if (entry.pending.write_ud) |ud| self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1 });
            entry.pending = .{};
            std.debug.assert(self.by_id.remove(@intFromEnum(entry.peer.id())));
            var peer = entry.peer;
            peer.deinit();
            std.debug.assert(self.conns.remove(fd));
        }
        self.ready.appendAssumeCapacity(.{ .user_data = user_data, .result = 0 });
    }

    /// Ferry this peer's locally gathered candidates out through the authority.
    /// Failure is terminal for the exchange: silently omitting a candidate can
    /// turn a local signaling fault into an unrelated remote timeout.
    fn pumpLocalCandidates(self: *Backend, fd: Fd, peer: *Peer) !void {
        var cand_buf: [4 * 1024]u8 = undefined;
        var cand_len: usize = 0;
        while (true) {
            const cand = try peer.nextLocalCandidate(&cand_buf, &cand_len);
            const ice = cand orelse return;
            try self.signaling.sendCandidate(self.signaling.ctx, fd, ice);
        }
    }

    /// Requires one unused ready-queue seat. The row is removed before the
    /// completion is published, so callers reserve that seat first.
    fn failDial(self: *Backend, fd: Fd, cause: anyerror) void {
        const kv = self.pending_dials.fetchRemove(fd) orelse return;
        var row = kv.value;
        std.debug.assert(self.by_id.remove(@intFromEnum(row.peer.id())));
        row.peer.deinit();
        self.allocator.free(row.designator);
        self.ready.appendAssumeCapacity(.{ .user_data = row.user_data, .result = -1, .failure = cause });
    }

    /// Publish an inbound exchange failure now or retain it for the next
    /// accept. The stash is pre-reserved: saturation is an explicit backend
    /// overload, never permission to discard an exchange.
    fn queueAcceptFailure(self: *Backend, cause: anyerror) !void {
        if (self.accept_ud) |ud| {
            self.ready.appendAssumeCapacity(.{ .user_data = ud, .result = -1, .failure = cause });
            self.accept_ud = null;
            return;
        }
        if (self.accept_stash.items.len >= max_accept_stash) return error.AcceptBacklogFull;
        self.accept_stash.appendAssumeCapacity(.{ .failed = cause });
    }

    /// Remove and close an answerer whose bring-up failed, then preserve that
    /// exact cause for the accept owner.
    fn failAdopt(self: *Backend, fd: Fd, cause: anyerror) !void {
        const kv = self.adopting.fetchRemove(fd) orelse return;
        var peer = kv.value.peer;
        std.debug.assert(self.by_id.remove(@intFromEnum(peer.id())));
        peer.deinit();
        try self.queueAcceptFailure(cause);
    }

    /// Mark an open channel terminal and wake every operation already parked
    /// on it. Future submissions observe the same originating cause.
    fn failOpenConnection(self: *Backend, entry: *ConnEntry, cause: anyerror) void {
        if (entry.terminal_failure == null) {
            entry.terminal_failure = cause;
            entry.peer.close();
        }
        if (entry.pending.read_ud != null) self.completeRecv(entry);
        if (entry.pending.write_ud != null) self.completeSend(entry);
    }

    /// Move an adopted answerer whose channel opened into the accept stash and
    /// let a parked accept claim it.
    fn openAdopted(self: *Backend, fd: Fd) !void {
        const kv = self.adopting.fetchRemove(fd) orelse return;
        if (self.accept_stash.items.len >= max_accept_stash) {
            var peer = kv.value.peer;
            std.debug.assert(self.by_id.remove(@intFromEnum(peer.id())));
            peer.deinit();
            return error.AcceptBacklogFull;
        }
        self.accept_stash.appendAssumeCapacity(.{ .connected = .{ .fd = fd, .peer = kv.value.peer } });
        self.takeAccept();
    }

    /// Apply the thread-safe queue on the loop thread: register adopted
    /// answerers, apply answers, apply candidates. Registration re-checks the
    /// open state because the open edge may have been drained before the row
    /// was visible (`checkOpen` is level, the event is edge).
    fn drainSignalIn(self: *Backend) !void {
        if (self.signal_work.items.len == 0) {
            self.signal_mutex.lock();
            defer self.signal_mutex.unlock();
            std.mem.swap(std.ArrayList(SignalIn), &self.signal_work, &self.signal_in);
        }
        // A queued answer or adoption can complete one Loop operation. Reserve
        // publication before consuming or freeing any queue row; on OOM the
        // work list remains intact for a caller that retries the backend.
        try self.ready.ensureUnusedCapacity(self.allocator, self.signal_work.items.len * 2);
        var consumed: usize = 0;
        defer {
            while (consumed < self.signal_work.items.len) : (consumed += 1) {
                self.freeQueued(self.signal_work.items[consumed]);
            }
            self.signal_work.clearRetainingCapacity();
        }
        while (consumed < self.signal_work.items.len) {
            const item = self.signal_work.items[consumed];
            consumed += 1;
            switch (item) {
                .adopt => |a| {
                    var peer = a.peer;
                    self.by_id.put(@intFromEnum(peer.id()), a.fd) catch {
                        peer.deinit();
                        try self.queueAcceptFailure(error.OutOfMemory);
                        continue;
                    };
                    self.adopting.put(a.fd, .{ .peer = peer }) catch {
                        std.debug.assert(self.by_id.remove(@intFromEnum(peer.id())));
                        peer.deinit();
                        try self.queueAcceptFailure(error.OutOfMemory);
                        continue;
                    };
                    const row = self.adopting.getPtr(a.fd).?;
                    self.pumpLocalCandidates(a.fd, &row.peer) catch |err| {
                        try self.failAdopt(a.fd, err);
                        continue;
                    };
                    if (row.peer.checkOpen()) |_| {
                        try self.openAdopted(a.fd);
                    } else |err| switch (err) {
                        error.WouldBlock => {},
                        error.Closed => try self.failAdopt(a.fd, error.WebRtcChannelClosed),
                    }
                },
                .answer => |a| {
                    defer self.releaseSignalPayload(a.slot);
                    const sdp = self.signal_payloads.bytes(a.slot, a.len);
                    const row = self.pending_dials.getPtr(a.fd) orelse continue;
                    row.peer.setRemoteAnswer(sdp) catch |err| {
                        self.failDial(a.fd, err);
                        continue;
                    };
                    // The open edge may already have fired while the answer sat
                    // queued; re-check the level.
                    if (row.peer.checkOpen()) |_| {
                        self.finishDial(a.fd);
                    } else |err| switch (err) {
                        error.WouldBlock => {},
                        error.Closed => self.failDial(a.fd, error.WebRtcChannelClosed),
                    }
                },
                .candidate => |c| {
                    defer self.releaseSignalPayload(c.slot);
                    const ice = self.signal_payloads.bytes(c.slot, c.len);
                    if (self.pending_dials.getPtr(c.fd)) |row| {
                        row.peer.addRemoteCandidate(ice) catch |err| {
                            // A candidate refusal while the exchange is still
                            // negotiating is terminal: no later readiness edge
                            // can complete this dial honestly.
                            self.failDial(c.fd, err);
                        };
                    } else if (self.adopting.getPtr(c.fd)) |row| {
                        row.peer.addRemoteCandidate(ice) catch |err| {
                            try self.failAdopt(c.fd, err);
                        };
                    } else if (self.conns.getPtr(c.fd)) |entry| {
                        entry.peer.addRemoteCandidate(ice) catch |err| self.failOpenConnection(entry, err);
                    }
                },
            }
        }
    }

    /// Move an opened dial into the connection table and complete the connect.
    /// Requires one unused ready-queue seat. The row is removed before the
    /// completion is published, so callers reserve that seat first.
    fn finishDial(self: *Backend, fd: Fd) void {
        const kv = self.pending_dials.fetchRemove(fd) orelse return;
        var row = kv.value;
        self.allocator.free(row.designator);
        self.conns.put(fd, .{ .peer = row.peer, .pending = .{ .writable_hint = true } }) catch {
            std.debug.assert(self.by_id.remove(@intFromEnum(row.peer.id())));
            row.peer.deinit();
            self.ready.appendAssumeCapacity(.{ .user_data = row.user_data, .result = -1, .failure = error.OutOfMemory });
            return;
        };
        self.ready.appendAssumeCapacity(.{ .user_data = row.user_data, .result = 0 });
    }

    fn dispatchReady(self: *Backend, ev: ReadyEvent) !void {
        const fd = self.by_id.get(ev.subject) orelse return;
        if (self.pending_dials.getPtr(fd)) |row| {
            if (ev.events & ev_candidate != 0) self.pumpLocalCandidates(fd, &row.peer) catch |err| return self.failDial(fd, err);
            if (ev.events & ev_closed != 0) return self.failDial(fd, error.WebRtcChannelClosed);
            if (ev.events & ev_open != 0) return self.finishDial(fd);
            return;
        }
        if (self.adopting.getPtr(fd)) |row| {
            if (ev.events & ev_candidate != 0) self.pumpLocalCandidates(fd, &row.peer) catch |err| return self.failAdopt(fd, err);
            if (ev.events & ev_closed != 0) {
                return self.failAdopt(fd, error.WebRtcChannelClosed);
            }
            if (ev.events & ev_open != 0) return self.openAdopted(fd);
            return;
        }
        const entry = self.conns.getPtr(fd) orelse return;
        if (ev.events & ev_candidate != 0) self.pumpLocalCandidates(fd, &entry.peer) catch |err| {
            self.failOpenConnection(entry, err);
            return;
        };
        if (ev.events & (ev_readable | ev_closed) != 0) {
            entry.pending.readable_hint = true;
            if (entry.pending.read_ud != null) self.completeRecv(entry);
        }
        if (ev.events & ev_writable != 0) {
            entry.pending.writable_hint = true;
            if (entry.pending.write_ud != null) self.completeSend(entry);
        }
    }

    /// Non-blocking harvest: drain the signaling wake and apply the thread-safe
    /// queue first (so a row registered this round can claim the events drained
    /// this round), then drain resident readiness records.
    fn harvestReadiness(self: *Backend) !bool {
        try self.signal_wake_failure.check();
        var pfds = [_]std.posix.pollfd{
            .{ .fd = self.signal_wake.read, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.readiness_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = net.poll.wait(&pfds, 0) catch |err| return err;
        var woke = false;
        if (pfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) {
            self.signal_wake.drain() catch |err| {
                self.signal_wake_failure.record(err);
                return err;
            };
            woke = true;
        }
        try self.drainSignalIn();

        if (pfds[1].revents & (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP) != 0) {
            var events_buf: [256]ReadyEvent = undefined;
            // One readiness record can complete both a pending read and write;
            // reserve before consuming any record.
            try self.ready.ensureUnusedCapacity(self.allocator, events_buf.len * 2);
            while (true) {
                const n = try self.resident.drainReady(&events_buf);
                if (n == 0) break;
                for (events_buf[0..n]) |ev| try self.dispatchReady(ev);
                if (n < events_buf.len) break;
                try self.ready.ensureUnusedCapacity(self.allocator, events_buf.len * 2);
            }
        }
        return woke;
    }

    pub fn poll(self: *Backend, out: []completion.Completion, timeout_ms: i32) !usize {
        const pre_wake = try self.harvestReadiness();
        {
            const n = self.ready.drain(out);
            if (n > 0) return n;
        }
        // The wake may have carried only loop-external state (stop) or
        // signaling work that did not complete a connection yet. Either way,
        // the owner loop must get a turn before this backend blocks again.
        if (pre_wake) return 0;

        var pfds = [_]std.posix.pollfd{
            .{ .fd = self.signal_wake.read, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = self.readiness_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = net.poll.wait(&pfds, timeout_ms) catch |err| return err;

        const post_wake = try self.harvestReadiness();
        const n = self.ready.drain(out);
        if (n > 0) return n;
        // Do not consume a wake and then immediately re-enter a backend wait.
        if (post_wake) return 0;
        return 0;
    }
};
