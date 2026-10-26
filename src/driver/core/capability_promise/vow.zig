//! A public Host vow passed outbound as a capability (ADR-0068). The
//! application's handle to a pending answer is a vow, and a vow is not a
//! value. `vowCapability` turns one into a capability promise. The vow row
//! names the promise as its watcher, the fire stages the settlement on the
//! promise row, and the pump finishes it on the `promise_settled` seat
//! reserved when the promise was made. On the vow's own session the promise
//! lowers as the open answer itself. Elsewhere it lowers through the local
//! promise projection every pending promise uses.

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
const vow_release = @import("../vows/release.zig");
const vows = @import("../vows.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const Row = promise_row.Row;

/// The capability promise for a public vow this Host asked over a session.
/// The same vow asked twice is one promise, retained once more. A settled
/// vow refuses `AlreadySettled`, since the application holds its value, and
/// a vow with no session refuses `SessionlessVow`.
pub fn vowCapability(self: *Host, vow_id: u64) !capability.Ref {
    const resolved = try vows.resolveVowSession(self, vow_id);
    const row = resolved.row;
    if (row.settled) return error.AlreadySettled;
    if (row.watcher) |id| return (try capability_promise.retainShared(self, id)).ref;
    const id: capability.PromiseId = @fromBackingInt(self.capability_promise_ids.peek() orelse
        return error.CapabilitySpaceExhausted);
    try self.capability_promises.ensureUnusedCapacity(self.allocator, 1);
    try self.node.reservePromiseSettlement();
    errdefer self.node.releasePromiseSettlement();
    const ref = try self.capabilities.retain(self.allocator, .{ .deferred = id });
    self.capability_promises.putAssumeCapacity(id, .{ .origin = .{ .vow = .{
        .peer_handle = resolved.session.peer_handle,
        .vow_id = vow_id,
    } } });
    self.capability_promise_ids.commit(@backingInt(id));
    row.watcher = id;
    return ref;
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
    const row = self.capability_promises.getPtr(id) orelse unreachable;
    std.debug.assert(row.state == .pending and !row.origin.vow.published);
    row.state = state;
    row.origin.vow.published = true;
    self.node.publishPromiseSettled(@backingInt(id));
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
    if (vow.published) return;
    self.node.releasePromiseSettlement();
    vow.published = true;
}

/// The vow moved to the session that owns its real send, so the promise
/// follows: that session's close is the one that ends both.
pub fn moved(self: *Host, id: capability.PromiseId, peer_handle: engine.PeerHandle) void {
    const row = self.capability_promises.getPtr(id) orelse unreachable;
    row.origin.vow.peer_handle = peer_handle;
}

/// The reference a pending vow promise lowers to on the vow's own session:
/// the open answer itself, which the partner shortens on arrival. Null on
/// another session, or once the vow row is gone, where a projection stands
/// in for it.
pub fn answerReference(self: *Host, row: *const Row, session: *const HostSession) ?model.Reference {
    const vow = switch (row.origin) {
        .vow => |vow| vow,
        .inline_give, .answer => return null,
    };
    if (vow.peer_handle != session.peer_handle) return null;
    const vow_row = self.vows.get(vow.vow_id) orelse return null;
    const answer = vows.pipelineAnswer(vow_row) catch return null;
    return .{ .promise = .{ .answer_position = answer.position } };
}
