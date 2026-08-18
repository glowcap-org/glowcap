//! `pairedWithOffers`: build two live peers from two negotiation offers,
//! refusing offers that share no codec, profile, or CapTP version — the
//! factory every pairing scenario family drives.

const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const codec = pancake.ocapn.codec;
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
