//! `pairedWithOffers`: build two live peers from two negotiation offers,
//! refusing offers that share no codec, profile, or CapTP version, the
//! factory every pairing scenario family drives.

const std = @import("std");
const glowcap = @import("glowcap");

const foundation = glowcap.foundation;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const session = glowcap.ocapn.session;
const codec = glowcap.ocapn.codec;
const pairing = engine.pairing;
const handshake = @import("../../support/handshake.zig");

const crypto = foundation.crypto;

pub fn offersShareCaptpVersion(local: engine.negotiation.Offer, remote: engine.negotiation.Offer) bool {
    for (local.captp_versions) |lp| {
        for (remote.captp_versions) |rp| {
            if (lp == rp) return true;
        }
    }
    return false;
}

/// Test helper: `negotiate` + `pairedNegotiated` (pairing keeps `pairedWithOffers` private).
pub fn pairedWithOffers(
    allocator: std.mem.Allocator,
    local: engine.negotiation.Offer,
    remote: engine.negotiation.Offer,
) !pairing.Pair {
    const negotiated = engine.negotiation.negotiate(local, remote) orelse {
        if (offersShareCaptpVersion(local, remote)) return pairing.Error.NoSharedCodec;
        return pairing.Error.NoSharedCaptpVersion;
    };
    return pairing.pairedNegotiated(allocator, negotiated);
}
