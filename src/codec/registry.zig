//! The set of codecs a build knows how to speak.
//!
//! pancake ships two — `syrup` and `capnp` — but the set is open. A Zig consumer
//! brings their own by declaring `pub const pancake_codecs` in their root source
//! file: a slice of [`Spec`] that this registry appends to the built-ins. The
//! whole thing is resolved at `comptime`, so `dispatch` stays a jump table with
//! no runtime indirection — a third codec costs nothing the two built-ins didn't
//! (ADR-0026, the open codec registry that superseded an earlier closed set).
//!
//! A codec is identified on the wire by its [`model.CodecId`] (a stable `u16`).
//! A `Spec` binds that id to the codec's frame shape and its implementation
//! module — any type exposing `decodeBody`, `decodePrefix`,
//! `encodeMessageForProfile`, and an `Error` set, exactly the shape `syrup` and
//! `capnp` already have.

const std = @import("std");
const builtin_zig = @import("builtin");

const foundation = @import("../foundation/mod.zig");
const model = @import("../model/mod.zig");
const syrup = @import("syrup/mod.zig");
const capnp = @import("capnp/mod.zig");

/// One registered codec: its wire id, the frame shape it produces, and the
/// module that implements it.
pub const Spec = struct {
    /// The id this codec answers to on the wire and in `session.codec`.
    id: model.CodecId,
    /// `.byte` for a self-delimiting byte stream, `.word` for 8-byte-aligned.
    frame_shape: foundation.FrameShape,
    /// The implementation: a type with `decodeBody` / `decodePrefix` /
    /// `encodeMessageForProfile` / `Error`.
    module: type,
};

/// The codecs pancake ships, best-first (matching negotiation's tie-break).
pub const builtin = [_]Spec{
    .{ .id = .capnp, .frame_shape = .word, .module = capnp },
    .{ .id = .syrup, .frame_shape = .byte, .module = syrup },
};

/// Codecs the root source file adds, or empty. A consumer writes
/// `pub const pancake_codecs = [_]pancake.codec.registry.Spec{ .{ ... } };`.
const extra: []const Spec = blk: {
    const root = @import("root");
    if (@hasDecl(root, "pancake_codecs")) break :blk root.pancake_codecs;
    break :blk &.{};
};

/// Every codec this build can speak: built-ins followed by consumer additions.
/// Resolved at `comptime`; `dispatch` iterates it with `inline for`.
pub const active: []const Spec = blk: {
    var all: [builtin.len + extra.len]Spec = undefined;
    for (builtin, 0..) |spec, i| all[i] = spec;
    for (extra, 0..) |spec, i| all[builtin.len + i] = spec;
    const frozen = all;
    break :blk &frozen;
};

/// The union of every registered codec's error set, plus `UnknownCodec` for an
/// id no registered codec claims.
pub const Error = unionErrors(active);

/// Build the error-set union over a codec spec list at `comptime`.
pub fn unionErrors(comptime specs: []const Spec) type {
    var E = error{UnknownCodec};
    for (specs) |spec| E = E || spec.module.Error;
    return E;
}
