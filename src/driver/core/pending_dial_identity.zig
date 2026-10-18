//! Identity proof for Host-owned pending dials.
//!
//! A public completion must be the dialed session for the ticket's active
//! route. Host-internal selection may instead reuse an authenticated same-key
//! session. These are separate claims: identity proof does not prove which
//! physical route an embedder completed.

const std = @import("std");

const engine = @import("engine");

const host_mod = @import("host.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;
const PeerProvenance = host_mod.PeerProvenance;

pub const Completion = struct {
    provenance: PeerProvenance,
};

fn requirePhysicalRoute(
    view: engine.Node.PendingDialView,
    session: *const HostSession,
) HostError!void {
    const locator = view.locator;
    if (!std.mem.eql(u8, session.transport, locator.transport))
        return error.PeerIdentityMismatch;
    switch (session.role) {
        .dialed => |target| if (!std.mem.eql(u8, target, locator.designator))
            return error.PeerIdentityMismatch,
        .accepted => return error.PeerIdentityMismatch,
    }
}

fn provenanceForView(
    view: engine.Node.PendingDialView,
    session: *const HostSession,
    physical_route_required: bool,
) HostError!PeerProvenance {
    if (physical_route_required) try requirePhysicalRoute(view, session);
    if (view.demanded_partner_key) |key| {
        const designator = key.toDesignator();
        if (session.served.port.peer.partnerDurableProvenance(designator[0..]) == .authenticated_transport)
            return .verified;
        if (view.authenticated_partner_required)
            return error.PeerIdentityUnverified;
    }

    if (!physical_route_required) try requirePhysicalRoute(view, session);
    return .dial_target;
}

fn completion(
    host: *const Host,
    ticket: engine.Node.PendingId,
    route_index: usize,
    session: *const HostSession,
    physical_route_required: bool,
) HostError!?Completion {
    const view = host.pendingDial(ticket, route_index) orelse return null;
    const result = try provenanceForView(view, session, physical_route_required);
    return .{ .provenance = result };
}

pub fn selectedSessionSatisfies(host: *const Host, ticket: engine.Node.PendingId, route_index: usize, session: *const HostSession) bool {
    return (completion(host, ticket, route_index, session, false) catch return false) != null;
}

pub fn requireDialed(
    host: *const Host,
    ticket: engine.Node.PendingId,
    route_index: usize,
    session: *const HostSession,
) HostError!?Completion {
    return completion(host, ticket, route_index, session, true);
}

pub fn requireSelected(
    host: *const Host,
    ticket: engine.Node.PendingId,
    route_index: usize,
    session: *const HostSession,
) HostError!?Completion {
    return completion(host, ticket, route_index, session, false);
}
