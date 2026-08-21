//! Exporter identity cache and deduplicated dial scheduler for redemption.

const std = @import("std");

const model = @import("model");
const node_mod = @import("../../node.zig");
const actions = @import("../actions.zig");
const redeem = @import("../redeem.zig");
const plan = @import("plan.zig");
const withdrawals = @import("withdrawals.zig");

const Node = node_mod.Node;
const PeerHandle = @import("../../peer_handle.zig").PeerHandle;

pub const PendingId = u64;
pub const PendingDialView = model.PeerLocator;
pub const Failure = enum { retry, exhausted, stale };
pub const Stage = union(enum) {
    open: PeerHandle,
    pending: PendingId,
};

const Waiter = struct {
    dest: redeem.Destination,
    give: []u8,
};

/// One in-flight exporter dial. A second redeem for the same canonical peer
/// identity joins `waiters` rather than opening another session.
const Pending = struct {
    plan: plan.Owned,
    path_index: usize = 0,
    /// A non-redeem owner joined or originated this dial.
    application_owned: bool = false,
    /// The external executor adopted the borrowed active plan.
    effect_in_flight: bool = false,
    /// Host closure sealed this row against later delivery.
    cancel_requested: bool = false,
    waiters: std.ArrayListUnmanaged(Waiter) = .empty,
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
    while (dial_it.next()) |pending| {
        pending.plan.deinit(self.allocator);
        for (pending.waiters.items) |waiter| self.allocator.free(waiter.give);
        releaseWaiterReservations(self, pending.waiters.items.len);
        pending.waiters.deinit(self.allocator);
    }
    std.debug.assert(state.waiter_action_reservations == 0);
    state.pending.deinit(self.allocator);
    // Keys aliased pending identities freed above.
    state.by_identity.deinit(self.allocator);
}

pub fn pendingDial(self: *const Node, pending: PendingId) ?PendingDialView {
    const entry = self.redeems.dials.pending.get(pending) orelse return null;
    if (entry.cancel_requested) return null;
    return entry.plan.view(entry.path_index);
}

/// Commit delivery of one dial effect to an external executor.
pub fn beginEffect(self: *Node, pending: PendingId) bool {
    const entry = self.redeems.dials.pending.getPtr(pending) orelse return false;
    if (entry.cancel_requested) return false;
    std.debug.assert(!entry.effect_in_flight);
    entry.effect_in_flight = true;
    return true;
}

/// Roll back a callback that refused before publishing its external effect.
pub fn rollbackEffect(self: *Node, pending: PendingId) void {
    const entry = self.redeems.dials.pending.getPtr(pending) orelse return;
    std.debug.assert(entry.effect_in_flight);
    entry.effect_in_flight = false;
}

/// Seal all pending dials and yield each already-running effect exactly once
/// for physical cancellation.
pub const CancellationIterator = struct {
    node: *Node,
    pending_dials: std.AutoHashMapUnmanaged(PendingId, Pending).Iterator,

    pub fn next(self: *CancellationIterator) ?PendingId {
        const state = &self.node.redeems.dials;
        while (self.pending_dials.next()) |entry| {
            if (entry.value_ptr.cancel_requested) continue;
            entry.value_ptr.cancel_requested = true;
            settleCancelledWaiters(self.node, entry.value_ptr);
            if (entry.value_ptr.effect_in_flight) return entry.key_ptr.*;
            const owned = entry.value_ptr.*;
            std.debug.assert(state.by_identity.remove(owned.plan.identity));
            state.pending.removeByPtr(entry.key_ptr);
            freeCancelled(self.node, owned);
        }
        return null;
    }
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
        var index: usize = 0;
        while (index < entry.value_ptr.waiters.items.len) {
            const waiter = entry.value_ptr.waiters.items[index];
            const matches = switch (waiter.dest) {
                .answer => false,
                .deferred => |dest| dest.recipient_peer == recipient_peer and
                    dest.id == deferred,
            };
            if (!matches) {
                index += 1;
                continue;
            }
            const removed = entry.value_ptr.waiters.orderedRemove(index);
            releaseWaiterReservations(self, 1);
            self.allocator.free(removed.give);
        }
        if (entry.value_ptr.waiters.items.len != 0 or
            entry.value_ptr.application_owned or
            entry.value_ptr.effect_in_flight)
            continue;
        const owned = entry.value_ptr.*;
        std.debug.assert(state.by_identity.remove(owned.plan.identity));
        state.pending.removeByPtr(entry.key_ptr);
        freeCancelled(self, owned);
    }
}

/// Physical cancellation completion. Idempotent when an ordinary outcome won.
pub fn cancelled(self: *Node, pending: PendingId) void {
    const state = &self.redeems.dials;
    const current = state.pending.get(pending) orelse return;
    if (!current.cancel_requested) return;
    const entry = (state.pending.fetchRemove(pending) orelse unreachable).value;
    std.debug.assert(state.by_identity.remove(entry.plan.identity));
    freeCancelled(self, entry);
}

fn freeCancelled(self: *Node, pending: Pending) void {
    var entry = pending;
    std.debug.assert(entry.waiters.items.len == 0);
    entry.waiters.deinit(self.allocator);
    entry.plan.deinit(self.allocator);
}

fn settleCancelledWaiters(self: *Node, pending: *Pending) void {
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

fn releaseWaiterReservations(self: *Node, count_value: usize) void {
    const state = &self.redeems.dials;
    std.debug.assert(state.waiter_action_reservations >= count_value);
    state.waiter_action_reservations -= count_value;
}

/// Recipient intercept for a returned handoff give.
pub fn acceptGive(
    self: *Node,
    recipient_peer: PeerHandle,
    answer: u64,
    give: []const u8,
    exporter_locator: []const u8,
) !void {
    return acceptGiveTo(
        self,
        .{ .answer = .{
            .recipient_peer = recipient_peer,
            .answer = .from(answer),
        } },
        give,
        exporter_locator,
    );
}

/// Recipient intercept for a give nested in a Passable value.
pub fn acceptInlineGive(
    self: *Node,
    recipient_peer: PeerHandle,
    deferred: u64,
    give: []const u8,
    exporter_locator: []const u8,
) !void {
    return acceptGiveTo(
        self,
        .{ .deferred = .{ .recipient_peer = recipient_peer, .id = deferred } },
        give,
        exporter_locator,
    );
}

fn acceptGiveTo(
    self: *Node,
    dest: redeem.Destination,
    give: []const u8,
    exporter_locator: []const u8,
) !void {
    if (exporter_locator.len == 0)
        return withdrawals.queueFailure(
            self,
            dest,
            "handoff give names no dialable exporter locator",
        );

    // One parse yields both canonical identity and owned dial parts. The
    // scheduler never retains or reparses the verbatim URI.
    var staged = plan.parse(self.allocator, exporter_locator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnparseableExporterLocator => return withdrawals.queueFailure(
            self,
            dest,
            "handoff give names unparseable exporter locator",
        ),
    };
    var staged_owned = true;
    defer if (staged_owned) staged.deinit(self.allocator);

    const state = &self.redeems.dials;
    if (state.exporters.get(staged.identity)) |exporter_peer| {
        const slot = self.peers.getPtr(exporter_peer);
        const retire_on_failure = if (slot) |live|
            live.provisional_exporter and live.pending_withdraw_count == 0
        else
            false;
        if (retire_on_failure) try actions.reserve(self, 3);
        try withdrawals.begin(self, exporter_peer, dest, give);
        if (retire_on_failure and slot.?.pending_withdraw_count == 0)
            actions.pushReserved(self, .{ .retire_exporter = exporter_peer });
        return;
    }

    const owned_give = try self.allocator.dupe(u8, give);
    errdefer self.allocator.free(owned_give);
    const waiter: Waiter = .{ .dest = dest, .give = owned_give };

    if (state.by_identity.get(staged.identity)) |pending_id| {
        const entry = state.pending.getPtr(pending_id).?;
        try actions.reserve(self, 1);
        try entry.waiters.append(self.allocator, waiter);
        state.waiter_action_reservations += 1;
        return;
    }

    // Every fallible acquisition precedes the pending-row publication. The
    // ticket itself is claimed last, after which all publication is infallible.
    try state.pending.ensureUnusedCapacity(self.allocator, 1);
    try state.by_identity.ensureUnusedCapacity(self.allocator, 1);
    try actions.reserve(self, 2);
    var pending: Pending = .{ .plan = staged };
    staged_owned = false;
    var pending_owned = true;
    errdefer if (pending_owned) {
        pending.waiters.deinit(self.allocator);
        pending.plan.deinit(self.allocator);
    };
    try pending.waiters.append(self.allocator, waiter);

    const pending_id = try actions.claimTicketRange(self, 1);
    const identity = pending.plan.identity;
    state.pending.putAssumeCapacity(pending_id, pending);
    pending_owned = false;
    state.waiter_action_reservations += 1;
    state.by_identity.putAssumeCapacity(identity, pending_id);
    actions.pushReserved(self, .{ .dial = .{ .pending = pending_id } });
}

/// Stage a connection dial with no redeem waiter, sharing cache and in-flight
/// identity with handoff redemption.
pub fn stage(self: *Node, locator: []const u8) !Stage {
    if (locator.len == 0) return error.UnparseableExporterLocator;
    var staged = try plan.parse(self.allocator, locator);
    var staged_owned = true;
    defer if (staged_owned) staged.deinit(self.allocator);
    const state = &self.redeems.dials;
    if (state.exporters.get(staged.identity)) |exporter_peer| {
        if (self.peers.getPtr(exporter_peer)) |slot| slot.provisional_exporter = false;
        return .{ .open = exporter_peer };
    }
    if (state.by_identity.get(staged.identity)) |pending_id| {
        state.pending.getPtr(pending_id).?.application_owned = true;
        return .{ .pending = pending_id };
    }

    try state.pending.ensureUnusedCapacity(self.allocator, 1);
    try state.by_identity.ensureUnusedCapacity(self.allocator, 1);
    try actions.reserve(self, 1);
    const pending_id = try actions.claimTicketRange(self, 1);
    const identity = staged.identity;
    state.pending.putAssumeCapacity(pending_id, .{
        .plan = staged,
        .application_owned = true,
    });
    staged_owned = false;
    state.by_identity.putAssumeCapacity(identity, pending_id);
    actions.pushReserved(self, .{ .dial = .{ .pending = pending_id } });
    return .{ .pending = pending_id };
}

pub fn exporterDialed(self: *Node, pending: PendingId, exporter_peer: PeerHandle) !void {
    try exporterReady(self, pending, exporter_peer, false);
}

pub fn exporterSelected(self: *Node, pending: PendingId, exporter_peer: PeerHandle) !void {
    try exporterReady(self, pending, exporter_peer, true);
}

pub fn exporterApplicationOwned(self: *Node, exporter_peer: PeerHandle) void {
    if (self.peers.getPtr(exporter_peer)) |slot| slot.provisional_exporter = false;
}

fn exporterReady(
    self: *Node,
    pending_id: PendingId,
    exporter_peer: PeerHandle,
    selected: bool,
) !void {
    const state = &self.redeems.dials;
    const pending_ptr = state.pending.getPtr(pending_id) orelse return;
    pending_ptr.effect_in_flight = false;
    if (pending_ptr.cancel_requested) return;
    const pending_view = pending_ptr.*;
    const waiter_count = pending_view.waiters.items.len;
    const redeem_only = !pending_view.application_owned and !selected;

    // Preflight the whole batch before consuming the pending row. Each waiter
    // then becomes a tracked withdrawal or an explicit terminal failure.
    const batch_actions = std.math.add(
        usize,
        waiter_count,
        @intFromBool(redeem_only),
    ) catch return error.OutOfMemory;
    try state.exporters.ensureUnusedCapacity(self.allocator, 1);
    try self.redeems.withdrawals.rows.ensureUnusedCapacity(
        self.allocator,
        std.math.cast(u32, waiter_count) orelse return error.OutOfMemory,
    );
    try actions.reserve(self, batch_actions);

    var entry = (state.pending.fetchRemove(pending_id) orelse return).value;
    releaseWaiterReservations(self, entry.waiters.items.len);
    defer {
        for (entry.waiters.items) |waiter| self.allocator.free(waiter.give);
        entry.waiters.deinit(self.allocator);
    }
    std.debug.assert(state.by_identity.remove(entry.plan.identity));
    entry.plan.deinitPaths(self.allocator);
    const cached = state.exporters.getOrPutAssumeCapacity(entry.plan.identity);
    if (cached.found_existing) {
        self.allocator.free(entry.plan.identity);
    } else {
        cached.value_ptr.* = exporter_peer;
    }

    const slot = self.peers.getPtr(exporter_peer);
    if (slot) |live| live.provisional_exporter = redeem_only;
    for (entry.waiters.items) |waiter| {
        withdrawals.begin(self, exporter_peer, waiter.dest, waiter.give) catch |err| switch (err) {
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
    if (slot) |live| {
        if (redeem_only and live.pending_withdraw_count == 0)
            actions.pushReserved(self, .{ .retire_exporter = exporter_peer });
    }
}

/// Claim a queued redeem-only exporter retirement at execution time.
pub fn claimExporterRetirement(self: *Node, exporter_peer: PeerHandle) bool {
    const slot = self.peers.getPtr(exporter_peer) orelse return false;
    if (!slot.provisional_exporter or slot.pending_withdraw_count != 0) return false;
    slot.provisional_exporter = false;
    evictExporterCache(self, exporter_peer);
    return true;
}

/// Report one path failure, retrying the next parsed path under the same ticket
/// or settling every waiter after exhaustion.
pub fn failed(self: *Node, pending: PendingId, reason: []const u8) !Failure {
    const state = &self.redeems.dials;
    const pending_view = state.pending.getPtr(pending) orelse return .stale;
    pending_view.effect_in_flight = false;
    if (pending_view.cancel_requested) return .stale;
    const waiter_count = pending_view.waiters.items.len;

    if (pending_view.path_index + 1 < pending_view.plan.paths.len) {
        try actions.reserve(self, 1);
        pending_view.path_index += 1;
        actions.pushReserved(self, .{ .dial = .{ .pending = pending } });
        return .retry;
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

    var entry = (state.pending.fetchRemove(pending) orelse return .stale).value;
    releaseWaiterReservations(self, entry.waiters.items.len);
    defer {
        entry.plan.deinit(self.allocator);
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
