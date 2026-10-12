//! Host capability routing: resolve raw or opaque targets to the exact
//! session/actor pair they ride, while enforcing the raw-Argument boundary
//! before any send, vow, route consumption, or exporter effect can begin.
//!
//! Node remains route-table authority, Registry remains opaque-capability
//! identity authority, and Host remains the state aggregate. This owner only
//! composes their read-only lookups with one bounded foreign-reference scan.

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("../../host.zig");
const capability = @import("../../capability.zig");
const capability_promise = @import("../../capability_promise.zig");
const vocab = @import("../../vocab.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;

pub const RoutedSend = struct { session: *HostSession, target: actors.Ref };

pub const ApplicationTarget = struct { ref: capability.Ref, session: ?*HostSession };

/// Application delivery needs no caller-selected session. A pending give queues
/// on its introducing session, which owns redemption authority. Once fulfilled,
/// follow the retained target to its actual local or foreign home. These are
/// borrowed identities. Admission uses the existing promise queue.
pub fn applicationTarget(self: *Host, ref: capability.Ref) !ApplicationTarget {
    self.assertOwner();
    var current = ref;
    while (true) {
        const target = self.capabilities.resolve(current) orelse return error.UnknownCapability;
        switch (target) {
            .local => return .{ .ref = current, .session = null },
            .remote => |remote| return .{
                .ref = current,
                .session = self.sessions.get(remote.peer_handle) orelse return error.UnknownCapability,
            },
            .deferred => |id| {
                const promise = self.capability_promises.get(id) orelse return error.UnknownCapability;
                switch (promise.state) {
                    .pending, .settling => return .{
                        .ref = current,
                        .session = self.sessions.get(promise.introducing_peer) orelse return error.UnknownCapability,
                    },
                    .fulfilled => |settled| current = settled,
                    .broken => return error.PromiseBroken,
                }
            },
        }
    }
}

const RouteScope = enum { host, session };

/// Resolve a send's target to the session and vat reference it rides: a near
/// export to its local actor on `session`, or a far/routed reference through
/// Node to its exporter session. Raw arguments are validated against the
/// resolved destination before the caller may publish any consequence.
pub fn routeSend(
    self: *Host,
    session: *HostSession,
    target: model.Reference,
    args: []const model.Argument,
) !RoutedSend {
    return routeTarget(self, session, target, args, .host);
}

/// Resolve one opaque Host capability to the actor/session that owns it.
/// `object_only` is the send/tell target gate. Listen callers pass false.
pub fn routeCapability(
    self: *Host,
    session: *HostSession,
    ref: capability.Ref,
    object_only: bool,
) !RoutedSend {
    self.assertOwner();
    try self.admitSessionOperation(session);
    try self.checkSession(session);
    const target = self.capabilities.resolve(ref) orelse return error.UnknownCapability;
    return switch (target) {
        .local => |actor_id| blk: {
            if (!self.vat.hasActor(actor_id)) return actors.Error.NoSuchActor;
            break :blk .{ .session = session, .target = .{ .local = actor_id } };
        },
        .remote => |remote| blk: {
            if (object_only and remote.far.kind != .object) return vocab.Error.UncallableTarget;
            const home = self.sessions.get(remote.peer_handle) orelse return error.UnknownCapability;
            if (home != session) try self.admitSessionOperation(home);
            try self.checkSession(home);
            if (!home.served.port.peer.session_state.holdsImport(remote.far.import_position) or
                home.served.port.peer.session_state.hostCapabilityFor(remote.far.import_position) != ref.raw())
                return error.UnknownCapability;
            break :blk .{ .session = home, .target = .{ .far = remote.far } };
        },
        .deferred => |id| return routeCapability(
            self,
            session,
            try capability_promise.resolvedRef(self, id),
            object_only,
        ),
    };
}

/// Raw/model callers have no Host capability retain to transfer into a delayed
/// inline-Passable transaction. Refuse cross-session references at this tier.
/// Owning `Value` verbs retain and stage them explicitly. The scan is the
/// validation pass itself, not a preflight for another traversal.
pub fn validateRoutedArguments(
    self: *Host,
    session: *HostSession,
    args: []const model.Argument,
) error{ ForeignArgument, NestingTooDeep }!void {
    for (args) |argument| {
        if (try argumentIsForeign(self, session.peer_handle, argument, 0))
            return error.ForeignArgument;
    }
}

/// Resolve a turn-forward target without allowing the turn to cross its
/// ingress session. C behavior callbacks adapt through this authority rather
/// than reimplementing capability routing and foreign-argument policy.
pub fn routeTurnTarget(
    self: *Host,
    session: *HostSession,
    target: model.Reference,
    args: []const model.Argument,
) !actors.Ref {
    return (try routeTarget(self, session, target, args, .session)).target;
}

/// Resolve an opaque target for one already-admitted inbound turn. A turn may
/// reach a local actor or a capability homed on its own ingress session.
/// Crossing to a sibling session would detach the answer from its causal Port.
pub fn routeTurnCapability(
    self: *Host,
    session: *HostSession,
    target: capability.Ref,
    args: []const model.Argument,
) !actors.Ref {
    const routed = try routeCapability(self, session, target, true);
    if (routed.session != session) return HostError.ForeignArgument;
    try validateRoutedArguments(self, session, args);
    return routed.target;
}

fn routeTarget(
    self: *Host,
    session: *HostSession,
    target: model.Reference,
    args: []const model.Argument,
    scope: RouteScope,
) !RoutedSend {
    self.assertOwner();
    try self.admitSessionOperation(session);
    try self.checkSession(session);
    switch (target) {
        .near => |near| {
            const ref = session.served.refForExport(near.export_position.int()) orelse
                return actors.Error.NoSuchActor;
            try validateRoutedArguments(self, session, args);
            return .{ .session = session, .target = ref };
        },
        .far, .routed => {
            const routed = self.node.routeReference(session.peer_handle, target) orelse
                return HostError.CapabilityRouteUnavailable;
            if (scope == .session and routed.peer_handle != session.peer_handle)
                return HostError.ForeignArgument;
            const routed_session = self.sessions.get(routed.peer_handle) orelse
                return HostError.CapabilityRouteUnavailable;
            if (routed_session != session) {
                try self.admitSessionOperation(routed_session);
                try self.checkSession(routed_session);
            }
            try validateRoutedArguments(self, routed_session, args);
            return .{ .session = routed_session, .target = .{ .far = routed.target.far } };
        },
        else => return vocab.Error.UncallableTarget,
    }
}

fn argumentIsForeign(
    self: *Host,
    peer_handle: engine.PeerHandle,
    argument: model.Argument,
    depth: usize,
) error{NestingTooDeep}!bool {
    if (depth > model.max_value_depth) return error.NestingTooDeep;
    return switch (argument) {
        .reference => |ref| self.node.argIsForeign(peer_handle, ref),
        .list, .set => |items| for (items) |item| {
            if (try argumentIsForeign(self, peer_handle, item, depth + 1)) break true;
        } else false,
        .tagged => |tagged| for (tagged.value) |item| {
            if (try argumentIsForeign(self, peer_handle, item, depth + 1)) break true;
        } else false,
        .@"struct" => |entries| for (entries) |entry| {
            if (try argumentIsForeign(self, peer_handle, entry.value, depth + 1)) break true;
        } else false,
        else => false,
    };
}
