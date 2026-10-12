//! Host-owned capability promises used when a signed handoff give appears
//! inline in a Passable value. The Node owns cross-session redemption. This
//! module owns the application identity that exists while redemption is
//! pending and the eventual Host capability it resolves to. The row contract
//! shared with Host storage lives in `capability_promise/row.zig`.

const std = @import("std");
const capability_lower = @import("host/capabilities/lower.zig");

const actors = @import("actors");
const engine = @import("engine");
const model = @import("model");
const capability = @import("capability.zig");
const promise_projection = @import("capability_promise/projection.zig");
const promise_row = @import("capability_promise/row.zig");
const promise_values = @import("capability_promise/values.zig");
const host_mod = @import("host.zig");
const host_pump = @import("host/pump.zig");
const vows = @import("vows.zig");
const value_mod = @import("value.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const Row = promise_row.Row;

pub const prepareProjection = promise_projection.prepare;
pub const rollbackProjection = promise_projection.rollback;

/// Turn one inline signed give into an immediately usable Host identity and
/// start the same Node redemption transaction returned handoffs use. The row
/// is installed before the Node can queue a terminal action. Every refusal
/// before that point rolls both authorities back.
pub fn liftInlineGive(
    self: *Host,
    session: *HostSession,
    give: model.HandoffGive,
) !Host.CapabilityLift {
    var handoff: model.Handoff = .{ .give = give };
    const give_view = model.view.Handoff.fromOwned(&handoff).give;
    var projected = try engine.handoff_recipient.projectGiveForRedeem(self.allocator, give_view);
    defer projected.deinit(self.allocator);

    if (self.next_capability_promise == std.math.maxInt(u64))
        return error.CapabilitySpaceExhausted;
    const id: capability.PromiseId = @fromBackingInt(@intCast(self.next_capability_promise));
    try self.capability_promises.ensureUnusedCapacity(self.allocator, 1);
    const ref = try self.capabilities.retain(self.allocator, .{ .deferred = id });
    var ref_live = true;
    errdefer if (ref_live) {
        _ = self.capabilities.release(ref, 1) catch unreachable;
    };

    self.capability_promises.putAssumeCapacity(id, .{
        .introducing_peer = session.peer_handle,
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
    self.next_capability_promise += 1;
    ref_live = false;
    return .{ .ref = ref, .claimed_wire_retain = false };
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
            self.commitCapabilityLift(lifted);
            break :blk lifted;
        },
        .settling => |prepared| prepared,
        .fulfilled, .broken => return .done,
    };
    const resolved = lifted.ref;
    while (row.projections.items.len != 0) {
        const projection = row.projections.items[row.projections.items.len - 1];
        const recipient = self.sessions.get(projection.peer_handle) orelse {
            _ = row.projections.pop();
            continue;
        };
        var prepared = try self.prepareCapability(recipient, resolved);
        defer prepared.deinit();
        const outcome = try self.interceptFulfilledReference(
            recipient,
            projection.answer_target,
            prepared.reference(),
        );
        switch (outcome) {
            .claimed => {},
            .resolve => |projected| {
                recipient.served.port.peer.sendAnswerTargetResolutionCopying(
                    projection.answer_target,
                    .{ .fulfill = projected },
                ) catch |err| switch (err) {
                    // The prepared lift rolls back with `prepared`; the
                    // projection stays owed and the drain parks on this
                    // recipient (ADR-0145).
                    error.OutboundBackpressure => return .{ .parked_on = projection.peer_handle },
                    else => return err,
                };
                host_pump.markDirty(self, projection.peer_handle);
            },
        }
        _ = prepared.commit();
        _ = row.projections.pop();
    }
    while (true) {
        // A directly settled listen may run an in-process vow listener. Refetch
        // after every such callback instead of retaining a pointer across code
        // that may release this promise or rehash the Host tables.
        const current = self.capability_promises.getPtr(id) orelse return .done;
        if (current.operation_head >= current.operations.items.len) break;
        const pending = &current.operations.items[current.operation_head];
        if (pending.stage == .queued) {
            const source = self.sessions.get(pending.source_peer) orelse return error.UnknownCapability;
            const routed = try self.routeCapability(source, resolved, pending.action != .listen);
            try self.checkOutboundAdmission(routed.session);
            switch (pending.action) {
                .send => |*message| {
                    var prepared = try self.prepareValues(routed.session, message.arena.allocator(), message.values);
                    defer prepared.deinit();
                    try capability_lower.holdForTurn(self, &prepared);
                    const location: actors.VowLocation = switch (routed.target) {
                        .local => .local,
                        .far => .far,
                    };
                    const listener = try routed.session.served.port.reserveListener(&self.vat, location);
                    const observer_release = if (location == .far)
                        try vows.reserveDeferredObserverRelease(self, pending.result_vow.?, routed.session)
                    else
                        null;
                    var observer_release_live = observer_release != null;
                    errdefer if (observer_release_live)
                        routed.session.served.port.peer.cancelPendingReservation(observer_release.?);
                    const vow = try self.servedSendWithStaging(
                        routed.session,
                        routed.target,
                        .{ .verb = message.verb, .args = prepared.values },
                        message.arena.allocator(),
                        message.retained_capabilities,
                    );
                    self.attachDeferredVow(
                        pending.result_vow.?,
                        routed.session,
                        listener,
                        vow,
                        if (location == .far) .peer_visible else .none,
                        observer_release,
                    );
                    observer_release_live = false;
                    _ = prepared.commit();
                },
                .tell => |*message| {
                    var prepared = try self.prepareValues(routed.session, message.arena.allocator(), message.values);
                    defer prepared.deinit();
                    try capability_lower.holdForTurn(self, &prepared);
                    try self.servedTellWithStaging(
                        routed.session,
                        routed.target,
                        .{ .verb = message.verb, .args = prepared.values },
                        message.arena.allocator(),
                        message.retained_capabilities,
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
                        continue;
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
        }
        try releaseRetainedCapabilities(self, pending);
        if (pending.action == .tell) if (self.sessions.get(pending.source_peer)) |source|
            self.finishSessionOperation(source);
        pending.deinit();
        current.operation_head += 1;
    }
    const completed = self.capability_promises.getPtr(id) orelse return .done;
    completed.operations.clearRetainingCapacity();
    completed.operation_head = 0;
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
    completed.state = .{ .fulfilled = resolved };
    return .done;
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
    const row = self.capability_promises.getPtr(id) orelse return .done;
    const settling_ref: ?capability.Ref = switch (row.state) {
        .pending => null,
        .settling => |lifted| if (terminal) lifted.ref else return .done,
        .fulfilled, .broken => return .done,
    };
    while (row.projections.items.len != 0) {
        const projection = row.projections.items[row.projections.items.len - 1];
        const recipient = self.sessions.get(projection.peer_handle) orelse {
            _ = row.projections.pop();
            continue;
        };
        recipient.served.port.peer.sendAnswerTargetResolutionCopying(
            projection.answer_target,
            .{ .@"break" = .{ .message = reason } },
        ) catch |err| {
            if (!terminal) {
                if (err == error.OutboundBackpressure) return .{ .parked_on = projection.peer_handle };
                return err;
            }
            host_pump.condemnAndClose(
                self,
                recipient,
                .resource_exhausted,
                "failed terminal handoff-promise projection",
            );
            _ = row.projections.pop();
            continue;
        };
        host_pump.markDirty(self, projection.peer_handle);
        _ = row.projections.pop();
    }
    const failure = Row.Failure.init(reason);
    row.state = .{ .broken = failure };
    row.projections.deinit(self.allocator);
    row.projections = .empty;
    var operations = row.operations;
    const operation_head = row.operation_head;
    row.operations = .empty;
    row.operation_head = 0;
    const abandoned = row.abandoned;
    if (abandoned) std.debug.assert(self.capability_promises.remove(id));

    if (settling_ref) |ref| self.releaseCapabilityTerminal(ref, null);

    for (operations.items[operation_head..]) |pending| {
        var owned = pending;
        releaseRetainedCapabilitiesTerminal(self, &owned, null);
        if (owned.result_vow) |vow_id| self.fireVow(vow_id, .{ .broken = failure.message() });
        owned.deinit();
    }
    operations.deinit(self.allocator);
    return .done;
}

/// Mark a promise whose application identity was rolled back or finally
/// released. Pending Node work keeps the row only as a terminal recipient. A
/// fulfilled row releases the capability retain it owns immediately.
pub fn abandon(self: *Host, id: capability.PromiseId) void {
    const row = self.capability_promises.getPtr(id) orelse return;
    switch (row.state) {
        .pending, .settling => row.abandoned = true,
        .fulfilled => |ref| {
            self.releaseCapabilityTerminal(ref, null);
            row.projections.deinit(self.allocator);
            row.operations.deinit(self.allocator);
            std.debug.assert(self.capability_promises.remove(id));
        },
        .broken => {
            row.projections.deinit(self.allocator);
            row.operations.deinit(self.allocator);
            std.debug.assert(self.capability_promises.remove(id));
        },
    }
}

/// Admit one eventual send against a promise whose exporter session does not
/// exist yet. The Host vow is public immediately. The owned values stay
/// session-neutral until redemption selects the real route.
pub fn queueSendValues(
    self: *Host,
    id: capability.PromiseId,
    source: *HostSession,
    verb: []const u8,
    values: []const value_mod.Value,
) !u64 {
    return (try queueMessage(self, id, source, .send, verb, values)).?;
}

/// Admit one fire-and-forget delivery against an unresolved handoff promise.
/// There is no synthetic result: if the target later breaks,
/// the send-only message has no protocol recipient, like an ordinary
/// tell to a broken promise.
pub fn queueTellValues(
    self: *Host,
    id: capability.PromiseId,
    source: *HostSession,
    verb: []const u8,
    values: []const value_mod.Value,
) !void {
    _ = try queueMessage(self, id, source, .tell, verb, values);
}

const MessageKind = enum { send, tell };

fn queueMessage(
    self: *Host,
    id: capability.PromiseId,
    source: *HostSession,
    kind: MessageKind,
    verb: []const u8,
    values: []const value_mod.Value,
) !?u64 {
    try prepareOperationSlot(self, id, source);
    const row = self.capability_promises.getPtr(id) orelse unreachable;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer arena.deinit();
    var retained: std.ArrayListUnmanaged(Host.StagedCapabilityRetain) = .empty;
    errdefer promise_values.rollbackRetains(self, retained.items);
    const owned_verb = try arena.allocator().dupe(u8, verb);
    const owned_values = try promise_values.cloneValues(self, arena.allocator(), values, &retained);
    const result_vow = switch (kind) {
        .send => try self.mintDeferredVow(source, .{
            .owner = @backingInt(id),
            .func = cancelQueuedVow,
            .terminal_func = cancelQueuedVowTerminal,
        }),
        .tell => null,
    };
    const message: Row.PendingOperation.OwnedMessage = .{
        .arena = arena,
        .verb = owned_verb,
        .values = owned_values,
        .retained_capabilities = retained.items,
    };
    row.operations.appendAssumeCapacity(.{
        .source_peer = source.peer_handle,
        .result_vow = result_vow,
        .action = switch (kind) {
            .send => .{ .send = message },
            .tell => .{ .tell = message },
        },
    });
    if (kind == .tell) self.beginSessionOperation(source);
    return result_vow;
}

pub fn queueListen(self: *Host, id: capability.PromiseId, source: *HostSession) !u64 {
    try prepareOperationSlot(self, id, source);
    const row = self.capability_promises.getPtr(id) orelse unreachable;
    const vow_id = try self.mintDeferredVow(source, .{
        .owner = @backingInt(id),
        .func = cancelQueuedVow,
        .terminal_func = cancelQueuedVowTerminal,
    });
    row.operations.appendAssumeCapacity(.{
        .source_peer = source.peer_handle,
        .result_vow = vow_id,
        .action = .listen,
    });
    return vow_id;
}

fn prepareOperationSlot(self: *Host, id: capability.PromiseId, source: *HostSession) !void {
    try self.admitSessionOperation(source);
    try self.checkSession(source);
    const row = self.capability_promises.getPtr(id) orelse return error.UnknownCapability;
    if (row.state != .pending and row.state != .settling) return error.PromiseNotPending;
    if (row.operations.items.len - row.operation_head >= source.served.port.peer.limits().queue_cap)
        return error.QueueCapExceeded;
    try row.operations.ensureUnusedCapacity(self.allocator, 1);
}

// Break the Host pump's recursive inferred-error dependency: releasing a
// remote retain may itself finish committed pump work. The concrete errors
// remain unchanged and are propagated to the Node action for retry.
fn releaseRetainedCapabilities(self: *Host, pending: *Row.PendingOperation) anyerror!void {
    switch (pending.action) {
        .send, .tell => |*message| while (message.release_head < message.retained_capabilities.len) {
            const retained = message.retained_capabilities[message.release_head];
            if (!retained.transferred) try self.releaseCapability(retained.ref, 1);
            message.release_head += 1;
        },
        .listen => {},
    }
}

fn operationForVow(row: *const Row, vow_id: u64) usize {
    var index = row.operation_head;
    while (index < row.operations.items.len) : (index += 1) {
        if (row.operations.items[index].result_vow == vow_id) return index;
    }
    unreachable;
}

fn cancelQueuedVow(self: *Host, vow_id: u64, owner: u64) anyerror!void {
    const id: capability.PromiseId = @fromBackingInt(@intCast(owner));
    var row = self.capability_promises.getPtr(id) orelse unreachable;
    var index = operationForVow(row, vow_id);
    const pending = &row.operations.items[index];
    std.debug.assert(pending.stage == .queued);
    try releaseRetainedCapabilities(self, pending);

    row = self.capability_promises.getPtr(id) orelse unreachable;
    index = operationForVow(row, vow_id);
    var owned = row.operations.orderedRemove(index);
    std.debug.assert(owned.stage == .queued and owned.result_vow == vow_id);
    owned.deinit();
}

fn cancelQueuedVowTerminal(self: *Host, vow_id: u64, owner: u64) void {
    const id: capability.PromiseId = @fromBackingInt(@intCast(owner));
    const row = self.capability_promises.getPtr(id) orelse return;
    const index = operationForVow(row, vow_id);
    var owned = row.operations.orderedRemove(index);
    std.debug.assert(owned.stage == .queued and owned.result_vow == vow_id);
    releaseRetainedCapabilitiesTerminal(self, &owned, owned.source_peer);
    owned.deinit();
}

/// Retire every promise edge owned by a session before its Port is freed:
/// redemption authority, projections, queued sends, tells, and listeners.
pub fn sessionReleased(self: *Host, peer_handle: engine.PeerHandle, reason: []const u8) void {
    // The signed give names the introducing session's key as recipient. Once
    // that session closes, no future exporter dial may truthfully withdraw it.
    // Find one row at a time because terminal vow callbacks may mutate maps.
    while (true) {
        var introduced: ?capability.PromiseId = null;
        var promise_rows = self.capability_promises.iterator();
        while (promise_rows.next()) |entry| {
            if (entry.value_ptr.introducing_peer != peer_handle) continue;
            if (entry.value_ptr.state != .pending and entry.value_ptr.state != .settling) continue;
            introduced = entry.key_ptr.*;
            break;
        }
        const id = introduced orelse break;
        self.node.cancelInlineGive(peer_handle, @backingInt(id));
        // Terminal: every projection is broken or its recipient condemned, so
        // no recipient is ever returned to park on.
        std.debug.assert((breakPromiseImpl(self, id, reason, true) catch unreachable) == .done);
    }

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
        releaseRetainedCapabilitiesTerminal(self, &pending, peer_handle);
        if (pending.result_vow) |vow_id| if (self.vows.contains(vow_id))
            self.fireVow(vow_id, .{ .broken = reason });
        if (pending.action == .tell) if (self.sessions.get(pending.source_peer)) |source|
            self.finishSessionOperation(source);
        pending.deinit();
    }
}

pub fn resolvedRef(self: *Host, id: capability.PromiseId) !capability.Ref {
    const row = self.capability_promises.get(id) orelse return error.UnknownCapability;
    return switch (row.state) {
        .pending, .settling => error.PromisePending,
        .broken => error.PromiseBroken,
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
    }
    self.capability_promises.deinit(self.allocator);
    self.capability_promises = .empty;
}

fn releaseRetainedCapabilitiesTerminal(self: *Host, pending: *Row.PendingOperation, closing_peer: ?engine.PeerHandle) void {
    switch (pending.action) {
        .send, .tell => |*message| while (message.release_head < message.retained_capabilities.len) {
            const retained = message.retained_capabilities[message.release_head];
            if (!retained.transferred)
                self.releaseCapabilityTerminal(retained.ref, closing_peer);
            message.release_head += 1;
        },
        .listen => {},
    }
}
