//! Host capability observation identity: the transaction that turns a local
//! actor or one session-scoped wire observation into a canonical opaque Host
//! reference, then commits, rolls back, or releases the authority it claimed.
//!
//! `capability.zig` remains the independent registry/data-structure owner.
//! This module owns the cross-authority ordering between that registry, the
//! Session import memo and wire retain, Node routes, and Vat actor roots.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("../../host.zig");
const capability = @import("../../capability.zig");
const capability_promise = @import("../../capability_promise.zig");
const vocab = @import("../../vocab.zig");
const host_pump = @import("../pump.zig");

/// The far reference `arg` names, or null when `arg` is not a plain far
/// capability: a break, a promise, a near, or a non-reference value. The one
/// unwrap of the `reference → far` shape the foreign-proxy, enroll, and enliven
/// paths each read off a fulfilled resolution.
/// `pub` for the Host-core siblings, not for embedders. Host-core internal.
pub fn asFarRef(arg: model.Argument) ?@FieldType(model.Reference, "far") {
    if (arg != .reference or arg.reference != .far) return null;
    return arg.reference.far;
}

/// The Vat-local id carried by `ref`. `pub` only for Host-core siblings: the
/// total result keeps general `actors.Ref` inputs from becoming an implicit
/// local-only precondition at a public Host verb.
pub fn localActorId(ref: actors.Ref) actors.Error!u64 {
    return switch (ref) {
        .local => |id| id,
        .far => error.NotLocal,
    };
}

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;

pub const CapabilityLift = struct {
    ref: capability.Ref,
    /// This observation claimed one of the import row's wire retains. A
    /// Host-internal re-observation can add only an application retain.
    claimed_wire_retain: bool,
    /// A redeemed Node route is consumed only when the application-facing
    /// projection commits. Keeping it live through preparation makes an
    /// allocation refusal retryable at the Node action boundary.
    redeemed_route_id: ?model.CapabilityRouteId = null,
};

/// Lift one session-scoped wire reference into this Host's opaque identity
/// space and report the ownership claimed by this exact observation. Routed
/// references are first resolved to their real owning session, so a direct
/// import and the same import reached through Node routing reuse one
/// canonical Host row.
pub fn liftCapabilityTracked(self: *Host, session: *HostSession, reference: model.Reference) !CapabilityLift {
    self.assertOwner();
    try self.checkSession(session);
    const source_route_id = self.node.redeemedRouteId(reference);
    var claimed_wire_retain = false;
    const target: capability.Target = switch (reference) {
        .near => |near| blk: {
            if (near.kind != .object) return error.UncallableTarget;
            const actor = session.served.refForExport(near.export_position.int()) orelse return actors.Error.NoSuchActor;
            const actor_id = switch (actor) {
                .local => |id| id,
                .far => unreachable,
            };
            break :blk .{ .local = actor_id };
        },
        .far, .routed => blk: {
            const routed = self.node.routeReference(session.peer_handle, reference) orelse return HostError.CapabilityRouteUnavailable;
            const home = self.sessions.get(routed.peer_handle) orelse return HostError.CapabilityRouteUnavailable;
            try self.checkSession(home);
            const far = switch (routed.target) {
                .far => |value| value,
                else => return error.ForeignArgument,
            };
            if (!home.served.port.peer.session_state.holdsImport(far.import_position)) return error.ForeignArgument;
            if (home.served.port.peer.session_state.hostImportIdentity(far.import_position)) |identity| {
                const existing = self.capabilities.refFromRaw(identity.ref);
                const existing_target = self.capabilities.resolve(existing) orelse return error.UnknownCapability;
                switch (existing_target) {
                    .remote => |remote| {
                        if (remote.peer_handle != routed.peer_handle or remote.far.import_position != far.import_position or remote.far.kind != far.kind)
                            return error.ImportKindConflict;
                    },
                    .local, .deferred => return error.ForeignArgument,
                }
                const retained = try self.capabilities.retain(self.allocator, existing_target);
                // A fresh wire occurrence contributes another import retain;
                // claim it under the canonical Host row. A Host-internal
                // re-observation (notably a sturdyref cache hit) contributes
                // only an application retain. It must reuse the identity
                // without inventing wire authority the exporter never sent.
                if (identity.lifted_retains < home.served.port.peer.session_state.importReleasable(far.import_position)) {
                    home.served.port.peer.session_state.claimHostCapabilityRetain(far.import_position, identity.ref) catch |err| {
                        _ = self.capabilities.release(retained, 1) catch unreachable;
                        return err;
                    };
                    claimed_wire_retain = true;
                }
                return .{
                    .ref = retained,
                    .claimed_wire_retain = claimed_wire_retain,
                    .redeemed_route_id = source_route_id,
                };
            }
            const incarnation = self.next_import_incarnation;
            if (incarnation == std.math.maxInt(u64)) return error.CapabilitySpaceExhausted;
            break :blk .{ .remote = .{
                .peer_handle = routed.peer_handle,
                .far = far,
                .incarnation = incarnation,
            } };
        },
        else => return error.UncallableTarget,
    };
    if (target == .local) return .{
        .ref = try retainLocalCapability(self, .{ .local = target.local }),
        .claimed_wire_retain = false,
    };
    const ref = try self.capabilities.retain(self.allocator, target);
    errdefer _ = self.capabilities.release(ref, 1) catch unreachable;
    const home = self.sessions.get(target.remote.peer_handle) orelse return HostError.CapabilityRouteUnavailable;
    try home.served.port.peer.session_state.noteHostCapability(target.remote.far.import_position, ref.raw());
    claimed_wire_retain = target.remote.far.import_position.int() != engine.bootstrap_position;
    self.next_import_incarnation = target.remote.incarnation + 1;
    return .{
        .ref = ref,
        .claimed_wire_retain = claimed_wire_retain,
        .redeemed_route_id = source_route_id,
    };
}

pub fn liftCapability(self: *Host, session: *HostSession, reference: model.Reference) !capability.Ref {
    const lifted = try liftCapabilityTracked(self, session, reference);
    commitCapabilityLift(self, lifted);
    return lifted.ref;
}

/// Commit a prepared lift's only external authority transfer. Registry and
/// session ownership were already established by `liftCapabilityTracked`. The
/// redeemed route stays in the Node until this point so rollback and retry can
/// still name it.
pub fn commitCapabilityLift(self: *Host, lifted: CapabilityLift) void {
    if (lifted.redeemed_route_id) |route_id|
        std.debug.assert(self.node.consumeRedeemedRoute(route_id));
}

const LocalRetain = struct {
    ref: capability.Ref,
    fresh: bool,
};

fn retainLiveLocalCapability(self: *Host, actor_id: u64) !LocalRetain {
    const target: capability.Target = .{ .local = actor_id };
    const fresh = !self.capabilities.hasTarget(target);
    const ref = try self.capabilities.retain(self.allocator, target);
    if (fresh) self.vat.retainActor(actor_id);
    return .{ .ref = ref, .fresh = fresh };
}

/// Retain one already-rooted live actor as a Host capability. A fresh slot adds
/// its own Vat root. Repeated observations reuse that root and identity.
pub fn retainLocalCapability(self: *Host, actor: actors.Ref) !capability.Ref {
    self.assertOwner();
    const actor_id = try localActorId(actor);
    // Vat retain is tolerant for relationships that outlive a restore. This
    // mint is not: no registry identity may be published for an actor that is
    // already gone.
    if (!self.vat.hasActor(actor_id)) return error.NoSuchActor;
    return (try retainLiveLocalCapability(self, actor_id)).ref;
}

/// Lift a freshly Vat-spawned local actor into the opaque identity space,
/// adopting its spawn root into the capability slot (ADR-0014). The owning
/// spawn verbs use this instead of an eager export binding: the actor gains
/// wire positions lazily, at first marshal onto a session (ADR-0027's
/// grant-on-marshal), so an unpassed spawn is rooted by its handle alone and
/// the final release reclaims it.
pub fn liftLocalActor(self: *Host, actor: actors.Ref) !capability.Ref {
    self.assertOwner();
    const actor_id = try localActorId(actor);
    // Preflight before Registry mutation: `Vat.retainActor` and
    // `Vat.releaseActor` are tolerant no-ops for retired rows, while a Host
    // capability must never canonically name one.
    if (!self.vat.hasActor(actor_id)) return error.NoSuchActor;
    const retained = try retainLiveLocalCapability(self, actor_id);
    // The transfer: the fresh slot's root replaces the spawn's.
    if (retained.fresh) self.vat.releaseActor(actor_id);
    return retained.ref;
}

/// Undo one lift that failed before its application handle became visible. A
/// claimed remote occurrence is real wire authority even though C never
/// received it, so queue its exact GC release rather than returning it to an
/// invisible pool. If allocation pressure prevents that release, condemn the
/// owning session. It may retain authority only until teardown and cannot admit
/// another inbound value meanwhile.
pub fn rollbackCapabilityLift(self: *Host, lifted: CapabilityLift) void {
    self.assertOwner();
    const target = self.capabilities.resolve(lifted.ref) orelse unreachable;
    var cleanup_failed = false;
    if (lifted.claimed_wire_retain) switch (target) {
        .local, .deferred => unreachable,
        .remote => |remote| {
            const session = self.sessions.get(remote.peer_handle) orelse unreachable;
            const positions = [_]u64{remote.far.import_position.int()};
            const deltas = [_]u64{1};
            if (session.served.port.peer.sendBorrowed(.{ .gc_export = .{ .positions = &positions, .deltas = &deltas } })) |_| {
                session.served.port.peer.session_state.releaseHostCapabilityRetains(remote.far.import_position, lifted.ref.raw(), 1);
                host_pump.dirtyThenPump(self, remote.peer_handle) catch {
                    cleanup_failed = true;
                };
            } else |_| {
                cleanup_failed = true;
            }
        },
    };
    const retired = self.capabilities.release(lifted.ref, 1) catch unreachable;
    if (retired != null) switch (target) {
        .local => self.vat.releaseActor(target.local),
        .remote => {
            const session = self.sessions.get(target.remote.peer_handle) orelse unreachable;
            session.served.port.peer.session_state.forgetHostCapability(
                target.remote.far.import_position,
                lifted.ref.raw(),
            );
        },
        .deferred => |id| capability_promise.abandon(self, id),
    };
    if (cleanup_failed and target == .remote) {
        const session = self.sessions.get(target.remote.peer_handle) orelse return;
        host_pump.condemnAndClose(self, session, .resource_exhausted, "failed capability projection cleanup");
    }
}

/// Discard one wire reference occurrence that a failed application projection
/// never exposed. A successful lift is immediately rolled back through exact
/// GC. If even the lift cannot allocate enough bookkeeping to name what must
/// be released, condemn the source session so it cannot accumulate more
/// invisible imports before teardown.
/// The owned form of a borrowed reference the lift can act on. A sturdyref or
/// a broken reference names no wire position and is never a callable target,
/// so neither needs the allocation its owned form would.
pub fn callableReference(reference: model.view.Reference) error{UncallableTarget}!model.Reference {
    return switch (reference) {
        .near => |near| .{ .near = near },
        .far => |far| .{ .far = far },
        .routed => |routed| .{ .routed = routed },
        .promise => |promise| .{ .promise = .{ .answer_position = promise.answer_position } },
        .sturdy, .broken => error.UncallableTarget,
    };
}

pub fn discardCapabilityObservation(self: *Host, session: *HostSession, reference: model.view.Reference) void {
    const lifted = lift: {
        const owned = callableReference(reference) catch break :lift null;
        break :lift liftCapabilityTracked(self, session, owned) catch null;
    } orelse {
        host_pump.condemnAndClose(self, session, .resource_exhausted, "failed capability projection cleanup");
        return;
    };
    commitCapabilityLift(self, lifted);
    rollbackCapabilityLift(self, lifted);
}

/// Mint and reserve the Host identity for one fresh local actor. Host-core
/// verbs call this immediately before spawn/publication and commit the token
/// without another capability-registry operation in between.
pub fn reserveFreshCapability(self: *Host, session: ?*HostSession) !capability.FreshLocalReservation {
    self.assertOwner();
    if (session) |home| try self.checkSession(home);
    return self.capabilities.reserveFreshLocal(self.allocator);
}

/// Commit a reserved capability as one more root beside an export binding.
pub fn retainReservedLocalCapability(
    self: *Host,
    reservation: capability.FreshLocalReservation,
    actor: actors.Ref,
) capability.Ref {
    self.assertOwner();
    const actor_id = localActorId(actor) catch unreachable;
    const ref = self.capabilities.commitFreshLocal(reservation, actor_id);
    self.vat.retainActor(actor_id);
    return ref;
}

/// Commit a reserved capability by adopting a fresh actor's spawn root.
pub fn adoptReservedLocalCapability(
    self: *Host,
    reservation: capability.FreshLocalReservation,
    actor: actors.Ref,
) capability.Ref {
    self.assertOwner();
    return self.capabilities.commitFreshLocal(reservation, localActorId(actor) catch unreachable);
}

/// Re-scope an ABI-stored raw id to this Host. Resolution still validates the
/// generation. This constructor grants no authority by itself.
pub fn capabilityFromRaw(self: *const Host, raw: u64) capability.Ref {
    return self.capabilities.refFromRaw(raw);
}

/// Borrow the settled identity of an inline handoff. The original occurrence
/// retains its target through the promise row. This query transfers no custody.
/// Pending redemption and terminal failure remain distinct from live objects.
pub fn settledCapability(self: *Host, ref: capability.Ref) !capability.Ref {
    self.assertOwner();
    const target = self.capabilities.resolve(ref) orelse return error.UnknownCapability;
    return switch (target) {
        .local, .remote => ref,
        .deferred => |id| try capability_promise.resolvedRef(self, id),
    };
}

/// The Vat actor a live local capability names, or null for a remote or stale
/// ref. The owning send verbs use it to run a same-side call as a direct local
/// send: no wire position is minted and no export-binding root taken
/// (ADR-0014), so a spawned-and-called actor still reclaims on final release.
pub fn localActorFor(self: *Host, ref: capability.Ref) ?actors.Ref {
    const target = self.capabilities.resolve(ref) orelse return null;
    return switch (target) {
        .local => |id| .{ .local = id },
        .remote, .deferred => null,
    };
}

/// The live session homing a remote `ref`, for application routing metadata.
/// Local actors belong to the Host Vat and return null because any Port may
/// project them. A returned shell remains Host-owned and is invalidated with
/// its remote import session.
pub fn capabilitySession(self: *Host, ref: capability.Ref) ?*HostSession {
    const settled = self.settledCapability(ref) catch return null;
    const target = self.capabilities.resolve(settled) orelse return null;
    return switch (target) {
        .local, .deferred => null,
        .remote => |remote| self.sessions.get(remote.peer_handle),
    };
}

/// Release application retains on one Host capability. A remote Host row may
/// have more application retains than wire retains (for example when a
/// sturdyref cache reissues the same identity). Keep enough wire retains to
/// back the surviving application retains and return only the surplus. The
/// final application release returns every remaining wire retain. Local
/// releases affect only the Host identity row. Once cancellation is committed,
/// session teardown owns wire retirement. Application cleanup still consumes
/// its retains without sending new GC traffic. If the remote home already
/// closed, its release-only row consumes the outstanding unit as a no-op:
/// session teardown already reclaimed the wire authority, while the application
/// handle still deserves a deterministic terminal recipient.
pub fn releaseCapability(self: *Host, ref: capability.Ref, delta: u64) !void {
    self.assertOwner();
    const retains = self.capabilities.retainCount(ref) orelse return error.UnknownCapability;
    if (delta > retains) return error.ReleaseExceedsRetains;
    if (delta == 0) return;

    const target = self.capabilities.resolve(ref) orelse {
        const retired = try self.capabilities.release(ref, delta);
        std.debug.assert(retired == null);
        return;
    };

    var flush_peer: ?engine.PeerHandle = null;
    switch (target) {
        .local => {},
        .remote => |remote| remote_release: {
            const session = self.sessions.get(remote.peer_handle) orelse return error.UnknownCapability;
            try self.checkOwnedSession(session);
            if (session.lifecyclePhase().condemned()) break :remote_release;
            const position = remote.far.import_position;
            // A partner may already have reused the numeric position after
            // another retain released the old import row. The stale Host row
            // must remain releasable, but it must not GC the replacement.
            if (session.served.port.peer.session_state.hostCapabilityFor(position) == ref.raw()) {
                const identity = session.served.port.peer.session_state.hostImportIdentity(position) orelse
                    return error.UnknownCapability;
                const remaining_app_retains = retains - delta;
                const wire_delta = identity.lifted_retains -| remaining_app_retains;
                if (wire_delta != 0) {
                    const enrolled_route = session.served.port.peer.session_state.foreignRouteIdFor(position);
                    const positions = [_]u64{position.int()};
                    const deltas = [_]u64{wire_delta};
                    try session.served.port.peer.sendBorrowed(.{ .gc_export = .{ .positions = &positions, .deltas = &deltas } });
                    if (enrolled_route) |route_id| self.node.retireReleasedRoute(route_id);
                    session.served.port.peer.session_state.releaseHostCapabilityRetains(position, ref.raw(), wire_delta);
                    flush_peer = remote.peer_handle;
                }
            }
        },
        .deferred => {},
    }
    // Every fallible protocol operation is above this commit point. The
    // retain count was validated before the wire release, so registry mutation
    // cannot now fail without an internal invariant breach.
    const retired = self.capabilities.release(ref, delta) catch unreachable;
    if (retired != null) switch (target) {
        .remote => if (self.sessions.get(target.remote.peer_handle)) |session|
            session.served.port.peer.session_state.forgetHostCapability(target.remote.far.import_position, ref.raw()),
        // A retired local slot releases the actor root it held (ADR-0014).
        .local => self.vat.releaseActor(target.local),
        .deferred => |id| capability_promise.abandon(self, id),
    };
    if (flush_peer) |peer_handle| {
        host_pump.dirtyThenPump(self, peer_handle) catch {
            // The GC message, import decrement, and Host retain release already
            // committed. Report consumed success and surface the cleanup
            // failure as a typed close instead of inviting retry.
            if (self.sessions.get(peer_handle)) |session|
                host_pump.condemnAndClose(self, session, .resource_exhausted, "capability release cleanup failed");
        };
    }
}

/// Consume a cleanup retain after its initiating operation can no longer return
/// an error. A live remote home is condemned if ordinary GC publication fails.
/// A dead home is skipped. Registry/Vat ownership is then retired exactly once
/// so terminal cleanup never parks forever.
pub fn releaseCapabilityTerminal(
    self: *Host,
    ref: capability.Ref,
    closing_peer: ?engine.PeerHandle,
) void {
    releaseCapability(self, ref, 1) catch {
        const target = self.capabilities.resolve(ref) orelse return;
        if (target == .remote) {
            const is_closing = if (closing_peer) |peer_handle|
                peer_handle == target.remote.peer_handle
            else
                false;
            if (!is_closing) if (self.sessions.get(target.remote.peer_handle)) |home|
                host_pump.condemnAndClose(
                    self,
                    home,
                    .resource_exhausted,
                    "failed terminal capability cleanup",
                );
        }
        const retired = self.capabilities.release(ref, 1) catch unreachable;
        if (retired != null) switch (target) {
            .local => self.vat.releaseActor(target.local),
            .remote => if (self.sessions.get(target.remote.peer_handle)) |home|
                home.served.port.peer.session_state.forgetHostCapability(
                    target.remote.far.import_position,
                    ref.raw(),
                ),
            .deferred => |id| capability_promise.abandon(self, id),
        };
    };
}
