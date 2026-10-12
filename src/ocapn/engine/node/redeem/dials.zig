//! Exporter identity cache and deduplicated dial scheduler for redemption.

const std = @import("std");

const model = @import("model");
const codec = @import("codec");
const crypto = @import("foundation").crypto;
const node_mod = @import("../../node.zig");
const actions = @import("../actions.zig");
const redeem = @import("../redeem.zig");
const plan = @import("plan.zig");
const attempts = @import("dials/attempts.zig");
const withdrawals = @import("withdrawals.zig");
const gift_recipe = @import("../handoffs/gifts/recipe.zig");

const Node = node_mod.Node;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;

pub const PendingId = u64;
pub const PendingDialView = struct {
    locator: model.PeerLocator,
    /// Session that supplied the oldest remaining give. A shared dial may
    /// serve several introducing sessions. This is one source for realizing
    /// its route, not authority to act on behalf of every waiter. A purely
    /// application-owned dial has no introducer.
    introducer: ?PeerHandle = null,
    demanded_partner_key: ?crypto.PeerKey = null,
    authenticated_partner_required: bool = false,
};
pub const ExporterCompletion = enum { dialed, selected };
pub const Failure = enum { retry, waiting, exhausted, stale };
pub const Waiter = struct {
    dest: redeem.Destination,
    give: []u8,
};

fn demandedPartnerKeyForPath(self: *const Node, staged: plan.Owned, path_index: usize) ?crypto.PeerKey {
    if (staged.pathRequiresIdentity(path_index))
        return plan.demandedPartnerKey(staged);
    if (path_index != 0 or staged.source == .id) return null;
    const primary = staged.paths[path_index];
    if (node_mod.Internal.designatorScheme(self, primary.transport) != .key) return null;
    return crypto.PeerKey.fromDesignator(primary.designator);
}

/// One in-flight exporter dial. A second redeem for the same canonical peer
/// identity joins `waiters` rather than opening another session.
pub const Dialing = struct {
    plan: plan.Owned,
    /// Parsed identity locator from an incoming give. It remains candidate
    /// advice until the reached session carries a successful withdrawal, and
    /// is encoded only if that session still needs discovered route advice.
    exporter_locator: ?model.PeerLocator = null,
    attempts: attempts.State = .{},
    /// A non-redeem owner joined or originated this dial.
    application_owned: bool = false,
    /// Host closure sealed this row against later delivery.
    cancel_requested: bool = false,
    waiters: std.ArrayListUnmanaged(Waiter) = .empty,
};

/// A winning route has settled the logical dial while these losing physical
/// effects are still being interrupted and joined. No locator or identity
/// storage survives in this state.
pub const Pending = union(enum) {
    dialing: Dialing,
    retiring: u8,
};

pub const State = struct {
    /// Canonical peer-identity URI -> live exporter session.
    exporters: std.StringHashMapUnmanaged(PeerHandle) = .empty,
    /// Node-minted ticket -> in-flight parsed dial.
    pending: std.AutoHashMapUnmanaged(PendingId, Pending) = .empty,
    /// Canonical identity -> ticket. Keys alias the pending row's identity.
    by_identity: std.StringHashMapUnmanaged(PendingId) = .empty,
    /// One future terminal failure seat per admitted waiter.
    waiter_action_reservations: usize = 0,
};

pub fn deinit(self: *Node) void {
    const state = &self.redeems.dials;
    var exporter_keys = state.exporters.keyIterator();
    while (exporter_keys.next()) |key| self.allocator.free(key.*);
    state.exporters.deinit(self.allocator);

    var dial_it = state.pending.valueIterator();
    while (dial_it.next()) |pending| switch (pending.*) {
        .dialing => |*dialing| freeDialing(self, dialing),
        .retiring => {},
    };
    std.debug.assert(state.waiter_action_reservations == 0);
    state.pending.deinit(self.allocator);
    // Keys aliased pending identities freed above.
    state.by_identity.deinit(self.allocator);
}

pub fn pendingDial(self: *const Node, pending: PendingId, route_index: usize) ?PendingDialView {
    const row = self.redeems.dials.pending.get(pending) orelse return null;
    const entry = switch (row) {
        .dialing => |dialing| dialing,
        .retiring => return null,
    };
    if (entry.cancel_requested or route_index >= entry.plan.paths.len or
        !entry.attempts.admitsReport(route_index)) return null;
    const locator = entry.plan.view(route_index);
    const identity_required = entry.plan.pathRequiresIdentity(route_index);
    return .{
        .locator = locator,
        .introducer = if (entry.waiters.items.len == 0) null else redeem.recipientPeer(entry.waiters.items[0].dest),
        .demanded_partner_key = demandedPartnerKeyForPath(self, entry.plan, route_index),
        .authenticated_partner_required = identity_required,
    };
}

/// Commit delivery of one dial effect to an external executor.
pub fn beginEffect(self: *Node, pending: PendingId, route_index: usize) bool {
    const row = self.redeems.dials.pending.getPtr(pending) orelse return false;
    const entry = switch (row.*) {
        .dialing => |*dialing| dialing,
        .retiring => return false,
    };
    if (entry.cancel_requested) return false;
    return entry.attempts.begin(route_index);
}

/// Roll back a callback that refused before publishing its external effect.
pub fn rollbackEffect(self: *Node, pending: PendingId, route_index: usize) void {
    const row = self.redeems.dials.pending.getPtr(pending) orelse return;
    switch (row.*) {
        .dialing => |*entry| entry.attempts.rollback(route_index),
        .retiring => {},
    }
}

/// Seal all pending dials and yield each already-running effect exactly once
/// for physical cancellation.
pub const CancellationIterator = struct {
    node: *Node,
    pending_dials: std.AutoHashMapUnmanaged(PendingId, Pending).Iterator,
    current_pending: PendingId = 0,
    remaining_routes: u8 = 0,

    pub fn next(self: *CancellationIterator) ?Cancellation {
        const state = &self.node.redeems.dials;
        if (popRoute(&self.remaining_routes)) |route_index|
            return .{ .pending = self.current_pending, .route_index = route_index };
        while (self.pending_dials.next()) |entry| {
            const dialing = switch (entry.value_ptr.*) {
                .dialing => |*value| value,
                .retiring => continue,
            };
            if (dialing.cancel_requested) continue;
            dialing.cancel_requested = true;
            settleCancelledWaiters(self.node, dialing);
            std.debug.assert(state.by_identity.remove(dialing.plan.identity));
            const flights = dialing.attempts.in_flight;
            if (flights == 0) {
                var owned = dialing.*;
                state.pending.removeByPtr(entry.key_ptr);
                freeDialing(self.node, &owned);
                continue;
            }
            self.current_pending = entry.key_ptr.*;
            self.remaining_routes = flights;
            return self.next();
        }
        return null;
    }
};

pub const Cancellation = struct {
    pending: PendingId,
    route_index: usize,
};

pub fn requestCancellations(self: *Node) CancellationIterator {
    return .{
        .node = self,
        .pending_dials = self.redeems.dials.pending.iterator(),
    };
}

pub fn count(self: *const Node) usize {
    return self.redeems.dials.pending.count();
}

/// Remove one Host-owned inline give waiter whose introducing session died.
/// A shared or in-flight dial remains for its other owner.
pub fn cancelInlineGive(self: *Node, recipient_peer: PeerHandle, deferred: u64) void {
    const state = &self.redeems.dials;
    var it = state.pending.iterator();
    while (it.next()) |entry| {
        const dialing = switch (entry.value_ptr.*) {
            .dialing => |*value| value,
            .retiring => continue,
        };
        var index: usize = 0;
        while (index < dialing.waiters.items.len) {
            const waiter = dialing.waiters.items[index];
            const matches = switch (waiter.dest) {
                .answer => false,
                .deferred => |dest| dest.recipient_peer == recipient_peer and
                    dest.id == deferred,
            };
            if (!matches) {
                index += 1;
                continue;
            }
            const removed = dialing.waiters.orderedRemove(index);
            releaseWaiterReservations(self, 1);
            self.allocator.free(removed.give);
        }
        if (dialing.waiters.items.len != 0 or
            dialing.application_owned or
            dialing.attempts.in_flight != 0)
            continue;
        var owned = dialing.*;
        std.debug.assert(state.by_identity.remove(owned.plan.identity));
        state.pending.removeByPtr(entry.key_ptr);
        freeDialing(self, &owned);
    }
}

/// Physical cancellation completion. Idempotent when an ordinary outcome won.
pub fn cancelled(self: *Node, pending: PendingId, route_index: usize) void {
    if (route_index >= model.route_bundle.max_route_list_count) return;
    const state = &self.redeems.dials;
    const row = state.pending.getPtr(pending) orelse return;
    const route = routeBit(route_index);
    switch (row.*) {
        .dialing => |*entry| {
            if (!entry.cancel_requested or entry.attempts.in_flight & route == 0) return;
            entry.attempts.in_flight &= ~route;
            if (entry.attempts.in_flight != 0) return;
            const removed = (state.pending.fetchRemove(pending) orelse unreachable).value;
            var owned = removed.dialing;
            freeDialing(self, &owned);
        },
        .retiring => |*routes| {
            if (routes.* & route == 0) return;
            routes.* &= ~route;
            if (routes.* == 0) std.debug.assert(state.pending.remove(pending));
        },
    }
}

fn freeDialing(self: *Node, entry: *Dialing) void {
    for (entry.waiters.items) |waiter| self.allocator.free(waiter.give);
    releaseWaiterReservations(self, entry.waiters.items.len);
    entry.waiters.deinit(self.allocator);
    entry.plan.deinit(self.allocator);
    if (entry.exporter_locator) |locator| model.freePeerLocator(self.allocator, locator);
}

fn settleCancelledWaiters(self: *Node, pending: *Dialing) void {
    releaseWaiterReservations(self, pending.waiters.items.len);
    for (pending.waiters.items) |waiter| {
        actions.pushReserved(self, .{ .fail = .{
            .dest = redeem.failureDestination(waiter.dest),
            .reason = .{ .static = "handoff redeem failed: host closing" },
        } });
        self.allocator.free(waiter.give);
    }
    pending.waiters.deinit(self.allocator);
    pending.waiters = .empty;
}

fn routeBit(index: usize) u8 {
    std.debug.assert(index < model.route_bundle.max_route_list_count);
    return @as(u8, 1) << @intCast(index);
}

fn popRoute(routes: *u8) ?usize {
    if (routes.* == 0) return null;
    const index: usize = @ctz(routes.*);
    routes.* &= ~routeBit(index);
    return index;
}

fn releaseWaiterReservations(self: *Node, count_value: usize) void {
    const state = &self.redeems.dials;
    std.debug.assert(state.waiter_action_reservations >= count_value);
    state.waiter_action_reservations -= count_value;
}

pub fn exporterDialed(self: *Node, pending: PendingId, route_index: usize, exporter_peer: PeerHandle) !bool {
    return exporterCompleted(self, pending, route_index, exporter_peer, .dialed);
}

pub fn exporterSelected(self: *Node, pending: PendingId, route_index: usize, exporter_peer: PeerHandle) !bool {
    return exporterCompleted(self, pending, route_index, exporter_peer, .selected);
}

pub fn exporterCompleted(
    self: *Node,
    pending: PendingId,
    route_index: usize,
    exporter_peer: PeerHandle,
    completion: ExporterCompletion,
) !bool {
    const row = self.redeems.dials.pending.get(pending) orelse return false;
    const pending_view = switch (row) {
        .dialing => |dialing| dialing,
        .retiring => return false,
    };
    if (route_index >= pending_view.plan.paths.len) return error.PeerIdentityMismatch;
    if (!pending_view.attempts.acceptsCompletion(route_index)) return false;
    const exporter = self.peer(exporter_peer) orelse return error.UnknownConnection;
    const demanded_partner_key = demandedPartnerKeyForPath(self, pending_view.plan, route_index);
    const authenticated_identity = if (demanded_partner_key) |demanded| authenticated: {
        const designator = demanded.toDesignator();
        break :authenticated exporter.partnerDurableProvenance(&designator) == .authenticated_transport;
    } else false;
    if (pending_view.plan.pathRequiresIdentity(route_index) and !authenticated_identity)
        return error.PeerIdentityMismatch;
    return exporterReady(self, pending, route_index, exporter_peer, completion == .selected, authenticated_identity);
}

pub fn exporterApplicationOwned(self: *Node, exporter_peer: PeerHandle) void {
    if (self.peers.getPtr(exporter_peer)) |slot| slot.provisional_exporter = false;
}

fn exporterReady(
    self: *Node,
    pending_id: PendingId,
    route_index: usize,
    exporter_peer: PeerHandle,
    selected: bool,
    authenticated_identity: bool,
) !bool {
    const state = &self.redeems.dials;
    const pending_row = state.pending.getPtr(pending_id) orelse return false;
    const pending_ptr = switch (pending_row.*) {
        .dialing => |*dialing| dialing,
        .retiring => return false,
    };
    if (pending_ptr.cancel_requested) return false;
    const pending_view = pending_ptr.*;
    const losing_flights = pending_view.attempts.losingFlights(route_index);
    const waiter_count = pending_view.waiters.items.len;
    const redeem_only = !pending_view.application_owned and !selected;
    const cache_identity = if (pending_view.plan.source == .id)
        authenticated_identity
    else
        route_index == 0 or authenticated_identity;
    // Route advice is scoped to this exact exporter session and becomes live
    // only after that session answers the authenticated withdrawal. A weak
    // carrier still cannot populate the durable-identity cache above, but it
    // may preserve the route that reached the capability for a later give.
    const retain_route_advice = pending_view.plan.source == .id and
        pending_view.exporter_locator != null and
        gift_recipe.needsDiscovered(self, exporter_peer);
    const encoded_route_advice = if (retain_route_advice)
        try codec.signed.encodeLocatorRecord(self.allocator, pending_view.exporter_locator.?)
    else
        null;
    var encoded_route_advice_owned = encoded_route_advice != null;
    errdefer if (encoded_route_advice_owned) if (encoded_route_advice) |location|
        self.allocator.free(location);

    // Preflight the whole batch before consuming the pending row. Each waiter
    // then becomes a tracked withdrawal or an explicit terminal failure.
    const outcome_actions = std.math.add(
        usize,
        waiter_count,
        @intFromBool(redeem_only),
    ) catch return error.OutOfMemory;
    const batch_actions = std.math.add(
        usize,
        outcome_actions,
        @popCount(losing_flights),
    ) catch return error.OutOfMemory;
    if (cache_identity) try state.exporters.ensureUnusedCapacity(self.allocator, 1);
    const route_advice = if (retain_route_advice)
        try withdrawals.createEmptyRouteAdvice(self)
    else
        null;
    errdefer withdrawals.finishRouteAdviceSetup(self, route_advice);
    try self.redeems.withdrawals.rows.ensureUnusedCapacity(
        self.allocator,
        std.math.cast(u32, waiter_count) orelse return error.OutOfMemory,
    );
    try actions.reserve(self, batch_actions);

    var entry = pending_ptr.*;
    if (losing_flights == 0)
        std.debug.assert(state.pending.remove(pending_id))
    else
        pending_row.* = .{ .retiring = losing_flights };
    releaseWaiterReservations(self, entry.waiters.items.len);
    defer {
        for (entry.waiters.items) |waiter| self.allocator.free(waiter.give);
        entry.waiters.deinit(self.allocator);
    }
    std.debug.assert(state.by_identity.remove(entry.plan.identity));
    var cancel_routes = losing_flights;
    while (popRoute(&cancel_routes)) |losing_route| actions.pushReserved(self, .{
        .cancel_dial = .{
            .pending = pending_id,
            .route_index = losing_route,
        },
    });
    entry.plan.deinitPaths(self.allocator);
    if (entry.exporter_locator) |locator| {
        model.freePeerLocator(self.allocator, locator);
        entry.exporter_locator = null;
    }
    if (route_advice) |advice| {
        advice.location = encoded_route_advice.?;
        encoded_route_advice_owned = false;
    }
    if (cache_identity) {
        const cached = state.exporters.getOrPutAssumeCapacity(entry.plan.identity);
        if (cached.found_existing) {
            self.allocator.free(entry.plan.identity);
        } else {
            cached.value_ptr.* = exporter_peer;
        }
    } else {
        self.allocator.free(entry.plan.identity);
    }

    const slot = self.peers.getPtr(exporter_peer);
    if (slot) |live| live.provisional_exporter = redeem_only;
    for (entry.waiters.items) |waiter| {
        withdrawals.begin(self, exporter_peer, waiter.dest, waiter.give, route_advice) catch |err| switch (err) {
            error.OutOfMemory => actions.pushReserved(self, .{ .fail = .{
                .dest = redeem.failureDestination(waiter.dest),
                .reason = .{ .static = "handoff redeem failed: local allocation failure" },
            } }),
            error.OutboundAnswerSpaceExhausted => actions.pushReserved(self, .{ .fail = .{
                .dest = redeem.failureDestination(waiter.dest),
                .reason = .{ .static = "handoff redeem failed: local answer space exhausted" },
            } }),
        };
    }
    withdrawals.finishRouteAdviceSetup(self, route_advice);
    if (slot) |live| {
        if (redeem_only and live.pending_withdraw_count == 0)
            actions.pushReserved(self, .{ .retire_exporter = exporter_peer });
    }
    return true;
}

/// Claim a queued redeem-only exporter retirement at execution time.
pub fn claimExporterRetirement(self: *Node, exporter_peer: PeerHandle) bool {
    const slot = self.peers.getPtr(exporter_peer) orelse return false;
    if (!slot.provisional_exporter or slot.pending_withdraw_count != 0) return false;
    slot.provisional_exporter = false;
    evictExporterCache(self, exporter_peer);
    return true;
}

/// Report one route failure. Strong identity routes keep a bounded race window
/// full. Weak fallbacks remain serial. Every waiter settles only after the last
/// eligible route fails.
pub fn failed(self: *Node, pending: PendingId, route_index: usize, reason: []const u8) !Failure {
    const state = &self.redeems.dials;
    const pending_row = state.pending.getPtr(pending) orelse return .stale;
    const pending_view = switch (pending_row.*) {
        .dialing => |*dialing| dialing,
        .retiring => return .stale,
    };
    if (pending_view.cancel_requested) return .stale;
    if (route_index >= pending_view.plan.paths.len or
        !pending_view.attempts.acceptsCompletion(route_index)) return .stale;
    const waiter_count = pending_view.waiters.items.len;

    const next = pending_view.attempts.previewAfterFailure(pending_view.plan, route_index);
    switch (next) {
        .queue => try actions.reserve(self, 1),
        .waiting, .exhausted => {},
    }
    pending_view.attempts.commitFailure(route_index);
    switch (next) {
        .queue => |next_index| {
            pending_view.attempts.markScheduled(next_index);
            actions.pushReserved(self, .{ .dial = .{
                .pending = pending,
                .route_index = next_index,
            } });
            return .retry;
        },
        .waiting => return .waiting,
        .exhausted => {},
    }

    var buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buf,
        "handoff redeem failed: {s}",
        .{reason},
    ) catch "handoff redeem failed";
    // Preserve transport detail when memory permits; held action seats still
    // settle the complete batch with a static reason under allocator pressure.
    const owned_reasons: ?[][]u8 = stage_reasons: {
        if (waiter_count == 0) break :stage_reasons null;
        const reasons = self.allocator.alloc([]u8, waiter_count) catch
            break :stage_reasons null;
        var initialized: usize = 0;
        while (initialized < reasons.len) : (initialized += 1) {
            reasons[initialized] = self.allocator.dupe(u8, message) catch {
                for (reasons[0..initialized]) |owned| self.allocator.free(owned);
                self.allocator.free(reasons);
                break :stage_reasons null;
            };
        }
        break :stage_reasons reasons;
    };
    defer if (owned_reasons) |reasons| self.allocator.free(reasons);

    const removed = (state.pending.fetchRemove(pending) orelse return .stale).value;
    var entry = removed.dialing;
    releaseWaiterReservations(self, entry.waiters.items.len);
    defer {
        entry.plan.deinit(self.allocator);
        if (entry.exporter_locator) |locator| model.freePeerLocator(self.allocator, locator);
        for (entry.waiters.items) |waiter| self.allocator.free(waiter.give);
        entry.waiters.deinit(self.allocator);
    }
    std.debug.assert(state.by_identity.remove(entry.plan.identity));
    for (entry.waiters.items, 0..) |waiter, index| {
        const failure_reason: Node.FailureReason = if (owned_reasons) |reasons|
            .{ .owned = reasons[index] }
        else
            .{ .static = "handoff redeem failed: exporter dial failed" };
        actions.pushReserved(self, .{ .fail = .{
            .dest = redeem.failureDestination(waiter.dest),
            .reason = failure_reason,
        } });
    }
    return .exhausted;
}

/// Evict every canonical identity row naming a dead exporter session.
pub fn evictExporterCache(self: *Node, peer_handle: PeerHandle) void {
    var it = self.redeems.dials.exporters.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != peer_handle) continue;
        const identity = entry.key_ptr.*;
        self.redeems.dials.exporters.removeByPtr(entry.key_ptr);
        self.allocator.free(identity);
    }
}
