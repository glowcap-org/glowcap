//! The words two peers settle on at handshake.
//!
//! None of these is a message. They are the vocabulary a handshake negotiates
//! over, which codec frames the bytes, which CapTP version is spoken, and which
//! optional features both sides advertised. The negotiation itself is a pure
//! function of two peers' offers in `engine.negotiation`. These are the types it
//! reads and returns. They carry no codec, no allocation, and no authority.

const std = @import("std");

/// Which wire codec a direct session speaks. The two built-ins are `capnp` (the
/// native word-aligned fast path) and `syrup` (the byte-record one everyone can
/// fall back to). Negotiation lists them best-first and breaks ties on that
/// order.
///
/// The enum is non-exhaustive: a consumer can mint their own codec id
/// (`@enumFromInt` past the built-ins) and register it with `codec.registry`, so
/// "bring your own codec" needs no fork of this type. The tag is a stable `u16`
/// wire identity, built-in values never move.
///
/// This lives in `model` rather than `codec`. The session
/// has to record which codec it picked, but it must not depend on a codec to do
/// it. The choice stays the session's to make. So the id sits down here,
/// `codec.registry`/`codec.dispatch` resolve it to an implementation, and
/// `engine.negotiation` is what settles it during the handshake.
pub const CodecId = enum(u16) {
    capnp = 0,
    syrup = 1,
    _,
};

/// What one peer prefers for a session: one CapTP version, one codec, and the
/// features it can do. Plain vocabulary, like everything else in this file,
/// the session records each side's, and `engine.negotiation` settles them.
///
/// Only the preference travels, never the accepted set, because a glowcap peer
/// speaks the v1.0 Syrup baseline by construction: it must, to reach a Goblins
/// vat at all. So what a peer accepts is derivable from what it prefers, and a
/// peer that names nothing has said "the baseline".
pub const Preference = struct {
    captp_version: CaptpVersion = .v1_0,
    codec: CodecId = .syrup,
    features: FeatureSet = FeatureSet.defaultOffer(),

    /// What glowcap offers when a caller does not override the session profile.
    pub const default_offer: Preference = .{};

    /// Glowcap's coherent peer-to-peer preference. Applications select this
    /// as one profile rather than pairing its codec and CapTP version by hand.
    pub const glowcap: Preference = .{
        .captp_version = .next,
        .codec = .capnp,
        .features = FeatureSet.full(),
    };

    /// The profile every conforming peer speaks, and so what a peer has
    /// told us by telling us nothing.
    pub const baseline: Preference = .{ .features = FeatureSet.baseline() };
};

/// CapTP version spoken on a session. Two jobs, one axis:
/// - `v1_0` / `"1.0"`: glowcap's current Goblins 0.18.0 and pinned-suite
///   interop floor. The wire token does not claim the draft is released.
/// - `next` / `"glowcap-next"`: glowcap-forward private track for glowcap-to-glowcap.
pub const CaptpVersion = enum {
    v1_0,
    next,

    pub fn wireString(self: CaptpVersion) []const u8 {
        return switch (self) {
            .v1_0 => "1.0",
            .next => "glowcap-next",
        };
    }

    /// A diagnostic label for logs and error text, not a wire token: the
    /// handshake puts `wireString()` on the wire, never this.
    pub fn name(self: CaptpVersion) []const u8 {
        return switch (self) {
            .v1_0 => "ocapn-v1.0",
            .next => "glowcap-next",
        };
    }

    /// The inverse of `wireString`, derived from it: every version is matched by
    /// the exact string `wireString` emits, so the two directions cannot drift
    /// and a new version is covered the moment it has a `wireString` arm.
    /// Spellings `wireString` never emits (including the former lenient
    /// `"ocapn-1.0"` alias) are refused, pinned by `test/model/model_test.zig`
    /// and the Syrup decode negative in `test/codec/syrup/decode_test.zig`.
    pub fn fromWireString(wire: []const u8) ?CaptpVersion {
        inline for (@typeInfo(CaptpVersion).@"enum".field_values) |field_value| {
            const version: CaptpVersion = @fromBackingInt(@intCast(field_value));
            if (std.mem.eql(u8, version.wireString(), wire)) return version;
        }
        return null;
    }
};

/// Optional CapTP capabilities a session may negotiate. Every field here is
/// gated in `session.validate` when the matching ops run, do not add a bit
/// that nothing enforces.
pub const FeatureSet = packed struct {
    pipelining: bool = false,
    handoff: bool = false,
    wire_delta: bool = false,
    sturdyref: bool = false,
    /// The peer explicitly advertises that it accepts outbound `op:untag`.
    /// Inbound `op:untag` remains part of OCapN 1.0 and is accepted regardless
    /// of this bit. The distinction lets a glowcap peer avoid sending the
    /// operation to Goblins, whose absent feature hint means the baseline set.
    untag: bool = false,
    /// Private identity-route vocabulary. A peer must advertise this before an
    /// `id/via` locator can appear in CapTP payloads.
    multi_location: bool = false,

    pub const wire_string_max_len = blk: {
        var len: usize = 0;
        var fields: usize = 0;
        for (@typeInfo(FeatureSet).@"struct".field_names) |field_name| {
            if (fields != 0) len += 1; // comma
            len += field_name.len;
            fields += 1;
        }
        break :blk len;
    };

    /// The minimal set: Deliver, Resolve, and Abort only.
    pub fn minimum() FeatureSet {
        return .{};
    }

    /// Capabilities an OCapN 1.0 peer can be assumed to support when it sends
    /// no glowcap feature hint. This is not `full`: the pinned
    /// draft includes `op:untag`, but Goblins does not implement it.
    pub fn baseline() FeatureSet {
        return .{
            .pipelining = true,
            .handoff = true,
            .wire_delta = true,
            .sturdyref = true,
        };
    }

    /// Full glowcap feature set: every feature field, driven off the
    /// field list itself so a new feature joins automatically.
    pub fn full() FeatureSet {
        var out: FeatureSet = .{};
        inline for (@typeInfo(FeatureSet).@"struct".field_names) |field_name| {
            @field(out, field_name) = true;
        }
        return out;
    }

    /// Glowcap's implicit offer keeps private route vocabulary silent. Callers
    /// opt in per session so enabling it cannot change baseline bytes.
    pub fn defaultOffer() FeatureSet {
        var out = FeatureSet.full();
        out.multi_location = false;
        return out;
    }

    /// Features usable under the active CapTP version. `multi_location` is
    /// glowcap-next identity-route vocabulary: a v1.0 session may hear an offer
    /// bit, but the settled session must not report it as usable.
    pub fn forCaptpVersion(self: FeatureSet, captp_version: CaptpVersion) FeatureSet {
        var out = self;
        if (captp_version != .next) out.multi_location = false;
        if (captp_version == .next) out.untag = false;
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
    /// `engine.negotiation.negotiate`. The codec half lives there.
    pub fn intersect(self: FeatureSet, other: FeatureSet) FeatureSet {
        var out: FeatureSet = .{};
        inline for (@typeInfo(FeatureSet).@"struct".field_names) |field_name| {
            @field(out, field_name) = @field(self, field_name) and @field(other, field_name);
        }
        return out;
    }

    /// Stable hint representation: enabled field names, comma-separated in
    /// declaration order. Callers omit the hint when the offered set is the
    /// compatibility baseline. If the hint is present, the minimum set is the
    /// empty string.
    pub fn toWireString(self: FeatureSet, buf: []u8) error{NoSpace}![]const u8 {
        var len: usize = 0;
        var first = true;
        inline for (@typeInfo(FeatureSet).@"struct".field_names) |field_name| {
            if (@field(self, field_name)) {
                if (!first) {
                    if (len == buf.len) return error.NoSpace;
                    buf[len] = ',';
                    len += 1;
                }
                if (buf.len - len < field_name.len) return error.NoSpace;
                @memcpy(buf[len..][0..field_name.len], field_name);
                len += field_name.len;
                first = false;
            }
        }
        return buf[0..len];
    }

    /// Parse `toWireString`. Unknown, empty-token, or repeated names are
    /// malformed: the feature hint is signed handshake authority, not an
    /// advisory routing hint.
    pub fn fromWireString(wire: []const u8) ?FeatureSet {
        var out: FeatureSet = .{};
        if (wire.len == 0) return out;
        var it = std.mem.splitScalar(u8, wire, ',');
        while (it.next()) |name| {
            if (name.len == 0) return null;
            var matched = false;
            inline for (@typeInfo(FeatureSet).@"struct".field_names) |field_name| {
                if (std.mem.eql(u8, name, field_name)) {
                    if (@field(out, field_name)) return null;
                    @field(out, field_name) = true;
                    matched = true;
                }
            }
            if (!matched) return null;
        }
        return out;
    }
};
