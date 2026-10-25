//! Rust sidecar ABI and its resident/peer adapters.

const std = @import("std");
const foundation = @import("foundation");
const net = @import("net");

const CPeer = opaque {};
const CEndpoint = opaque {};

/// Borrowed UTF-8 text in the private sidecar ABI.
pub const StringView = extern struct {
    ptr: ?[*]const u8,
    len: usize,

    pub fn from(bytes: []const u8) StringView {
        return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
    }
};

/// One ICE server record. URLs and credentials are borrowed for endpoint
/// construction. The sidecar copies them into endpoint-owned configuration.
pub const IceServerConfig = extern struct {
    urls: ?[*]const StringView,
    url_count: usize,
    username: StringView,
    credential: StringView,
};

/// The sidecar's endpoint config, field-for-field with its `#[repr(C)]`
/// counterpart. Passed by pointer so a new setting is a field here rather than a
/// wider signature every caller has to agree on.
const CEndpointConfig = extern struct {
    ice_servers: ?[*]const IceServerConfig,
    ice_server_count: usize,
    include_loopback_candidates: u32,
    worker_threads: u32,
};

extern fn glowcap_webrtc_sidecar_endpoint_new(config: *const CEndpointConfig) ?*CEndpoint;
extern fn glowcap_webrtc_sidecar_endpoint_readiness_fd(endpoint: *const CEndpoint) i32;
extern fn glowcap_webrtc_sidecar_endpoint_drain_ready(endpoint: *const CEndpoint, out: [*]ReadyEvent, out_cap: usize) isize;
extern fn glowcap_webrtc_sidecar_endpoint_driver_readiness_fd(endpoint: *const CEndpoint) i32;
extern fn glowcap_webrtc_sidecar_endpoint_drain_driver_ready(endpoint: *const CEndpoint, out: [*]ReadyEvent, out_cap: usize) isize;
extern fn glowcap_webrtc_sidecar_endpoint_free(endpoint: *CEndpoint) i32;
extern fn glowcap_webrtc_sidecar_peer_new(endpoint: *CEndpoint, is_offerer: i32) ?*CPeer;
extern fn glowcap_webrtc_sidecar_peer_create_offer(peer: *CPeer, out: [*]u8, cap: usize, out_len: *usize) i32;
extern fn glowcap_webrtc_sidecar_peer_create_answer(peer: *CPeer, out: [*]u8, cap: usize, out_len: *usize) i32;
extern fn glowcap_webrtc_sidecar_peer_set_remote(peer: *CPeer, sdp: [*]const u8, sdp_len: usize, is_offer: i32) i32;
extern fn glowcap_webrtc_sidecar_peer_add_remote_candidate(peer: *CPeer, cand: [*]const u8, cand_len: usize) i32;
extern fn glowcap_webrtc_sidecar_peer_next_local_candidate(peer: *CPeer, out: [*]u8, cap: usize, out_len: *usize) i32;
extern fn glowcap_webrtc_sidecar_peer_id(peer: *const CPeer) usize;
extern fn glowcap_webrtc_sidecar_peer_is_open(peer: *const CPeer) i32;
extern fn glowcap_webrtc_sidecar_conn_try_receive_packet(peer: *CPeer, buf: [*]u8, len: usize) isize;
extern fn glowcap_webrtc_sidecar_conn_try_send_packet(peer: *CPeer, buf: [*]const u8, len: usize) isize;
extern fn glowcap_webrtc_sidecar_conn_close(peer: *CPeer) void;
extern fn glowcap_webrtc_sidecar_peer_free(peer: *CPeer) void;

/// Sidecar return codes, kept in lockstep with the constants in
/// `transports/webrtc/src/lib.rs`.
const rc_ok: i32 = 0;
const rc_would_block: i32 = -2;
const rc_buffer_too_small: i32 = -3;
const rc_signal_too_large: i32 = -4;
const rc_closed: i32 = -5;

pub const ev_open: u32 = 1;
pub const ev_candidate: u32 = 2;
pub const ev_readable: u32 = 4;
pub const ev_writable: u32 = 8;
pub const ev_closed: u32 = 16;
pub const max_signal_bytes: usize = 16 * 1024;
pub const max_ice_candidate_bytes: usize = max_signal_bytes;
pub const max_ice_servers: usize = 16;
pub const max_ice_urls_per_server: usize = 16;
pub const max_ice_url_bytes: usize = 2 * 1024;
pub const max_ice_credential_bytes: usize = 4 * 1024;

pub const IceConfigError = error{
    NullPointer,
    TooManyIceServers,
    MissingIceUrls,
    TooManyIceUrls,
    EmptyIceUrl,
    IceUrlTooLarge,
    InvalidIceUrlUtf8,
    InvalidIceUrlScheme,
    StunCredentials,
    MissingTurnCredentials,
    CredentialTooLarge,
    InvalidCredentialUtf8,
};

pub fn validateIceServers(servers: []const IceServerConfig) IceConfigError!void {
    if (servers.len > max_ice_servers) return error.TooManyIceServers;
    for (servers) |server| {
        const urls = try requiredViews(server.urls, server.url_count);
        var has_turn = false;
        for (urls) |url_view| {
            const url = try viewBytes(url_view);
            if (url.len == 0) return error.EmptyIceUrl;
            if (url.len > max_ice_url_bytes) return error.IceUrlTooLarge;
            if (!std.unicode.utf8ValidateSlice(url)) return error.InvalidIceUrlUtf8;
            has_turn = has_turn or (try iceUrlIsTurn(url));
        }

        const username = try credentialBytes(server.username);
        const credential = try credentialBytes(server.credential);
        const has_credentials = username.len != 0 or credential.len != 0;
        if (!has_turn and has_credentials) return error.StunCredentials;
        if (has_turn and (username.len == 0 or credential.len == 0)) return error.MissingTurnCredentials;
    }
}

fn requiredViews(views: ?[*]const StringView, count: usize) IceConfigError![]const StringView {
    if (count == 0) return error.MissingIceUrls;
    if (count > max_ice_urls_per_server) return error.TooManyIceUrls;
    return (views orelse return error.NullPointer)[0..count];
}

fn viewBytes(view: StringView) IceConfigError![]const u8 {
    if (view.len == 0) return &.{};
    return (view.ptr orelse return error.NullPointer)[0..view.len];
}

fn credentialBytes(view: StringView) IceConfigError![]const u8 {
    const bytes = try viewBytes(view);
    if (bytes.len > max_ice_credential_bytes) return error.CredentialTooLarge;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidCredentialUtf8;
    return bytes;
}

fn iceUrlIsTurn(url: []const u8) IceConfigError!bool {
    if (startsWithAsciiIgnoreCase(url, "stun:") or startsWithAsciiIgnoreCase(url, "stuns:")) return false;
    if (startsWithAsciiIgnoreCase(url, "turn:") or startsWithAsciiIgnoreCase(url, "turns:")) return true;
    return error.InvalidIceUrlScheme;
}

fn startsWithAsciiIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    for (prefix, 0..) |want, i| {
        if (std.ascii.toLower(value[i]) != want) return false;
    }
    return true;
}

/// One resident readiness record. `subject` is a stable, nonzero `PeerId`
/// minted by that resident and never reused during its lifetime.
pub const ReadyEvent = extern struct {
    subject: usize,
    events: u32,
};

pub const PeerId = enum(usize) {
    _,
};

// ── The resident ─────────────────────────────────────────────────────────────

/// A signaling call that could not complete. `BufferTooSmall` names an SDP or
/// candidate too large for the caller's buffer. The caller retries with a larger
/// one. `SignalTooLarge` names malformed or unusable signaling input before it
/// enters the sidecar parser. `SignalFailed` is any other sidecar refusal.
pub const SignalError = error{ SignalFailed, BufferTooSmall, SignalTooLarge };

/// One WebRTC peer: the sidecar handle for its connection and single data
/// channel. The caller creates a `Peer`, drives the signaling exchange to bring
/// the channel up, then uses packet-shaped try-I/O.
pub const Peer = struct {
    peer: *CPeer,
    /// The capability-authorized remote identity (ADR-0028): the Ed25519 key
    /// the signaling exchange was scoped to, recorded by `authorizeRemote`
    /// before the channel carries CapTP bytes. Null when the signaling layer
    /// named no peer identity.
    authorized_remote: ?foundation.crypto.PeerKey = null,

    pub const InitError = error{PeerCreateFailed};

    /// Create a peer in one of the two signaling roles. The offerer creates the
    /// data channel and produces the SDP offer. The answerer receives the
    /// channel and produces the answer. The readiness path reads and writes
    /// session packets with `tryReceivePacket` / `trySendPacket`.
    fn init(resident: *Resident, is_offerer: bool) InitError!Peer {
        const peer = glowcap_webrtc_sidecar_peer_new(resident.endpoint, @intFromBool(is_offerer)) orelse return error.PeerCreateFailed;
        return .{ .peer = peer };
    }

    /// Stable resident-scoped identity carried by `ReadyEvent.subject`.
    pub fn id(self: *const Peer) PeerId {
        const raw = glowcap_webrtc_sidecar_peer_id(self.peer);
        std.debug.assert(raw != 0);
        return @fromBackingInt(@intCast(raw));
    }

    /// Record the peer identity this channel's signaling was authorized for
    /// (ADR-0028). WebRTC's DTLS handshake binds the channel to the SDP
    /// fingerprints the signaling capability ferried, so the identity that
    /// capability was scoped to is the durable claim this channel may carry.
    /// The completion backend reports it through `verifiedChannelKey`, on offer
    /// and answer legs alike.
    ///
    /// What the resident asserts here is the signaling capability's scope, not
    /// a sidecar proof: binding a cryptographic fingerprint directly to the
    /// durable identity remains adapter work. A caller that cannot name a peer
    /// leaves this unset, and the session reports no authenticated identity.
    pub fn authorizeRemote(self: *Peer, key: foundation.crypto.PeerKey) void {
        self.authorized_remote = key;
    }

    /// Close the data channel and connection without freeing the handle,
    /// waking any parked reader with end of stream. Idempotent. The shutdown
    /// lever for a host whose read parks on another thread. `deinit` still frees.
    pub fn close(self: *Peer) void {
        glowcap_webrtc_sidecar_conn_close(self.peer);
    }

    /// Free the sidecar peer and release its reference to the resident's shared
    /// runtime.
    pub fn deinit(self: *Peer) void {
        glowcap_webrtc_sidecar_peer_free(self.peer);
        self.* = undefined;
    }

    /// Produce this peer's SDP offer into `out` and set it as the local
    /// description, writing the SDP length to `out_len` and returning it as a
    /// slice of `out`. On `error.BufferTooSmall` the required length is still
    /// written to `out_len`, so the caller retries with a buffer that size.
    /// Offerer only.
    pub fn createOffer(self: *Peer, out: []u8, out_len: *usize) SignalError![]const u8 {
        const capped = out[0..@min(out.len, max_signal_bytes)];
        return switch (glowcap_webrtc_sidecar_peer_create_offer(self.peer, capped.ptr, capped.len, out_len)) {
            rc_ok => out[0..out_len.*],
            rc_signal_too_large => error.SignalTooLarge,
            rc_buffer_too_small => if (out_len.* > max_signal_bytes) error.SignalTooLarge else error.BufferTooSmall,
            else => error.SignalFailed,
        };
    }

    /// Produce this peer's SDP answer into `out` and set it as the local
    /// description, writing the SDP length to `out_len`. Answerer only, after
    /// `setRemoteOffer`. `error.BufferTooSmall` still writes the required length.
    pub fn createAnswer(self: *Peer, out: []u8, out_len: *usize) SignalError![]const u8 {
        const capped = out[0..@min(out.len, max_signal_bytes)];
        return switch (glowcap_webrtc_sidecar_peer_create_answer(self.peer, capped.ptr, capped.len, out_len)) {
            rc_ok => out[0..out_len.*],
            rc_signal_too_large => error.SignalTooLarge,
            rc_buffer_too_small => if (out_len.* > max_signal_bytes) error.SignalTooLarge else error.BufferTooSmall,
            else => error.SignalFailed,
        };
    }

    /// Set the far offerer's SDP offer as the remote description. Answerer side.
    pub fn setRemoteOffer(self: *Peer, sdp: []const u8) SignalError!void {
        if (sdp.len > max_signal_bytes) return error.SignalTooLarge;
        if (glowcap_webrtc_sidecar_peer_set_remote(self.peer, sdp.ptr, sdp.len, 1) != rc_ok) return error.SignalFailed;
    }

    /// Set the far answerer's SDP answer as the remote description. Offerer side.
    pub fn setRemoteAnswer(self: *Peer, sdp: []const u8) SignalError!void {
        if (sdp.len > max_signal_bytes) return error.SignalTooLarge;
        if (glowcap_webrtc_sidecar_peer_set_remote(self.peer, sdp.ptr, sdp.len, 0) != rc_ok) return error.SignalFailed;
    }

    /// Add one ICE candidate the far peer gathered, as the JSON its
    /// `nextLocalCandidate` produced. One that arrives before the remote
    /// description is held and added once that description is set.
    pub fn addRemoteCandidate(self: *Peer, candidate: []const u8) SignalError!void {
        if (candidate.len > max_ice_candidate_bytes) return error.SignalTooLarge;
        if (glowcap_webrtc_sidecar_peer_add_remote_candidate(self.peer, candidate.ptr, candidate.len) != rc_ok) return error.SignalFailed;
    }

    /// Drain the next locally gathered ICE candidate into `out` as JSON, writing
    /// its length to `out_len`, or null when none is pending yet. The caller status-allow: pending state or quoted runtime label
    /// ferries each to the far peer. `error.BufferTooSmall` still writes the
    /// required length to `out_len`.
    pub fn nextLocalCandidate(self: *Peer, out: []u8, out_len: *usize) SignalError!?[]const u8 {
        const capped = out[0..@min(out.len, max_ice_candidate_bytes)];
        return switch (glowcap_webrtc_sidecar_peer_next_local_candidate(self.peer, capped.ptr, capped.len, out_len)) {
            rc_ok => out[0..out_len.*],
            rc_would_block => null,
            rc_signal_too_large => error.SignalTooLarge,
            rc_buffer_too_small => if (out_len.* > max_ice_candidate_bytes) error.SignalTooLarge else error.BufferTooSmall,
            else => error.SignalFailed,
        };
    }

    /// Non-blocking channel-open check. `WouldBlock` means wait for an `ev_open`
    /// or `ev_closed` readiness record and retry. `Failed` is terminal setup
    /// failure.
    pub const OpenError = error{ WouldBlock, Closed, Failed };

    pub fn checkOpen(self: *const Peer) OpenError!void {
        return switch (glowcap_webrtc_sidecar_peer_is_open(self.peer)) {
            rc_ok => {},
            rc_would_block => error.WouldBlock,
            rc_closed => error.Closed,
            else => error.Failed,
        };
    }

    pub const TryPacketError = error{ WouldBlock, Closed, Failed, BufferTooSmall };

    /// Non-blocking packet receive for readiness owners. `WouldBlock` means
    /// re-arm on `ev_readable`. `Closed` is clean end of stream.
    pub fn tryReceivePacket(self: *Peer, buf: []u8) TryPacketError!usize {
        const n = glowcap_webrtc_sidecar_conn_try_receive_packet(self.peer, buf.ptr, buf.len);
        if (n == 0) return error.Closed;
        if (n == rc_would_block) return error.WouldBlock;
        if (n == rc_buffer_too_small) return error.BufferTooSmall;
        // A count past the buffer is the sidecar breaking its contract.
        if (n < 0 or n > buf.len) return error.Failed;
        return @intCast(n);
    }

    /// Hand one whole packet to the sidecar's outbound staging buffer and return
    /// immediately. `WouldBlock` means re-arm on `ev_writable` and retry the
    /// same packet.
    pub fn trySendPacket(self: *Peer, bytes: []const u8) TryPacketError!usize {
        const n = glowcap_webrtc_sidecar_conn_try_send_packet(self.peer, bytes.ptr, bytes.len);
        if (n == rc_would_block) return error.WouldBlock;
        if (n == rc_buffer_too_small) return error.BufferTooSmall;
        if (n < 0 or n > bytes.len) return error.Failed;
        return @intCast(n);
    }
};

/// The WebRTC netlayer resident: one shared sidecar runtime, readiness fd, and
/// stable peer-id namespace. It exposes no `Netlayer`: a bare
/// `webrtc` locator carries no signaling authority, so generic address-based
/// dial and listen methods would be false APIs. The host's dial classifier still
/// identifies the signaling shape. A signaling owner creates peers here.
pub const Resident = struct {
    endpoint: *CEndpoint,

    pub const InitError = IceConfigError || error{EndpointCreateFailed};

    /// One endpoint's configuration. The C ABI's `GlowcapWebrtcConfig` is the
    /// authority on what each setting means. A single config so a future
    /// endpoint setting rides it without growing the constructor's arity.
    ///
    /// `include_loopback_candidates` defaults to false, so a peer offers
    /// loopback only where a caller says it wants it. Two peers in one process
    /// or on one host need it and say so. A deployment neither needs it nor
    /// wants to advertise addresses a partner can never use.
    pub const Config = struct {
        ice_servers: []const IceServerConfig = &.{},
        include_loopback_candidates: bool = false,
        worker_threads: u32 = 0,
    };

    pub fn init(config: Config) InitError!Resident {
        try validateIceServers(config.ice_servers);
        const c_config: CEndpointConfig = .{
            .ice_servers = if (config.ice_servers.len == 0) null else config.ice_servers.ptr,
            .ice_server_count = config.ice_servers.len,
            .include_loopback_candidates = @intFromBool(config.include_loopback_candidates),
            .worker_threads = config.worker_threads,
        };
        return .{
            .endpoint = glowcap_webrtc_sidecar_endpoint_new(&c_config) orelse return error.EndpointCreateFailed,
        };
    }

    pub fn deinit(self: *Resident) error{SidecarTeardownFailed}!void {
        if (glowcap_webrtc_sidecar_endpoint_free(self.endpoint) != 0) return error.SidecarTeardownFailed;
        self.* = undefined;
    }

    pub fn newPeer(self: *Resident, is_offerer: bool) Peer.InitError!Peer {
        return Peer.init(self, is_offerer);
    }

    /// Borrowed, read-only OS readiness fd. Register it once and call
    /// `drainReady` whenever it wakes. The resident owns it until `deinit`.
    pub fn readinessFd(self: *const Resident) i32 {
        return glowcap_webrtc_sidecar_endpoint_readiness_fd(self.endpoint);
    }

    /// Clear the fd's coalesced wake bytes, then drain stable peer-id records.
    /// Owning that order here makes a lost-wakeup ordering error unavailable to
    /// callers. A concurrent signal either joins this drain or leaves its wake
    /// byte for the next poll.
    pub fn drainReady(self: *const Resident, out: []ReadyEvent) error{ReadinessFailed}!usize {
        const count = glowcap_webrtc_sidecar_endpoint_drain_ready(self.endpoint, out.ptr, out.len);
        // A count past `out` is the sidecar breaking its contract.
        if (count < 0 or count > out.len) return error.ReadinessFailed;
        return @intCast(count);
    }

    /// Borrow the generic driver's independent subscription. Calling this
    /// lazily creates the second sidecar queue. Raw signaling continues to use
    /// `readinessFd`/`drainReady` and cannot lose events to the driver.
    pub fn driverReadinessFd(self: *const Resident) i32 {
        return glowcap_webrtc_sidecar_endpoint_driver_readiness_fd(self.endpoint);
    }

    pub fn drainDriverReady(self: *const Resident, out: []ReadyEvent) error{ReadinessFailed}!usize {
        const count = glowcap_webrtc_sidecar_endpoint_drain_driver_ready(self.endpoint, out.ptr, out.len);
        if (count < 0 or count > out.len) return error.ReadinessFailed;
        return @intCast(count);
    }

    /// Park on the readiness fd for at most `timeout_ms`, then perform the same
    /// ordered wake-byte and record drain as `drainReady`. This is the blocking
    /// embedding helper. Reactors register `readinessFd` and call `drainReady`
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
