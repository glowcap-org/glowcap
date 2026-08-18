//! Withdrawals and the exporter sessions they ride: V1 counts span sessions
//! while next counts stay session-local, a live exporter withdraws
//! immediately, retirement yields to newer withdrawals, and application
//! activity keeps a redeem-opened session alive.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const codec = pancake.ocapn.codec;
const engine = pancake.ocapn.engine;
const crypto = pancake.foundation.crypto;
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
    var node = Node.init(allocator, [_]u8{0x53} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient_a = try node.registerPeer(.{});
    const exporter_a = try node.registerPeer(.{});
    var counterpart_a = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(exporter_a).?,
        [_]u8{0x54} ** crypto.SEED_BYTES,
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
        [_]u8{0x55} ** crypto.SEED_BYTES,
    );
    defer counterpart_b.deinit();

    const give_a = try testGiveBytes(allocator);
    defer allocator.free(give_a);
    try node.acceptGive(recipient_a, 1, give_a, "ocapn://127.0.0.1%3A9061.tcp");
    const dial_a = node.nextAction().?;
    try node.exporterDialed(dial_a.dial.pending, exporter_a);
    try std.testing.expectEqual(exporter_a, node.nextAction().?.flush);
    try std.testing.expectEqual(@as(u64, 0), try takeWithdrawCount(node.peer(exporter_a).?));

    const give_b = try testGiveBytes(allocator);
    defer allocator.free(give_b);
    try node.acceptGive(recipient_b, 2, give_b, "ocapn://127.0.0.1%3A9062.tcp");
    const dial_b = node.nextAction().?;
    try node.exporterDialed(dial_b.dial.pending, exporter_b);
    try std.testing.expectEqual(exporter_b, node.nextAction().?.flush);
    try std.testing.expectEqual(@as(u64, 1), try takeWithdrawCount(node.peer(exporter_b).?));

    // The compatibility cursor affects issuance only. Each fresh V1 session's
    // own emitted counter remains untouched, and its accepted replay state is
    // still the authority for receives arriving on that session.
    try std.testing.expectEqual(@as(u64, 0), node.peer(exporter_a).?.giftRegistry().next_emitted_handoff_count);
    try std.testing.expectEqual(@as(u64, 0), node.peer(exporter_b).?.giftRegistry().next_emitted_handoff_count);
    try std.testing.expectEqual(@as(?u64, null), node.peer(exporter_a).?.giftRegistry().accepted_handoff_count);
    try std.testing.expectEqual(@as(?u64, null), node.peer(exporter_b).?.giftRegistry().accepted_handoff_count);

    const next_options: engine.Peer.NegotiatingOptions = .{ .captp_version = .next };
    const next_recipient_a = try node.registerPeer(next_options);
    const next_exporter_a = try node.registerPeer(next_options);
    var next_counterpart_a = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(next_exporter_a).?,
        [_]u8{0x56} ** crypto.SEED_BYTES,
    );
    defer next_counterpart_a.deinit();
    const next_recipient_b = try node.registerPeer(next_options);
    const next_exporter_b = try node.registerPeer(next_options);
    var next_counterpart_b = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(next_exporter_b).?,
        [_]u8{0x57} ** crypto.SEED_BYTES,
    );
    defer next_counterpart_b.deinit();

    const next_give_a = try testGiveBytes(allocator);
    defer allocator.free(next_give_a);
    try node.acceptGive(next_recipient_a, 3, next_give_a, "ocapn://127.0.0.1%3A9063.tcp");
    const next_dial_a = node.nextAction().?;
    try node.exporterDialed(next_dial_a.dial.pending, next_exporter_a);
    try std.testing.expectEqual(next_exporter_a, node.nextAction().?.flush);
    try std.testing.expectEqual(@as(u64, 0), try takeWithdrawCount(node.peer(next_exporter_a).?));

    const next_give_b = try testGiveBytes(allocator);
    defer allocator.free(next_give_b);
    try node.acceptGive(next_recipient_b, 4, next_give_b, "ocapn://127.0.0.1%3A9064.tcp");
    const next_dial_b = node.nextAction().?;
    try node.exporterDialed(next_dial_b.dial.pending, next_exporter_b);
    try std.testing.expectEqual(next_exporter_b, node.nextAction().?.flush);
    try std.testing.expectEqual(@as(u64, 0), try takeWithdrawCount(node.peer(next_exporter_b).?));
    try std.testing.expectEqual(@as(u64, 1), node.peer(next_exporter_a).?.giftRegistry().next_emitted_handoff_count);
    try std.testing.expectEqual(@as(u64, 1), node.peer(next_exporter_b).?.giftRegistry().next_emitted_handoff_count);
}

test "a live exporter withdraws immediately and the claimed resolve settles a routable route" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{8} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter).?, [_]u8{9} ** crypto.SEED_BYTES);
    defer counterpart.deinit();

    const locator = "ocapn://127.0.0.1%3A9052.tcp";
    const give = try testGiveBytes(allocator);
    defer allocator.free(give);
    try node.acceptGive(recipient, 31, give, locator);
    const dial = node.nextAction().?;
    try node.exporterDialed(dial.dial.pending, exporter);

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
    try std.testing.expectEqual(exporter, routed.peer_id);
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
    var node = Node.init(allocator, [_]u8{10} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter).?, [_]u8{11} ** crypto.SEED_BYTES);
    defer counterpart.deinit();

    const locator = "ocapn://127.0.0.1%3A9053.tcp";
    const give_a = try testGiveBytes(allocator);
    defer allocator.free(give_a);
    const give_b = try testGiveBytes(allocator);
    defer allocator.free(give_b);
    try node.acceptGive(recipient, 41, give_a, locator);
    try node.acceptGive(recipient, 42, give_b, locator);
    const dial = node.nextAction().?;
    try node.exporterDialed(dial.dial.pending, exporter);
    _ = node.nextAction().?; // first flush
    _ = node.nextAction().?; // second flush
    var answers: [2]u64 = undefined;
    var answer_index: usize = 0;
    var withdraws = node.pending_withdraws.keyIterator();
    while (withdraws.next()) |key| {
        try std.testing.expectEqual(exporter, key.peer_id);
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
    var node = Node.init(allocator, [_]u8{0x47} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter).?, [_]u8{0x48} ** crypto.SEED_BYTES);
    defer counterpart.deinit();

    const locator = "ocapn://127.0.0.1%3A9053.tcp";
    const first_give = try testGiveBytes(allocator);
    defer allocator.free(first_give);
    try node.acceptGive(recipient, 45, first_give, locator);
    const dial = node.nextAction().?;
    try node.exporterDialed(dial.dial.pending, exporter);
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
    var node = Node.init(allocator, [_]u8{10} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter).?, [_]u8{11} ** crypto.SEED_BYTES);
    defer counterpart.deinit();

    const give = try testGiveBytes(allocator);
    defer allocator.free(give);
    try node.acceptGive(recipient, 42, give, "ocapn://127.0.0.1%3A9053.tcp");
    const dial = node.nextAction().?;
    try node.exporterSelected(dial.dial.pending, exporter);
    _ = node.nextAction().?; // the flush
    const answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, answer, .not_capability));
    const refused = node.nextAction().?;
    try std.testing.expectEqualStrings("withdraw-gift did not resolve to a capability", refused.fail.reason.bytes());
    try std.testing.expect(node.nextAction() == null);
}

test "application activity preserves a redeem-opened exporter session" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{0x45} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter).?, [_]u8{0x46} ** crypto.SEED_BYTES);
    defer counterpart.deinit();

    const give = try testGiveBytes(allocator);
    defer allocator.free(give);
    try node.acceptGive(recipient, 44, give, "ocapn://127.0.0.1%3A9053.tcp");
    const dial = node.nextAction().?;
    try node.exporterDialed(dial.dial.pending, exporter);
    _ = node.nextAction().?; // flush

    node.exporterApplicationOwned(exporter);
    const answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, answer, .not_capability));
    _ = node.nextAction().?; // failure
    try std.testing.expect(node.nextAction() == null);
}

test "an application dial joining a pending redeem owns the exporter session" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{12} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter).?, [_]u8{13} ** crypto.SEED_BYTES);
    defer counterpart.deinit();

    const locator = "ocapn://127.0.0.1%3A9053.tcp";
    const give = try testGiveBytes(allocator);
    defer allocator.free(give);
    try node.acceptGive(recipient, 43, give, locator);
    const dial = node.nextAction().?;
    const joined = try node.stageDial(locator);
    try std.testing.expectEqual(dial.dial.pending, joined.pending);

    try node.exporterDialed(dial.dial.pending, exporter);
    _ = node.nextAction().?; // the flush
    const answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, answer, .{ .broken = "missing" }));
    _ = node.nextAction().?; // the failure
    try std.testing.expect(node.nextAction() == null);
}
