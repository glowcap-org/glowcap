//! Settling on a CapTP version, codec, and feature set that both peers can
//! do.
//!
//! It is not a wire back-and-forth. `op:start-session` carries the baseline
//! message shape. glowcap does not add fields to OCapN's messages. A peer's
//! preference rides in locator hints, so this is a pure symmetric function of
//! the two peers' offers and both ends compute the same answer from the same
//! two inputs.
//!
//! What each end knows of the other is one `model.Preference`, which the hello
//! states in its locator hints (`model.transport.hint_captp_version`,
//! `hint_codec`, and `hint_features`) and
//! `session.Session.partner_preference` records. `settle` below is the whole
//! path from two of those to a session's active profile.
//! `engine.Peer.settleNegotiatedProfile` calls it when the partner's hello
//! lands, and `engine.pairing` reaches the same answer in one process.
//!
//! The hello itself is always the baseline, in both its version field and its
//! grammar, and that is what makes any of this reachable: a peer that greeted
//! with its preference would be aborted by every partner that did not already
//! share it, which is the opposite of negotiating.
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
const glowcap_versions = [_]model.CaptpVersion{ model.Preference.glowcap.captp_version, .v1_0 };
const glowcap_codecs = [_]model.CodecId{ model.Preference.glowcap.codec, .syrup };

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

    /// Glowcap-forward job: prefer `next` and Cap'n Proto, fall back to
    /// `"1.0"` / Syrup when the partner only offers those.
    pub fn glowcap(features: model.FeatureSet) Offer {
        return .{
            .captp_versions = glowcap_versions[0..],
            .codecs = glowcap_codecs[0..],
            .features = features,
        };
    }
};

/// Storage an offer's slices point into: a preference plus the baseline is
/// the whole offer, so two of each is the bound.
pub const Storage = struct {
    captp_versions: [2]model.CaptpVersion = undefined,
    codecs: [2]model.CodecId = undefined,
};

/// Expand a preference into the offer `negotiate` reads: what the peer asked
/// for, then the baseline it speaks by construction.
pub fn offerFor(preference: model.Preference, storage: *Storage) Offer {
    const baseline = model.Preference.baseline;
    storage.captp_versions[0] = preference.captp_version;
    storage.codecs[0] = preference.codec;
    const versions: usize = if (preference.captp_version == baseline.captp_version) 1 else blk: {
        storage.captp_versions[1] = baseline.captp_version;
        break :blk 2;
    };
    const codecs: usize = if (preference.codec == baseline.codec) 1 else blk: {
        storage.codecs[1] = baseline.codec;
        break :blk 2;
    };
    return .{
        .captp_versions = storage.captp_versions[0..versions],
        .codecs = storage.codecs[0..codecs],
        .features = preference.features,
    };
}

/// Settle two preferences into the profile the session runs on. Symmetric, so
/// both sides reach it without a further round trip. An axis the two cannot
/// agree on falls back to the baseline rather than failing the session: every
/// glowcap peer speaks it, so there is always an answer.
pub fn settle(local: model.Preference, remote: model.Preference) Negotiated {
    var local_storage: Storage = .{};
    var remote_storage: Storage = .{};
    return negotiate(
        offerFor(local, &local_storage),
        offerFor(remote, &remote_storage),
    ) orelse .{
        .captp_version = model.Preference.baseline.captp_version,
        .codec = model.Preference.baseline.codec,
        .features = local.features.intersect(remote.features).forCaptpVersion(model.Preference.baseline.captp_version),
    };
}

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
/// `local_idx + remote_idx` over each intersection. Ties break on version and
/// codec declaration order.
pub fn negotiate(local: Offer, remote: Offer) ?Negotiated {
    const captp_version = choosePreferred(model.CaptpVersion, local.captp_versions, remote.captp_versions) orelse return null;
    const codec = choosePreferred(model.CodecId, local.codecs, remote.codecs) orelse return null;
    return .{
        .captp_version = captp_version,
        .codec = codec,
        .features = local.features.intersect(remote.features).forCaptpVersion(captp_version),
    };
}

/// The option both sides list that ranks best: the lowest sum of the two
/// list positions, and the lower wire value when two tie, so both peers reach
/// the same answer from either side's view of the lists.
fn choosePreferred(comptime Option: type, local: []const Option, remote: []const Option) ?Option {
    var best: ?struct { score: usize, option: Option } = null;
    for (local, 0..) |lo, local_idx| {
        for (remote, 0..) |ro, remote_idx| {
            if (lo != ro) continue;
            const score = local_idx + remote_idx;
            const better = if (best) |current|
                score < current.score or (score == current.score and @backingInt(lo) < @backingInt(current.option))
            else
                true;
            if (better) best = .{ .score = score, .option = lo };
        }
    }
    return if (best) |winner| winner.option else null;
}
