//! Converging next-proxy subscriptions: recipient groups merge behind one
//! home listener, and mixed application/Node consumers share that listener
//! in either order.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const LiveBytesAllocator = @import("../../../support/alloc_metrics.zig").LiveBytesAllocator;

const Node = engine.Node;

const harness = @import("../harness.zig");
const projection_support = @import("../../../support/projection.zig");
const pendingWithdrawAnswer = harness.pendingWithdrawAnswer;
const peerUri = harness.peerUri;
const peerUriWithAlternatives = harness.peerUriWithAlternatives;
const takeWithdrawCount = harness.takeWithdrawCount;
const testGiveBytes = harness.testGiveBytes;
const mintRedeemedRoute = harness.mintRedeemedRoute;
const openKeyedSessionWithCounterpart = harness.openKeyedSessionWithCounterpart;

test "converging next proxy subscriptions merge recipient groups behind one listener" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.seed_bytes]u8, @splat(0x44)));
    defer node.deinit();

    const home = try node.registerPeer(.{ .captp_version = .next });
    const recipient_a = try node.registerPeer(.{});
    const recipient_b = try node.registerPeer(.{});
    const recipient_c = try node.registerPeer(.{});
    const recipient_d = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(home).?,
        @as([crypto.seed_bytes]u8, @splat(0x45)),
    );
    defer counterpart.deinit();
    const home_peer = node.peer(home).?;

    const source: u64 = 4;
    const target: u64 = 6;
    try home_peer.session_state.registerImport(.from(source));
    const source_shortening = home_peer.session_state.exports.nextPosition();
    try engine.listen.ensureShorteningListener(home_peer, .from(source));
    const source_route = try node.enrollForeign(home, model.FarRef.promise(source));
    const source_ref = (try node.proxyForeignPromiseFulfill(recipient_a, source_route.routed.id)).?;
    // Hold the projection as the partner would once its message is sent.
    node.peer(recipient_a).?.session_state.exports.retain(.from(source_ref.near.export_position.int()));

    try home_peer.session_state.registerImport(.from(target));
    try engine.listen.ensureShorteningListener(home_peer, .from(target));
    const target_route = try node.enrollForeign(home, model.FarRef.promise(target));
    const target_ref = (try node.proxyForeignPromiseFulfill(recipient_b, target_route.routed.id)).?;
    // Hold the projection as the partner would once its message is sent.
    node.peer(recipient_b).?.session_state.exports.retain(.from(target_ref.near.export_position.int()));

    while ((try home_peer.step()) != .idle) {}
    var source_shortening_frame = home_peer.takeOutbound().?;
    defer source_shortening_frame.deinit();
    var source_settling_frame = home_peer.takeOutbound().?;
    defer source_settling_frame.deinit();
    var target_shortening_frame = home_peer.takeOutbound().?;
    defer target_shortening_frame.deinit();
    var target_settling_frame = home_peer.takeOutbound().?;
    defer target_settling_frame.deinit();
    const target_settling = try glowcap.ocapn.codec.syrup.decodeBodyForProfile(.next, target_settling_frame.view());
    const target_listener = target_settling.listen.listener.far.import_position.int();
    try std.testing.expect(home_peer.takeOutbound() == null);

    const shortening_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(target) } },
    };
    var shortening = try glowcap.ocapn.codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(source_shortening.int()) },
        .args = &shortening_args,
    } });
    defer shortening.deinit();
    try home_peer.recvBorrowed(shortening.view());
    while ((try home_peer.step()) != .idle) {}
    try std.testing.expect(home_peer.takeOutbound() == null);

    // Both enrolled names remain usable after convergence. They join the
    // surviving target proxy through its current-wire index and must not arm a
    // second settling listener.
    const source_late = (try node.proxyForeignPromiseFulfill(
        recipient_c,
        source_route.routed.id,
    )).?;
    const target_late = (try node.proxyForeignPromiseFulfill(
        recipient_d,
        target_route.routed.id,
    )).?;
    // Hold the projection as the partner would once its message is sent.
    node.peer(recipient_c).?.session_state.exports.retain(.from(source_late.near.export_position.int()));
    // Hold the projection as the partner would once its message is sent.
    node.peer(recipient_d).?.session_state.exports.retain(.from(target_late.near.export_position.int()));
    while ((try home_peer.step()) != .idle) {}
    try std.testing.expect(home_peer.takeOutbound() == null);

    const payload = try allocator.dupe(u8, "shared settlement");
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, target_listener, .{
        .fulfill = .{ .bytes = payload },
    }));
    try std.testing.expectEqualStrings(
        "shared settlement",
        projection_support.resolution(&node.peer(recipient_a).?.session_state, .from(source_ref.near.export_position.int())).?.fulfill.bytes,
    );
    try std.testing.expectEqualStrings(
        "shared settlement",
        projection_support.resolution(&node.peer(recipient_b).?.session_state, .from(target_ref.near.export_position.int())).?.fulfill.bytes,
    );
    try std.testing.expectEqualStrings(
        "shared settlement",
        projection_support.resolution(&node.peer(recipient_c).?.session_state, .from(source_late.near.export_position.int())).?.fulfill.bytes,
    );
    try std.testing.expectEqualStrings(
        "shared settlement",
        projection_support.resolution(&node.peer(recipient_d).?.session_state, .from(target_late.near.export_position.int())).?.fulfill.bytes,
    );
}

fn runMixedSettlingConvergence(
    allocator: std.mem.Allocator,
    source_is_node: bool,
    release_application_before_settlement: bool,
) !void {
    var node = Node.init(allocator, @as([crypto.seed_bytes]u8, @splat(0x46)));
    defer node.deinit();

    const home = try node.registerPeer(.{ .captp_version = .next });
    const recipient = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(
        allocator,
        &node,
        node.peer(home).?,
        @as([crypto.seed_bytes]u8, @splat(0x47)),
    );
    defer counterpart.deinit();
    const home_peer = node.peer(home).?;
    const source: u64 = 4;
    const target: u64 = 6;
    try home_peer.session_state.registerImport(.from(source));
    const source_shortening = home_peer.session_state.exports.nextPosition();
    try engine.listen.ensureShorteningListener(home_peer, .from(source));
    try home_peer.session_state.registerImport(.from(target));
    try engine.listen.ensureShorteningListener(home_peer, .from(target));

    var application_answer: model.AnswerPosition = undefined;
    var recipient_import: u64 = undefined;
    if (source_is_node) {
        const source_route = try node.enrollForeign(home, model.FarRef.promise(source));
        const recipient_ref = (try node.proxyForeignPromiseFulfill(recipient, source_route.routed.id)).?;
        recipient_import = recipient_ref.near.export_position.int();
        // Hold the projection as the partner would once its message is sent.
        node.peer(recipient).?.session_state.exports.retain(.from(recipient_import));
        application_answer = (try engine.listen.listenOnFar(home_peer, .{ .far = model.FarRef.promise(target) })).position;
    } else {
        application_answer = (try engine.listen.listenOnFar(home_peer, .{ .far = model.FarRef.promise(source) })).position;
        const target_route = try node.enrollForeign(home, model.FarRef.promise(target));
        const recipient_ref = (try node.proxyForeignPromiseFulfill(recipient, target_route.routed.id)).?;
        recipient_import = recipient_ref.near.export_position.int();
        // Hold the projection as the partner would once its message is sent.
        node.peer(recipient).?.session_state.exports.retain(.from(recipient_import));
    }
    while ((try home_peer.step()) != .idle) {}
    while (home_peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    const shortening_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .reference = .{ .near = model.NearRef.promise(target) } },
    };
    var shortening = try glowcap.ocapn.codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(source_shortening.int()) },
        .args = &shortening_args,
    } });
    defer shortening.deinit();
    try home_peer.recvBorrowed(shortening.view());
    while ((try home_peer.step()) != .idle) {}
    try std.testing.expect(home_peer.takeOutbound() == null);

    const target_incarnation = home_peer.session_state.shorteningIncarnationForImport(.from(target)).?;
    const target_listener = home_peer.session_state.promiseSettlingListenerExport(target_incarnation).?.int();
    if (release_application_before_settlement) {
        try home_peer.session_state.releaseOutboundAnswer(application_answer);
        while ((try home_peer.step()) != .idle) {}
        try std.testing.expect(home_peer.takeOutbound() == null);
        try std.testing.expect(home_peer.session_state.outboundAnswer(application_answer) == null);
        try std.testing.expect(home_peer.session_state.resolverPurpose(.from(target_listener)).? == .node_settling);
    }
    const settlement_args = [_]model.Argument{
        .{ .symbol = "fulfill" },
        .{ .bytes = "mixed settlement" },
    };
    var settlement = try glowcap.ocapn.codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(target_listener) },
        .args = &settlement_args,
    } });
    defer settlement.deinit();
    try home_peer.recvBorrowed(settlement.view());
    var event = home_peer.pollEvent().?;
    defer event.deinit();

    const wire = event.wireView();
    const resolution = try engine.events.resolutionFromResolverCallback(wire.deliver.args);
    try std.testing.expect(try node.claimProjectedProxyListenerFire(allocator, home, target_listener, resolution));
    const semantic = event.view();
    if (release_application_before_settlement) {
        try std.testing.expect(semantic.* == .deliver);
        try std.testing.expectEqual(
            glowcap.ocapn.session.RetiredResolverState.complete,
            home_peer.session_state.retiredResolverState(.from(target_listener)).?,
        );
        try std.testing.expect(!home_peer.session_state.promiseSettlingListenerClaimed(target_incarnation));
    } else {
        try std.testing.expectEqual(application_answer, semantic.resolve.answer);
        try std.testing.expectEqual(@as(usize, 0), event.resolveAliases().len);
        try std.testing.expectEqual(
            glowcap.ocapn.session.AnswerStatus.fulfilled,
            home_peer.session_state.outboundAnswer(application_answer).?.status,
        );
    }
    try std.testing.expectEqualStrings(
        "mixed settlement",
        projection_support.resolution(&node.peer(recipient).?.session_state, .from(recipient_import)).?.fulfill.bytes,
    );
}

test "mixed next settling convergence serves application and Node consumers in either order" {
    try runMixedSettlingConvergence(std.testing.allocator, false, false);
    try runMixedSettlingConvergence(std.testing.allocator, true, false);
}

test "mixed next settling convergence leaves the Node consumer after application release" {
    try runMixedSettlingConvergence(std.testing.allocator, false, true);
    try runMixedSettlingConvergence(std.testing.allocator, true, true);
}
