//! The WebRTC transport's public C ABI: a host-driven peer boundary for C, the
//! peer-to-peer DataChannel sibling of the iroh QUIC companion (ADR-0089).
//!
//! This is a separate artifact from `libglowcap_ocapn` (ADR-0059): it links
//! the Rust webrtc sidecar, so folding it into the pure-Zig core would drag
//! cargo into every consumer of the protocol library. The artifact
//! (`libglowcap_net_transport_webrtc`) is a companion, not a superset. It
//! imports only the shared vocabulary leaf (`@import("c_abi_shared")`: codes,
//! allocation, the last-error slot), so it exports just the `glowcap_webrtc_*`
//! family and shares no core symbol with `libglowcap_ocapn`. A consumer links
//! both libraries (core for the peer surface, this for the transport) and reuses
//! the shared types by layout, as a C program including both headers
//! does. The core archives never import this file and stay cargo-free.
//!
//! Unlike iroh, a WebRTC peer has no dialable address, so there is no
//! `connect(addr)`. Signaling brings a channel up, in one of two ways. A
//! netlayer created with `GlowcapWebrtcConfig.signaling` runs the exchange
//! itself, calling the application to carry each offer, answer, and
//! candidate. For the driver's dials it takes the answer back through
//! `glowcap_webrtc_netlayer_provide_answer` (ADR-0226, `dial.zig`), and for
//! the driver's listener it takes each inbound offer through
//! `glowcap_webrtc_netlayer_provide_offer` (ADR-0232, `accept.zig`). An
//! application can instead drive the exchange by hand with the
//! `glowcap_webrtc_peer_*` calls (`peer_signaling.zig`) and give the open
//! peer to the driver through the provider's `claim_external`. Either way,
//! channel establishment and byte
//! I/O use the same reactor discipline: one netlayer readiness fd reports
//! stable peer-id OPEN/CANDIDATE/READABLE/WRITABLE/CLOSED events, and every
//! drain or try-I/O call returns immediately.
//!
//! Symbol names avoid the sidecar's own `glowcap_webrtc_sidecar_*`
//! exports, so the private byte-level seam and this public ABI share no prefix
//! and link into one library without colliding.
//!
//! Threading: a `GlowcapWebrtcNetlayer` and its peers are single-owner. Signaling
//! submissions complete synchronously and may wait on the sidecar runtime, so a
//! host performs them outside its reactor turn. Once submitted, channel progress,
//! candidates, byte I/O, and closure are readiness-driven and never park the
//! reactor. Release every peer before releasing its netlayer.

pub const std_options = @import("c_abi_shared").library_options;

const std = @import("std");

const webrtc = @import("webrtc");
const crypto = @import("foundation").crypto;
const ownership = @import("ownership.zig");
const provider = @import("provider.zig");
const exchange = @import("exchange.zig");
const accept = @import("accept.zig");
const peer_signaling = @import("peer_signaling.zig");

// The shared C-ABI vocabulary leaf (codes, allocation policy, the per-thread
// last-error slot), not the `c_abi` ocapn root, so this transport ABI pulls
// none of libglowcap_ocapn's exported surface (ADR-0059 companion split).
const c = @import("c_abi_shared");

pub const contract_layouts = [_]c.archive_contract.Layout{
    c.archive_contract.layout("GLOWCAP_WEBRTC_READY_EVENT", GlowcapWebrtcReadyEvent),
    c.archive_contract.layout("GLOWCAP_WEBRTC_STRING_VIEW", GlowcapWebrtcStringView),
    c.archive_contract.layout("GLOWCAP_WEBRTC_ICE_SERVER", GlowcapWebrtcIceServer),
    c.archive_contract.layout("GLOWCAP_WEBRTC_SIGNALING", GlowcapWebrtcSignaling),
    c.archive_contract.layout("GLOWCAP_WEBRTC_CONFIG", GlowcapWebrtcConfig),
};
pub const GLOWCAP_WEBRTC_ARCHIVE_FINGERPRINT = c.archive_contract.fingerprint(
    "webrtc",
    @This(),
    .{ c.contract_layouts, contract_layouts },
);

pub export fn glowcap_webrtc_archive_fingerprint() u64 {
    return GLOWCAP_WEBRTC_ARCHIVE_FINGERPRINT;
}

// The opaque context handle whose allocator the `_in` constructor twin uses,
// so allocation policy is one axis spelled one way across every archive
// (ADR-0059), the same twin `glowcap_tcp_netlayer_new_in` and its siblings hold.
const GlowcapContext = c.GlowcapContext;

pub const GlowcapWebrtcPeer = ownership.GlowcapWebrtcPeer;
pub const GlowcapWebrtcNetlayer = ownership.GlowcapWebrtcNetlayer;
pub const GlowcapWebrtcSignaling = exchange.GlowcapWebrtcSignaling;
pub const GlowcapWebrtcSendOfferFn = exchange.GlowcapWebrtcSendOfferFn;
pub const GlowcapWebrtcSendAnswerFn = exchange.GlowcapWebrtcSendAnswerFn;
pub const GlowcapWebrtcSendCandidateFn = exchange.GlowcapWebrtcSendCandidateFn;
pub const GlowcapWebrtcExchangeDoneFn = exchange.GlowcapWebrtcExchangeDoneFn;

pub const GLOWCAP_WEBRTC_EV_OPEN: u32 = webrtc.ev_open;
pub const GLOWCAP_WEBRTC_EV_CANDIDATE: u32 = webrtc.ev_candidate;
pub const GLOWCAP_WEBRTC_EV_READABLE: u32 = webrtc.ev_readable;
pub const GLOWCAP_WEBRTC_EV_WRITABLE: u32 = webrtc.ev_writable;
pub const GLOWCAP_WEBRTC_EV_CLOSED: u32 = webrtc.ev_closed;
pub const GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES: usize = webrtc.max_signal_bytes;
pub const GLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES: usize = webrtc.max_ice_candidate_bytes;
pub const GLOWCAP_WEBRTC_MAX_ICE_SERVERS: usize = webrtc.max_ice_servers;
pub const GLOWCAP_WEBRTC_MAX_ICE_URLS_PER_SERVER: usize = webrtc.max_ice_urls_per_server;
pub const GLOWCAP_WEBRTC_MAX_ICE_URL_BYTES: usize = webrtc.max_ice_url_bytes;
pub const GLOWCAP_WEBRTC_MAX_ICE_CREDENTIAL_BYTES: usize = webrtc.max_ice_credential_bytes;
pub const GLOWCAP_WEBRTC_MAX_PENDING_ICE_CANDIDATES: usize = webrtc.max_pending_ice_candidates;
pub const GLOWCAP_WEBRTC_MAX_ACCEPTS_IN_FLIGHT: usize = webrtc.max_accepts_in_flight;
pub const GLOWCAP_WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES: usize = webrtc.pending_ice_candidate_queue_bytes;
pub const GLOWCAP_WEBRTC_DATA_CHANNEL_QUEUE_BYTES: usize = webrtc.data_channel_queue_bytes;
pub const GlowcapWebrtcStringView = webrtc.StringView;
pub const GlowcapWebrtcIceServer = webrtc.IceServerConfig;

/// One readiness record. `subject` is `glowcap_webrtc_peer_id(peer)` and is
/// never reused during this netlayer's lifetime.
pub const GlowcapWebrtcReadyEvent = extern struct {
    subject: usize,
    events: u32,
};

const setLastError = c.setLastError;

const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = c.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_BUFFER_TOO_SMALL = c.GLOWCAP_ERR_BUFFER_TOO_SMALL;
const GLOWCAP_ERR_INTERNAL = c.GLOWCAP_ERR_INTERNAL;
const GLOWCAP_ERR_WOULD_BLOCK = c.GLOWCAP_ERR_WOULD_BLOCK;
const GLOWCAP_ERR_CLOSED = c.GLOWCAP_ERR_CLOSED;
const GLOWCAP_ERR_IO = c.GLOWCAP_ERR_IO;

/// The annotated symbol inventory (crossing semantics per export) the binding
/// FFI-table generators reflect from. See `symbols.zig`.
pub const symbols = @import("symbols.zig");

const PeerPayload = ownership.PeerPayload;
const NetlayerPayload = ownership.NetlayerPayload;
const releaseNetlayer = ownership.releaseNetlayer;
const releasePeer = ownership.releasePeer;
const payloadFromOpaque = ownership.payloadFromOpaque;
const netlayerFromOpaque = ownership.netlayerFromOpaque;
const ioError = peer_signaling.ioError;

/// Copy the calling thread's last webrtc-transport error into `out_buf`, the
/// webrtc sibling of `glowcap_last_error`. Copies at most `cap - 1` bytes and
/// always NUL-terminates when `cap > 0`. `out_buf == NULL` or `cap == 0` queries
/// the length. Returns the full message length, or 0 when none is set.
pub export fn glowcap_webrtc_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return c.lastErrorRead(out_buf, cap);
}

/// Clear the calling thread's webrtc-transport last error slot.
pub export fn glowcap_webrtc_clear_last_error() void {
    c.lastErrorClear();
}

/// One WebRTC endpoint's configuration, filled by the caller and passed to
/// `glowcap_webrtc_netlayer_new` / `_new_in`.
///
/// This struct is the authority for what these settings mean. The resident and
/// the sidecar mirror it and point here.
///
/// `ice_servers` is a borrowed array of generic ICE server records. Empty offers
/// host candidates only, which connects two peers on one network and nothing
/// beyond it, because neither end can discover the address a NAT gave it. Each
/// record has 1-`GLOWCAP_WEBRTC_MAX_ICE_URLS_PER_SERVER` non-empty UTF-8
/// `stun:`, `stuns:`, `turn:`, or `turns:` URLs. A configuration has at most
/// `GLOWCAP_WEBRTC_MAX_ICE_SERVERS` records. A deployment crossing NAT names
/// STUN servers here. Restrictive networks can add credentialed TURN records
/// from any issuer that supplies URLs plus short-lived username/password
/// credentials. Credentials are empty unless at least one URL in the record is
/// TURN, and both username and credential are required for TURN. Provider
/// endpoints, long-lived issuer tokens, expiry, and refresh policy stay outside
/// this transport ABI.
///
/// `include_loopback_candidates` offers loopback addresses too, so two peers
/// in one process or on one host can connect with no STUN. It is off
/// unless asked for. A test wants it and says so, while a deployment neither
/// needs it nor wants to advertise addresses a partner can never reach.
///
/// `worker_threads` sizes this endpoint's runtime. 0 takes the sidecar's
/// default. It is a per-endpoint cost, so a process holding many endpoints, or
/// one endpoint holding many peers, is the caller that should name it.
///
/// There is no establishment deadline here, unlike the iroh endpoint's
/// `connect_timeout_ms`. That sidecar
/// performs a dial on the caller's behalf and is the only party that can see it
/// fail, so it must bound it. This one runs a state machine the caller feeds,
/// and publishes every terminal outcome as a readiness event, including a
/// connection that fails to establish. The caller already owns the wall clock,
/// and a second deadline here would be a second authority for the same fact.
///
/// `signaling` is how the application carries offers, answers, and candidates
/// for the exchanges this netlayer runs on the driver's behalf
/// (`GlowcapWebrtcSignaling`). `send_offer` gives the provider its connect
/// verbs and `send_answer` its listen verbs. Left zero, the netlayer runs no
/// exchange: the driver refuses a `webrtc` dial or listen as unsupported, and
/// only peers the application signals by hand reach the driver, through
/// `claim_external`.
///
/// Callers must zero-initialize the whole struct before filling the fields they
/// set, so a field added in a later version defaults to 0 rather than reading a
/// caller's stack garbage. The `extern struct` counterpart of the header's
/// `GlowcapWebrtcConfig`.
pub const GlowcapWebrtcConfig = extern struct {
    ice_servers: ?[*]const GlowcapWebrtcIceServer,
    ice_server_count: usize,
    include_loopback_candidates: u32,
    worker_threads: u32,
    signaling: GlowcapWebrtcSignaling,
};

/// Create the shared WebRTC runtime and readiness endpoint. Every peer is
/// created from this netlayer and must be released before the netlayer.
/// `config` carries the endpoint's settings. A null one is
/// `GLOWCAP_ERR_NULL_POINTER`.
pub export fn glowcap_webrtc_netlayer_new(
    config: ?*const GlowcapWebrtcConfig,
    out_netlayer: ?*?*GlowcapWebrtcNetlayer,
) i32 {
    c.lastErrorClear();
    const slot = out_netlayer orelse return GLOWCAP_ERR_NULL_POINTER;
    const cfg = config orelse return GLOWCAP_ERR_NULL_POINTER;
    return netlayerNewIn(c.library_allocator, cfg, slot);
}

pub export fn glowcap_webrtc_netlayer_new_in(
    context: ?*GlowcapContext,
    config: ?*const GlowcapWebrtcConfig,
    out_netlayer: ?*?*GlowcapWebrtcNetlayer,
) i32 {
    c.lastErrorClear();
    const c_ctx = c.ctxFromOpaque(context) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_netlayer orelse return GLOWCAP_ERR_NULL_POINTER;
    const cfg = config orelse return GLOWCAP_ERR_NULL_POINTER;
    return netlayerNewIn(c_ctx.allocator(), cfg, slot);
}

fn netlayerNewIn(
    alloc: std.mem.Allocator,
    cfg: *const GlowcapWebrtcConfig,
    slot: *?*GlowcapWebrtcNetlayer,
) i32 {
    slot.* = null;
    const ice_servers = decodeIceServers(cfg) catch |err| return iceConfigPointerError(err);
    exchange.validate(cfg.signaling) catch |err| switch (err) {
        error.HalfSignaling => {
            setLastError("webrtc netlayer_new: signaling needs send_candidate with send_offer or send_answer, or none of them", .{});
            return GLOWCAP_ERR_INVALID_ARGUMENT;
        },
    };
    const payload = alloc.create(NetlayerPayload) catch |err|
        return c.failInternal("webrtc netlayer_new", err);
    payload.* = .{
        .resident = webrtc.Resident.init(.{
            .ice_servers = ice_servers,
            .include_loopback_candidates = cfg.include_loopback_candidates != 0,
            .worker_threads = cfg.worker_threads,
        }) catch |err| {
            alloc.destroy(payload);
            return residentInitError(err);
        },
        .allocator = alloc,
        .signaling = cfg.signaling,
    };
    slot.* = @ptrCast(payload);
    return GLOWCAP_OK;
}

fn decodeIceServers(cfg: *const GlowcapWebrtcConfig) error{NullPointer}![]const GlowcapWebrtcIceServer {
    const servers = cfg.ice_servers;
    const count = cfg.ice_server_count;
    if (count == 0) return &.{};
    const ptr = servers orelse return error.NullPointer;
    return ptr[0..count];
}

fn iceConfigPointerError(err: error{NullPointer}) i32 {
    switch (err) {
        error.NullPointer => {
            setLastError("webrtc netlayer_new: ICE server array is null with a non-zero count", .{});
            return GLOWCAP_ERR_NULL_POINTER;
        },
    }
}

fn residentInitError(err: webrtc.Resident.InitError) i32 {
    switch (err) {
        error.NullPointer => {
            setLastError("webrtc netlayer_new: ICE configuration has a non-empty null view", .{});
            return GLOWCAP_ERR_NULL_POINTER;
        },
        error.TooManyIceServers => setLastError("webrtc netlayer_new: too many ICE server records", .{}),
        error.MissingIceUrls => setLastError("webrtc netlayer_new: each ICE server needs at least one URL", .{}),
        error.TooManyIceUrls => setLastError("webrtc netlayer_new: too many URLs in one ICE server", .{}),
        error.EmptyIceUrl => setLastError("webrtc netlayer_new: ICE server URL must not be empty", .{}),
        error.IceUrlTooLarge => setLastError("webrtc netlayer_new: ICE server URL is too large", .{}),
        error.InvalidIceUrlUtf8 => setLastError("webrtc netlayer_new: ICE server URL is not UTF-8", .{}),
        error.InvalidIceUrlScheme => setLastError("webrtc netlayer_new: ICE server URL must use stun:, stuns:, turn:, or turns:", .{}),
        error.StunCredentials => setLastError("webrtc netlayer_new: STUN-only ICE records must not carry TURN credentials", .{}),
        error.MissingTurnCredentials => setLastError("webrtc netlayer_new: TURN ICE records need both username and credential", .{}),
        error.CredentialTooLarge => setLastError("webrtc netlayer_new: TURN credential text is too large", .{}),
        error.InvalidCredentialUtf8 => setLastError("webrtc netlayer_new: TURN credential text is not UTF-8", .{}),
        error.EndpointCreateFailed => return c.failIo("webrtc netlayer_new endpoint", err),
    }
    return GLOWCAP_ERR_INVALID_ARGUMENT;
}

/// Borrow the netlayer's single read-only readiness fd. Register it once. Do
/// not close it.
pub export fn glowcap_webrtc_netlayer_readiness_fd(netlayer: ?*GlowcapWebrtcNetlayer) i32 {
    c.lastErrorClear();
    const payload = netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    return payload.resident.readinessFd();
}

/// Drain pending stable peer-id events without blocking. The fd wake bytes are
/// consumed before the authoritative queue, preserving concurrent wakeups.
pub export fn glowcap_webrtc_netlayer_drain_ready(
    netlayer: ?*GlowcapWebrtcNetlayer,
    out_events: ?[*]GlowcapWebrtcReadyEvent,
    out_cap: usize,
    out_count: ?*usize,
) i32 {
    c.lastErrorClear();
    const payload = netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const dest = out_events orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_count orelse return GLOWCAP_ERR_NULL_POINTER;
    if (out_cap == 0) {
        setLastError("webrtc drain_ready: out_cap must not be zero", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }

    var raw: [128]webrtc.ReadyEvent = undefined;
    var count: usize = 0;
    while (count < out_cap) {
        const want = @min(out_cap - count, raw.len);
        const n = payload.resident.drainReady(raw[0..want]) catch |err|
            return c.failInternal("webrtc drain_ready", err);
        for (raw[0..n]) |event| {
            dest[count] = .{ .subject = event.subject, .events = event.events };
            count += 1;
        }
        if (n < want) break;
    }
    slot.* = count;
    return GLOWCAP_OK;
}

/// Release the readiness endpoint after every peer created from it is released.
pub export fn glowcap_webrtc_netlayer_release(netlayer: ?*GlowcapWebrtcNetlayer) i32 {
    c.lastErrorClear();
    const payload = netlayerFromOpaque(netlayer) orelse return GLOWCAP_OK;
    if (releaseNetlayer(payload)) |failure|
        return c.failIo("webrtc netlayer release", failure);
    return GLOWCAP_OK;
}

/// Create a peer in one of the two signaling roles from `netlayer`.
pub export fn glowcap_webrtc_peer_new(netlayer: ?*GlowcapWebrtcNetlayer, is_offerer: i32, out_peer: ?*?*GlowcapWebrtcPeer) i32 {
    c.lastErrorClear();
    const nl = netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    return peerNewIn(nl.allocator, nl, is_offerer, out_peer);
}

/// As `glowcap_webrtc_peer_new`, allocating the peer shell through `context`.
pub export fn glowcap_webrtc_peer_new_in(context: ?*GlowcapContext, netlayer: ?*GlowcapWebrtcNetlayer, is_offerer: i32, out_peer: ?*?*GlowcapWebrtcPeer) i32 {
    c.lastErrorClear();
    const c_ctx = c.ctxFromOpaque(context) orelse return GLOWCAP_ERR_NULL_POINTER;
    const nl = netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    return peerNewIn(c_ctx.allocator(), nl, is_offerer, out_peer);
}

fn peerNewIn(alloc: std.mem.Allocator, nl: *NetlayerPayload, is_offerer: i32, out_peer: ?*?*GlowcapWebrtcPeer) i32 {
    const slot = out_peer orelse return GLOWCAP_ERR_NULL_POINTER;
    slot.* = null;
    const payload = ownership.createPeer(alloc, nl, is_offerer != 0) catch |err| return switch (err) {
        error.NetlayerReleased => {
            setLastError("webrtc peer_new: netlayer already released", .{});
            return GLOWCAP_ERR_CLOSED;
        },
        error.OutOfMemory => c.failInternal("webrtc peer_new", err),
        error.PeerCreateFailed => c.failIo("webrtc peer_new: the WebRTC library", err),
    };
    slot.* = @ptrCast(payload);
    return GLOWCAP_OK;
}

/// Stable readiness identity for this peer, unique for the netlayer's lifetime.
pub export fn glowcap_webrtc_peer_id(peer: ?*GlowcapWebrtcPeer) usize {
    const payload = payloadFromOpaque(peer) orelse return 0;
    return @backingInt(payload.peer.id());
}

/// Non-blocking channel-open check. Retry after OPEN or CLOSED readiness.
/// `GLOWCAP_ERR_IO` means setup faulted before the channel opened.
pub export fn glowcap_webrtc_peer_is_open(peer: ?*GlowcapWebrtcPeer) i32 {
    c.lastErrorClear();
    const payload = payloadFromOpaque(peer) orelse return GLOWCAP_ERR_NULL_POINTER;
    payload.peer.checkOpen() catch |err| return switch (err) {
        error.WouldBlock => GLOWCAP_ERR_WOULD_BLOCK,
        error.Closed => GLOWCAP_ERR_CLOSED,
        error.Failed => ioError("peer_is_open: the channel faulted"),
    };
    return GLOWCAP_OK;
}

/// Non-blocking receive of one inbound packet. Retry after READABLE readiness.
pub export fn glowcap_webrtc_peer_try_receive_packet(peer: ?*GlowcapWebrtcPeer, buf: ?[*]u8, len: usize, out_read: ?*usize) i32 {
    c.lastErrorClear();
    const payload = payloadFromOpaque(peer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const dest = buf orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_read orelse return GLOWCAP_ERR_NULL_POINTER;
    const n = payload.peer.tryReceivePacket(dest[0..len]) catch |err| return switch (err) {
        error.WouldBlock => GLOWCAP_ERR_WOULD_BLOCK,
        error.Closed => GLOWCAP_ERR_CLOSED,
        error.BufferTooSmall => GLOWCAP_ERR_BUFFER_TOO_SMALL,
        error.Failed => ioError("peer_try_receive_packet: the channel faulted"),
    };
    slot.* = n;
    return GLOWCAP_OK;
}

/// Hand one whole outbound packet to the sidecar's staging buffer and return
/// immediately. On `GLOWCAP_ERR_WOULD_BLOCK`, retry the same packet after
/// WRITABLE readiness.
pub export fn glowcap_webrtc_peer_try_send_packet(peer: ?*GlowcapWebrtcPeer, buf: ?[*]const u8, len: usize, out_written: ?*usize) i32 {
    c.lastErrorClear();
    const payload = payloadFromOpaque(peer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const src = buf orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_written orelse return GLOWCAP_ERR_NULL_POINTER;
    const n = payload.peer.trySendPacket(src[0..len]) catch |err| return switch (err) {
        error.WouldBlock => GLOWCAP_ERR_WOULD_BLOCK,
        error.Closed => GLOWCAP_ERR_CLOSED,
        error.BufferTooSmall => GLOWCAP_ERR_BUFFER_TOO_SMALL,
        error.Failed => ioError("peer_try_send_packet: the channel faulted"),
    };
    slot.* = n;
    return GLOWCAP_OK;
}

/// Close the channel and connection without releasing the handle, waking any
/// readiness owner with CLOSED. Idempotent. Release still frees the handle.
pub export fn glowcap_webrtc_peer_close(peer: ?*GlowcapWebrtcPeer) void {
    const payload = payloadFromOpaque(peer) orelse return;
    payload.peer.close();
}

/// Release the peer, closing its channel. When the caller already released the
/// public netlayer lease, this consumes the endpoint's final lease and returns
/// that teardown outcome instead of hiding it in thread-local diagnostics.
pub export fn glowcap_webrtc_peer_release(peer: ?*GlowcapWebrtcPeer) i32 {
    c.lastErrorClear();
    const payload = payloadFromOpaque(peer) orelse return GLOWCAP_OK;
    if (!payload.provider_claimed) {
        // tolerant: the driver may already have retired its ownership edge, and
        // the caller's final handle release still owns this reference.
        _ = payload.netlayer.peers.remove(@backingInt(payload.peer.id()));
    }
    if (releasePeer(payload)) |failure|
        return c.failIo("webrtc peer release", failure);
    return GLOWCAP_OK;
}

/// Fill the generic driver provider package. The driver claims a peer the
/// application signaled by hand through `claim_external`, dials through the
/// connect verbs when the netlayer's signaling carries `send_offer`, and
/// listens through the listen verbs when it carries `send_answer`.
pub export fn glowcap_webrtc_transport_provider(
    netlayer: ?*GlowcapWebrtcNetlayer,
    out_provider: ?*c.GlowcapTransportProvider,
) i32 {
    c.lastErrorClear();
    const payload = netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_provider orelse return GLOWCAP_ERR_NULL_POINTER;
    provider.fill(payload, slot);
    return GLOWCAP_OK;
}

// The exports whose bodies live in a leaf. The alias is the public index, and
// the walk below roots every annotated export so omission from the linked
// artifact is impossible.
pub const glowcap_webrtc_peer_authorize_remote = peer_signaling.glowcap_webrtc_peer_authorize_remote;
pub const glowcap_webrtc_peer_create_offer = peer_signaling.glowcap_webrtc_peer_create_offer;
pub const glowcap_webrtc_peer_create_answer = peer_signaling.glowcap_webrtc_peer_create_answer;
pub const glowcap_webrtc_peer_set_remote_offer = peer_signaling.glowcap_webrtc_peer_set_remote_offer;
pub const glowcap_webrtc_peer_set_remote_answer = peer_signaling.glowcap_webrtc_peer_set_remote_answer;
pub const glowcap_webrtc_peer_add_remote_candidate = peer_signaling.glowcap_webrtc_peer_add_remote_candidate;
pub const glowcap_webrtc_peer_next_local_candidate = peer_signaling.glowcap_webrtc_peer_next_local_candidate;
pub const glowcap_webrtc_netlayer_provide_offer = accept.glowcap_webrtc_netlayer_provide_offer;
pub const glowcap_webrtc_netlayer_provide_answer = exchange.glowcap_webrtc_netlayer_provide_answer;
pub const glowcap_webrtc_netlayer_provide_candidate = exchange.glowcap_webrtc_netlayer_provide_candidate;
pub const glowcap_webrtc_netlayer_fail_exchange = exchange.glowcap_webrtc_netlayer_fail_exchange;

comptime {
    for (symbols.symbols) |symbol| _ = @field(@This(), symbol.name);
}
