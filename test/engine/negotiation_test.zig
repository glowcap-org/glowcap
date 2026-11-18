const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const negotiation = glowcap.ocapn.engine.negotiation;

test "every packed feature set intersects pointwise" {
    const Bits = @Int(.unsigned, @bitSizeOf(model.FeatureSet));
    for (0..1 << @bitSizeOf(Bits)) |i| for (0..1 << @bitSizeOf(Bits)) |j| {
        const a: Bits = @intCast(i);
        const b: Bits = @intCast(j);
        const left: model.FeatureSet = @bitCast(a);
        try std.testing.expectEqual(a & b, @as(Bits, @bitCast(left.intersect(@bitCast(b)))));
    };
    try std.testing.expectEqual(model.FeatureSet{ .pipelining = true, .handoff = true, .wire_delta = true }, model.FeatureSet.pipeliningAndHandoff());
}

test "FeatureSet wire hint round-trips, refuses ambiguous forms, and drops unknown names" {
    var buf: [64]u8 = undefined;

    try std.testing.expectEqualStrings("", try model.FeatureSet.minimum().toWireString(&buf));
    const full = try model.FeatureSet.full().toWireString(&buf);
    try std.testing.expectEqualStrings("pipelining,handoff,wire_delta,sturdyref,untag,multi_location", full);
    try std.testing.expectEqual(model.FeatureSet.full(), model.FeatureSet.fromWireString(full).?);
    try std.testing.expectEqual(model.FeatureSet.minimum(), model.FeatureSet.fromWireString("").?);

    try std.testing.expect(model.FeatureSet.fromWireString("pipelining,pipelining") == null);
    try std.testing.expect(model.FeatureSet.fromWireString("pipelining,") == null);
    // A name this build does not know is a feature it cannot use, so a newer
    // build's addition narrows the shared set rather than refusing the hello.
    try std.testing.expectEqual(model.FeatureSet.minimum(), model.FeatureSet.fromWireString("sturdy").?);
    try std.testing.expectEqual(
        model.FeatureSet{ .pipelining = true },
        model.FeatureSet.fromWireString("a_later_feature,pipelining").?,
    );
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

fn offers(comptime T: type, comptime a: T, comptime b: T) [5][]const T {
    return .{ &.{}, &.{a}, &.{b}, &.{ a, b }, &.{ b, a } };
}

// The winner must be shared and no candidate may beat its rank or tie-break.
fn expectWinner(comptime T: type, winner: T, a: []const T, b: []const T) !void {
    const rank = (std.mem.findScalar(T, a, winner) orelse return error.UnsharedWinner) +
        (std.mem.findScalar(T, b, winner) orelse return error.UnsharedWinner);
    for (a, 0..) |option, i| {
        const j = std.mem.findScalar(T, b, option) orelse continue;
        try std.testing.expect(rank < i + j or (rank == i + j and @backingInt(winner) <= @backingInt(option)));
    }
}

test "every built-in offer pair selects the best shared version and codec" {
    const versions = offers(model.CaptpVersion, .v1_0, .next);
    const codecs = offers(model.CodecId, .capnp, .syrup);
    const full = model.FeatureSet.full();
    for (versions) |a| for (versions) |b| for (codecs) |c| for (codecs) |d| {
        const shared = std.mem.findAny(model.CaptpVersion, a, b) != null and std.mem.findAny(model.CodecId, c, d) != null;
        for ([_]model.FeatureSet{ full, model.FeatureSet.pipeliningAndHandoff() }) |offered| {
            const left: negotiation.Offer = .{ .captp_versions = a, .codecs = c, .features = full };
            const right: negotiation.Offer = .{ .captp_versions = b, .codecs = d, .features = offered };
            const result = negotiation.negotiate(left, right);
            try std.testing.expectEqualDeep(result, negotiation.negotiate(right, left));
            try std.testing.expectEqual(shared, result != null);
            if (result) |n| {
                try expectWinner(model.CaptpVersion, n.captp_version, a, b);
                try expectWinner(model.CodecId, n.codec, c, d);
                var expected = offered;
                expected.multi_location = offered.multi_location and n.captp_version == .next;
                expected.untag = offered.untag and n.captp_version == .v1_0;
                try std.testing.expectEqual(expected, n.features);
            }
        }
    };
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
