//! The managed WebRTC dial: one signaling exchange the provider runs on the
//! driver's behalf (ADR-0226).
//!
//! `start_connect` creates the offerer, authorizes the dialed key, and hands
//! the offer to the application's `send_offer`. The application brings the
//! answer and the far peer's candidates back through
//! `glowcap_webrtc_netlayer_provide_answer` and `_provide_candidate`, naming
//! the exchange by the driver's request id, or gives up on it with
//! `glowcap_webrtc_netlayer_fail_exchange` (`exchange.zig`). Readiness records
//! for the dialing peer route through `exchange.routeEvent`: local candidates
//! go out through `send_candidate`, and the channel opening or failing becomes
//! the driver's connect record. `finish_connect` then claims the open peer as
//! a connection, and `cancel_connect` or a failure releases it.

const std = @import("std");

const crypto = @import("foundation").crypto;
const c = @import("c_abi_shared");
const webrtc = @import("webrtc");
const ownership = @import("ownership.zig");
const exchange = @import("exchange.zig");
const accept = @import("accept.zig");

const NetlayerPayload = ownership.NetlayerPayload;
const PeerPayload = ownership.PeerPayload;
const setLastError = c.setLastError;
const failProvider = c.transport_provider.failProvider;
const retire = exchange.retire;
const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = c.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_INTERNAL = c.GLOWCAP_ERR_INTERNAL;
const GLOWCAP_ERR_WOULD_BLOCK = c.GLOWCAP_ERR_WOULD_BLOCK;
const GLOWCAP_ERR_CLOSED = c.GLOWCAP_ERR_CLOSED;
const GLOWCAP_ERR_IO = c.GLOWCAP_ERR_IO;

/// The multiplexed provider's `start_connect`.
pub fn startConnect(
    ctx: ?*anyopaque,
    request_id: u64,
    locator_view: ?*const c.GlowcapLocatorView,
    options: ?*const c.GlowcapTransportOperationOptions,
    origin: ?*const c.GlowcapDialOrigin,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    if (!c.transport_provider.operationOptionsAreInherited(options))
        return failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidOptions);
    const view = locator_view orelse return failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const transport_ptr = view.transport orelse return failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    if (!std.mem.eql(u8, transport_ptr[0..view.transport_len], webrtc.transport_name))
        return failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.UnknownTransport);
    const designator_ptr = view.designator orelse return failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const designator = designator_ptr[0..view.designator_len];
    // The dialed designator is the key this channel is authorized to carry
    // (ADR-0105), so a locator that names no key dials nothing.
    const key = crypto.PeerKey.fromDesignator(designator) orelse
        return failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    // The high bit marks the ids this netlayer mints for accepts, so one
    // table and one `provide_candidate` serve both directions.
    if (request_id & accept.accept_id_bit != 0)
        return failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidRequestId);
    if (payload.exchanges.contains(request_id))
        return failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.DuplicateRequest);
    payload.exchanges.ensureUnusedCapacity(payload.allocator, 1) catch |err|
        return failProvider(out_failure, GLOWCAP_ERR_INTERNAL, err);

    const peer = ownership.createPeer(payload.allocator, payload, true) catch |err| return switch (err) {
        error.NetlayerReleased => failProvider(out_failure, GLOWCAP_ERR_CLOSED, err),
        error.OutOfMemory => failProvider(out_failure, GLOWCAP_ERR_INTERNAL, err),
        error.PeerCreateFailed => failProvider(out_failure, GLOWCAP_ERR_IO, err),
    };
    peer.peer.authorizeRemote(key);
    peer.exchange = .{ .id = request_id, .role = .dial };
    payload.exchanges.putAssumeCapacity(request_id, peer);

    var sdp_buf: [webrtc.max_signal_bytes]u8 = undefined;
    var sdp_len: usize = 0;
    const sdp = peer.peer.createOffer(&sdp_buf, &sdp_len) catch |err| {
        // The provider lease pins the netlayer, so this release frees the
        // peer alone and cannot fail.
        std.debug.assert(retire(payload, peer, .silent) == null);
        return failProvider(out_failure, GLOWCAP_ERR_IO, err);
    };
    const signaling = payload.signaling;
    const introducer = c.transport_provider.dialOriginIntroducer(origin);
    const introducer_ptr: ?[*]const u8 = if (introducer) |value| value.ptr else null;
    const introducer_len: usize = if (introducer) |value| value.len else 0;
    if (signaling.send_offer.?(
        signaling.ctx,
        request_id,
        designator.ptr,
        designator.len,
        introducer_ptr,
        introducer_len,
        sdp.ptr,
        sdp.len,
    ) != 0) {
        std.debug.assert(retire(payload, peer, .silent) == null);
        setLastError("webrtc dial: signaling refused the offer", .{});
        return failProvider(out_failure, GLOWCAP_ERR_IO, error.SignalingRefused);
    }
    return GLOWCAP_OK;
}

/// The dial the driver's `request_id` names, if one is in flight. A request
/// id never carries the accept bit, so an accept's row is never found here.
fn dialPeer(payload: *NetlayerPayload, request_id: u64) ?*PeerPayload {
    const peer = payload.exchanges.get(request_id) orelse return null;
    std.debug.assert(peer.exchange.?.role == .dial);
    return peer;
}

/// The multiplexed provider's `finish_connect`, called after the connect
/// record. An open exchange becomes a claimed connection whose id is the
/// peer id, the same subject `claim_external` uses. A failed one reports the
/// cause its readiness recorded. Either way the exchange is over.
pub fn finishConnect(
    ctx: ?*anyopaque,
    request_id: u64,
    out_conn: ?*u64,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const slot = out_conn orelse return failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const peer = dialPeer(payload, request_id) orelse
        return failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.UnknownExchange);
    switch (peer.exchange.?.state) {
        .failed, .refused => {
            const failure = peer.failure;
            std.debug.assert(retire(payload, peer, .announced) == null);
            if (out_failure) |out| out.* = failure;
            return failure.result;
        },
        .signaling => {
            std.debug.assert(retire(payload, peer, .announced) == null);
            return failProvider(out_failure, GLOWCAP_ERR_WOULD_BLOCK, error.WouldBlock);
        },
        .open => {
            std.debug.assert(payload.exchanges.remove(request_id));
            peer.exchange = null;
            // The driver's connection is the peer's one reference: no handle
            // was ever handed out, so `conn_close` frees it.
            peer.provider_claimed = true;
            slot.* = @backingInt(peer.peer.id());
            if (payload.signaling.done) |done| done(payload.signaling.ctx, request_id);
            return GLOWCAP_OK;
        },
    }
}

/// The multiplexed provider's `cancel_connect`. Idempotent: a request that
/// is not dialing is already gone.
pub fn cancelConnect(ctx: ?*anyopaque, request_id: u64, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    const peer = dialPeer(payload, request_id) orelse return GLOWCAP_OK;
    if (retire(payload, peer, .announced)) |err| return failProvider(out_failure, GLOWCAP_ERR_IO, err);
    return GLOWCAP_OK;
}
