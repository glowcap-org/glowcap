const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const protocol_oracle = @import("protocol_oracle.zig");
const syrup = pancake.codec.syrup;

fn repeatedByte(comptime len: usize, byte: u8) [len]u8 {
    return [_]u8{byte} ** len;
}

const fixture_recipient_key = repeatedByte(32, 0x42);
const fixture_gifter_session = repeatedByte(32, 0xcc);
const fixture_gifter_side = repeatedByte(32, 0x11);
const fixture_gift_id = repeatedByte(32, 0x01);
const fixture_give_signature = repeatedByte(64, 0xaa);
const fixture_receiving_session = repeatedByte(32, 0xdd);
const fixture_receiving_side = repeatedByte(32, 0x22);
const fixture_receive_signature = repeatedByte(64, 0xbb);

fn fixtureGive() model.HandoffGive {
    return .{
        .recipient_key = fixture_recipient_key[0..],
        .exporter_location = "memory:exporter",
        .gifter_exporter_session = fixture_gifter_session[0..],
        .gifter_side = fixture_gifter_side[0..],
        .gift_id = fixture_gift_id[0..],
        .signature = fixture_give_signature[0..],
    };
}

fn fixtureReceive() model.HandoffReceive {
    return .{
        .receiving_session = fixture_receiving_session[0..],
        .receiving_side = fixture_receiving_side[0..],
        .handoff_count = 1,
        .signed_give = fixtureGive(),
        .signature = fixture_receive_signature[0..],
    };
}

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
        var frame = try syrup.encodeMessage(allocator, .{ .handoff = .{ .give = fixtureGive() } });
        defer frame.deinit();
        try std.testing.expectEqualSlices(
            u8,
            protocol_oracle.fixtureByName("op_handoff_give.bin").?.bytes(),
            frame.bytes(),
        );
    }

    {
        var frame = try syrup.encodeMessage(allocator, .{ .handoff = .{ .receive = fixtureReceive() } });
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
    const cross_peer = pancake.runtime.cross_peer;

    var gifter = pancake.runtime.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = pancake.runtime.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = pancake.runtime.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = pancake.runtime.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, fixtureGive());
    try std.testing.expect(exporter.session_state.giftDeposited(fixture_gift_id[0..]));

    {
        var event = recipient_from_gifter.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(pancake.runtime.EventKind.handoff, event.kind());
    }

    try cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        fixtureReceive(),
        cross_peer.acceptingVerifier(),
    );
    try std.testing.expect(exporter.session_state.giftWithdrawn(fixture_gift_id[0..]));

    {
        var event = exporter.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(pancake.runtime.EventKind.handoff, event.kind());
    }
}

test "oracle-check verifies supported owned fixture decoding parity" {
    const allocator = std.testing.allocator;
    const fixture = protocol_oracle.fixtureByName("op_handoff_give.bin").?;
    const decoded = try syrup.decodeOwned(allocator, .{ .bytes = fixture.bytes(), .shape = .byte });
    defer {
        allocator.free(decoded.handoff.give.recipient_key);
        allocator.free(decoded.handoff.give.exporter_location);
        allocator.free(decoded.handoff.give.gifter_exporter_session);
        allocator.free(decoded.handoff.give.gifter_side);
        allocator.free(decoded.handoff.give.gift_id);
        allocator.free(decoded.handoff.give.signature);
    }

    try std.testing.expectEqualStrings(fixture_recipient_key[0..], decoded.handoff.give.recipient_key);
    try std.testing.expectEqualStrings("memory:exporter", decoded.handoff.give.exporter_location);
    try std.testing.expectEqualStrings(fixture_gift_id[0..], decoded.handoff.give.gift_id);
}

test "oracle-check verifies runtime deliver event and resolve state scenarios" {
    const allocator = std.testing.allocator;
    var peer = pancake.runtime.Peer.init(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(7);

    try peer.recvBorrowed(.{
        .bytes = "<10'op:deliver<11'desc:export7+>[]11+f>",
        .shape = .byte,
    });
    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(pancake.runtime.EventKind.deliver, event.kind());
    try std.testing.expect(peer.session_state.inboundAnswer(11) != null);

    var resolver = pancake.runtime.Peer.init(allocator);
    defer resolver.deinit();
    try resolver.session_state.registerImport(9);
    try resolver.session_state.recordSend(.{
        .deliver = .{
            .target = .{ .far = .{ .import_id = 9 } },
            .args = &.{},
            .answer = 42,
        },
    });
    try resolver.recvBorrowed(.{
        .bytes = "<10'op:resolve42+<15'resolve:fulfill<4'void>>>",
        .shape = .byte,
    });
    try std.testing.expectEqual(
        pancake.session.AnswerStatus.fulfilled,
        resolver.session_state.outboundAnswer(42).?.status,
    );
}
