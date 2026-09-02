//! The set of codecs a build knows how to speak.
//!
//! glowcap ships two — `syrup` and `capnp` — but the set is open. A Zig consumer
//! brings their own by declaring `pub const glowcap_codecs` in their root source
//! file: a slice of `Spec` that this registry appends to the built-ins. The
//! whole thing is resolved at `comptime`, so `dispatch` stays a jump table with
//! no runtime indirection — a third codec costs nothing the two built-ins
//! didn't (ADR-0026).
//!
//! `framePrefix` is the profile-less structural parser: it returns only a frame
//! boundary. `decodePrefixForProfile` returns the projected body once a session
//! knows which CapTP semantics apply.
//!
//! A codec is identified on the wire by its `model.CodecId` (a stable `u16`).
//! A `Spec` binds that id to the codec's frame shape and its implementation
//! module — any type exposing `decodeBody`, `decodePrefix`, `framePrefix`,
//! `encodeMessageForProfile`, and an `Error` set, exactly the shape `syrup` and
//! `capnp` already have.
//!
//! Each module also declares `pub const self_delimiting: bool`. A codec whose
//! frame length is computable from a header declares `false` and omits
//! `scanStream(bytes, *StreamScan, max_frame_bytes) Verdict`, as `capnp` does.
//! A codec with a self-delimiting grammar declares `true` and provides it:
//! without one, a frame that arrives over many reads is walked from its first
//! byte on every read, which is work quadratic in the frame's size over a
//! chunk size the sender chooses. The `comptime` block below `active` holds
//! every registered module to this shape, so a misspelled member is a compile
//! error naming the member rather than a silent fallback.

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
    /// The implementation: a type with `decodeBody` / `decodePrefix` / `framePrefix` /
    /// `encodeMessageForProfile` / `Error`, and optionally `scanStream` (see
    /// the module header — omit it only if frame length is computable up front).
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
/// Resolved at `comptime`; `dispatch` iterates it with `inline for`.
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
    // instead of silently taking a fallback. The dangerous case is
    // `scanStream`: `dispatch` infers "no incremental scan" from the *absence*
    // of the name, so a typo would not be an error, it would be the quadratic
    // from-start re-walk the member exists to avoid. `self_delimiting` turns
    // that absence into a statement the build can check.
    for (active, 0..) |spec, i| {
        for (active[0..i]) |prior| {
            if (prior.id == spec.id)
                @compileError("codec id " ++ std.fmt.comptimePrint("{d}", .{@backingInt(spec.id)}) ++
                    " is registered more than once (" ++ @typeName(prior.module) ++ " and " ++ @typeName(spec.module) ++ ")");
        }
        const M = spec.module;
        const name = @typeName(M);
        for ([_][]const u8{ "decodeBody", "decodeBodyForProfile", "decodePrefix", "decodePrefixForProfile", "framePrefix", "encodeMessageForProfile", "Error", "self_delimiting" }) |member| {
            if (!@hasDecl(M, member))
                @compileError("codec module " ++ name ++ " is missing `" ++ member ++ "` (see registry.Spec.module)");
        }
        if (M.self_delimiting != @hasDecl(M, "scanStream"))
            @compileError("codec module " ++ name ++ if (M.self_delimiting)
                " declares self_delimiting = true but has no scanStream"
            else
                " has a scanStream but declares self_delimiting = false; a self-describing frame length makes the incremental scan dead weight");
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

/// Build the error-set union over a codec spec list at `comptime`.
pub fn unionErrors(comptime specs: []const Spec) type {
    var E = error{UnknownCodec};
    for (specs) |spec| E = E || spec.module.Error;
    return E;
}
