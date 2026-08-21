//! Inline gift staging under budgets: per-recipient occurrence admission,
//! shared exporter reservations, and nested foreign promises sharing one
//! prepared home listener. The failure and retirement half lives in
//! `gift_failure_test.zig`.

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

test "inline gift staging refuses a complete message that exceeds the recipient budget" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x70)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(.{});
    const exporter_id = try node.registerPeer(.{});
    const recipient = node.peer(recipient_id).?;
    const exporter = node.peer(exporter_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0x71)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        exporter,
        @as([crypto.SEED_BYTES]u8, @splat(0x72)),
    );
    defer exporter_counterpart.deinit();

    try recipient.session_state.registerImport(.from(2));
    try exporter.session_state.registerImport(.from(4));
    const foreign = try node.enrollForeign(exporter_id, .{ .far = model.FarRef.object(4) });
    const message: model.Message = .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(2) },
        .args = &.{.{ .reference = foreign }},
    } };
    const retained_charge = try model.measureMessageOwnedBytes(message);
    try std.testing.expect(retained_charge > 0);
    recipient.outbound_budget = retained_charge - 1;

    try std.testing.expectError(error.OutboundBackpressure, recipient.sendCopying(message));
    try std.testing.expectEqual(@as(usize, 0), node.pendingGiftEffects());
    try std.testing.expect(node.nextAction() == null);
    try std.testing.expectEqual(@as(usize, 0), recipient.queuedOutboundBytes());
    try std.testing.expectEqual(engine.StepOutcome.idle, try exporter.step());
    try std.testing.expect(exporter.takeOutbound() == null);
}

test "inline gift occurrence admission is aggregate per recipient" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x73)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(.{ .limits = .{ .queue_cap = 2 } });
    const exporter_id = try node.registerPeer(.{});
    const recipient = node.peer(recipient_id).?;
    const exporter = node.peer(exporter_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0x74)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        exporter,
        @as([crypto.SEED_BYTES]u8, @splat(0x75)),
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
    try recipient.sendCopying(message);
    try std.testing.expectError(error.QueueCapExceeded, recipient.sendCopying(message));
    try std.testing.expectEqual(@as(usize, 2), node.pendingGiftEffects());
    const first = node.nextAction().?.need_gift_id.ticket;
    const second = node.nextAction().?.need_gift_id.ticket;
    try node.giftIdFailed(first);
    // The batch ticket tombstone pass must not consume a sibling batch's row.
    try std.testing.expect(!node.hasPendingGift(first));
    try std.testing.expect(node.hasPendingGift(second));
    try std.testing.expectEqual(@as(usize, 1), node.pendingGiftEffects());
    // Failing either admitted batch terminalizes the recipient. The sibling
    // batch is then retired by the session-close seam.
    const failure = node.nextAction().?.fail_session;
    try std.testing.expectEqual(recipient_id, failure.peer_handle);
    recipient.closeSession();
    try node.giftIdFailed(second); // stale after recipient retirement
    try std.testing.expectEqual(@as(usize, 0), node.pendingGiftEffects());
    try std.testing.expect(node.nextAction() == null);
}

test "same-exporter inline deposits share one cumulative outbound reservation" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x76)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(.{});
    const exporter_id = try node.registerPeer(.{});
    const recipient = node.peer(recipient_id).?;
    const exporter = node.peer(exporter_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0x77)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        exporter,
        @as([crypto.SEED_BYTES]u8, @splat(0x78)),
    );
    defer exporter_counterpart.deinit();

    try recipient.session_state.registerImport(.from(2));
    try exporter.session_state.registerImport(.from(4));
    const wire = model.Reference{ .far = model.FarRef.object(4) };
    const foreign = try node.enrollForeign(exporter_id, wire);
    const one_deposit: model.Message = .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(engine.BOOTSTRAP_POSITION) },
        .args = &.{ .{ .symbol = "deposit-gift" }, .{ .bytes = &(@as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0))) }, .{ .reference = wire } },
        .answer = null,
    } };
    const one_charge = try model.measureMessageOwnedBytes(one_deposit);
    exporter.outbound_budget = one_charge * 2 - 1;

    try recipient.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(2) },
        .args = &.{ .{ .reference = foreign }, .{ .reference = foreign } },
    } });
    const first = node.nextAction().?.need_gift_id.ticket;
    const second = node.nextAction().?.need_gift_id.ticket;
    const first_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0x79));
    const second_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0x7a));
    try node.provideGiftId(first, &first_id);
    try node.provideGiftId(second, &second_id);

    const failure = node.nextAction().?.fail_session;
    try std.testing.expectEqual(recipient_id, failure.peer_handle);
    recipient.closeSession();
    try std.testing.expectEqual(@as(usize, 0), node.pendingGiftEffects());
    try std.testing.expectEqual(engine.StepOutcome.idle, try exporter.step());
    try std.testing.expect(exporter.takeOutbound() == null);
}

test "nested foreign promises share one prepared home listener" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x7b)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(.{});
    const home_id = try node.registerPeer(.{});
    const recipient = node.peer(recipient_id).?;
    const home = node.peer(home_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0x7c)),
    );
    defer recipient_counterpart.deinit();
    var home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        home,
        @as([crypto.SEED_BYTES]u8, @splat(0x7d)),
    );
    defer home_counterpart.deinit();

    try recipient.session_state.registerImport(.from(2));
    try home.session_state.registerImport(.from(4));
    const foreign = try node.enrollForeign(home_id, .{ .far = model.FarRef.promise(4) });
    try recipient.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(2) },
        .args = &.{.{ .list = &.{
            .{ .reference = foreign },
            .{ .@"struct" = &.{.{ .key = "nested", .value = .{ .reference = foreign } }} },
        } }},
    } });

    var home_flushes: usize = 0;
    var recipient_flushes: usize = 0;
    while (node.nextAction()) |action| switch (action) {
        .flush => |peer_handle| {
            if (peer_handle == home_id) {
                home_flushes += 1;
            } else if (peer_handle == recipient_id) {
                recipient_flushes += 1;
            } else {
                return error.UnexpectedNodeAction;
            }
        },
        else => return error.UnexpectedNodeAction,
    };
    try std.testing.expectEqual(@as(usize, 1), home_flushes);
    try std.testing.expectEqual(@as(usize, 1), recipient_flushes);

    try home.stepToIdle();
    const listener_position = blk: {
        var home_frame = home.takeOutbound().?;
        defer home_frame.deinit();
        const listen = (try codec.dispatch.decodeBodyForProfile(
            home.session_state.codec,
            home.session_state.captp_version,
            home_frame.view(),
        )).listen;
        try std.testing.expectEqual(@as(u64, 4), listen.target.near.export_position.int());
        break :blk listen.listener.far.import_position.int();
    };
    try std.testing.expect(home.takeOutbound() == null);

    try recipient.stepToIdle();
    var recipient_frame = recipient.takeOutbound().?;
    defer recipient_frame.deinit();
    const delivered = (try codec.dispatch.decodeBodyForProfile(
        recipient.session_state.codec,
        recipient.session_state.captp_version,
        recipient_frame.view(),
    )).deliver;
    const nested = (try delivered.args.at(0)).list;
    const first = (try nested.at(0)).reference;
    const second = (try (try nested.at(1)).@"struct".at(0)).value.reference;
    try std.testing.expect(first == .far and first.far.kind == .promise);
    try std.testing.expect(second == .far and second.far.kind == .promise);
    try std.testing.expect(first.far.import_position != second.far.import_position);
    try std.testing.expect(recipient.takeOutbound() == null);

    const settlement = try allocator.dupe(u8, "settled");
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home_id, listener_position, .{
        .fulfill = .{ .bytes = settlement },
    }));
    const first_settlement = recipient.session_state.importedPromiseResolution(first.far.import_position).?;
    const second_settlement = recipient.session_state.importedPromiseResolution(second.far.import_position).?;
    try std.testing.expectEqualStrings("settled", first_settlement.fulfill.bytes);
    try std.testing.expectEqualStrings("settled", second_settlement.fulfill.bytes);
    var settlement_flushes: usize = 0;
    while (node.nextAction()) |action| switch (action) {
        .flush => |peer_handle| {
            try std.testing.expectEqual(recipient_id, peer_handle);
            settlement_flushes += 1;
        },
        else => return error.UnexpectedNodeAction,
    };
    try std.testing.expectEqual(@as(usize, 2), settlement_flushes);
}
