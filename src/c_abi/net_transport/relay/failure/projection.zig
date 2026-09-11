//! Stable C result projection for relay-owned failure classifications.

const c = @import("c_abi_shared");
const net = @import("net");
const abi = c.transport_provider;

pub fn carrierPhase(phase: ?net.carrier_failure.Phase) u32 {
    const value = phase orelse return abi.GLOWCAP_CARRIER_PHASE_NONE;
    return abi.carrierPhaseCode(value);
}

pub fn failDial(
    out: ?*c.GlowcapProviderFailure,
    failure: net.netlayer.DialFailure,
) i32 {
    const code = dial(failure.classification);
    c.transport_provider.setProviderFailureChain(out, code, failure.chain, dial);
    if (out) |slot| {
        slot.carrier_phase = carrierPhase(failure.carrier_phase);
        slot.carrier_verification_flags = failure.carrier_detail.verification_flags;
        if (failure.carrier_detail.peer_alert) |alert| {
            slot.carrier_detail_flags |= abi.GLOWCAP_CARRIER_DETAIL_PEER_ALERT;
            slot.carrier_peer_alert = alert;
        }
        if (failure.carrier_detail.engine_code) |engine_code| {
            slot.carrier_detail_flags |= abi.GLOWCAP_CARRIER_DETAIL_ENGINE_CODE;
            slot.carrier_engine_code = engine_code;
        }
    }
    return code;
}

pub fn dial(cause: anyerror) i32 {
    return c.dialFailureCode(cause);
}

pub fn listen(cause: anyerror) i32 {
    return switch (cause) {
        error.InvalidAddress, error.InvalidOptions => c.GLOWCAP_ERR_INVALID_ARGUMENT,
        error.OutOfMemory => c.GLOWCAP_ERR_INTERNAL,
        else => c.GLOWCAP_ERR_IO,
    };
}

pub fn release(cause: anyerror) i32 {
    return switch (cause) {
        error.OutOfMemory => c.GLOWCAP_ERR_INTERNAL,
        error.Closed, error.Closing => c.GLOWCAP_ERR_CLOSED,
        else => c.GLOWCAP_ERR_IO,
    };
}
