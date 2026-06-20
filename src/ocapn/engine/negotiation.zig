//! Settling on a profile, codec, and feature set that both peers can actually do.
//!
//! `op:start-session` doesn't carry a feature list on the wire, because pancake
//! doesn't add fields to OCapN's messages. So this isn't a back-and-forth. It's a
//! pure, symmetric function of the two peers' local `Offer`s, and both ends
//! compute the same answer from the same two offers. The in-process driver
//! (`pairing`) has both offers in hand already; a netlayer adapter learns the
//! partner's offer some other way, like the `pancake/codec` hint on the
//! acceptable location, and runs the very same function.
//!
//! Profiles and codecs are negotiated as independent axes. The profile picked is
//! whichever the two prefer most in combination, with `CaptpVersion` declaration
//! order breaking ties. The codec uses the same preference-score rule, with
//! `CodecId` declaration order breaking ties. The features are the intersection
//! of the two sets (`model.FeatureSet.intersect`). Both sessions are then built
//! from that one result, so neither side ends up using something the other never
//! offered.

const std = @import("std");
const model = @import("model");

/// Built-in codec identifier, re-exported from `model.CodecId`, whose
/// declaration order (`capnp` then `syrup`) is the negotiation tie-break
/// (most-preferred first). Both codecs are live-session selectable; the codec
/// dispatch boundary (`codec.dispatch`) routes each frame by this id.
pub const CodecId = model.CodecId;

const goblins_profiles = [_]model.WireProfile{model.WireProfile.v1_0};
const goblins_codecs = [_]CodecId{.syrup};
const pancake_profiles = [_]model.WireProfile{ model.WireProfile.pre_spec, model.WireProfile.v1_0 };
const pancake_codecs = [_]CodecId{ .capnp, .syrup };
const default_profiles = [_]model.WireProfile{model.WireProfile.v1_0};

pub const InteropTarget = enum {
    goblins,
    pancake,
};

/// What a peer offers at handshake: the profiles and codecs it can speak (index
/// 0 most preferred) and the semantic feature set it supports.
pub const Offer = struct {
    profiles: []const model.WireProfile = default_profiles[0..],
    codecs: []const CodecId,
    features: model.FeatureSet,
};

/// The negotiated outcome: the chosen profile, codec, and the mutually-supported
/// (intersected) feature set.
pub const Negotiated = struct {
    profile: model.WireProfile,
    chosen: CodecId,
    features: model.FeatureSet,
};

/// Produce the default offer for an interop target without collapsing target,
/// profile, or codec into one another. Goblins is the upstream v1.0 Syrup
/// proof path. Pancake-to-Pancake keeps the target, profile, and codec axes
/// independent.
pub fn offerForTarget(target: InteropTarget, features: model.FeatureSet) Offer {
    return switch (target) {
        .goblins => .{
            .profiles = goblins_profiles[0..],
            .codecs = goblins_codecs[0..],
            .features = features,
        },
        .pancake => .{
            .profiles = pancake_profiles[0..],
            .codecs = pancake_codecs[0..],
            .features = features,
        },
    };
}

/// Pick the most-preferred mutually-supported profile, codec, and the
/// intersected feature set, or `null` when the offers share no profile or codec.
///
/// Symmetric: `negotiate(a, b)` and `negotiate(b, a)` agree on both the chosen
/// profile, chosen codec, and feature set, so both sides of a handshake reach
/// the same answer without an extra round-trip. Selection minimizes
/// `local_idx + remote_idx` over each intersection; ties break on profile and
/// codec declaration order.
pub fn negotiate(local: Offer, remote: Offer) ?Negotiated {
    const profile = chooseProfile(local.profiles, remote.profiles) orelse return null;
    const codec = chooseCodec(local.codecs, remote.codecs) orelse return null;
    return .{
        .profile = profile,
        .chosen = codec,
        .features = local.features.intersect(remote.features),
    };
}

pub fn sharesProfile(local: Offer, remote: Offer) bool {
    return chooseProfile(local.profiles, remote.profiles) != null;
}

fn chooseProfile(local: []const model.WireProfile, remote: []const model.WireProfile) ?model.WireProfile {
    var best: ?struct { score: usize, profile: model.WireProfile } = null;
    for (local, 0..) |lp, local_idx| {
        for (remote, 0..) |rp, remote_idx| {
            if (lp.captp_version != rp.captp_version) continue;
            const score = local_idx + remote_idx;
            if (best) |current| {
                if (score < current.score or
                    (score == current.score and @intFromEnum(lp.captp_version) < @intFromEnum(current.profile.captp_version)))
                {
                    best = .{ .score = score, .profile = lp };
                }
            } else {
                best = .{ .score = score, .profile = lp };
            }
        }
    }
    return if (best) |winner| winner.profile else null;
}

fn chooseCodec(local: []const CodecId, remote: []const CodecId) ?CodecId {
    var best: ?struct { score: usize, codec: CodecId } = null;
    for (local, 0..) |lc, local_idx| {
        for (remote, 0..) |rc, remote_idx| {
            if (lc != rc) continue;
            const score = local_idx + remote_idx;
            if (best) |current| {
                if (score < current.score or
                    (score == current.score and @intFromEnum(lc) < @intFromEnum(current.codec)))
                {
                    best = .{ .score = score, .codec = lc };
                }
            } else {
                best = .{ .score = score, .codec = lc };
            }
        }
    }
    return if (best) |winner| winner.codec else null;
}
