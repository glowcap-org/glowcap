//! Session-scoped actor publication transactions.
//!
//! The Host owns capability identity and the Vat owns actors. These verbs
//! reserve both sides before publishing or spawning so a refusal never leaves
//! an actor without its Host capability, or a capability without its actor.

const actors = @import("actors");

const capability = @import("../capability.zig");
const host_mod = @import("../host.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;

fn prepareLocalCapability(self: *Host, session: ?*HostSession) !capability.FreshLocalReservation {
    try self.refuseReentry();
    try self.admitApplicationOperation();
    if (session) |home| try self.admitSessionOperation(home);
    return self.reserveFreshCapability(session);
}

/// Publish a Zig actor under one session's bootstrap namespace and return its
/// Host-scoped capability. Export allocation, publication rollback, actor
/// rooting, and capability adoption are one core transaction.
pub fn publish(
    self: *Host,
    session: *HostSession,
    name: []const u8,
    comptime Behavior: type,
    initial: Behavior,
) !capability.Ref {
    const reservation = try prepareLocalCapability(self, session);

    const exported = try session.served.publish(&self.vat, name, Behavior, initial);
    return self.retainReservedLocalCapability(reservation, exported.ref);
}

/// `prepareLocalCapability` for a hosted actor, which transfers on every
/// outcome: a refused reservation frees its context here.
fn prepareHostedCapability(self: *Host, session: ?*HostSession, hosted: actors.HostedActor) !capability.FreshLocalReservation {
    errdefer hosted.discard();
    return prepareLocalCapability(self, session);
}

/// Foreign-callback twin of `publish`. Adapters construct only the HostedActor
/// trampoline. The ownership transaction stays here.
pub fn publishHosted(
    self: *Host,
    session: *HostSession,
    name: []const u8,
    hosted: actors.HostedActor,
) !capability.Ref {
    const reservation = try prepareHostedCapability(self, session, hosted);
    const exported = try session.served.publishHosted(&self.vat, name, hosted);
    return self.retainReservedLocalCapability(reservation, exported.ref);
}

/// Spawn a Zig actor and adopt its spawn root into one opaque Host capability.
/// Wire positions remain lazy until the capability is marshalled.
pub fn spawn(
    self: *Host,
    session: ?*HostSession,
    comptime Behavior: type,
    initial: Behavior,
) !capability.Ref {
    const reservation = try prepareLocalCapability(self, session);

    const actor = try self.vat.spawn(Behavior, initial);
    errdefer self.vat.discardFreshActor(actor);
    return self.adoptReservedLocalCapability(reservation, actor);
}

/// Foreign-callback twin of `spawn`.
pub fn spawnHosted(
    self: *Host,
    session: ?*HostSession,
    hosted: actors.HostedActor,
) !capability.Ref {
    const reservation = try prepareHostedCapability(self, session, hosted);
    const actor = try self.vat.spawnHosted(hosted);
    errdefer self.vat.discardFreshActor(actor);
    return self.adoptReservedLocalCapability(reservation, actor);
}
