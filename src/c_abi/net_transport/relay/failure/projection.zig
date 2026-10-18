//! Stable C result projection for relay-owned failures. Dial, listen, and
//! accept codes come from the shared netlayer table (`c.netlayerFailureCode`);
//! this file adds the relay's carrier detail to a dial report and names the
//! codes of a release.

const c = @import("c_abi_shared");
const net = @import("net");
const abi = c.transport_provider;

pub fn failDial(
    out: ?*c.GlowcapProviderFailure,
    failure: net.netlayer.DialFailure,
) i32 {
    const code = c.netlayerFailureCode(failure.classification);
    abi.setProviderFailureChain(out, code, failure.chain, c.netlayerFailureCode);
    if (out) |slot| {
        slot.carrier_phase = abi.optionalCarrierPhaseCode(failure.carrier_phase);
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

pub fn release(cause: anyerror) i32 {
    return switch (cause) {
        error.OutOfMemory => c.GLOWCAP_ERR_INTERNAL,
        error.Closed, error.Closing => c.GLOWCAP_ERR_CLOSED,
        else => c.GLOWCAP_ERR_IO,
    };
}
