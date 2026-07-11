const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const protocol_oracle = @import("protocol_oracle.zig");
const syrup = pancake.ocapn.codec.syrup;
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
        const fire = pancake.ocapn.engine.pipeline.borrowedListenerFire(
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

    {
        var frame = try syrup.encodeMessage(allocator, .{ .handoff = .{ .give = handoff_fixtures.give() } });
        defer frame.deinit();
        try std.testing.expectEqualSlices(
            u8,
            protocol_oracle.fixtureByName("op_handoff_give.bin").?.bytes(),
            frame.bytes(),
        );
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{ .handoff = .{ .receive = handoff_fixtures.receive() } });
        defer frame.deinit();
        try std.testing.expectEqualSlices(
            u8,
            protocol_oracle.fixtureByName("op_handoff_receive.bin").?.bytes(),
            frame.bytes(),
        );
    }
}

test "oracle-check exercises a three-peer handoff give and withdrawal" {
    const allocator = std.testing.allocator;
    const cross_peer = @import("../support/cross_peer.zig");

    var gifter = pancake.ocapn.engine.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = pancake.ocapn.engine.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = pancake.ocapn.engine.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = pancake.ocapn.engine.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, handoff_fixtures.give(), null);
    try std.testing.expect(exporter.giftRegistry().giftLive(handoff_fixtures.gift_id[0..]));

    {
        var event = recipient_from_gifter.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(pancake.ocapn.engine.EventKind.handoff, event.kind());
    }

    try cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        handoff_fixtures.receive(),
        cross_peer.acceptingVerifier(),
    );
    try std.testing.expect(!exporter.giftRegistry().giftLive(handoff_fixtures.gift_id[0..]));

    {
        var event = exporter.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(pancake.ocapn.engine.EventKind.handoff, event.kind());
    }
}

test "oracle-check verifies supported owned fixture decoding parity" {
    const allocator = std.testing.allocator;
    const fixture = protocol_oracle.fixtureByName("op_handoff_give.bin").?;
    const decoded = try syrup.decodeOwned(allocator, .{ .bytes = fixture.bytes(), .shape = .byte });
    // Free through the model so every owned field is reclaimed, including the
    // signed-envelope `raw_signed` bytes the decode captures for verification.
    defer model.freeMessage(allocator, decoded);

    try std.testing.expectEqualStrings(handoff_fixtures.recipient_key[0..], decoded.handoff.give.recipient_key);
    try std.testing.expectEqualStrings("memory:exporter", decoded.handoff.give.exporter_location);
    try std.testing.expectEqualStrings(handoff_fixtures.gift_id[0..], decoded.handoff.give.gift_id);
}

test "oracle-check verifies runtime deliver event and resolve state scenarios" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer.recvBorrowed(.{
        .bytes = "<10'op:deliver<11'desc:export7+>[]11+f>",
        .shape = .byte,
    });
    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(pancake.ocapn.engine.EventKind.deliver, event.kind());
    try std.testing.expect(peer.session_state.inboundAnswer(.from(11)) != null);

    var resolver = peer_fixture.openPeer(allocator);
    defer resolver.deinit();
    try resolver.session_state.registerImport(.from(9));
    try resolver.session_state.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(9) } },
            .args = &.{},
            .answer = .from(42),
        },
    });
    try resolver.recvBorrowed(.{
        .bytes = "<10'op:resolve42+<15'resolve:fulfill<4'void>>>",
        .shape = .byte,
    });
    try std.testing.expectEqual(
        pancake.ocapn.session.AnswerStatus.fulfilled,
        resolver.session_state.outboundAnswer(.from(42)).?.status,
    );
}
