//! Redeemed routes and foreign-promise proxies: a route reaches its exporter
//! with the real reference swapped in, one home listen serves every recipient,
//! settlement relays into third-party import promises, and nested foreign
//! arguments publish as one transaction.

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

test "inline handoff redemption preserves its Host promise destination" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x4a)));
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const give = try testGiveBytes(allocator);
    defer allocator.free(give);
    try node.acceptInlineGive(
        recipient,
        73,
        give,
        "ocapn://127.0.0.1%3A7099.tcp",
    );

    const dial = node.nextAction().?;
    try std.testing.expect(dial == .dial);
    try std.testing.expectEqual(Node.DialFailure.exhausted, try node.dialFailed(dial.dial.pending, 0, "refused"));
    const failed = node.nextAction().?;
    try std.testing.expect(failed == .fail);
    try std.testing.expectEqual(recipient, failed.fail.dest.deferred.recipient_peer);
    try std.testing.expectEqual(@as(u64, 73), failed.fail.dest.deferred.id);
    try std.testing.expect(std.mem.indexOf(u8, failed.fail.reason.bytes(), "refused") != null);
}

test "a redeemed route routes to its exporter with the real reference swapped in" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(9)));
    defer node.deinit();

    const recipient_conn = try node.registerPeer(.{});
    const exporter_conn = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter_conn).?, @as([crypto.SEED_BYTES]u8, @splat(16)));
    defer counterpart.deinit();

    // Redeem a give against the live exporter; the claimed resolve enrolls the
    // real exporter-side reference (far 42) under a fresh Node route.
    const route = try mintRedeemedRoute(&node, recipient_conn, exporter_conn, 71, 42, "ocapn://127.0.0.1%3A9055.tcp");
    const route_ref: model.Reference = .{ .routed = .{ .id = route } };
    try std.testing.expectEqual(route, node.redeemedRouteId(route_ref).?);

    // A send to the route routes to the exporter connection with the real ref.
    const routed = node.routeReference(recipient_conn, route_ref).?;
    try std.testing.expectEqual(exporter_conn, routed.peer_handle);
    try std.testing.expectEqual(@as(u64, 42), routed.target.far.import_position.int());

    // An ordinary far import rides the connection the app addressed, unchanged.
    const plain: model.Reference = .{ .far = model.FarRef.object(3) };
    const plain_routed = node.routeReference(recipient_conn, plain).?;
    try std.testing.expectEqual(recipient_conn, plain_routed.peer_handle);
    try std.testing.expectEqual(@as(u64, 3), plain_routed.target.far.import_position.int());

    // A route whose exporter connection is gone fails closed.
    node.removePeer(exporter_conn);
    try std.testing.expectEqual(@as(usize, 0), node.redeemed.count());
    try std.testing.expect(node.routeReference(recipient_conn, route_ref) == null);
}

test "enrollForeign preserves promise RefKind on the route" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(3)));
    defer node.deinit();
    const home = try node.registerPeer(.{});
    try node.peer(home).?.session_state.registerImport(.from(8));
    try node.peer(home).?.session_state.registerImport(.from(9));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(8) });
    try std.testing.expectEqual(model.RefKind.promise, route.routed.kind);
    const object_route = try node.enrollForeign(home, .{ .far = model.FarRef.object(9) });
    try std.testing.expectEqual(model.RefKind.object, object_route.routed.kind);
}

test "proxyForeignPromiseFulfill refuses when the home session is not open" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(11)));
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    try node.peer(home).?.session_state.registerImport(.from(4));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(4) });
    try std.testing.expectError(
        error.session_not_open,
        node.proxyForeignPromiseFulfill(recipient, route.routed.id),
    );
}

test "proxyForeignPromiseFulfill mints a third-party import-promise on the recipient peer" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(11)));
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, @as([crypto.SEED_BYTES]u8, @splat(19)));
    defer home_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const far_id = route.routed.id;

    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, far_id)).?;
    try std.testing.expectEqual(model.RefKind.promise, rewritten.near.kind);
    const pos = rewritten.near.export_position;
    const peer = node.peer(recipient).?;
    try std.testing.expect(peer.session_state.isThirdPartyImport(.from(pos.int())));

    try node.peer(home).?.session_state.registerImport(.from(5));
    const obj = try node.enrollForeign(home, .{ .far = model.FarRef.object(5) });
    try std.testing.expect((try node.proxyForeignPromiseFulfill(recipient, obj.routed.id)) == null);
    try std.testing.expect((try node.proxyForeignPromiseFulfill(home, far_id)) == null);
}

test "proxyForeignPromise home listen relays settlement to the recipient third-party import" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(13)));
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, @as([crypto.SEED_BYTES]u8, @splat(21)));
    defer home_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const far_id = route.routed.id;

    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, far_id)).?;
    const import_pos = rewritten.near.export_position.int();

    // Home listen is queued; step encodes it. The listener export is what Host
    // will match on an inbound fire deliver.
    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    const listener = blk: {
        var frame = node.peer(home).?.takeOutbound().?;
        defer frame.deinit();
        const view = try glowcap.ocapn.codec.syrup.decodeBody(frame.view());
        try std.testing.expect(view == .listen);
        // Own-outbound decode flips near export → far import; position is the
        // listener export we allocated on the home peer.
        break :blk view.listen.listener.far.import_position.int();
    };
    const payload = try allocator.dupe(u8, "relayed");
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, listener, .{ .fulfill = .{ .bytes = payload } }));

    const recip = node.peer(recipient).?;
    try std.testing.expectEqualStrings("relayed", recip.session_state.importedPromiseResolution(.from(import_pos)).?.fulfill.bytes);

    // After settle the proxy is torn down; a second deliver is not claimed
    // (resolve-once lives in the import store, not a zombie Node index).
    const second = try allocator.dupe(u8, "again");
    defer allocator.free(second);
    try std.testing.expect(!node.consumeProjectedProxyListenerFire(home, listener, .{ .fulfill = .{ .bytes = second } }));
}

test "a next proxy settling listener follows shortening on its home session" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x42)));
    defer node.deinit();

    const home = try node.registerPeer(.{ .captp_version = .next });
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(home).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x43)),
    );
    defer home_counterpart.deinit();

    const source: u64 = 4;
    const target: u64 = 6;
    const home_peer = node.peer(home).?;
    try home_peer.session_state.registerImport(.from(source));
    const shortening_resolver = model.ExportPosition.from(home_peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(home_peer, .from(source));

    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(source) });
    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, route.routed.id)).?;
    const recipient_import = rewritten.near.export_position.int();

    while ((try home_peer.step()) != .idle) {}
    var initial_shortening = home_peer.takeOutbound().?;
    defer initial_shortening.deinit();
    var initial_settling = home_peer.takeOutbound().?;
    defer initial_settling.deinit();
    const initial_shortening_body = try glowcap.ocapn.codec.syrup.decodeBodyForProfile(.next, initial_shortening.view());
    const initial_settling_body = try glowcap.ocapn.codec.syrup.decodeBodyForProfile(.next, initial_settling.view());
    try std.testing.expectEqual(model.ListenMode.shortening_only, initial_shortening_body.listen.mode);
    try std.testing.expectEqual(model.ListenMode.settling_only, initial_settling_body.listen.mode);
    const settling_listener = initial_settling_body.listen.listener.far.import_position.int();

    const shortening_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(target) } },
    };
    var shortening = try glowcap.ocapn.codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(shortening_resolver.int()) },
        .args = &shortening_args,
    } });
    defer shortening.deinit();
    try home_peer.recvBorrowed(shortening.view());

    while ((try home_peer.step()) != .idle) {}
    var recursive_shortening = home_peer.takeOutbound().?;
    defer recursive_shortening.deinit();
    var rearmed_settling = home_peer.takeOutbound().?;
    defer rearmed_settling.deinit();
    const recursive_body = try glowcap.ocapn.codec.syrup.decodeBodyForProfile(.next, recursive_shortening.view());
    const rearmed_body = try glowcap.ocapn.codec.syrup.decodeBodyForProfile(.next, rearmed_settling.view());
    try std.testing.expectEqual(model.ListenMode.shortening_only, recursive_body.listen.mode);
    try std.testing.expectEqual(target, recursive_body.listen.target.near.export_position.int());
    try std.testing.expectEqual(model.ListenMode.settling_only, rearmed_body.listen.mode);
    try std.testing.expectEqual(target, rearmed_body.listen.target.near.export_position.int());
    try std.testing.expectEqual(settling_listener, rearmed_body.listen.listener.far.import_position.int());
    try std.testing.expect(node.isProxyHomeListener(home, settling_listener));

    const payload = try allocator.dupe(u8, "shortened relay");
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, settling_listener, .{
        .fulfill = .{ .bytes = payload },
    }));
    try std.testing.expectEqualStrings(
        "shortened relay",
        node.peer(recipient).?.session_state.importedPromiseResolution(.from(recipient_import)).?.fulfill.bytes,
    );

    // A proxy first requested after shortening starts at the current target;
    // it must not spend its one settling subscription on the obsolete source.
    const late_source: u64 = 8;
    const late_target: u64 = 9;
    try home_peer.session_state.registerImport(.from(late_source));
    const late_shortening_resolver = model.ExportPosition.from(home_peer.session_state.next_export_position);
    try engine.listen.ensureShorteningListener(home_peer, .from(late_source));
    while ((try home_peer.step()) != .idle) {}
    while (home_peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const late_shortening_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(late_target) } },
    };
    var late_shortening = try glowcap.ocapn.codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(late_shortening_resolver.int()) },
        .args = &late_shortening_args,
    } });
    defer late_shortening.deinit();
    try home_peer.recvBorrowed(late_shortening.view());
    while ((try home_peer.step()) != .idle) {}
    while (home_peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const late_route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(late_source) });
    _ = (try node.proxyForeignPromiseFulfill(recipient, late_route.routed.id)).?;
    while ((try home_peer.step()) != .idle) {}
    var late_settling = home_peer.takeOutbound().?;
    defer late_settling.deinit();
    const late_settling_body = try glowcap.ocapn.codec.syrup.decodeBodyForProfile(.next, late_settling.view());
    try std.testing.expectEqual(model.ListenMode.settling_only, late_settling_body.listen.mode);
    try std.testing.expectEqual(late_target, late_settling_body.listen.target.near.export_position.int());
}

test "proxyForeignPromise multi-introduce shares one home listen and materializes into each store" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(15)));
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient_a = try node.registerPeer(.{});
    const recipient_b = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, @as([crypto.SEED_BYTES]u8, @splat(23)));
    defer home_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const far_id = route.routed.id;

    const rewritten_a = (try node.proxyForeignPromiseFulfill(recipient_a, far_id)).?;
    const rewritten_b = (try node.proxyForeignPromiseFulfill(recipient_b, far_id)).?;
    const import_a = rewritten_a.near.export_position.int();
    const import_b = rewritten_b.near.export_position.int();

    // Exactly one home listen for both introduces.
    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    const listener = blk: {
        var frame = node.peer(home).?.takeOutbound().?;
        defer frame.deinit();
        const view = try glowcap.ocapn.codec.syrup.decodeBody(frame.view());
        try std.testing.expect(view == .listen);
        break :blk view.listen.listener.far.import_position.int();
    };
    try std.testing.expectEqual(engine.StepOutcome.idle, try node.peer(home).?.step());

    const payload = try allocator.dupe(u8, "shared");
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, listener, .{ .fulfill = .{ .bytes = payload } }));

    try std.testing.expectEqualStrings(
        "shared",
        node.peer(recipient_a).?.session_state.importedPromiseResolution(.from(import_a)).?.fulfill.bytes,
    );
    try std.testing.expectEqualStrings(
        "shared",
        node.peer(recipient_b).?.session_state.importedPromiseResolution(.from(import_b)).?.fulfill.bytes,
    );
}

test "raw send-argument routability distinguishes a route's home" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(3)));
    defer node.deinit();

    const here = try node.registerPeer(.{});
    const elsewhere = try node.registerPeer(.{});

    // Raw/model Host verbs ask this one Node verdict because they have no
    // application retain to transfer into delayed inline handoff (ADR-0116).
    try node.peer(elsewhere).?.session_state.registerImport(.from(8));
    const import = try node.enrollForeign(elsewhere, .{ .far = model.FarRef.object(8) });
    // Foreign when sent from `here` (it lives on `elsewhere`)…
    try std.testing.expect(node.argIsForeign(here, import));
    // …native when sent from its own home.
    try std.testing.expect(!node.argIsForeign(elsewhere, import));

    // An ordinary wire far rides its own connection: not foreign, regardless
    // of its numeric position.
    const unknown: model.Reference = .{ .far = model.FarRef.object(9) };
    try std.testing.expect(!node.argIsForeign(here, unknown));

    // A redeemed route is foreign from any connection of the node, its home
    // included: it has no wire home, so it can only be re-routed as a send target,
    // never marshalled as an argument.
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(elsewhere).?, @as([crypto.SEED_BYTES]u8, @splat(17)));
    defer counterpart.deinit();
    const route_id = try mintRedeemedRoute(&node, here, elsewhere, 81, 1, "ocapn://127.0.0.1%3A9056.tcp");
    const route: model.Reference = .{ .routed = .{ .id = route_id } };
    try std.testing.expect(node.argIsForeign(here, route));
    try std.testing.expect(node.argIsForeign(elsewhere, route));
}

fn runNestedForeignArguments(codec_id: model.CodecId) !void {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x2d)));
    defer node.deinit();

    const recipient_id = try node.registerPeer(.{ .captp_version = .next, .codec = codec_id });
    const exporter_id = try node.registerPeer(.{ .captp_version = .next, .codec = codec_id });
    const recipient = node.peer(recipient_id).?;
    const exporter = node.peer(exporter_id).?;
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        recipient,
        @as([crypto.SEED_BYTES]u8, @splat(0x2e)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        exporter,
        @as([crypto.SEED_BYTES]u8, @splat(0x2f)),
    );
    defer exporter_counterpart.deinit();

    try recipient.session_state.registerImport(.from(2));
    try exporter.session_state.registerImport(.from(4));
    const foreign = try node.enrollForeign(
        exporter_id,
        .{ .far = model.FarRef.object(4) },
    );
    const list = [_]model.Argument{
        .{ .reference = foreign },
        .{ .@"struct" = &.{.{ .key = "nested", .value = .{ .reference = foreign } }} },
    };
    try recipient.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(2) },
        .args = &.{.{ .list = &list }},
    } });

    // No half-transaction is visible while even one entropy request remains.
    try std.testing.expectEqual(@as(usize, 2), node.pendingGiftEffects());
    try std.testing.expectEqual(engine.StepOutcome.idle, try recipient.step());
    try std.testing.expectEqual(engine.StepOutcome.idle, try exporter.step());
    const first = node.nextAction().?.need_gift_id.ticket;
    const second = node.nextAction().?.need_gift_id.ticket;
    const first_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0xa1));
    try node.provideGiftId(second, &first_id);
    try std.testing.expect(node.nextAction() == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try recipient.step());
    try std.testing.expectEqual(engine.StepOutcome.idle, try exporter.step());

    const second_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(0xa2));
    try node.provideGiftId(first, &second_id);
    try std.testing.expectEqual(@as(usize, 0), node.pendingGiftEffects());
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
    const nested = (try delivered.args.at(0)).list;
    try std.testing.expect((try nested.at(0)) == .handoff);
    try std.testing.expect((try (try nested.at(0)).handoff.project()) == .give);
    const structured = (try nested.at(1)).@"struct";
    try std.testing.expect((try (try structured.at(0)).value.handoff.project()) == .give);
    try std.testing.expect(recipient.takeOutbound() == null);

    try exporter.stepToIdle();
    var deposits: usize = 0;
    while (exporter.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        const body = try codec.dispatch.decodeBodyForProfile(
            exporter.session_state.codec,
            exporter.session_state.captp_version,
            frame.view(),
        );
        try std.testing.expect(body == .deliver);
        try std.testing.expectEqualStrings("deposit-gift", (try body.deliver.args.at(0)).symbol);
        deposits += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), deposits);
}

test "nested foreign arguments wait for every gift id then publish one transaction" {
    for ([_]model.CodecId{ .syrup, .capnp }) |codec_id|
        try runNestedForeignArguments(codec_id);
}
