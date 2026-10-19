//! The set of codecs a build knows how to speak.
//!
//! glowcap ships two, `syrup` and `capnp`, but the set is open. A Zig consumer
//! brings their own by declaring `pub const glowcap_codecs` in their root source
//! file: a slice of `Spec` that this registry appends to the built-ins. The
//! whole thing is resolved at `comptime`, so `dispatch` stays a jump table with
//! no runtime indirection, a third codec costs nothing the two built-ins
//! didn't (ADR-0010).
//!
//! A codec decodes whole frames. The byte-stream envelope (ADR-0012) or the
//! transport's own message boundary delimits a frame before any codec sees
//! it, so no codec frames a stream.
//!
//! A codec is identified on the wire by its `model.CodecId` (a stable `u16`).
//! A `Spec` binds that id to the codec's frame shape and its implementation
//! module, any type exposing `decodeBody`, `decodeBodyForProfile`,
//! `decodeBodyInto`, `encodeMessageForProfile`, `encodeBodyForProfile`, a
//! `meter` (the type that sizes an outbound tree's values during the
//! session's admission walk, or null when the codec sizes its own frames),
//! and an `Error` set, exactly the shape `syrup` and `capnp` already have.
//! The `comptime` block below
//! `active` holds every registered module to this shape, so a misspelled
//! member is a compile error naming the member rather than a silent fallback.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const syrup = @import("syrup");
const capnp = @import("capnp");

/// One registered codec: its wire id, the frame shape it produces, and the
/// module that implements it.
pub const Spec = struct {
    /// The id this codec answers to on the wire and in `session.codec`.
    id: model.CodecId,
    /// `.byte` for a self-delimiting byte stream, `.word` for 8-byte-aligned.
    frame_shape: foundation.FrameShape,
    /// The implementation: a type with `decodeBodyInto` /
    /// `encodeMessageForProfile` / `encodeBodyForProfile` / `meter` / `Error` /
    /// `EncodeError` (see the module header).
    module: type,
};

/// The codecs glowcap ships, best-first (matching negotiation's tie-break).
pub const builtin = [_]Spec{
    .{ .id = .capnp, .frame_shape = .word, .module = capnp },
    .{ .id = .syrup, .frame_shape = .byte, .module = syrup },
};

/// Codecs the root source file adds, or empty. A consumer writes
/// `pub const glowcap_codecs = [_]glowcap.ocapn.codec.registry.Spec{ .{ ... } };`.
const extra: []const Spec = blk: {
    const root = @import("root");
    if (@hasDecl(root, "glowcap_codecs")) break :blk root.glowcap_codecs;
    break :blk &.{};
};

/// Every codec this build can speak: built-ins followed by consumer additions.
/// Resolved at `comptime`. `dispatch` iterates it with `inline for`.
pub const active: []const Spec = blk: {
    var all: [builtin.len + extra.len]Spec = undefined;
    for (builtin, 0..) |spec, i| all[i] = spec;
    for (extra, 0..) |spec, i| all[builtin.len + i] = spec;
    const frozen = all;
    break :blk &frozen;
};

comptime {
    // Hold every registered module to the interface the doc comments describe,
    // so a consumer codec with a misspelled member fails to compile by name
    // instead of silently taking a fallback.
    for (active, 0..) |spec, i| {
        for (active[0..i]) |prior| {
            if (prior.id == spec.id)
                @compileError("codec id " ++ std.fmt.comptimePrint("{d}", .{@backingInt(spec.id)}) ++
                    " is registered more than once (" ++ @typeName(prior.module) ++ " and " ++ @typeName(spec.module) ++ ")");
        }
        const M = spec.module;
        const name = @typeName(M);
        for ([_][]const u8{ "decodeBodyInto", "encodeMessageForProfile", "encodeBodyForProfile", "meter", "Error", "EncodeError" }) |member| {
            if (!@hasDecl(M, member))
                @compileError("codec module " ++ name ++ " is missing `" ++ member ++ "` (see registry.Spec.module)");
        }
    }
}

/// Whether this build has an implementation for `id`. Codec ids are an open
/// wire set, so enum construction alone does not establish membership.
pub fn contains(id: model.CodecId) bool {
    inline for (active) |spec| {
        if (spec.id == id) return true;
    }
    return false;
}

/// The union of every registered codec's error set, plus `UnknownCodec` for an
/// id no registered codec claims.
pub const Error = unionErrors(active);

/// The union of every registered codec's `EncodeError`, plus `UnknownCodec`:
/// what encoding a message for a wire profile can refuse.
pub const EncodeError = blk: {
    var E = error{UnknownCodec};
    for (active) |spec| E = E || spec.module.EncodeError;
    break :blk E;
};

/// Build the error-set union over a codec spec list at `comptime`.
pub fn unionErrors(comptime specs: []const Spec) type {
    var E = error{UnknownCodec};
    for (specs) |spec| E = E || spec.module.Error;
    return E;
}
