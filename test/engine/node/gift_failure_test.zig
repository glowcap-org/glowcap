//! Inline gift staging under failure: preparation rollback on a refused
//! recipient message, entropy tickets that retire whole messages, exporter
//! and home closures retiring every ticket, recipient refusals and
//! admission failures publishing no orphan deposit, and relayed failures
//! that spend no allocation after the home fire.

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

test "foreign-promise preparation rolls back when the recipient message is refused" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x7e)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(.{});
    const home_id = try node.registerPeer(.{});
    const recipient = node.peer(recipient_id).?;
    const home = node.peer(home_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0x7f)),
    );
    defer recipient_counterpart.deinit();
    var home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        home,
        @as([crypto.SEED_BYTES]u8, @splat(0x80)),
    );
    defer home_counterpart.deinit();

    try home.session_state.registerImport(.from(4));
    const foreign = try node.enrollForeign(home_id, .{ .far = model.FarRef.promise(4) });
    try std.testing.expectError(error.InvalidReference, recipient.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(99) },
        .args = &.{.{ .reference = foreign }},
    } }));

    try std.testing.expectEqual(@as(usize, 0), node.pendingGiftEffects());
    try std.testing.expect(node.nextAction() == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try home.step());
    try std.testing.expect(home.takeOutbound() == null);
    // The failed projection's paired export/import rows were never published.
    try std.testing.expect(!recipient.session_state.hasImport(.from(recipient.session_state.export_base)));
}

test "mixed object and promise projections publish only after gift entropy" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x81)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(.{});
    const home_id = try node.registerPeer(.{});
    const recipient = node.peer(recipient_id).?;
    const home = node.peer(home_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0x82)),
    );
    defer recipient_counterpart.deinit();
    var home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        home,
        @as([crypto.SEED_BYTES]u8, @splat(0x83)),
    );
    defer home_counterpart.deinit();

    try recipient.session_state.registerImport(.from(2));
    try home.session_state.registerImport(.from(4));
    try home.session_state.registerImport(.from(5));
    const object = try node.enrollForeign(home_id, .{ .far = model.FarRef.object(4) });
    const promise = try node.enrollForeign(home_id, .{ .far = model.FarRef.promise(5) });
    try recipient.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(2) },
        .args = &.{ .{ .reference = object }, .{ .reference = promise } },
    } });

    const ticket = node.nextAction().?.need_gift_id.ticket;
    try std.testing.expectEqual(engine.StepOutcome.idle, try recipient.step());
    try std.testing.expectEqual(engine.StepOutcome.idle, try home.step());
    try std.testing.expectError(error.InvalidArgument, node.provideGiftId(ticket, "short"));
    try std.testing.expect(node.hasPendingGift(ticket));
    try std.testing.expect(node.nextAction() == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try recipient.step());
    try std.testing.expectEqual(engine.StepOutcome.idle, try home.step());
    const gift_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0x84));
    try node.provideGiftId(ticket, &gift_id);

    var flushes: usize = 0;
    while (node.nextAction()) |action| switch (action) {
        .flush => flushes += 1,
        else => return error.UnexpectedNodeAction,
    };
    try std.testing.expectEqual(@as(usize, 3), flushes);
    try recipient.stepToIdle();
    var recipient_frame = recipient.takeOutbound().?;
    defer recipient_frame.deinit();
    const delivered = (try codec.dispatch.decodeBodyForProfile(
        recipient.session_state.codec,
        recipient.session_state.captp_version,
        recipient_frame.view(),
    )).deliver;
    try std.testing.expect((try delivered.args.at(0)).handoff == .give);
    const projected = (try delivered.args.at(1)).reference;
    try std.testing.expect(projected == .far and projected.far.kind == .promise);

    try home.stepToIdle();
    var deposits: usize = 0;
    var listens: usize = 0;
    while (home.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        const body = try codec.dispatch.decodeBodyForProfile(
            home.session_state.codec,
            home.session_state.captp_version,
            frame.view(),
        );
        switch (body) {
            .deliver => deposits += 1,
            .listen => listens += 1,
            else => return error.UnexpectedMessage,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), deposits);
    try std.testing.expectEqual(@as(usize, 1), listens);
}

test "closing a promise home retires a mixed projection waiting on gift entropy" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x85)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(.{});
    const exporter_id = try node.registerPeer(.{});
    const promise_home_id = try node.registerPeer(.{});
    const recipient = node.peer(recipient_id).?;
    const exporter = node.peer(exporter_id).?;
    const promise_home = node.peer(promise_home_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0x86)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        exporter,
        @as([crypto.SEED_BYTES]u8, @splat(0x87)),
    );
    defer exporter_counterpart.deinit();
    var promise_home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        promise_home,
        @as([crypto.SEED_BYTES]u8, @splat(0x88)),
    );
    defer promise_home_counterpart.deinit();

    try recipient.session_state.registerImport(.from(2));
    try exporter.session_state.registerImport(.from(4));
    try promise_home.session_state.registerImport(.from(5));
    const object = try node.enrollForeign(exporter_id, .{ .far = model.FarRef.object(4) });
    const promise = try node.enrollForeign(promise_home_id, .{ .far = model.FarRef.promise(5) });
    try recipient.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(2) },
        .args = &.{ .{ .reference = object }, .{ .reference = promise } },
    } });

    _ = node.nextAction().?.need_gift_id;
    node.removePeer(promise_home_id);

    try std.testing.expectEqual(@as(usize, 0), node.pendingGiftEffects());
    const failure = node.nextAction().?.fail_session;
    try std.testing.expectEqual(recipient_id, failure.peer_handle);
    recipient.closeSession();
    try std.testing.expect(node.nextAction() == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try exporter.step());
    try std.testing.expect(exporter.takeOutbound() == null);
}

test "inline gift entropy failure retires the whole message without a deposit" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x30)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(.{});
    const exporter_id = try node.registerPeer(.{});
    const recipient = node.peer(recipient_id).?;
    const exporter = node.peer(exporter_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0x31)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        exporter,
        @as([crypto.SEED_BYTES]u8, @splat(0x32)),
    );
    defer exporter_counterpart.deinit();

    try recipient.session_state.registerImport(.from(2));
    try exporter.session_state.registerImport(.from(4));
    const foreign = try node.enrollForeign(
        exporter_id,
        .{ .far = model.FarRef.object(4) },
    );
    try recipient.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(2) },
        .args = &.{ .{ .reference = foreign }, .{ .reference = foreign } },
    } });
    const failed_ticket = node.nextAction().?.need_gift_id.ticket;
    _ = node.nextAction().?; // the sibling ticket becomes stale with the batch
    try node.giftIdFailed(failed_ticket);

    try std.testing.expectEqual(@as(usize, 0), node.pendingGiftEffects());
    const action = node.nextAction().?;
    try std.testing.expectEqual(recipient_id, action.fail_session.peer_handle);
    recipient.closeSession();
    try std.testing.expect(!recipient.sessionIsOpen());
    try std.testing.expect(node.nextAction() == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try exporter.step());
    try std.testing.expect(exporter.takeOutbound() == null);
}

test "terminal cancellation retires an inline batch and its admission budget" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x39)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(.{ .limits = .{ .queue_cap = 1 } });
    const exporter_id = try node.registerPeer(.{});
    const recipient = node.peer(recipient_id).?;
    const exporter = node.peer(exporter_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0x3a)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        exporter,
        @as([crypto.SEED_BYTES]u8, @splat(0x3b)),
    );
    defer exporter_counterpart.deinit();

    try recipient.session_state.registerImport(.from(2));
    try exporter.session_state.registerImport(.from(4));
    const foreign = try node.enrollForeign(exporter_id, .{ .far = model.FarRef.object(4) });
    const message: model.Message = .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(2) },
        .args = &.{.{ .reference = foreign }},
    } };

    try recipient.sendCopying(message);
    try std.testing.expectEqual(@as(usize, 1), node.pendingGiftEffects());
    try std.testing.expect(recipient.queuedOutboundBytes() > 0);
    node.cancelPendingGifts();
    try std.testing.expectEqual(@as(usize, 0), node.pendingGiftEffects());
    try std.testing.expectEqual(@as(usize, 0), recipient.queuedOutboundBytes());
    const stale = node.nextAction().?.need_gift_id.ticket;
    try node.giftIdFailed(stale);
    try std.testing.expect(node.nextAction() == null);

    // The occurrence cap and terminal action seat retired with the batch, so
    // the same live session can admit new work instead of remaining wedged.
    try recipient.sendCopying(message);
    try std.testing.expectEqual(@as(usize, 1), node.pendingGiftEffects());
    const fresh = node.nextAction().?.need_gift_id.ticket;
    node.cancelPendingGifts();
    try node.giftIdFailed(fresh);
    try std.testing.expect(node.nextAction() == null);
}

test "closing an inline gift exporter retires every entropy ticket and the recipient" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x36)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(.{});
    const exporter_id = try node.registerPeer(.{});
    const recipient = node.peer(recipient_id).?;
    const exporter = node.peer(exporter_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0x37)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        exporter,
        @as([crypto.SEED_BYTES]u8, @splat(0x38)),
    );
    defer exporter_counterpart.deinit();

    try recipient.session_state.registerImport(.from(2));
    try exporter.session_state.registerImport(.from(4));
    const foreign = try node.enrollForeign(
        exporter_id,
        .{ .far = model.FarRef.object(4) },
    );
    try recipient.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(2) },
        .args = &.{ .{ .reference = foreign }, .{ .reference = foreign } },
    } });
    _ = node.nextAction().?.need_gift_id;
    _ = node.nextAction().?.need_gift_id;

    node.removePeer(exporter_id);
    try std.testing.expectEqual(@as(usize, 0), node.pendingGiftEffects());
    const failure = node.nextAction().?.fail_session;
    try std.testing.expectEqual(recipient_id, failure.peer_handle);
    recipient.closeSession();
    try std.testing.expect(!recipient.sessionIsOpen());
    try std.testing.expect(node.nextAction() == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try recipient.step());
    try std.testing.expect(recipient.takeOutbound() == null);
}

test "inline gift recipient refusal publishes no prepared deposit" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x33)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(.{});
    const exporter_id = try node.registerPeer(.{});
    const recipient = node.peer(recipient_id).?;
    const exporter = node.peer(exporter_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0x34)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        exporter,
        @as([crypto.SEED_BYTES]u8, @splat(0x35)),
    );
    defer exporter_counterpart.deinit();

    try recipient.session_state.registerImport(.from(2));
    try exporter.session_state.registerImport(.from(4));
    const foreign = try node.enrollForeign(
        exporter_id,
        .{ .far = model.FarRef.object(4) },
    );
    try recipient.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(2) },
        .args = &.{.{ .reference = foreign }},
    } });
    const ticket = node.nextAction().?.need_gift_id.ticket;

    // Every exporter deposit can be prepared, but the recipient cannot admit
    // its rewritten message. None of those preparations may become visible.
    recipient.outbound_budget = 1;
    const gift_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0xa3));
    try node.provideGiftId(ticket, &gift_id);
    const failure = node.nextAction().?.fail_session;
    try std.testing.expectEqual(recipient_id, failure.peer_handle);
    recipient.closeSession();
    try std.testing.expect(!recipient.sessionIsOpen());
    try std.testing.expectEqual(@as(usize, 0), node.pendingGiftEffects());
    try std.testing.expect(node.nextAction() == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try exporter.step());
    try std.testing.expect(exporter.takeOutbound() == null);
}

test "origination fails closed when the gift's home connection is gone" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(5)));
    defer node.deinit();

    const here = try node.registerPeer(.{});
    const elsewhere = try node.registerPeer(.{});

    // A foreign-home reply is claimed and the node asks for gift-id entropy;
    // the home connection then dies before the entropy answer arrives, so the
    // origination fails closed as a broken answer on the vanished connection
    // instead of mis-encoding a cross-connection reference. The negotiating
    // (session-never-opened) fail-closed arm is pinned by the
    // `interceptFulfilledRoute` test below; the live positive proof is the
    // `*-goblins-gift` matrix.
    try node.peer(elsewhere).?.session_state.registerImport(.from(4));
    const gift = try node.enrollForeign(elsewhere, .{ .far = model.FarRef.object(4) });
    try node.peer(here).?.session_state.installInboundAnswer(.from(61));
    try std.testing.expect(try node.interceptFulfilledRoute(here, 61, gift.routed.id));
    const ask = node.nextAction().?;
    node.removePeer(elsewhere);
    const gift_id = @as([32]u8, @splat(0xAB));
    try node.provideGiftId(ask.need_gift_id.ticket, &gift_id);
    const action = node.nextAction().?;
    try std.testing.expectEqual(here, action.fail.dest.served_answer.recipient_peer);
    try std.testing.expectEqual(
        model.AnswerName.fromWire(.from(61)),
        action.fail.dest.served_answer.answer.name,
    );
    try std.testing.expect(std.mem.startsWith(u8, action.fail.reason.bytes(), "handoff origination failed:"));
}

test "recipient admission failure publishes no orphan deposit" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x6a)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(recipient).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x6b)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(exporter).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x6c)),
    );
    defer exporter_counterpart.deinit();

    const answer = model.AnswerPosition.from(62);
    try node.peer(recipient).?.session_state.installInboundAnswer(answer);
    try node.peer(exporter).?.session_state.registerImport(.from(4));
    const gift = try node.enrollForeign(exporter, .{ .far = model.FarRef.object(4) });
    try std.testing.expect(try node.interceptFulfilledRoute(recipient, answer.int(), gift.routed.id));
    const ask = node.nextAction().?;

    // The exporter can prepare its deposit, but the recipient cannot admit the
    // give. Origination must publish neither half; the old deposit-first order
    // left a real deposit queued here with no give that could ever name it.
    node.peer(recipient).?.outbound_budget = 1;
    const gift_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0x6d));
    try node.provideGiftId(ask.need_gift_id.ticket, &gift_id);
    const failed = node.nextAction().?;
    try std.testing.expectEqual(recipient, failed.fail.dest.served_answer.recipient_peer);
    try std.testing.expectEqual(
        model.AnswerName.fromWire(answer),
        failed.fail.dest.served_answer.answer.name,
    );
    try std.testing.expect(node.peer(recipient).?.session_state.peekResolution(answer) == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try node.peer(exporter).?.step());
    try std.testing.expect(node.peer(exporter).?.takeOutbound() == null);
}

test "gift-id entropy failure settles the claimed handoff instead of stranding its ticket" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(6)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    try node.peer(exporter).?.session_state.registerImport(.from(4));
    const gift = try node.enrollForeign(exporter, .{ .far = model.FarRef.object(4) });
    try node.peer(recipient).?.session_state.installInboundAnswer(.from(62));
    try std.testing.expect(try node.interceptFulfilledRoute(recipient, 62, gift.routed.id));
    const ask = node.nextAction().?;

    try node.giftIdFailed(ask.need_gift_id.ticket);
    const failed = node.nextAction().?;
    try std.testing.expect(failed.fail.dest == .served_answer);
    try std.testing.expectEqual(recipient, failed.fail.dest.served_answer.recipient_peer);
    try std.testing.expectEqual(
        model.AnswerName.fromWire(.from(62)),
        failed.fail.dest.served_answer.answer.name,
    );
    try std.testing.expectEqualStrings(
        "handoff origination failed: gift-id entropy unavailable",
        failed.fail.reason.bytes(),
    );

    // Completion reports are idempotent across racing teardown/retry.
    try node.giftIdFailed(ask.need_gift_id.ticket);
    try std.testing.expect(node.nextAction() == null);
}

test "relayed gift-id failure spends no allocation after the home fire" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x76)));
    defer node.deinit();
    defer failing.fail_index = std.math.maxInt(usize);

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(home).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x77)),
    );
    defer home_counterpart.deinit();

    try node.peer(home).?.session_state.registerImport(.from(4));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(4) });
    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, route.routed.id)).?;
    const import_pos = rewritten.near.export_position.int();
    try std.testing.expectEqual(home, node.nextAction().?.flush);
    try node.peer(recipient).?.session_state.registerImport(.from(12));
    try node.peer(recipient).?.session_state.installImportedPromiseListener(.from(import_pos), .{
        .listener = .{ .import_position = .from(12) },
        .mode = .settling_only,
    });

    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    const listener = blk: {
        var frame = node.peer(home).?.takeOutbound().?;
        defer frame.deinit();
        const view = try pancake.ocapn.codec.syrup.decodeBody(frame.view());
        break :blk view.listen.listener.far.import_position.int();
    };

    try node.peer(home).?.session_state.registerImport(.from(9));
    const gifted = try node.enrollForeign(home, .{ .far = model.FarRef.object(9) });
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, listener, .{
        .fulfill = .{ .reference = gifted },
    }));
    const ask = node.nextAction().?;
    try std.testing.expect(ask == .need_gift_id);

    // The source fire and its only retry opportunity are gone. Admission
    // reserved the terminal resolution, so reporting entropy failure must
    // settle even when the allocator refuses every request from here onward.
    failing.fail_index = failing.alloc_index;
    try node.giftIdFailed(ask.need_gift_id.ticket);
    const settled = node.peer(recipient).?.session_state.importedPromiseResolution(.from(import_pos)).?;
    try std.testing.expect(settled.* == .@"break");
    try std.testing.expectEqualStrings("relayed promise could not be settled", settled.@"break".message);

    // The admission-time scheduler reservation becomes a recipient flush even
    // though no carrier could be allocated yet. Once pressure clears, `step`
    // retries the stored settlement and emits the listener fire exactly once.
    try std.testing.expectEqual(recipient, node.nextAction().?.flush);
    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(recipient).?.step());
    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(recipient).?.step());
    var fire = node.peer(recipient).?.takeOutbound().?;
    fire.deinit();
    try std.testing.expectEqual(engine.StepOutcome.idle, try node.peer(recipient).?.step());
}

test "a projected relayed value breaks from admission escrow under allocation failure" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x78)));
    defer node.deinit();
    defer failing.fail_index = std.math.maxInt(usize);

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(home).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x79)),
    );
    defer home_counterpart.deinit();

    try node.peer(home).?.session_state.registerImport(.from(4));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(4) });
    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, route.routed.id)).?;
    const import_pos = rewritten.near.export_position.int();
    try std.testing.expectEqual(home, node.nextAction().?.flush);

    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    const listener = blk: {
        var frame = node.peer(home).?.takeOutbound().?;
        defer frame.deinit();
        const view = try pancake.ocapn.codec.syrup.decodeBody(frame.view());
        break :blk view.listen.listener.far.import_position.int();
    };

    // The already-consumed source fire cannot be retried when recipient
    // materialization fails. Its admission escrow must still settle broken
    // without a best-effort allocation.
    try node.peer(home).?.session_state.registerImport(.from(10));
    const chained = try node.enrollForeign(home, .{ .far = model.FarRef.promise(10) });
    failing.fail_index = failing.alloc_index;
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, listener, .{
        .fulfill = .{ .reference = chained },
    }));
    const settled = node.peer(recipient).?.session_state.importedPromiseResolution(.from(import_pos)).?;
    try std.testing.expect(settled.* == .@"break");
    try std.testing.expectEqualStrings("relayed promise could not be settled", settled.@"break".message);
}

// ── The serve step: the sans-io redeem state machine ─────────────────────────
//
// These prove the *decisions* the serve step owns — interception, the exporter
// cache, dial dedup, pending withdraws, route settlement, fail-closed arms —
// as data in and actions out, with no socket. The live proof that the same
// step drives a real three-party redeem is `zig build goblins-handoff`.
