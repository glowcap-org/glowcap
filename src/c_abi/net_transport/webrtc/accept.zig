//! The managed WebRTC accept: the dial's mirror (ADR-0232).
//!
//! A netlayer whose signaling carries `send_answer` fills the multiplexed
//! provider's listen verbs. `listen` is ready at once and records the
//! designator the listener is reachable as, which `listener_locator` projects
//! as a `webrtc` locator. The application hands each inbound offer in with
//! `glowcap_webrtc_netlayer_provide_offer`, naming the offerer's designator.
//! The provider creates the answerer, authorizes that designator as the
//! channel's remote key (ADR-0105), sets the offer, produces the answer, and
//! sends it through `send_answer` under an exchange id it mints. Later
//! candidates flow under that id through `provide_candidate` and
//! `send_candidate` (`exchange.zig`). When the channel opens the listener's
//! accept record fires, `finish_accept` claims the peer as a connection, and
//! `stop_listen` closes every accept still in flight.
//!
//! `provide_offer` belongs on the thread that steps the driver, like every
//! other `provide_*` call.

const std = @import("std");

const crypto = @import("foundation").crypto;
const c = @import("c_abi_shared");
const webrtc = @import("webrtc");
const ownership = @import("ownership.zig");
const exchange = @import("exchange.zig");
const peer_signaling = @import("peer_signaling.zig");

const NetlayerPayload = ownership.NetlayerPayload;
const PeerPayload = ownership.PeerPayload;
const GlowcapWebrtcNetlayer = ownership.GlowcapWebrtcNetlayer;
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

/// The bit every accept exchange id carries and no driver request id does.
/// The driver mints request ids by counting from one.
pub const accept_id_bit: u64 = 1 << 63;

/// The multiplexed provider's `listen`. Ready at once: reachability is the
/// signaling the application carries, not a socket. The listener is named
/// by the requested designator, or by the Host's identity designator when
/// none is requested, and both must name the same key when both are given.
pub fn listen(
    ctx: ?*anyopaque,
    route_id: u64,
    transport: ?[*]const u8,
    transport_len: usize,
    requested_designator: ?[*]const u8,
    requested_designator_len: usize,
    identity_designator: ?[*]const u8,
    identity_designator_len: usize,
    options: ?*const c.GlowcapTransportOperationOptions,
    out_result: ?*c.GlowcapListenResult,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(ctx.?));
    if (!c.transport_provider.operationOptionsAreInherited(options))
        return failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidOptions);
    const result = out_result orelse return failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const transport_ptr = transport orelse return failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    if (!std.mem.eql(u8, transport_ptr[0..transport_len], webrtc.transport_name))
        return failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.UnknownTransport);
    if (payload.listener != null)
        return failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.AlreadyListening);
    const requested: []const u8 = if (requested_designator) |ptr| ptr[0..requested_designator_len] else &.{};
    const identity: []const u8 = if (identity_designator) |ptr| ptr[0..identity_designator_len] else &.{};
    const designator = if (requested.len != 0) requested else identity;
    if (crypto.PeerKey.fromDesignator(designator) == null)
        return failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    if (requested.len != 0 and identity.len != 0 and !std.mem.eql(u8, requested, identity))
        return failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    var ready: std.ArrayListUnmanaged(*PeerPayload) = .empty;
    ready.ensureTotalCapacity(payload.allocator, webrtc.max_accepts_in_flight) catch |err|
        return failProvider(out_failure, GLOWCAP_ERR_INTERNAL, err);
    payload.listener = .{
        .route_id = route_id,
        .designator = designator[0..crypto.PeerKey.designator_len].*,
        .ready = ready,
    };
    result.* = .{
        .state = c.GLOWCAP_LISTEN_READY,
        .listener = payload,
        .attempt = null,
        .readiness_fd = -1,
    };
    return GLOWCAP_OK;
}

fn listenerOf(listener_ctx: ?*anyopaque) ?*ownership.Listener {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(listener_ctx orelse return null));
    return if (payload.listener) |*listener| listener else null;
}

/// The multiplexed provider's `listener_locator`: the `webrtc` locator for
/// the designator the listener recorded.
pub fn listenerLocator(
    listener_ctx: ?*anyopaque,
    sink_ctx: ?*anyopaque,
    sink: c.GlowcapLocatorSinkFn,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(listener_ctx.?));
    const listener = listenerOf(listener_ctx) orelse
        return failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.NotListening);
    var hint_stack: [c.locator_adapter.inline_hint_capacity]c.GlowcapLocatorHintView = undefined;
    var projection = c.locator_adapter.Projection.init(
        payload.allocator,
        webrtc.locator(&listener.designator),
        &hint_stack,
    ) catch |err| return failProvider(out_failure, c.locatorAdapterErrorCode(err), err);
    defer projection.deinit(payload.allocator);
    return sink(sink_ctx, &projection.view);
}

/// The multiplexed provider's `listener_advertise`. A WebRTC peer is reachable
/// only as its key, so the one locator a listener may advertise is its own.
pub fn listenerAdvertise(
    listener_ctx: ?*anyopaque,
    locator_view: ?*const c.GlowcapLocatorView,
    sink_ctx: ?*anyopaque,
    sink: c.GlowcapLocatorSinkFn,
    out_failure: ?*c.GlowcapProviderFailure,
) callconv(.c) i32 {
    const listener = listenerOf(listener_ctx) orelse
        return failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.NotListening);
    const view = locator_view orelse return failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const transport_ptr = view.transport orelse return failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const designator_ptr = view.designator orelse return failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    if (!std.mem.eql(u8, transport_ptr[0..view.transport_len], webrtc.transport_name) or
        !std.mem.eql(u8, designator_ptr[0..view.designator_len], &listener.designator))
        return failProvider(out_failure, GLOWCAP_ERR_INVALID_ARGUMENT, error.InvalidAddress);
    return sink(sink_ctx, view);
}

/// The multiplexed provider's `finish_accept`: the oldest opened accept
/// becomes a claimed connection whose id is the peer id, and its exchange is
/// over. `GLOWCAP_ERR_WOULD_BLOCK` when none has opened.
pub fn finishAccept(listener_ctx: ?*anyopaque, out_conn: ?*u64, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(listener_ctx.?));
    const slot = out_conn orelse return failProvider(out_failure, GLOWCAP_ERR_NULL_POINTER, error.NullPointer);
    const listener = listenerOf(listener_ctx) orelse return GLOWCAP_ERR_WOULD_BLOCK;
    if (listener.ready.items.len == 0) return GLOWCAP_ERR_WOULD_BLOCK;
    const peer = listener.ready.orderedRemove(0);
    const id = peer.exchange.?.id;
    std.debug.assert(payload.exchanges.remove(id));
    peer.exchange = null;
    // The driver's connection is the peer's one reference: no handle was
    // ever handed out, so `conn_close` frees it.
    peer.provider_claimed = true;
    slot.* = @backingInt(peer.peer.id());
    if (payload.signaling.done) |done| done(payload.signaling.ctx, id);
    return GLOWCAP_OK;
}

/// The multiplexed provider's `stop_listen`. Every accept still in flight,
/// opened or not, closes with `done`. Idempotent.
pub fn stopListen(listener_ctx: ?*anyopaque, out_failure: ?*c.GlowcapProviderFailure) callconv(.c) i32 {
    const payload: *NetlayerPayload = @ptrCast(@alignCast(listener_ctx.?));
    var listener = payload.listener orelse return GLOWCAP_OK;
    payload.listener = null;
    listener.ready.deinit(payload.allocator);
    var failure: ?anyerror = null;
    while (firstAccept(payload)) |peer| {
        if (retire(payload, peer, .announced)) |err| failure = failure orelse err;
    }
    if (failure) |err| return failProvider(out_failure, GLOWCAP_ERR_IO, err);
    return GLOWCAP_OK;
}

fn firstAccept(payload: *NetlayerPayload) ?*PeerPayload {
    var it = payload.exchanges.valueIterator();
    while (it.next()) |peer| if (peer.*.exchange.?.role == .accept) return peer.*;
    return null;
}

/// Answer an inbound offer from the peer `designator` names. Call it on the
/// thread that steps the driver, while a `webrtc` listener is active. The
/// netlayer creates the answerer, authorizes `designator` as the channel's
/// remote key, sets the offer, and hands the answer to `send_answer` under
/// the exchange id written to `out_exchange`: route the offerer's later
/// candidates to it with `glowcap_webrtc_netlayer_provide_candidate`, and
/// expect `send_candidate` under it. The channel opening is the listener's
/// accept, and `done` fires once the driver has claimed it or the exchange
/// has ended. Every refusal has no effect: `GLOWCAP_ERR_CLOSED` when no
/// listener is active, `GLOWCAP_ERR_INVALID_ARGUMENT` when `designator` names
/// no key, `GLOWCAP_ERR_WOULD_BLOCK` while the most accepts the netlayer holds
/// are already signaling, and `GLOWCAP_ERR_IO` when the WebRTC library refuses
/// the offer or `send_answer` refuses the answer. Every exchange has its own
/// id, so an offer from a peer this netlayer is also dialing runs beside that
/// dial, and CapTP's crossed-hellos rule keeps one of the two sessions.
pub export fn glowcap_webrtc_netlayer_provide_offer(
    netlayer: ?*GlowcapWebrtcNetlayer,
    designator: ?[*]const u8,
    designator_len: usize,
    sdp: ?[*]const u8,
    sdp_len: usize,
    out_exchange: ?*u64,
) i32 {
    c.lastErrorClear();
    const payload = ownership.netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_exchange orelse return GLOWCAP_ERR_NULL_POINTER;
    if (payload.listener == null) {
        setLastError("webrtc provide_offer: no listener is active", .{});
        return GLOWCAP_ERR_CLOSED;
    }
    const designator_bytes = c.sliceFromC(designator, designator_len) catch |err| return c.marshalErrorToCode(err);
    const key = crypto.PeerKey.fromDesignator(designator_bytes) orelse {
        setLastError("webrtc provide_offer: the offerer designator names no key", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    const offer = peer_signaling.signalInput(sdp, sdp_len) catch |err| return peer_signaling.signalInputError(err, "provide_offer", "SDP offer");
    if (acceptsInFlight(payload) >= webrtc.max_accepts_in_flight) {
        setLastError("webrtc provide_offer: {d} accepts are already in flight", .{webrtc.max_accepts_in_flight});
        return GLOWCAP_ERR_WOULD_BLOCK;
    }
    payload.exchanges.ensureUnusedCapacity(payload.allocator, 1) catch |err|
        return c.failInternal("webrtc provide_offer", err);

    const peer = ownership.createPeer(payload.allocator, payload, false) catch |err| return switch (err) {
        error.NetlayerReleased => GLOWCAP_ERR_CLOSED,
        error.OutOfMemory => c.failInternal("webrtc provide_offer", err),
        error.PeerCreateFailed => peer_signaling.ioError("provide_offer: the WebRTC library could not create the answerer"),
    };
    peer.peer.authorizeRemote(key);
    const id = accept_id_bit | payload.next_accept;
    payload.next_accept += 1;
    peer.exchange = .{ .id = id, .role = .accept };
    payload.exchanges.putAssumeCapacity(id, peer);

    // The provider lease pins the netlayer, so each release below frees the
    // peer alone and cannot fail.
    peer.peer.setRemoteOffer(offer) catch |err| {
        std.debug.assert(retire(payload, peer, .silent) == null);
        return switch (err) {
            error.SignalTooLarge => peer_signaling.signalOutputTooLarge("provide_offer", "SDP offer"),
            else => peer_signaling.ioError("provide_offer: the WebRTC library refused the offer"),
        };
    };
    var answer_buf: [webrtc.max_signal_bytes]u8 = undefined;
    var answer_len: usize = 0;
    const answer = peer.peer.createAnswer(&answer_buf, &answer_len) catch {
        std.debug.assert(retire(payload, peer, .silent) == null);
        return peer_signaling.ioError("provide_offer: the WebRTC library produced no answer");
    };
    const signaling = payload.signaling;
    if (signaling.send_answer.?(signaling.ctx, id, designator_bytes.ptr, designator_bytes.len, answer.ptr, answer.len) != 0) {
        std.debug.assert(retire(payload, peer, .silent) == null);
        return peer_signaling.ioError("provide_offer: signaling refused the answer");
    }
    slot.* = id;
    return GLOWCAP_OK;
}

fn acceptsInFlight(payload: *NetlayerPayload) usize {
    var count: usize = 0;
    var it = payload.exchanges.valueIterator();
    while (it.next()) |peer| count += @intFromBool(peer.*.exchange.?.role == .accept);
    return count;
}
