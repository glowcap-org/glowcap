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
//! `connect(addr)`. The caller drives an out-of-band signaling exchange first:
//! the offerer produces an SDP offer, the answerer an SDP answer, and both
//! trickle ICE candidates until the channel opens (`pancake_webrtc_peer_wait_open`).
//! Then `pancake_webrtc_peer_read` / `_write` move raw session bytes, which the
//! host frames itself (feed them to its peer's stream-input path), the same
//! shape the iroh and TCP consumers use. Phase 2 carries the signaling strings
//! through the caller; a later phase routes them through an OCapN capability.
//!
//! Symbol names deliberately avoid the sidecar's own `pancake_webrtc_sidecar_*`
//! exports, so the private byte-level seam and this public ABI share no prefix
//! and link into one library without colliding.
//!
//! Threading: a `PancakeWebrtcPeer` is single-owner — serialize every call on
//! one onto one thread. `pancake_webrtc_peer_read` blocks the calling thread
//! until bytes arrive or the channel closes, so a host that must not park runs
//! it on a thread of its own.

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

fn payloadFromOpaque(p: ?*PancakeWebrtcPeer) ?*PeerPayload {
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

/// Create a peer in one of the two signaling roles: `is_offerer` nonzero makes
/// the offerer (which creates the data channel and produces the SDP offer),
/// zero the answerer (which receives the channel and produces the answer). The
/// handle is written to `*out_peer`; the caller frees it with
/// `pancake_webrtc_peer_release`.
pub export fn pancake_webrtc_peer_new(is_offerer: i32, out_peer: ?*?*PancakeWebrtcPeer) i32 {
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    return peerNewIn(c.library_allocator, is_offerer, slot);
}

/// As `pancake_webrtc_peer_new`, but the handle allocates through `context`'s
/// allocator instead of the library allocator. Released the same way, with
/// `pancake_webrtc_peer_release`.
pub export fn pancake_webrtc_peer_new_in(context: ?*PancakeContext, is_offerer: i32, out_peer: ?*?*PancakeWebrtcPeer) i32 {
    const c_ctx = c.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    return peerNewIn(c_ctx.allocator(), is_offerer, slot);
}

fn peerNewIn(alloc: std.mem.Allocator, is_offerer: i32, slot: *?*PancakeWebrtcPeer) i32 {
    const payload = alloc.create(PeerPayload) catch return PANCAKE_ERR_INTERNAL;
    payload.* = .{
        .peer = webrtc.Peer.init(is_offerer != 0) catch {
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

/// Block until the data channel opens, or `timeout_ms` elapses. `PANCAKE_OK`
/// once open, `PANCAKE_ERR_WOULD_BLOCK` on timeout.
pub export fn pancake_webrtc_peer_wait_open(peer: ?*PancakeWebrtcPeer, timeout_ms: u64) i32 {
    const payload = payloadFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    return if (payload.peer.waitOpen(timeout_ms)) PANCAKE_OK else PANCAKE_ERR_WOULD_BLOCK;
}

/// Blocking read of raw inbound session bytes into `(buf, len)`: `PANCAKE_OK`
/// with the count read written to `*out_read`, `PANCAKE_ERR_CLOSED` on a clean
/// end of stream, or `PANCAKE_ERR_IO` on a fault. `out_read` is untouched on any
/// non-OK return. The host frames these bytes itself.
pub export fn pancake_webrtc_peer_read(peer: ?*PancakeWebrtcPeer, buf: ?[*]u8, len: usize, out_read: ?*usize) i32 {
    const payload = payloadFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const dest = buf orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_read orelse return PANCAKE_ERR_NULL_POINTER;
    const n = payload.peer.read(dest[0..len]) catch |err| return switch (err) {
        error.Closed => PANCAKE_ERR_CLOSED,
        error.Failed => ioError("peer_read: the channel faulted"),
    };
    slot.* = n;
    return PANCAKE_OK;
}

/// Write `len` raw session bytes from `buf`: `PANCAKE_OK` with the count written
/// to `*out_written` (the whole slice, since the sidecar send is all-or-nothing),
/// or `PANCAKE_ERR_IO` on a fault. `out_written` is untouched on any non-OK
/// return.
pub export fn pancake_webrtc_peer_write(peer: ?*PancakeWebrtcPeer, buf: ?[*]const u8, len: usize, out_written: ?*usize) i32 {
    const payload = payloadFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const src = buf orelse return PANCAKE_ERR_NULL_POINTER;
    const n = payload.peer.write(src[0..len]) catch |err| return switch (err) {
        error.Failed => ioError("peer_write: the channel faulted"),
    };
    slot: {
        const slot = out_written orelse break :slot;
        slot.* = n;
    }
    return PANCAKE_OK;
}

/// Close the channel and connection without releasing the handle, waking any
/// parked reader with end of stream. Idempotent. The shutdown lever for a host
/// whose read parks on another thread; the handle is still released with
/// `pancake_webrtc_peer_release`.
pub export fn pancake_webrtc_peer_close(peer: ?*PancakeWebrtcPeer) void {
    const payload = payloadFromOpaque(peer) orelse return;
    payload.peer.close();
}

/// Release the peer, closing its channel and shutting down its runtime.
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
