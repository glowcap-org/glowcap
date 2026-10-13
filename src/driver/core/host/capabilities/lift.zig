//! Host value lifting: the complete transaction that turns one bounded
//! session Argument tree into application Values, commits or rolls back every
//! capability observation, and retires every occurrence a failed projection
//! did not expose.

const std = @import("std");

const model = @import("model");

const host_mod = @import("../../host.zig");
const value_mod = @import("../../value.zig");
const host_pump = @import("../pump.zig");
const identity = @import("identity.zig");
const capability_promise = @import("../../capability_promise.zig");

const Host = host_mod.Host;
const HostSession = host_mod.HostSession;
const CapabilityLift = identity.CapabilityLift;

const CapabilityLiftReceipts = struct {
    const inline_capacity = 8;

    inline_items: [inline_capacity]CapabilityLift = undefined,
    len: usize = 0,
    reference_count: usize = 0,
    spill: std.ArrayListUnmanaged(CapabilityLift) = .empty,

    fn ensureOne(self: *CapabilityLiftReceipts, arena: std.mem.Allocator) !void {
        if (self.spill.capacity != 0) {
            try self.spill.ensureUnusedCapacity(arena, 1);
            return;
        }
        if (self.len < inline_capacity) return;
        try self.spill.ensureTotalCapacityPrecise(arena, inline_capacity + 1);
        self.spill.appendSliceAssumeCapacity(self.inline_items[0..self.len]);
    }

    fn appendAssumeCapacity(
        self: *CapabilityLiftReceipts,
        lift: CapabilityLift,
        source: enum { reference, inline_give },
    ) void {
        if (self.spill.capacity != 0)
            self.spill.appendAssumeCapacity(lift)
        else
            self.inline_items[self.len] = lift;
        self.len += 1;
        if (source == .reference) self.reference_count += 1;
    }

    fn items(self: *const CapabilityLiftReceipts) []const CapabilityLift {
        return if (self.spill.capacity != 0) self.spill.items else self.inline_items[0..self.len];
    }
};

fn commitCapabilityLifts(self: *Host, lifts: []const CapabilityLift) void {
    for (lifts) |lifted| identity.commitCapabilityLift(self, lifted);
}

fn rollbackCapabilityLifts(self: *Host, lifts: []const CapabilityLift) void {
    var i = lifts.len;
    while (i != 0) {
        i -= 1;
        identity.rollbackCapabilityLift(self, lifts[i]);
    }
}

fn discardUnprojectedArgumentReferences(
    self: *Host,
    session: *HostSession,
    arg: model.Argument,
    skip: *usize,
    depth: usize,
) error{NestingTooDeep}!void {
    if (depth > model.max_value_depth) return error.NestingTooDeep;
    switch (arg) {
        .reference => |reference| {
            if (skip.* != 0)
                skip.* -= 1
            else
                identity.discardCapabilityObservation(self, session, reference);
        },
        .list, .set => |items| for (items) |item|
            try discardUnprojectedArgumentReferences(self, session, item, skip, depth + 1),
        .tagged => |tagged| for (tagged.value) |item|
            try discardUnprojectedArgumentReferences(self, session, item, skip, depth + 1),
        .@"struct" => |entries| for (entries) |entry|
            try discardUnprojectedArgumentReferences(self, session, entry.value, skip, depth + 1),
        else => {},
    }
}

fn failValuesProjection(
    self: *Host,
    session: *HostSession,
    args: []const model.Argument,
    lifts: *const CapabilityLiftReceipts,
) void {
    const items = lifts.items();
    // Redeemed routes become consumed facts before their exact Host retains
    // roll back. A failed application projection is terminal for this wire
    // occurrence; it is never made retryable by leaving a route half-owned.
    commitCapabilityLifts(self, items);
    rollbackCapabilityLifts(self, items);

    // Only `.reference` observations correspond to positions in this walk.
    // Inline gives have rollback receipts too, but counting them here would
    // skip a later reference and strand invisible wire authority.
    var skip = lifts.reference_count;
    for (args) |arg| discardUnprojectedArgumentReferences(self, session, arg, &skip, 0) catch {
        // An overdeep source cannot be enumerated safely under the same stack
        // bound. Completed observations above are already retired; condemn the
        // source so terminal session teardown remains the last owner of any
        // unvisited wire retains.
        host_pump.condemnAndClose(
            self,
            session,
            .resource_exhausted,
            "failed capability projection cleanup",
        );
        return;
    };
    std.debug.assert(skip == 0);
}

fn failValueProjection(
    self: *Host,
    session: *HostSession,
    arg: model.Argument,
    lifts: *const CapabilityLiftReceipts,
) void {
    failValuesProjection(self, session, &.{arg}, lifts);
}

/// Retire an unexposed borrowed value without materializing its representation.
/// This uses the same bounded reference walk and terminal cleanup as a failed
/// projection. The caller retains no reference from the value afterward.
pub fn discardValueObservation(self: *Host, session: *HostSession, arg: model.Argument) void {
    const lifts = CapabilityLiftReceipts{};
    failValueProjection(self, session, arg, &lifts);
}

const ByteOwnership = enum {
    borrowed,
    owned,

    fn materialize(comptime self: ByteOwnership, arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
        return if (self == .owned) try arena.dupe(u8, bytes) else bytes;
    }
};

/// Materialize one turn-borrowed wire value for an owner that outlives the
/// turn. One walk copies bytes/spines and acquires canonical capability retains.
pub fn ownValue(self: *Host, session: *HostSession, arena: std.mem.Allocator, arg: model.Argument) !value_mod.Value {
    var lifts = CapabilityLiftReceipts{};
    // Receipt spill is temporary; the action arena retains only its Value.
    defer lifts.spill.deinit(self.allocator);
    const value = liftValueInner(self, session, arena, arg, &lifts, 0, .owned) catch |err| {
        failValueProjection(self, session, arg, &lifts);
        return err;
    };
    commitCapabilityLifts(self, lifts.items());
    return value;
}

/// The lift walk keeps `anyerror`: `liftValueInner` and `liftValuesInner` are
/// mutually recursive, which this toolchain refuses to resolve as inferred
/// sets, and the walk's true set mirrors the actor-turn error vocabulary
/// reached through `liftCapabilityTracked`.
fn liftValueInner(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    arg: model.Argument,
    lifts: *CapabilityLiftReceipts,
    depth: usize,
    comptime bytes: ByteOwnership,
) anyerror!value_mod.Value {
    if (depth > model.max_value_depth) return error.NestingTooDeep;
    return switch (arg) {
        .bytes => |v| .{ .bytes = try bytes.materialize(arena, v) },
        .symbol => |v| .{ .symbol = try bytes.materialize(arena, v) },
        .reference => |reference| blk: {
            try lifts.ensureOne(if (bytes == .owned) self.allocator else arena);
            const lifted = try identity.liftCapabilityTracked(self, session, reference);
            lifts.appendAssumeCapacity(lifted, .reference);
            break :blk .{ .capability = lifted.ref };
        },
        .@"error" => |reason| .{ .@"error" = .{ .message = try bytes.materialize(arena, reason.message) } },
        .string => |v| .{ .string = try bytes.materialize(arena, v) },
        .integer => |v| .{ .integer = v },
        .boolean => |v| .{ .boolean = v },
        .list => |items| .{ .list = try liftValuesInner(self, session, arena, items, lifts, depth + 1, bytes) },
        .void => .{ .void = {} },
        .float64 => |v| .{ .float64 = v },
        .set => |items| .{ .set = try liftValuesInner(self, session, arena, items, lifts, depth + 1, bytes) },
        .tagged => |tagged| .{ .tagged = .{
            .tag = try bytes.materialize(arena, tagged.tag),
            .value = try liftValuesInner(self, session, arena, tagged.value, lifts, depth + 1, bytes),
        } },
        .keyword => |v| .{ .keyword = try bytes.materialize(arena, v) },
        .big_integer => |v| .{ .big_integer = .{ .negative = v.negative, .digits = try bytes.materialize(arena, v.digits) } },
        .@"struct" => |entries| blk: {
            const out = try arena.alloc(value_mod.Value.StructEntry, entries.len);
            for (entries, 0..) |entry, i| out[i] = .{
                .key = try bytes.materialize(arena, entry.key),
                .value = try liftValueInner(self, session, arena, entry.value, lifts, depth + 1, bytes),
            };
            break :blk .{ .@"struct" = out };
        },
        .handoff => |handoff| switch (handoff.*) {
            .give => |give| blk: {
                try lifts.ensureOne(if (bytes == .owned) self.allocator else arena);
                const lifted = try capability_promise.liftInlineGive(self, session, give);
                lifts.appendAssumeCapacity(lifted, .inline_give);
                break :blk .{ .capability = lifted.ref };
            },
            // A receive is an exporter bootstrap request, never an
            // application Passable value.
            .receive => error.UnsupportedValue,
        },
    };
}

fn liftValuesInner(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    args: []const model.Argument,
    lifts: *CapabilityLiftReceipts,
    depth: usize,
    comptime bytes: ByteOwnership,
) anyerror![]value_mod.Value {
    if (depth > model.max_value_depth) return error.NestingTooDeep;
    const out = try arena.alloc(value_mod.Value, args.len);
    for (args, 0..) |arg, i|
        out[i] = try liftValueInner(self, session, arena, arg, lifts, depth, bytes);
    return out;
}

/// Lift one wire-shaped argument into the Host's `Value`: every
/// reference becomes an opaque Host capability through the canonical identity
/// owner. Spine containers are allocated in `arena`. Leaf bytes stay borrowed.
/// Any failure retires completed and unvisited observations as one transaction.
pub fn liftValue(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    arg: model.Argument,
) anyerror!value_mod.Value {
    var lifts = CapabilityLiftReceipts{};
    const value = liftValueInner(self, session, arena, arg, &lifts, 0, .borrowed) catch |err| {
        failValueProjection(self, session, arg, &lifts);
        return err;
    };
    commitCapabilityLifts(self, lifts.items());
    return value;
}

fn projectedValueType(comptime project: anytype) type {
    const return_type = @typeInfo(@TypeOf(project)).@"fn".return_type.?;
    return @typeInfo(return_type).error_union.payload;
}

/// Lift and project one application-facing value as one transaction. The
/// callback owns representation only. On any failure this Host rolls back
/// completed lifts and retires every reference observation not exposed.
pub fn projectValue(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    arg: model.Argument,
    context: anytype,
    comptime project: anytype,
) anyerror!projectedValueType(project) {
    var lifts = CapabilityLiftReceipts{};
    const value = liftValueInner(self, session, arena, arg, &lifts, 0, .borrowed) catch |err| {
        failValueProjection(self, session, arg, &lifts);
        return err;
    };
    const projected = project(context, value) catch |err| {
        failValueProjection(self, session, arg, &lifts);
        return err;
    };
    commitCapabilityLifts(self, lifts.items());
    return projected;
}

/// `projectValue` over a whole argument list under one capability
/// transaction. A failure anywhere retires the complete unexposed input.
pub fn projectValues(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    args: []const model.Argument,
    context: anytype,
    comptime project: anytype,
) anyerror!projectedValueType(project) {
    var lifts = CapabilityLiftReceipts{};
    const values = liftValuesInner(self, session, arena, args, &lifts, 0, .borrowed) catch |err| {
        failValuesProjection(self, session, args, &lifts);
        return err;
    };
    const projected = project(context, values) catch |err| {
        failValuesProjection(self, session, args, &lifts);
        return err;
    };
    commitCapabilityLifts(self, lifts.items());
    return projected;
}

/// `liftValue` over a whole argument list, under one receipts scope: a
/// failure anywhere retires every completed and unvisited observation.
pub fn liftValues(
    self: *Host,
    session: *HostSession,
    arena: std.mem.Allocator,
    args: []const model.Argument,
) anyerror![]value_mod.Value {
    var lifts = CapabilityLiftReceipts{};
    const values = liftValuesInner(self, session, arena, args, &lifts, 0, .borrowed) catch |err| {
        failValuesProjection(self, session, args, &lifts);
        return err;
    };
    commitCapabilityLifts(self, lifts.items());
    return values;
}
