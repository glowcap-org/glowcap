//! Handshake negotiation — pick a mutually-supported codec and the intersected
//! feature set for a direct session.
//!
//! `op:start-session` carries no feature operand on the wire (Invariant 10:
//! pancake does not extend OCapN's wire shapes), so negotiation is a *pure,
//! symmetric* function over the two peers' locally-configured [`Offer`]s, not a
//! wire exchange. Both ends compute the same answer from the same two offers:
//! the in-process handshake driver ([`factories`]) knows both offers directly;
//! a netlayer adapter learns the partner's offer out-of-band (e.g. the
//! `pancake/codec` acceptable-location hint) and runs the identical function.
//!
//! Codec choice is by lowest combined preference index (ties broken by
//! [`CodecId`] declaration order); features by [`model.FeatureSet.intersect`].
//! The result is what *both* sessions are constructed with, so neither side
//! exercises a capability the other did not advertise.

const std = @import("std");
const model = @import("../model/mod.zig");

/// Built-in codec identifier — re-exported from [`model.CodecId`], whose
/// declaration order (`capnp` then `syrup`) is the negotiation tie-break
/// (most-preferred first). Both codecs are live-session selectable; the codec
/// dispatch seam ([`codec.dispatch`]) routes each frame by this id.
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
