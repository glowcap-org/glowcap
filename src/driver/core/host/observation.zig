//! Host application observation: bootstrap fetches and promise listeners.
//!
//! Both families mint a Host vow around one session-owned observation, commit
//! exporter ownership only after the wire operation exists, and then either
//! drive progress or leave it parked for listener installation. Vow tables,
//! capability identity, routing, and the pump remain their independent owners.

const model = @import("model");

const host_mod = @import("../host.zig");
const capability = @import("../capability.zig");
const capability_promise = @import("../capability_promise.zig");
const vows = @import("../vows.zig");
const host_pump = @import("pump.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;

/// Fetch the partner capability published as `name`, minting a host vow for
/// the outcome: observe it in-process with `vowOn`, or drain its
/// `settled`/`failed` completion from the action queue. A fulfilled far
/// capability settles *already enrolled* under a node-unique route (ADR-0069)
/// — recorded before the outcome is dispatched, so a reply that immediately
/// re-gifts it routes to the right exporter. Top-level: refused from inside a
/// callback.
pub fn fetch(self: *Host, session: *HostSession, name: []const u8) !u64 {
    return fetchWithProgress(self, session, name, true);
}

/// `fetch` with progress deferred until the caller has installed its
/// in-process listener. See `queueSend`.
pub fn queueFetch(self: *Host, session: *HostSession, name: []const u8) !u64 {
    return fetchWithProgress(self, session, name, false);
}

fn fetchWithProgress(self: *Host, session: *HostSession, name: []const u8, drive_now: bool) !u64 {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    try self.admitSessionOperation(session);
    try self.checkSession(session);
    try self.checkOutboundAdmission(session);
    const reservation = try vows.reserveVow(self, session, .far, .fetch, .peer_visible);
    var reservation_live = true;
    errdefer if (reservation_live) vows.cancelVowReservation(self, reservation);
    const vow = try session.served.sendBootstrapFetch(&self.vat, name);
    const id = vows.commitVow(self, session, reservation, vow);
    reservation_live = false;
    self.node.exporterApplicationOwned(session.peer_handle);
    if (drive_now)
        host_pump.finishCommittedVow(self, session)
    else
        host_pump.markDirty(self, session.peer_handle);
    return id;
}

/// Listen on the promise `target` names, minting a host vow for its settlement
/// (ADR-0095). A promise this session handed us — an introducing session's
/// proxy for a third party's promise (ADR-0009) — settles through a
/// notification the partner delivers, and this is the verb that asks for it.
/// A far target routes through the node first, the way `send` and `tell` route,
/// so a Node route is listened on the session that exports it rather than the
/// session where it was learned. The vow is `.plain`, not `.fetch`: a listen
/// makes no blanket claim that what arrives is a capability, and a give that
/// does arrive is auto-redeemed on the way through, exactly as one arriving in
/// a call's reply is. Enqueueing, like `send`: legal inside a callback, because
/// a settle callback is where you learn the promise to listen on.
pub fn listenTo(self: *Host, session: *HostSession, target: model.Reference) !u64 {
    return listenToWithProgress(self, session, target, true);
}

/// `listenTo` with progress deferred until the caller has installed its
/// in-process listener. See `queueSend`.
pub fn queueListenTo(self: *Host, session: *HostSession, target: model.Reference) !u64 {
    return listenToWithProgress(self, session, target, false);
}

/// Listen through an opaque Host capability, routing a remote capability
/// directly to its home session. A local actor is not a far reference the
/// partner can notify us about and is refused `InvalidReference` without
/// creating a Port projection.
pub fn listenToCapability(self: *Host, session: *HostSession, target: capability.Ref) !u64 {
    return listenToCapabilityWithProgress(self, session, target, true);
}

/// `listenToCapability` with progress deferred until its Host vow can be
/// observed.
pub fn queueListenToCapability(self: *Host, session: *HostSession, target: capability.Ref) !u64 {
    return listenToCapabilityWithProgress(self, session, target, false);
}

fn listenToWithProgress(
    self: *Host,
    session: *HostSession,
    target: model.Reference,
    drive_now: bool,
) !u64 {
    // This verb is callback-safe, so claim the owner without refusing the
    // callback latch. Ownership still precedes routing, which may inspect or
    // mutate node/session state for a far target.
    self.assertOwner();
    try self.admitApplicationOperation();
    try self.checkOwnedSession(session);
    try self.admitSessionOperation(session);
    var home = session;
    var wire = target;
    if (target == .far or target == .routed) {
        const routed = try self.routeSend(session, target, &.{});
        home = routed.session;
        wire = .{ .far = routed.target.far };
    } else {
        // Not routed: the engine verb refuses every non-far shape with the
        // `InvalidReference` every tier names, so it flows through.
        try self.checkSession(session);
    }
    try self.admitSessionOperation(home);
    try self.checkOutboundAdmission(home);
    return commitRoutedListen(self, home, wire, drive_now);
}

fn listenToCapabilityWithProgress(
    self: *Host,
    session: *HostSession,
    target: capability.Ref,
    drive_now: bool,
) !u64 {
    self.assertOwner();
    try self.admitApplicationOperation();
    const resolved_target = self.capabilities.resolve(target) orelse return error.UnknownCapability;
    if (resolved_target == .deferred) {
        const promise = self.capability_promises.get(resolved_target.deferred) orelse
            return error.UnknownCapability;
        switch (promise.state) {
            .pending, .settling => {
                const id = try capability_promise.queueListen(self, resolved_target.deferred, session);
                if (drive_now) host_pump.finishCommittedWork(self, session);
                return id;
            },
            .fulfilled, .broken => {},
        }
    }
    const routed = try self.routeCapability(session, target, false);
    const wire = switch (routed.target) {
        .local => return error.InvalidReference,
        .far => |far| model.Reference{ .far = far },
    };
    try self.checkOutboundAdmission(routed.session);
    return commitRoutedListen(self, routed.session, wire, drive_now);
}

fn commitRoutedListen(
    self: *Host,
    home: *HostSession,
    wire: model.Reference,
    drive_now: bool,
) !u64 {
    const reservation = try vows.reserveVow(self, home, .far, .plain, .session_private);
    var reservation_live = true;
    errdefer if (reservation_live) vows.cancelVowReservation(self, reservation);
    const vow = try home.served.listenTo(wire);
    const id = vows.commitVow(self, home, reservation, vow);
    reservation_live = false;
    self.node.exporterApplicationOwned(home.peer_handle);
    if (drive_now)
        host_pump.finishCommittedVow(self, home)
    else
        host_pump.markDirty(self, home.peer_handle);
    return id;
}
