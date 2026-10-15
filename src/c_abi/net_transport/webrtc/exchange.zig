//! One managed signaling exchange, in either direction (ADR-0226, ADR-0232).
//!
//! A dial's exchange is the driver's request id, and `dial.zig` runs it. An
//! accept's exchange is an id this netlayer mints, and `accept.zig` runs it.
//! Both are rows in `NetlayerPayload.exchanges`, and this file owns what they
//! share: the application's signaling callbacks, how a readiness record for an
//! exchanging peer becomes the driver's record, and the three calls the
//! application makes under an exchange id, `provide_answer`,
//! `provide_candidate`, and `fail_exchange`.
//!
//! Every callback runs on the thread that steps the driver, inside
//! `glowcap_driver_dial`, `glowcap_driver_step`, or
//! `glowcap_webrtc_netlayer_provide_offer`, and the `provide_*` and
//! `fail_exchange` calls belong on that thread too. A callback returns at
//! once: it hands the text to whatever carries signaling and never waits for
//! the reply.

const std = @import("std");

const c = @import("c_abi_shared");
const webrtc = @import("webrtc");
const ownership = @import("ownership.zig");
const peer_signaling = @import("peer_signaling.zig");

const NetlayerPayload = ownership.NetlayerPayload;
const PeerPayload = ownership.PeerPayload;
const GlowcapWebrtcNetlayer = ownership.GlowcapWebrtcNetlayer;
const setLastError = c.setLastError;
const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = c.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_CLOSED = c.GLOWCAP_ERR_CLOSED;
const GLOWCAP_ERR_IO = c.GLOWCAP_ERR_IO;

/// Carry one SDP offer to the peer `designator` names, for the dial
/// `exchange`. `introducer` is the designator of the session that handed over
/// the reference this dial follows, so the application can carry the offer
/// through the party that knows the peer. It is null with a zero length for a
/// dial the application started itself or whose introducing session signed no
/// designator. The far peer's answer comes back through
/// `glowcap_webrtc_netlayer_provide_answer`. Return 0 to accept. Any other
/// value refuses the dial, which fails with `GLOWCAP_ERR_IO`.
pub const GlowcapWebrtcSendOfferFn = *const fn (
    ctx: ?*anyopaque,
    exchange: u64,
    designator: ?[*]const u8,
    designator_len: usize,
    introducer: ?[*]const u8,
    introducer_len: usize,
    sdp: ?[*]const u8,
    sdp_len: usize,
) callconv(.c) i32;

/// Carry one SDP answer back to the offerer `designator` names, for the
/// accept `exchange` that `glowcap_webrtc_netlayer_provide_offer` returns.
/// Return 0 to accept. Any other value refuses the accept, which closes the
/// answerer before the offerer ever learns of it.
pub const GlowcapWebrtcSendAnswerFn = *const fn (
    ctx: ?*anyopaque,
    exchange: u64,
    designator: ?[*]const u8,
    designator_len: usize,
    sdp: ?[*]const u8,
    sdp_len: usize,
) callconv(.c) i32;

/// Carry one local ICE candidate, as JSON, to the peer the `exchange` is for.
/// Return 0 to accept. Any other value fails the exchange.
pub const GlowcapWebrtcSendCandidateFn = *const fn (
    ctx: ?*anyopaque,
    exchange: u64,
    ice: ?[*]const u8,
    ice_len: usize,
) callconv(.c) i32;

/// The `exchange` is over: it became a connection, failed, or was cancelled.
/// Nothing more arrives for it, and a `provide_*` call naming it is refused
/// from here on.
pub const GlowcapWebrtcExchangeDoneFn = *const fn (ctx: ?*anyopaque, exchange: u64) callconv(.c) void;

/// How the application carries signaling for the exchanges this netlayer runs.
/// `send_offer` lets it dial: the provider fills the connect verbs. `send_answer`
/// lets it accept: the provider fills the listen verbs. Either needs
/// `send_candidate`. All zero means the netlayer runs no exchange, and the
/// driver refuses a `webrtc` dial or listen as unsupported. `done` is optional.
/// `ctx` is passed back to every callback unread.
///
/// Each callback runs on the thread that steps the driver and returns at once.
/// `done` fires once for every exchange whose offer `send_offer` accepted and
/// once for every exchange `glowcap_webrtc_netlayer_provide_offer` returned.
pub const GlowcapWebrtcSignaling = extern struct {
    ctx: ?*anyopaque,
    send_offer: ?GlowcapWebrtcSendOfferFn,
    send_answer: ?GlowcapWebrtcSendAnswerFn,
    send_candidate: ?GlowcapWebrtcSendCandidateFn,
    done: ?GlowcapWebrtcExchangeDoneFn,
};

pub const ConfigError = error{HalfSignaling};

/// Reject a configuration that names an offer or answer callback without the
/// candidate callback, or the candidate callback alone.
pub fn validate(signaling: GlowcapWebrtcSignaling) ConfigError!void {
    const sends = signaling.send_offer != null or signaling.send_answer != null;
    if (sends != (signaling.send_candidate != null)) return error.HalfSignaling;
}

/// Whether this netlayer can run a dial.
pub fn dials(signaling: GlowcapWebrtcSignaling) bool {
    return signaling.send_offer != null;
}

/// Whether this netlayer can answer an offer.
pub fn accepts(signaling: GlowcapWebrtcSignaling) bool {
    return signaling.send_answer != null;
}

/// End an exchange: forget it, tell the application when it had learned of
/// the exchange, and release the peer. Returns the release outcome, which is
/// clean while the provider lease holds the netlayer.
pub fn retire(payload: *NetlayerPayload, peer: *PeerPayload, announce: bool) ?anyerror {
    const id = peer.exchange.?.id;
    std.debug.assert(payload.exchanges.remove(id));
    std.debug.assert(payload.peers.remove(@backingInt(peer.peer.id())));
    peer.exchange = null;
    if (announce) if (payload.signaling.done) |done| done(payload.signaling.ctx, id);
    return ownership.releasePeer(peer);
}

/// Route one readiness record for an exchanging peer, and return the record
/// the driver sees, if any. While signaling, candidates go out, and the
/// channel opening becomes the dial's connect record or the listener's accept
/// record. A dial that fails keeps its cause for `finish_connect`. An accept
/// that fails before opening ends here, with `done`, because the listener has
/// nothing to report for it. Once open, I/O readiness passes through under
/// the peer id until the driver claims the peer, so a hello the far peer
/// sends first is not lost.
pub fn routeEvent(payload: *NetlayerPayload, peer: *PeerPayload, events: u32) ?c.GlowcapMultiplexedReadyEvent {
    const exchange = &peer.exchange.?;
    switch (exchange.state) {
        .failed => return null,
        // The application gave up and the peer is closing. Its closed record
        // carries the failure `fail_exchange` stored, and nothing else counts.
        .refused => {
            if (events & webrtc.ev_closed == 0) return null;
            return failExchange(payload, peer, GLOWCAP_ERR_IO, error.SignalingFailed);
        },
        .open => {
            var mapped: u32 = 0;
            if (events & webrtc.ev_readable != 0) mapped |= c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_READABLE;
            if (events & webrtc.ev_writable != 0) mapped |= c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_WRITABLE;
            if (events & webrtc.ev_closed != 0) mapped |= c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_CLOSED;
            if (mapped == 0) return null;
            return .{ .subject = @backingInt(peer.peer.id()), .events = mapped };
        },
        .signaling => {},
    }
    if (events & webrtc.ev_candidate != 0) {
        pumpCandidates(payload, peer) catch |err| return failExchange(payload, peer, GLOWCAP_ERR_IO, err);
    }
    if (events & webrtc.ev_open != 0) {
        peer.peer.checkOpen() catch |err| return switch (err) {
            error.WouldBlock => null,
            error.Closed => failExchange(payload, peer, GLOWCAP_ERR_CLOSED, err),
            error.Failed => failExchange(payload, peer, GLOWCAP_ERR_IO, err),
        };
        exchange.state = .open;
        return switch (exchange.role) {
            .dial => .{ .subject = exchange.id, .events = c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_CONNECT },
            .accept => blk: {
                const listener = if (payload.listener) |*listener| listener else unreachable;
                listener.ready.appendAssumeCapacity(peer);
                break :blk .{ .subject = listener.route_id, .events = c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_ACCEPT };
            },
        };
    }
    if (events & webrtc.ev_closed != 0) return failExchange(payload, peer, GLOWCAP_ERR_CLOSED, error.Closed);
    return null;
}

/// A dial keeps its cause and reports a connect record for `finish_connect`.
/// An accept has no driver record to carry a cause, so it ends at once.
fn failExchange(payload: *NetlayerPayload, peer: *PeerPayload, code: i32, err: anyerror) ?c.GlowcapMultiplexedReadyEvent {
    const exchange = &peer.exchange.?;
    switch (exchange.role) {
        .dial => {
            exchange.state = .failed;
            if (c.transport_provider.providerFailureEmpty(peer.failure))
                c.transport_provider.setProviderFailure(&peer.failure, code, err);
            return .{ .subject = exchange.id, .events = c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_CONNECT };
        },
        .accept => {
            // The provider lease pins the netlayer, so this release frees the
            // peer alone and cannot fail.
            std.debug.assert(retire(payload, peer, true) == null);
            return null;
        },
    }
}

fn pumpCandidates(payload: *NetlayerPayload, peer: *PeerPayload) (webrtc.SignalError || error{SignalingRefused})!void {
    var buf: [webrtc.max_ice_candidate_bytes]u8 = undefined;
    var len: usize = 0;
    while (try peer.peer.nextLocalCandidate(&buf, &len)) |ice| {
        const signaling = payload.signaling;
        if (signaling.send_candidate.?(signaling.ctx, peer.exchange.?.id, ice.ptr, ice.len) != 0) return error.SignalingRefused;
    }
}

pub fn exchangePeer(payload: *NetlayerPayload, exchange: u64, operation: []const u8) ?*PeerPayload {
    return payload.exchanges.get(exchange) orelse {
        setLastError("webrtc {s}: no exchange {d} is in progress", .{ operation, exchange });
        return null;
    };
}

/// The `exchange` while it still takes signaling: one that was given up or
/// has failed is past it, and a late answer or candidate has no effect.
fn signalingPeer(payload: *NetlayerPayload, exchange: u64, operation: []const u8) ?*PeerPayload {
    const peer = exchangePeer(payload, exchange, operation) orelse return null;
    return switch (peer.exchange.?.state) {
        .signaling, .open => peer,
        .refused, .failed => {
            setLastError("webrtc {s}: exchange {d} is past signaling", .{ operation, exchange });
            return null;
        },
    };
}

/// Hand the far peer's SDP answer to the dial `exchange`. Call it on the
/// thread that steps the driver. `GLOWCAP_ERR_INVALID_ARGUMENT` with no
/// effect when no such dial is in progress, which a late answer after `done`
/// or after `fail_exchange` earns too, and when the exchange is an accept,
/// whose answer this netlayer produced itself.
pub export fn glowcap_webrtc_netlayer_provide_answer(
    netlayer: ?*GlowcapWebrtcNetlayer,
    exchange: u64,
    sdp: ?[*]const u8,
    sdp_len: usize,
) i32 {
    c.lastErrorClear();
    const payload = ownership.netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const peer = signalingPeer(payload, exchange, "provide_answer") orelse return GLOWCAP_ERR_INVALID_ARGUMENT;
    if (peer.exchange.?.role == .accept) {
        setLastError("webrtc provide_answer: exchange {d} is an accept, whose answer this netlayer sent", .{exchange});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    const bytes = peer_signaling.signalInput(sdp, sdp_len) catch |err| return peer_signaling.signalInputError(err, "provide_answer", "SDP answer");
    peer.peer.setRemoteAnswer(bytes) catch |err| return switch (err) {
        error.SignalTooLarge => peer_signaling.signalOutputTooLarge("provide_answer", "SDP answer"),
        else => peer_signaling.ioError("provide_answer: the WebRTC library refused the answer"),
    };
    return GLOWCAP_OK;
}

/// Give up on the `exchange` because the application's signaling failed: the
/// far peer is unreachable, refused, or the channel carrying the offer or
/// answer broke. A dial fails with `GLOWCAP_ERR_IO` and the cause
/// `SignalingFailed` at the driver's next step instead of waiting for its
/// handshake deadline. An accept ends quietly with `done`. The real error
/// stays with the application, which saw it first. Same thread as
/// `provide_answer`, and never from inside a signaling callback: a callback
/// that cannot carry its text returns nonzero instead.
/// `GLOWCAP_ERR_INVALID_ARGUMENT` with no effect when no such exchange is in
/// progress, or when its channel has already opened.
pub export fn glowcap_webrtc_netlayer_fail_exchange(netlayer: ?*GlowcapWebrtcNetlayer, exchange: u64) i32 {
    c.lastErrorClear();
    const payload = ownership.netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const peer = exchangePeer(payload, exchange, "fail_exchange") orelse return GLOWCAP_ERR_INVALID_ARGUMENT;
    switch (peer.exchange.?.state) {
        .signaling => {},
        .refused, .failed => return GLOWCAP_OK,
        .open => {
            setLastError("webrtc fail_exchange: exchange {d} has already opened its channel", .{exchange});
            return GLOWCAP_ERR_INVALID_ARGUMENT;
        },
    }
    peer.exchange.?.state = .refused;
    c.transport_provider.setProviderFailure(&peer.failure, GLOWCAP_ERR_IO, error.SignalingFailed);
    // Closing publishes the peer's closed record on the readiness fd, which
    // wakes the driver and ends the exchange in `routeEvent`.
    peer.peer.close();
    return GLOWCAP_OK;
}

/// Hand one of the far peer's ICE candidates, as the JSON it produced, to
/// the `exchange`. Same thread and same refusals as `provide_answer`, for a
/// dial or an accept. A candidate that arrives before the answer waits and
/// is added with it.
pub export fn glowcap_webrtc_netlayer_provide_candidate(
    netlayer: ?*GlowcapWebrtcNetlayer,
    exchange: u64,
    ice: ?[*]const u8,
    ice_len: usize,
) i32 {
    c.lastErrorClear();
    const payload = ownership.netlayerFromOpaque(netlayer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const peer = signalingPeer(payload, exchange, "provide_candidate") orelse return GLOWCAP_ERR_INVALID_ARGUMENT;
    const bytes = peer_signaling.candidateInput(ice, ice_len) catch |err| return peer_signaling.candidateInputError(err, "provide_candidate", "ICE candidate");
    peer.peer.addRemoteCandidate(bytes) catch |err| return switch (err) {
        error.SignalTooLarge => peer_signaling.candidateOutputTooLarge("provide_candidate", "ICE candidate"),
        else => peer_signaling.ioError("provide_candidate: the WebRTC library refused the candidate"),
    };
    return GLOWCAP_OK;
}
