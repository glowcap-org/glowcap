const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const protocol_oracle = @import("protocol_oracle.zig");
const syrup = glowcap.ocapn.codec.syrup;
const handoff_fixtures = @import("../support/handoff_fixtures.zig");
const peer_fixture = @import("../support/peer_fixture.zig");

test "oracle-check verifies core Syrup fixture encoding parity" {
    const allocator = std.testing.allocator;

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .abort = .{ .kind = .other, .message = "shutting down" },
        });
        defer frame.deinit();
        try std.testing.expectEqualSlices(
            u8,
            protocol_oracle.fixtureByName("op_abort.bin").?.bytes(),
            frame.bytes(),
        );
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{
            .gc_answer = .{ .positions = &.{ 11, 13 } },
        });
        defer frame.deinit();
        try std.testing.expectEqualSlices(
            u8,
            protocol_oracle.fixtureByName("op_gc_answers.bin").?.bytes(),
            frame.bytes(),
        );
    }

    {
        // The op:listen break-notification fire, built by the engine itself
        // (`pipeline.borrowedListenerFire`): the break reason rides as a BARE
        // Symbol — `[Symbol("break"), Symbol(reason)]` — never as an `<error>`
        // record. Goblins' unmarshaller rejects unknown records and the
        // upstream conformance suite's `test_op_listen_to_promise_and_break`
        // asserts exactly this shape; this fixture pins it hermetically so a
        // regression to an `<error>`-record payload fails `zig build check`
        // without needing the opt-in live-Goblins gates.
        var args: [2]model.Argument = undefined;
        const fire = glowcap.ocapn.engine.pipeline.borrowedListenerFire(
            9,
            .{ .@"break" = .{ .message = "target unreachable" } },
            &args,
        );
        var frame = try syrup.encodeMessage(allocator, fire);
        defer frame.deinit();
        try std.testing.expectEqualSlices(
            u8,
            protocol_oracle.fixtureByName("op_deliver_listen_break_notification.bin").?.bytes(),
            frame.bytes(),
        );
    }
}

test "oracle-check exercises a three-peer handoff give and withdrawal" {
    const allocator = std.testing.allocator;
    const cross_peer = @import("../support/cross_peer.zig");

    var give_pair = try cross_peer.GivePair.init(allocator, &handoff_fixtures.recipient_key);
    defer give_pair.deinit();
    var recipient_to_exporter = glowcap.ocapn.engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = glowcap.ocapn.engine.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&give_pair.sender, &give_pair.recipient, &exporter, handoff_fixtures.give());
    try std.testing.expect(exporter.giftRegistry().giftLive(handoff_fixtures.gift_id[0..]));

    {
        var event = give_pair.recipient.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(glowcap.ocapn.engine.EventKind.deliver, event.kind());
    }

    try cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        handoff_fixtures.receiveFromRecipient(),
        cross_peer.testOnlyAcceptingVerifier(),
    );
    try std.testing.expect(!exporter.giftRegistry().giftLive(handoff_fixtures.gift_id[0..]));

    {
        var event = exporter.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(glowcap.ocapn.engine.EventKind.deliver, event.kind());
    }
}

test "oracle-check verifies supported owned fixture decoding parity" {
    const allocator = std.testing.allocator;
    const fixture = protocol_oracle.fixtureByName("desc_handoff_give_signed.bin").?;
    const decoded = try syrup.decodeSignedHandoffGiveOwned(allocator, fixture.bytes());
    defer model.freeHandoffGive(allocator, decoded);

    try std.testing.expectEqualStrings(handoff_fixtures.recipient_key[0..], decoded.recipient_key);
    try std.testing.expectEqualStrings("memory", decoded.exporter.transport);
    try std.testing.expectEqualStrings("exporter", decoded.exporter.designator);
    try std.testing.expectEqualStrings(handoff_fixtures.gift_id[0..], decoded.gift_id);
}

test "oracle-check verifies runtime deliver event and resolve state scenarios" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer.recvBorrowed(.{
        .bytes = "<10'op:deliver<11'desc:export7+>[]11+>",
        .shape = .byte,
    });
    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(glowcap.ocapn.engine.EventKind.deliver, event.kind());
    try std.testing.expect(peer.session_state.inboundAnswer(.from(11)) != null);

    var resolver = peer_fixture.openPeer(allocator);
    defer resolver.deinit();
    try resolver.session_state.registerImport(.from(9));
    try resolver.sendBorrowed(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(9) } },
            .args = &.{},
            .answer = .from(42),
        },
    });
    while ((try resolver.step()) != .idle) {}
    while (resolver.takeOutbound()) |frame_value| {
        var frame = frame_value;
        frame.deinit();
    }
    try peer_fixture.receiveResolverCallback(&resolver, .from(42), .{ .fulfill = .void });
    try std.testing.expectEqual(
        glowcap.ocapn.session.AnswerStatus.fulfilled,
        resolver.session_state.outboundAnswer(.from(42)).?.status,
    );
}
