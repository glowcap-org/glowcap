//! Local vow minting, observation, and depth-guarded settlement.

const std = @import("std");
const model = @import("model");
const serve_mod = @import("serve.zig");
const vat_mod = @import("mod.zig");

const Vat = vat_mod.Vat;
const Vow = vat_mod.Vow;
const Resolution = vat_mod.Resolution;
const Listener = vat_mod.Listener;
const ResolverPair = vat_mod.ResolverPair;
const ResolverPairReservation = vat_mod.ResolverPairReservation;
const Error = vat_mod.Error;
const steady_settle_arena_bytes = vat_mod.steady_settle_arena_bytes;

/// A local vow name in this Vat's monotonic, never-reused epoch. Keeping the
/// map key distinct prevents a wire answer position or another bare integer
/// namespace from being used here by accident.
pub const PendingLocalVowKey = struct { id: u64 };
pub fn freeOwnedForwardContexts(allocator: std.mem.Allocator, map: anytype) void {
    var it = map.valueIterator();
    while (it.next()) |listener| {
        if (listener.func == serve_mod.forwardListener) {
            const fc: *serve_mod.ForwardContext = @ptrCast(@alignCast(listener.ctx.?));
            allocator.destroy(fc);
        }
    }
}
pub fn spawnVow(self: *Vat) Error!ResolverPair {
    const reservation = try reserveResolverPair(self);
    return spawnReservedVow(self, reservation);
}

pub fn reserveResolverPair(self: *Vat) Error!ResolverPairReservation {
    try vat_mod.ensureFreshId(self.next_vow);
    try vat_mod.ensureFreshId(self.next_resolver);
    try self.pending_local_vows.ensureUnusedCapacity(self.allocator, 1);
    try self.resolver_vows.ensureUnusedCapacity(self.allocator, 1);
    return .{};
}

pub fn spawnReservedVow(self: *Vat, reservation: ResolverPairReservation) ResolverPair {
    _ = reservation;
    vat_mod.ensureFreshId(self.next_vow) catch unreachable;
    vat_mod.ensureFreshId(self.next_resolver) catch unreachable;
    const vow = self.next_vow;
    self.next_vow += 1;
    self.pending_local_vows.putAssumeCapacity(.{ .id = vow }, {});
    const resolver = self.next_resolver;
    self.next_resolver += 1;
    self.resolver_vows.putAssumeCapacity(resolver, vow);
    return .{ .vow = .{ .local = vow }, .resolver = resolver };
}

/// Settle a resolver vow fulfilled (ADR-0102). Top-level like `drive` —
/// the vow's listener may open a nested drive, so a settle from inside a
/// turn refuses (`SettleInTurn`) and re-enters later instead. Fulfillment
/// prepares the listener's owned value before consuming the resolver, so
/// allocation failure is retryable with the same settle authority.
/// `value` is borrowed for the call; the settle spine clones what a
/// listener may outlive.
pub fn fulfillVow(self: *Vat, resolver: u64, value: model.Argument) Error!void {
    try settleResolver(self, resolver, .{ .fulfilled = value });
}

/// Settle a resolver vow broken (ADR-0102). The same contract as
/// `fulfillVow`; `reason` is borrowed for the call — the listener fires
/// within it and retains nothing.
pub fn breakVow(self: *Vat, resolver: u64, reason: []const u8) Error!void {
    try settleResolver(self, resolver, .{ .broken = reason });
}

fn settleResolver(self: *Vat, resolver: u64, resolution: Resolution) Error!void {
    if (self.turn_depth != 0) return Error.SettleInTurn;
    const vow = self.resolver_vows.get(resolver) orelse return Error.AlreadySettled;
    // The settle runs listeners under the drive discipline `settleLocal`
    // requires: a listener may open a nested drive or far settle, and the
    // settle arena's depth guard covers both.
    self.drive_depth += 1;
    defer self.drive_depth -= 1;
    switch (resolution) {
        .fulfilled => |value| {
            if (self.listeners.contains(vow)) {
                const arena = beginSettle(self);
                defer endSettle(self);
                const owned = try model.cloneArgument(arena, value);
                std.debug.assert(self.resolver_vows.remove(resolver));
                settleLocalPrepared(self, vow, .{ .fulfilled = owned });
                return;
            }
        },
        .broken => {},
        .give => unreachable,
    }
    std.debug.assert(self.resolver_vows.remove(resolver));
    try settleLocal(self, vow, resolution);
}

/// Settle with a resolution whose lifetime is already safe for the
/// listener call. No allocation remains after the resolver is consumed.
fn settleLocalPrepared(self: *Vat, vow_id: u64, resolution: Resolution) void {
    std.debug.assert(self.pending_local_vows.remove(.{ .id = vow_id }));
    const listener = self.listeners.fetchRemove(vow_id) orelse return;
    listener.value.func(listener.value.ctx, resolution);
}

/// Register a one-shot listener for a local `vow`. Far vows are observed
/// through `Port.on`, where the session projection can dispatch the
/// partner's resolution. A vow holds at most one listener, so a second
/// registration before the first fires returns `AlreadyListening` instead
/// of silently orphaning the first.
pub fn on(self: *Vat, vow: Vow, listener: Listener) Error!void {
    switch (vow) {
        .local => |id| {
            // A local vow settles exactly once, during `drive`; a
            // listener registered after that settlement would never fire,
            // so refuse it loud.
            if (id < self.next_vow and !self.pending_local_vows.contains(.{ .id = id })) return Error.AlreadySettled;
            const gop = try self.listeners.getOrPut(self.allocator, id);
            if (gop.found_existing) return Error.AlreadyListening;
            gop.value_ptr.* = listener;
        },
        .far => return Error.NotConnected,
    }
}

/// Enter one nested settlement borrow scope.
fn beginSettle(self: *Vat) std.mem.Allocator {
    self.settle_depth += 1;
    return self.settle_arena.allocator();
}

fn endSettle(self: *Vat) void {
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
/// A broken resolution carries `@errorName`'s static string, which no
/// reset can free.
pub fn settleLocal(self: *Vat, vow_id: u64, resolution: Resolution) Error!void {
    // Local settlement only occurs inside a drive; hold that invariant
    // mechanically even though its clone now lives in the settle arena.
    std.debug.assert(self.drive_depth >= 1);
    // Remove before anything fallible: the turn ran, so a later `on` must
    // refuse even if cloning its result for an already-parked listener OOMs.
    std.debug.assert(self.pending_local_vows.remove(.{ .id = vow_id }));
    // Peek the listener rather than remove it, mirroring the far-resolve
    // arm in `serve`: the fulfilled arm clones fallibly before firing, and
    // an OOM return must leave the entry in the map so teardown
    // (`freeOwnedForwardContexts`) still reclaims a forward's heap
    // context. Each arm removes the entry immediately before it fires,
    // preserving the remove-before-fire order a listener that re-registers
    // the vow relies on.
    const listener = self.listeners.get(vow_id) orelse return;
    switch (resolution) {
        .fulfilled => |value| {
            const arena = beginSettle(self);
            defer endSettle(self);
            const owned = try model.cloneArgument(arena, value);
            std.debug.assert(self.listeners.fetchRemove(vow_id) != null);
            listener.func(listener.ctx, .{ .fulfilled = owned });
        },
        .broken => {
            std.debug.assert(self.listeners.fetchRemove(vow_id) != null);
            listener.func(listener.ctx, resolution);
        },
        // Local settlement never carries a wire introduction; only the
        // far-resolve path in `serve` constructs `.give`.
        .give => unreachable,
    }
}
