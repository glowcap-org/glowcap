//! Settling on a CapTP version, codec, and feature set that both peers can
//! actually do.
//!
//! `op:start-session` doesn't carry a feature list or codec on the wire, because
//! pancake doesn't add fields to OCapN's messages. So this isn't a wire
//! back-and-forth. It's a pure, symmetric function of the two peers' local
//! `Offer`s, and both ends compute the same answer from the same two offers.
//! The in-process driver (`pairing`) has both offers in hand already and runs
//! `negotiate`; a netlayer adapter that learns the partner's offer (for example
//! from a locator hint) runs the same function.
//!
//! CapTP versions and codecs are negotiated as independent axes. The version
//! picked is whichever the two prefer most in combination, with `CaptpVersion`
//! declaration order breaking ties. The codec uses the same preference-score
//! rule, with `CodecId` declaration order breaking ties. The features are the
//! intersection of the two sets (`model.FeatureSet.intersect`). Both sessions
//! are then built from that one result, so neither side ends up using something
//! the other never offered.

const std = @import("std");
const model = @import("model");

const v1_0_syrup_versions = [_]model.CaptpVersion{.v1_0};
const v1_0_syrup_codecs = [_]model.CodecId{.syrup};
const native_versions = [_]model.CaptpVersion{ .next, .v1_0 };
const native_codecs = [_]model.CodecId{ .capnp, .syrup };

/// What a peer offers at handshake: the CapTP versions and codecs it can speak
/// (index 0 most preferred) and the semantic feature set it supports.
pub const Offer = struct {
    captp_versions: []const model.CaptpVersion,
    codecs: []const model.CodecId,
    features: model.FeatureSet,

    /// Frozen v1.0 interop job: OCapN `"1.0"` over Syrup, the wire the live
    /// checks prove against a real Goblins peer and the upstream OCapN suite.
    pub fn v1_0Syrup(features: model.FeatureSet) Offer {
        return .{
            .captp_versions = v1_0_syrup_versions[0..],
            .codecs = v1_0_syrup_codecs[0..],
            .features = features,
        };
    }

    /// Pancake-forward job: prefer `next` and Cap'n Proto, fall back to
    /// `"1.0"` / Syrup when the partner only offers those.
    pub fn native(features: model.FeatureSet) Offer {
        return .{
            .captp_versions = native_versions[0..],
            .codecs = native_codecs[0..],
            .features = features,
        };
    }
};

/// The negotiated outcome: CapTP version, codec, and the mutually-supported
/// (intersected) feature set.
pub const Negotiated = struct {
    captp_version: model.CaptpVersion,
    codec: model.CodecId,
    features: model.FeatureSet,
};

/// Pick the most-preferred mutually-supported CapTP version, codec, and the
/// intersected feature set, or `null` when the offers share no version or codec.
///
/// Symmetric: `negotiate(a, b)` and `negotiate(b, a)` agree on both the chosen
/// version, chosen codec, and feature set, so both sides of a handshake reach
/// the same answer without an extra round-trip. Selection minimizes
/// `local_idx + remote_idx` over each intersection; ties break on version and
/// codec declaration order.
pub fn negotiate(local: Offer, remote: Offer) ?Negotiated {
    const captp_version = chooseCaptpVersion(local.captp_versions, remote.captp_versions) orelse return null;
    const codec = chooseCodec(local.codecs, remote.codecs) orelse return null;
    return .{
        .captp_version = captp_version,
        .codec = codec,
        .features = local.features.intersect(remote.features),
    };
}

fn chooseCaptpVersion(local: []const model.CaptpVersion, remote: []const model.CaptpVersion) ?model.CaptpVersion {
    var best: ?struct { score: usize, captp_version: model.CaptpVersion } = null;
    for (local, 0..) |lp, local_idx| {
        for (remote, 0..) |rp, remote_idx| {
            if (lp != rp) continue;
            const score = local_idx + remote_idx;
            if (best) |current| {
                if (score < current.score or
                    (score == current.score and @intFromEnum(lp) < @intFromEnum(current.captp_version)))
                {
                    best = .{ .score = score, .captp_version = lp };
                }
            } else {
                best = .{ .score = score, .captp_version = lp };
            }
        }
    }
    return if (best) |winner| winner.captp_version else null;
}

fn chooseCodec(local: []const model.CodecId, remote: []const model.CodecId) ?model.CodecId {
    var best: ?struct { score: usize, codec: model.CodecId } = null;
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
