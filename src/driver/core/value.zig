//! The owning tier's passable-value vocabulary (ADR-0096): `Value` is what an
//! application passes to and receives from the opaque-capability verbs on the
//! owning host face. It mirrors the codec-neutral `model.Argument` data arms,
//! with one difference that is the point: a capability is the opaque
//! Host-scoped `Capability`, never a wire position or an actor id. The
//! translation walks live on `driver_core.Host` (`lowerValue` / `liftValue`),
//! where the session context both directions need is in scope — the same
//! boundary the C ABI's argument projection crosses.

const std = @import("std");

const model = @import("model");
const capability = @import("capability.zig");

/// The opaque Host-scoped capability identity (see `capability.Ref`).
pub const Capability = capability.Ref;

/// A passable value on the owning host tier. Data arms mirror
/// `model.Argument`; a capability mention is opaque. There is no handoff arm
/// because the host redeems a give before the application sees it. An Error is
/// a first-class value and remains distinct from `Reply.broken`: returning one
/// fulfills with an Error, while breaking rejects the reply.
pub const Value = union(enum) {
    bytes: []const u8,
    symbol: []const u8,
    capability: Capability,
    @"error": model.BreakReason,
    string: []const u8,
    integer: i64,
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
};

/// How an owning-tier `call` / `fetchSettled` / `listenSettled` settled. Both
/// arms are materialized into the caller-supplied arena, and every capability
/// in a fulfilled value is already lifted to its opaque Host identity. Reset
/// the arena to reclaim the reply; there is no `deinit`, because the lifted
/// tree's spine and leaves share the arena with the capture that produced it.
pub const Reply = union(enum) {
    fulfilled: Value,
    broken: []const u8,
};
