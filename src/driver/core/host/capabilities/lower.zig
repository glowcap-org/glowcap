//! Host capability lowering: the transaction that projects opaque Host
//! capabilities and application Values onto one session, retaining exact
//! rollback authority until the semantic consequence has been published.
//!
//! Registry identity, Vat actors, Port exports, Node routes, and deferred
//! promise rows remain owned by their respective modules. This owner only
//! coordinates their prepare/commit/rollback edges and the occurrence leases
//! that cross an inline-Passable staging window.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");

const host_mod = @import("../../host.zig");
const capability = @import("../../capability.zig");
const capability_promise = @import("../../capability_promise.zig");
const value_mod = @import("../../value.zig");
const identity = @import("identity.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;

pub const CapabilityLoweringReceipt = union(enum) {
    local: struct {
        session: *HostSession,
        actor_id: u64,
        position: u64,
    },
    foreign: engine.Node.ForeignEnrollmentReceipt,
    deferred_projection: struct {
        session: *HostSession,
        promise_id: capability.PromiseId,
        export_position: model.ExportPosition,
    },
};
const capability_lowering_receipt_budget_bytes = 40;
comptime {
    if (@sizeOf(CapabilityLoweringReceipt) > capability_lowering_receipt_budget_bytes)
        @compileError("capability lowering rollback receipt exceeded its five-word stack budget");
}

const CapabilityLoweringReceipts = struct {
    const inline_capacity = 8;

    inline_items: [inline_capacity]CapabilityLoweringReceipt = undefined,
    len: usize = 0,
    spill: std.ArrayListUnmanaged(CapabilityLoweringReceipt) = .empty,

    fn ensureOne(self: *CapabilityLoweringReceipts, arena: std.mem.Allocator) !void {
        if (self.spill.capacity != 0) {
            try self.spill.ensureUnusedCapacity(arena, 1);
            return;
        }
        if (self.len < inline_capacity) return;
        try self.spill.ensureTotalCapacityPrecise(arena, inline_capacity + 1);
        self.spill.appendSliceAssumeCapacity(self.inline_items[0..self.len]);
    }

    fn appendAssumeCapacity(self: *CapabilityLoweringReceipts, receipt: CapabilityLoweringReceipt) void {
        if (self.spill.capacity != 0)
            self.spill.appendAssumeCapacity(receipt)
        else
            self.inline_items[self.len] = receipt;
        self.len += 1;
    }

    fn items(self: *const CapabilityLoweringReceipts) []const CapabilityLoweringReceipt {
        return if (self.spill.capacity != 0) self.spill.items else self.inline_items[0..self.len];
    }
};

const LoweredCapability = struct {
    reference: model.Reference,
    receipt: ?CapabilityLoweringReceipt,
};

/// One value lowering that has not yet crossed its semantic commit point.
/// Public only for Host-core sibling modules; adapters call the complete
/// send/tell/vow operations instead of managing this transaction.
pub const PreparedValues = struct {
    host: *Host,
    values: []model.Argument,
    receipts: CapabilityLoweringReceipts,
    committed: bool = false,
    /// `holdForTurn` reserved room for these receipts in the running turn.
    turn_held: bool = false,

    pub fn commit(self: *PreparedValues) []model.Argument {
        self.committed = true;
        if (self.turn_held) {
            const receipts = self.receipts.items();
            self.host.turn_receipts.held.appendSliceAssumeCapacity(receipts);
            self.host.turn_receipts.reserved -= receipts.len;
            self.turn_held = false;
        }
        return self.values;
    }

    /// A local deferred reply's listeners acquire canonical Host custody
    /// synchronously. Reclaim newly minted local export names unless a listener
    /// published a wire occurrence. Foreign routes retain their normal owner.
    pub fn finishLocalBorrow(self: *PreparedValues) void {
        for (self.receipts.items()) |receipt| switch (receipt) {
            .local => |local| {
                if (local.session.served.port.peer.session_state.exportRefcount(.from(local.position)) == 1)
                    local.session.served.port.rollbackExport(&self.host.vat, .{ .local = local.actor_id }, local.position);
            },
            .foreign, .deferred_projection => {},
        };
        self.committed = true;
    }

    pub fn deinit(self: *PreparedValues) void {
        if (!self.committed) rollbackCapabilityLowerings(self.host, self.receipts.items());
        if (self.turn_held) self.host.turn_receipts.reserved -= self.receipts.items().len;
        self.* = undefined;
    }
};

/// Lowering receipts of sends made in the running turn, and the room
/// `holdForTurn` reserved for receipts not yet committed.
pub const TurnReceipts = struct {
    held: std.ArrayListUnmanaged(CapabilityLoweringReceipt) = .empty,
    reserved: usize = 0,

    pub fn deinit(self: *TurnReceipts, allocator: std.mem.Allocator) void {
        self.held.deinit(allocator);
    }
};

/// Keep `prepared`'s receipts until the running turn's outcome when its send
/// is made inside a turn (ADR-0194). Call before the send: enrollment and
/// room are the fallible steps, so `commit` then moves the receipts without
/// allocating. Outside a turn this does nothing.
pub fn holdForTurn(self: *Host, prepared: *PreparedValues) !void {
    if (self.vat.turn_depth == 0) return;
    const count = prepared.receipts.items().len;
    if (count == 0) return;
    try self.vat.enrollTurn(.{ .ctx = self, .commit = commitTurnReceipts, .abort = abortTurnReceipts });
    try self.turn_receipts.held.ensureUnusedCapacity(self.allocator, self.turn_receipts.reserved + count);
    self.turn_receipts.reserved += count;
    prepared.turn_held = true;
}

fn commitTurnReceipts(ctx: *anyopaque, vat: *actors.Vat) void {
    _ = vat;
    const self: *Host = @ptrCast(@alignCast(ctx));
    self.turn_receipts.held.clearRetainingCapacity();
}

/// The Port has already retracted the failed turn's sends, which returned each
/// projection they named to its baseline. Roll back the projections those
/// sends minted that no surviving message names. Node staging withdraws its
/// carriers, gifts and leases. A committed foreign enrollment stays as the
/// Session import's canonical route memo, with no additional import retain;
/// a reentrant surviving turn may already name it. Import retirement owns it.
fn abortTurnReceipts(ctx: *anyopaque, vat: *actors.Vat, reason: []const u8) void {
    _ = vat;
    _ = reason;
    const self: *Host = @ptrCast(@alignCast(ctx));
    const receipts = self.turn_receipts.held.items;
    var i = receipts.len;
    while (i != 0) {
        i -= 1;
        switch (receipts[i]) {
            .local => |local| if (unshared(local.session, local.position))
                local.session.served.port.rollbackExport(&self.vat, .{ .local = local.actor_id }, local.position),
            .deferred_projection => |projection| if (unshared(projection.session, projection.export_position.int()))
                capability_promise.rollbackProjection(self, projection.promise_id, projection.session, projection.export_position),
            .foreign => {},
        }
    }
    self.turn_receipts.held.clearRetainingCapacity();
}

fn unshared(session: *HostSession, position: u64) bool {
    return session.served.port.peer.session_state.exportRefcount(.from(position)) == 1;
}

/// One extra Host retain accompanying a capability occurrence while an
/// owning-tier message crosses into the engine. An inline-Passable batch marks
/// it transferred; otherwise the caller rolls it back immediately after the
/// synchronous enqueue.
pub const StagedCapabilityRetain = struct {
    ref: capability.Ref,
    transferred: bool = false,
};

fn countValueCapabilitiesAt(
    values: []const value_mod.Value,
    depth: usize,
) error{ OutOfMemory, NestingTooDeep }!usize {
    if (depth > model.max_value_depth) return error.NestingTooDeep;
    var count: usize = 0;
    for (values) |value| {
        const added: usize = switch (value) {
            .capability => 1,
            .list, .set => |items| try countValueCapabilitiesAt(items, depth + 1),
            .tagged => |tagged| try countValueCapabilitiesAt(tagged.value, depth + 1),
            .@"struct" => |entries| blk: {
                var nested: usize = 0;
                for (entries) |entry| nested = std.math.add(
                    usize,
                    nested,
                    try countValueCapabilitiesAt(&.{entry.value}, depth + 1),
                ) catch return error.OutOfMemory;
                break :blk nested;
            },
            else => 0,
        };
        count = std.math.add(usize, count, added) catch return error.OutOfMemory;
    }
    return count;
}

fn countValueCapabilities(values: []const value_mod.Value) error{ OutOfMemory, NestingTooDeep }!usize {
    return countValueCapabilitiesAt(values, 0);
}

fn retainValueCapabilitiesInto(
    self: *Host,
    values: []const value_mod.Value,
    out: []StagedCapabilityRetain,
    index: *usize,
    depth: usize,
) !void {
    if (depth > model.max_value_depth) return error.NestingTooDeep;
    for (values) |value| switch (value) {
        .capability => |ref| {
            const target = self.capabilities.resolve(ref) orelse return error.UnknownCapability;
            out[index.*] = .{ .ref = try self.capabilities.retain(self.allocator, target) };
            index.* += 1;
        },
        .list, .set => |items| try retainValueCapabilitiesInto(self, items, out, index, depth + 1),
        .tagged => |tagged| try retainValueCapabilitiesInto(self, tagged.value, out, index, depth + 1),
        .@"struct" => |entries| for (entries) |entry|
            try retainValueCapabilitiesInto(self, &.{entry.value}, out, index, depth + 1),
        else => {},
    };
}

pub fn retainValueCapabilities(
    self: *Host,
    arena: std.mem.Allocator,
    values: []const value_mod.Value,
) ![]StagedCapabilityRetain {
    const retained = try arena.alloc(StagedCapabilityRetain, try countValueCapabilities(values));
    var index: usize = 0;
    errdefer while (index != 0) {
        index -= 1;
        const retired = self.capabilities.release(retained[index].ref, 1) catch unreachable;
        std.debug.assert(retired == null);
    };
    try retainValueCapabilitiesInto(self, values, retained, &index, 0);
    std.debug.assert(index == retained.len);
    return retained;
}

pub fn releaseUntransferredCapabilityRetains(
    self: *Host,
    retained: []StagedCapabilityRetain,
) void {
    for (retained) |item| {
        if (item.transferred) continue;
        const retired = self.capabilities.release(item.ref, 1) catch unreachable;
        std.debug.assert(retired == null);
    }
}

pub fn releaseValueCapabilitiesTerminalAt(
    self: *Host,
    values: []const value_mod.Value,
    closing_peer: ?engine.PeerHandle,
) void {
    for (values) |value| switch (value) {
        .capability => |ref| identity.releaseCapabilityTerminal(self, ref, closing_peer),
        .list, .set => |items| releaseValueCapabilitiesTerminalAt(self, items, closing_peer),
        .tagged => |tagged| releaseValueCapabilitiesTerminalAt(self, tagged.value, closing_peer),
        .@"struct" => |entries| for (entries) |entry|
            releaseValueCapabilitiesTerminalAt(self, &.{entry.value}, closing_peer),
        else => {},
    };
}

fn bindOutboundStagingLeaseArgument(
    arg: model.Argument,
    retained: []StagedCapabilityRetain,
    leases: []engine.Node.OutboundStagingLease,
    index: *usize,
) void {
    switch (arg) {
        .reference => |reference| {
            const route_id: model.CapabilityRouteId = switch (reference) {
                .routed => |routed| routed.id,
                else => .from(0),
            };
            leases[index.*] = .{
                .route_id = route_id,
                .capability = retained[index.*].ref.raw(),
            };
            index.* += 1;
        },
        .list, .set => |items| for (items) |item|
            bindOutboundStagingLeaseArgument(item, retained, leases, index),
        .tagged => |tagged| for (tagged.value) |item|
            bindOutboundStagingLeaseArgument(item, retained, leases, index),
        .@"struct" => |entries| for (entries) |entry|
            bindOutboundStagingLeaseArgument(entry.value, retained, leases, index),
        else => {},
    }
}

pub fn beginOutboundStagingLeases(
    self: *Host,
    arena: std.mem.Allocator,
    args: []const model.Argument,
    retained: []StagedCapabilityRetain,
) ![]engine.Node.OutboundStagingLease {
    const leases = try arena.alloc(engine.Node.OutboundStagingLease, retained.len);
    var index: usize = 0;
    for (args) |arg| bindOutboundStagingLeaseArgument(arg, retained, leases, &index);
    std.debug.assert(index == retained.len);
    self.node.beginOutboundStagingLeases(leases);
    return leases;
}

pub fn finishOutboundStagingLeases(
    self: *Host,
    retained: []StagedCapabilityRetain,
    leases: []const engine.Node.OutboundStagingLease,
) void {
    self.node.endOutboundStagingLeases();
    for (retained, leases) |*item, lease| item.transferred = lease.claimed;
}

pub fn servedSendWithStaging(
    self: *Host,
    session: *HostSession,
    target: actors.Ref,
    msg: actors.Message,
    arena: std.mem.Allocator,
    retained: []StagedCapabilityRetain,
) !actors.Vow {
    const leases = try beginOutboundStagingLeases(self, arena, msg.args, retained);
    errdefer finishOutboundStagingLeases(self, retained, leases);
    const vow = try session.served.send(&self.vat, target, msg);
    finishOutboundStagingLeases(self, retained, leases);
    return vow;
}

pub fn servedTellWithStaging(
    self: *Host,
    session: *HostSession,
    target: actors.Ref,
    msg: actors.Message,
    arena: std.mem.Allocator,
    retained: []StagedCapabilityRetain,
) !void {
    const leases = try beginOutboundStagingLeases(self, arena, msg.args, retained);
    errdefer finishOutboundStagingLeases(self, retained, leases);
    try session.served.tell(&self.vat, target, msg);
    finishOutboundStagingLeases(self, retained, leases);
}

/// One capability lowering whose newly-created projection remains
/// rollback-owned until the surrounding Host-core transaction commits.
/// Sibling modules use this instead of discarding the receipt returned by the
/// private lowering walk.
pub const PreparedCapability = struct {
    host: *Host,
    lowered: LoweredCapability,
    committed: bool = false,

    pub fn reference(self: *const PreparedCapability) model.Reference {
        return self.lowered.reference;
    }

    pub fn commit(self: *PreparedCapability) model.Reference {
        self.committed = true;
        return self.lowered.reference;
    }

    pub fn deinit(self: *PreparedCapability) void {
        if (!self.committed) if (self.lowered.receipt) |receipt| {
            const receipts = [_]CapabilityLoweringReceipt{receipt};
            rollbackCapabilityLowerings(self.host, &receipts);
        };
        self.* = undefined;
    }
};

fn rollbackCapabilityLowerings(self: *Host, receipts: []const CapabilityLoweringReceipt) void {
    var i = receipts.len;
    while (i != 0) {
        i -= 1;
        switch (receipts[i]) {
            .local => |local| local.session.served.port.rollbackExport(
                &self.vat,
                .{ .local = local.actor_id },
                local.position,
            ),
            .foreign => |foreign| self.node.abandonForeignEnrollment(foreign),
            .deferred_projection => |projection| capability_promise.rollbackProjection(
                self,
                projection.promise_id,
                projection.session,
                projection.export_position,
            ),
        }
    }
}

/// Lower a live Host identity onto the session that can currently name it,
/// returning rollback authority when this call minted an otherwise unseen
/// Port projection or Node enrollment.
fn lowerCapabilityTracked(self: *Host, session: *HostSession, ref: capability.Ref) !LoweredCapability {
    self.assertOwner();
    try self.checkSession(session);
    const target = self.capabilities.resolve(ref) orelse return error.UnknownCapability;
    return switch (target) {
        .local => |actor_id| blk: {
            if (!self.vat.hasActor(actor_id)) return actors.Error.NoSuchActor;
            const actor: actors.Ref = .{ .local = actor_id };
            const projection = try session.served.port.prepareProjection(&self.vat, actor);
            break :blk .{
                .reference = .{ .near = projection.near },
                .receipt = if (projection.created) .{ .local = .{
                    .session = session,
                    .actor_id = actor_id,
                    .position = projection.near.export_position.int(),
                } } else null,
            };
        },
        .remote => |remote| blk: {
            const home = self.sessions.get(remote.peer_handle) orelse return error.UnknownCapability;
            try self.checkSession(home);
            if (!home.served.port.peer.session_state.holdsImport(remote.far.import_position)) return error.UnknownCapability;
            if (home.served.port.peer.session_state.hostCapabilityFor(remote.far.import_position) != ref.raw())
                return error.UnknownCapability;
            if (remote.peer_handle != session.peer_handle) {
                const enrollment = try self.node.prepareForeignEnrollment(remote.peer_handle, .{ .far = remote.far });
                break :blk .{
                    .reference = enrollment.reference,
                    .receipt = if (enrollment.abandon) |abandon| .{ .foreign = abandon } else null,
                };
            }
            break :blk .{ .reference = .{ .far = remote.far }, .receipt = null };
        },
        .deferred => |id| blk: {
            const row = self.capability_promises.get(id) orelse return error.UnknownCapability;
            switch (row.state) {
                .fulfilled => |resolved| break :blk try lowerCapabilityTracked(self, session, resolved),
                .broken => return error.PromiseBroken,
                .pending, .settling => {
                    const projection = try capability_promise.prepareProjection(self, id, session);
                    break :blk .{
                        .reference = projection.reference,
                        .receipt = if (projection.created) .{ .deferred_projection = .{
                            .session = session,
                            .promise_id = id,
                            .export_position = projection.reference.near.export_position,
                        } } else null,
                    };
                },
            }
        },
    };
}

/// Lower one capability and publish any canonical projection it creates.
pub fn lowerCapability(self: *Host, session: *HostSession, ref: capability.Ref) !model.Reference {
    var prepared = try prepareCapability(self, session, ref);
    defer prepared.deinit();
    return prepared.commit();
}

/// Prepare a capability lowering without surrendering rollback authority.
/// Host-core settlement bridges commit only after their resolve/gift
/// consequence is durably queued.
pub fn prepareCapability(self: *Host, session: *HostSession, ref: capability.Ref) !PreparedCapability {
    return .{ .host = self, .lowered = try lowerCapabilityTracked(self, session, ref) };
}

/// Lower one owning-tier `Value` into a wire-shaped `model.Argument` on
/// `session`: data arms are borrowed as they stand, and each `.capability`
/// lowers through `lowerCapability`, so a local target projects on this
/// session's Port and a cross-home capability becomes a routable Node
/// reference. Spine containers are allocated in `arena`; leaf bytes stay
/// borrowed. A stale, foreign, or overdeep value fails the whole transaction
/// closed and rolls back every projection it created.
pub fn lowerValue(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    value: value_mod.Value,
) anyerror!model.Argument {
    var receipts = CapabilityLoweringReceipts{};
    errdefer rollbackCapabilityLowerings(self, receipts.items());
    return lowerValueInner(self, session, arena, value, &receipts, 0);
}

fn lowerValueInner(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    value: value_mod.Value,
    receipts: *CapabilityLoweringReceipts,
    depth: usize,
) anyerror!model.Argument {
    if (depth > model.max_value_depth) return error.NestingTooDeep;
    return switch (value) {
        .bytes => |v| .{ .bytes = v },
        .symbol => |v| .{ .symbol = v },
        .capability => |ref| blk: {
            try receipts.ensureOne(arena);
            const lowered = try lowerCapabilityTracked(self, session, ref);
            if (lowered.receipt) |receipt| receipts.appendAssumeCapacity(receipt);
            break :blk .{ .reference = lowered.reference };
        },
        .@"error" => |reason| .{ .@"error" = reason },
        .string => |v| .{ .string = v },
        .integer => |v| .{ .integer = v },
        .boolean => |v| .{ .boolean = v },
        .list => |items| .{ .list = try lowerValuesInner(self, session, arena, items, receipts, depth + 1) },
        .void => .{ .void = {} },
        .float64 => |v| .{ .float64 = v },
        .set => |items| .{ .set = try lowerValuesInner(self, session, arena, items, receipts, depth + 1) },
        .tagged => |tagged| .{ .tagged = .{
            .tag = tagged.tag,
            .value = try lowerValuesInner(self, session, arena, tagged.value, receipts, depth + 1),
        } },
        .keyword => |v| .{ .keyword = v },
        .big_integer => |v| .{ .big_integer = v },
        .@"struct" => |entries| blk: {
            const out = try arena.alloc(model.StructEntry, entries.len);
            for (entries, 0..) |entry, i| out[i] = .{
                .key = entry.key,
                .value = try lowerValueInner(self, session, arena, entry.value, receipts, depth + 1),
            };
            break :blk .{ .@"struct" = out };
        },
    };
}

/// `lowerValue` over a whole argument list (see it for the contract).
pub fn lowerValues(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    values: []const value_mod.Value,
) anyerror![]model.Argument {
    var prepared = try prepareValues(self, session, arena, values);
    defer prepared.deinit();
    return prepared.commit();
}

/// Prepare a transactional owning-tier value lowering. Public only for
/// Host-core siblings; `deinit` rolls back until `commit` is called.
pub fn prepareValues(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    values: []const value_mod.Value,
) anyerror!PreparedValues {
    var receipts = CapabilityLoweringReceipts{};
    errdefer rollbackCapabilityLowerings(self, receipts.items());
    const lowered = try lowerValuesInner(self, session, arena, values, &receipts, 0);
    return .{ .host = self, .values = lowered, .receipts = receipts };
}

fn lowerValuesInner(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    values: []const value_mod.Value,
    receipts: *CapabilityLoweringReceipts,
    depth: usize,
) anyerror![]model.Argument {
    if (depth > model.max_value_depth) return error.NestingTooDeep;
    const out = try arena.alloc(model.Argument, values.len);
    for (values, 0..) |value, i|
        out[i] = try lowerValueInner(self, session, arena, value, receipts, depth);
    return out;
}
