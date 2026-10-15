const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const negotiation = glowcap.ocapn.engine.negotiation;

test "FeatureSet.intersect is the field-wise AND and is symmetric" {
    const a = model.FeatureSet.full();
    const b = model.FeatureSet.pipeliningAndHandoff();

    const ab = a.intersect(b);
    const ba = b.intersect(a);

    // Symmetric.
    try std.testing.expectEqual(ab, ba);
    // The intersection drops whatever either side withholds.
    try std.testing.expect(ab.pipelining);
    try std.testing.expect(ab.handoff);
    try std.testing.expect(ab.wire_delta);
    try std.testing.expect(!ab.sturdyref);
    try std.testing.expect(!ab.untag);
    try std.testing.expect(!ab.multi_location);
}

test "intersect with minimum yields minimum" {
    const intersected = model.FeatureSet.full().intersect(model.FeatureSet.minimum());
    try std.testing.expectEqual(model.FeatureSet.minimum(), intersected);
}

test "FeatureSet wire hint round-trips and rejects ambiguous spellings" {
    var buf: [64]u8 = undefined;

    try std.testing.expectEqualStrings("", try model.FeatureSet.minimum().toWireString(&buf));
    const full = try model.FeatureSet.full().toWireString(&buf);
    try std.testing.expectEqualStrings("pipelining,handoff,wire_delta,sturdyref,untag,multi_location", full);
    try std.testing.expectEqual(model.FeatureSet.full(), model.FeatureSet.fromWireString(full).?);
    try std.testing.expectEqual(model.FeatureSet.minimum(), model.FeatureSet.fromWireString("").?);

    try std.testing.expect(model.FeatureSet.fromWireString("pipelining,pipelining") == null);
    try std.testing.expect(model.FeatureSet.fromWireString("pipelining,") == null);
    try std.testing.expect(model.FeatureSet.fromWireString("sturdy") == null);
}

test "default offer excludes private identity-route vocabulary" {
    const default_offer = model.FeatureSet.defaultOffer();
    try std.testing.expect(default_offer.untag);
    try std.testing.expect(!default_offer.multi_location);
    try std.testing.expect(model.FeatureSet.full().multi_location);
    try std.testing.expect(!(model.Preference{}).features.multi_location);
}

test "an absent feature hint never grants outbound untag" {
    const local = model.Preference{};
    try std.testing.expect(local.features.untag);
    const negotiated = negotiation.settle(local, model.Preference.baseline);
    try std.testing.expect(!model.Preference.baseline.features.untag);
    try std.testing.expect(!negotiated.features.untag);

    const glowcap_peer = negotiation.settle(local, local);
    try std.testing.expect(glowcap_peer.features.untag);
}

test "negotiate picks the most-preferred shared codec and intersects features" {
    const local = negotiation.Offer.glowcap(model.FeatureSet.full());
    const remote: negotiation.Offer = .{
        .captp_versions = &.{ .v1_0, .next },
        .codecs = &.{ .syrup, .capnp },
        .features = model.FeatureSet.pipeliningAndHandoff(),
    };

    const n = negotiation.negotiate(local, remote).?;
    // Both sum to preference 1; CaptpVersion declaration order breaks the tie to v1.0.
    try std.testing.expectEqual(model.CaptpVersion.v1_0, n.captp_version);
    // Both sum to preference 1; the CodecId tie-break picks `capnp` (declared
    // first).
    try std.testing.expectEqual(model.CodecId.capnp, n.codec);
    try std.testing.expectEqual(model.FeatureSet.pipeliningAndHandoff(), n.features);
}

test "v1.0 negotiation drops the glowcap-next multi-location feature" {
    const local = negotiation.Offer.v1_0Syrup(model.FeatureSet.full());
    const remote = negotiation.Offer.v1_0Syrup(model.FeatureSet.full());

    const n = negotiation.negotiate(local, remote).?;
    try std.testing.expectEqual(model.CaptpVersion.v1_0, n.captp_version);
    try std.testing.expect(!n.features.multi_location);
    try std.testing.expect(model.FeatureSet.full().forCaptpVersion(.next).multi_location);
}

test "negotiate is symmetric under perspective swap" {
    const a = negotiation.Offer.glowcap(model.FeatureSet.full());
    const b: negotiation.Offer = .{
        .captp_versions = &.{ .v1_0, .next },
        .codecs = &.{.syrup},
        .features = model.FeatureSet.full(),
    };

    const from_a = negotiation.negotiate(a, b).?;
    const from_b = negotiation.negotiate(b, a).?;
    try std.testing.expectEqual(from_a.captp_version, from_b.captp_version);
    try std.testing.expectEqual(from_a.codec, from_b.codec);
    try std.testing.expectEqual(from_a.features, from_b.features);
    // Both profiles are shared; the tie-break is profile declaration order, not
    // the codec or target.
    try std.testing.expectEqual(model.CaptpVersion.v1_0, from_a.captp_version);
    // Only syrup is shared.
    try std.testing.expectEqual(model.CodecId.syrup, from_a.codec);
}

test "negotiate returns null when no codec is shared" {
    const a: negotiation.Offer = .{
        .captp_versions = &.{.next},
        .codecs = &.{.capnp},
        .features = model.FeatureSet.full(),
    };
    const b: negotiation.Offer = .{
        .captp_versions = &.{.next},
        .codecs = &.{.syrup},
        .features = model.FeatureSet.full(),
    };
    try std.testing.expect(negotiation.negotiate(a, b) == null);
    try std.testing.expect(negotiation.negotiate(b, a) == null);
}

test "negotiate returns null when no profile is shared" {
    const a: negotiation.Offer = .{
        .captp_versions = &.{.next},
        .codecs = &.{.syrup},
        .features = model.FeatureSet.full(),
    };
    const b: negotiation.Offer = .{
        .captp_versions = &.{.v1_0},
        .codecs = &.{.syrup},
        .features = model.FeatureSet.full(),
    };
    try std.testing.expect(negotiation.negotiate(a, b) == null);
    try std.testing.expect(negotiation.negotiate(b, a) == null);
}

test "interop target offers constrain target without collapsing profile and codec axes" {
    const floor = negotiation.Offer.v1_0Syrup(model.FeatureSet.full());
    try std.testing.expectEqual(@as(usize, 1), floor.captp_versions.len);
    try std.testing.expectEqual(model.CaptpVersion.v1_0, floor.captp_versions[0]);
    try std.testing.expectEqual(@as(usize, 1), floor.codecs.len);
    try std.testing.expectEqual(model.CodecId.syrup, floor.codecs[0]);

    const glowcap_offer = negotiation.Offer.glowcap(model.FeatureSet.full());
    try std.testing.expect(glowcap_offer.captp_versions.len >= 2);
    try std.testing.expect(glowcap_offer.codecs.len >= 2);

    const negotiated = negotiation.negotiate(floor, glowcap_offer).?;
    try std.testing.expectEqual(model.CaptpVersion.v1_0, negotiated.captp_version);
    try std.testing.expectEqual(model.CodecId.syrup, negotiated.codec);
}

test "glowcap offers prefer next and capnp" {
    const n = negotiation.negotiate(
        negotiation.Offer.glowcap(model.FeatureSet.full()),
        negotiation.Offer.glowcap(model.FeatureSet.full()),
    ).?;
    try std.testing.expectEqual(model.CaptpVersion.next, n.captp_version);
    try std.testing.expectEqual(model.CodecId.capnp, n.codec);
}
