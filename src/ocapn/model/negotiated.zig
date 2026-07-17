//! The words two peers settle on at handshake.
//!
//! None of these is a message; they are the vocabulary a handshake negotiates
//! over, which codec frames the bytes, which CapTP version is spoken, and which
//! optional features both sides advertised. The negotiation itself is a pure
//! function of two peers' offers in `engine.negotiation`; these are the types it
//! reads and returns. They carry no codec, no allocation, and no authority.

const std = @import("std");

/// Which wire codec a direct session speaks. The two built-ins are `capnp` (the
/// native word-aligned fast path) and `syrup` (the byte-record one everyone can
/// fall back to); negotiation lists them best-first and breaks ties on that
/// order.
///
/// The enum is non-exhaustive on purpose: a consumer can mint their own codec id
/// (`@enumFromInt` past the built-ins) and register it with `codec.registry`, so
/// "bring your own codec" needs no fork of this type. The tag is a stable `u16`
/// wire identity, built-in values never move.
///
/// This lives in `model` rather than `codec`, and that's deliberate. The session
/// has to record which codec it picked, but it must not depend on a codec to do
/// it; the choice stays the session's to make. So the id sits down here,
/// `codec.registry`/`codec.dispatch` resolve it to an implementation, and
/// `engine.negotiation` is what settles it during the handshake.
pub const CodecId = enum(u16) {
    capnp = 0,
    syrup = 1,
    _,
};

/// CapTP version spoken on a session. Two jobs, one axis:
/// - `v1_0` / `"1.0"` — frozen released interop (Goblins / cross-platform).
/// - `next` / `"pancake-next"` — pancake-forward private track for pancake-to-pancake.
pub const CaptpVersion = enum {
    v1_0,
    next,

    pub fn wireString(self: CaptpVersion) []const u8 {
        return switch (self) {
            .v1_0 => "1.0",
            .next => "pancake-next",
        };
    }

    /// A diagnostic label for logs and error text, not a wire token: the
    /// handshake puts `wireString()` on the wire, never this.
    pub fn name(self: CaptpVersion) []const u8 {
        return switch (self) {
            .v1_0 => "ocapn-v1.0",
            .next => "pancake-next",
        };
    }

    /// The inverse of `wireString`, derived from it: every version is matched by
    /// the exact string `wireString` emits, so the two directions cannot drift
    /// and a new version is covered the moment it has a `wireString` arm.
    /// Spellings `wireString` never emits (including the former lenient
    /// `"ocapn-1.0"` alias) are refused — pinned by `test/model/model_test.zig`
    /// and the Syrup decode negative in `test/codec/syrup_test.zig`.
    pub fn fromWireString(wire: []const u8) ?CaptpVersion {
        inline for (@typeInfo(CaptpVersion).@"enum".fields) |field| {
            const version: CaptpVersion = @enumFromInt(field.value);
            if (std.mem.eql(u8, version.wireString(), wire)) return version;
        }
        return null;
    }
};

/// Optional CapTP capabilities a session may negotiate. Every field here is
/// gated in `session.validate` when the matching ops run — do not add a bit
/// that nothing enforces.
pub const FeatureSet = struct {
    pipelining: bool = false,
    handoff: bool = false,
    wire_delta: bool = false,
    sturdyref: bool = false,

    /// The minimal set: Deliver, Resolve, and Abort only.
    pub fn minimum() FeatureSet {
        return .{};
    }

    /// Full pancake-native feature set: every feature field, driven off the
    /// field list itself so a new feature joins automatically.
    pub fn full() FeatureSet {
        var out: FeatureSet = .{};
        inline for (@typeInfo(FeatureSet).@"struct".fields) |field| {
            @field(out, field.name) = true;
        }
        return out;
    }

    /// Pipelining, handoff, and wire-delta, without sturdyrefs (ADR-0008,
    /// ADR-0009).
    pub fn pipeliningAndHandoff() FeatureSet {
        return .{ .pipelining = true, .handoff = true, .wire_delta = true };
    }

    /// Per-feature intersection, the handshake-negotiated set is the AND of the
    /// two peers' advertised sets, so neither side exercises a capability the
    /// other did not advertise. Pure and symmetric:
    /// `a.intersect(b) == b.intersect(a)`. The feature half of
    /// `engine.negotiation.negotiate`; the codec half lives there.
    pub fn intersect(self: FeatureSet, other: FeatureSet) FeatureSet {
        var out: FeatureSet = .{};
        inline for (@typeInfo(FeatureSet).@"struct".fields) |field| {
            @field(out, field.name) = @field(self, field.name) and @field(other, field.name);
        }
        return out;
    }
};
