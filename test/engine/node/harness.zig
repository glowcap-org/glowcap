//! Shared fixtures for the `engine.Node` routing-core suite (ADR-0066): the
//! keyed session pair every scenario opens, give bytes and redeemed routes to
//! mint, and the withdraw bookkeeping the exporter tests read back.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const LiveBytesAllocator = @import("../../support/alloc_metrics.zig").LiveBytesAllocator;

const Node = engine.Node;

/// The answer position the node assigned the one withdraw it has parked on
/// `exporter`. In production the exporter echoes this id on its resolve frame,
/// so a host reads it off the wire; a white-box test drives `claimResolve`
/// directly and recovers it from the node's single pending withdraw. Asserts
/// exactly one withdraw is parked, on `exporter`.
pub fn pendingWithdrawAnswer(node: *Node, exporter: engine.PeerHandle) u64 {
    std.testing.expectEqual(
        @as(usize, 1),
        node.redeems.withdrawals.rows.count(),
    ) catch unreachable;
    var it = node.redeems.withdrawals.rows.keyIterator();
    const key = it.next().?.*;
    std.testing.expectEqual(exporter, key.peer_handle) catch unreachable;
    return key.answer;
}

pub fn peerUri(allocator: std.mem.Allocator, designator: []const u8) ![]u8 {
    return model.uri.writePeer(allocator, .{
        .transport = model.transport.tcp,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    });
}

pub fn peerUriWithAlternatives(
    allocator: std.mem.Allocator,
    designator: []const u8,
    alternatives: []const u8,
) ![]u8 {
    var entries = [_]model.HintEntry{.{
        .name = model.transport.hint_alt_locators,
        .value = .{ .string = alternatives },
    }};
    return model.uri.writePeer(allocator, .{
        .transport = model.transport.tcp,
        .designator = designator,
        .hints = .{ .entries = &entries },
    });
}

pub fn takeWithdrawCount(peer: *engine.Peer) !u64 {
    try peer.stepToIdle();
    var frame = peer.takeOutbound() orelse return error.NoOutboundFrame;
    defer frame.deinit();
    const body = try codec.syrup.decodeBodyForProfile(peer.session_state.captp_version, frame.view());
    if (body != .deliver) return error.UnexpectedMessage;
    const handoff = (try body.deliver.args.at(1)).handoff;
    if (handoff != .receive) return error.UnexpectedMessage;
    return handoff.receive.handoff_count;
}

/// A structurally valid signed `desc:handoff-give`, for tests that exercise
/// `Node`'s withdraw bookkeeping rather than the give's own signature or
/// content — any two calls are interchangeable here. `Node.acceptGive` hands
/// its `give` bytes to `Peer.sendWithdrawGift`, which now decodes them into
/// typed fields (`decodeSignedHandoffGiveOwned`) so a Cap'n Proto session can
/// carry a binding-originated give too; an ASCII placeholder no longer parses
/// as Syrup, where this file used to get away with one. Caller owns the
/// returned bytes.
pub fn testGiveBytes(allocator: std.mem.Allocator) ![]u8 {
    const location = try engine.encodePeerLocatorRecord(allocator, .{
        .transport = "tcp",
        .designator = "127.0.0.1:9099",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(location);
    const secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x77)));
    return engine.handoff_gifter.buildSignedGive(
        allocator,
        secret,
        &(@as([32]u8, @splat(0x01))),
        location,
        &(@as([32]u8, @splat(0x02))),
        &(@as([32]u8, @splat(0x03))),
        &(@as([32]u8, @splat(0x04))),
    );
}

/// Mint a routable redeemed route through the public redeem flow: accept a
/// give on `recipient`, report `exporter` (whose keyed session is open) as the
/// dialed connection, and claim the withdraw's resolve with `far_id`. Returns
/// the settled Node route id.
pub fn mintRedeemedRoute(
    node: *Node,
    recipient: engine.PeerHandle,
    exporter: engine.PeerHandle,
    answer: u64,
    far_id: u64,
    locator: []const u8,
) !model.CapabilityRouteId {
    const give = try testGiveBytes(node.allocator);
    defer node.allocator.free(give);
    try node.acceptGive(recipient, answer, give, locator);
    const dial = node.nextAction().?;
    _ = try node.exporterDialed(dial.dial.pending, 0, exporter);
    _ = node.nextAction().?; // the withdraw flush
    const withdraw_answer = pendingWithdrawAnswer(node, exporter);
    if (!try node.claimResolve(exporter, withdraw_answer, .{ .far = far_id })) return error.NotClaimed;
    const settle = node.nextAction().?;
    if (settle.settle.dest.answer.answer.int() != answer) return error.WrongAnswerSettled;
    return settle.settle.route_id;
}

/// Open a keyed session between the node-owned peer `p` (signing with the
/// node's retained identity) and a fresh standalone counterpart, driving both
/// handshakes to quiescence in memory. Returns the counterpart; the caller
/// deinits it.
pub fn openKeyedSessionWithCounterpart(
    allocator: std.mem.Allocator,
    node: *Node,
    p: *engine.Peer,
    counterpart_seed: [crypto.SEED_BYTES]u8,
) !engine.Peer {
    var counterpart = engine.Peer.initNegotiatingWith(allocator, .{
        .captp_version = p.session_state.captp_version,
        .codec = p.session_state.codec,
        .features = p.session_state.features,
    });
    errdefer counterpart.deinit();

    const node_secret = node.secretKey();
    const partner_secret = crypto.SecretKey.fromSeed(counterpart_seed);

    const node_loc: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:1", .hints = model.Hints.emptyMap() };
    const partner_loc: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:2", .hints = model.Hints.emptyMap() };
    try p.sendKeyedStartSession(node_loc, node_secret);
    try counterpart.sendKeyedStartSession(partner_loc, partner_secret);
    if (try engine.pairing.shuttleUntilQuiescent(p, &counterpart) != .quiescent) {
        return error.HandshakeDidNotQuiesce;
    }
    while (p.pollEvent()) |ev| {
        var event = ev;
        event.deinit();
    }
    while (counterpart.pollEvent()) |ev| {
        var event = ev;
        event.deinit();
    }
    return counterpart;
}
