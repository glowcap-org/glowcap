//! Relayed resolutions that carry capabilities: each recipient gets its own
//! give, one recipient can break without rolling back a sibling, a home
//! promise is not introduced to unboundedly many third parties, and a
//! relayed promise installs a successor proxy instead of breaking.

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

test "a relayed resolution carrying a capability is introduced by handoff, not broken" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(31)));
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, @as([crypto.SEED_BYTES]u8, @splat(37)));
    defer home_counterpart.deinit();
    // The recipient must be a keyed open session too: a give is addressed to
    // the recipient's session key and signed under the gifter-to-exporter one.
    var recipient_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(recipient).?, @as([crypto.SEED_BYTES]u8, @splat(39)));
    defer recipient_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, route.routed.id)).?;
    const import_pos = rewritten.near.export_position.int();
    // Arming the proxy queues the home session's flush: the `op:listen` it
    // enqueued rides a session no verb here is driving. This test steps that
    // peer by hand below, so the notice is drained rather than acted on.
    try std.testing.expectEqual(home, node.nextAction().?.flush);

    // The recipient listens on the promise it was introduced to, the way a
    // real partner does: sender `.far` becomes a wire `<desc:export>`, which
    // this side receives as `.near`. Without this there is no fire to carry
    // the give, and storing it would prove nothing a partner could observe.
    try node.peer(recipient).?.session_state.exports.retain(allocator, .from(import_pos));
    try recipient_counterpart.session_state.registerImport(.from(import_pos));
    try recipient_counterpart.session_state.registerExport(.from(9));
    try recipient_counterpart.sendCopying(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(import_pos) },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .mode = .settling_only,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try recipient_counterpart.step());
    try node.peer(recipient).?.feedOwned(recipient_counterpart.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(recipient).?.step());
    {
        var listen_event = node.peer(recipient).?.pollEvent().?;
        listen_event.deinit();
    }

    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    const listener = blk: {
        var frame = node.peer(home).?.takeOutbound().?;
        defer frame.deinit();
        const view = try pancake.ocapn.codec.syrup.decodeBody(frame.view());
        break :blk view.listen.listener.far.import_position.int();
    };

    // The home promise settles to a capability rather than to bytes. The
    // number means something only in the home conversation, so it cannot be
    // stored on the recipient as it stands. The protocol's answer is to
    // introduce it: the node asks for gift-id entropy rather than settling.
    const gifted: u64 = 9;
    try node.peer(home).?.session_state.registerImport(.from(gifted));
    const gifted_route = try node.enrollForeign(home, .{ .far = model.FarRef.object(gifted) });
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, listener, .{
        .fulfill = .{ .reference = gifted_route },
    }));
    try std.testing.expect(node.peer(recipient).?.session_state.importedPromiseResolution(.from(import_pos)) == null);

    const ask = node.nextAction().?;
    const gift_id = @as([32]u8, @splat(0xC3));
    try node.provideGiftId(ask.need_gift_id.ticket, &gift_id);

    // The recipient's promise now settles with a signed give it can redeem by
    // dialing the exporter, which is the reachable outcome a break was not.
    const settled = node.peer(recipient).?.session_state.importedPromiseResolution(.from(import_pos)).?;
    try std.testing.expect(settled.* == .fulfill);
    try std.testing.expect(settled.fulfill == .handoff);
    try std.testing.expect(settled.fulfill.handoff.* == .give);

    // Storing it is not the claim that matters — reaching the recipient is.
    // Drain the fire the listener installed above and read the give back off
    // the wire, which is the only evidence a real partner would ever see.
    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(recipient).?.step());
    var fired = false;
    while (node.peer(recipient).?.takeOutbound()) |frame_const| {
        var frame = frame_const;
        defer frame.deinit();
        const view = try pancake.ocapn.codec.syrup.decodeBody(frame.view());
        if (view != .deliver) continue;
        if (try view.deliver.args.len() != 2) continue;
        const tag = try view.deliver.args.at(0);
        if (tag != .symbol or !std.mem.eql(u8, tag.symbol, "fulfill")) continue;
        const payload = try view.deliver.args.at(1);
        try std.testing.expect(payload == .handoff);
        try std.testing.expect(payload.handoff == .give);
        try std.testing.expectEqualStrings(&gift_id, payload.handoff.give.gift_id);
        fired = true;
    }
    try std.testing.expect(fired);

    // And the exporter side of the handoff is real: the deposit naming the
    // gifted capability is on the home wire under the same gift id.
    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    var deposited = false;
    while (node.peer(home).?.takeOutbound()) |frame_const| {
        var frame = frame_const;
        defer frame.deinit();
        const view = try pancake.ocapn.codec.syrup.decodeBody(frame.view());
        // A deposit is a bootstrap deliver, not an `op:handoff`: the gifter
        // asks the exporter's bootstrap object to hold the capability under
        // the gift id, and the exporter answers a later `withdraw-gift`.
        if (view != .deliver) continue;
        if (try view.deliver.args.len() != 3) continue;
        const verb = try view.deliver.args.at(0);
        if (verb != .symbol or !std.mem.eql(u8, verb.symbol, "deposit-gift")) continue;
        try std.testing.expectEqualStrings(&gift_id, (try view.deliver.args.at(1)).bytes);
        // Named as the *exporter* knows it: our import of position 9 is the
        // exporter's own export, so it goes out as a near. A far here would
        // ask the exporter to deposit something from our side of the wire.
        const named = (try view.deliver.args.at(2)).reference;
        try std.testing.expectEqual(gifted, named.near.export_position.int());
        deposited = true;
    }
    try std.testing.expect(deposited);

    // And the home session is untouched. It fulfilled a promise, which the
    // protocol permits; tearing it down would punish it for our limit.
    try std.testing.expect(node.peer(home).?.sessionIsOpen());
}

test "two recipients of one relayed capability each get their own give" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(47)));
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const first = try node.registerPeer(.{});
    const second = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, @as([crypto.SEED_BYTES]u8, @splat(49)));
    defer home_counterpart.deinit();
    var first_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(first).?, @as([crypto.SEED_BYTES]u8, @splat(51)));
    defer first_counterpart.deinit();
    var second_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(second).?, @as([crypto.SEED_BYTES]u8, @splat(53)));
    defer second_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const far_id = route.routed.id;

    // One home promise, introduced to two different recipients: the node keeps
    // a single home `op:listen` and one proxy row with two recipient slots.
    const first_slot = (try node.proxyForeignPromiseFulfill(first, far_id)).?.near.export_position.int();
    const second_slot = (try node.proxyForeignPromiseFulfill(second, far_id)).?.near.export_position.int();

    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    const listener = blk: {
        var frame = node.peer(home).?.takeOutbound().?;
        defer frame.deinit();
        const view = try pancake.ocapn.codec.syrup.decodeBody(frame.view());
        break :blk view.listen.listener.far.import_position.int();
    };

    const gifted: u64 = 9;
    try node.peer(home).?.session_state.registerImport(.from(gifted));
    const gifted_route = try node.enrollForeign(home, .{ .far = model.FarRef.object(gifted) });
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, listener, .{
        .fulfill = .{ .reference = gifted_route },
    }));

    // A give is addressed to one recipient's session key and redeemed once, so
    // two recipients need two gift ids and two deposits. Sharing one id would
    // let either recipient consume the other's gift.
    var ids_asked: usize = 0;
    var next_id: u8 = 0x10;
    while (node.nextAction()) |action| {
        if (action != .need_gift_id) continue;
        const gift_id = @as([32]u8, @splat(next_id));
        next_id += 1;
        ids_asked += 1;
        try node.provideGiftId(action.need_gift_id.ticket, &gift_id);
    }
    try std.testing.expectEqual(@as(usize, 2), ids_asked);

    for ([_]struct { peer: engine.PeerHandle, slot: u64 }{
        .{ .peer = first, .slot = first_slot },
        .{ .peer = second, .slot = second_slot },
    }) |r| {
        const settled = node.peer(r.peer).?.session_state.importedPromiseResolution(.from(r.slot)).?;
        try std.testing.expect(settled.* == .fulfill);
        try std.testing.expect(settled.fulfill == .handoff);
        try std.testing.expect(settled.fulfill.handoff.* == .give);
    }

    // The two gives name different gift ids, so neither recipient can withdraw
    // the other's.
    const a = node.peer(first).?.session_state.importedPromiseResolution(.from(first_slot)).?.fulfill.handoff.give;
    const b = node.peer(second).?.session_state.importedPromiseResolution(.from(second_slot)).?.fulfill.handoff.give;
    try std.testing.expect(!std.mem.eql(u8, a.gift_id, b.gift_id));
}

test "one relayed recipient can break under pressure without rolling back its sibling" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x91)));
    defer node.deinit();

    const home = try node.registerPeer(.{});
    var tight_limits = engine.SessionLimits{};
    tight_limits.queue_cap = 1;
    const tight = try node.registerPeer(.{ .limits = tight_limits });
    const roomy = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(home).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x92)),
    );
    defer home_counterpart.deinit();
    var tight_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(tight).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x93)),
    );
    defer tight_counterpart.deinit();
    var roomy_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(roomy).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x94)),
    );
    defer roomy_counterpart.deinit();

    try node.peer(home).?.session_state.registerImport(.from(4));
    const source = try node.enrollForeign(home, .{ .far = model.FarRef.promise(4) });
    const tight_projection = (try node.proxyForeignPromiseFulfill(
        tight,
        source.routed.id,
    )).?;
    const roomy_projection = (try node.proxyForeignPromiseFulfill(
        roomy,
        source.routed.id,
    )).?;
    try node.peer(home).?.stepToIdle();
    var listen_frame = node.peer(home).?.takeOutbound().?;
    defer listen_frame.deinit();
    const listener = (try pancake.ocapn.codec.syrup.decodeBody(listen_frame.view()))
        .listen.listener.far.import_position.int();

    try node.peer(home).?.session_state.registerImport(.from(9));
    const object = try node.enrollForeign(home, .{ .far = model.FarRef.object(9) });
    const repeated = try allocator.alloc(model.Argument, 2);
    repeated[0] = .{ .reference = object };
    repeated[1] = .{ .reference = object };
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, listener, .{
        .fulfill = .{ .list = repeated },
    }));

    const tight_settlement = node.peer(tight).?.session_state.importedPromiseResolution(
        .from(tight_projection.near.export_position.int()),
    ).?;
    try std.testing.expect(tight_settlement.* == .@"break");

    var requested: usize = 0;
    while (node.nextAction()) |action| switch (action) {
        .need_gift_id => |request| {
            const gift_id = @as([model.HANDOFF_GIFT_ID_BYTES]u8, @splat(@intCast(0xa0 + requested)));
            requested += 1;
            try node.provideGiftId(request.ticket, &gift_id);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), requested);
    const roomy_settlement = node.peer(roomy).?.session_state.importedPromiseResolution(
        .from(roomy_projection.near.export_position.int()),
    ).?;
    try std.testing.expect(roomy_settlement.* == .fulfill);
    try std.testing.expectEqual(@as(usize, 2), roomy_settlement.fulfill.list.len);
    for (roomy_settlement.fulfill.list) |value| {
        try std.testing.expect(value == .handoff);
        try std.testing.expect(value.handoff.* == .give);
    }
}

test "one home promise will not be introduced to unboundedly many third parties" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(63)));
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, @as([crypto.SEED_BYTES]u8, @splat(65)));
    defer home_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const far_id = route.routed.id;

    // The recipient drives the count: it asks repeatedly and the application
    // answers each time with the same foreign promise. The home session is the
    // one that would pay — a signature and a deposit per recipient when the
    // promise settles — so the fan-out is refused here, at introduce time,
    // where the caller asking for it can still see the refusal.
    var introduced: usize = 0;
    while (introduced < Node.max_proxy_recipients) : (introduced += 1) {
        _ = try node.proxyForeignPromiseFulfill(recipient, far_id);
    }
    try std.testing.expectError(
        error.ProxyRecipientCapExceeded,
        node.proxyForeignPromiseFulfill(recipient, far_id),
    );

    // Refusing leaves the home session usable: it is not the party at fault.
    try std.testing.expect(node.peer(home).?.sessionIsOpen());
}

test "a relayed promise installs a successor proxy instead of breaking" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(57)));
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, @as([crypto.SEED_BYTES]u8, @splat(59)));
    defer home_counterpart.deinit();
    var recipient_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(recipient).?, @as([crypto.SEED_BYTES]u8, @splat(61)));
    defer recipient_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, route.routed.id)).?;
    const import_pos = rewritten.near.export_position.int();
    // Arming the proxy queues the home session's flush: the `op:listen` it
    // enqueued rides a session no verb here is driving. This test steps that
    // peer by hand below, so the notice is drained rather than acted on.
    try std.testing.expectEqual(home, node.nextAction().?.flush);

    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    const listener = blk: {
        var frame = node.peer(home).?.takeOutbound().?;
        defer frame.deinit();
        const view = try pancake.ocapn.codec.syrup.decodeBody(frame.view());
        break :blk view.listen.listener.far.import_position.int();
    };

    // The home promise settles to another promise. Node identity preserves
    // that fact as a route, and the shared Passable staging transaction mints
    // a successor recipient promise plus one home settlement listener.
    const chained: u64 = 11;
    try node.peer(home).?.session_state.registerImport(.from(chained));
    const chained_route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(chained) });
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, listener, .{
        .fulfill = .{ .reference = chained_route },
    }));

    const settled = node.peer(recipient).?.session_state.importedPromiseResolution(.from(import_pos)).?;
    try std.testing.expect(settled.* == .fulfill);
    try std.testing.expect(settled.fulfill == .reference);
    try std.testing.expect(settled.fulfill.reference == .near);
    try std.testing.expectEqual(.promise, settled.fulfill.reference.near.kind);
    var saw_home_flush = false;
    var saw_recipient_flush = false;
    while (node.nextAction()) |action| if (action == .flush) {
        saw_home_flush = saw_home_flush or action.flush == home;
        saw_recipient_flush = saw_recipient_flush or action.flush == recipient;
    };
    try std.testing.expect(saw_home_flush);
    try std.testing.expect(saw_recipient_flush);
    try std.testing.expect(node.peer(home).?.sessionIsOpen());
}

test "a relayed resolution carrying a sturdyref relays, because a sturdyref means the same everywhere" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(41)));
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, @as([crypto.SEED_BYTES]u8, @splat(43)));
    defer home_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, route.routed.id)).?;
    const import_pos = rewritten.near.export_position.int();
    // Arming the proxy queues the home session's flush: the `op:listen` it
    // enqueued rides a session no verb here is driving. This test steps that
    // peer by hand below, so the notice is drained rather than acted on.
    try std.testing.expectEqual(home, node.nextAction().?.flush);

    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    const listener = blk: {
        var frame = node.peer(home).?.takeOutbound().?;
        defer frame.deinit();
        const view = try pancake.ocapn.codec.syrup.decodeBody(frame.view());
        break :blk view.listen.listener.far.import_position.int();
    };

    // A sturdyref names a peer and a swissnum, not a slot in the home
    // conversation, so the recipient can use it as it stands. Refusing it
    // would refuse the ordinary way to hand a durable capability to a third
    // party without a handoff.
    const sturdy = try allocator.create(model.SturdyRef);
    sturdy.* = .{
        .peer = .{
            .transport = try allocator.dupe(u8, "tcp"),
            .designator = try allocator.dupe(u8, "127.0.0.1:9099"),
            .hints = model.Hints.emptyFalse(),
        },
        .swissnum = try allocator.dupe(u8, "durable-swiss"),
    };
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, listener, .{
        .fulfill = .{ .reference = .{ .sturdy = sturdy } },
    }));

    const settled = node.peer(recipient).?.session_state.importedPromiseResolution(.from(import_pos)).?;
    try std.testing.expect(settled.* == .fulfill);
    try std.testing.expectEqualStrings("durable-swiss", settled.fulfill.reference.sturdy.swissnum);
}

test "a relayed resolution carrying a routing route emits the wire import position, never the route" {
    // `Peer.applyRelayedResolution` is the one outbound path that bypasses
    // `send`'s lowering chokepoint, so it lowers the resolution itself before
    // storing it (ADR-0009/0069). A node-local routing route is meaningless
    // to a partner and is not even a legal wire position — it sits in the
    // explicit routed arm cannot be encoded — so what reaches the wire has to
    // be the real import position the route stands for. This drives that
    // path with a route-carrying fulfillment and reads the emitted frame.
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x2c)));
    defer node.deinit();

    // A raw-open fixture peer adopted by the node: an open session (so an
    // injected listen is accepted) that still carries node services, which is
    // what makes the lowering under test run at all.
    var relaying_storage = engine.testing.initRawOpenPeer(allocator);
    defer relaying_storage.deinit();
    const relaying_id = try node.registerPeerOver(&relaying_storage);
    const relaying = &relaying_storage;

    // This session imports a capability, and the node enrolls it under a
    // routing route — the id an application holds and could name.
    const wire_import: u64 = 7;
    try relaying.session_state.registerImport(.from(wire_import));
    const route = try node.enrollForeign(relaying_id, .{ .far = model.FarRef.object(wire_import) });
    try std.testing.expect(route == .routed);

    // The same session holds a third-party promise behind a proxy export, so
    // the partner can listen through the CapTP target role (`desc:export`).
    const relayed_export = try relaying.session_state.allocatePromiseExport();
    try relaying.session_state.exports.retain(allocator, relayed_export);
    const relayed_position = model.ImportPosition.from(relayed_export.int());
    try relaying.session_state.installThirdPartyImport(relayed_position, "exporter");
    var partner = engine.testing.initRawOpenPeer(allocator);
    defer partner.deinit();
    try partner.session_state.registerImport(.from(relayed_export.int()));
    try partner.session_state.registerExport(.from(9));
    try partner.sendCopying(.{ .listen = .{
        .target = .{ .far = model.FarRef.promise(relayed_export.int()) },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .mode = .settling_only,
    } });
    _ = try partner.step();
    try relaying.feedOwned(partner.takeOutbound().?);
    _ = try relaying.step();
    while (relaying.pollEvent()) |ev| {
        var e = ev;
        e.deinit();
    }
    while (relaying.takeOutbound()) |f| {
        var frame_out = f;
        frame_out.deinit();
    }

    // Relay a fulfillment naming the capability by its *route*.
    const row_id = relaying.session_state.importedPromiseRowId(relayed_position) orelse 0;
    try relaying.applyRelayedResolution(relayed_position, row_id, .{
        .fulfill = .{ .reference = route },
    });
    _ = try relaying.step();

    // The emitted fire names the wire import the routed capability stood for.
    var frame = relaying.takeOutbound() orelse return error.NoResolveEmitted;
    defer frame.deinit();
    const bytes = frame.bytes();

    var wire_digits: [24]u8 = undefined;
    const wire_text = try std.fmt.bufPrint(&wire_digits, "{d}", .{wire_import});
    try std.testing.expect(std.mem.indexOf(u8, bytes, wire_text) != null);
}
