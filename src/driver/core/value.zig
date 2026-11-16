//! The Host's passable-value vocabulary (ADR-0026): `Value` is what an
//! application passes to and receives from the Host's opaque-capability
//! verbs. It mirrors the codec-neutral `model.Argument` data arms,
//! with one difference: a capability is the opaque
//! Host-scoped `Capability`, never a wire position or an actor id. The
//! translation bodies live in `host/capabilities/lower.zig` and `lift.zig`.
//! `driver_core.Host` exposes their direct aliases where the session context
//! both directions need is in scope, the same boundary the C ABI crosses.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const capability = @import("capability.zig");

/// The opaque Host-scoped capability identity (see `capability.Ref`).
pub const Capability = capability.Ref;

/// The depth of the items of a container at `depth`, or `ValueTooDeep` when
/// `model.mayHoldItems` refuses them. Shared by the walks over `Value` here and
/// in `value_copy.zig`, which import it from this file.
pub inline fn itemsDepth(depth: usize) error{ValueTooDeep}!usize {
    if (!model.mayHoldItems(depth)) return error.ValueTooDeep;
    return depth + 1;
}

/// A passable value on the Host. Data arms mirror
/// `model.Argument`. A capability mention is opaque. There is no handoff arm
/// because the host redeems a give before the application sees it. An Error is
/// a first-class value and remains distinct from `Reply.broken`: returning one
/// fulfills with an Error, while breaking rejects the reply. `integers` is
/// the list of the integers in its slice, lent as one leaf (ADR-0064): a
/// send reads the words where they lie instead of one value at a time.
pub const Value = union(enum) {
    bytes: []const u8,
    symbol: []const u8,
    capability: Capability,
    @"error": model.BreakReason,
    string: []const u8,
    integer: i64,
    integers: []const i64,
    boolean: bool,
    list: []const Value,
    void: void,
    float64: f64,
    set: []const Value,
    tagged: Tagged,
    keyword: []const u8,
    big_integer: model.BigInteger,
    @"struct": []const StructEntry,

    pub const Tagged = struct {
        tag: []const u8,
        value: []const Value,
    };

    pub const StructEntry = struct {
        key: []const u8,
        value: Value,
    };

    /// The nesting a value may have to be copied, measured, retained, or
    /// delivered to a local actor. A deeper value is `ValueTooDeep`. It is the
    /// one ceiling every path shares (`model.max_value_depth`).
    pub const max_depth = model.max_value_depth;

    /// Visit every capability in this value without allocation. Composite
    /// values are bounded to the same depth as owning-tier copy and retention.
    /// The walk returns exactly the visitor's errors and `ValueTooDeep`.
    pub fn forEachCapability(
        self: *const Value,
        ctx: anytype,
        comptime visit: anytype,
    ) VisitError(visit)!void {
        return self.forEachCapabilityAt(ctx, visit, 0);
    }

    pub fn VisitError(comptime visit: anytype) type {
        return error{ValueTooDeep} || foundation.error_sets.Of(visit);
    }

    fn forEachCapabilityAt(
        self: *const Value,
        ctx: anytype,
        comptime visit: anytype,
        depth: usize,
    ) VisitError(visit)!void {
        switch (self.*) {
            .capability => |ref| try visit(ctx, ref),
            .integers => {
                _ = try itemsDepth(depth);
            },
            .list, .set => |items| {
                const items_depth = try itemsDepth(depth);
                for (items) |*item| try item.forEachCapabilityAt(ctx, visit, items_depth);
            },
            .tagged => |tag| {
                const items_depth = try itemsDepth(depth);
                for (tag.value) |*item| try item.forEachCapabilityAt(ctx, visit, items_depth);
            },
            .@"struct" => |items| {
                const items_depth = try itemsDepth(depth);
                for (items) |*item| try item.value.forEachCapabilityAt(ctx, visit, items_depth);
            },
            .bytes,
            .symbol,
            .@"error",
            .string,
            .integer,
            .boolean,
            .void,
            .float64,
            .keyword,
            .big_integer,
            => {},
        }
    }
};

/// How an owning-tier `call` / `fetchSettled` / `listenSettled` settled. Both
/// arms are materialized into the caller-supplied arena, and every capability
/// in a fulfilled value is already lifted to its opaque Host identity. Reset
/// the arena to reclaim the reply. There is no `deinit`, because the lifted
/// tree's spine and leaves share the arena with the capture that produced it.
pub const Reply = union(enum) {
    fulfilled: Value,
    broken: foundation.break_cause.Broken,
};
