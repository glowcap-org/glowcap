//! One stable C projection of the neutral native carrier failure phase.

const net = @import("net");
const shared = @import("c_abi_shared");
const abi = shared.transport_provider;

pub const DecodeError = error{InvalidCarrierPhase};

pub const Projection = struct {
    phase: u32 = abi.GLOWCAP_CARRIER_PHASE_NONE,
    detail_flags: u32 = 0,
    verification_flags: u32 = 0,
    peer_alert: u32 = 0,
    engine_code: i32 = 0,
};

pub fn encode(phase: ?net.carrier_failure.Phase) u32 {
    const value = phase orelse return abi.GLOWCAP_CARRIER_PHASE_NONE;
    return abi.carrierPhaseCode(value);
}

pub fn decode(value: u32) DecodeError!?net.carrier_failure.Phase {
    return switch (value) {
        abi.GLOWCAP_CARRIER_PHASE_NONE => null,
        abi.GLOWCAP_CARRIER_PHASE_RESOLVE => .resolve,
        abi.GLOWCAP_CARRIER_PHASE_CONNECT => .connect,
        abi.GLOWCAP_CARRIER_PHASE_SECURE_HANDSHAKE => .secure_handshake,
        abi.GLOWCAP_CARRIER_PHASE_WEBSOCKET_UPGRADE => .websocket_upgrade,
        abi.GLOWCAP_CARRIER_PHASE_REGISTRATION => .registration,
        abi.GLOWCAP_CARRIER_PHASE_RECEIVE => .receive,
        abi.GLOWCAP_CARRIER_PHASE_TRANSMIT => .transmit,
        abi.GLOWCAP_CARRIER_PHASE_SHUTDOWN => .shutdown,
        else => error.InvalidCarrierPhase,
    };
}

pub fn project(
    phase: ?net.carrier_failure.Phase,
    detail: net.carrier_failure.Detail,
) Projection {
    if (phase == null) return .{};
    var projected: Projection = .{
        .phase = encode(phase),
        .verification_flags = detail.verification_flags,
    };
    if (detail.peer_alert) |alert| {
        projected.detail_flags |= abi.GLOWCAP_CARRIER_DETAIL_PEER_ALERT;
        projected.peer_alert = alert;
    }
    if (detail.engine_code) |code| {
        projected.detail_flags |= abi.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE;
        projected.engine_code = code;
    }
    return projected;
}

pub fn decodeDetail(
    phase: ?net.carrier_failure.Phase,
    flags: u32,
    verification_flags: u32,
    peer_alert: u32,
    engine_code: i32,
) DecodeError!net.carrier_failure.Detail {
    const known = abi.GLOWCAP_CARRIER_DETAIL_PEER_ALERT |
        abi.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE;
    if (flags & ~known != 0 or
        (phase == null and (flags != 0 or verification_flags != 0 or
            peer_alert != 0 or engine_code != 0)) or
        (flags & abi.GLOWCAP_CARRIER_DETAIL_PEER_ALERT == 0 and peer_alert != 0) or
        (flags & abi.GLOWCAP_CARRIER_DETAIL_PEER_ALERT != 0 and peer_alert > 255) or
        (flags & abi.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE == 0 and engine_code != 0))
        return error.InvalidCarrierPhase;
    return .{
        .verification_flags = verification_flags,
        .peer_alert = if (flags & abi.GLOWCAP_CARRIER_DETAIL_PEER_ALERT != 0)
            @intCast(peer_alert)
        else
            null,
        .engine_code = if (flags & abi.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE != 0)
            engine_code
        else
            null,
    };
}
