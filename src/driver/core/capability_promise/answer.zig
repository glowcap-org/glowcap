//! A partner's pending answer, passed as an argument, lifted to a Host
//! capability promise (ADR-0068).
//!
//! The row subscribes to the inbound answer through one retain on its payload
//! and the payload's `host_promise` mark, so the same question passed twice is
//! one capability and the stored resolution outlives the partner's GC of the
//! position. The Peer publishes one `promise_settled` Node action when the
//! settlement leaves, on a seat reserved at the first subscription, and the
//! Host follows the stored resolution chain to its end: a reference lifts as an
//! ordinary capability, data settles the row to data, a break breaks it, and a
//! further pending answer moves the subscription.

const std = @import("std");

const engine = @import("engine");
const model = @import("model");

const capability = @import("../capability.zig");
const capability_lift = @import("../host/capabilities/lift.zig");
const capability_lower = @import("../host/capabilities/lower.zig");
const identity = @import("../host/capabilities/identity.zig");
const capability_promise = @import("../capability_promise.zig");
const operations = @import("operations.zig");
const promise_values = @import("values.zig");
const promise_row = @import("row.zig");
const host_mod = @import("../host.zig");
const host_pump = @import("../host/pump.zig");
const PendingCancel = @import("../vows/settlement.zig").PendingCancel;
const value_mod = @import("../value.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const Row = promise_row.Row;
const Answer = Row.Origin.Answer;

/// The reason a send to a promise that settled to data breaks with: the one a
/// message to a non-object gets.
pub const uncallable_reason = @errorName(error.UncallableTarget);

/// Whether a stored terminal names a partner object this side released since
/// it sent the resolution: the engine's released-target rule applied to the
/// whole value a lift would own, a bare reference or data with references
/// inside it.
fn namesReleasedImport(session: *HostSession, value: model.Argument) bool {
    return engine.resolution_chain.namesReleasedImport(session.served.port.peer, value);
}

/// Lift one answer reference inside a value the partner delivered. The answer
/// is one of this session's own open questions, named by its position.
pub fn lift(
    self: *Host,
    session: *HostSession,
    answer_position: model.AnswerPosition,
) capability_lift.LiftError!Host.CapabilityLift {
    const peer = session.served.port.peer;
    const target = peer.session_state.answerTargetNamed(.{ .wire = answer_position }) orelse
        return error.InvalidReference;
    return liftTarget(self, session, target);
}

/// Lift a reference to an export of ours that serves no actor. The one such
/// export is the local promise a projection stands for, whose virtual answer
/// is an inbound answer like any other: it lifts as a partner's question
/// does and settles when the projection resolves. Any other export is no
/// actor at all.
pub fn liftNearPromise(
    self: *Host,
    session: *HostSession,
    export_position: model.ExportPosition,
) capability_lift.LiftError!Host.CapabilityLift {
    const peer = session.served.port.peer;
    const name = peer.session_state.answerForLocalPromiseExport(export_position) orelse return error.NoSuchActor;
    // A projection this Host still owes names the promise that owes it, and
    // the same promise coming back is one capability. The walk is over the
    // Host's promise rows, on the rare path of a projection returning before
    // it settles. A settled one lifts as what its answer settled to.
    var rows = self.capability_promises.iterator();
    while (rows.next()) |entry| for (entry.value_ptr.projections.items) |projection| {
        if (projection.peer_handle == session.peer_handle and projection.export_position == export_position)
            return capability_promise.retainShared(self, entry.key_ptr.*);
    };
    const target = peer.session_state.answerTargetNamed(name) orelse return error.InvalidReference;
    return liftTarget(self, session, target);
}

/// An answer already settled lifts as what it settled to. One with a promise
/// subscribed shares that promise. Otherwise a new promise subscribes.
fn liftTarget(
    self: *Host,
    session: *HostSession,
    target: engine.AnswerTarget,
) capability_lift.LiftError!Host.CapabilityLift {
    const peer = session.served.port.peer;
    if (peer.session_state.answerPayloadForTarget(target)) |payload| {
        if (peer.session_state.answerPayloadStoredResolution(payload) != null)
            return liftSettled(self, session, target, engine.resolution_chain.followAnswer(peer, target, payload));
        if (payload.host_promise != 0) return capability_promise.retainShared(self, @fromBackingInt(payload.host_promise));
    }
    return liftPending(self, session, target);
}

/// The lift of an answer whose chain already ends: a reference shortens to
/// the capability itself, data and a break lift as a settled promise, and a
/// chain that ends at another open question subscribes to that one.
fn liftSettled(
    self: *Host,
    session: *HostSession,
    target: engine.AnswerTarget,
    outcome: engine.resolution_chain.Outcome,
) capability_lift.LiftError!Host.CapabilityLift {
    const origin: Row.Origin = .{ .answer = .{ .peer_handle = session.peer_handle, .target = target, .payload = null } };
    switch (outcome) {
        .terminal => |terminal| switch (terminal.resolution) {
            .fulfill => |argument| if (namesReleasedImport(session, argument))
                return settledRow(self, origin, .{ .broken = Row.Failure.init(engine.resolution_chain.released_target_message) })
            else switch (argument) {
                .reference => |reference| switch (reference) {
                    .near, .far, .routed => return identity.liftCapabilityTracked(self, session, reference),
                    // A chain ends at a promise only through a pending outcome.
                    .promise => unreachable,
                    .sturdy => return settledRow(self, origin, .{ .broken = Row.Failure.init(uncallable_reason) }),
                    .broken => |broken| return settledRow(self, origin, .{ .broken = Row.Failure.init(broken.message) }),
                },
                else => {
                    var data = ownData(self, session, argument) catch |err| switch (err) {
                        error.OutOfMemory => return err,
                        // Data this Host cannot receive, such as a reference
                        // inside it that names no object, breaks the promise.
                        else => |refusal| return settledRow(self, origin, .{ .broken = Row.Failure.init(@errorName(refusal)) }),
                    };
                    errdefer releaseData(self, &data, null);
                    return settledRow(self, origin, .{ .fulfilled_data = data });
                },
            },
            .@"break" => |reason| return settledRow(self, origin, .{ .broken = Row.Failure.init(reason.message) }),
        },
        .terminal_break => |message| return settledRow(self, origin, .{ .broken = Row.Failure.init(message) }),
        .pending => |next| return liftTarget(self, session, next),
    }
}

/// A row that holds its settlement from the start. It subscribes to nothing
/// and counts against no bound: the application's retains are its lifetime.
fn settledRow(self: *Host, origin: Row.Origin, state: Row.State) !Host.CapabilityLift {
    const reservation = try capability_promise.reserveRow(self);
    return reservation.commit(self, .{ .origin = origin, .state = state });
}

/// Subscribe a new promise to a pending answer: the session's subscription,
/// which holds the bound and the payload retain, the Node seat, and the
/// registry row, each rolled back by a later refusal.
fn liftPending(
    self: *Host,
    session: *HostSession,
    target: engine.AnswerTarget,
) capability_lift.LiftError!Host.CapabilityLift {
    const peer = session.served.port.peer;
    const reservation = try capability_promise.reserveRow(self);
    const payload = try peer.session_state.subscribeHostPromise(target, @backingInt(reservation.id));
    errdefer peer.session_state.unsubscribeHostPromise(target, payload);
    try self.node.reservePromiseSettlement();
    errdefer self.node.releasePromiseSettlement();
    return reservation.commit(self, .{ .origin = .{ .answer = .{
        .peer_handle = session.peer_handle,
        .target = target,
        .payload = payload,
    } } });
}

/// The `promise_settled` action: the answer a promise stands for has settled.
/// Memory or outbound pressure leaves the action retryable, and a projection
/// recipient's backpressure parks it as an inline give's settle does. Any other
/// refusal met before the row changes state breaks the promise with it, since
/// repeating the action could not change the answer.
pub fn settle(self: *Host, id: capability.PromiseId) !host_pump.ActionOutcome {
    const row = self.capability_promises.getPtr(id) orelse return .done;
    const answer = switch (row.origin) {
        .answer => |answer| answer,
        .inline_give, .vow => unreachable,
    };
    const session = self.sessions.get(answer.peer_handle) orelse return .done;
    const peer = session.served.port.peer;
    switch (row.state) {
        .pending => {},
        .settling => |lifted| return capability_promise.fulfillLifted(self, id, lifted),
        .settling_data => return finishData(self, id),
        // Only a vow holds a break for the pump.
        .breaking => unreachable,
        .fulfilled, .fulfilled_data, .broken => return .done,
    }
    const payload = answer.payload orelse unreachable;
    switch (engine.resolution_chain.followAnswer(peer, answer.target, payload)) {
        .terminal => |terminal| switch (terminal.resolution) {
            .fulfill => |argument| if (namesReleasedImport(session, argument))
                return capability_promise.breakPromise(self, id, engine.resolution_chain.released_target_message)
            else switch (argument) {
                .reference => |reference| switch (reference) {
                    .near, .far, .routed => {
                        const lifted = identity.liftCapabilityTracked(self, session, reference) catch |err| {
                            if (capability_promise.retriesLater(err)) return err;
                            return capability_promise.breakPromise(self, id, @errorName(err));
                        };
                        row.state = .{ .settling = lifted };
                        self.commitCapabilityLift(lifted);
                        return capability_promise.fulfillLifted(self, id, lifted);
                    },
                    .promise => unreachable,
                    .sturdy => return capability_promise.breakPromise(self, id, uncallable_reason),
                    .broken => |broken| return capability_promise.breakPromise(self, id, broken.message),
                },
                else => return fulfillData(self, id, session, argument),
            },
            .@"break" => |reason| return capability_promise.breakPromise(self, id, reason.message),
        },
        .terminal_break => |message| return capability_promise.breakPromise(self, id, message),
        .pending => |next| return moveSubscription(self, id, session, next) catch |err| {
            if (capability_promise.retriesLater(err)) return err;
            return capability_promise.breakPromise(self, id, @errorName(err));
        },
    }
}

/// The answer resolved to another of the session's open questions. A promise
/// already subscribed to that one absorbs this row's work, and this row
/// settles to it. One that is this promise's own projection back to the
/// partner closes a loop nothing outside it settles, so the promise breaks.
/// Otherwise the subscription moves, with every fallible step before the
/// row changes, so a refusal leaves it subscribed where it was.
fn moveSubscription(
    self: *Host,
    id: capability.PromiseId,
    session: *HostSession,
    next: engine.AnswerTarget,
) !host_pump.ActionOutcome {
    const peer = session.served.port.peer;
    if (peer.session_state.answerPayloadForTarget(next)) |shared| if (shared.host_promise != 0)
        return fulfillWithPromise(self, id, @fromBackingInt(shared.host_promise));
    const row = self.capability_promises.getPtr(id) orelse unreachable;
    for (row.projections.items) |projection| {
        if (projection.peer_handle == session.peer_handle and std.meta.eql(projection.answer_target, next))
            return capability_promise.breakPromise(self, id, engine.resolution_chain.cycle_message);
    }
    const answer = &row.origin.answer;
    try self.node.reservePromiseSettlement();
    errdefer self.node.releasePromiseSettlement();
    const next_payload = try peer.session_state.moveHostPromise(answer.target, answer.payload.?, next, @backingInt(id));
    answer.target = next;
    answer.payload = next_payload;
    return .done;
}

/// Settle `id` to the promise `target`, which stands for the same eventual
/// answer: queued operations and owed projections move to the target row and
/// `id` fulfills with a retain on it, so routing follows the chain.
fn fulfillWithPromise(self: *Host, id: capability.PromiseId, target: capability.PromiseId) !host_pump.ActionOutcome {
    const row = self.capability_promises.getPtr(id) orelse unreachable;
    const target_row = self.capability_promises.getPtr(target) orelse unreachable;
    std.debug.assert(target_row.state.isPending());
    const moved = row.operations.items[row.operation_head..];
    try target_row.operations.ensureUnusedCapacity(self.allocator, moved.len);
    try target_row.projections.ensureUnusedCapacity(self.allocator, row.projections.items.len);
    const ref = try self.capabilities.retain(self.allocator, .{ .deferred = target });
    target_row.abandoned = false;
    for (moved) |pending| {
        if (pending.result_vow) |vow_id| operations.reown(self, vow_id, target);
        target_row.operations.appendAssumeCapacity(pending);
    }
    target_row.projections.appendSliceAssumeCapacity(row.projections.items);
    row.operations.clearRetainingCapacity();
    row.operation_head = 0;
    row.projections.clearRetainingCapacity();
    finished(self, &row.origin.answer);
    return capability_promise.completeFulfilled(self, id, .{ .ref = ref, .claimed_wire_retain = false });
}

/// Own the settled data under the origin session, then finish what was
/// queued against the promise. The data is held in the row across a park.
/// Data this Host cannot receive breaks the promise, as `liftSettled` does.
fn fulfillData(
    self: *Host,
    id: capability.PromiseId,
    session: *HostSession,
    argument: model.Argument,
) !host_pump.ActionOutcome {
    const data = ownData(self, session, argument) catch |err| {
        if (capability_promise.retriesLater(err)) return err;
        return capability_promise.breakPromise(self, id, @errorName(err));
    };
    const row = self.capability_promises.getPtr(id) orelse unreachable;
    row.state = .{ .settling_data = data };
    return finishData(self, id);
}

/// Own `argument` under `session`: one arena holds the value, and every
/// capability inside it holds a Host retain. The vow origin stages its data
/// settlement through this too.
pub fn ownData(self: *Host, session: *HostSession, argument: model.Argument) !Row.SettledData {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer arena.deinit();
    const value = try capability_lift.ownValue(self, session, arena.allocator(), argument);
    return .{ .arena = arena, .value = value };
}

/// Own a clone of `value` for a promise: a Host retain per capability inside
/// it, and one arena for the rest. The vow origin stages a completion its row
/// kept through this (ADR-0068), since the row keeps its own copy for a later
/// ask.
pub fn cloneData(self: *Host, value: value_mod.Value) !Row.SettledData {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    errdefer arena.deinit();
    var retained: std.ArrayListUnmanaged(capability.Ref) = .empty;
    errdefer promise_values.rollbackRetains(self, retained.items);
    const cloned = try promise_values.cloneValues(self, arena.allocator(), &.{value}, &retained);
    return .{ .arena = arena, .value = cloned[0] };
}

/// Give back what settled data owns: a Host retain per capability inside it
/// and the arena. Terminal, as every release of a settled row's holdings is.
pub fn releaseData(self: *Host, data: *Row.SettledData, closing_peer: ?engine.PeerHandle) void {
    capability_lower.releaseValueCapabilitiesTerminalAt(self, &.{data.value}, closing_peer);
    data.arena.deinit();
}

/// Break each queued send and tell, fulfill each queued listen, project the
/// data to every recipient owed it, then settle the row. Operations run first
/// because a fulfilled listen may pass the promise on and owe one more
/// projection. A recipient's backpressure parks with its projection still
/// owed, and a listener or recipient the data cannot be lowered for hears the
/// refusal as its break.
pub fn finishData(self: *Host, id: capability.PromiseId) !host_pump.ActionOutcome {
    var row = self.capability_promises.getPtr(id) orelse return .done;
    const value = row.state.settling_data.value;
    // Firing a vow may run an in-process listener that releases this promise
    // or rehashes the Host tables, so each operation is detached first and
    // the row refetched after.
    while (true) {
        row = self.capability_promises.getPtr(id) orelse return .done;
        if (row.operation_head >= row.operations.items.len) break;
        const pending = &row.operations.items[row.operation_head];
        switch (pending.action) {
            .send, .tell => {
                try operations.releaseRetainedCapabilities(self, pending);
                row = self.capability_promises.getPtr(id) orelse return .done;
                var owned = row.operations.items[row.operation_head];
                row.operation_head += 1;
                if (owned.result_vow) |vow_id| if (self.vows.contains(vow_id))
                    self.fireVow(vow_id, .{ .broken = uncallable_reason });
                if (owned.action == .tell) if (self.sessions.get(owned.source_peer)) |source|
                    self.finishSessionOperation(source);
                owned.deinit();
            },
            .listen => {
                const vow_id = pending.result_vow.?;
                // A listener whose session left went with that session's vows.
                const source = self.sessions.get(pending.source_peer) orelse {
                    row.operation_head += 1;
                    continue;
                };
                var scratch = std.heap.ArenaAllocator.init(self.allocator);
                defer scratch.deinit();
                // An in-process listener takes its own retains during the
                // fire, so the lowering is a local borrow, as a resolver's
                // local settlement is.
                var prepared = self.prepareValues(source, scratch.allocator(), &.{value}) catch |err| {
                    if (capability_promise.retriesLater(err)) return err;
                    row.operation_head += 1;
                    if (self.vows.contains(vow_id)) self.fireVow(vow_id, .{ .broken = @errorName(err) });
                    continue;
                };
                defer prepared.deinit();
                row.operation_head += 1;
                self.fireVow(vow_id, .{ .fulfilled = prepared.values[0] });
                prepared.finishLocalBorrow();
            },
        }
    }
    while (capability_promise.nextOwedProjection(self, row)) |owed| {
        projectData(self, owed.recipient, owed.projection, value) catch |err| {
            if (err == error.OutboundBackpressure) return .{ .parked_on = owed.projection.peer_handle };
            if (capability_promise.retriesLater(err)) return err;
            capability_promise.breakProjection(self, owed.recipient, owed.projection, @errorName(err)) catch |break_err| {
                if (break_err == error.OutboundBackpressure) return .{ .parked_on = owed.projection.peer_handle };
                return break_err;
            };
        };
        _ = row.projections.pop();
    }
    row.operations.clearRetainingCapacity();
    row.operation_head = 0;
    capability_promise.finishOrigin(self, id, row);
    var data = row.state.settling_data;
    if (row.abandoned) {
        row.projections.deinit(self.allocator);
        row.operations.deinit(self.allocator);
        std.debug.assert(self.capability_promises.remove(id));
        releaseData(self, &data, null);
        return .done;
    }
    row.projections.deinit(self.allocator);
    row.projections = .empty;
    row.operations.deinit(self.allocator);
    row.operations = .empty;
    row.state = .{ .fulfilled_data = data };
    return .done;
}

/// Lower the data into the recipient's session and resolve the projection
/// with it. The prepared lowering rolls back on every refusal.
fn projectData(self: *Host, recipient: *HostSession, projection: Row.Projection, value: value_mod.Value) !void {
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    var prepared = try self.prepareValues(recipient, scratch.allocator(), &.{value});
    defer prepared.deinit();
    try recipient.served.port.peer.sendAnswerTargetResolutionCopying(
        projection.answer_target,
        .{ .fulfill = prepared.values[0] },
    );
    host_pump.markDirty(self, projection.peer_handle);
    _ = prepared.commit();
}

/// Observe a promise that settled to data: the vow is fulfilled with the data
/// before it is returned, so its completion is already queued for the
/// embedder. There is nothing left to cancel on it.
pub fn listenData(self: *Host, id: capability.PromiseId, source: *HostSession) !u64 {
    try self.admitSessionOperation(source);
    try self.checkSession(source);
    const row = self.capability_promises.getPtr(id) orelse return error.UnknownCapability;
    const value = row.state.fulfilled_data.value;
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    var prepared = try self.prepareValues(source, scratch.allocator(), &.{value});
    defer prepared.deinit();
    const vow_id = try self.mintDeferredVow(source, .{
        .owner = @backingInt(id),
        .func = nothingToCancel,
        .terminal_func = nothingToCancelTerminal,
    });
    self.fireVow(vow_id, .{ .fulfilled = prepared.values[0] });
    prepared.finishLocalBorrow();
    return vow_id;
}

fn nothingToCancel(_: *Host, _: u64, _: u64) PendingCancel.CancelError!void {}

fn nothingToCancelTerminal(_: *Host, _: u64, _: u64) void {}

/// Leave the answer's subscription: give back the Node seat if the settlement
/// never published, then the session's mark, count, and payload retain. Only
/// a held retain names its session: a row forgotten at teardown holds none,
/// and its session may be gone by the time the row is released.
fn unsubscribe(self: *Host, answer: *Answer) void {
    const payload = answer.payload orelse return;
    answer.payload = null;
    if (!payload.host_promise_notified) self.node.releasePromiseSettlement();
    const session = self.sessions.get(answer.peer_handle) orelse unreachable;
    session.served.port.peer.session_state.unsubscribeHostPromise(answer.target, payload);
}

/// A subscribed row reached its settlement or broke.
pub const finished = unsubscribe;
