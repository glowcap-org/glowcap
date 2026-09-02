//! The v1.0 resolver-callback wire shape: resolve round-trips as a
//! resolver-callback deliver across paired peers, a record-shaped break
//! reason is accepted (Goblins interop), and a break encodes its reason as
//! the bare Symbol Goblins unmarshals.

const std = @import("std");
const glowcap = @import("glowcap");

const foundation = glowcap.foundation;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const session = glowcap.ocapn.session;
const codec = glowcap.ocapn.codec;
const pairing = engine.pairing;
const handshake = @import("../../support/handshake.zig");

const crypto = foundation.crypto;

const pairing_support = @import("harness.zig");
const pairedWithOffers = pairing_support.pairedWithOffers;

test "pairedWithOffers builds both peers with the negotiated (intersected) features" {
    const allocator = std.testing.allocator;
    // One side withholds handoff + sturdyref; the intersection must too, on both
    // peers, so neither exercises a capability the other did not advertise.
    const local: engine.negotiation.Offer = .{
        .captp_versions = &.{.v1_0},
        .codecs = &.{.syrup},
        .features = model.FeatureSet.full(),
    };
    const remote: engine.negotiation.Offer = .{
        .captp_versions = &.{.v1_0},
        .codecs = &.{.syrup},
        // full minus handoff + sturdyref.
        .features = .{
            .pipelining = true,
            .handoff = false,
            .wire_delta = true,
            .sturdyref = false,
        },
    };

    var pair = try pairedWithOffers(allocator, local, remote);
    defer pair.deinit();

    inline for (.{ &pair.p1, &pair.p2 }) |peer| {
        try std.testing.expectEqual(session.State.open, peer.session_state.state);
        try std.testing.expect(peer.session_state.features.pipelining);
        try std.testing.expect(peer.session_state.features.wire_delta);
        // Withheld by the intersection.
        try std.testing.expect(!peer.session_state.features.handoff);
        try std.testing.expect(!peer.session_state.features.sturdyref);
    }
}

test "v1.0 resolver-callback break encodes its reason as a bare Symbol, the shape Goblins unmarshals" {
    const allocator = std.testing.allocator;
    var pair = try pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();

    // p1 calls the partner bootstrap with an answer, minting a resolver export.
    try pair.p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(session.BOOTSTRAP_POSITION) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(42),
        .resolve_me_desc = null,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());

    const deliver_frame = pair.p1.takeOutbound().?;
    try pair.p2.feedOwned(deliver_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());
    {
        var event = pair.p2.pollEvent().?;
        event.deinit();
    }

    // p2 breaks the answer. On the V1.0 wire this becomes a resolver-callback
    // deliver whose break payload must be a bare Symbol: Goblins' unmarshal
    // table has no `<error …>` record (an unknown record tag raises
    // `captp-unknown-record-rag` and the break is lost), while a Symbol passes
    // its unmarshaller untouched, the same payload shape the `op:listen`
    // listener fire uses.
    try pair.p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .@"break" = .{ .message = "unknown swissnum" } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p2.step());

    const break_frame = pair.p2.takeOutbound().?;
    {
        // Pin the wire shape before handing the frame on.
        const body = try codec.dispatch.decodeBody(.syrup, break_frame.view());
        try std.testing.expect(body == .deliver);
        try std.testing.expectEqual(@as(usize, 2), try body.deliver.args.len());
        const tag = try body.deliver.args.at(0);
        try std.testing.expect(tag == .symbol);
        try std.testing.expectEqualSlices(u8, "break", tag.symbol);
        const payload = try body.deliver.args.at(1);
        try std.testing.expect(payload == .symbol);
        try std.testing.expectEqualSlices(u8, "unknown swissnum", payload.symbol);
    }

    // Symmetry: the receiving glowcap peer projects the same semantic break it
    // accepted before the shape change.
    try pair.p1.feedOwned(break_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try pair.p1.step());
    var event = pair.p1.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.resolve, event.kind());
    const view = try event.view();
    try std.testing.expectEqual(@as(u64, 42), view.resolve.answer.int());
    try std.testing.expect(view.resolve.resolution == .@"break");
    try std.testing.expectEqualSlices(u8, "unknown swissnum", view.resolve.resolution.@"break".message);
}
