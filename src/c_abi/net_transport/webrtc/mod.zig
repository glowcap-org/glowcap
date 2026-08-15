//! The WebRTC transport's public C ABI — a host-driven peer boundary for C, the
//! peer-to-peer DataChannel sibling of the iroh QUIC companion (ADR-0089).
//!
//! This is a *separate artifact* from `libpancake_ocapn` (ADR-0059): it links
//! the Rust webrtc sidecar, so folding it into the pure-Zig core would drag
//! cargo into every consumer of the protocol library. The artifact
//! (`libpancake_net_transport_webrtc`) is a *companion*, not a superset: it
//! imports only the shared vocabulary leaf (`@import("c_abi_shared")` — codes,
//! allocation, the last-error slot), so it exports just the `pancake_webrtc_*`
//! family and shares no core symbol with `libpancake_ocapn`. A consumer links
//! both libraries (core for the peer surface, this for the transport) and reuses
//! the shared types by layout, exactly as a C program including both headers
//! does. The core archives never import this file and stay cargo-free.
//!
//! Unlike iroh, a WebRTC peer has no dialable address, so there is no
//! `connect(addr)`. The caller drives signaling, but channel establishment and
//! byte I/O use the same reactor discipline: one netlayer readiness fd reports
//! stable peer-id OPEN/CANDIDATE/READABLE/WRITABLE/CLOSED events, and every
//! drain or try-I/O call returns immediately.
//!
//! Symbol names deliberately avoid the sidecar's own `pancake_webrtc_sidecar_*`
//! exports, so the private byte-level seam and this public ABI share no prefix
//! and link into one library without colliding.
//!
//! Threading: a `PancakeWebrtcNetlayer` and its peers are single-owner. Signaling
//! submissions complete synchronously and may wait on the sidecar runtime, so a
//! host performs them outside its reactor turn. Once submitted, channel progress,
//! candidates, byte I/O, and closure are readiness-driven and never park the
//! reactor. Release every peer before releasing its netlayer.

const std = @import("std");

const webrtc = @import("webrtc");
const crypto = @import("foundation").crypto;

// The shared C-ABI vocabulary leaf (codes, allocation policy, the per-thread
// last-error slot), not the `c_abi` ocapn root, so this transport ABI pulls
// none of libpancake_ocapn's exported surface (ADR-0059 companion split).
const c = @import("c_abi_shared");

// The opaque context handle whose allocator the `_in` constructor twin uses,
// so allocation policy is one axis spelled one way across every archive
// (ADR-0059), the same twin `pancake_tcp_netlayer_new_in` and its siblings hold.
const PancakeContext = c.PancakeContext;

/// One WebRTC peer: its `RTCPeerConnection` and single data channel, wrapping
/// the netlayer resident's byte-fed `Peer`. Owned by the caller; released with
/// `pancake_webrtc_peer_release`.
pub const PancakeWebrtcPeer = opaque {};
pub const PancakeWebrtcNetlayer = opaque {};

pub const PANCAKE_WEBRTC_EV_OPEN: u32 = webrtc.ev_open;
pub const PANCAKE_WEBRTC_EV_CANDIDATE: u32 = webrtc.ev_candidate;
pub const PANCAKE_WEBRTC_EV_READABLE: u32 = webrtc.ev_readable;
pub const PANCAKE_WEBRTC_EV_WRITABLE: u32 = webrtc.ev_writable;
pub const PANCAKE_WEBRTC_EV_CLOSED: u32 = webrtc.ev_closed;

/// One readiness record. `subject` is `pancake_webrtc_peer_id(peer)` and is
/// never reused during this netlayer's lifetime.
pub const PancakeWebrtcReadyEvent = extern struct {
    subject: usize,
    events: u32,
};

const setLastError = c.setLastError;

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_BUFFER_TOO_SMALL = c.PANCAKE_ERR_BUFFER_TOO_SMALL;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_WOULD_BLOCK = c.PANCAKE_ERR_WOULD_BLOCK;
const PANCAKE_ERR_CLOSED = c.PANCAKE_ERR_CLOSED;
const PANCAKE_ERR_IO = c.PANCAKE_ERR_IO;

/// The annotated symbol inventory (crossing semantics per export) the binding
/// FFI-table generators reflect from — see `symbols.zig`.
pub const symbols = @import("symbols.zig");

/// The heap-pinned peer: the resident `Peer` plus the allocator that frees it.
const PeerPayload = struct {
    peer: webrtc.Peer,
    allocator: std.mem.Allocator,
    netlayer: *NetlayerPayload,
    references: usize = 1,
    provider_claimed: bool = false,
    failure: c.PancakeProviderFailure = std.mem.zeroes(c.PancakeProviderFailure),
};

const NetlayerPayload = struct {
    resident: webrtc.Resident,
    allocator: std.mem.Allocator,
    references: usize = 1,
    peers: std.AutoHashMapUnmanaged(usize, *PeerPayload) = .{},
    provider_profile: c.PancakeTransportProfile = undefined,
    multiplexed_transport: c.PancakeMultiplexedTransport = undefined,
    provider_entry: c.PancakeTransportProviderEntry = undefined,
    provider_initialized: bool = false,
};

fn payloadFromOpaque(p: ?*PancakeWebrtcPeer) ?*PeerPayload {
    return @ptrCast(@alignCast(p orelse return null));
}

fn netlayerFromOpaque(p: ?*PancakeWebrtcNetlayer) ?*NetlayerPayload {
    return @ptrCast(@alignCast(p orelse return null));
}

fn retainNetlayer(payload: *NetlayerPayload) void {
    std.debug.assert(payload.references != 0);
    payload.references += 1;
}

fn releaseNetlayer(payload: *NetlayerPayload) ?anyerror {
    std.debug.assert(payload.references != 0);
    payload.references -= 1;
    if (payload.references != 0) return null;
    std.debug.assert(payload.peers.count() == 0);
    payload.peers.deinit(payload.allocator);
    var failure: ?anyerror = null;
    payload.resident.deinit() catch |err| {
        failure = err;
    };
    payload.allocator.destroy(payload);
    return failure;
}

fn releasePeer(payload: *PeerPayload) ?anyerror {
    std.debug.assert(payload.references != 0);
    payload.references -= 1;
    if (payload.references != 0) return null;
    const allocator = payload.allocator;
    payload.peer.deinit();
    const failure = releaseNetlayer(payload.netlayer);
    allocator.destroy(payload);
    return failure;
}

/// Copy the calling thread's last webrtc-transport error into `out_buf`, the
/// webrtc sibling of `pancake_last_error`. Copies at most `cap - 1` bytes and
/// always NUL-terminates when `cap > 0`; `out_buf == NULL` or `cap == 0` queries
/// the length. Returns the full message length, or 0 when none is set.
pub export fn pancake_webrtc_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return c.lastErrorRead(out_buf, cap);
}

/// Clear the calling thread's webrtc-transport last error slot.
pub export fn pancake_webrtc_clear_last_error() void {
    c.lastErrorClear();
}

/// One WebRTC endpoint's configuration, filled by the caller and passed to
/// `pancake_webrtc_netlayer_new` / `_new_in`.
///
/// **This is the authority for what these settings mean**; the resident and the
/// sidecar mirror this struct and point here.
///
/// `ice_servers` is a comma-separated list of ICE server URLs, borrowed for the
/// call, and it decides how far a peer created from this endpoint can reach.
/// Empty offers host candidates only, which connects two peers on one network
/// and nothing beyond it, because neither end can discover the address a NAT
/// gave it. A deployment crossing NAT names STUN servers here
/// (`stun:host:port`). Credentialed TURN relaying is not expressible yet; see
/// ADR-0089.
///
/// `include_loopback_candidates` offers loopback addresses too, which is what
/// lets two peers in one process or on one host connect with no STUN. It is off
/// unless asked for: a test wants it and says so, while a deployment neither
/// needs it nor wants to advertise addresses a partner can never reach.
///
/// `worker_threads` sizes this endpoint's runtime; 0 takes the sidecar's
/// default. It is a per-endpoint cost, so a process holding many endpoints, or
/// one endpoint holding many peers, is the caller that should name it.
///
/// There is no establishment deadline here, unlike the iroh endpoint's
/// `connect_timeout_ms`, and the difference is deliberate. That sidecar
/// performs a dial on the caller's behalf and is the only party that can see it
/// fail, so it must bound it. This one runs a state machine the caller feeds,
/// and publishes every terminal outcome as a readiness event, including a
/// connection that fails to establish. The caller already owns the wall clock,
/// and a second deadline here would be a second authority for the same fact.
///
/// Callers must zero-initialize the whole struct before filling the fields they
/// set, so a field added in a later version defaults to 0 rather than reading a
/// caller's stack garbage. The `extern struct` counterpart of the header's
/// `PancakeWebrtcConfig`.
pub const PancakeWebrtcConfig = extern struct {
    ice_servers: ?[*]const u8,
    ice_servers_len: usize,
    include_loopback_candidates: u32,
    worker_threads: u32,
};

/// Create the shared WebRTC runtime and readiness endpoint. Every peer is
/// created from this netlayer and must be released before the netlayer.
/// `config` carries the endpoint's settings; a null one is
/// `PANCAKE_ERR_NULL_POINTER`.
pub export fn pancake_webrtc_netlayer_new(
    config: ?*const PancakeWebrtcConfig,
    out_netlayer: ?*?*PancakeWebrtcNetlayer,
) i32 {
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    const cfg = config orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c.library_allocator, cfg, slot);
}

pub export fn pancake_webrtc_netlayer_new_in(
    context: ?*PancakeContext,
    config: ?*const PancakeWebrtcConfig,
    out_netlayer: ?*?*PancakeWebrtcNetlayer,
) i32 {
    const c_ctx = c.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_netlayer orelse return PANCAKE_ERR_NULL_POINTER;
    const cfg = config orelse return PANCAKE_ERR_NULL_POINTER;
    return netlayerNewIn(c_ctx.allocator(), cfg, slot);
}

fn netlayerNewIn(
    alloc: std.mem.Allocator,
    cfg: *const PancakeWebrtcConfig,
    slot: *?*PancakeWebrtcNetlayer,
) i32 {
    slot.* = null;
    const ice_servers = c.sliceFromC(cfg.ice_servers, cfg.ice_servers_len) catch |err| {
        setLastError("webrtc netlayer_new: invalid ice_servers view: {s}", .{@errorName(err)});
        return c.marshalErrorToCode(err);
    };
    const payload = alloc.create(NetlayerPayload) catch |err|
        return c.failInternal("webrtc netlayer_new", err);
    payload.* = .{
        .resident = webrtc.Resident.init(.{
            .ice_servers = ice_servers,
            .include_loopback_candidates = cfg.include_loopback_candidates != 0,
            .worker_threads = cfg.worker_threads,
        }) catch {
            alloc.destroy(payload);
            setLastError("webrtc netlayer_new: the sidecar could not create an endpoint", .{});
            return PANCAKE_ERR_IO;
        },
        .allocator = alloc,
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Borrow the netlayer's single read-only readiness fd. Register it once; do
/// not close it.
pub export fn pancake_webrtc_netlayer_readiness_fd(netlayer: ?*PancakeWebrtcNetlayer) i32 {
    const payload = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    return payload.resident.readinessFd();
}

/// Drain pending stable peer-id events without blocking. The fd wake bytes are
/// consumed before the authoritative queue, preserving concurrent wakeups.
pub export fn pancake_webrtc_netlayer_drain_ready(
    netlayer: ?*PancakeWebrtcNetlayer,
    out_events: ?[*]PancakeWebrtcReadyEvent,
    out_cap: usize,
    out_count: ?*usize,
) i32 {
    const payload = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const dest = out_events orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_count orelse return PANCAKE_ERR_NULL_POINTER;
    if (out_cap == 0) {
        setLastError("webrtc drain_ready: out_cap must not be zero", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
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
    return PANCAKE_OK;
}

/// Release the readiness endpoint after every peer created from it is released.
pub export fn pancake_webrtc_netlayer_release(netlayer: ?*PancakeWebrtcNetlayer) i32 {
    const payload = netlayerFromOpaque(netlayer) orelse return PANCAKE_OK;
    if (releaseNetlayer(payload)) |_| {
        setLastError("webrtc netlayer release: endpoint teardown failed", .{});
        return PANCAKE_ERR_IO;
    }
    return PANCAKE_OK;
}

/// Create a peer in one of the two signaling roles from `netlayer`.
pub export fn pancake_webrtc_peer_new(netlayer: ?*PancakeWebrtcNetlayer, is_offerer: i32, out_peer: ?*?*PancakeWebrtcPeer) i32 {
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    return peerNewIn(nl.allocator, nl, is_offerer, out_peer);
}

/// As `pancake_webrtc_peer_new`, allocating the peer shell through `context`.
pub export fn pancake_webrtc_peer_new_in(context: ?*PancakeContext, netlayer: ?*PancakeWebrtcNetlayer, is_offerer: i32, out_peer: ?*?*PancakeWebrtcPeer) i32 {
    const c_ctx = c.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const nl = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    return peerNewIn(c_ctx.allocator(), nl, is_offerer, out_peer);
}

fn peerNewIn(alloc: std.mem.Allocator, nl: *NetlayerPayload, is_offerer: i32, out_peer: ?*?*PancakeWebrtcPeer) i32 {
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = null;
    const payload = alloc.create(PeerPayload) catch |err|
        return c.failInternal("webrtc peer_new", err);
    retainNetlayer(nl);
    payload.* = .{
        .peer = nl.resident.newPeer(is_offerer != 0) catch {
            _ = releaseNetlayer(nl);
            alloc.destroy(payload);
            setLastError("webrtc peer_new: the sidecar could not create a peer connection", .{});
            return PANCAKE_ERR_IO;
        },
        .allocator = alloc,
        .netlayer = nl,
    };
    nl.peers.put(nl.allocator, @intFromEnum(payload.peer.id()), payload) catch {
        payload.peer.deinit();
        _ = releaseNetlayer(nl);
        alloc.destroy(payload);
        setLastError("webrtc peer_new: the peer subject table could not grow", .{});
        return PANCAKE_ERR_INTERNAL;
    };
    slot.* = @ptrCast(payload);
    return PANCAKE_OK;
}

/// Bind the durable key authorized by the signaling authority. Authorization
/// is a pre-open fact: after the channel opens, changing it would make the
/// provider's transport provenance mutable while the driver owns the wire.
pub export fn pancake_webrtc_peer_authorize_remote(
    peer: ?*PancakeWebrtcPeer,
    designator: ?[*]const u8,
    designator_len: usize,
) i32 {
    const payload = payloadFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes = designator orelse return PANCAKE_ERR_NULL_POINTER;
    if (payload.peer.authorized_remote != null) {
        setLastError("webrtc authorize_remote: remote identity is already authorized", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    if (payload.peer.checkOpen()) |_| {
        setLastError("webrtc authorize_remote: the channel is already open", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    } else |err| switch (err) {
        error.WouldBlock => {},
        error.Closed => return PANCAKE_ERR_CLOSED,
    }
    const key = crypto.PeerKey.fromDesignator(bytes[0..designator_len]) orelse {
        setLastError("webrtc authorize_remote: invalid durable key designator", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    payload.peer.authorizeRemote(key);
    return PANCAKE_OK;
}

/// Produce the offerer's SDP offer into `(out, cap)`, writing its length to
/// `*out_len`. `PANCAKE_ERR_BUFFER_TOO_SMALL` still writes the required length,
/// so the caller retries with a buffer that size. Offerer only.
pub export fn pancake_webrtc_peer_create_offer(peer: ?*PancakeWebrtcPeer, out: ?[*]u8, cap: usize, out_len: ?*usize) i32 {
    return produceSdp(peer, out, cap, out_len, .offer);
}

/// Produce the answerer's SDP answer into `(out, cap)`, writing its length to
/// `*out_len`. Answerer only, after `pancake_webrtc_peer_set_remote_offer`.
pub export fn pancake_webrtc_peer_create_answer(peer: ?*PancakeWebrtcPeer, out: ?[*]u8, cap: usize, out_len: ?*usize) i32 {
    return produceSdp(peer, out, cap, out_len, .answer);
}

const SdpKind = enum { offer, answer };

fn produceSdp(peer: ?*PancakeWebrtcPeer, out: ?[*]u8, cap: usize, out_len: ?*usize, kind: SdpKind) i32 {
    const payload = payloadFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const dest = out orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_len orelse return PANCAKE_ERR_NULL_POINTER;
    const result = switch (kind) {
        .offer => payload.peer.createOffer(dest[0..cap], slot),
        .answer => payload.peer.createAnswer(dest[0..cap], slot),
    };
    _ = result catch |err| return switch (err) {
        error.BufferTooSmall => PANCAKE_ERR_BUFFER_TOO_SMALL,
        error.SignalFailed => ioError("create_offer/answer: the sidecar refused"),
    };
    return PANCAKE_OK;
}

/// Set the far offerer's SDP offer as the remote description. Answerer side.
pub export fn pancake_webrtc_peer_set_remote_offer(peer: ?*PancakeWebrtcPeer, sdp: ?[*]const u8, sdp_len: usize) i32 {
    return setRemote(peer, sdp, sdp_len, true);
}

/// Set the far answerer's SDP answer as the remote description. Offerer side.
pub export fn pancake_webrtc_peer_set_remote_answer(peer: ?*PancakeWebrtcPeer, sdp: ?[*]const u8, sdp_len: usize) i32 {
    return setRemote(peer, sdp, sdp_len, false);
}

fn setRemote(peer: ?*PancakeWebrtcPeer, sdp: ?[*]const u8, sdp_len: usize, is_offer: bool) i32 {
    const payload = payloadFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const src = sdp orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes = src[0..sdp_len];
    const result = if (is_offer) payload.peer.setRemoteOffer(bytes) else payload.peer.setRemoteAnswer(bytes);
    result catch return ioError("set_remote: the sidecar refused the description");
    return PANCAKE_OK;
}

/// Add one remote ICE candidate, as the JSON the far peer's
/// `pancake_webrtc_peer_next_local_candidate` produced.
pub export fn pancake_webrtc_peer_add_remote_candidate(peer: ?*PancakeWebrtcPeer, cand: ?[*]const u8, cand_len: usize) i32 {
    const payload = payloadFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const src = cand orelse return PANCAKE_ERR_NULL_POINTER;
    payload.peer.addRemoteCandidate(src[0..cand_len]) catch return ioError("add_remote_candidate: the sidecar refused the candidate");
    return PANCAKE_OK;
}

/// Drain the next locally gathered ICE candidate into `(out, cap)` as JSON,
/// writing its length to `*out_len`. `PANCAKE_ERR_WOULD_BLOCK` when none is
/// pending yet; `PANCAKE_ERR_BUFFER_TOO_SMALL` still writes the required length.
pub export fn pancake_webrtc_peer_next_local_candidate(peer: ?*PancakeWebrtcPeer, out: ?[*]u8, cap: usize, out_len: ?*usize) i32 {
    const payload = payloadFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const dest = out orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_len orelse return PANCAKE_ERR_NULL_POINTER;
    const candidate = payload.peer.nextLocalCandidate(dest[0..cap], slot) catch |err| return switch (err) {
        error.BufferTooSmall => PANCAKE_ERR_BUFFER_TOO_SMALL,
        error.SignalFailed => ioError("next_local_candidate: the sidecar refused"),
    };
    return if (candidate == null) PANCAKE_ERR_WOULD_BLOCK else PANCAKE_OK;
}

/// Stable readiness identity for this peer, unique for the netlayer's lifetime.
pub export fn pancake_webrtc_peer_id(peer: ?*PancakeWebrtcPeer) usize {
    const payload = payloadFromOpaque(peer) orelse return 0;
    return @intFromEnum(payload.peer.id());
}

/// Non-blocking channel-open check. Retry after OPEN or CLOSED readiness.
pub export fn pancake_webrtc_peer_is_open(peer: ?*PancakeWebrtcPeer) i32 {
    const payload = payloadFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    payload.peer.checkOpen() catch |err| return switch (err) {
        error.WouldBlock => PANCAKE_ERR_WOULD_BLOCK,
        error.Closed => PANCAKE_ERR_CLOSED,
    };
    return PANCAKE_OK;
}

/// Non-blocking read of raw inbound bytes. Retry after READABLE readiness.
pub export fn pancake_webrtc_peer_try_read(peer: ?*PancakeWebrtcPeer, buf: ?[*]u8, len: usize, out_read: ?*usize) i32 {
    const payload = payloadFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const dest = buf orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_read orelse return PANCAKE_ERR_NULL_POINTER;
    const n = payload.peer.tryRead(dest[0..len]) catch |err| return switch (err) {
        error.WouldBlock => PANCAKE_ERR_WOULD_BLOCK,
        error.Closed => PANCAKE_ERR_CLOSED,
        error.Failed => ioError("peer_try_read: the channel faulted"),
    };
    slot.* = n;
    return PANCAKE_OK;
}

/// Hand a bounded prefix to the sidecar's outbound staging buffer and return
/// immediately. Advance by `out_written`; after `PANCAKE_ERR_WOULD_BLOCK`,
/// retry the remaining slice on WRITABLE readiness.
pub export fn pancake_webrtc_peer_try_write(peer: ?*PancakeWebrtcPeer, buf: ?[*]const u8, len: usize, out_written: ?*usize) i32 {
    const payload = payloadFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const src = buf orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_written orelse return PANCAKE_ERR_NULL_POINTER;
    const n = payload.peer.tryWrite(src[0..len]) catch |err| return switch (err) {
        error.WouldBlock => PANCAKE_ERR_WOULD_BLOCK,
        error.Closed => PANCAKE_ERR_CLOSED,
        error.Failed => ioError("peer_try_write: the channel faulted"),
    };
    slot.* = n;
    return PANCAKE_OK;
}

/// Close the channel and connection without releasing the handle, waking any
/// readiness owner with CLOSED. Idempotent; release still frees the handle.
pub export fn pancake_webrtc_peer_close(peer: ?*PancakeWebrtcPeer) void {
    const payload = payloadFromOpaque(peer) orelse return;
    payload.peer.close();
}

/// Release the peer, closing its channel. When the caller already released the
/// public netlayer lease, this consumes the endpoint's final lease and returns
/// that teardown outcome instead of hiding it in thread-local diagnostics.
pub export fn pancake_webrtc_peer_release(peer: ?*PancakeWebrtcPeer) i32 {
    const payload = payloadFromOpaque(peer) orelse return PANCAKE_OK;
    if (!payload.provider_claimed) {
        // tolerant: the driver may already have retired its ownership edge;
        // the caller's final handle release still owns this reference.
        _ = payload.netlayer.peers.remove(@intFromEnum(payload.peer.id()));
    }
    if (releasePeer(payload)) |failure|
        return c.failIo("webrtc peer release", failure);
    return PANCAKE_OK;
}

// ── Generic multiplexed provider ────────────────────────────────────────────

const transport_name = "webrtc";

fn multiplexedReadinessFd(ctx: ?*anyopaque) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    return payload.resident.driverReadinessFd();
}

fn multiplexedDrainReady(ctx: ?*anyopaque, out: ?[*]c.PancakeMultiplexedReadyEvent, cap: usize, out_count: ?*usize, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const count = out_count orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const dest = out orelse if (cap == 0) null else return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    var total: usize = 0;

    var raw: [1]webrtc.ReadyEvent = undefined;
    while (total < cap) {
        const n = payload.resident.drainDriverReady(&raw) catch |err| return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, err);
        if (n == 0) break;
        const event = raw[0];
        const peer = payload.peers.get(event.subject) orelse continue;
        if (!peer.provider_claimed) continue;
        var mapped: u32 = 0;
        if (event.events & webrtc.ev_readable != 0) mapped |= c.multiplexed_transport.PANCAKE_MULTIPLEXED_EV_READABLE;
        if (event.events & webrtc.ev_writable != 0) mapped |= c.multiplexed_transport.PANCAKE_MULTIPLEXED_EV_WRITABLE;
        if (event.events & webrtc.ev_closed != 0) mapped |= c.multiplexed_transport.PANCAKE_MULTIPLEXED_EV_CLOSED;
        if (mapped == 0) continue;
        dest.?[total] = .{ .subject = @intCast(event.subject), .events = mapped };
        total += 1;
    }
    count.* = total;
    return PANCAKE_OK;
}

fn claimExternal(ctx: ?*anyopaque, subject: u64, out_conn: ?*u64, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const slot = out_conn orelse return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
    const peer = payload.peers.get(@intCast(subject)) orelse
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    if (peer.provider_claimed or peer.peer.authorized_remote == null)
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_INVALID_ARGUMENT, error.InvalidOptions);
    peer.peer.checkOpen() catch |err| return switch (err) {
        error.WouldBlock => c.transport_provider.failProvider(out_failure, PANCAKE_ERR_WOULD_BLOCK, err),
        error.Closed => c.transport_provider.failProvider(out_failure, PANCAKE_ERR_CLOSED, err),
    };
    peer.provider_claimed = true;
    peer.references += 1;
    slot.* = subject;
    return PANCAKE_OK;
}

fn multiplexedTryRead(ctx: ?*anyopaque, conn: u64, buf: ?[*]u8, cap: usize) callconv(.c) isize {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const dest = buf orelse return -1;
    const peer = payload.peers.get(@intCast(conn)) orelse return -1;
    if (!peer.provider_claimed) return -1;
    const n = peer.peer.tryRead(dest[0..cap]) catch |err| {
        if (err == error.WouldBlock) return c.multiplexed_transport.PANCAKE_MULTIPLEXED_WOULD_BLOCK;
        if (c.transport_provider.providerFailureEmpty(peer.failure))
            c.transport_provider.setProviderFailure(&peer.failure, PANCAKE_ERR_IO, err);
        return -1;
    };
    return @intCast(n);
}

fn multiplexedTryWrite(ctx: ?*anyopaque, conn: u64, bytes: ?[*]const u8, len: usize) callconv(.c) isize {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const src = bytes orelse return -1;
    const peer = payload.peers.get(@intCast(conn)) orelse return -1;
    if (!peer.provider_claimed) return -1;
    const n = peer.peer.tryWrite(src[0..len]) catch |err| {
        if (err == error.WouldBlock) return c.multiplexed_transport.PANCAKE_MULTIPLEXED_WOULD_BLOCK;
        if (c.transport_provider.providerFailureEmpty(peer.failure))
            c.transport_provider.setProviderFailure(&peer.failure, PANCAKE_ERR_IO, err);
        return -1;
    };
    return @intCast(n);
}

fn multiplexedConnTakeFailure(ctx: ?*anyopaque, conn: u64, out_failure: ?*c.PancakeProviderFailure) callconv(.c) void {
    const slot = out_failure orelse return;
    slot.* = std.mem.zeroes(c.PancakeProviderFailure);
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const peer = payload.peers.get(@intCast(conn)) orelse return;
    if (!peer.provider_claimed) return;
    slot.* = peer.failure;
    peer.failure = std.mem.zeroes(c.PancakeProviderFailure);
}

fn multiplexedConnClose(ctx: ?*anyopaque, conn: u64, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const key: usize = @intCast(conn);
    const peer = payload.peers.get(key) orelse return PANCAKE_OK;
    if (!peer.provider_claimed) return PANCAKE_OK;
    peer.peer.close();
    peer.provider_claimed = false;
    std.debug.assert(payload.peers.remove(key));
    if (releasePeer(peer)) |failure|
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, failure);
    return PANCAKE_OK;
}

fn multiplexedConnRemoteKey(ctx: ?*anyopaque, conn: u64, out_key: ?[*]u8) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const dest = out_key orelse return PANCAKE_ERR_NULL_POINTER;
    const peer = payload.peers.get(@intCast(conn)) orelse return 0;
    if (!peer.provider_claimed) return 0;
    peer.peer.checkOpen() catch return 0;
    const key = peer.peer.authorized_remote orelse return 0;
    @memcpy(dest[0..crypto.PEER_KEY_BYTES], key.asBytes());
    return 1;
}

fn providerRetain(ctx: ?*anyopaque, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx orelse {
        c.transport_provider.setProviderFailure(out_failure, PANCAKE_ERR_NULL_POINTER, error.NullPointer);
        return PANCAKE_ERR_NULL_POINTER;
    }));
    retainNetlayer(payload);
    return PANCAKE_OK;
}

fn providerRelease(ctx: ?*anyopaque, out_failure: ?*c.PancakeProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx orelse return PANCAKE_OK));
    if (releaseNetlayer(payload)) |failure|
        return c.transport_provider.failProvider(out_failure, PANCAKE_ERR_IO, failure);
    return PANCAKE_OK;
}

fn providerSameConfiguration(ctx: ?*anyopaque, other_ctx: ?*anyopaque) callconv(.c) u8 {
    // Each signaling-owned resident is its own external-channel namespace.
    return @intFromBool(ctx == other_ctx);
}

fn ensureProvider(payload: *NetlayerPayload) void {
    if (payload.provider_initialized) return;
    payload.provider_profile = .{
        .abi_version = c.transport_provider.PANCAKE_TRANSPORT_PROFILE_ABI_VERSION,
        .struct_size = @sizeOf(c.PancakeTransportProfile),
        .transport_name = transport_name.ptr,
        .transport_name_len = transport_name.len,
        .designator_scheme = c.transport_provider.PANCAKE_DESIGNATOR_SCHEME_KEY,
        .sealed_channel = c.transport_provider.PANCAKE_SEALED_CHANNEL_NONE,
    };
    payload.multiplexed_transport = .{
        .abi_version = c.multiplexed_transport.PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION,
        .struct_size = @sizeOf(c.PancakeMultiplexedTransport),
        .ctx = payload,
        .readiness_fd = multiplexedReadinessFd,
        .drain_ready = multiplexedDrainReady,
        .start_connect = null,
        .finish_connect = null,
        .claim_external = claimExternal,
        .cancel_connect = null,
        .listen = null,
        .finish_listen = null,
        .cancel_listen = null,
        .listener_locator = null,
        .listener_advertise = null,
        .finish_accept = null,
        .stop_listen = null,
        .try_read = multiplexedTryRead,
        .try_write = multiplexedTryWrite,
        .conn_close = multiplexedConnClose,
        .conn_take_failure = multiplexedConnTakeFailure,
        .conn_remote_key = multiplexedConnRemoteKey,
    };
    payload.provider_entry = .{
        .profile = &payload.provider_profile,
        .execution_model = c.transport_provider.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED,
        .implementation = &payload.multiplexed_transport,
    };
    payload.provider_initialized = true;
}

/// Fill the generic driver provider package for externally established WebRTC
/// peers. The package has no dial or listener operation: signaling owns those
/// actions, and the driver claims only an authorized open subject.
pub export fn pancake_webrtc_transport_provider(
    netlayer: ?*PancakeWebrtcNetlayer,
    out_provider: ?*c.PancakeTransportProvider,
) i32 {
    const payload = netlayerFromOpaque(netlayer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_provider orelse return PANCAKE_ERR_NULL_POINTER;
    ensureProvider(payload);
    slot.* = .{
        .abi_version = c.transport_provider.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION,
        .struct_size = @sizeOf(c.PancakeTransportProvider),
        .entries = @ptrCast(&payload.provider_entry),
        .entry_count = 1,
        .lease_ctx = payload,
        .same_configuration = providerSameConfiguration,
        .retain = providerRetain,
        .release = providerRelease,
    };
    return PANCAKE_OK;
}

/// Record `msg` in the last-error slot and return `PANCAKE_ERR_IO`, the one
/// fault code every sidecar refusal maps to.
fn ioError(msg: []const u8) i32 {
    setLastError("{s}", .{msg});
    return PANCAKE_ERR_IO;
}
