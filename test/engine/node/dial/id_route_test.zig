//! Identity-layer route proof cases for the Node dial scheduler.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const crypto = pancake.foundation.crypto;

const Node = engine.Node;
const harness = @import("../harness.zig");
const openKeyedSessionWithCounterpart = harness.openKeyedSessionWithCounterpart;
const pendingWithdrawAnswer = harness.pendingWithdrawAnswer;
const testGiveBytes = harness.testGiveBytes;

fn routeOptions() engine.Peer.NegotiatingOptions {
    return .{
        .captp_version = .next,
        .features = model.FeatureSet.full(),
    };
}

test "id route bundles refuse carriers that cannot prove the canonical key" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x2f)));
    defer node.deinit();

    const recipient = try node.registerPeer(routeOptions());
    const key = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x30))).publicKey().toDesignator();
    const unsafe = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.keyed-relay",
        .{ key[0..], key[0..] },
    );
    defer allocator.free(unsafe);
    try std.testing.expectError(error.MalformedMessage, node.acceptGive(recipient, 34, "give-id", unsafe));
    try std.testing.expectEqual(@as(usize, 0), node.pendingDialCount());
    try std.testing.expect(node.nextAction() == null);

    try std.testing.expectError(error.UnsupportedId, node.stageDial(unsafe));
    try std.testing.expectEqual(@as(usize, 0), node.pendingDialCount());
    try std.testing.expect(node.nextAction() == null);
}

test "id route bundles race same-key proving carriers in order" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x31)));
    defer node.deinit();

    const key = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x32))).publicKey().toDesignator();
    const id_locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.iroh%7Cocapn%3A%2F%2F{s}.noise-relay",
        .{ key[0..], key[0..], key[0..] },
    );
    defer allocator.free(id_locator);

    const staged = try node.stageDial(id_locator);
    const ticket = staged.pending;
    try std.testing.expectEqual(ticket, node.nextAction().?.dial.pending);
    const first = node.pendingDial(ticket, 0).?;
    try std.testing.expectEqualStrings(model.transport.iroh, first.locator.transport);
    try std.testing.expectEqualStrings(key[0..], first.locator.designator);

    try std.testing.expectEqual(engine.Node.DialFailure.waiting, try node.dialFailed(ticket, 0, "iroh unavailable"));
    const second_action = node.nextAction().?;
    try std.testing.expectEqual(ticket, second_action.dial.pending);
    try std.testing.expectEqual(@as(usize, 1), second_action.dial.route_index);
    const second = node.pendingDial(ticket, 1).?;
    try std.testing.expectEqualStrings(model.transport.noise_relay, second.locator.transport);
    try std.testing.expectEqualStrings(key[0..], second.locator.designator);

    const exporter = try node.registerPeer(.{});
    _ = try std.testing.expectError(error.PeerIdentityMismatch, node.exporterDialed(ticket, 1, exporter));
    try std.testing.expect(node.pendingDial(ticket, 1) != null);
    node.peer(exporter).?.bindVerifiedChannelKey(crypto.PeerKey.fromDesignator(&key).?);
    try std.testing.expect(try node.exporterDialed(ticket, 1, exporter));
    try std.testing.expect(node.pendingDial(ticket, 1) == null);
    try std.testing.expect(node.nextAction() == null);
}

test "id route rank fills a bounded strong window before serial weak fallback" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x33)));
    defer node.deinit();

    const recipient = try node.registerPeer(routeOptions());
    const key = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x34))).publicKey().toDesignator();
    const id_locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.iroh%7Cocapn%3A%2F%2F{s}.noise-relay%7Cocapn%3A%2F%2F{s}.noise-tcp&alt-locators=ocapn%3A%2F%2Ffallback-one.onion%7Cocapn%3A%2F%2F127.0.0.1%253A7010.tcp",
        .{ key[0..], key[0..], key[0..], key[0..] },
    );
    defer allocator.free(id_locator);
    const give = try testGiveBytes(allocator);
    defer allocator.free(give);

    try node.acceptGive(recipient, 40, give, id_locator);
    const first = node.nextAction().?.dial;
    const second = node.nextAction().?.dial;
    try std.testing.expectEqual(first.pending, second.pending);
    try std.testing.expectEqual(@as(usize, 0), first.route_index);
    try std.testing.expectEqual(@as(usize, 1), second.route_index);
    try std.testing.expect(node.nextAction() == null);

    try std.testing.expectEqual(
        engine.Node.DialFailure.retry,
        try node.dialFailed(first.pending, second.route_index, "relay unavailable"),
    );
    const third = node.nextAction().?.dial;
    try std.testing.expectEqual(@as(usize, 2), third.route_index);
    try std.testing.expectEqualStrings(
        model.transport.noise_tcp,
        node.pendingDial(first.pending, third.route_index).?.locator.transport,
    );
    try std.testing.expectEqual(
        engine.Node.DialFailure.waiting,
        try node.dialFailed(first.pending, first.route_index, "iroh unavailable"),
    );
    try std.testing.expect(node.nextAction() == null);

    try std.testing.expectEqual(
        engine.Node.DialFailure.retry,
        try node.dialFailed(first.pending, third.route_index, "noise tcp unavailable"),
    );
    const weak_one = node.nextAction().?.dial;
    try std.testing.expectEqual(@as(usize, 3), weak_one.route_index);
    try std.testing.expectEqualStrings(
        model.transport.onion,
        node.pendingDial(first.pending, weak_one.route_index).?.locator.transport,
    );
    try std.testing.expectEqual(
        engine.Node.DialFailure.retry,
        try node.dialFailed(first.pending, weak_one.route_index, "onion unavailable"),
    );
    const weak_two = node.nextAction().?.dial;
    try std.testing.expectEqual(@as(usize, 4), weak_two.route_index);
    try std.testing.expect(node.nextAction() == null);
    try std.testing.expectEqual(
        engine.Node.DialFailure.exhausted,
        try node.dialFailed(first.pending, weak_two.route_index, "tcp unavailable"),
    );
    try std.testing.expect(node.nextAction().? == .fail);
    try std.testing.expect(node.nextAction() == null);
}

test "first completed admitted id route wins and late losers are stale" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x35)));
    defer node.deinit();

    const key = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x36))).publicKey().toDesignator();
    const id_locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.iroh%7Cocapn%3A%2F%2F{s}.noise-relay",
        .{ key[0..], key[0..], key[0..] },
    );
    defer allocator.free(id_locator);

    const staged = try node.stageDial(id_locator);
    const first = node.nextAction().?.dial;
    const second = node.nextAction().?.dial;
    try std.testing.expectEqual(staged.pending, first.pending);
    try std.testing.expectEqual(first.pending, second.pending);

    const winner = try node.registerPeer(.{});
    node.peer(winner).?.bindVerifiedChannelKey(crypto.PeerKey.fromDesignator(&key).?);
    try std.testing.expect(try node.exporterDialed(second.pending, second.route_index, winner));
    const cancel = node.nextAction().?.cancel_dial;
    try std.testing.expectEqual(first.pending, cancel.pending);
    try std.testing.expectEqual(first.route_index, cancel.route_index);

    const late = try node.registerPeer(.{});
    node.peer(late).?.bindVerifiedChannelKey(crypto.PeerKey.fromDesignator(&key).?);
    try std.testing.expect(!try node.exporterDialed(first.pending, first.route_index, late));
    try std.testing.expectEqual(
        engine.Node.DialFailure.stale,
        try node.dialFailed(first.pending, first.route_index, "late failure"),
    );
    node.dialCancelled(cancel.pending, cancel.route_index);
    try std.testing.expectEqual(@as(usize, 0), node.pendingDialCount());
    try std.testing.expect(node.nextAction() == null);
}

test "id route weak fallbacks redeem without claiming the outer identity" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x36)));
    defer node.deinit();

    const recipient = try node.registerPeer(routeOptions());
    const key = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x37))).publicKey().toDesignator();
    const id_locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.iroh&alt-locators=ocapn%3A%2F%2Fbaseline-service.onion",
        .{ key[0..], key[0..] },
    );
    defer allocator.free(id_locator);

    try node.acceptGive(recipient, 35, "give-id", id_locator);
    const ticket = node.nextAction().?.dial.pending;
    const strong = node.pendingDial(ticket, 0).?;
    try std.testing.expectEqualStrings(model.transport.iroh, strong.locator.transport);
    try std.testing.expect(strong.authenticated_partner_required);
    try std.testing.expect(strong.demanded_partner_key != null);

    try std.testing.expectEqual(engine.Node.DialFailure.retry, try node.dialFailed(ticket, 0, "iroh unavailable"));
    try std.testing.expectEqual(ticket, node.nextAction().?.dial.pending);
    const weak = node.pendingDial(ticket, 1).?;
    try std.testing.expectEqualStrings(model.transport.onion, weak.locator.transport);
    try std.testing.expectEqualStrings("baseline-service", weak.locator.designator);
    try std.testing.expect(!weak.authenticated_partner_required);
    try std.testing.expect(weak.demanded_partner_key == null);

    const exporter = try node.registerPeer(.{});
    try std.testing.expect(try node.exporterDialed(ticket, 1, exporter));
    try std.testing.expectEqual(@as(usize, 0), node.redeems.dials.exporters.count());
    try std.testing.expectEqual(@as(usize, 0), node.gifts.recipe.by_exporter.count());
}

test "verified id completion keeps one discovered route under explicit policy" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x38)));
    defer node.deinit();

    const recipient = try node.registerPeer(routeOptions());
    const exporter = try node.registerPeer(.{});
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(recipient).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x3e)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(exporter).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x3f)),
    );
    defer exporter_counterpart.deinit();
    const key = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x39))).publicKey().toDesignator();
    const id_locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.iroh%7Cocapn%3A%2F%2F{s}.noise-relay&alt-locators=ocapn%3A%2F%2Fbaseline-service.onion",
        .{ key[0..], key[0..], key[0..] },
    );
    defer allocator.free(id_locator);
    const parsed = try model.uri.parsePeer(allocator, id_locator);
    defer model.freePeerLocator(allocator, parsed);
    const canonical = try engine.encodePeerLocatorRecord(allocator, parsed);
    defer allocator.free(canonical);

    const give = try testGiveBytes(allocator);
    defer allocator.free(give);
    try node.acceptGive(recipient, 36, give, id_locator);
    const ticket = node.nextAction().?.dial.pending;
    const second = node.nextAction().?.dial;
    try std.testing.expectEqual(ticket, second.pending);
    try std.testing.expectEqual(@as(usize, 1), second.route_index);
    node.peer(exporter).?.bindVerifiedChannelKey(crypto.PeerKey.fromDesignator(&key).?);
    try std.testing.expect(try node.exporterCompleted(ticket, 1, exporter, .dialed));
    try std.testing.expect(node.gifts.recipe.by_exporter.get(exporter) == null);
    const withdraw_answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, withdraw_answer, .{ .far = 9 }));
    const discovered = node.gifts.recipe.by_exporter.get(exporter).?.discovered.?;
    try std.testing.expectEqualSlices(u8, canonical, discovered);

    const explicit = try model.uri.parsePeer(allocator, "ocapn://127.0.0.1%3A7001.tcp");
    defer model.freePeerLocator(allocator, explicit);
    try node.setExporterLocation(exporter, explicit);
    const with_explicit = node.gifts.recipe.by_exporter.get(exporter).?;
    try std.testing.expect(with_explicit.explicit != null);
    try std.testing.expectEqualSlices(u8, canonical, with_explicit.discovered.?);

    try node.setExporterLocation(exporter, null);
    const restored = node.gifts.recipe.by_exporter.get(exporter).?;
    try std.testing.expect(restored.explicit == null);
    try std.testing.expectEqualSlices(u8, canonical, restored.discovered.?);

    const later = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.noise-tcp&alt-locators=ocapn%3A%2F%2Flater-service.onion",
        .{ key[0..], key[0..] },
    );
    defer allocator.free(later);
    try node.acceptGive(recipient, 37, "later-give", later);
    try std.testing.expectEqualSlices(
        u8,
        canonical,
        node.gifts.recipe.by_exporter.get(exporter).?.discovered.?,
    );
}

test "weak id completion retains route advice only after withdrawal without caching identity" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x3a)));
    defer node.deinit();

    const recipient = try node.registerPeer(routeOptions());
    const exporter = try node.registerPeer(.{});
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(recipient).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x40)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(exporter).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x41)),
    );
    defer exporter_counterpart.deinit();
    const key = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x3b))).publicKey().toDesignator();
    const id_locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.iroh&alt-locators=ocapn%3A%2F%2Fbaseline-service.onion",
        .{ key[0..], key[0..] },
    );
    defer allocator.free(id_locator);
    const parsed = try model.uri.parsePeer(allocator, id_locator);
    defer model.freePeerLocator(allocator, parsed);
    const canonical = try engine.encodePeerLocatorRecord(allocator, parsed);
    defer allocator.free(canonical);
    const give = try testGiveBytes(allocator);
    defer allocator.free(give);

    try node.acceptGive(recipient, 38, give, id_locator);
    const ticket = node.nextAction().?.dial.pending;
    try std.testing.expectEqual(engine.Node.DialFailure.retry, try node.dialFailed(ticket, 0, "iroh unavailable"));
    try std.testing.expectEqual(ticket, node.nextAction().?.dial.pending);
    try std.testing.expect(try node.exporterCompleted(ticket, 1, exporter, .dialed));
    try std.testing.expectEqual(@as(usize, 0), node.redeems.dials.exporters.count());
    try std.testing.expectEqual(@as(usize, 0), node.gifts.recipe.by_exporter.count());

    const withdraw_answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, withdraw_answer, .{ .far = 9 }));
    try std.testing.expectEqual(@as(usize, 0), node.redeems.dials.exporters.count());
    const discovered = node.gifts.recipe.by_exporter.get(exporter).?.discovered.?;
    try std.testing.expectEqualSlices(u8, canonical, discovered);
}

test "broken id withdrawal cannot publish route advice" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x3c)));
    defer node.deinit();

    const recipient = try node.registerPeer(routeOptions());
    const exporter = try node.registerPeer(.{});
    var recipient_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(recipient).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x42)),
    );
    defer recipient_counterpart.deinit();
    var exporter_counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(exporter).?,
        @as([crypto.SEED_BYTES]u8, @splat(0x43)),
    );
    defer exporter_counterpart.deinit();
    const key = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x3d))).publicKey().toDesignator();
    const id_locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.iroh",
        .{ key[0..], key[0..] },
    );
    defer allocator.free(id_locator);
    const give = try testGiveBytes(allocator);
    defer allocator.free(give);

    try node.acceptGive(recipient, 39, give, id_locator);
    const ticket = node.nextAction().?.dial.pending;
    node.peer(exporter).?.bindVerifiedChannelKey(crypto.PeerKey.fromDesignator(&key).?);
    _ = try node.exporterCompleted(ticket, 0, exporter, .dialed);
    const withdraw_answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, withdraw_answer, .{ .broken = "invalid handoff signature" }));
    try std.testing.expectEqual(@as(usize, 0), node.gifts.recipe.by_exporter.count());
}

test "exporter completion refuses an unknown peer without consuming the pending dial" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x44)));
    defer node.deinit();

    const staged = try node.stageDial("ocapn://127.0.0.1%3A9044.tcp");
    const ticket = staged.pending;
    _ = node.nextAction().?;
    _ = try std.testing.expectError(error.UnknownConnection, node.exporterDialed(ticket, 0, .from(999)));
    const pending = node.pendingDial(ticket, 0).?;
    try std.testing.expectEqualStrings(model.transport.tcp, pending.locator.transport);
    try std.testing.expectEqualStrings("127.0.0.1:9044", pending.locator.designator);
    try std.testing.expectEqual(@as(usize, 0), node.redeems.dials.exporters.count());
}

test "id route bundles refuse routes that prove a different key" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x33)));
    defer node.deinit();

    const id_key = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x34))).publicKey().toDesignator();
    const route_key = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x35))).publicKey().toDesignator();
    const id_locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.iroh",
        .{ id_key[0..], route_key[0..] },
    );
    defer allocator.free(id_locator);

    try std.testing.expectError(error.UnsupportedId, node.stageDial(id_locator));
    try std.testing.expectEqual(@as(usize, 0), node.pendingDialCount());
    try std.testing.expect(node.nextAction() == null);
}
