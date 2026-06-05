const std = @import("std");
const pancake = @import("pancake");

const model = pancake.model;
const runtime = pancake.runtime;
const session = pancake.session;
const cross_peer = runtime.cross_peer;

fn repeated(comptime n: usize, byte: u8) [n]u8 {
    return [_]u8{byte} ** n;
}

const recipient_key = repeated(32, 0x42);
const gifter_session = repeated(32, 0xcc);
const gifter_side = repeated(32, 0x11);
const receiving_session = repeated(32, 0xdd);
const receiving_side = repeated(32, 0x22);
const give_signature = repeated(64, 0xaa);
const receive_signature = repeated(64, 0xbb);
const gift_id_a = repeated(32, 0x01);
const gift_id_b = repeated(32, 0x02);

fn giveWith(gift_id: []const u8) model.HandoffGive {
    return .{
        .recipient_key = recipient_key[0..],
        .exporter_location = "memory:exporter",
        .gifter_exporter_session = gifter_session[0..],
        .gifter_side = gifter_side[0..],
        .gift_id = gift_id,
        .signature = give_signature[0..],
    };
}

fn receiveWith(gift_id: []const u8, count: u64, signature: []const u8) model.HandoffReceive {
    return .{
        .receiving_session = receiving_session[0..],
        .receiving_side = receiving_side[0..],
        .handoff_count = count,
        .signed_give = giveWith(gift_id),
        .signature = signature,
    };
}

const RejectingVerifier = struct {
    var context: u8 = 0;

    fn verify(_: *anyopaque, _: []const u8, _: []const u8) bool {
        return false;
    }

    fn make() cross_peer.SignatureVerifier {
        return .{ .context = &context, .verify_fn = verify };
    }
};

test "third-party handoff routes a give and authorizes a withdrawal across peers" {
    const allocator = std.testing.allocator;
    var gifter = runtime.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = runtime.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = runtime.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = runtime.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, giveWith(gift_id_a[0..]));

    {
        var event = recipient_from_gifter.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(runtime.EventKind.handoff, event.kind());
    }
    try std.testing.expect(exporter.session_state.giftDeposited(gift_id_a[0..]));
    try std.testing.expect(!exporter.session_state.giftWithdrawn(gift_id_a[0..]));

    try cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_a[0..], 1, receive_signature[0..]),
        cross_peer.acceptingVerifier(),
    );

    {
        var event = exporter.pollEvent().?;
        defer event.deinit();
        try std.testing.expectEqual(runtime.EventKind.handoff, event.kind());
    }
    try std.testing.expect(exporter.session_state.giftWithdrawn(gift_id_a[0..]));
}

test "third-party handoff rejects a replayed handoff count across peers" {
    const allocator = std.testing.allocator;
    var gifter = runtime.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = runtime.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = runtime.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = runtime.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, giveWith(gift_id_a[0..]));
    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, giveWith(gift_id_b[0..]));

    try cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_a[0..], 2, receive_signature[0..]),
        cross_peer.acceptingVerifier(),
    );

    try std.testing.expectError(session.Error.HandoffReplay, cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_b[0..], 1, receive_signature[0..]),
        cross_peer.acceptingVerifier(),
    ));
    try std.testing.expect(!exporter.session_state.giftWithdrawn(gift_id_b[0..]));
}

test "third-party handoff rejects a withdrawal whose signature fails verification" {
    const allocator = std.testing.allocator;
    var gifter = runtime.Peer.init(allocator);
    defer gifter.deinit();
    var recipient_from_gifter = runtime.Peer.init(allocator);
    defer recipient_from_gifter.deinit();
    var recipient_to_exporter = runtime.Peer.init(allocator);
    defer recipient_to_exporter.deinit();
    var exporter = runtime.Peer.init(allocator);
    defer exporter.deinit();

    try cross_peer.deliverGive(&gifter, &recipient_from_gifter, &exporter, giveWith(gift_id_a[0..]));

    try std.testing.expectError(cross_peer.Error.SignatureRejected, cross_peer.withdrawGift(
        &recipient_to_exporter,
        &exporter,
        receiveWith(gift_id_a[0..], 1, receive_signature[0..]),
        RejectingVerifier.make(),
    ));
    try std.testing.expect(!exporter.session_state.giftWithdrawn(gift_id_a[0..]));
}
