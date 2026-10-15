//! Host resolver pairs: defer one served turn onto a sessionless Vat vow, then
//! settle that authority off-turn on the Host owner thread.

const std = @import("std");

const actors = @import("actors");
const model = @import("model");

const host_mod = @import("../host.zig");
const host_pump = @import("../host/pump.zig");
const settlement = @import("settlement.zig");
const vows = @import("../vows.zig");
const lower = @import("../host/capabilities/lower.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const HostError = host_mod.HostError;

fn ensureFreshResolverId(self: *Host) !void {
    if (self.next_resolver == std.math.maxInt(u64))
        return error.CapabilitySpaceExhausted;
}

/// Atomically mint the resolver authority and defer `turn` onto its vow. Every
/// Host/Vat row and the forward listener are reserved before either side is
/// published, so refusal leaves no resolver and no forwarded effect behind.
pub fn deferTurn(self: *Host, maybe_session: ?*HostSession, turn: *actors.Turn) !u64 {
    self.assertOwner();
    const session = maybe_session orelse return deferOwned(self, turn);
    try self.admitApplicationOperation();
    if (session.host != self or self.sessions.get(session.peer_handle) != session)
        return HostError.ForeignTurn;
    if (turn.vat != &self.vat) return HostError.ForeignTurn;
    switch (turn.origin) {
        .local => return actors.Error.NotLocal,
        .eventual => |eventual| if (eventual.answer == null) return HostError.NoAnswer,
        .served => |answer| if (answer == null) return HostError.NoAnswer,
    }
    if (turn.port != &session.served.port or
        turn.ingress != session.served.port.ingress)
        return HostError.ForeignTurn;
    try self.admitSessionOperation(session);
    try vows.ensureFreshVowId(self);
    try ensureFreshResolverId(self);
    const row = try vows.reserveRow(self, null, .plain, .none, self.next_vow);
    errdefer self.allocator.destroy(row);
    try self.resolver_index.ensureUnusedCapacity(self.allocator, 1);
    const vat_reservation = try self.vat.reserveResolverPair();
    const forward_reservation = try turn.reserveForwardVow(.local);

    const pair = self.vat.spawnReservedVow(vat_reservation);
    row.vow = pair.vow;
    vows.publishRow(self, row);
    self.next_vow += 1;
    const resolver_id = self.next_resolver;
    self.next_resolver += 1;
    self.resolver_index.putAssumeCapacity(resolver_id, .{
        .vow_id = row.id,
        .vat_resolver = pair.resolver,
    });
    turn.forwardReservedVow(forward_reservation, pair.vow);
    row.forwarded = .{ .session = .{ .peer = session.peer_handle, .local_answer = turn.origin == .eventual } };
    self.beginSessionOperation(session);
    return resolver_id;
}

/// Settle a resolver vow fulfilled (ADR-0102). Top-level: the settle runs the
/// deferred answer's listeners and pumps every session it dirtied, so it
/// refuses from inside a callback. A successful settle consumes the resolver.
/// Preparation failure leaves it live for retry. `value` must contain no
/// capability authority.
pub fn fulfill(self: *Host, resolver_id: u64, value: model.Argument) !void {
    try self.refuseReentry();
    if (!model.argumentIsPlainData(&value)) return HostError.ForeignArgument;
    if (self.resolver_index.get(resolver_id)) |entry| {
        const row = self.vows.get(entry.vow_id) orelse unreachable;
        if (row.forwarded == .owning) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const converted = try @import("../value_copy.zig").copy(@import("../value.zig").Value, arena.allocator(), value);
            return fulfillValue(self, resolver_id, converted, arena.allocator());
        }
    }
    try settle(self, resolver_id, .{ .fulfilled = value }, null);
}

/// Settle an owning-thread application value in the deferred caller's session.
/// Capability projections remain rollback-owned until settlement commits. This
/// path borrows leaf data and allocates only lowering containers in `arena`.
/// The existing Vat settlement scope owns the listener lifetime. Wire answers
/// transfer foreign occurrences through Node's ordinary outbound staging.
pub fn fulfillValue(self: *Host, resolver_id: u64, value: @import("../value.zig").Value, arena: std.mem.Allocator) !void {
    try self.refuseReentry();
    if (resolver_id == 0 or resolver_id >= self.next_resolver) return HostError.NoSuchResolver;
    const entry = self.resolver_index.get(resolver_id) orelse return actors.Error.AlreadySettled;
    const row = self.vows.get(entry.vow_id) orelse unreachable;
    if (row.forwarded == .owning) {
        const producer = row.forwarded.owning.producer;
        try producer.prepare(value);
        errdefer producer.cancelPreparation();
        try settle(self, resolver_id, .{ .fulfilled = .{ .void = {} } }, null);
        return;
    }
    const peer = row.forwardedPeer() orelse return HostError.ForeignArgument;
    const session = self.sessions.get(peer) orelse return HostError.ForeignArgument;
    const local_answer = row.forwarded.session.local_answer;
    var prepared = try self.prepareValues(session, arena, &.{value});
    defer prepared.deinit();
    // Only the served wire answer produces outbound occurrences. Local
    // listeners may enqueue their own sends, each with its own staging scope.
    const staging: ?*lower.PreparedValues = if (local_answer) null else &prepared;
    try settle(self, resolver_id, .{ .fulfilled = prepared.values[0] }, staging);
    // Local listeners have acquired their own canonical retains synchronously.
    // Only a wire answer transfers a projection into session-owned authority.
    if (local_answer) prepared.finishLocalBorrow() else _ = prepared.commit();
}

/// Break a resolver vow. `reason` is borrowed for this call. Ownership and
/// retry behavior match `fulfill`.
pub fn breakVow(self: *Host, resolver_id: u64, reason: []const u8) !void {
    try self.refuseReentry();
    try settle(self, resolver_id, .{ .broken = reason }, null);
}

/// Preserve an owning producer's typed failure through deferred settlement.
/// Wire breaks carry their existing protocol diagnostic. Neither kind proves
/// whether an external effect applied. Receipt outcome belongs to its owner.
pub fn reject(self: *Host, resolver_id: u64, kind: @import("../host/action.zig").VowFailure, reason: []const u8) !void {
    try self.refuseReentry();
    if (resolver_id == 0 or resolver_id >= self.next_resolver) return HostError.NoSuchResolver;
    const entry = self.resolver_index.get(resolver_id) orelse return actors.Error.AlreadySettled;
    const row = self.vows.get(entry.vow_id) orelse unreachable;
    if (row.forwarded != .owning) return settle(self, resolver_id, .{ .broken = reason }, null);
    const producer = row.forwarded.owning.producer;
    const previous = producer.failure_kind;
    producer.failure_kind = kind;
    errdefer producer.failure_kind = previous;
    try settle(self, resolver_id, .{ .broken = reason }, null);
}

/// Relinquish a resolver's answer. Session teardown may have consumed the
/// resolver already. That is complete cleanup, while an unminted id still
/// identifies a caller defect. Top-level ownership and retry rules match break.
pub fn abandon(self: *Host, resolver_id: u64, reason: []const u8) !void {
    self.resolverBreak(resolver_id, reason) catch |err| switch (err) {
        error.AlreadySettled => {},
        else => return err,
    };
}

fn settle(self: *Host, resolver_id: u64, resolution: actors.Resolution, staging: ?*lower.PreparedValues) !void {
    // An id this Host never minted is a caller defect, distinct from a
    // consumed settle authority.
    if (resolver_id == 0 or resolver_id >= self.next_resolver) return HostError.NoSuchResolver;
    const entry = self.resolver_index.get(resolver_id) orelse
        return actors.Error.AlreadySettled;
    const row = self.vows.get(entry.vow_id) orelse unreachable;
    const forwarded = row.forwarded;
    switch (resolution) {
        .fulfilled => |value| {
            if (staging) |prepared| {
                prepared.beginStaging();
                defer prepared.endStaging();
                try self.vat.fulfillVow(entry.vat_resolver, value);
            } else try self.vat.fulfillVow(entry.vat_resolver, value);
        },
        .broken => |reason| try self.vat.breakVow(entry.vat_resolver, reason),
        .give => unreachable,
    }
    settlement.markRowSettled(self, row);
    std.debug.assert(self.resolver_index.remove(resolver_id));
    std.debug.assert(self.vows.remove(entry.vow_id));
    self.allocator.destroy(row);

    if (forwarded == .owning) forwarded.owning.producer.release();
    if (forwarded == .session) {
        const peer_handle = forwarded.session.peer;
        const session = self.sessions.get(peer_handle) orelse return;
        self.finishSessionOperation(session);
        host_pump.markDirty(self, peer_handle);
        host_pump.finishCommittedWork(self, session);
    }
}

/// Local owning deferral reserves the existing Host/Vat resolver and listener
/// indexes. Its turn participant retracts the settle authority on outer-turn
/// failure. Ordinary success leaves only the durable caller's explicit handle.
fn deferOwned(self: *Host, turn: *actors.Turn) !u64 {
    const producer = try @import("../host/local_delivery.zig").producer(turn);
    if (producer.host != self or turn.port != null or producer.phase != .running or producer.lease == null)
        return HostError.ForeignTurn;
    switch (self.lifecyclePhase()) {
        .active, .finishing => {},
        .terminating, .closed => return error.HostClosing,
    }
    switch (turn.origin) {
        .eventual => |eventual| if (eventual.answer == null) return HostError.NoAnswer,
        else => return HostError.NoAnswer,
    }
    try vows.ensureFreshVowId(self);
    try ensureFreshResolverId(self);
    const row = try vows.reserveRow(self, null, .plain, .none, self.next_vow);
    errdefer self.allocator.destroy(row);
    try self.resolver_index.ensureUnusedCapacity(self.allocator, 1);
    const reservation = try self.vat.reserveResolverPair();
    const forward = try turn.reserveForwardVow(.local);
    errdefer turn.cancelForwardVow(forward);
    try self.vat.enrollTurn(.{ .ctx = row, .commit = keepOwnedResolver, .abort = abortOwnedResolver });
    const pair = self.vat.spawnReservedVow(reservation);
    row.vow = pair.vow;
    const resolver = self.next_resolver;
    producer.retain();
    row.forwarded = .{ .owning = .{ .producer = producer, .resolver = resolver } };
    vows.publishRow(self, row);
    self.next_vow += 1;
    self.next_resolver += 1;
    self.resolver_index.putAssumeCapacity(resolver, .{ .vow_id = row.id, .vat_resolver = pair.resolver });
    turn.forwardReservedVow(forward, pair.vow);
    return resolver;
}

fn keepOwnedResolver(_: *anyopaque, _: *actors.Vat) void {}

fn abortOwnedResolver(ctx: *anyopaque, _: *actors.Vat, _: []const u8) void {
    const row: *settlement.VowRow = @ptrCast(@alignCast(ctx));
    terminateOwned(row.host, row.forwarded.owning.resolver);
}

/// Terminal rollback/cancellation consumes only an exclusively held owning
/// resolver. The static break reaches its original producer without allocation.
/// The failed turn's producer participant preserves the actual failure text.
pub fn terminateOwned(self: *Host, resolver: u64) void {
    const entry = self.resolver_index.get(resolver) orelse unreachable;
    const row = self.vows.get(entry.vow_id) orelse unreachable;
    const producer = row.forwarded.owning.producer;
    self.vat.breakVowTerminal(entry.vat_resolver, "TurnAborted");
    settlement.markRowSettled(self, row);
    std.debug.assert(self.resolver_index.remove(resolver));
    std.debug.assert(self.vows.remove(row.id));
    self.allocator.destroy(row);
    producer.release();
}
