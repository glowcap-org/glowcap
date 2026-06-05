const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const negotiation = pancake.runtime.negotiation;

test "FeatureSet.intersect is the field-wise AND and is symmetric" {
    const a = model.FeatureSet.full();
    const b = model.FeatureSet.stage2Default(); // no sturdyref / stream / equality

    const ab = a.intersect(b);
    const ba = b.intersect(a);

    // Symmetric.
    try std.testing.expectEqual(ab, ba);
    // The intersection drops whatever either side withholds.
    try std.testing.expect(ab.pipelining);
    try std.testing.expect(ab.handoff);
    try std.testing.expect(ab.wire_delta);
    try std.testing.expect(!ab.sturdyref);
    try std.testing.expect(!ab.stream);
    try std.testing.expect(!ab.equality);
}

test "intersect with minimum yields minimum" {
    const intersected = model.FeatureSet.full().intersect(model.FeatureSet.minimum());
    try std.testing.expectEqual(model.FeatureSet.minimum(), intersected);
}

test "negotiate picks the most-preferred shared codec and intersects features" {
    const local: negotiation.Offer = .{
        .codecs = &.{ .capnp, .syrup },
        .features = model.FeatureSet.full(),
    };
    const remote: negotiation.Offer = .{
        .codecs = &.{ .syrup, .capnp },
        .features = model.FeatureSet.stage2Default(),
    };

    const n = negotiation.negotiate(local, remote).?;
    // Both sum to preference 1; the CodecId tie-break picks `capnp` (declared
    // first).
    try std.testing.expectEqual(negotiation.CodecId.capnp, n.chosen);
    try std.testing.expectEqual(model.FeatureSet.stage2Default(), n.features);
}

test "negotiate is symmetric under perspective swap" {
    const a: negotiation.Offer = .{ .codecs = &.{ .capnp, .syrup }, .features = model.FeatureSet.full() };
    const b: negotiation.Offer = .{ .codecs = &.{.syrup}, .features = model.FeatureSet.stage3Default() };

    const from_a = negotiation.negotiate(a, b).?;
    const from_b = negotiation.negotiate(b, a).?;
    try std.testing.expectEqual(from_a.chosen, from_b.chosen);
    try std.testing.expectEqual(from_a.features, from_b.features);
    // Only syrup is shared.
    try std.testing.expectEqual(negotiation.CodecId.syrup, from_a.chosen);
}

test "negotiate returns null when no codec is shared" {
    const a: negotiation.Offer = .{ .codecs = &.{.capnp}, .features = model.FeatureSet.full() };
    const b: negotiation.Offer = .{ .codecs = &.{.syrup}, .features = model.FeatureSet.full() };
    try std.testing.expect(negotiation.negotiate(a, b) == null);
    try std.testing.expect(negotiation.negotiate(b, a) == null);
}
