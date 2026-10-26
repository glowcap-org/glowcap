//! Completion rows for host vows with no in-process listener.
//!
//! Settlement fires while the Vat resolution is borrowed. The action queue is
//! drained later by an embedder, so this owner materializes the completion or
//! records an allocation-free failure.

const std = @import("std");
const model = @import("model");
const lift = @import("../host/capabilities/lift.zig");
const engine = @import("engine");
const actors = @import("actors");

const capability_promise = @import("../capability_promise.zig");
const host_mod = @import("../host.zig");
const host_action = @import("../host/action.zig");
const lower = @import("../host/capabilities/lower.zig");
const settlement = @import("settlement.zig");

const Host = host_mod.Host;

/// Queue a settled vow's completion for the embedder, infallible by reservation.
/// The action owns materialized Values and capabilities because the source
/// resolution is turn-borrowed. In-process listeners keep their borrowed path.
pub fn queueVowCompletion(self: *Host, peer_handle: engine.PeerHandle, vow_id: u64, resolution: actors.Resolution) void {
    switch (resolution) {
        .fulfilled => |value| {
            const session = self.sessions.get(peer_handle) orelse {
                queueFailure(self, peer_handle, vow_id, .closed, host_action.retainFailureMessage(self.allocator, "resolution session closed"));
                return;
            };
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            const owned = lift.ownValue(self, session, arena.allocator(), value) catch |err| {
                arena.deinit();
                queueFailure(self, peer_handle, vow_id, .broken, retainError(self, err));
                return;
            };
            self.actions.pushReserved(.{ .settled = .{
                .peer_handle = peer_handle,
                .vow_id = vow_id,
                .value = owned,
                .storage = arena.state,
            } });
        },
        .broken => |message| queueFailure(self, peer_handle, vow_id, classifyFailure(self, peer_handle), host_action.retainFailureMessage(self.allocator, message)),
        .give => queueFailure(self, peer_handle, vow_id, .broken, host_action.retainFailureMessage(self.allocator, give_reason)),
    }
}

/// The break a vow reports when its resolution is a raw handoff give, which
/// no settle listener can hold.
pub const give_reason = "raw handoff reached a settle listener";

/// Keep a drained completion with its session row, so the vow still passes
/// as a promise after it settled (ADR-0068). The row keeps the value and its
/// storage, and names the capabilities inside without retaining them: the
/// action's retains go here as a discarded payload's do, so the
/// application's own retains alone decide when a capability leaves, and a
/// later ask finds a released one gone. A promise asked for between the fire
/// and this drain is staged first, as the fire stages one asked for before
/// it, and a row whose handle already left retires once it is staged. False when
/// no session row holds the vow: a released handle, or a local row, whose
/// completion the Host is never asked for again.
pub fn holdDrained(self: *Host, action: host_action.HostAction) bool {
    const vow_id = switch (action) {
        .settled => |settled| settled.vow_id,
        .failed => |failed| failed.vow_id,
        else => return false,
    };
    const row = self.vows.get(vow_id) orelse return false;
    if (row.peer() == null) return false;
    std.debug.assert(row.settled and row.completion == .none);
    row.completion = switch (action) {
        .settled => |settled| .{ .fulfilled = .{ .value = settled.value, .storage = settled.storage } },
        .failed => |failed| .{ .failed = .{ .failure = failed.failure, .message = failed.message } },
        else => unreachable,
    };
    if (row.watcher) |watcher| if (capability_promise.vowPromiseAwaitsStaging(self, watcher))
        capability_promise.stageHeldSettlement(self, watcher, row);
    if (action == .settled)
        lower.releaseValueCapabilitiesTerminalAt(self, &.{action.settled.value}, null);
    if (row.handle_released) settlement.retireRow(self, row);
    return true;
}

/// Free the storage of a row's held completion. Its capabilities hold no
/// retain of the row's, so nothing else is given back.
pub fn freeHeld(self: *Host, row: *settlement.VowRow) void {
    const held = row.completion;
    row.completion = .none;
    switch (held) {
        .none => {},
        .fulfilled => |fulfilled| {
            var arena = fulfilled.storage.promote(self.allocator);
            arena.deinit();
        },
        .failed => |failed| failed.message.deinit(self.allocator),
    }
}

/// Classify a Vat break while the owning session row is still authoritative.
/// Finishing keeps admitted work live, so only terminal teardown is closure.
pub fn classifyFailure(self: *const Host, peer_handle: engine.PeerHandle) host_action.VowFailure {
    const session = self.sessions.get(peer_handle) orelse return .closed;
    return if (session.isTerminating()) .closed else .broken;
}

/// Cached references contribute no new wire occurrence. A failed acquisition
/// leaves existing observations untouched. Successful actions own their retain.
pub fn queueCachedCompletion(self: *Host, session: *host_mod.HostSession, id: u64, reference: model.Reference) void {
    const ref = self.liftCapability(session, reference) catch |err| {
        queueFailure(self, session.peer_handle, id, .broken, retainError(self, err));
        return;
    };
    self.actions.pushReserved(.{ .settled = .{
        .peer_handle = session.peer_handle,
        .vow_id = id,
        .value = .{ .capability = ref },
    } });
}

fn queueFailure(self: *Host, peer: engine.PeerHandle, id: u64, failure: host_action.VowFailure, message: host_action.RetainedFailureMessage) void {
    self.actions.pushReserved(.{ .failed = .{
        .peer_handle = peer,
        .vow_id = id,
        .failure = failure,
        .message = message,
    } });
}

fn retainError(self: *Host, err: anyerror) host_action.RetainedFailureMessage {
    return if (err == error.OutOfMemory) .fallback else host_action.retainFailureMessage(self.allocator, @errorName(err));
}
