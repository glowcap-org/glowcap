//! Durable peer identity checks and live session selection for sturdyrefs.
const std = @import("std");
const foundation = @import("foundation");
const model = @import("model");
const host_mod = @import("../host.zig");
const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;
const PeerProvenance = host_mod.PeerProvenance;
const crypto = foundation.crypto;

pub const EnlivenPeerPolicy = enum {
    /// Require an authenticated durable key designator or the exact address
    /// this side dialed. An accepted address-session assertion is refused.
    checked,
    /// Permit an accepted address transport's session-signed but unproved
    /// locator claim. The returned provenance remains explicit.
    assertion_only,
};

pub fn matchSturdyrefPeer(
    self: *Host,
    session: *HostSession,
    sturdyref: model.SturdyRef,
    policy: EnlivenPeerPolicy,
) !PeerProvenance {
    try self.checkSession(session);
    const locator = sturdyref.peer;
    if (std.mem.eql(u8, locator.transport, model.transport.id)) {
        if (!hostAcceptsRouteVocabulary(self)) return HostError.PeerIdentityMismatch;
        const demanded = self.node.validateIdRouteLocator(locator) catch
            return HostError.PeerIdentityMismatch;
        return matchIdSturdyrefPeer(session, demanded);
    }
    if (!std.mem.eql(u8, locator.transport, session.transport)) return HostError.PeerIdentityMismatch;

    if (try self.designatorScheme(session.transport) == .key) {
        const identity = try self.partnerIdentity(session);
        if (!std.mem.eql(u8, locator.designator, identity.designator)) return HostError.PeerIdentityMismatch;
        // The provenance-bearing predicate, not key equality (ADR-0097): this
        // needs a proved durable peer. The fresh session key verifies the hello;
        // only authenticated channel evidence proves the durable designator.
        if (!identity.durableIdentityAuthenticated()) return HostError.PeerIdentityUnverified;
        return .verified;
    }

    switch (session.role) {
        .dialed => |target| {
            if (!std.mem.eql(u8, locator.designator, target)) return HostError.PeerIdentityMismatch;
            return .dial_target;
        },
        .accepted => {
            const claimed = session.served.port.peer.session_state.partnerDesignator() orelse
                return HostError.HandshakeIncomplete;
            if (!std.mem.eql(u8, locator.designator, claimed)) return HostError.PeerIdentityMismatch;
            if (policy != .assertion_only) return HostError.PeerIdentityUnverified;
            return .assertion_only;
        },
    }
}

fn matchIdSturdyrefPeer(session: *HostSession, key: crypto.PeerKey) !PeerProvenance {
    const designator = key.toDesignator();
    if (session.served.port.peer.partnerDurableProvenance(designator[0..]) != .authenticated_transport)
        return HostError.PeerIdentityUnverified;
    return .verified;
}

pub fn hostAcceptsRouteVocabulary(self: *const Host) bool {
    return self.opts.captp_version == .next and self.opts.features.multi_location;
}

pub fn authenticatedSessionForKey(self: *const Host, key: foundation.crypto.PeerKey) ?*HostSession {
    const session = self.sessions.get(self.peer_by_durable.get(key.bytes) orelse return null) orelse return null;
    if (session.lifecyclePhase() != .active) return null;
    const designator = key.toDesignator();
    if (session.served.port.peer.partnerDurableProvenance(designator[0..]) != .authenticated_transport)
        return null;
    return session;
}
