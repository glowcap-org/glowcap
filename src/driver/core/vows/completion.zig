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
const promise_values = @import("../capability_promise/values.zig");
const release = @import("release.zig");
const settlement = @import("settlement.zig");
const value_mod = @import("../value.zig");
const capability = @import("../capability.zig");

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

/// Who holds the retains a drained completion's value carries. An embedder
/// took its own at the drain, so the row names the capabilities without
/// retaining them, the application's retains alone decide when one leaves,
/// and a later ask finds a released one gone. A drive with no embedder, the
/// Zig Session, leaves them on the row until `takeHeld` or the release.
pub const Custody = enum { embedder, row };

/// Keep a drained completion with its session row, so the vow still passes
/// as a promise after it settled (ADR-0068) and `takeHeld` can read it. The
/// row keeps the value and its storage, and `custody` says whether it keeps
/// the retains. A promise asked for between the fire and this drain is
/// staged first, as the fire stages one asked for before it, and a row whose
/// handle already left retires once it is staged. False when no session row
/// holds the vow: a released handle, or a local row, whose completion the
/// Host is never asked for again.
pub fn holdDrained(self: *Host, action: host_action.HostAction, custody: Custody) bool {
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
    row.held_retains = action == .settled and custody == .row;
    if (row.watcher) |watcher| if (capability_promise.vowPromiseAwaitsStaging(self, watcher))
        capability_promise.stageHeldSettlement(self, watcher, row);
    if (action == .settled and custody == .embedder)
        lower.releaseValueCapabilitiesTerminalAt(self, &.{action.settled.value}, null);
    if (row.handle_released) settlement.retireRow(self, row);
    return true;
}

/// Free a row's held completion: the retains it kept for the application, if
/// it kept them, then the storage.
pub fn freeHeld(self: *Host, row: *settlement.VowRow) void {
    const held = row.completion;
    const retained = row.held_retains;
    row.completion = .none;
    row.held_retains = false;
    switch (held) {
        .none => {},
        .fulfilled => |fulfilled| {
            if (retained) lower.releaseValueCapabilitiesTerminalAt(self, &.{fulfilled.value}, null);
            var arena = fulfilled.storage.promote(self.allocator);
            arena.deinit();
        },
        .failed => |failed| failed.message.deinit(self.allocator),
    }
}

/// What `takeHeld` found on the row.
pub const Held = union(enum) {
    /// The vow is pending, or is not a session row, so the caller listens
    /// through `vowOn` as before.
    pending,
    /// The vow settled and its completion is still queued for the drain: a
    /// drain that stopped at outbound pressure. The caller drains and asks
    /// again.
    queued,
    taken: value_mod.Reply,
};

/// The completion a session row kept for the application, as a reply
/// materialized into `arena` with one fresh retain per capability inside,
/// and the row released: how `Session.settle` reads a vow whose reply
/// arrived while another verb pumped the session. A completion an embedder
/// drained is that embedder's, and the ask is refused `AlreadySettled`. The
/// copy is one reply nobody listened for, off the wire path.
pub fn takeHeld(self: *Host, vow_id: u64, arena: std.mem.Allocator) !Held {
    const row = self.vows.get(vow_id) orelse return host_mod.HostError.NoSuchVow;
    if (!row.settled or row.handle_released or row.peer() == null) return .pending;
    var retained: std.ArrayListUnmanaged(capability.Ref) = .empty;
    errdefer promise_values.rollbackRetains(self, retained.items);
    const reply: value_mod.Reply = switch (row.completion) {
        .none => return .queued,
        .failed => |failed| .{ .broken = try arena.dupe(u8, failed.message.bytes()) },
        .fulfilled => |fulfilled| if (row.held_retains)
            .{ .fulfilled = (try promise_values.cloneValues(self, arena, &.{fulfilled.value}, &retained))[0] }
        else
            return error.AlreadySettled,
    };
    try release.release(self, vow_id);
    return .{ .taken = reply };
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
