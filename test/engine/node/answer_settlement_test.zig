//! Answer settlements use the same recursive Passable transaction as ordinary
//! messages while retaining their semantic wire or virtual answer identity.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const codec = pancake.ocapn.codec;
const crypto = pancake.foundation.crypto;

const Node = engine.Node;
const openKeyedSessionWithCounterpart = @import("harness.zig").openKeyedSessionWithCounterpart;

const AnswerPath = enum {
    v1_wire,
    v1_virtual,
    next_wire,
};

fn installObservedAnswer(
    recipient: *engine.Peer,
    counterpart: *engine.Peer,
    path: AnswerPath,
) !model.AnswerName {
    const target = model.ExportPosition.from(recipient.session_state.next_export_position);
    try recipient.session_state.registerExport(target);
    try counterpart.session_state.registerImport(.from(target.int()));
    const virtual_resolver = model.ExportPosition.from(
        counterpart.session_state.next_export_position,
    );
    if (path == .v1_virtual)
        try counterpart.session_state.registerExport(virtual_resolver);

    try counterpart.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(target.int()) },
        .args = &.{},
        .answer = if (path == .v1_virtual) null else .from(41),
        .resolve_me_desc = if (path == .v1_virtual)
            .{ .near = model.NearRef.object(virtual_resolver.int()) }
        else
            null,
    } });
    try counterpart.stepToIdle();
    while (counterpart.takeOutbound()) |frame|
        try recipient.feedOwned(frame);
    try recipient.stepToIdle();

    var found: ?model.AnswerName = null;
    while (recipient.pollEvent()) |event_in| {
        var event = event_in;
        defer event.deinit();
        if (event.kind() == .deliver)
            found = try event.deliverAnswerName();
    }
    const answer = found orelse return error.MissingAnswer;
    switch (path) {
        .v1_virtual => try std.testing.expect(answer == .virtual),
        .v1_wire, .next_wire => try std.testing.expectEqual(
            model.AnswerName.fromWire(.from(41)),
            answer,
        ),
    }
    return answer;
}

fn runNestedSettlement(
    path: AnswerPath,
    options: engine.Peer.NegotiatingOptions,
) !void {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0xb0)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(options);
    const exporter_id = try node.registerPeer(options);
    const recipient = node.peer(recipient_id).?;
    const exporter = node.peer(exporter_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0xb1)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        exporter,
        @as([crypto.SEED_BYTES]u8, @splat(0xb2)),
    );
    defer exporter_counterpart.deinit();

    const answer = try installObservedAnswer(recipient, &recipient_counterpart, path);
    const original_target = recipient.session_state.answerTargetNamed(answer).?;
    try exporter.session_state.registerImport(.from(4));
    const foreign = try node.enrollForeign(exporter_id, .{ .far = model.FarRef.object(4) });
    const nested = [_]model.Argument{
        .{ .reference = foreign },
        .{ .list = &.{.{ .reference = foreign }} },
    };

    try recipient.sendAnswerTargetResolutionCopying(
        original_target,
        .{ .fulfill = .{ .list = &nested } },
    );
    try std.testing.expectEqual(@as(usize, 2), node.pendingGiftEffects());
    try std.testing.expect(recipient.session_state.peekResolutionNamed(answer) == null);
    const staged_bytes = recipient.queuedOutboundBytes();
    try std.testing.expect(staged_bytes > 0);
    const first = node.nextAction().?.need_gift_id.ticket;
    const second = node.nextAction().?.need_gift_id.ticket;

    // V1's resolver callback is accepted when the application result enters
    // staging. Releasing and legally reusing the partner-selected name while
    // gift entropy is pending must not cancel that callback or retarget the
    // old result to the replacement row.
    if (path == .v1_wire) {
        try recipient.session_state.recordRecv(.{ .gc_answer = .{
            .positions = &.{answer.wire.int()},
        } });
        try recipient.session_state.installInboundAnswerNamed(answer);
        const replacement = recipient.session_state.answerTargetNamed(answer).?;
        try std.testing.expect(replacement.row_id != original_target.row_id);
    }

    const first_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0xb3));
    try node.provideGiftId(second, &first_id);
    try std.testing.expect(recipient.session_state.peekResolutionNamed(answer) == null);
    try std.testing.expect(node.nextAction() == null);

    const second_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0xb4));
    try node.provideGiftId(first, &second_id);
    try std.testing.expectEqual(@as(usize, 0), node.pendingGiftEffects());
    const original_payload = recipient.session_state.answerPayloadForTarget(original_target).?;
    const stored = recipient.session_state.answerPayloadResolution(original_payload).?;
    try std.testing.expect(stored.* == .fulfill);
    const values = stored.fulfill.list;
    try std.testing.expectEqual(@as(usize, 2), values.len);
    try std.testing.expect(values[0] == .handoff);
    try std.testing.expect(values[1].list[0] == .handoff);
    if (path == .v1_wire)
        try std.testing.expect(recipient.session_state.peekResolutionNamed(answer) == null);
    const store_bytes = recipient.session_state.retainedSentAnswerBytes();
    try std.testing.expect(store_bytes > 0);
    try std.testing.expect(recipient.queuedOutboundBytes() >= store_bytes);

    var exporter_flushes: usize = 0;
    var recipient_flushes: usize = 0;
    while (node.nextAction()) |action| switch (action) {
        .flush => |peer_handle| {
            if (peer_handle == exporter_id) exporter_flushes += 1 else if (peer_handle == recipient_id) recipient_flushes += 1 else return error.UnexpectedNodeAction;
        },
        else => return error.UnexpectedNodeAction,
    };
    try std.testing.expectEqual(@as(usize, 2), exporter_flushes);
    try std.testing.expectEqual(@as(usize, 1), recipient_flushes);
    try std.testing.expect(recipient.sessionIsOpen());
    try std.testing.expect(exporter.sessionIsOpen());

    try exporter.stepToIdle();
    var deposits: usize = 0;
    while (exporter.takeOutbound()) |frame_value| {
        var frame = frame_value;
        frame.deinit();
        deposits += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), deposits);

    try recipient.stepToIdle();
    var callback_frame = recipient.takeOutbound().?;
    var callback_owned = true;
    defer if (callback_owned) callback_frame.deinit();
    const callback = (try codec.dispatch.decodeBodyForProfile(
        recipient.session_state.codec,
        recipient.session_state.captp_version,
        callback_frame.view(),
    )).deliver;
    try std.testing.expectEqual(@as(usize, 2), try callback.args.len());
    const tag = try callback.args.at(0);
    try std.testing.expect(tag == .symbol);
    try std.testing.expectEqualStrings("fulfill", tag.symbol);
    const callback_values = (try callback.args.at(1)).list;
    try std.testing.expectEqual(@as(usize, 2), try callback_values.len());
    try std.testing.expect((try callback_values.at(0)) == .handoff);
    try std.testing.expect((try (try callback_values.at(1)).list.at(0)) == .handoff);
    try std.testing.expect(recipient.takeOutbound() == null);

    if (path == .v1_virtual)
        try std.testing.expect(!recipient.session_state.hasInboundAnswerNamed(answer));

    if (path != .v1_virtual) {
        const feed_result = recipient_counterpart.feedOwned(callback_frame);
        callback_owned = false;
        try feed_result;
        try recipient_counterpart.stepToIdle();
        var saw_resolution = false;
        while (recipient_counterpart.pollEvent()) |event_in| {
            var event = event_in;
            defer event.deinit();
            if (event.kind() == .resolve) saw_resolution = true;
        }
        try std.testing.expect(saw_resolution);
    }

    try std.testing.expect(recipient.sessionIsOpen());
    try std.testing.expect(recipient_counterpart.sessionIsOpen());
    try std.testing.expect(exporter.sessionIsOpen());

    if (answer == .wire) {
        try recipient.session_state.recordRecv(.{ .gc_answer = .{
            .positions = &.{answer.wire.int()},
        } });
        try std.testing.expectEqual(
            @as(usize, 0),
            recipient.session_state.retainedSentAnswerBytes(),
        );
        try std.testing.expect(recipient.queuedOutboundBytes() < store_bytes);
    }
}

test "wire answer settlement recursively projects repeated nested foreign references" {
    try runNestedSettlement(.v1_wire, .{});
}

test "resolver-only virtual answer settlement preserves its name through a V1 callback" {
    try runNestedSettlement(.v1_virtual, .{});
}

test "next Cap'n Proto answer settlement fires its installed listener" {
    try runNestedSettlement(.next_wire, .{
        .captp_version = .next,
        .codec = .capnp,
    });
}

test "answer settlement recursively projects repeated nested foreign promises" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0xb5)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(.{});
    const home_id = try node.registerPeer(.{});
    const recipient = node.peer(recipient_id).?;
    const home = node.peer(home_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0xb6)),
    );
    defer recipient_counterpart.deinit();
    var home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        home,
        @as([crypto.SEED_BYTES]u8, @splat(0xb7)),
    );
    defer home_counterpart.deinit();

    const answer = model.AnswerName.fromWire(.from(44));
    try recipient.session_state.installInboundAnswerNamed(answer);
    try home.session_state.registerImport(.from(4));
    const foreign = try node.enrollForeign(home_id, .{ .far = model.FarRef.promise(4) });
    const nested = [_]model.Argument{
        .{ .reference = foreign },
        .{ .@"struct" = &.{.{ .key = "nested", .value = .{ .reference = foreign } }} },
    };

    try recipient.sendAnswerResolutionCopying(
        answer,
        .{ .fulfill = .{ .list = &nested } },
    );

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
    var home_frame = home.takeOutbound().?;
    defer home_frame.deinit();
    const listen = (try codec.dispatch.decodeBodyForProfile(
        home.session_state.codec,
        home.session_state.captp_version,
        home_frame.view(),
    )).listen;
    try std.testing.expectEqual(@as(u64, 4), listen.target.near.export_position.int());
    const listener_position = listen.listener.far.import_position.int();
    try std.testing.expect(home.takeOutbound() == null);

    const stored = recipient.session_state.peekResolutionNamed(answer).?.fulfill.list;
    const first = stored[0].reference;
    const second = stored[1].@"struct"[0].value.reference;
    try std.testing.expect(first == .near and first.near.kind == .promise);
    try std.testing.expect(second == .near and second.near.kind == .promise);
    try std.testing.expect(first.near.export_position != second.near.export_position);
    try std.testing.expectEqual(
        @as(u64, 1),
        recipient.session_state.exportRefcount(first.near.export_position),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        recipient.session_state.exportRefcount(second.near.export_position),
    );

    // This synthetic V1 answer has no resolver callback, so settlement is a
    // local consequence only. The paired third-party import uses the same
    // numeric slot; an ordinary wire delivery proves its counterpart-facing
    // `.far` encoding in `gift_test.zig`.
    try recipient.stepToIdle();
    try std.testing.expect(recipient.takeOutbound() == null);
    const first_import = model.ImportPosition.from(first.near.export_position.int());
    const second_import = model.ImportPosition.from(second.near.export_position.int());

    const settlement = try allocator.dupe(u8, "settled");
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home_id, listener_position, .{
        .fulfill = .{ .bytes = settlement },
    }));
    const first_settlement = recipient.session_state.importedPromiseResolution(first_import).?;
    const second_settlement = recipient.session_state.importedPromiseResolution(second_import).?;
    try std.testing.expectEqualStrings("settled", first_settlement.fulfill.bytes);
    try std.testing.expectEqualStrings("settled", second_settlement.fulfill.bytes);
}

test "settlement admission refusal leaves named answer and projection authority untouched" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0xc0)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(.{});
    const exporter_id = try node.registerPeer(.{});
    const recipient = node.peer(recipient_id).?;
    const exporter = node.peer(exporter_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0xc1)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        exporter,
        @as([crypto.SEED_BYTES]u8, @splat(0xc2)),
    );
    defer exporter_counterpart.deinit();

    const answer = model.AnswerName.fromWire(.from(42));
    try recipient.session_state.installInboundAnswerNamed(answer);
    try exporter.session_state.registerImport(.from(4));
    const foreign = try node.enrollForeign(exporter_id, .{ .far = model.FarRef.object(4) });
    const resolution: model.Resolution = .{ .fulfill = .{ .list = &.{
        .{ .reference = foreign },
        .{ .list = &.{.{ .reference = foreign }} },
    } } };
    const charge = try model.measureResolutionOwnedBytes(resolution);
    const staging_carrier_charge = engine.testing.answer_settlement_staging_carrier_bytes;
    try std.testing.expect(staging_carrier_charge > @sizeOf(model.AnswerName));
    recipient.outbound_budget = staging_carrier_charge + charge - 1;

    try std.testing.expectError(
        error.OutboundBackpressure,
        recipient.sendAnswerResolutionCopying(answer, resolution),
    );
    try std.testing.expect(!recipient.session_state.answerResolvedNamed(answer));
    try std.testing.expect(recipient.session_state.peekResolutionNamed(answer) == null);
    try std.testing.expectEqual(@as(usize, 0), recipient.queuedOutboundBytes());
    try std.testing.expectEqual(@as(usize, 0), node.pendingGiftEffects());
    try std.testing.expect(node.nextAction() == null);
    try std.testing.expect(recipient.sessionIsOpen());
    try std.testing.expect(exporter.sessionIsOpen());

    // The routed tree itself now fits, but replacing both leaves with signed
    // gives grows the retained settlement beyond the budget at commit. That
    // refusal releases the staging charge and publishes neither the answer nor
    // either prepared deposit; the adopted batch has one correlated terminal
    // session outcome.
    recipient.outbound_budget = staging_carrier_charge + charge;
    try recipient.sendAnswerResolutionCopying(answer, resolution);
    const first = node.nextAction().?.need_gift_id.ticket;
    const second = node.nextAction().?.need_gift_id.ticket;
    const first_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0xc3));
    const second_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0xc4));
    try node.provideGiftId(first, &first_id);
    try node.provideGiftId(second, &second_id);
    const terminal = node.nextAction().?.fail_session;
    try std.testing.expectEqual(recipient_id, terminal.peer_handle);
    try std.testing.expect(!recipient.session_state.answerResolvedNamed(answer));
    try std.testing.expectEqual(@as(usize, 0), recipient.queuedOutboundBytes());
    try std.testing.expectEqual(@as(usize, 0), node.pendingGiftEffects());
    try std.testing.expectEqual(engine.StepOutcome.idle, try exporter.step());
    try std.testing.expect(exporter.takeOutbound() == null);
}

test "settled answer admission charges its full fixed carrier plus resolution" {
    const allocator = std.testing.allocator;
    var peer = engine.testing.initRawOpenPeer(allocator);
    defer peer.deinit();

    const answer = model.AnswerName.fromWire(.from(46));
    const resolution: model.Resolution = .{ .fulfill = .{ .bytes = "retained" } };
    try peer.session_state.installInboundAnswerNamed(answer);
    const resolution_charge = try model.measureResolutionOwnedBytes(resolution);
    const carrier_charge = @sizeOf(@FieldType(engine.PendingOutbound, "item"));
    const total_charge = carrier_charge + resolution_charge;

    peer.outbound_budget = total_charge - 1;
    try std.testing.expectError(
        error.OutboundBackpressure,
        peer.sendAnswerResolutionCopying(answer, resolution),
    );
    try std.testing.expect(!peer.session_state.answerResolvedNamed(answer));
    try std.testing.expectEqual(@as(usize, 0), peer.queuedOutboundBytes());

    peer.outbound_budget = total_charge;
    try peer.sendAnswerResolutionCopying(answer, resolution);
    try std.testing.expectEqual(resolution_charge, peer.session_state.retainedSentAnswerBytes());
    try std.testing.expectEqual(total_charge, peer.queuedOutboundBytes());
}

test "stored answer replacement transfers the exact retained charge" {
    const allocator = std.testing.allocator;
    var peer = engine.testing.initRawOpenPeer(allocator);
    defer peer.deinit();

    const answer = model.AnswerName.fromWire(.from(43));
    try peer.session_state.installInboundAnswerNamed(answer);
    const large: model.Resolution = .{ .fulfill = .{
        .bytes = try allocator.dupe(u8, "a retained answer payload"),
    } };
    const large_charge = try model.measureResolutionOwnedBytes(large);
    try peer.session_state.storeResolutionNamed(answer, large);
    try std.testing.expectEqual(large_charge, peer.session_state.retainedSentAnswerBytes());

    const small: model.Resolution = .{ .fulfill = .{
        .bytes = try allocator.dupe(u8, "small"),
    } };
    const small_charge = try model.measureResolutionOwnedBytes(small);
    try peer.session_state.storeResolutionNamed(answer, small);
    try std.testing.expectEqual(small_charge, peer.session_state.retainedSentAnswerBytes());
    try std.testing.expectEqual(small_charge, peer.queuedOutboundBytes());
}

test "answer-store allocation refusal precedes every export mutation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var peer = engine.testing.initRawOpenPeer(allocator);
    defer peer.deinit();
    defer failing.fail_index = std.math.maxInt(usize);

    const answer = model.AnswerName.fromWire(.from(45));
    const export_position = model.ExportPosition.from(8);
    try peer.session_state.installInboundAnswerNamed(answer);
    try peer.session_state.reserveExport(export_position);
    const resolution: model.Resolution = .{ .fulfill = .{ .reference = .{
        .near = model.NearRef.promise(export_position.int()),
    } } };
    try peer.session_state.ensureSentResolutionExportCapacity(resolution);

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        peer.session_state.recordSentResolutionNamed(answer, resolution),
    );
    try std.testing.expect(!peer.session_state.answerResolvedNamed(answer));
    try std.testing.expect(peer.session_state.peekResolutionNamed(answer) == null);
    try std.testing.expectEqual(@as(u64, 1), peer.session_state.exportRefcount(export_position));
    try std.testing.expectEqual(@as(usize, 0), peer.session_state.retainedSentAnswerBytes());
}
