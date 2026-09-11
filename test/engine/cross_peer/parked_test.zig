//! The withdraw that arrives before its deposit: it parks and settles once
//! the gift lands, one wake scans nothing unrelated, and parked ids share
//! the session frame-byte cap. The verification and admission-bound half
//! lives in `parked_admission_test.zig`.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const session = glowcap.ocapn.session;
const crypto = glowcap.foundation.crypto;
const syrup = glowcap.ocapn.codec.syrup;
const cross_peer = @import("../../support/cross_peer.zig");
const CountingAllocator = @import("../../support/alloc_metrics.zig").CountingAllocator;
const peer_fixture = @import("../../support/peer_fixture.zig");

const fixtures = @import("fixtures.zig");
const repeated = fixtures.repeated;
const recipient_key = fixtures.recipient_key;
const gifter_session = fixtures.gifter_session;
const gifter_side = fixtures.gifter_side;
const receiving_session = fixtures.receiving_session;
const receiving_side = fixtures.receiving_side;
const give_signature = fixtures.give_signature;
const receive_signature = fixtures.receive_signature;
const gift_id_a = fixtures.gift_id_a;
const gift_id_b = fixtures.gift_id_b;
const sideOf = fixtures.sideOf;
const GifterSessionFixture = fixtures.GifterSessionFixture;
const PermissiveGifterSessionFixture = fixtures.PermissiveGifterSessionFixture;
const giveWith = fixtures.giveWith;
const receiveWith = fixtures.receiveWith;
const RejectingVerifier = fixtures.RejectingVerifier;
const RoutingVerifier = fixtures.RoutingVerifier;
const signedGive = fixtures.signedGive;

test "a withdraw that arrives before its deposit parks and settles once the gift lands" {
    const allocator = std.testing.allocator;

    const gifter_secret = crypto.SecretKey.fromSeed(repeated(32, 0x61));
    const recipient_secret = crypto.SecretKey.fromSeed(repeated(32, 0x62));
    const gifter_pub = gifter_secret.publicKey();
    const recipient_pub = recipient_secret.publicKey();
    // The receive has to name the side the exporter derives from the give.
    const recipient_side = sideOf(recipient_pub);

    var give_signed: []u8 = undefined;
    var give_sig: crypto.Signature = undefined;
    const give = try signedGive(gift_id_a[0..], recipient_pub.asBytes(), &gifter_secret, &give_signed, &give_sig, allocator);
    defer allocator.free(give_signed);

    var receive: model.HandoffReceive = .{
        .receiving_session = receiving_session[0..],
        .receiving_side = &recipient_side,
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&recipient_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    // Next settlement is observable through the mandatory listener callback.
    var exporter = peer_fixture.openPeer(allocator);
    defer exporter.deinit();
    var resolver_fixture: GifterSessionFixture = .{
        .side = gifter_side,
        .session_name = gifter_session,
        .key = gifter_pub.bytes,
        .gifts = exporter.giftRegistry(),
    };
    var node = engine.Node.init(allocator, repeated(32, 0x63));
    defer node.deinit();
    node.setGifterSessionResolver(resolver_fixture.resolver());
    _ = try node.registerPeerOver(&exporter);
    try exporter.session_state.transitionToOpen();

    // The withdraw arrives on the wire before any deposit: `deposit-gift` and
    // `withdraw-gift` travel on different sessions, so this order is legal.
    var handoff_arg = model.Handoff{ .receive = receive };
    // Verification materializes exactly the receive that can outlive this
    // frame. The caller either admits that owned value to its bounded pending
    // table or frees it without retaining untrusted input.
    const handoff_view = model.view.Handoff.fromOwned(&handoff_arg);
    switch (try engine.bootstrap.resolveForWithdraw(
        allocator,
        &exporter.session_state,
        exporter.giftRegistry(),
        exporter.gifterSessionResolver(),
        null,
        null,
        .{ .receive = handoff_view.receive, .answer = .fromWire(.from(1)) },
    )) {
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(allocator);
        },
        .settled => return error.TestUnexpectedSettlement,
    }
    const frame = try syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(0) },
        .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &handoff_arg } },
        .answer = .from(1),
    } });
    try exporter.feedOwned(frame);
    while ((try exporter.step()) != .idle) {}
    while (exporter.pollEvent()) |event_value| {
        var event = event_value;
        event.deinit();
    }
    try peer_fixture.receiveListenerForAnswer(&exporter, .from(1));

    // Not refused, parked: no answer left the peer and the entry is held. The
    // gift is not in the registry yet; the deposit lands below. The parked row
    // owns the verified receive and its accepted replay count, not a gift.
    try std.testing.expect(exporter.takeOutbound() == null);
    try std.testing.expectEqual(@as(usize, 1), exporter.pendingWithdrawCount());
    try std.testing.expect(!exporter.giftRegistry().giftLive(gift_id_a[0..]));

    // A second valid certificate can arrive before the same gift. Its newer
    // count advances replay authority immediately while both verified waits
    // remain parked. Settling the older wait below must never move that
    // monotonic counter backward.
    var later_receive = receive;
    later_receive.handoff_count = 2;
    later_receive.signature = "";
    const later_signed = try syrup.canonicalHandoffReceiveSignedBytes(allocator, later_receive);
    defer allocator.free(later_signed);
    const later_sig = crypto.sign(&recipient_secret, later_signed);
    later_receive.signature = later_sig.asBytes();
    var later_handoff = model.Handoff{ .receive = later_receive };
    const later_frame = try syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(0) },
        .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &later_handoff } },
        .answer = .from(2),
    } });
    try exporter.feedOwned(later_frame);
    while ((try exporter.step()) != .idle) {}
    while (exporter.pollEvent()) |event_value| {
        var event = event_value;
        event.deinit();
    }
    try peer_fixture.receiveListenerForAnswer(&exporter, .from(2));
    try std.testing.expect(exporter.takeOutbound() == null);
    try std.testing.expectEqual(@as(usize, 2), exporter.pendingWithdrawCount());

    // The deposit lands on the vat's registry (in production, via the gifter's
    // session to this same vat). The settlement below sends this reference on
    // *this* session, so the fixture holds the import it names: a fulfill may
    // only name a far this session holds, and the withdraw responder is not
    // exempt from that.
    try exporter.session_state.registerImport(.from(9));
    const deposited = model.Reference{ .far = .{ .import_position = .from(9) } };
    try exporter.giftRegistry().depositOwned(
        allocator,
        exporter.session_state.limits,
        null,
        gift_id_a[0..],
        deposited,
    );
    // This fixture writes the registry directly and drives the Peer without a
    // Host, so explicitly provide the exact wake a production Host forwards
    // from the Node after an inbound bootstrap deposit commits.
    exporter.noteHandoffChange(engine.node_services.HandoffDependency.init(
        exporter.node_services.?.peer_handle,
        gift_id_a[0..],
    ));

    // The next steps settle the parked withdraw: signature-verified, applied,
    // and answered with the deposited capability.
    while ((try exporter.step()) != .idle) {}
    var settled = exporter.takeOutbound() orelse return error.TestNoSettlement;
    defer settled.deinit();
    // One deposit satisfies one wait. The newer accepted wait remains parked
    // for a later re-deposit of the same gifter/id pair.
    try std.testing.expectEqual(@as(usize, 1), exporter.pendingWithdrawCount());
    try std.testing.expect(!exporter.giftRegistry().giftLive(gift_id_a[0..]));

    // The older wait settled after count 2 had already been accepted. Reusing
    // count 2 is still a replay; a plain assignment in commitWithdraw used to
    // roll the counter back to 1 and admit this certificate again.
    const later_view = model.view.Handoff.fromOwned(&later_handoff);
    var replay = switch (try engine.bootstrap.resolveForWithdraw(
        allocator,
        &exporter.session_state,
        exporter.giftRegistry(),
        exporter.gifterSessionResolver(),
        null,
        null,
        .{ .receive = later_view.receive, .answer = .fromWire(.from(3)) },
    )) {
        .settled => |prepared| prepared,
        .awaiting_deposit => |admission| {
            var pending_receive = admission.receive;
            pending_receive.deinit(allocator);
            return error.TestReplayWasParked;
        },
    };
    defer replay.deinit(allocator);
    try std.testing.expect(replay.resolution.? == .@"break");
}

test "one exact gift wake does not scan unrelated pending withdrawals" {
    const allocator = std.testing.allocator;
    var exporter = peer_fixture.openPeer(allocator);
    defer exporter.deinit();
    var resolver_fixture: GifterSessionFixture = .{
        .side = gifter_side,
        .session_name = gifter_session,
        .key = recipient_key,
        .gifts = exporter.giftRegistry(),
    };
    var node = engine.Node.init(allocator, repeated(32, 0x65));
    defer node.deinit();
    node.setGifterSessionResolver(resolver_fixture.resolver());
    const receiver_id = try node.registerPeerOver(&exporter);
    resolver_fixture.peer_handle = receiver_id;

    const pending_count = 256;
    var gift_ids: [pending_count][32]u8 = undefined;
    for (&gift_ids, 0..) |*gift_id, i| {
        gift_id.* = @as([32]u8, @splat(0));
        std.mem.writeInt(u64, gift_id[0..8], i, .little);
        var pending: engine.bootstrap.PendingReceive = .{
            .handoff_count = @intCast(i + 1),
            .recipient_key = recipient_key,
            .gifter_exporter_session = gifter_session,
            .gifter_side = gifter_side,
            .gift_id = try allocator.dupe(u8, gift_id),
        };
        exporter.parkPendingWithdraw(pending, .fromWire(.from(@intCast(i + 1))), receiver_id) catch |err| {
            pending.deinit(allocator);
            return err;
        };
    }
    try std.testing.expectEqual(@as(usize, pending_count), exporter.pendingWithdrawCount());

    const target = pending_count / 2;
    try exporter.session_state.installInboundAnswer(.from(target + 1));
    try peer_fixture.receiveListenerForAnswer(&exporter, .from(target + 1));
    try exporter.session_state.registerImport(.from(9));
    try exporter.giftRegistry().depositOwned(
        allocator,
        exporter.session_state.limits,
        null,
        &gift_ids[target],
        .{ .far = model.FarRef.object(9) },
    );
    const calls_before = resolver_fixture.resolve_calls;
    exporter.noteHandoffChange(engine.node_services.HandoffDependency.init(receiver_id, &gift_ids[target]));
    while ((try exporter.step()) != .idle) {}

    // The resolver is the observable probe at the head of every row retry.
    // Exact grouping calls it once for the matching row, not 256 times.
    try std.testing.expectEqual(calls_before + 1, resolver_fixture.resolve_calls);
    try std.testing.expectEqual(@as(usize, pending_count - 1), exporter.pendingWithdrawCount());
    var settlement = exporter.takeOutbound() orelse return error.MissingExactSettlement;
    settlement.deinit();
}

test "parked withdrawal gift ids share the session frame-byte cap" {
    const allocator = std.testing.allocator;
    var limits: engine.SessionLimits = .{};
    limits.max_frame_bytes = 64;
    var peer = engine.Peer.initNegotiatingWith(allocator, .{ .limits = limits });
    defer peer.deinit();

    const first: engine.bootstrap.PendingReceive = .{
        .handoff_count = 1,
        .recipient_key = recipient_key,
        .gifter_exporter_session = gifter_session,
        .gifter_side = gifter_side,
        .gift_id = try allocator.dupe(u8, &(@as([40]u8, @splat(0x41)))),
    };
    try peer.parkPendingWithdraw(first, .fromWire(.from(1)), .from(7));

    var second: engine.bootstrap.PendingReceive = .{
        .handoff_count = 2,
        .recipient_key = recipient_key,
        .gifter_exporter_session = gifter_session,
        .gifter_side = gifter_side,
        .gift_id = try allocator.dupe(u8, &(@as([40]u8, @splat(0x42)))),
    };
    try std.testing.expectError(session.Error.PendingWithdrawCapExceeded, peer.parkPendingWithdraw(second, .fromWire(.from(2)), .from(7)));
    second.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), peer.pendingWithdrawCount());
}
