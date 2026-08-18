//! Host-owned capability promises used when a signed handoff give appears
//! inline in a Passable value. The Node owns cross-session redemption; this
//! module owns the application identity that exists while redemption is
//! pending and the eventual Host capability it resolves to.

const std = @import("std");

const actors = @import("actors");
const engine = @import("engine");
const model = @import("model");
const capability = @import("capability.zig");
const promise_values = @import("capability_promise_values.zig");
const host_mod = @import("host.zig");
const host_pump = @import("host_pump.zig");
const value_mod = @import("value.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;

pub const Row = struct {
    /// The session whose signed give created this promise. Its session key is
    /// the recipient identity accepted by the exporter; closing that session
    /// therefore ends redemption authority even when another session has
    /// already pipelined through this Host identity.
    introducing_peer: engine.PeerId,
    state: State = .pending,
    abandoned: bool = false,
    projections: std.ArrayListUnmanaged(Projection) = .empty,
    operations: std.ArrayListUnmanaged(PendingOperation) = .empty,
    operation_head: usize = 0,

    pub const Projection = struct {
        peer_id: engine.PeerId,
        export_position: model.ExportPosition,
        answer_name: model.AnswerName,
    };

    pub const PendingOperation = struct {
        source_peer: engine.PeerId,
        result_vow: ?u64,
        stage: union(enum) {
            queued,
            dispatched: engine.PeerId,
        } = .queued,
        action: Action,

        pub const Action = union(enum) {
            send: OwnedMessage,
            tell: OwnedMessage,
            listen,
        };

        pub const OwnedMessage = struct {
            arena: std.heap.ArenaAllocator,
            verb: []const u8,
            values: []const value_mod.Value,
            retained_capabilities: []Host.StagedCapabilityRetain,
            release_head: usize = 0,
        };

        fn deinit(self: *PendingOperation) void {
            switch (self.action) {
                .send, .tell => |*message| {
                    std.debug.assert(message.release_head == message.retained_capabilities.len);
                    message.arena.deinit();
                },
                .listen => {},
            }
        }
    };

    pub const State = union(enum) {
        pending,
        settling: Host.CapabilityLift,
        fulfilled: capability.Ref,
        broken: Failure,
    };

    /// A handoff failure must survive the Node action that carried it without
    /// allocating at the terminal edge. The message is diagnostic text, not
    /// protocol data; retain a bounded UTF-8 prefix and keep the state typed.
    pub const Failure = struct {
        bytes: [256]u8 = undefined,
        len: u16 = 0,

        pub fn init(text: []const u8) Failure {
            var failure: Failure = .{};
            const limit = @min(text.len, failure.bytes.len);
            var end = limit;
            while (end != 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
            @memcpy(failure.bytes[0..end], text[0..end]);
            failure.len = @intCast(end);
            return failure;
        }

        pub fn message(self: *const Failure) []const u8 {
            return self.bytes[0..self.len];
        }
    };
};

pub const PreparedProjection = struct {
    reference: model.Reference,
    created: bool,
};

/// Turn one inline signed give into an immediately usable Host identity and
/// start the same Node redemption transaction returned handoffs use. The row
/// is installed before the Node can queue a terminal action; every refusal
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
    const id: capability.PromiseId = @enumFromInt(self.next_capability_promise);
    try self.capability_promises.ensureUnusedCapacity(self.allocator, 1);
    const ref = try self.capabilities.retain(self.allocator, .{ .deferred = id });
    var ref_live = true;
    errdefer if (ref_live) {
        _ = self.capabilities.release(ref, 1) catch unreachable;
    };

    self.capability_promises.putAssumeCapacity(id, .{
        .introducing_peer = session.peer_id,
    });
    errdefer std.debug.assert(self.capability_promises.remove(id));
    const locator = switch (projected.locator) {
        .uri => |uri| uri,
        .absent, .malformed => "",
    };
    try self.node.acceptInlineGive(
        session.peer_id,
        @intFromEnum(id),
        projected.bytes() orelse "",
        locator,
    );
    self.next_capability_promise += 1;
    ref_live = false;
    return .{ .ref = ref, .claimed_wire_retain = false };
}

/// Resolve the Node's routed capability into the ordinary Host capability the
/// promise row owns. The Node action is only consumed after this succeeds, so
/// allocation failure leaves the exact settlement retryable.
pub fn fulfill(self: *Host, id: capability.PromiseId, route_id: model.CapabilityRouteId) !void {
    const row = self.capability_promises.getPtr(id) orelse return;
    const lifted = switch (row.state) {
        .pending => blk: {
            const route = self.node.routeCapability(route_id) orelse return error.UnknownCapability;
            const session = self.sessions.get(route.peer_id) orelse return error.UnknownCapability;
            const lifted = try self.liftCapabilityTracked(
                session,
                .{ .routed = .{ .id = route_id } },
            );
            row.state = .{ .settling = lifted };
            self.commitCapabilityLift(lifted);
            break :blk lifted;
        },
        .settling => |prepared| prepared,
        .fulfilled, .broken => return,
    };
    const resolved = lifted.ref;
    while (row.projections.items.len != 0) {
        const projection = row.projections.items[row.projections.items.len - 1];
        const recipient = self.sessions.get(projection.peer_id) orelse {
            _ = row.projections.pop();
            continue;
        };
        var prepared = try self.prepareCapability(recipient, resolved);
        defer prepared.deinit();
        const outcome = try self.interceptFulfilledReference(
            recipient,
            projection.answer_name,
            prepared.reference(),
        );
        switch (outcome) {
            .claimed => {},
            .resolve => |projected| {
                try recipient.served.port.peer.sendAnswerResolutionCopying(
                    projection.answer_name,
                    .{ .fulfill = projected },
                );
                host_pump.markDirty(self, projection.peer_id);
            },
        }
        _ = prepared.commit();
        _ = row.projections.pop();
    }
    while (row.operation_head < row.operations.items.len) {
        const pending = &row.operations.items[row.operation_head];
        if (pending.stage == .queued) {
            const source = self.sessions.get(pending.source_peer) orelse return error.UnknownCapability;
            const routed = try self.routeCapability(source, resolved, pending.action != .listen);
            try self.checkOutboundAdmission(routed.session);
            switch (pending.action) {
                .send => |*message| {
                    var prepared = try self.prepareValues(routed.session, message.arena.allocator(), message.values);
                    defer prepared.deinit();
                    const location: actors.VowLocation = switch (routed.target) {
                        .local => .local,
                        .far => .far,
                    };
                    const listener = try routed.session.served.port.reserveListener(&self.vat, location);
                    const vow = try self.servedSendWithStaging(
                        routed.session,
                        routed.target,
                        .{ .verb = message.verb, .args = prepared.values },
                        message.arena.allocator(),
                        message.retained_capabilities,
                    );
                    self.attachDeferredVow(pending.result_vow.?, routed.session, listener, vow);
                    _ = prepared.commit();
                },
                .tell => |*message| {
                    var prepared = try self.prepareValues(routed.session, message.arena.allocator(), message.values);
                    defer prepared.deinit();
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
                    const wire = switch (routed.target) {
                        .local => return error.InvalidReference,
                        .far => |far| model.Reference{ .far = far },
                    };
                    const listener = try routed.session.served.port.reserveListener(&self.vat, .far);
                    const vow = try routed.session.served.listenTo(wire);
                    self.attachDeferredVow(pending.result_vow.?, routed.session, listener, vow);
                },
            }
            self.node.exporterApplicationOwned(routed.session.peer_id);
            host_pump.markDirty(self, routed.session.peer_id);
            pending.stage = .{ .dispatched = routed.session.peer_id };
        }
        try releaseRetainedCapabilities(self, pending);
        if (pending.action == .tell) if (self.sessions.get(pending.source_peer)) |source|
            self.finishSessionOperation(source);
        pending.deinit();
        row.operation_head += 1;
    }
    row.operations.clearRetainingCapacity();
    row.operation_head = 0;
    if (row.abandoned) {
        self.rollbackCapabilityLift(lifted);
        row.projections.deinit(self.allocator);
        row.operations.deinit(self.allocator);
        std.debug.assert(self.capability_promises.remove(id));
        return;
    }
    row.projections.deinit(self.allocator);
    row.projections = .empty;
    row.operations.deinit(self.allocator);
    row.operations = .empty;
    row.state = .{ .fulfilled = resolved };
}

pub fn breakPromise(self: *Host, id: capability.PromiseId, reason: []const u8) !void {
    return breakPromiseImpl(self, id, reason, false);
}

fn breakPromiseImpl(
    self: *Host,
    id: capability.PromiseId,
    reason: []const u8,
    terminal: bool,
) !void {
    const row = self.capability_promises.getPtr(id) orelse return;
    const settling_ref: ?capability.Ref = switch (row.state) {
        .pending => null,
        .settling => |lifted| if (terminal) lifted.ref else return,
        .fulfilled, .broken => return,
    };
    while (row.projections.items.len != 0) {
        const projection = row.projections.items[row.projections.items.len - 1];
        const recipient = self.sessions.get(projection.peer_id) orelse {
            _ = row.projections.pop();
            continue;
        };
        recipient.served.port.peer.sendAnswerResolutionCopying(
            projection.answer_name,
            .{ .@"break" = .{ .message = reason } },
        ) catch |err| {
            if (!terminal) return err;
            host_pump.condemnAndClose(
                self,
                recipient,
                .resource_exhausted,
                "failed terminal handoff-promise projection",
            );
            _ = row.projections.pop();
            continue;
        };
        host_pump.markDirty(self, projection.peer_id);
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
}

/// Mark a promise whose application identity was rolled back or finally
/// released. Pending Node work keeps the row only as a terminal recipient; a
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
/// exist yet. The Host vow is public immediately; the owned values stay
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
/// There is deliberately no synthetic result: if the target later breaks,
/// the send-only message has no protocol recipient, exactly like an ordinary
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
        .send => try self.mintDeferredVow(source),
        .tell => null,
    };
    const message: Row.PendingOperation.OwnedMessage = .{
        .arena = arena,
        .verb = owned_verb,
        .values = owned_values,
        .retained_capabilities = retained.items,
    };
    row.operations.appendAssumeCapacity(.{
        .source_peer = source.peer_id,
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
    const vow_id = try self.mintDeferredVow(source);
    row.operations.appendAssumeCapacity(.{
        .source_peer = source.peer_id,
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

/// Project a still-pending Host promise onto one session. The session owns the
/// paired export/answer rows once a surrounding send commits; `created` gives
/// that transaction exact rollback authority until then.
pub fn prepareProjection(self: *Host, id: capability.PromiseId, session: *HostSession) !PreparedProjection {
    const row = self.capability_promises.getPtr(id) orelse return error.UnknownCapability;
    if (row.state != .pending and row.state != .settling) return error.PromiseNotPending;
    for (row.projections.items) |projection| {
        if (projection.peer_id == session.peer_id) return .{
            .reference = .{ .near = model.NearRef.promise(projection.export_position.int()) },
            .created = false,
        };
    }
    try row.projections.ensureUnusedCapacity(self.allocator, 1);
    const projection = try session.served.port.peer.session_state.allocateLocalPromiseProjection();
    row.projections.appendAssumeCapacity(.{
        .peer_id = session.peer_id,
        .export_position = projection.export_position,
        .answer_name = projection.answer_name,
    });
    return .{
        .reference = .{ .near = model.NearRef.promise(projection.export_position.int()) },
        .created = true,
    };
}

pub fn rollbackProjection(self: *Host, id: capability.PromiseId, session: *HostSession, export_position: model.ExportPosition) void {
    const row = self.capability_promises.getPtr(id) orelse unreachable;
    for (row.projections.items, 0..) |projection, index| {
        if (projection.peer_id != session.peer_id or projection.export_position != export_position) continue;
        const removed = row.projections.swapRemove(index);
        std.debug.assert(removed.peer_id == session.peer_id and removed.export_position == export_position);
        session.served.port.peer.session_state.abandonLocalPromiseProjection(export_position);
        return;
    }
    unreachable;
}

/// Forget projections whose session is being destroyed. The session itself
/// owns and frees its export/answer tables; this only prevents a later redeem
/// from addressing the dead shell.
pub fn sessionReleased(self: *Host, peer_id: engine.PeerId, reason: []const u8) void {
    // The signed give names the introducing session's key as recipient. Once
    // that session closes, no future exporter dial may truthfully withdraw it.
    // Find one row at a time because terminal vow callbacks may mutate maps.
    while (true) {
        var introduced: ?capability.PromiseId = null;
        var promise_rows = self.capability_promises.iterator();
        while (promise_rows.next()) |entry| {
            if (entry.value_ptr.introducing_peer != peer_id) continue;
            if (entry.value_ptr.state != .pending and entry.value_ptr.state != .settling) continue;
            introduced = entry.key_ptr.*;
            break;
        }
        const id = introduced orelse break;
        self.node.cancelInlineGive(peer_id, @intFromEnum(id));
        breakPromiseImpl(self, id, reason, true) catch unreachable;
    }

    var rows = self.capability_promises.valueIterator();
    while (rows.next()) |row| {
        var index: usize = 0;
        while (index < row.projections.items.len) {
            if (row.projections.items[index].peer_id == peer_id) {
                const removed = row.projections.swapRemove(index);
                std.debug.assert(removed.peer_id == peer_id);
            } else index += 1;
        }
    }

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
                if (owner_peer != peer_id) continue;
                detached = row.operations.orderedRemove(index);
                break;
            }
            if (detached != null) break;
        }
        var pending = detached orelse break;
        releaseRetainedCapabilitiesTerminal(self, &pending, peer_id);
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

fn releaseRetainedCapabilitiesTerminal(self: *Host, pending: *Row.PendingOperation, closing_peer: ?engine.PeerId) void {
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
