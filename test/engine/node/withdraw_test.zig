//! Withdrawals and the exporter sessions they ride: V1 counts span sessions
//! while next counts stay session-local, a live exporter withdraws
//! immediately, retirement yields to newer withdrawals, and application
//! activity keeps a redeem-opened session alive.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const LiveBytesAllocator = @import("../../support/alloc_metrics.zig").LiveBytesAllocator;

const Node = engine.Node;

const harness = @import("harness.zig");
const pendingWithdrawAnswer = harness.pendingWithdrawAnswer;
const peerUri = harness.peerUri;
const peerUriWithAlternatives = harness.peerUriWithAlternatives;
const takeWithdrawCount = harness.takeWithdrawCount;
const testGiveBytes = harness.testGiveBytes;
const mintRedeemedRoute = harness.mintRedeemedRoute;
const openKeyedSessionWithCounterpart = harness.openKeyedSessionWithCounterpart;

test "Node V1 withdrawal counts span sessions while next counts remain session-local" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x53)));
    defer node.deinit();

    const recipient_a = try node.registerPeer(.{});
    const exporter_a = try node.registerPeer(.{});
    var counterpart_a = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(exporter_a).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x54)),
    );
    defer counterpart_a.deinit();
    try std.testing.expectError(
        codec.syrup.Error.MalformedFrame,
        node.peer(exporter_a).?.sendWithdrawGift(node.secretKey(), "not a signed give", .from(99)),
    );
    try std.testing.expectEqual(@as(u64, 0), node.next_v1_emitted_handoff_count);

    const recipient_b = try node.registerPeer(.{});
    const exporter_b = try node.registerPeer(.{});
    var counterpart_b = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(exporter_b).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x55)),
    );
    defer counterpart_b.deinit();

    const give_a = try testGiveBytes(allocator);
    defer allocator.free(give_a);
    try node.acceptGive(recipient_a, 1, give_a, "ocapn://127.0.0.1%3A9061.tcp");
    const dial_a = node.nextAction().?;
    _ = try node.exporterDialed(dial_a.dial.pending, 0, exporter_a);
    try std.testing.expectEqual(exporter_a, node.nextAction().?.flush);
    try std.testing.expectEqual(@as(u64, 0), try takeWithdrawCount(node.peer(exporter_a).?));

    const give_b = try testGiveBytes(allocator);
    defer allocator.free(give_b);
    try node.acceptGive(recipient_b, 2, give_b, "ocapn://127.0.0.1%3A9062.tcp");
    const dial_b = node.nextAction().?;
    _ = try node.exporterDialed(dial_b.dial.pending, 0, exporter_b);
    try std.testing.expectEqual(exporter_b, node.nextAction().?.flush);
    try std.testing.expectEqual(@as(u64, 1), try takeWithdrawCount(node.peer(exporter_b).?));

    // The compatibility cursor affects issuance only. Each fresh V1 session's
    // own emitted counter remains untouched, and its accepted replay state is
    // still the authority for receives arriving on that session.
    try std.testing.expectEqual(@as(u64, 0), node.peer(exporter_a).?.giftRegistry().next_emitted_handoff_count);
    try std.testing.expectEqual(@as(u64, 0), node.peer(exporter_b).?.giftRegistry().next_emitted_handoff_count);
    try std.testing.expectEqual(@as(?u64, null), node.peer(exporter_a).?.giftRegistry().acceptedHandoffCount());
    try std.testing.expectEqual(@as(?u64, null), node.peer(exporter_b).?.giftRegistry().acceptedHandoffCount());

    const next_options: engine.Peer.NegotiatingOptions = .{ .captp_version = .next };
    const next_recipient_a = try node.registerPeer(next_options);
    const next_exporter_a = try node.registerPeer(next_options);
    var next_counterpart_a = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(next_exporter_a).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x56)),
    );
    defer next_counterpart_a.deinit();
    const next_recipient_b = try node.registerPeer(next_options);
    const next_exporter_b = try node.registerPeer(next_options);
    var next_counterpart_b = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(next_exporter_b).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x57)),
    );
    defer next_counterpart_b.deinit();

    const next_give_a = try testGiveBytes(allocator);
    defer allocator.free(next_give_a);
    try node.acceptGive(next_recipient_a, 3, next_give_a, "ocapn://127.0.0.1%3A9063.tcp");
    const next_dial_a = node.nextAction().?;
    _ = try node.exporterDialed(next_dial_a.dial.pending, 0, next_exporter_a);
    try std.testing.expectEqual(next_exporter_a, node.nextAction().?.flush);
    try std.testing.expectEqual(@as(u64, 0), try takeWithdrawCount(node.peer(next_exporter_a).?));

    const next_give_b = try testGiveBytes(allocator);
    defer allocator.free(next_give_b);
    try node.acceptGive(next_recipient_b, 4, next_give_b, "ocapn://127.0.0.1%3A9064.tcp");
    const next_dial_b = node.nextAction().?;
    _ = try node.exporterDialed(next_dial_b.dial.pending, 0, next_exporter_b);
    try std.testing.expectEqual(next_exporter_b, node.nextAction().?.flush);
    try std.testing.expectEqual(@as(u64, 0), try takeWithdrawCount(node.peer(next_exporter_b).?));
    try std.testing.expectEqual(@as(u64, 1), node.peer(next_exporter_a).?.giftRegistry().next_emitted_handoff_count);
    try std.testing.expectEqual(@as(u64, 1), node.peer(next_exporter_b).?.giftRegistry().next_emitted_handoff_count);
}

test "a live exporter withdraws immediately and the claimed resolve settles a routable route" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(8)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter).?, @as([crypto.SEED_BYTES]u8, @splat(9)));
    defer counterpart.deinit();

    const locator = "ocapn://127.0.0.1%3A9052.tcp";
    const give = try testGiveBytes(allocator);
    defer allocator.free(give);
    try node.acceptGive(recipient, 31, give, locator);
    const dial = node.nextAction().?;
    _ = try node.exporterDialed(dial.dial.pending, 0, exporter);

    // The withdraw went out on the exporter connection: one flush action, one
    // pending withdraw.
    const flush = node.nextAction().?;
    try std.testing.expectEqual(exporter, flush.flush);
    try std.testing.expect(node.nextAction() == null);
    const withdraw_answer = pendingWithdrawAnswer(&node, exporter);

    // An unrelated resolve is not claimed.
    try std.testing.expect(!try node.claimResolve(exporter, withdraw_answer + 100, .{ .far = 5 }));

    // The pending withdraw's resolve is claimed, the capability enrolled, and
    // the application answer settles with a routable route.
    try std.testing.expect(try node.claimResolve(exporter, withdraw_answer, .{ .far = 6 }));
    const settle = node.nextAction().?;
    try std.testing.expectEqual(recipient, settle.settle.dest.answer.recipient_peer);
    try std.testing.expectEqual(@as(u64, 31), settle.settle.dest.answer.answer.int());
    const routed = node.routeReference(recipient, .{ .routed = .{ .id = settle.settle.route_id } }).?;
    try std.testing.expectEqual(exporter, routed.peer_handle);
    try std.testing.expectEqual(@as(u64, 6), routed.target.far.import_position.int());

    // The exporter is cached: a later give for the same locator withdraws
    // immediately, no dial action.
    const give_more = try testGiveBytes(allocator);
    defer allocator.free(give_more);
    try node.acceptGive(recipient, 32, give_more, locator);
    const flush_again = node.nextAction().?;
    try std.testing.expectEqual(exporter, flush_again.flush);
    const second_answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, second_answer, .{ .broken = "later gift missing" }));
    const later_failure = node.nextAction().?;
    try std.testing.expectEqual(@as(u64, 32), later_failure.fail.dest.answer.answer.int());
    // The successful first redeem gave the application ownership of this
    // exporter session, so a later failed redeem does not retire it.
    try std.testing.expect(node.nextAction() == null);
}

test "the final failed withdraw retires a redeem-only exporter" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(10)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter).?, @as([crypto.SEED_BYTES]u8, @splat(11)));
    defer counterpart.deinit();

    const locator = "ocapn://127.0.0.1%3A9053.tcp";
    const give_a = try testGiveBytes(allocator);
    defer allocator.free(give_a);
    const give_b = try testGiveBytes(allocator);
    defer allocator.free(give_b);
    try node.acceptGive(recipient, 41, give_a, locator);
    try node.acceptGive(recipient, 42, give_b, locator);
    const dial = node.nextAction().?;
    _ = try node.exporterDialed(dial.dial.pending, 0, exporter);
    _ = node.nextAction().?; // first flush
    _ = node.nextAction().?; // second flush
    var answers: [2]u64 = undefined;
    var answer_index: usize = 0;
    var withdraws = node.redeems.withdrawals.rows.keyIterator();
    while (withdraws.next()) |key| {
        try std.testing.expectEqual(exporter, key.peer_handle);
        answers[answer_index] = key.answer;
        answer_index += 1;
    }
    try std.testing.expectEqual(answers.len, answer_index);

    try std.testing.expect(try node.claimResolve(exporter, answers[0], .{ .broken = "no such gift" }));
    const broke = node.nextAction().?;
    try std.testing.expectEqualStrings("handoff redeem failed: no such gift", broke.fail.reason.bytes());
    // One withdrawal is still live, so the exporter remains available for it.
    try std.testing.expect(node.nextAction() == null);

    try std.testing.expect(try node.claimResolve(exporter, answers[1], .not_capability));
    const refused = node.nextAction().?;
    try std.testing.expectEqualStrings("withdraw-gift did not resolve to a capability", refused.fail.reason.bytes());
    const retire = node.nextAction().?;
    try std.testing.expectEqual(exporter, retire.retire_exporter);
    try std.testing.expect(node.claimExporterRetirement(exporter));
    try std.testing.expect(!node.claimExporterRetirement(exporter));
    try std.testing.expect(node.nextAction() == null);
}

test "a queued exporter retirement yields to a newer withdrawal" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x47)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter).?, @as([crypto.SEED_BYTES]u8, @splat(0x48)));
    defer counterpart.deinit();

    const locator = "ocapn://127.0.0.1%3A9053.tcp";
    const first_give = try testGiveBytes(allocator);
    defer allocator.free(first_give);
    try node.acceptGive(recipient, 45, first_give, locator);
    const dial = node.nextAction().?;
    _ = try node.exporterDialed(dial.dial.pending, 0, exporter);
    _ = node.nextAction().?; // flush

    const first_answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, first_answer, .not_capability));
    _ = node.nextAction().?; // application failure

    // Before the queued retirement executes, another give reuses the retained
    // exporter cache and begins a withdrawal. The stale action must not close
    // a session the new redeem now needs.
    const second_give = try testGiveBytes(allocator);
    defer allocator.free(second_give);
    try node.acceptGive(recipient, 46, second_give, locator);
    const stale_retire = node.nextAction().?;
    try std.testing.expectEqual(exporter, stale_retire.retire_exporter);
    try std.testing.expect(!node.claimExporterRetirement(exporter));
    const second_flush = node.nextAction().?;
    try std.testing.expectEqual(exporter, second_flush.flush);

    const second_answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, second_answer, .not_capability));
    _ = node.nextAction().?; // application failure
    const final_retire = node.nextAction().?;
    try std.testing.expectEqual(exporter, final_retire.retire_exporter);
    try std.testing.expect(node.claimExporterRetirement(exporter));
}

test "a failed withdraw does not retire a selected exporter session" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(10)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter).?, @as([crypto.SEED_BYTES]u8, @splat(11)));
    defer counterpart.deinit();

    const give = try testGiveBytes(allocator);
    defer allocator.free(give);
    try node.acceptGive(recipient, 42, give, "ocapn://127.0.0.1%3A9053.tcp");
    const dial = node.nextAction().?;
    _ = try node.exporterSelected(dial.dial.pending, 0, exporter);
    _ = node.nextAction().?; // the flush
    const answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, answer, .not_capability));
    const refused = node.nextAction().?;
    try std.testing.expectEqualStrings("withdraw-gift did not resolve to a capability", refused.fail.reason.bytes());
    try std.testing.expect(node.nextAction() == null);
}

test "an application stage preserves a redeem-opened exporter session" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x45)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter).?, @as([crypto.SEED_BYTES]u8, @splat(0x46)));
    defer counterpart.deinit();

    const give = try testGiveBytes(allocator);
    defer allocator.free(give);
    const locator = "ocapn://127.0.0.1%3A9053.tcp";
    try node.acceptGive(recipient, 44, give, locator);
    const dial = node.nextAction().?;
    _ = try node.exporterDialed(dial.dial.pending, 0, exporter);
    _ = node.nextAction().?; // flush

    const staged = try node.stageDial(locator);
    try std.testing.expectEqual(exporter, staged.open);
    const answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, answer, .not_capability));
    _ = node.nextAction().?; // failure
    try std.testing.expect(node.nextAction() == null);
}

test "preparing application activity does not preserve a redeem-opened exporter session" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x47)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter).?, @as([crypto.SEED_BYTES]u8, @splat(0x48)));
    defer counterpart.deinit();

    const locator = model.PeerLocator{
        .transport = "tcp",
        .designator = "127.0.0.1:9053",
    };
    const give = try testGiveBytes(allocator);
    defer allocator.free(give);
    try node.acceptGive(recipient, 45, give, "ocapn://127.0.0.1%3A9053.tcp");
    const dial = node.nextAction().?;
    _ = try node.exporterDialed(dial.dial.pending, 0, exporter);
    _ = node.nextAction().?; // flush

    var prepared = try node.prepareDialLocator(locator);
    prepared.deinit(&node);

    const answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, answer, .not_capability));
    _ = node.nextAction().?; // failure
    const retire = node.nextAction().?;
    try std.testing.expectEqual(exporter, retire.retire_exporter);
    try std.testing.expect(node.claimExporterRetirement(exporter));
}

test "an application dial joining a pending redeem owns the exporter session" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(12)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter).?, @as([crypto.SEED_BYTES]u8, @splat(13)));
    defer counterpart.deinit();

    const locator = "ocapn://127.0.0.1%3A9053.tcp";
    const give = try testGiveBytes(allocator);
    defer allocator.free(give);
    try node.acceptGive(recipient, 43, give, locator);
    const dial = node.nextAction().?;
    const joined = try node.stageDial(locator);
    try std.testing.expectEqual(dial.dial.pending, joined.pending);

    _ = try node.exporterDialed(dial.dial.pending, 0, exporter);
    _ = node.nextAction().?; // the flush
    const answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, answer, .{ .broken = "missing" }));
    _ = node.nextAction().?; // the failure
    try std.testing.expect(node.nextAction() == null);
}
