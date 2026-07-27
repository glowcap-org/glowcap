const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const negotiation = pancake.ocapn.engine.negotiation;

test "FeatureSet.intersect is the field-wise AND and is symmetric" {
    const a = model.FeatureSet.full();
    const b = model.FeatureSet.pipeliningAndHandoff(); // no sturdyref

    const ab = a.intersect(b);
    const ba = b.intersect(a);

    // Symmetric.
    try std.testing.expectEqual(ab, ba);
    // The intersection drops whatever either side withholds.
    try std.testing.expect(ab.pipelining);
    try std.testing.expect(ab.handoff);
    try std.testing.expect(ab.wire_delta);
    try std.testing.expect(!ab.sturdyref);
}

test "intersect with minimum yields minimum" {
    const intersected = model.FeatureSet.full().intersect(model.FeatureSet.minimum());
    try std.testing.expectEqual(model.FeatureSet.minimum(), intersected);
}

test "negotiate picks the most-preferred shared codec and intersects features" {
    const local = negotiation.Offer.native(model.FeatureSet.full());
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

test "negotiate is symmetric under perspective swap" {
    const a = negotiation.Offer.native(model.FeatureSet.full());
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

    const pancake_offer = negotiation.Offer.native(model.FeatureSet.full());
    try std.testing.expect(pancake_offer.captp_versions.len >= 2);
    try std.testing.expect(pancake_offer.codecs.len >= 2);

    const negotiated = negotiation.negotiate(floor, pancake_offer).?;
    try std.testing.expectEqual(model.CaptpVersion.v1_0, negotiated.captp_version);
    try std.testing.expectEqual(model.CodecId.syrup, negotiated.codec);
}

test "native offers prefer next and capnp" {
    const n = negotiation.negotiate(
        negotiation.Offer.native(model.FeatureSet.full()),
        negotiation.Offer.native(model.FeatureSet.full()),
    ).?;
    try std.testing.expectEqual(model.CaptpVersion.next, n.captp_version);
    try std.testing.expectEqual(model.CodecId.capnp, n.codec);
}
