//! Host-owned capability promises: a signed handoff give that appears inline
//! in a Passable value, a partner's pending answer passed as an argument, or
//! a public Host vow passed as one (ADR-0068). The Node owns cross-session
//! redemption, the answer's own session owns its settlement, and the vow row
//! owns its fire. This module owns the application identity that exists
//! while any is pending and the eventual settlement: a Host capability,
//! data, or a break. The row contract shared with Host storage lives in
//! `capability_promise/row.zig`, the answer subscription in
//! `capability_promise/answer.zig`, the vow watcher in
//! `capability_promise/vow.zig`, and the queued operations in
//! `capability_promise/operations.zig`.

const std = @import("std");
const capability_lower = @import("host/capabilities/lower.zig");

const actors = @import("actors");
const engine = @import("engine");
const model = @import("model");
const capability = @import("capability.zig");
const value_mod = @import("value.zig");
const promise_answer = @import("capability_promise/answer.zig");
const promise_operations = @import("capability_promise/operations.zig");
const promise_projection = @import("capability_promise/projection.zig");
const promise_row = @import("capability_promise/row.zig");
const promise_vow = @import("capability_promise/vow.zig");
const host_mod = @import("host.zig");
const host_pump = @import("host/pump.zig");
const vows = @import("vows.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const Row = promise_row.Row;

pub const prepareProjection = promise_projection.prepare;
pub const rollbackProjection = promise_projection.rollback;
pub const liftAnswer = promise_answer.lift;
pub const liftNearPromise = promise_answer.liftNearPromise;
pub const vowCapability = promise_vow.vowCapability;
pub const stageVowSettlement = promise_vow.stage;
pub const stageHeldSettlement = promise_vow.stageHeld;
pub const vowPromiseAwaitsStaging = promise_vow.awaitsStaging;
pub const vowAnswerReference = promise_vow.answerReference;
pub const listenData = promise_answer.listenData;
pub const vowMoved = promise_vow.moved;
pub const queueSendValues = promise_operations.queueSendValues;
pub const queueTellValues = promise_operations.queueTellValues;
pub const queueListen = promise_operations.queueListen;
const retireOperationTerminal = promise_operations.retireOperationTerminal;
const releaseRetainedCapabilities = promise_operations.releaseRetainedCapabilities;

/// Turn one inline signed give into an immediately usable Host identity and
/// start the same Node redemption transaction returned handoffs use. The row
/// is installed before the Node can queue a terminal action. Every refusal
/// before that point rolls both authorities back.
pub fn liftInlineGive(
    self: *Host,
    session: *HostSession,
    give: model.view.HandoffGive,
) !Host.CapabilityLift {
    const pending = self.pending_inline_gives.get(session.peer_handle) orelse 0;
    if (pending >= session.served.port.peer.session_state.limits.max_pending_withdraws)
        return error.PendingWithdrawCapExceeded;
    try self.pending_inline_gives.ensureUnusedCapacity(self.allocator, 1);
    var projected = try engine.handoff_recipient.projectGiveForRedeem(self.allocator, give);
    defer projected.deinit(self.allocator);

    const id: capability.PromiseId = @fromBackingInt(self.capability_promise_ids.peek() orelse
        return error.CapabilitySpaceExhausted);
    try self.capability_promises.ensureUnusedCapacity(self.allocator, 1);
    const ref = try self.capabilities.retain(self.allocator, .{ .deferred = id });
    var ref_live = true;
    errdefer if (ref_live) {
        _ = self.capabilities.release(ref, 1) catch unreachable;
    };

    self.capability_promises.putAssumeCapacity(id, .{
        .origin = .{ .inline_give = session.peer_handle },
    });
    errdefer std.debug.assert(self.capability_promises.remove(id));
    const locator = switch (projected.locator) {
        .uri => |uri| uri,
        .absent, .malformed => "",
    };
    try self.node.acceptInlineGive(
        session.peer_handle,
        @backingInt(id),
        projected.bytes() orelse "",
        locator,
    );
    self.capability_promise_ids.commit(@backingInt(id));
    ref_live = false;
    const seat = self.pending_inline_gives.getOrPutAssumeCapacity(session.peer_handle);
    if (!seat.found_existing) seat.value_ptr.* = 0;
    seat.value_ptr.* += 1;
    return .{ .ref = ref, .claimed_wire_retain = false };
}

/// A redemption settled, so its introducing session holds one fewer pending
/// inline give. Every pending row was counted when it was lifted, so the
/// entry is there, and the last settlement removes it. An answer-origin row
/// gives its seat back when it finishes, in `promise_answer.finished`.
/// The `promise_settled` action: what a promise stands for has settled, and
/// its origin finishes the row from what it stored.
pub fn finishSettlement(self: *Host, id: capability.PromiseId) !host_pump.ActionOutcome {
    const row = self.capability_promises.getPtr(id) orelse return .done;
    return switch (row.origin) {
        .answer => promise_answer.settle(self, id),
        .vow => promise_vow.settle(self, id),
        // An inline give settles through the Node's own `settle` action.
        .inline_give => unreachable,
    };
}

/// One more application retain on a promise that already exists for its
/// origin. A row the application had let go of is wanted again.
pub fn retainShared(self: *Host, id: capability.PromiseId) !Host.CapabilityLift {
    const row = self.capability_promises.getPtr(id) orelse unreachable;
    const ref = try self.capabilities.retain(self.allocator, .{ .deferred = id });
    row.abandoned = false;
    return .{ .ref = ref, .claimed_wire_retain = false };
}

/// A row reached its settlement or broke: release what its origin held for
/// the wait. An answer drops its subscription, and a vow drops its watch.
pub fn finishOrigin(self: *Host, id: capability.PromiseId, row: *Row) void {
    switch (row.origin) {
        .answer => |*answer| promise_answer.finished(self, answer),
        .vow => |*vow| promise_vow.finished(self, id, vow),
        .inline_give => {},
    }
}

/// Host teardown: give back what every row of `session` holds in the Peer
/// and the Node before either is freed. The rows themselves go with the map.
pub fn forgetSession(self: *Host, session: *HostSession) void {
    var rows = self.capability_promises.valueIterator();
    while (rows.next()) |row| switch (row.origin) {
        .answer => |*answer| if (answer.peer_handle == session.peer_handle) promise_answer.finished(self, answer),
        .vow => |*vow| if (vow.peer_handle == session.peer_handle) promise_vow.forget(self, vow),
        .inline_give => {},
    };
}

fn settledPending(self: *Host, row: *const Row) void {
    const introducing_peer = switch (row.origin) {
        .inline_give => |peer_handle| peer_handle,
        .answer, .vow => return,
    };
    const count = self.pending_inline_gives.getPtr(introducing_peer).?;
    count.* -= 1;
    if (count.* == 0) std.debug.assert(self.pending_inline_gives.remove(introducing_peer));
}

/// Resolve the Node's routed capability into the ordinary Host capability the
/// promise row owns. The Node action is only consumed after this succeeds, so
/// allocation failure leaves the exact settlement retryable. A projection
/// recipient whose outbound pressure stops the settle is reported with its
/// projection still owed, so the drain parks the action on that recipient.
pub fn fulfill(self: *Host, id: capability.PromiseId, route_id: model.CapabilityRouteId) !host_pump.ActionOutcome {
    const row = self.capability_promises.getPtr(id) orelse return .done;
    const lifted = switch (row.state) {
        .pending => blk: {
            const route = self.node.routeCapability(route_id) orelse return error.UnknownCapability;
            const session = self.sessions.get(route.peer_handle) orelse return error.UnknownCapability;
            const lifted = try self.liftCapabilityTracked(
                session,
                .{ .routed = .{ .id = route_id } },
            );
            row.state = .{ .settling = lifted };
            settledPending(self, row);
            self.commitCapabilityLift(lifted);
            break :blk lifted;
        },
        .settling => |prepared| prepared,
        .settling_data, .breaking, .fulfilled, .fulfilled_data, .broken => return .done,
    };
    return fulfillLifted(self, id, lifted);
}

/// Finish a promise whose settled capability is lifted and held in its
/// `settling` state: project it, dispatch what was queued, then settle the
/// row. Shared by inline-give redemption and answer settlement.
pub fn fulfillLifted(self: *Host, id: capability.PromiseId, lifted: Host.CapabilityLift) !host_pump.ActionOutcome {
    const resolved = lifted.ref;
    // Operations first: a listen settled in place runs an in-process
    // listener, which may pass the promise on and owe one more projection.
    try dispatchQueuedOperations(self, id, resolved);
    const row = self.capability_promises.getPtr(id) orelse return .done;
    if (try settleProjections(self, row, resolved)) |parked| return parked;
    row.operations.clearRetainingCapacity();
    row.operation_head = 0;
    finishOrigin(self, id, row);
    return completeFulfilled(self, id, lifted);
}

/// Whether a refusal met while settling a promise clears on a later pump.
/// Memory pressure and a recipient's outbound pressure do, so the action
/// stays at the Node queue head. Every other refusal names state only the
/// partner or the application changes, so the settle reports it where it
/// belongs, as the broken promise, vow, or projection, and the queue moves on.
pub fn retriesLater(err: anyerror) bool {
    return err == error.OutOfMemory or err == error.OutboundBackpressure;
}

/// The data a promise settled to, through promises that settled to other
/// promises. Null when the chain ends anywhere else.
pub fn settledData(self: *Host, id: capability.PromiseId) ?*const value_mod.Value {
    var current = id;
    while (true) {
        const row = self.capability_promises.getPtr(current) orelse return null;
        switch (row.state) {
            .fulfilled_data => |*data| return &data.value,
            .fulfilled => |ref| {
                const target = self.capabilities.resolve(ref) orelse return null;
                if (target != .deferred) return null;
                current = target.deferred;
            },
            .pending, .settling, .settling_data, .breaking, .broken => return null,
        }
    }
}

/// The last step of a fulfillment whose projections and operations are done:
/// an abandoned row leaves with its lift rolled back, and any other holds the
/// capability.
pub fn completeFulfilled(self: *Host, id: capability.PromiseId, lifted: Host.CapabilityLift) host_pump.ActionOutcome {
    const completed = self.capability_promises.getPtr(id) orelse return .done;
    if (completed.abandoned) {
        self.rollbackCapabilityLift(lifted);
        completed.projections.deinit(self.allocator);
        completed.operations.deinit(self.allocator);
        std.debug.assert(self.capability_promises.remove(id));
        return .done;
    }
    completed.projections.deinit(self.allocator);
    completed.projections = .empty;
    completed.operations.deinit(self.allocator);
    completed.operations = .empty;
    completed.state = .{ .fulfilled = lifted.ref };
    return .done;
}

/// The newest projection still owed to a live recipient. A projection whose
/// recipient has already left is dropped on the way.
pub fn nextOwedProjection(self: *Host, row: *Row) ?struct { projection: Row.Projection, recipient: *HostSession } {
    while (row.projections.items.len != 0) {
        const projection = row.projections.items[row.projections.items.len - 1];
        if (self.sessions.get(projection.peer_handle)) |recipient| return .{ .projection = projection, .recipient = recipient };
        _ = row.projections.pop();
    }
    return null;
}

/// Project the settled capability to every recipient it was promised to,
/// newest first. A recipient whose outbound pressure refuses the resolution
/// keeps its projection owed, and the settle parks on that recipient. One
/// that cannot hold the capability hears the refusal as its break.
fn settleProjections(self: *Host, row: *Row, resolved: capability.Ref) !?host_pump.ActionOutcome {
    while (nextOwedProjection(self, row)) |owed| {
        projectCapability(self, owed.recipient, owed.projection, resolved) catch |err| {
            if (err == error.OutboundBackpressure) return .{ .parked_on = owed.projection.peer_handle };
            if (retriesLater(err)) return err;
            breakProjection(self, owed.recipient, owed.projection, @errorName(err)) catch |break_err| {
                if (break_err == error.OutboundBackpressure) return .{ .parked_on = owed.projection.peer_handle };
                return break_err;
            };
        };
        host_pump.markDirty(self, owed.projection.peer_handle);
        _ = row.projections.pop();
    }
    return null;
}

/// Lower the capability into the recipient's session and resolve the
/// projection with it. The prepared lift rolls back on every refusal, so the
/// projection stays owed (ADR-0017).
fn projectCapability(self: *Host, recipient: *HostSession, projection: Row.Projection, resolved: capability.Ref) !void {
    var prepared = try self.prepareCapability(recipient, resolved);
    defer prepared.deinit();
    switch (try self.interceptFulfilledReference(recipient, projection.answer_target, prepared.reference())) {
        .claimed => {},
        .resolve => |projected| try recipient.served.port.peer.sendAnswerTargetResolutionViewCopying(
            projection.answer_target,
            model.view.Resolution{ .fulfill = projected },
        ),
    }
    _ = prepared.commit();
}

/// Resolve a projection broken, with the reason the recipient hears.
pub fn breakProjection(self: *Host, recipient: *HostSession, projection: Row.Projection, reason: []const u8) !void {
    try recipient.served.port.peer.sendAnswerTargetResolutionCopying(
        projection.answer_target,
        .{ .@"break" = .{ .message = reason } },
    );
    host_pump.markDirty(self, projection.peer_handle);
}

/// Dispatch every operation queued against the promise while it was
/// pending. A directly settled listen may run an in-process vow listener, so
/// the row is refetched after every operation instead of holding a pointer
/// across code that may release this promise or rehash the Host tables.
fn dispatchQueuedOperations(self: *Host, id: capability.PromiseId, resolved: capability.Ref) !void {
    while (true) {
        const current = self.capability_promises.getPtr(id) orelse return;
        if (current.operation_head >= current.operations.items.len) return;
        const pending = &current.operations.items[current.operation_head];
        if (pending.stage == .queued) switch (dispatchQueued(self, current, pending, resolved) catch |err| {
            if (retriesLater(err)) return err;
            // The operation cannot reach what the promise settled to, as a
            // send to the capability itself could not. Its vow hears why.
            var owned = current.operations.items[current.operation_head];
            current.operation_head += 1;
            retireOperationTerminal(self, &owned, @errorName(err), null);
            continue;
        }) {
            .dispatched => {},
            .settled_in_place => continue,
        };
        try releaseRetainedCapabilities(self, pending);
        if (pending.action == .tell) if (self.sessions.get(pending.source_peer)) |source|
            self.finishSessionOperation(source);
        pending.deinit();
        current.operation_head += 1;
    }
}

/// A queued operation either went out on the capability's home session and
/// now awaits that session, or was a listen the Host settled in place, which
/// consumed its own row entry.
const Dispatched = enum { dispatched, settled_in_place };

fn dispatchQueued(self: *Host, current: *Row, pending: *Row.PendingOperation, resolved: capability.Ref) !Dispatched {
    const source = self.sessions.get(pending.source_peer) orelse return error.UnknownCapability;
    const routed = try self.routeCapability(source, resolved, .any_target);
    try self.checkOutboundAdmission(routed.session);
    switch (pending.action) {
        .send => |*message| try dispatchQueuedSend(self, routed, message, pending.result_vow.?),
        .tell => |*message| {
            var prepared = try self.prepareValues(routed.session, message.arena.allocator(), message.values);
            defer prepared.deinit();
            try capability_lower.holdForTurn(self, &prepared);
            try self.servedTellWithStaging(
                routed.session,
                routed.target,
                .{ .verb = message.verb, .args = prepared.values },
                &prepared,
            );
            _ = prepared.commit();
        },
        .listen => {
            if (routed.target == .local or routed.target.far.kind == .object) {
                const vow_id = pending.result_vow.?;
                // The resolution belongs to its home session, just as a
                // deferred wire listen does after attachDeferredVow.
                // Moving first keeps completion projection on that
                // session and avoids manufacturing a foreign route only
                // to consume it again inside this Host.
                self.moveDeferredVow(vow_id, routed.session);
                var prepared = try self.prepareCapability(routed.session, resolved);
                defer prepared.deinit();
                pending.deinit();
                current.operation_head += 1;
                const reference = prepared.commit();
                self.fireVow(vow_id, .{ .fulfilled = .{ .reference = reference } });
                return .settled_in_place;
            }
            const wire = switch (routed.target) {
                .local => return error.InvalidReference,
                .far => |far| model.Reference{ .far = far },
            };
            const listener = try routed.session.served.port.reserveListener(&self.vat, .far);
            const vow = try routed.session.served.listenTo(wire);
            self.attachDeferredVow(
                pending.result_vow.?,
                routed.session,
                listener,
                vow,
                .session_private,
                null,
            );
        },
    }
    self.node.exporterApplicationOwned(routed.session.peer_handle);
    host_pump.markDirty(self, routed.session.peer_handle);
    pending.stage = .{ .dispatched = routed.session.peer_handle };
    return .dispatched;
}

/// A queued send goes out with its result vow attached to the home session's
/// listener, and a far target also reserves the observer release the vow's
/// settlement will send.
fn dispatchQueuedSend(self: *Host, routed: Host.RoutedSend, message: *Row.PendingOperation.OwnedMessage, result_vow: u64) !void {
    var prepared = try self.prepareValues(routed.session, message.arena.allocator(), message.values);
    defer prepared.deinit();
    try capability_lower.holdForTurn(self, &prepared);
    const location: actors.VowLocation = switch (routed.target) {
        .local => .local,
        .far => .far,
    };
    const listener = try routed.session.served.port.reserveListener(&self.vat, location);
    const observer_release = if (location == .far)
        try vows.reserveDeferredObserverRelease(self, result_vow, routed.session)
    else
        null;
    var observer_release_live = observer_release != null;
    errdefer if (observer_release_live)
        routed.session.served.port.peer.cancelPendingReservation(observer_release.?);
    const vow = try self.servedSendWithStaging(
        routed.session,
        routed.target,
        .{ .verb = message.verb, .args = prepared.values },
        &prepared,
    );
    self.attachDeferredVow(
        result_vow,
        routed.session,
        listener,
        vow,
        if (location == .far) .peer_visible else .none,
        observer_release,
    );
    observer_release_live = false;
    _ = prepared.commit();
}

/// Break the promise toward every projection, parking on a recipient whose
/// outbound pressure stops it, as `fulfill` does.
pub fn breakPromise(self: *Host, id: capability.PromiseId, reason: []const u8) !host_pump.ActionOutcome {
    return breakPromiseImpl(self, id, reason, false);
}

fn breakPromiseImpl(
    self: *Host,
    id: capability.PromiseId,
    reason: []const u8,
    terminal: bool,
) !host_pump.ActionOutcome {
    var row = self.capability_promises.getPtr(id) orelse return .done;
    var settling_ref: ?capability.Ref = null;
    var settling_data: ?Row.SettledData = null;
    switch (row.state) {
        .pending, .breaking => {},
        .settling => |lifted| if (terminal) {
            settling_ref = lifted.ref;
        } else return .done,
        .settling_data => |data| if (terminal) {
            settling_data = data;
        } else return .done,
        .fulfilled, .fulfilled_data, .broken => return .done,
    }
    const was_pending = row.state == .pending;
    while (nextOwedProjection(self, row)) |owed| {
        const projection = owed.projection;
        const recipient = owed.recipient;
        recipient.served.port.peer.sendAnswerTargetResolutionCopying(
            projection.answer_target,
            .{ .@"break" = .{ .message = reason } },
        ) catch |err| {
            if (!terminal) {
                if (err == error.OutboundBackpressure) return .{ .parked_on = projection.peer_handle };
                return err;
            }
            // Detach this exact projection before condemnation can fire a
            // listener that appends another projection or rehashes the map.
            _ = row.projections.pop();
            host_pump.condemnAndClose(
                self,
                recipient,
                .resource_exhausted,
                "failed terminal handoff-promise projection",
            );
            row = self.capability_promises.getPtr(id) orelse return .done;
            continue;
        };
        host_pump.markDirty(self, projection.peer_handle);
        _ = row.projections.pop();
    }
    const failure = Row.Failure.init(reason);
    row.state = .{ .broken = failure };
    if (was_pending) settledPending(self, row);
    finishOrigin(self, id, row);
    row.projections.deinit(self.allocator);
    row.projections = .empty;
    var operations = row.operations;
    const operation_head = row.operation_head;
    row.operations = .empty;
    row.operation_head = 0;
    const abandoned = row.abandoned;
    if (abandoned) std.debug.assert(self.capability_promises.remove(id));

    if (settling_ref) |ref| self.releaseCapabilityTerminal(ref, null);
    if (settling_data) |*data| promise_answer.releaseData(self, data, null);

    for (operations.items[operation_head..]) |pending| {
        var owned = pending;
        retireOperationTerminal(self, &owned, failure.message(), null);
    }
    operations.deinit(self.allocator);
    return .done;
}

/// Mark a promise whose application identity was rolled back or finally
/// released. Pending Node work keeps the row only as a terminal recipient. A
/// fulfilled row releases the capability retain it owns immediately.
pub fn abandon(self: *Host, id: capability.PromiseId) void {
    const row = self.capability_promises.getPtr(id) orelse return;
    var resolved: ?capability.Ref = null;
    var data: ?Row.SettledData = null;
    switch (row.state) {
        .pending => {
            // A lifted answer or watched vow nothing waits on, with no
            // application retain, no owed projection, and no queued
            // operation, leaves at once instead of holding its seat to the
            // settlement. One a settle has begun keeps its state.
            if (row.origin != .inline_give and row.projections.items.len == 0 and row.operation_head >= row.operations.items.len) {
                finishOrigin(self, id, row);
                row.projections.deinit(self.allocator);
                row.operations.deinit(self.allocator);
                std.debug.assert(self.capability_promises.remove(id));
                return;
            }
            row.abandoned = true;
            return;
        },
        .settling, .settling_data, .breaking => {
            row.abandoned = true;
            return;
        },
        .fulfilled => |ref| resolved = ref,
        .fulfilled_data => |settled| data = settled,
        .broken => {},
    }
    row.projections.deinit(self.allocator);
    row.operations.deinit(self.allocator);
    std.debug.assert(self.capability_promises.remove(id));
    // Terminal GC failure may condemn the home and invoke listeners that
    // grow this map. Finish retiring its row before releasing the result.
    if (resolved) |ref| self.releaseCapabilityTerminal(ref, null);
    if (data) |*settled| promise_answer.releaseData(self, settled, null);
}

/// Retire every promise edge owned by a session before its Port is freed:
/// redemption authority, projections, queued sends, tells, and listeners.
pub fn sessionReleased(self: *Host, peer_handle: engine.PeerHandle, reason: []const u8) void {
    // The signed give names the introducing session's key as recipient. Once
    // that session closes, no future exporter dial may truthfully withdraw it.
    // An answer the closed session owed has nothing left to settle it. Find
    // one row at a time because terminal vow callbacks may mutate maps.
    while (true) {
        var introduced: ?capability.PromiseId = null;
        var promise_rows = self.capability_promises.iterator();
        while (promise_rows.next()) |entry| {
            if (entry.value_ptr.origin.peer() != peer_handle) continue;
            if (!entry.value_ptr.state.awaitsSettlement()) continue;
            introduced = entry.key_ptr.*;
            break;
        }
        const id = introduced orelse break;
        if (self.capability_promises.get(id).?.origin == .inline_give)
            self.node.cancelInlineGive(peer_handle, @backingInt(id));
        // Terminal: every projection is broken or its recipient condemned, so
        // no recipient is ever returned to park on.
        std.debug.assert((breakPromiseImpl(self, id, reason, true) catch unreachable) == .done);
    }

    std.debug.assert(!self.pending_inline_gives.contains(peer_handle));

    promise_projection.forgetSession(self, peer_handle);

    // A listener may enqueue more Host work and rehash the promise map. Detach
    // one operation before each callback and restart the scan. Teardown is a
    // cold path; an extra scan is preferable to a second lifecycle index.
    while (true) {
        var detached: ?Row.PendingOperation = null;
        var send_rows = self.capability_promises.valueIterator();
        while (send_rows.next()) |row| {
            var index = row.operation_head;
            while (index < row.operations.items.len) : (index += 1) {
                const pending = row.operations.items[index];
                const owner_peer = if (pending.action == .tell)
                    pending.source_peer
                else switch (pending.stage) {
                    .queued => pending.source_peer,
                    .dispatched => |target_peer| target_peer,
                };
                if (owner_peer != peer_handle) continue;
                detached = row.operations.orderedRemove(index);
                break;
            }
            if (detached != null) break;
        }
        var pending = detached orelse break;
        retireOperationTerminal(self, &pending, reason, peer_handle);
    }
}

pub fn resolvedRef(self: *Host, id: capability.PromiseId) !capability.Ref {
    const row = self.capability_promises.get(id) orelse return error.UnknownCapability;
    return switch (row.state) {
        .pending, .settling, .settling_data => error.PromisePending,
        .breaking, .broken => error.PromiseBroken,
        // Data is not a target. The listen path reads it.
        .fulfilled_data => error.UncallableTarget,
        .fulfilled => |ref| if (self.capabilities.resolve(ref) != null)
            ref
        else
            error.UnknownCapability,
    };
}

pub fn deinit(self: *Host) void {
    var rows = self.capability_promises.valueIterator();
    while (rows.next()) |row| {
        for (row.operations.items[row.operation_head..]) |*pending| {
            // Host destruction collapses the capability registry, every
            // session, and the Vat as one ownership barrier. Emitting wire GC
            // or releasing actor roots here would address owners that the
            // outer teardown has already destroyed; free only this row's
            // private storage and let those aggregate owners deinit once.
            switch (pending.action) {
                .send, .tell => |*message| message.arena.deinit(),
                .listen => {},
            }
        }
        row.operations.deinit(self.allocator);
        row.projections.deinit(self.allocator);
        switch (row.state) {
            .settling_data, .fulfilled_data => |*data| data.arena.deinit(),
            .pending, .settling, .breaking, .fulfilled, .broken => {},
        }
    }
    self.capability_promises.deinit(self.allocator);
    self.capability_promises = .empty;
    self.pending_inline_gives.deinit(self.allocator);
    self.pending_inline_gives = .empty;
}
