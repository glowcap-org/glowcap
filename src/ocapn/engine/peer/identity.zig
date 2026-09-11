//! Connection-scoped durable identity evidence for one Peer (ADR-0105).
//!
//! A dial target and a verified byte-channel endpoint are separate facts. This
//! module owns both writes, both direct reads, and the one provenance
//! derivation, so transport symbols and partner claims cannot manufacture
//! authentication by being interpreted elsewhere.

const std = @import("std");
const foundation = @import("foundation");

const engine = @import("../mod.zig");

const Peer = engine.Peer;

pub const DurablePin = struct {
    /// A dial target requirement, not evidence that the connection proved it.
    demanded_partner: ?foundation.crypto.PeerKey = null,
    /// Durable key verified for the byte channel's far endpoint. Under a relay,
    /// this endpoint and the CapTP partner can be different nodes.
    channel: ?foundation.crypto.PeerKey = null,
};

/// What authenticated the durable identity a partner advertised.
pub const DurableProvenance = enum {
    /// A lower layer proved the partner's claimed key is also the byte
    /// channel's far endpoint.
    authenticated_transport,
    /// No held evidence proves the claimed durable identity.
    unauthenticated,
};

/// Record the durable identity named by a dial before partner bytes arrive.
/// This is a target requirement, never proof. A partner hello selecting a key
/// route must claim it; an address route makes no durable claim and is weighed
/// on the realizer/netlayer evidence. Repeating the same demand is idempotent;
/// naming another key is a caller bug because no peer input reaches here.
pub fn demandPartnerDurableKey(self: *Peer, key: foundation.crypto.PeerKey) void {
    if (self.durable_pin.demanded_partner) |existing| std.debug.assert(existing.eql(key));
    self.durable_pin.demanded_partner = key;
}

/// Record the durable key the connection realizer proved for the byte-channel
/// endpoint. Native iroh/WebRTC residents, the completion bridge, a completed
/// Noise handshake, or a foreign realizer through the C ABI may make this
/// assertion; the transport symbol itself is never proof. The key names the
/// channel endpoint, not necessarily the CapTP partner across a transparent
/// relay. Repeating the same proof is idempotent; another key is a caller bug.
pub fn bindVerifiedChannelKey(self: *Peer, key: foundation.crypto.PeerKey) void {
    if (self.durable_pin.channel) |existing| std.debug.assert(existing.eql(key));
    self.durable_pin.channel = key;
}

/// Durable identity demanded of the CapTP partner, if the dial named one. This
/// answers who the session intended to reach, not who the channel authenticated.
pub fn demandedPartnerKey(self: *const Peer) ?foundation.crypto.PeerKey {
    return self.durable_pin.demanded_partner;
}

/// Durable key proved for the byte channel's far endpoint, if any. This answers
/// what the realizer authenticated, not who the CapTP partner claimed to be.
pub fn verifiedChannelKey(self: *const Peer) ?foundation.crypto.PeerKey {
    return self.durable_pin.channel;
}

/// Derive provenance for exactly the durable key `designator` names. Channel
/// evidence authenticates the partner only when both names identify one node;
/// a byte-transparent relay deliberately permits them to differ.
pub fn partnerDurableProvenance(self: *const Peer, designator: []const u8) DurableProvenance {
    const claimed = foundation.crypto.PeerKey.fromDesignator(designator) orelse
        return .unauthenticated;
    if (self.durable_pin.channel) |channel| {
        if (channel.eql(claimed)) return .authenticated_transport;
    }
    return .unauthenticated;
}
