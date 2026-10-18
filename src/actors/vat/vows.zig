//! Local vow minting, observation, and depth-guarded settlement.

const std = @import("std");
const model = @import("model");
const forwarding = @import("forwarding.zig");
const vat_mod = @import("mod.zig");

const Vat = vat_mod.Vat;
const Vow = vat_mod.Vow;
const Resolution = vat_mod.Resolution;
const Listener = vat_mod.Listener;
const ResolverPair = vat_mod.ResolverPair;
const ResolverPairReservation = vat_mod.ResolverPairReservation;
const Outcome = vat_mod.Outcome;
const Error = vat_mod.Error;
const Queued = @import("behavior.zig").Queued;
const steady_settle_arena_bytes = vat_mod.steady_settle_arena_bytes;

/// A local vow name in this Vat's monotonic, never-reused epoch. Keeping the
/// map key distinct prevents a wire answer position or another bare integer
/// namespace from being used here by accident.
pub const PendingLocalVowKey = struct { id: u64 };
pub fn freeOwnedForwardContexts(self: *Vat, map: anytype) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        const listener = entry.value_ptr;
        if (listener.func == self.forward_listener) {
            const fc: *forwarding.ForwardContext = @ptrCast(@alignCast(listener.ctx.?));
            std.debug.assert(fc.vat == self);
            self.allocator.destroy(fc);
        }
    }
}
pub fn spawnVow(self: *Vat) Error!ResolverPair {
    const reservation = try reserveResolverPair(self);
    return spawnReservedVow(self, reservation);
}

pub fn reserveResolverPair(self: *Vat) Error!ResolverPairReservation {
    try self.admitMutation();
    const vow = try vat_mod.peekId(self.vow_ids);
    const resolver = try vat_mod.peekId(self.resolver_ids);
    try self.pending_local_vows.ensureUnusedCapacity(self.allocator, 1);
    try self.resolver_vows.ensureUnusedCapacity(self.allocator, 1);
    return .{ .vow = vow, .resolver = resolver };
}

/// Nothing spends an id between the reservation and this commit, which each
/// issuer asserts.
pub fn spawnReservedVow(self: *Vat, reservation: ResolverPairReservation) ResolverPair {
    self.admitMutation() catch unreachable;
    self.vow_ids.commit(reservation.vow);
    self.pending_local_vows.putAssumeCapacity(.{ .id = reservation.vow }, {});
    self.resolver_ids.commit(reservation.resolver);
    self.resolver_vows.putAssumeCapacity(reservation.resolver, reservation.vow);
    return .{ .vow = .{ .local = reservation.vow }, .resolver = reservation.resolver };
}

/// Settle a resolver vow fulfilled (ADR-0102). Top-level like `drive`,
/// the vow's listener may open a nested drive, so a settle from inside a
/// turn refuses (`SettleInTurn`) and re-enters later instead. Fulfillment
/// prepares the listener's owned value before consuming the resolver, so
/// allocation failure is retryable with the same settle authority.
/// `value` is borrowed for the call. The settle spine clones what a
/// listener may outlive.
pub fn fulfillVow(self: *Vat, resolver: u64, value: model.Argument) Error!void {
    try settleResolver(self, resolver, .{ .fulfilled = value });
}

/// Settle a resolver vow broken (ADR-0102). The same contract as
/// `fulfillVow`. `reason` is borrowed for the call, the listener fires
/// within it and retains nothing.
pub fn breakVow(self: *Vat, resolver: u64, reason: []const u8) Error!void {
    try settleResolver(self, resolver, .{ .broken = reason });
}

fn settleResolver(self: *Vat, resolver: u64, outcome: Outcome) Error!void {
    try self.admitMutation();
    if (self.turn_depth != 0) return error.SettleInTurn;
    if (!self.resolver_ids.issued(resolver)) return error.NoSuchResolver;
    const vow = self.resolver_vows.get(resolver) orelse return error.AlreadySettled;
    if (!self.listeners.contains(vow)) {
        std.debug.assert(self.resolver_vows.remove(resolver));
        std.debug.assert(self.pending_local_vows.remove(.{ .id = vow }));
        return;
    }
    // The listener runs under the drive discipline: it may open a nested
    // drive or far settle, and the settle arena's depth guard covers both.
    self.drive_depth += 1;
    defer self.drive_depth -= 1;
    const arena = beginSettle(self);
    defer endSettle(self);
    const owned = try ownOutcome(arena, outcome);
    std.debug.assert(self.resolver_vows.remove(resolver));
    settleLocalPrepared(self, vow, owned.resolution());
}

/// `outcome` with its payload cloned into `arena`, the settlement scope a
/// listener may reenter.
fn ownOutcome(arena: std.mem.Allocator, outcome: Outcome) !Outcome {
    return switch (outcome) {
        .fulfilled => |value| .{ .fulfilled = try model.cloneArgument(arena, value) },
        .broken => |reason| .{ .broken = try arena.dupe(u8, reason) },
    };
}

/// Terminal cleanup of an exclusively held resolver. The static diagnostic
/// survives listener reentry without allocation, so rollback cannot be refused.
pub fn breakVowTerminal(self: *Vat, resolver: u64, comptime reason: []const u8) void {
    self.admitMutation() catch unreachable;
    std.debug.assert(self.turn_depth == 0);
    const vow = self.resolver_vows.fetchRemove(resolver) orelse unreachable;
    self.drive_depth += 1;
    defer self.drive_depth -= 1;
    settleLocalPrepared(self, vow.value, .{ .broken = reason });
}

/// Settle with a resolution already protected across listener reentry by the
/// producer's settlement scope. No allocation or additional clone remains.
pub fn settleLocalPrepared(self: *Vat, vow_id: u64, resolution: Resolution) void {
    std.debug.assert(self.pending_local_vows.remove(.{ .id = vow_id }));
    const listener = self.listeners.fetchRemove(vow_id) orelse return;
    fireLocalListener(self, listener.value, resolution);
}

// Local forwarding chains settle iteratively. A queued chain may be much
// longer than the bounded synchronous near-call stack.
fn fireLocalListener(self: *Vat, first: Listener, resolution: Resolution) void {
    var listener = first;
    while (listener.func == self.forward_listener) {
        const context: *forwarding.ForwardContext = @ptrCast(@alignCast(listener.ctx.?));
        if (context.answer != .local) break;
        const id = context.answer.local;
        self.allocator.destroy(context);
        std.debug.assert(self.pending_local_vows.remove(.{ .id = id }));
        listener = (self.listeners.fetchRemove(id) orelse return).value;
    }
    listener.func(listener.ctx, resolution);
}

pub fn reserveLocalListener(self: *Vat) Error!void {
    try self.admitMutation();
    try self.listeners.ensureUnusedCapacity(self.allocator, 1);
}

pub fn onReservedLocal(self: *Vat, id: u64, listener: Listener) void {
    self.admitMutation() catch unreachable;
    std.debug.assert(self.pending_local_vows.contains(.{ .id = id }));
    std.debug.assert(!self.listeners.contains(id));
    self.listeners.putAssumeCapacity(id, listener);
}

/// Register a one-shot listener for a local `vow`. Far vows are observed
/// through `Port.on`, where the session projection can dispatch the
/// partner's resolution. A vow holds at most one listener, so a second
/// registration before the first fires returns `AlreadyListening` instead
/// of silently orphaning the first.
pub fn on(self: *Vat, vow: Vow, listener: Listener) Error!void {
    try self.admitMutation();
    switch (vow) {
        .local => |id| {
            // A local vow settles exactly once, during `drive`; a
            // listener registered after that settlement would never fire,
            // so refuse it loud.
            if (!self.vow_ids.issued(id)) return error.NoSuchVow;
            if (!self.pending_local_vows.contains(.{ .id = id })) return error.AlreadySettled;
            const gop = try self.listeners.getOrPut(self.allocator, id);
            if (gop.found_existing) return error.AlreadyListening;
            gop.value_ptr.* = listener;
        },
        .far => return error.NotConnected,
    }
}

/// Remove and return the listener on one still-pending local vow. The vow
/// itself remains in the Vat and may settle normally. Only this observer's
/// lifetime ends. Host handle release uses this before freeing the listener's
/// context, so a later local turn cannot call through a dead pointer.
pub fn takeListener(self: *Vat, vow: Vow) ?Listener {
    return switch (vow) {
        .local => |id| if (self.listeners.fetchRemove(id)) |entry| entry.value else null,
        .far => null,
    };
}

/// Enter one nested settlement borrow scope: the settle arena a listener's
/// value lives in, reset when the outermost scope closes.
pub fn beginSettle(self: *Vat) std.mem.Allocator {
    self.settle_depth += 1;
    return self.settle_arena.allocator();
}

pub fn endSettle(self: *Vat) void {
    self.settle_depth -= 1;
    if (self.settle_depth == 0) {
        _ = self.settle_arena.reset(.{ .retain_with_limit = steady_settle_arena_bytes });
    }
}

/// Fire `vow_id`'s listener, if any. The clone below defends two
/// hazards, so it can be re-homed but never deleted. First, a fulfilled
/// value lives in the turn arena (or aliases the queued message), and a
/// listener may legitimately open a top-level turn (`near` or `drive`)
/// while it runs, whose depth-0 reset would free that storage mid-call.
/// Second, the value may borrow the settling actor's own mutable state,
/// and a listener-opened nested drive can run a turn that mutates or
/// `become`-frees that state under the borrow. So the one argument is
/// cloned into the settle arena shared with far settlement. Its depth guard
/// lets a listener open a nested drive or far settle without freeing the
/// outer listener's value.
/// A broken resolution may carry a callback's dynamic diagnostic. That
/// message receives the same settlement-lifetime protection.
///
/// The turn has already run by the time this is called, so its waiter has
/// no other producer. A refused clone therefore fires the listener broken
/// with the exact failure name and then returns that failure to the driver,
/// leaving the rest of the queue live. The far arms in `serve` keep their
/// listener parked on a refusal instead. That is open to them only because
/// their producer survives it: a Host action stays parked for a retry, and a
/// refused frame retires the session, whose release runs `breakFarVows`.
/// The outcome is protected before `retirement` releases the queued
/// message's custody, because retirement can reenter just like a listener,
/// so both borrow the same settlement scope.
pub fn settleLocal(self: *Vat, vow_id: u64, outcome: Outcome, retirement: ?*Queued) Error!void {
    std.debug.assert(self.drive_depth >= 1);
    std.debug.assert(self.pending_local_vows.remove(.{ .id = vow_id }));
    const listener: ?Listener = if (self.listeners.fetchRemove(vow_id)) |entry| entry.value else null;
    if (listener == null and retirement == null) return;
    const arena = beginSettle(self);
    defer endSettle(self);
    const owned = ownOutcome(arena, outcome) catch |err| {
        if (retirement) |delivery| delivery.retire(@errorName(err));
        if (listener) |observer| fireLocalListener(self, observer, .{ .broken = @errorName(err) });
        return err;
    };
    if (retirement) |delivery| delivery.retire(if (owned == .broken) owned.broken else null);
    if (listener) |observer| fireLocalListener(self, observer, owned.resolution());
}
