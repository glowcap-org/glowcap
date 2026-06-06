//! Settling on a codec and a feature set that both peers can actually do.
//!
//! `op:start-session` doesn't carry a feature list on the wire, because pancake
//! doesn't add fields to OCapN's messages. So this isn't a back-and-forth. It's a
//! pure, symmetric function of the two peers' local `Offer`s, and both ends
//! compute the same answer from the same two offers. The in-process driver
//! (`pairing`) has both offers in hand already; a netlayer adapter learns the
//! partner's offer some other way, like the `pancake/codec` hint on the
//! acceptable location, and runs the very same function.
//!
//! The codec picked is whichever the two prefer most in combination, with
//! `CodecId` declaration order breaking ties. The features are the intersection of
//! the two sets (`model.FeatureSet.intersect`). Both sessions are then built from
//! that one result, so neither side ends up using something the other never
//! offered.

const std = @import("std");
const model = @import("../model/mod.zig");

/// Built-in codec identifier — re-exported from [`model.CodecId`], whose
/// declaration order (`capnp` then `syrup`) is the negotiation tie-break
/// (most-preferred first). Both codecs are live-session selectable; the codec
/// dispatch boundary ([`codec.dispatch`]) routes each frame by this id.
pub const CodecId = model.CodecId;

/// What a peer offers at handshake: the codecs it can speak (index 0 most
/// preferred) and the semantic feature set it supports.
pub const Offer = struct {
    codecs: []const CodecId,
    features: model.FeatureSet,
};

/// The negotiated outcome: the chosen codec and the mutually-supported
/// (intersected) feature set.
pub const Negotiated = struct {
    chosen: CodecId,
    features: model.FeatureSet,
};

/// Pick the most-preferred mutually-supported codec and the intersected feature
/// set, or `null` when the offers share no codec.
///
/// Symmetric: `negotiate(a, b)` and `negotiate(b, a)` agree on both the chosen
/// codec and the feature set, so both sides of a handshake reach the same answer
/// without an extra round-trip. Selection minimizes `local_idx + remote_idx`
/// over the codec intersection; ties break on [`CodecId`] declaration order.
pub fn negotiate(local: Offer, remote: Offer) ?Negotiated {
    var best: ?struct { score: usize, codec: CodecId } = null;
    for (local.codecs, 0..) |lc, local_idx| {
        for (remote.codecs, 0..) |rc, remote_idx| {
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
    const winner = best orelse return null;
    return .{
        .chosen = winner.codec,
        .features = local.features.intersect(remote.features),
    };
}
