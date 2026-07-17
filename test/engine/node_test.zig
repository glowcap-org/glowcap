//! `engine.Node` routing-core test (ADR-0066).
//!
//! Hermetic, no-I/O: exercises the sans-io router's connection table, the
//! redeemed-token model, and foreign-home recording directly, without a socket.
//! The live three-party test that the same router drives a real Goblins handoff
//! is `zig build goblins-handoff`.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const crypto = pancake.foundation.crypto;

const Node = engine.Node;

test "ActionFifo preserves order across compaction and rewinds when drained" {
    const allocator = std.testing.allocator;
    var fifo = engine.ActionFifo(u64){};
    defer fifo.deinit(allocator);

    // Push well past the compaction threshold, interleaving pops so the head
    // crosses it with rows still queued: order must survive the forward copy.
    var pushed: u64 = 0;
    while (pushed < 40) : (pushed += 1) try fifo.push(allocator, pushed);
    var popped: u64 = 0;
    while (popped < 35) : (popped += 1) try std.testing.expectEqual(popped, fifo.pop().?);
    try fifo.push(allocator, 40);
    try std.testing.expectEqual(@as(usize, 6), fifo.unpopped().len);
    while (popped < 41) : (popped += 1) try std.testing.expectEqual(popped, fifo.pop().?);

    // Drained: the pop that finds nothing rewinds the list for capacity reuse.
    try std.testing.expectEqual(@as(?u64, null), fifo.pop());
    try std.testing.expectEqual(@as(usize, 0), fifo.unpopped().len);

    // The reserve/pushReserved pair holds the infallible-push contract.
    try fifo.reserve(allocator, 2);
    fifo.pushReserved(7);
    fifo.pushReserved(8);
    try std.testing.expectEqual(@as(u64, 7), fifo.pop().?);
    try std.testing.expectEqual(@as(u64, 8), fifo.pop().?);
}

test "registerPeerOver adopts a peer the embedder owns without freeing it" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{8} ** crypto.SEED_BYTES);

    // A peer the test owns and pins, standing in for the completion loop's
    // inline per-connection peer at its stable slot address.
    var adopted = engine.Peer.initNegotiating(allocator);
    defer adopted.deinit();

    const id = try node.registerPeerOver(&adopted);
    // The adopted peer is the one the node routes to, and it now shares the
    // node's gift registry — the whole point of joining the node.
    try std.testing.expectEqual(&adopted, node.peer(id).?);
    try std.testing.expectEqual(&node.gifts, adopted.giftRegistry());

    // removePeer unregisters the slot but must not free the borrowed peer: the
    // test's own `defer adopted.deinit()` is the single free. std.testing's
    // allocator would flag a double-free or use-after-free here.
    node.removePeer(id);
    try std.testing.expect(node.peer(id) == null);

    // A second adopted registration outlives node.deinit for the same reason:
    // the node frees only what it owns.
    var adopted2 = engine.Peer.initNegotiating(allocator);
    defer adopted2.deinit();
    _ = try node.registerPeerOver(&adopted2);
    node.deinit();
}

test "registerPeer yields stable, non-reused ids and node-owned peers" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{7} ** crypto.SEED_BYTES);
    defer node.deinit();

    const a = try node.registerPeer(.{});
    const b = try node.registerPeer(.{});
    try std.testing.expect(a != b);
    try std.testing.expect(node.peer(a) != null);
    try std.testing.expect(node.peer(b) != null);
    // Every registered peer shares the node's one gift registry.
    try std.testing.expectEqual(&node.gifts, node.peer(a).?.giftRegistry());
    try std.testing.expectEqual(&node.gifts, node.peer(b).?.giftRegistry());

    node.removePeer(a);
    try std.testing.expect(node.peer(a) == null);
    // A removed id is not reused: the next registration gets a fresh id past it.
    const c = try node.registerPeer(.{});
    try std.testing.expect(c != a);
    try std.testing.expect(c != b);
}

/// The answer position the node assigned the one withdraw it has parked on
/// `exporter`. In production the exporter echoes this id on its resolve frame,
/// so a host reads it off the wire; a white-box test drives `claimResolve`
/// directly and recovers it from the node's single pending withdraw. Asserts
/// exactly one withdraw is parked, on `exporter`.
fn pendingWithdrawAnswer(node: *Node, exporter: engine.PeerId) u64 {
    std.testing.expectEqual(@as(usize, 1), node.pending_withdraws.count()) catch unreachable;
    var it = node.pending_withdraws.keyIterator();
    const key = it.next().?.*;
    std.testing.expectEqual(exporter, key.peer_id) catch unreachable;
    return key.answer;
}

/// A structurally valid signed `desc:handoff-give`, for tests that exercise
/// `Node`'s withdraw bookkeeping rather than the give's own signature or
/// content — any two calls are interchangeable here. `Node.acceptGive` hands
/// its `give` bytes to `Peer.sendWithdrawGift`, which now decodes them into
/// typed fields (`decodeSignedHandoffGiveOwned`) so a Cap'n Proto session can
/// carry a binding-originated give too; an ASCII placeholder no longer parses
/// as Syrup, where this file used to get away with one. Caller owns the
/// returned bytes.
fn testGiveBytes(allocator: std.mem.Allocator) ![]u8 {
    const location = try engine.encodePeerLocatorRecord(allocator, .{
        .transport = "tcp",
        .designator = "127.0.0.1:9099",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(location);
    const secret = crypto.SecretKey.fromSeed([_]u8{0x77} ** crypto.SEED_BYTES);
    return engine.handoff_gifter.buildSignedGive(
        allocator,
        secret,
        &([_]u8{0x01} ** 32),
        location,
        &([_]u8{0x02} ** 32),
        &([_]u8{0x03} ** 32),
        &([_]u8{0x04} ** 32),
    );
}

/// Mint a routable redeemed token through the public redeem flow: accept a
/// give on `recipient`, report `exporter` (whose keyed session is open) as the
/// dialed connection, and claim the withdraw's resolve with `far_id`. Returns
/// the settled synthetic token id.
fn mintRedeemedToken(
    node: *Node,
    recipient: engine.PeerId,
    exporter: engine.PeerId,
    answer: u64,
    far_id: u64,
    locator: []const u8,
) !u64 {
    const give = try testGiveBytes(node.allocator);
    defer node.allocator.free(give);
    try node.acceptGive(recipient, answer, give, locator);
    const dial = node.nextAction().?;
    try node.exporterDialed(dial.dial.pending, exporter);
    _ = node.nextAction().?; // the withdraw flush
    const withdraw_answer = pendingWithdrawAnswer(node, exporter);
    if (!try node.claimResolve(exporter, withdraw_answer, .{ .far = far_id })) return error.NotClaimed;
    const settle = node.nextAction().?;
    if (settle.settle.answer != answer) return error.WrongAnswerSettled;
    return settle.settle.token;
}

test "a redeemed token routes to its exporter with the real reference swapped in" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{9} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient_conn = try node.registerPeer(.{});
    const exporter_conn = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter_conn).?, [_]u8{16} ** crypto.SEED_BYTES);
    defer counterpart.deinit();

    // Redeem a give against the live exporter; the claimed resolve enrolls the
    // real exporter-side reference (far 42) under a fresh synthetic token.
    const token = try mintRedeemedToken(&node, recipient_conn, exporter_conn, 71, 42, "ocapn://127.0.0.1%3A9055.tcp");
    // The application receives an opaque far token in the reserved range.
    try std.testing.expect(token >= Node.REDEEMED_TOKEN_BASE);
    const token_ref: model.Reference = .{ .far = model.FarRef.object(token) };

    // A send to the token routes to the exporter connection with the real ref.
    const routed = node.routeReference(recipient_conn, token_ref).?;
    try std.testing.expectEqual(exporter_conn, routed.peer_id);
    try std.testing.expectEqual(@as(u64, 42), routed.target.far.import_position.int());

    // An ordinary far import rides the connection the app addressed, unchanged.
    const plain: model.Reference = .{ .far = model.FarRef.object(3) };
    const plain_routed = node.routeReference(recipient_conn, plain).?;
    try std.testing.expectEqual(recipient_conn, plain_routed.peer_id);
    try std.testing.expectEqual(@as(u64, 3), plain_routed.target.far.import_position.int());

    // A token whose exporter connection is gone fails closed.
    node.removePeer(exporter_conn);
    try std.testing.expect(node.routeReference(recipient_conn, token_ref) == null);
}

test "enrollForeign preserves promise RefKind on the token" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{3} ** crypto.SEED_BYTES);
    defer node.deinit();
    const home = try node.registerPeer(.{});
    const token = try node.enrollForeign(home, .{ .far = model.FarRef.promise(8) });
    try std.testing.expectEqual(model.RefKind.promise, token.far.kind);
    const object_token = try node.enrollForeign(home, .{ .far = model.FarRef.object(9) });
    try std.testing.expectEqual(model.RefKind.object, object_token.far.kind);
}

test "proxyForeignPromiseFulfill refuses when the home session is not open" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{11} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    const token = try node.enrollForeign(home, .{ .far = model.FarRef.promise(4) });
    try std.testing.expectError(
        error.session_not_open,
        node.proxyForeignPromiseFulfill(recipient, token.far.import_position.int()),
    );
}

test "proxyForeignPromiseFulfill mints a third-party import-promise on the recipient peer" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{11} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, [_]u8{19} ** crypto.SEED_BYTES);
    defer home_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const token = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const far_id = token.far.import_position.int();

    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, far_id)).?;
    try std.testing.expectEqual(model.RefKind.promise, rewritten.near.kind);
    const pos = rewritten.near.export_position;
    const peer = node.peer(recipient).?;
    try std.testing.expect(peer.session_state.isThirdPartyImport(.from(pos.int())));

    const obj = try node.enrollForeign(home, .{ .far = model.FarRef.object(5) });
    try std.testing.expect((try node.proxyForeignPromiseFulfill(recipient, obj.far.import_position.int())) == null);
    try std.testing.expect((try node.proxyForeignPromiseFulfill(home, far_id)) == null);
}

test "proxyForeignPromise home listen relays settlement to the recipient third-party import" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{13} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, [_]u8{21} ** crypto.SEED_BYTES);
    defer home_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const token = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const far_id = token.far.import_position.int();

    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, far_id)).?;
    const import_pos = rewritten.near.export_position.int();

    // Home listen is queued; step encodes it. The listener export is what Host
    // will match on an inbound fire deliver.
    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    const listener = blk: {
        var frame = node.peer(home).?.takeOutbound().?;
        defer frame.deinit();
        const view = try pancake.ocapn.codec.syrup.decodeBody(frame.view());
        try std.testing.expect(view == .listen);
        // Own-outbound decode flips near export → far import; position is the
        // listener export we allocated on the home peer.
        break :blk view.listen.listener.far.import_position.int();
    };
    const payload = try allocator.dupe(u8, "relayed");
    try std.testing.expect(try node.consumeProxyListenerFire(home, listener, .{ .fulfill = .{ .bytes = payload } }));

    const recip = node.peer(recipient).?;
    try std.testing.expectEqualStrings("relayed", recip.session_state.importedPromiseResolution(.from(import_pos)).?.fulfill.bytes);

    // After settle the proxy is torn down; a second deliver is not claimed
    // (resolve-once lives in the import store, not a zombie Node index).
    const second = try allocator.dupe(u8, "again");
    defer allocator.free(second);
    try std.testing.expect(!try node.consumeProxyListenerFire(home, listener, .{ .fulfill = .{ .bytes = second } }));
}

test "proxyForeignPromise multi-introduce shares one home listen and materializes into each store" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{15} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient_a = try node.registerPeer(.{});
    const recipient_b = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, [_]u8{23} ** crypto.SEED_BYTES);
    defer home_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const token = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const far_id = token.far.import_position.int();

    const rewritten_a = (try node.proxyForeignPromiseFulfill(recipient_a, far_id)).?;
    const rewritten_b = (try node.proxyForeignPromiseFulfill(recipient_b, far_id)).?;
    const import_a = rewritten_a.near.export_position.int();
    const import_b = rewritten_b.near.export_position.int();

    // Exactly one home listen for both introduces.
    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    const listener = blk: {
        var frame = node.peer(home).?.takeOutbound().?;
        defer frame.deinit();
        const view = try pancake.ocapn.codec.syrup.decodeBody(frame.view());
        try std.testing.expect(view == .listen);
        break :blk view.listen.listener.far.import_position.int();
    };
    try std.testing.expectEqual(engine.StepOutcome.idle, try node.peer(home).?.step());

    const payload = try allocator.dupe(u8, "shared");
    try std.testing.expect(try node.consumeProxyListenerFire(home, listener, .{ .fulfill = .{ .bytes = payload } }));

    try std.testing.expectEqualStrings(
        "shared",
        node.peer(recipient_a).?.session_state.importedPromiseResolution(.from(import_a)).?.fulfill.bytes,
    );
    try std.testing.expectEqualStrings(
        "shared",
        node.peer(recipient_b).?.session_state.importedPromiseResolution(.from(import_b)).?.fulfill.bytes,
    );
}

test "send-argument routability: a capability on another connection is foreign, its home native" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{3} ** crypto.SEED_BYTES);
    defer node.deinit();

    const here = try node.registerPeer(.{});
    const elsewhere = try node.registerPeer(.{});

    // The verdict every binding's send-argument guard computes from the node: a
    // far is foreign in argument position when it is a redeemed token (reserved
    // range, no wire home) or a fetched-import token addressed away from its home.
    // `Node.argIsForeign` is the one definition; every binding's fail-closed guard
    // projects it through pancake_node_arg_is_foreign rather than hand-rolling a
    // copy (ADR-0069).
    const import = try node.enrollForeign(elsewhere, .{ .far = model.FarRef.object(8) });
    // Foreign when sent from `here` (it lives on `elsewhere`)…
    try std.testing.expect(node.argIsForeign(here, import));
    // …native when sent from its own home.
    try std.testing.expect(!node.argIsForeign(elsewhere, import));

    // An ordinary wire far, below the reserved token range, rides its own
    // connection: not foreign.
    const unknown: model.Reference = .{ .far = model.FarRef.object(9) };
    try std.testing.expect(!node.argIsForeign(here, unknown));

    // A redeemed token is foreign from any connection of the node, its home
    // included: it has no wire home, so it can only be re-routed as a send target,
    // never marshalled as an argument.
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(elsewhere).?, [_]u8{17} ** crypto.SEED_BYTES);
    defer counterpart.deinit();
    const token_id = try mintRedeemedToken(&node, here, elsewhere, 81, 1, "ocapn://127.0.0.1%3A9056.tcp");
    const token: model.Reference = .{ .far = model.FarRef.object(token_id) };
    try std.testing.expect(node.argIsForeign(here, token));
    try std.testing.expect(node.argIsForeign(elsewhere, token));
}

test "origination fails closed when the gift's home connection is gone" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{5} ** crypto.SEED_BYTES);
    defer node.deinit();

    const here = try node.registerPeer(.{});
    const elsewhere = try node.registerPeer(.{});

    // A foreign-home reply is claimed and the node asks for gift-id entropy;
    // the home connection then dies before the entropy answer arrives, so the
    // origination fails closed as a broken answer on the vanished connection
    // instead of mis-encoding a cross-connection reference. The negotiating
    // (session-never-opened) fail-closed arm is pinned by the
    // `interceptFulfilledRef` test below; the live positive proof is the
    // `*-goblins-gift` matrix.
    const gift = try node.enrollForeign(elsewhere, .{ .far = model.FarRef.object(4) });
    try std.testing.expect(try node.interceptFulfilledRef(here, 61, gift.far.import_position.int()));
    const ask = node.nextAction().?;
    node.removePeer(elsewhere);
    const gift_id = [_]u8{0xAB} ** 32;
    try node.provideGiftId(ask.need_gift_id.ticket, &gift_id);
    const action = node.nextAction().?;
    try std.testing.expectEqual(here, action.fail.peer_id);
    try std.testing.expectEqual(@as(u64, 61), action.fail.answer);
    try std.testing.expect(std.mem.startsWith(u8, action.fail.reason, "handoff origination failed:"));
}

// ── The serve step: the sans-io redeem state machine ─────────────────────────
//
// These prove the *decisions* the serve step owns — interception, the exporter
// cache, dial dedup, pending withdraws, token settlement, fail-closed arms —
// as data in and actions out, with no socket. The live proof that the same
// step drives a real three-party redeem is `zig build goblins-handoff`.

test "acceptGive with no dialable exporter locator fails the answer closed" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{2} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    try node.acceptGive(recipient, 7, "give-bytes", "");

    const action = node.nextAction().?;
    try std.testing.expectEqual(recipient, action.fail.peer_id);
    try std.testing.expectEqual(@as(u64, 7), action.fail.answer);
    try std.testing.expectEqualStrings("handoff give names no dialable exporter locator", action.fail.reason);
    try std.testing.expect(node.nextAction() == null);
}

test "an unknown exporter becomes one dial action; a second give joins it" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{4} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const locator = "ocapn://127.0.0.1%3A9050.tcp";
    try node.acceptGive(recipient, 11, "give-one", locator);
    // A second redeem naming the same exporter joins the pending dial instead
    // of opening a second connection.
    try node.acceptGive(recipient, 12, "give-two", locator);

    const action = node.nextAction().?;
    const join_view = node.pendingDial(action.dial.pending).?;
    try std.testing.expectEqualStrings("tcp", join_view.transport);
    try std.testing.expectEqualStrings("127.0.0.1:9050", join_view.designator);
    try std.testing.expect(node.nextAction() == null);

    // The dial failing breaks both waiting answers, in order.
    try node.dialFailed(action.dial.pending, "connection refused");
    const first = node.nextAction().?;
    try std.testing.expectEqual(@as(u64, 11), first.fail.answer);
    try std.testing.expectEqualStrings("handoff redeem failed: connection refused", first.fail.reason);
    const second = node.nextAction().?;
    try std.testing.expectEqual(@as(u64, 12), second.fail.answer);
    try std.testing.expect(node.nextAction() == null);

    // The settled ticket is retired: reporting it again is a no-op.
    try node.dialFailed(action.dial.pending, "late");
    try std.testing.expect(node.nextAction() == null);
}

test "acceptGive materializes dial view once for pendingDial" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{4} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const locator = "ocapn://127.0.0.1%3A9049.tcp?direct-addresses=10.0.0.1%3A1";
    try node.acceptGive(recipient, 9, "give-bytes", locator);
    const action = node.nextAction().?;
    const view = node.pendingDial(action.dial.pending).?;
    try std.testing.expectEqualStrings("tcp", view.transport);
    try std.testing.expectEqualStrings("127.0.0.1:9049", view.designator);
    try std.testing.expectEqualStrings("10.0.0.1:1", view.direct_addresses_hint);
    try node.dialFailed(action.dial.pending, "stop");
    _ = node.nextAction();
}

test "acceptGive fails closed on unparseable exporter locator" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{6} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    try node.acceptGive(recipient, 3, "give-bytes", "not-a-locator");
    const action = node.nextAction().?;
    try std.testing.expect(action == .fail);
    try std.testing.expectEqual(@as(u64, 3), action.fail.answer);
    try std.testing.expect(std.mem.indexOf(u8, action.fail.reason, "unparseable") != null);
    try std.testing.expect(node.nextAction() == null);
}

test "exporterDialed frees empty hint sentinel without leaking" {
    // Hint-less URI stages an unowned empty hint; exporterDialed must free
    // through freeDialPart (not raw allocator.free on "").
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{7} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    const locator = "ocapn://127.0.0.1%3A9051.tcp";
    try node.acceptGive(recipient, 4, "give-bytes", locator);
    const action = node.nextAction().?;
    const view = node.pendingDial(action.dial.pending).?;
    try std.testing.expectEqual(@as(usize, 0), view.direct_addresses_hint.len);
    try node.exporterDialed(action.dial.pending, exporter);
    // Withdraw flush against the exporter; drain so deinit is clean.
    while (node.nextAction()) |_| {}
}

test "acceptGive joins pending dials on peer identity, not URI spelling" {
    // ADR-0012: hints are connection advice, not identity. Two gives that name
    // the same transport+designator must share one in-flight dial even when the
    // URI bytes differ (query hints / encoding).
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{5} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const bare = "ocapn://127.0.0.1%3A9050.tcp";
    const hinted = "ocapn://127.0.0.1%3A9050.tcp?host=127.0.0.1&port=9050";
    try node.acceptGive(recipient, 11, "give-one", bare);
    try node.acceptGive(recipient, 12, "give-two", hinted);

    const action = node.nextAction().?;
    const identity_view = node.pendingDial(action.dial.pending).?;
    try std.testing.expectEqualStrings("tcp", identity_view.transport);
    try std.testing.expectEqualStrings("127.0.0.1:9050", identity_view.designator);
    try std.testing.expect(node.nextAction() == null);

    try node.dialFailed(action.dial.pending, "connection refused");
    try std.testing.expectEqual(@as(u64, 11), node.nextAction().?.fail.answer);
    try std.testing.expectEqual(@as(u64, 12), node.nextAction().?.fail.answer);
    try std.testing.expect(node.nextAction() == null);
}

test "a dialed exporter whose session never opened fails the redeem closed" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{6} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    try node.acceptGive(recipient, 21, "give-bytes", "ocapn://127.0.0.1%3A9051.tcp");
    const dial = node.nextAction().?;

    // The embedder registers the exporter conn but the keyed session is not
    // open (no partner key), so the withdraw cannot be signed: the redeem
    // breaks instead of hanging.
    const exporter = try node.registerPeer(.{});
    try node.exporterDialed(dial.dial.pending, exporter);
    const action = node.nextAction().?;
    try std.testing.expectEqual(recipient, action.fail.peer_id);
    try std.testing.expectEqual(@as(u64, 21), action.fail.answer);
    try std.testing.expect(std.mem.startsWith(u8, action.fail.reason, "handoff redeem failed:"));
}

/// Open a keyed session between the node-owned peer `p` (signing with the
/// node's retained identity) and a fresh standalone counterpart, driving both
/// handshakes to quiescence in memory. Returns the counterpart; the caller
/// deinits it.
fn openKeyedSessionWithCounterpart(
    allocator: std.mem.Allocator,
    node: *Node,
    p: *engine.Peer,
    counterpart_seed: [crypto.SEED_BYTES]u8,
) !engine.Peer {
    const codec = pancake.ocapn.codec;
    var counterpart = engine.Peer.initNegotiating(allocator);
    errdefer counterpart.deinit();

    const node_secret = node.secretKey();
    const partner_secret = crypto.SecretKey.fromSeed(counterpart_seed);

    const node_loc: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:1", .hints = model.Hints.emptyMap() };
    const partner_loc: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:2", .hints = model.Hints.emptyMap() };

    const node_signed = try codec.syrup.canonicalLocationSignedBytes(allocator, node_loc);
    defer allocator.free(node_signed);
    const partner_signed = try codec.syrup.canonicalLocationSignedBytes(allocator, partner_loc);
    defer allocator.free(partner_signed);

    const node_sig = crypto.sign(&node_secret, node_signed);
    const partner_sig = crypto.sign(&partner_secret, partner_signed);

    try p.sendCopying(.{ .start_session = .{
        .captp_version = p.session_state.captp_version,
        .session_pubkey = .{ .bytes = node_secret.publicKey().asBytes() },
        .acceptable_location = node_loc,
        .acceptable_location_sig = .{ .bytes = node_sig.asBytes() },
    } });
    try counterpart.sendCopying(.{ .start_session = .{
        .captp_version = counterpart.session_state.captp_version,
        .session_pubkey = .{ .bytes = partner_secret.publicKey().asBytes() },
        .acceptable_location = partner_loc,
        .acceptable_location_sig = .{ .bytes = partner_sig.asBytes() },
    } });
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

test "a live exporter withdraws immediately and the claimed resolve settles a routable token" {
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
    // the application answer settles with a routable token.
    try std.testing.expect(try node.claimResolve(exporter, withdraw_answer, .{ .far = 6 }));
    const settle = node.nextAction().?;
    try std.testing.expectEqual(recipient, settle.settle.peer_id);
    try std.testing.expectEqual(@as(u64, 31), settle.settle.answer);
    try std.testing.expect(settle.settle.token >= Node.REDEEMED_TOKEN_BASE);
    const routed = node.routeReference(recipient, .{ .far = model.FarRef.object(settle.settle.token) }).?;
    try std.testing.expectEqual(exporter, routed.peer_id);
    try std.testing.expectEqual(@as(u64, 6), routed.target.far.import_position.int());

    // The exporter is cached: a later give for the same locator withdraws
    // immediately, no dial action.
    const give_more = try testGiveBytes(allocator);
    defer allocator.free(give_more);
    try node.acceptGive(recipient, 32, give_more, locator);
    const flush_again = node.nextAction().?;
    try std.testing.expectEqual(exporter, flush_again.flush);
    try std.testing.expect(node.nextAction() == null);
}

test "a broken or non-capability withdraw breaks the application answer" {
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
    try node.acceptGive(recipient, 41, give_a, locator);
    const dial = node.nextAction().?;
    try node.exporterDialed(dial.dial.pending, exporter);
    _ = node.nextAction().?; // the flush
    const first_answer = pendingWithdrawAnswer(&node, exporter);

    try std.testing.expect(try node.claimResolve(exporter, first_answer, .{ .broken = "no such gift" }));
    const broke = node.nextAction().?;
    try std.testing.expectEqual(@as(u64, 41), broke.fail.answer);
    try std.testing.expectEqualStrings("handoff redeem failed: no such gift", broke.fail.reason);

    // A withdraw fulfilled with a non-capability breaks with the named reason.
    const give_b = try testGiveBytes(allocator);
    defer allocator.free(give_b);
    try node.acceptGive(recipient, 42, give_b, locator);
    _ = node.nextAction().?; // the flush (exporter already cached)
    const second_answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, second_answer, .not_capability));
    const refused = node.nextAction().?;
    try std.testing.expectEqualStrings("withdraw-gift did not resolve to a capability", refused.fail.reason);
}

test "interceptFulfilledRef claims only a foreign-home reply, entropy as an effect" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{12} ** crypto.SEED_BYTES);
    defer node.deinit();

    const here = try node.registerPeer(.{});
    const elsewhere = try node.registerPeer(.{});

    // No enrollment, or a home on this very connection: not claimed, the embedder
    // resolves the reply itself — and no entropy is ever requested for an ordinary
    // reply. A token homed here is returned to its own owner, so the chokepoint
    // lowers it and no re-gift is needed.
    try std.testing.expect(!try node.interceptFulfilledRef(here, 51, 5));
    const home_here = try node.enrollForeign(here, .{ .far = model.FarRef.object(5) });
    try std.testing.expect(!try node.interceptFulfilledRef(here, 51, home_here.far.import_position.int()));
    try std.testing.expect(node.nextAction() == null);

    // A capability homed on another connection is claimed: the node asks for
    // gift-id entropy (a host effect, like dialing) rather than receiving it
    // speculatively.
    const home_else = try node.enrollForeign(elsewhere, .{ .far = model.FarRef.object(6) });
    try std.testing.expect(try node.interceptFulfilledRef(here, 52, home_else.far.import_position.int()));
    const ask = node.nextAction().?;
    const ticket = ask.need_gift_id.ticket;

    // The sessions here are not open, so the origination fails closed into a
    // broken answer rather than a mis-encoded cross-connection reference; the
    // live positive proof is the `*-goblins-gift` matrix.
    const gift_id = [_]u8{0xCD} ** 32;
    try node.provideGiftId(ticket, &gift_id);
    const action = node.nextAction().?;
    try std.testing.expectEqual(@as(u64, 52), action.fail.answer);
    try std.testing.expect(std.mem.startsWith(u8, action.fail.reason, "handoff origination failed:"));

    // A settled ticket is retired: answering it again is a no-op.
    try node.provideGiftId(ticket, &gift_id);
    try std.testing.expect(node.nextAction() == null);
}

test "a fetched foreign import is enrolled under a node-unique token; two at one position never collide and each routes home (ADR-0069)" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{18} ** crypto.SEED_BYTES);
    defer node.deinit();

    const conn_a = try node.registerPeer(.{});
    const conn_b = try node.registerPeer(.{});

    // Two capabilities fetched over different connections land at the SAME wire
    // position (imports are numbered per session). Enrolling each yields a
    // distinct node-unique token, so the node-global collision the old
    // position-keyed home map had — where the second fetch clobbered the first —
    // cannot happen.
    const wire: model.Reference = .{ .far = model.FarRef.object(1) };
    const token_a = try node.enrollForeign(conn_a, wire);
    const token_b = try node.enrollForeign(conn_b, wire);
    const a = token_a.far.import_position.int();
    const b = token_b.far.import_position.int();
    try std.testing.expect(a != b);
    try std.testing.expect(a >= Node.REDEEMED_TOKEN_BASE);

    // Each token routes to its OWN home, lowered to the real wire reference. This
    // is the same swap the served-reply interceptor uses to keep a token off the
    // wire when a fetched capability is returned to its own owner.
    const ra = node.routeReference(conn_a, token_a).?;
    try std.testing.expectEqual(conn_a, ra.peer_id);
    try std.testing.expectEqual(@as(u64, 1), ra.target.far.import_position.int());
    const rb = node.routeReference(conn_b, token_b).?;
    try std.testing.expectEqual(conn_b, rb.peer_id);
    try std.testing.expectEqual(@as(u64, 1), rb.target.far.import_position.int());

    // In argument position each token is native on its home, foreign elsewhere.
    try std.testing.expect(!node.argIsForeign(conn_a, token_a));
    try std.testing.expect(node.argIsForeign(conn_b, token_a));
    try std.testing.expect(!node.argIsForeign(conn_b, token_b));
    try std.testing.expect(node.argIsForeign(conn_a, token_b));

    // A served reply returning a token on its OWN home is not re-gifted (the
    // interceptor lowers it); returned elsewhere it would be. Same-home returns
    // false and queues nothing — proving each token's home is its own connection,
    // not the last one enrolled.
    try std.testing.expect(!try node.interceptFulfilledRef(conn_a, 70, a));
    try std.testing.expect(!try node.interceptFulfilledRef(conn_b, 71, b));
    try std.testing.expect(node.nextAction() == null);

    // Reclamation + fail-closed: closing conn_a reclaims token_a's enrollment, and
    // using the retired token fails closed rather than leaking the synthetic id
    // onto the wire. token_b, whose home is live, still routes.
    node.removePeer(conn_a);
    try std.testing.expect(node.routeReference(conn_b, token_a) == null);
    try std.testing.expectEqual(conn_b, node.routeReference(conn_b, token_b).?.peer_id);
}

test "lowerForConn swaps a token to its wire reference on its home and fails closed elsewhere (ADR-0069)" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{21} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const other = try node.registerPeer(.{});

    // A plain wire reference, below the reserved token range, is the fast path:
    // it lowers to itself with no lookup, on any connection.
    const plain: model.Reference = .{ .far = model.FarRef.object(4) };
    try std.testing.expectEqual(@as(u64, 4), (try node.lowerForConn(home, plain)).far.import_position.int());
    try std.testing.expectEqual(@as(u64, 4), (try node.lowerForConn(other, plain)).far.import_position.int());
    // A near reference is not a token either; it passes through untouched.
    const near: model.Reference = .{ .near = .{ .export_position = .from(2) } };
    try std.testing.expect((try node.lowerForConn(home, near)) == .near);

    // A foreign-import token lowers to its real wire import on its home
    // connection — this is the swap the outbound chokepoint (`Peer.send`) makes so
    // the token never reaches the wire — and fails closed on any other connection,
    // where it has no wire name.
    const token = try node.enrollForeign(home, .{ .far = model.FarRef.object(7) });
    try std.testing.expectEqual(@as(u64, 7), (try node.lowerForConn(home, token)).far.import_position.int());
    try std.testing.expectError(error.TokenNotLiftable, node.lowerForConn(other, token));

    // Enrolling the first token latched the walk gate on; a node that never
    // fetched a foreign capability leaves it off so every send skips the walk.
    try std.testing.expect(node.foreign_active);

    // A synthetic id the node never enrolled (a retired or fabricated token) has
    // no route and fails closed rather than reaching the wire as its bare id.
    const ghost: model.Reference = .{ .far = model.FarRef.object(Node.REDEEMED_TOKEN_BASE + 999) };
    try std.testing.expectError(error.TokenNotLiftable, node.lowerForConn(home, ghost));
}

test "setExporterLocation records, replaces, and clears the give-location override" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{13} ** crypto.SEED_BYTES);
    defer node.deinit();

    const conn = try node.registerPeer(.{});
    const first = try model.uri.parsePeer(allocator, "ocapn://127.0.0.1%3A7001.tcp");
    defer model.freePeerLocator(allocator, first);
    try node.setExporterLocation(conn, first);
    const replaced = try model.uri.parsePeer(allocator, "ocapn://127.0.0.1%3A7002.tcp");
    defer model.freePeerLocator(allocator, replaced);
    try node.setExporterLocation(conn, replaced);
    // Clearing returns the give to the exporter session's own signed record.
    try node.setExporterLocation(conn, null);
    // Removal frees a recorded override with the connection.
    const again = try model.uri.parsePeer(allocator, "ocapn://127.0.0.1%3A7003.tcp");
    defer model.freePeerLocator(allocator, again);
    try node.setExporterLocation(conn, again);
    node.removePeer(conn);
}

test "removePeer evicts the exporter cache and fails stranded withdraws closed" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{14} ** crypto.SEED_BYTES);
    defer node.deinit();

    const recipient = try node.registerPeer(.{});
    const exporter = try node.registerPeer(.{});
    var counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(exporter).?, [_]u8{15} ** crypto.SEED_BYTES);
    defer counterpart.deinit();

    const locator = "ocapn://127.0.0.1%3A9054.tcp";
    const give = try testGiveBytes(allocator);
    defer allocator.free(give);
    try node.acceptGive(recipient, 61, give, locator);
    const dial = node.nextAction().?;
    try node.exporterDialed(dial.dial.pending, exporter);
    _ = node.nextAction().?; // the flush

    // The exporter dies mid-withdraw: the pending withdraw fails closed (the
    // recipient's answer breaks instead of hanging) and the cache row is
    // evicted, so the next give for the same exporter dials fresh instead of
    // failing against the dead connection forever.
    node.removePeer(exporter);
    const failed = node.nextAction().?;
    try std.testing.expectEqual(recipient, failed.fail.peer_id);
    try std.testing.expectEqual(@as(u64, 61), failed.fail.answer);
    try std.testing.expectEqualStrings("handoff redeem failed: exporter connection closed", failed.fail.reason);
    try std.testing.expect(node.nextAction() == null);

    try node.acceptGive(recipient, 62, "give-again", locator);
    const redial = node.nextAction().?;
    const redial_view = node.pendingDial(redial.dial.pending).?;
    try std.testing.expectEqualStrings("tcp", redial_view.transport);
    try std.testing.expectEqualStrings("127.0.0.1:9054", redial_view.designator);
}
