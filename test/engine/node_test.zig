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
const LiveBytesAllocator = @import("../support/alloc_metrics.zig").LiveBytesAllocator;

const Node = engine.Node;

test "ActionFifo preserves order across compaction, and a drain keeps its reservation" {
    const allocator = std.testing.allocator;
    var fifo = engine.ActionFifo(u64){};
    defer fifo.deinit(allocator);

    // The shared spine slides a dead prefix forward once it dominates the
    // backing (`fifo.popHead`), so drive the head past that point with rows
    // still queued: order has to survive the forward copy.
    var pushed: u64 = 0;
    while (pushed < 400) : (pushed += 1) try fifo.push(allocator, pushed);
    var popped: u64 = 0;
    while (popped < 300) : (popped += 1) try std.testing.expectEqual(popped, fifo.pop(allocator).?);
    try fifo.push(allocator, 400);
    try std.testing.expectEqual(@as(usize, 101), fifo.unpopped().len);
    while (popped < 401) : (popped += 1) try std.testing.expectEqual(popped, fifo.pop(allocator).?);

    // Drained: the pop that finds nothing rewinds the list for reuse.
    try std.testing.expectEqual(@as(?u64, null), fifo.pop(allocator));
    try std.testing.expectEqual(@as(usize, 0), fifo.unpopped().len);

    // The reserve/pushReserved pair holds the infallible-push contract.
    try fifo.reserve(allocator, 2);
    fifo.pushReserved(7);
    fifo.pushReserved(8);
    try std.testing.expectEqual(@as(u64, 7), fifo.pop(allocator).?);
    try std.testing.expectEqual(@as(u64, 8), fifo.pop(allocator).?);
}

test "a reservation survives the drain that happens before it is spent" {
    const allocator = std.testing.allocator;
    // The host reserves action-queue capacity when it mints a vow, so the
    // settle that fires later can push without a failure path — a settled vow
    // with no completion is unrepresentable. The embedder drains the queue
    // between those two moments, every time, because that is the documented
    // loop. A drain that shed capacity would leave the infallible push writing
    // past the end of the backing, which is a memory-safety break rather than a
    // lost row, and it is invisible until a host holds enough live vows for the
    // reservation to have grown the list at all.
    var fifo = engine.ActionFifo(u64){};
    defer fifo.deinit(allocator);

    // Past the steady byte bound, which is where a reclaiming drain would
    // actually shed: the host reaches this with a few dozen live vows, since
    // its action rows are far wider than these.
    const rows = 2 * engine.fifo_steady_bytes / @sizeOf(u64);
    try fifo.reserve(allocator, rows);
    const reserved = fifo.list.capacity;
    try std.testing.expect(reserved * @sizeOf(u64) > engine.fifo_steady_bytes);

    // Drain to empty, the state the embedder leaves behind on every loop.
    try std.testing.expectEqual(@as(?u64, null), fifo.pop(allocator));
    try std.testing.expectEqual(reserved, fifo.list.capacity);

    // Now spend it, as a settle fires.
    var i: u64 = 0;
    while (i < rows) : (i += 1) fifo.pushReserved(i);
    try std.testing.expectEqual(@as(u64, 0), fifo.pop(allocator).?);
}

test "registerPeerOver adopts a peer the embedder owns without freeing it" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{8} ** crypto.SEED_BYTES);

    // A peer the test owns and pins, standing in for the completion loop's
    // inline per-connection peer at its stable slot address.
    var adopted = engine.Peer.initNegotiating(allocator);
    defer adopted.deinit();

    const id = try node.registerPeerOver(&adopted);
    // The adopted peer is the one the node routes to. Its gift registry remains
    // session-owned; joining a Node does not move protocol transcript state.
    try std.testing.expectEqual(&adopted, node.peer(id).?);

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

test "failed adopted registration severs the borrowed Node services link" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    var node = Node.init(allocator, [_]u8{0x18} ** crypto.SEED_BYTES);
    defer node.deinit();
    var adopted = engine.Peer.initNegotiating(allocator);
    defer adopted.deinit();

    try std.testing.expectError(error.OutOfMemory, node.registerPeerOver(&adopted));
    try std.testing.expect(adopted.node_services == null);
}

test "handoff scheduler releases its backing at total quiescence" {
    var live = LiveBytesAllocator{ .backing = std.testing.allocator };
    const allocator = live.allocator();
    var node = Node.init(allocator, [_]u8{0x19} ** crypto.SEED_BYTES);
    defer node.deinit();

    const gifter_a = try node.registerPeer(.{});
    const gifter_b = try node.registerPeer(.{});
    const receiver = try node.registerPeer(.{});
    const services = node.peer(receiver).?.node_services.?;
    const baseline = live.liveBytes();
    const dependency_a = engine.node_services.HandoffDependency.init(gifter_a, "gift-a");
    const dependency_b = engine.node_services.HandoffDependency.init(gifter_b, "gift-b");

    try services.pendingWithdrawAdded(dependency_a);
    try services.pendingWithdrawAdded(dependency_b);
    try std.testing.expect(live.liveBytes() > baseline);
    services.pendingWithdrawRemoved(dependency_a);
    services.pendingWithdrawRemoved(dependency_b);

    try std.testing.expectEqual(baseline, live.liveBytes());
}

test "handoff changes wake only receivers dependent on the changed gifter" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{9} ** crypto.SEED_BYTES);
    defer node.deinit();

    const gifter_a = try node.registerPeer(.{});
    const gifter_b = try node.registerPeer(.{});
    const receiver_a = try node.registerPeer(.{});
    const receiver_b = try node.registerPeer(.{});
    const services_a = node.peer(receiver_a).?.node_services.?;
    const services_b = node.peer(receiver_b).?.node_services.?;
    const dependency_a1 = engine.node_services.HandoffDependency.init(gifter_a, "gift-a1");
    const dependency_a2 = engine.node_services.HandoffDependency.init(gifter_a, "gift-a2");
    const dependency_b = engine.node_services.HandoffDependency.init(gifter_b, "gift-b");

    // Two gift ids on one gifter are independent scheduler rows. Depositing
    // one must not wake the receiver on behalf of the other.
    try services_a.pendingWithdrawAdded(dependency_a1);
    try services_a.pendingWithdrawAdded(dependency_a2);
    try services_b.pendingWithdrawAdded(dependency_b);
    try std.testing.expectEqual(@as(usize, 2), node.handoffWaiterCount(gifter_a));
    try std.testing.expectEqual(@as(usize, 1), node.handoffWaiterCount(gifter_b));

    node.peer(gifter_a).?.node_services.?.giftDeposited("gift-a1");
    try std.testing.expectEqual(dependency_a1, node.nextHandoffChange().?);
    var waiters = node.handoffWaiters(dependency_a1);
    try std.testing.expectEqual(receiver_a, waiters.next().?);
    try std.testing.expect(waiters.next() == null);
    node.consumeHandoffChange(dependency_a1);
    try std.testing.expect(node.nextHandoffChange() == null);

    // Protocol closure is authority closure even while the registered shell
    // remains allocated. An inbound abort therefore marks the same targeted
    // dependency immediately; waiting for `removePeer` would leave gifts live.
    const gifter_a_peer = node.peer(gifter_a).?;
    try gifter_a_peer.session_state.transitionToOpen();
    const abort = try pancake.ocapn.codec.syrup.encodeMessage(allocator, .{ .abort = .{
        .kind = .graceful_shutdown,
        .message = "done",
    } });
    try gifter_a_peer.feedOwned(abort);
    while ((try gifter_a_peer.step()) != .idle) {}
    const first_close_change = node.nextHandoffChange().?;
    try std.testing.expectEqual(gifter_a, first_close_change.gifter);
    node.consumeHandoffChange(first_close_change);
    const second_close_change = node.nextHandoffChange().?;
    try std.testing.expectEqual(gifter_a, second_close_change.gifter);
    node.consumeHandoffChange(second_close_change);

    services_a.pendingWithdrawRemoved(dependency_a1);
    try std.testing.expectEqual(@as(usize, 1), node.handoffWaiterCount(gifter_a));
    services_a.pendingWithdrawRemoved(dependency_a2);
    try std.testing.expectEqual(@as(usize, 0), node.handoffWaiterCount(gifter_a));

    // Closing a gifter marks only that gifter's dependents. The receiver-side
    // pending-row removal then unlinks both the relation and its unconsumed
    // change (Peer teardown invokes this callback for every real pending row).
    node.removePeer(gifter_b);
    try std.testing.expectEqual(dependency_b, node.nextHandoffChange().?);
    waiters = node.handoffWaiters(dependency_b);
    try std.testing.expectEqual(receiver_b, waiters.next().?);
    try std.testing.expect(waiters.next() == null);
    services_b.pendingWithdrawRemoved(dependency_b);
    try std.testing.expect(node.nextHandoffChange() == null);
    node.removePeer(receiver_b);
}

test "every registration gets its own export range, owned and adopted alike" {
    const allocator = std.testing.allocator;
    // Two sessions counting exports from the same place name different objects
    // with the same number, so a capability offered to the wrong one resolves
    // silently instead of being refused. The node is what holds many sessions,
    // so it is what hands out the ranges — there is no register verb that
    // enrols a session without numbering it, and no posture that can carry or
    // overwrite a range.
    var node = engine.Node.init(allocator, [_]u8{0x71} ** 32);
    defer node.deinit();

    const a = try node.registerPeer(.{});
    const b = try node.registerPeer(.{});
    const base_a = node.peer(a).?.session_state.export_base;
    const base_b = node.peer(b).?.session_state.export_base;
    try std.testing.expect(base_a != base_b);
    try std.testing.expect(base_a >= node.peer(a).?.session_state.export_position_end or
        base_b >= node.peer(b).?.session_state.export_position_end or
        base_a + (node.peer(a).?.session_state.export_position_end - base_a) <= base_b or
        base_b + (node.peer(b).?.session_state.export_position_end - base_b) <= base_a);

    // The adopted path is the one a completion loop uses, and it goes through
    // the same door: a peer the embedder built and pinned is numbered too.
    var adopted = engine.Peer.initNegotiating(allocator);
    defer adopted.deinit();
    const c = try node.registerPeerOver(&adopted);
    try std.testing.expect(adopted.session_state.export_base != base_a);
    try std.testing.expect(adopted.session_state.export_base != base_b);

    // Every range stays under the reserved token base, so no export position
    // can ever be read as a redeemed token.
    try std.testing.expect(node.peer(a).?.session_state.export_position_end <= engine.Node.REDEEMED_TOKEN_BASE);
    try std.testing.expect(adopted.session_state.export_position_end <= engine.Node.REDEEMED_TOKEN_BASE);

    // A removed session gives its range back, so the slot bounds live sessions
    // rather than every session the node has ever registered.
    node.removePeer(c);
    var reused = engine.Peer.initNegotiating(allocator);
    defer reused.deinit();
    _ = try node.registerPeerOver(&reused);
    try std.testing.expectEqual(adopted.session_state.export_base, reused.session_state.export_base);
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
    try std.testing.expect(node.peer(a).?.giftRegistry() != node.peer(b).?.giftRegistry());

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
    try node.peer(home).?.session_state.registerImport(.from(8));
    try node.peer(home).?.session_state.registerImport(.from(9));
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
    try node.peer(home).?.session_state.registerImport(.from(4));
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

    try node.peer(home).?.session_state.registerImport(.from(5));
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
    try node.peer(elsewhere).?.session_state.registerImport(.from(8));
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
    try node.peer(elsewhere).?.session_state.registerImport(.from(4));
    const gift = try node.enrollForeign(elsewhere, .{ .far = model.FarRef.object(4) });
    try std.testing.expect(try node.interceptFulfilledRef(here, 61, gift.far.import_position.int()));
    const ask = node.nextAction().?;
    node.removePeer(elsewhere);
    const gift_id = [_]u8{0xAB} ** 32;
    try node.provideGiftId(ask.need_gift_id.ticket, &gift_id);
    const action = node.nextAction().?;
    try std.testing.expectEqual(here, action.fail.peer_id);
    try std.testing.expectEqual(@as(u64, 61), action.fail.answer);
    try std.testing.expect(std.mem.startsWith(u8, action.fail.reason.bytes(), "handoff origination failed:"));
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
    try std.testing.expectEqualStrings("handoff give names no dialable exporter locator", action.fail.reason.bytes());
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
    try std.testing.expectEqualStrings("handoff redeem failed: connection refused", first.fail.reason.bytes());
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
    try std.testing.expect(std.mem.indexOf(u8, action.fail.reason.bytes(), "unparseable") != null);
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
    try std.testing.expect(std.mem.startsWith(u8, action.fail.reason.bytes(), "handoff redeem failed:"));
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
    try std.testing.expectEqualStrings("handoff redeem failed: no such gift", broke.fail.reason.bytes());

    // A withdraw fulfilled with a non-capability breaks with the named reason.
    const give_b = try testGiveBytes(allocator);
    defer allocator.free(give_b);
    try node.acceptGive(recipient, 42, give_b, locator);
    _ = node.nextAction().?; // the flush (exporter already cached)
    const second_answer = pendingWithdrawAnswer(&node, exporter);
    try std.testing.expect(try node.claimResolve(exporter, second_answer, .not_capability));
    const refused = node.nextAction().?;
    try std.testing.expectEqualStrings("withdraw-gift did not resolve to a capability", refused.fail.reason.bytes());
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
    try node.peer(here).?.session_state.registerImport(.from(5));
    const home_here = try node.enrollForeign(here, .{ .far = model.FarRef.object(5) });
    try std.testing.expect(!try node.interceptFulfilledRef(here, 51, home_here.far.import_position.int()));
    try std.testing.expect(node.nextAction() == null);

    // A capability homed on another connection is claimed: the node asks for
    // gift-id entropy (a host effect, like dialing) rather than receiving it
    // speculatively.
    try node.peer(elsewhere).?.session_state.registerImport(.from(6));
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
    try std.testing.expect(std.mem.startsWith(u8, action.fail.reason.bytes(), "handoff origination failed:"));

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
    try node.peer(conn_a).?.session_state.registerImport(.from(1));
    try node.peer(conn_b).?.session_state.registerImport(.from(1));
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
    try node.peer(home).?.session_state.registerImport(.from(7));
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
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
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
    failing.fail_index = failing.alloc_index;
    node.removePeer(exporter);
    const failed = node.nextAction().?;
    try std.testing.expectEqual(recipient, failed.fail.peer_id);
    try std.testing.expectEqual(@as(u64, 61), failed.fail.answer);
    try std.testing.expectEqualStrings("handoff redeem failed: exporter connection closed", failed.fail.reason.bytes());
    try std.testing.expect(node.nextAction() == null);

    failing.fail_index = std.math.maxInt(usize);
    try node.acceptGive(recipient, 62, "give-again", locator);
    const redial = node.nextAction().?;
    const redial_view = node.pendingDial(redial.dial.pending).?;
    try std.testing.expectEqualStrings("tcp", redial_view.transport);
    try std.testing.expectEqualStrings("127.0.0.1:9054", redial_view.designator);
}

test "enrollForeign gives one import one token, and forgets it when the import goes" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{23} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const wire_pos: u64 = 7;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));

    // Enrolling the same import twice names it the same way both times. Minting
    // a second token would give one capability two identities — a caller
    // comparing two fetches of the same name would see different references —
    // and would leave a routing row behind on every enrollment, so a loop that
    // re-fetches would grow the node's table without bound.
    const first = try node.enrollForeign(home, .{ .far = model.FarRef.object(wire_pos) });
    const second = try node.enrollForeign(home, .{ .far = model.FarRef.object(wire_pos) });
    try std.testing.expectEqual(first.far.import_position.int(), second.far.import_position.int());
    // One row, not two.
    try std.testing.expectEqual(@as(usize, 1), node.foreign_imports.count());

    // A different import on the same session is a different capability.
    try node.peer(home).?.session_state.registerImport(.from(8));
    const other = try node.enrollForeign(home, .{ .far = model.FarRef.object(8) });
    try std.testing.expect(other.far.import_position.int() != first.far.import_position.int());

    // Releasing the import forgets its token. The partner may put a different
    // capability at that position next, and handing out the old token for it
    // would route to the capability that is gone.
    node.peer(home).?.session_state.releaseImportRetain(.from(wire_pos));
    try std.testing.expect(node.peer(home).?.session_state.foreignTokenFor(.from(wire_pos)) == null);
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const after_reuse = try node.enrollForeign(home, .{ .far = model.FarRef.object(wire_pos) });
    try std.testing.expect(after_reuse.far.import_position.int() != first.far.import_position.int());
}

test "a released import retires its node route before the partner reuses the position" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{24} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const home_peer = node.peer(home).?;
    const position: u64 = 7;
    try home_peer.session_state.registerImport(.from(position));
    try home_peer.session_state.registerImport(.from(position));

    const enrolled = try node.enrollForeign(home, .{ .far = model.FarRef.object(position) });
    const token = enrolled.far.import_position.int();
    try std.testing.expect(node.routeToken(token) != null);

    // A partial release leaves both the import and its route live.
    home_peer.session_state.releaseImportRetain(.from(position));
    node.retireReleasedToken(token);
    try std.testing.expect(node.routeToken(token) != null);

    // The final release removes the import row. The old synthetic token must
    // stop routing before the partner can put a different object at position 7.
    home_peer.session_state.releaseImportRetain(.from(position));
    try std.testing.expect(node.routeToken(token) == null);

    // Reuse can race a low-level embedder's route cleanup. The new row records
    // a different token, so the old route remains closed before it is retired.
    try home_peer.session_state.registerImport(.from(position));
    const replacement = try node.enrollForeign(home, .{ .far = model.FarRef.object(position) });
    try std.testing.expect(replacement.far.import_position.int() != token);
    try std.testing.expect(node.routeToken(replacement.far.import_position.int()) != null);
    try std.testing.expect(node.routeToken(token) == null);

    node.retireReleasedToken(token);
    try std.testing.expectEqual(@as(usize, 1), node.foreign_imports.count());
}

test "a re-enroll under the other kind is answered with the kind the row holds" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{27} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const wire_pos: u64 = 11;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));

    // The kind lives on the enrolled row, because the row is what routing reads
    // when it decides whether a token names a promise a third party can wait on.
    // Two callers can name one position with different kinds — the wire form is
    // the same either way — and idempotency means the second one gets the first
    // one's token. So the reference it gets back has to carry the row's kind and
    // not its own request, or the token and the reference describing it would
    // disagree about where the token points.
    const enrolled = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    try std.testing.expectEqual(model.RefKind.promise, enrolled.far.kind);

    const disagreeing = try node.enrollForeign(home, .{ .far = model.FarRef.object(wire_pos) });
    try std.testing.expectEqual(enrolled.far.import_position.int(), disagreeing.far.import_position.int());
    try std.testing.expectEqual(model.RefKind.promise, disagreeing.far.kind);
    try std.testing.expectEqual(@as(usize, 1), node.foreign_imports.count());

    // The tier above turns that disagreement into a refusal
    // (`driver_core.Host.enrollCapability`), so a caller never has to notice
    // that what came back is not what it asked for. This is the node's half:
    // report the row, never the request.
}

test "a churning node holds live sessions, not every session it ever registered" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{29} ** crypto.SEED_BYTES);
    defer node.deinit();

    // A host serving connections opens and closes sessions for as long as it
    // runs. What has to stay flat is what the node retains, not what it has
    // seen: a table that kept a row per session ever registered would grow for
    // the life of the process on connection churn alone.
    for (0..512) |_| {
        const id = try node.registerPeer(.{});
        node.removePeer(id);
    }
    try std.testing.expectEqual(@as(usize, 0), node.peers.count());

    // Reclaiming the row must not reclaim the id. A redeemed token's route
    // keeps naming its exporter session after that session dies, and routing
    // reads the missing peer to fail the token closed; handing the same id to a
    // later session would forward the capability onto that one instead.
    const first = try node.registerPeer(.{});
    node.removePeer(first);
    const second = try node.registerPeer(.{});
    try std.testing.expect(first != second);
    try std.testing.expect(node.peer(first) == null);
    try std.testing.expect(node.peer(second) != null);
}

test "a relayed resolution carrying a capability is introduced by handoff, not broken" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{31} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, [_]u8{37} ** crypto.SEED_BYTES);
    defer home_counterpart.deinit();
    // The recipient must be a keyed open session too: a give is addressed to
    // the recipient's session key and signed under the gifter-to-exporter one.
    var recipient_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(recipient).?, [_]u8{39} ** crypto.SEED_BYTES);
    defer recipient_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const token = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, token.far.import_position.int())).?;
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
        .wants_partial = false,
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
    try std.testing.expect(try node.consumeProxyListenerFire(home, listener, .{
        .fulfill = .{ .reference = .{ .far = model.FarRef.object(gifted) } },
    }));
    try std.testing.expect(node.peer(recipient).?.session_state.importedPromiseResolution(.from(import_pos)) == null);

    const ask = node.nextAction().?;
    const gift_id = [_]u8{0xC3} ** 32;
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
    var node = Node.init(allocator, [_]u8{47} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const first = try node.registerPeer(.{});
    const second = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, [_]u8{49} ** crypto.SEED_BYTES);
    defer home_counterpart.deinit();
    var first_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(first).?, [_]u8{51} ** crypto.SEED_BYTES);
    defer first_counterpart.deinit();
    var second_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(second).?, [_]u8{53} ** crypto.SEED_BYTES);
    defer second_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const token = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const far_id = token.far.import_position.int();

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
    try std.testing.expect(try node.consumeProxyListenerFire(home, listener, .{
        .fulfill = .{ .reference = .{ .far = model.FarRef.object(gifted) } },
    }));

    // A give is addressed to one recipient's session key and redeemed once, so
    // two recipients need two gift ids and two deposits. Sharing one id would
    // let either recipient consume the other's gift.
    var ids_asked: usize = 0;
    var next_id: u8 = 0x10;
    while (node.nextAction()) |action| {
        if (action != .need_gift_id) continue;
        const gift_id = [_]u8{next_id} ** 32;
        next_id += 1;
        ids_asked += 1;
        try node.provideGiftId(action.need_gift_id.ticket, &gift_id);
    }
    try std.testing.expectEqual(@as(usize, 2), ids_asked);

    for ([_]struct { peer: engine.PeerId, slot: u64 }{
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

test "one home promise will not be introduced to unboundedly many third parties" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{63} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, [_]u8{65} ** crypto.SEED_BYTES);
    defer home_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const token = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const far_id = token.far.import_position.int();

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

test "a relayed promise still breaks, because a handoff introduces a capability" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{57} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, [_]u8{59} ** crypto.SEED_BYTES);
    defer home_counterpart.deinit();
    var recipient_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(recipient).?, [_]u8{61} ** crypto.SEED_BYTES);
    defer recipient_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const token = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, token.far.import_position.int())).?;
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

    // The home promise settles to another promise. A handoff introduces a
    // capability the exporter can deposit and a recipient can withdraw once;
    // a promise has a settlement of its own that no gift registry models, so
    // this is not a shape a give can carry and the recipient is told so.
    const chained: u64 = 11;
    try node.peer(home).?.session_state.registerImport(.from(chained));
    try std.testing.expect(try node.consumeProxyListenerFire(home, listener, .{
        .fulfill = .{ .reference = .{ .far = model.FarRef.promise(chained) } },
    }));

    try std.testing.expect(node.nextAction() == null);
    const settled = node.peer(recipient).?.session_state.importedPromiseResolution(.from(import_pos)).?;
    try std.testing.expect(settled.* == .@"break");
    try std.testing.expect(node.peer(home).?.sessionIsOpen());
}

test "a relayed resolution carrying a sturdyref relays, because a sturdyref means the same everywhere" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{41} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, [_]u8{43} ** crypto.SEED_BYTES);
    defer home_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const token = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, token.far.import_position.int())).?;
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
    try std.testing.expect(try node.consumeProxyListenerFire(home, listener, .{
        .fulfill = .{ .reference = .{ .sturdy = sturdy } },
    }));

    const settled = node.peer(recipient).?.session_state.importedPromiseResolution(.from(import_pos)).?;
    try std.testing.expect(settled.* == .fulfill);
    try std.testing.expectEqualStrings("durable-swiss", settled.fulfill.reference.sturdy.swissnum);
}
