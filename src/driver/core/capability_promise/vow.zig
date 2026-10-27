//! A public Host vow passed outbound as a capability (ADR-0068). The
//! application's handle to a pending answer is a vow, and a vow is not a
//! value. `vowCapability` turns one into a capability promise. The vow row
//! names the promise as its watcher, the fire stages the settlement on the
//! promise row, and the pump finishes it on the `promise_settled` seat
//! reserved when the promise was made. The promise lowers through the local
//! promise projection every pending promise uses, on the vow's own session
//! too: an answer position belongs to the peer that asked, and the partner
//! would read the open answer as a question of this Host's.

const std = @import("std");

const actors = @import("actors");
const engine = @import("engine");
const model = @import("model");

const capability = @import("../capability.zig");
const capability_lift = @import("../host/capabilities/lift.zig");
const capability_promise = @import("../capability_promise.zig");
const host_mod = @import("../host.zig");
const host_pump = @import("../host/pump.zig");
const promise_answer = @import("answer.zig");
const promise_row = @import("row.zig");
const vow_completion = @import("../vows/completion.zig");
const vow_settlement = @import("../vows/settlement.zig");
const vow_release = @import("../vows/release.zig");
const vows = @import("../vows.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const Row = promise_row.Row;

/// The capability promise for a public vow this Host asked over a session,
/// in any state the vow is in until its handle is released. The same vow
/// asked twice is one promise, retained once more. A settled vow's promise
/// is staged from the completion its row kept, or from the drain when the
/// completion is still queued. A vow with no session refuses
/// `SessionlessVow`.
pub fn vowCapability(self: *Host, vow_id: u64) !capability.Ref {
    const resolved = try vows.resolveVowSession(self, vow_id);
    const row = resolved.row;
    if (row.watcher) |id| return (try capability_promise.retainShared(self, id)).ref;
    const reservation = try capability_promise.reserveRow(self);
    try self.node.reservePromiseSettlement();
    errdefer self.node.releasePromiseSettlement();
    const lifted = try reservation.commit(self, .{ .origin = .{ .vow = .{
        .peer_handle = resolved.session.peer_handle,
        .vow_id = vow_id,
    } } });
    row.watcher = reservation.id;
    if (row.completion != .none) stageHeld(self, reservation.id, row);
    return lifted.ref;
}

/// Stage the vow's settlement on its promise as the vow fires. Nothing may
/// refuse here, so a capability the Host cannot hold and data it cannot own
/// become the promise's break, and the pump finishes every case from the
/// seat the promise reserved. The lift or the copy may add a promise row,
/// so the row is fetched after them.
pub fn stage(self: *Host, id: capability.PromiseId, session: *HostSession, resolution: actors.Resolution) void {
    const state: Row.State = switch (resolution) {
        .fulfilled => |argument| switch (argument) {
            .reference => |*reference| liftedState(self, id, session, reference),
            else => if (promise_answer.ownData(self, session, argument)) |data|
                .{ .settling_data = data }
            else |err|
                .{ .breaking = Row.Failure.init(@errorName(err)) },
        },
        .broken => |reason| .{ .breaking = Row.Failure.init(reason) },
        .give => .{ .breaking = Row.Failure.init(vow_completion.give_reason) },
    };
    publishStaged(self, id, state);
}

/// Stage the settlement a vow row kept after its drain (ADR-0068). The row
/// keeps its completion for a later ask, so a capability is retained for the
/// promise and data is cloned under the promise's own arena. Nothing may
/// refuse here either, so a clone the Host cannot own becomes the promise's
/// break, as does a capability the application released since the drain.
pub fn stageHeld(self: *Host, id: capability.PromiseId, row: *const vow_settlement.VowRow) void {
    const state: Row.State = switch (row.completion) {
        .none => unreachable,
        .failed => |failed| .{ .breaking = Row.Failure.init(failed.message.bytes()) },
        .fulfilled => |fulfilled| switch (fulfilled.value) {
            .capability => |ref| retainedState(self, id, ref),
            else => if (promise_answer.cloneData(self, fulfilled.value)) |data|
                .{ .settling_data = data }
            else |err|
                .{ .breaking = Row.Failure.init(@errorName(err)) },
        },
    };
    publishStaged(self, id, state);
}

/// Whether the promise still waits for its vow's settlement to be staged: a
/// promise asked for after the fire, whose completion is still queued for
/// the drain.
pub fn awaitsStaging(self: *const Host, id: capability.PromiseId) bool {
    const row = self.capability_promises.get(id) orelse return false;
    return row.state == .pending and !row.origin.vow.seat_spent;
}

fn publishStaged(self: *Host, id: capability.PromiseId, state: Row.State) void {
    const row = self.capability_promises.getPtr(id) orelse unreachable;
    std.debug.assert(row.state == .pending and !row.origin.vow.seat_spent);
    row.state = state;
    row.origin.vow.seat_spent = true;
    self.node.publishPromiseSettled(@backingInt(id));
}

/// The capability a held completion names, retained for the promise. A row
/// an embedder drained holds no retain of its own, so one the application
/// released is gone and breaks the promise. A reference to the promise's own
/// projection breaks as a resolution cycle does.
fn retainedState(self: *Host, id: capability.PromiseId, ref: capability.Ref) Row.State {
    const target = self.capabilities.resolve(ref) orelse
        return .{ .breaking = Row.Failure.init(@errorName(error.UnknownCapability)) };
    if (target == .deferred and target.deferred == id)
        return .{ .breaking = Row.Failure.init(engine.resolution_chain.cycle_message) };
    const retained = self.capabilities.retain(self.allocator, target) catch |err|
        return .{ .breaking = Row.Failure.init(@errorName(err)) };
    return .{ .settling = .{ .ref = retained, .claimed_wire_retain = false } };
}

/// The capability a vow settled to, held until the pump finishes the
/// promise. A reference to the promise's own projection would settle it to
/// itself, a loop nothing outside it settles, so it breaks as a resolution
/// cycle does, with the lift undone.
fn liftedState(self: *Host, id: capability.PromiseId, session: *HostSession, reference: *const model.Reference) Row.State {
    const lifted = capability_lift.liftReference(self, session, .fromOwned(reference)) catch |err|
        return .{ .breaking = Row.Failure.init(@errorName(err)) };
    if (self.capabilities.resolve(lifted.ref)) |target| if (target == .deferred and target.deferred == id) {
        self.rollbackCapabilityLift(lifted);
        return .{ .breaking = Row.Failure.init(engine.resolution_chain.cycle_message) };
    };
    self.commitCapabilityLift(lifted);
    return .{ .settling = lifted };
}

/// The `promise_settled` action for a vow origin: finish what the fire
/// staged. Memory or outbound pressure leaves the action retryable, as it
/// does for an answer.
pub fn settle(self: *Host, id: capability.PromiseId) !host_pump.ActionOutcome {
    const row = self.capability_promises.getPtr(id) orelse return .done;
    switch (row.state) {
        .settling => |lifted| return capability_promise.fulfillLifted(self, id, lifted),
        .settling_data => return promise_answer.finishData(self, id),
        .breaking => |held| {
            // The break replaces the row's copy, so the reason leaves it first.
            const failure = held;
            return capability_promise.breakPromise(self, id, failure.message());
        },
        // The vow publishes only after staging.
        .pending => unreachable,
        .fulfilled, .fulfilled_data, .broken => return .done,
    }
}

/// The promise reached its settlement or broke: give back a seat that never
/// published, and let the vow row go on without a watcher. A row whose handle
/// the application already released has nothing left waiting for the fire,
/// so it retires as a released row does.
pub fn finished(self: *Host, id: capability.PromiseId, vow: *Row.Origin.Vow) void {
    releaseSeat(self, vow);
    const row = self.vows.get(vow.vow_id) orelse return;
    if (row.watcher != id) return;
    row.watcher = null;
    if (row.handle_released and !row.settled) {
        const session = self.sessions.get(vow.peer_handle) orelse unreachable;
        vow_release.retireUnwatched(self, row, session);
    }
}

/// Host teardown: give back the seat a row still holds before the Node is
/// freed. The row itself goes with the map.
pub const forget = releaseSeat;

fn releaseSeat(self: *Host, vow: *Row.Origin.Vow) void {
    if (vow.seat_spent) return;
    self.node.releasePromiseSettlement();
    vow.seat_spent = true;
}

/// The vow moved to the session that owns its real send, so the promise
/// follows: that session's close is the one that ends both.
pub fn moved(self: *Host, id: capability.PromiseId, peer_handle: engine.PeerHandle) void {
    const row = self.capability_promises.getPtr(id) orelse unreachable;
    row.origin.vow.peer_handle = peer_handle;
}
