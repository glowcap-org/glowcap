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
    const local: negotiation.Offer = .{
        .profiles = &.{ model.WireProfile.pre_spec, model.WireProfile.v1_0 },
        .codecs = &.{ .capnp, .syrup },
        .features = model.FeatureSet.full(),
    };
    const remote: negotiation.Offer = .{
        .profiles = &.{ model.WireProfile.v1_0, model.WireProfile.pre_spec },
        .codecs = &.{ .syrup, .capnp },
        .features = model.FeatureSet.pipeliningAndHandoff(),
    };

    const n = negotiation.negotiate(local, remote).?;
    // Both sum to preference 1; WireProfile order breaks the tie to v1.0.
    try std.testing.expectEqual(model.CaptpVersion.v1_0, n.profile.captp_version);
    // Both sum to preference 1; the CodecId tie-break picks `capnp` (declared
    // first).
    try std.testing.expectEqual(model.CodecId.capnp, n.chosen);
    try std.testing.expectEqual(model.FeatureSet.pipeliningAndHandoff(), n.features);
}

test "negotiate is symmetric under perspective swap" {
    const a: negotiation.Offer = .{
        .profiles = &.{ model.WireProfile.pre_spec, model.WireProfile.v1_0 },
        .codecs = &.{ .capnp, .syrup },
        .features = model.FeatureSet.full(),
    };
    const b: negotiation.Offer = .{
        .profiles = &.{ model.WireProfile.v1_0, model.WireProfile.pre_spec },
        .codecs = &.{.syrup},
        .features = model.FeatureSet.full(),
    };

    const from_a = negotiation.negotiate(a, b).?;
    const from_b = negotiation.negotiate(b, a).?;
    try std.testing.expectEqual(from_a.profile.captp_version, from_b.profile.captp_version);
    try std.testing.expectEqual(from_a.chosen, from_b.chosen);
    try std.testing.expectEqual(from_a.features, from_b.features);
    // Both profiles are shared; the tie-break is profile declaration order, not
    // the codec or target.
    try std.testing.expectEqual(model.CaptpVersion.v1_0, from_a.profile.captp_version);
    // Only syrup is shared.
    try std.testing.expectEqual(model.CodecId.syrup, from_a.chosen);
}

test "negotiate returns null when no codec is shared" {
    const a: negotiation.Offer = .{ .codecs = &.{.capnp}, .features = model.FeatureSet.full() };
    const b: negotiation.Offer = .{ .codecs = &.{.syrup}, .features = model.FeatureSet.full() };
    try std.testing.expect(negotiation.negotiate(a, b) == null);
    try std.testing.expect(negotiation.negotiate(b, a) == null);
}

test "negotiate returns null when no profile is shared" {
    const a: negotiation.Offer = .{
        .profiles = &.{model.WireProfile.pre_spec},
        .codecs = &.{.syrup},
        .features = model.FeatureSet.full(),
    };
    const b: negotiation.Offer = .{
        .profiles = &.{model.WireProfile.v1_0},
        .codecs = &.{.syrup},
        .features = model.FeatureSet.full(),
    };
    try std.testing.expect(negotiation.negotiate(a, b) == null);
    try std.testing.expect(negotiation.negotiate(b, a) == null);
}

const goblins_profiles = [_]model.WireProfile{model.WireProfile.v1_0};
const goblins_codecs = [_]model.CodecId{.syrup};
const pancake_profiles = [_]model.WireProfile{ model.WireProfile.pre_spec, model.WireProfile.v1_0 };
const pancake_codecs = [_]model.CodecId{ .capnp, .syrup };

fn offerForTarget(target: enum { goblins, pancake }, features: model.FeatureSet) negotiation.Offer {
    return switch (target) {
        .goblins => .{ .profiles = goblins_profiles[0..], .codecs = goblins_codecs[0..], .features = features },
        .pancake => .{ .profiles = pancake_profiles[0..], .codecs = pancake_codecs[0..], .features = features },
    };
}

test "interop target offers constrain target without collapsing profile and codec axes" {
    const goblins = offerForTarget(.goblins, model.FeatureSet.full());
    try std.testing.expectEqual(@as(usize, 1), goblins.profiles.len);
    try std.testing.expectEqual(model.CaptpVersion.v1_0, goblins.profiles[0].captp_version);
    try std.testing.expectEqual(@as(usize, 1), goblins.codecs.len);
    try std.testing.expectEqual(model.CodecId.syrup, goblins.codecs[0]);

    const pancake_offer = offerForTarget(.pancake, model.FeatureSet.full());
    try std.testing.expect(pancake_offer.profiles.len >= 2);
    try std.testing.expect(pancake_offer.codecs.len >= 2);

    const negotiated = negotiation.negotiate(goblins, pancake_offer).?;
    try std.testing.expectEqual(model.CaptpVersion.v1_0, negotiated.profile.captp_version);
    try std.testing.expectEqual(model.CodecId.syrup, negotiated.chosen);
}
