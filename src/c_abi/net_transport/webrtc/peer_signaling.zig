//! The hand-driven signaling exports of one WebRTC peer: authorize the far
//! key, produce an offer or answer, take the far description and candidates,
//! and drain local candidates. An application that carries its own signaling
//! calls these and then hands the open peer to the driver with
//! `claim_external`. The managed dial in `dial.zig` runs the same steps on
//! the driver's behalf and shares the input bounds declared here.

const c = @import("c_abi_shared");
const crypto = @import("foundation").crypto;
const webrtc = @import("webrtc");
const ownership = @import("ownership.zig");

const GlowcapWebrtcPeer = ownership.GlowcapWebrtcPeer;
const payloadFromOpaque = ownership.payloadFromOpaque;
const setLastError = c.setLastError;
const GLOWCAP_OK = c.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = c.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = c.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_BUFFER_TOO_SMALL = c.GLOWCAP_ERR_BUFFER_TOO_SMALL;
const GLOWCAP_ERR_WOULD_BLOCK = c.GLOWCAP_ERR_WOULD_BLOCK;
const GLOWCAP_ERR_CLOSED = c.GLOWCAP_ERR_CLOSED;
const GLOWCAP_ERR_IO = c.GLOWCAP_ERR_IO;

/// Record `msg` in the last-error slot and return `GLOWCAP_ERR_IO`, the one
/// fault code every sidecar refusal maps to.
pub fn ioError(msg: []const u8) i32 {
    setLastError("{s}", .{msg});
    return GLOWCAP_ERR_IO;
}

/// Bind the durable key authorized by the signaling authority. Authorization
/// is a pre-open fact: after the channel opens, changing it would make the
/// provider's transport provenance mutable while the driver owns the wire.
pub export fn glowcap_webrtc_peer_authorize_remote(
    peer: ?*GlowcapWebrtcPeer,
    designator: ?[*]const u8,
    designator_len: usize,
) i32 {
    c.lastErrorClear();
    const payload = payloadFromOpaque(peer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const bytes = keyDesignatorInput(designator, designator_len) catch |err| return keyDesignatorInputError(err);
    const key = crypto.PeerKey.fromDesignator(bytes) orelse {
        setLastError("webrtc authorize_remote: invalid durable key designator", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    if (payload.peer.authorized_remote != null) {
        setLastError("webrtc authorize_remote: remote identity is already authorized", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    if (payload.peer.checkOpen()) |_| {
        setLastError("webrtc authorize_remote: the channel is already open", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    } else |err| switch (err) {
        error.WouldBlock => {},
        error.Closed => return GLOWCAP_ERR_CLOSED,
        error.Failed => return ioError("authorize_remote: the channel faulted"),
    }
    payload.peer.authorizeRemote(key);
    return GLOWCAP_OK;
}

fn keyDesignatorInput(ptr: ?[*]const u8, len: usize) error{ NullPointer, InvalidArgument }![]const u8 {
    if (len != crypto.PeerKey.designator_len) return error.InvalidArgument;
    const src = ptr orelse return error.NullPointer;
    return src[0..crypto.PeerKey.designator_len];
}

fn keyDesignatorInputError(err: error{ NullPointer, InvalidArgument }) i32 {
    return switch (err) {
        error.NullPointer => GLOWCAP_ERR_NULL_POINTER,
        error.InvalidArgument => {
            setLastError("webrtc authorize_remote: remote identity must be a {d}-byte lowercase hex designator", .{crypto.PeerKey.designator_len});
            return GLOWCAP_ERR_INVALID_ARGUMENT;
        },
    };
}

/// Produce the offerer's SDP offer into `(out, cap)`, writing its length to
/// `*out_len`. `GLOWCAP_ERR_BUFFER_TOO_SMALL` still writes the required length,
/// so the caller retries with a buffer that size. `GLOWCAP_ERR_INVALID_ARGUMENT`
/// means the generated SDP exceeds `GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES`. Offerer
/// only.
pub export fn glowcap_webrtc_peer_create_offer(peer: ?*GlowcapWebrtcPeer, out: ?[*]u8, cap: usize, out_len: ?*usize) i32 {
    c.lastErrorClear();
    return produceSdp(peer, out, cap, out_len, .offer);
}

/// Produce the answerer's SDP answer into `(out, cap)`, writing its length to
/// `*out_len`. `GLOWCAP_ERR_INVALID_ARGUMENT` means the generated SDP exceeds
/// `GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES`. Answerer only, after
/// `glowcap_webrtc_peer_set_remote_offer`.
pub export fn glowcap_webrtc_peer_create_answer(peer: ?*GlowcapWebrtcPeer, out: ?[*]u8, cap: usize, out_len: ?*usize) i32 {
    c.lastErrorClear();
    return produceSdp(peer, out, cap, out_len, .answer);
}

const SdpKind = enum { offer, answer };

fn produceSdp(peer: ?*GlowcapWebrtcPeer, out: ?[*]u8, cap: usize, out_len: ?*usize, kind: SdpKind) i32 {
    const payload = payloadFromOpaque(peer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const dest = out orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_len orelse return GLOWCAP_ERR_NULL_POINTER;
    const result = switch (kind) {
        .offer => payload.peer.createOffer(dest[0..cap], slot),
        .answer => payload.peer.createAnswer(dest[0..cap], slot),
    };
    _ = result catch |err| return switch (err) {
        error.BufferTooSmall => GLOWCAP_ERR_BUFFER_TOO_SMALL,
        error.SignalTooLarge => signalOutputTooLarge("create_offer/answer", "generated SDP"),
        error.SignalFailed => ioError("create_offer/answer: the WebRTC library refused"),
    };
    return GLOWCAP_OK;
}

/// Set the far offerer's SDP offer as the remote description. Answerer side.
pub export fn glowcap_webrtc_peer_set_remote_offer(peer: ?*GlowcapWebrtcPeer, sdp: ?[*]const u8, sdp_len: usize) i32 {
    c.lastErrorClear();
    return setRemote(peer, sdp, sdp_len, true);
}

/// Set the far answerer's SDP answer as the remote description. Offerer side.
pub export fn glowcap_webrtc_peer_set_remote_answer(peer: ?*GlowcapWebrtcPeer, sdp: ?[*]const u8, sdp_len: usize) i32 {
    c.lastErrorClear();
    return setRemote(peer, sdp, sdp_len, false);
}

fn setRemote(peer: ?*GlowcapWebrtcPeer, sdp: ?[*]const u8, sdp_len: usize, is_offer: bool) i32 {
    const payload = payloadFromOpaque(peer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const bytes = signalInput(sdp, sdp_len) catch |err| return signalInputError(err, "set_remote", "SDP description");
    const result = if (is_offer) payload.peer.setRemoteOffer(bytes) else payload.peer.setRemoteAnswer(bytes);
    result catch |err| return switch (err) {
        error.SignalTooLarge => signalOutputTooLarge("set_remote", "SDP description"),
        else => ioError("set_remote: the WebRTC library refused the description"),
    };
    return GLOWCAP_OK;
}

/// Add one remote ICE candidate, as the JSON the far peer's
/// `glowcap_webrtc_peer_next_local_candidate` produced.
pub export fn glowcap_webrtc_peer_add_remote_candidate(peer: ?*GlowcapWebrtcPeer, cand: ?[*]const u8, cand_len: usize) i32 {
    c.lastErrorClear();
    const payload = payloadFromOpaque(peer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const bytes = candidateInput(cand, cand_len) catch |err| return candidateInputError(err, "add_remote_candidate", "ICE candidate");
    payload.peer.addRemoteCandidate(bytes) catch |err| return switch (err) {
        error.SignalTooLarge => candidateOutputTooLarge("add_remote_candidate", "ICE candidate"),
        else => ioError("add_remote_candidate: the WebRTC library refused the candidate"),
    };
    return GLOWCAP_OK;
}

pub const InputError = error{ NullPointer, SignalTooLarge };

/// Borrow one SDP description, refusing more than `GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES`.
pub fn signalInput(ptr: ?[*]const u8, len: usize) InputError![]const u8 {
    const src = ptr orelse return error.NullPointer;
    if (len > webrtc.max_signal_bytes) return error.SignalTooLarge;
    return src[0..len];
}

/// Borrow one ICE candidate, refusing more than `GLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES`.
pub fn candidateInput(ptr: ?[*]const u8, len: usize) InputError![]const u8 {
    const src = ptr orelse return error.NullPointer;
    if (len > webrtc.max_ice_candidate_bytes) return error.SignalTooLarge;
    return src[0..len];
}

pub fn signalInputError(err: InputError, operation: []const u8, label: []const u8) i32 {
    return switch (err) {
        error.NullPointer => GLOWCAP_ERR_NULL_POINTER,
        error.SignalTooLarge => signalOutputTooLarge(operation, label),
    };
}

pub fn candidateInputError(err: InputError, operation: []const u8, label: []const u8) i32 {
    return switch (err) {
        error.NullPointer => GLOWCAP_ERR_NULL_POINTER,
        error.SignalTooLarge => candidateOutputTooLarge(operation, label),
    };
}

/// Drain the next locally gathered ICE candidate into `(out, cap)` as JSON,
/// writing its length to `*out_len`. `GLOWCAP_ERR_WOULD_BLOCK` when none is
/// pending yet. `GLOWCAP_ERR_BUFFER_TOO_SMALL` still writes the required length. status-allow: pending state or quoted runtime label
/// `GLOWCAP_ERR_INVALID_ARGUMENT` means the candidate exceeds
/// `GLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES`.
pub export fn glowcap_webrtc_peer_next_local_candidate(peer: ?*GlowcapWebrtcPeer, out: ?[*]u8, cap: usize, out_len: ?*usize) i32 {
    c.lastErrorClear();
    const payload = payloadFromOpaque(peer) orelse return GLOWCAP_ERR_NULL_POINTER;
    const dest = out orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_len orelse return GLOWCAP_ERR_NULL_POINTER;
    const candidate = payload.peer.nextLocalCandidate(dest[0..cap], slot) catch |err| return switch (err) {
        error.BufferTooSmall => GLOWCAP_ERR_BUFFER_TOO_SMALL,
        error.SignalTooLarge => candidateOutputTooLarge("next_local_candidate", "local ICE candidate"),
        error.SignalFailed => ioError("next_local_candidate: the WebRTC library refused"),
    };
    return if (candidate == null) GLOWCAP_ERR_WOULD_BLOCK else GLOWCAP_OK;
}

pub fn signalOutputTooLarge(operation: []const u8, label: []const u8) i32 {
    setLastError("webrtc {s}: {s} exceeds GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES", .{ operation, label });
    return GLOWCAP_ERR_INVALID_ARGUMENT;
}

pub fn candidateOutputTooLarge(operation: []const u8, label: []const u8) i32 {
    setLastError("webrtc {s}: {s} exceeds GLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES", .{ operation, label });
    return GLOWCAP_ERR_INVALID_ARGUMENT;
}
