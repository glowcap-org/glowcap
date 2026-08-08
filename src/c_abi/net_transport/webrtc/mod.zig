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
};

const NetlayerPayload = struct {
    resident: webrtc.Resident,
    allocator: std.mem.Allocator,
};

fn payloadFromOpaque(p: ?*PancakeWebrtcPeer) ?*PeerPayload {
    return @ptrCast(@alignCast(p orelse return null));
}

fn netlayerFromOpaque(p: ?*PancakeWebrtcNetlayer) ?*NetlayerPayload {
    return @ptrCast(@alignCast(p orelse return null));
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
    const ice_servers = c.sliceFromC(cfg.ice_servers, cfg.ice_servers_len) catch
        return PANCAKE_ERR_INVALID_ARGUMENT;
    const payload = alloc.create(NetlayerPayload) catch return PANCAKE_ERR_INTERNAL;
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
    if (out_cap == 0) return PANCAKE_ERR_INVALID_ARGUMENT;

    var raw: [128]webrtc.ReadyEvent = undefined;
    var count: usize = 0;
    while (count < out_cap) {
        const want = @min(out_cap - count, raw.len);
        const n = payload.resident.drainReady(raw[0..want]) catch return PANCAKE_ERR_INTERNAL;
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
pub export fn pancake_webrtc_netlayer_release(netlayer: ?*PancakeWebrtcNetlayer) void {
    const payload = netlayerFromOpaque(netlayer) orelse return;
    const alloc = payload.allocator;
    payload.resident.deinit();
    alloc.destroy(payload);
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
    const payload = alloc.create(PeerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.* = .{
        .peer = nl.resident.newPeer(is_offerer != 0) catch {
            alloc.destroy(payload);
            setLastError("webrtc peer_new: the sidecar could not create a peer connection", .{});
            return PANCAKE_ERR_IO;
        },
        .allocator = alloc,
    };
    slot.* = @ptrCast(payload);
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

/// Copy a prefix into the bounded send queue and return immediately. Advance by
/// `out_written`; after `PANCAKE_ERR_WOULD_BLOCK`, retry the remaining slice on
/// WRITABLE readiness.
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

/// Release the peer, closing its channel. Release before its netlayer.
pub export fn pancake_webrtc_peer_release(peer: ?*PancakeWebrtcPeer) void {
    const payload = payloadFromOpaque(peer) orelse return;
    const alloc = payload.allocator;
    payload.peer.deinit();
    alloc.destroy(payload);
}

/// Record `msg` in the last-error slot and return `PANCAKE_ERR_IO`, the one
/// fault code every sidecar refusal maps to.
fn ioError(msg: []const u8) i32 {
    setLastError("{s}", .{msg});
    return PANCAKE_ERR_IO;
}
