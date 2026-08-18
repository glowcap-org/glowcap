//! Route identity and enrollment: a fetched foreign import is enrolled under
//! a node-unique route, lowerForConn swaps a route only on its home,
//! exporter-location overrides record and roll back, and a released import
//! retires its route before the partner reuses the position.

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

test "interceptFulfilledRoute claims only a foreign-home reply, entropy as an effect" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{12} ** crypto.SEED_BYTES);
    defer node.deinit();

    const here = try node.registerPeer(.{});
    const elsewhere = try node.registerPeer(.{});

    // No enrollment, or a home on this very connection: not claimed, the embedder
    // resolves the reply itself — and no entropy is ever requested for an ordinary
    // reply. A route homed here is returned to its own owner, so the chokepoint
    // lowers it and no re-gift is needed.
    try std.testing.expect(!try node.interceptFulfilledRoute(here, 51, .from(5)));
    try node.peer(here).?.session_state.registerImport(.from(5));
    const home_here = try node.enrollForeign(here, .{ .far = model.FarRef.object(5) });
    try std.testing.expect(!try node.interceptFulfilledRoute(here, 51, home_here.routed.id));
    try std.testing.expect(node.nextAction() == null);

    // A capability homed on another connection is claimed: the node asks for
    // gift-id entropy (a host effect, like dialing) rather than receiving it
    // speculatively.
    try node.peer(elsewhere).?.session_state.registerImport(.from(6));
    const home_else = try node.enrollForeign(elsewhere, .{ .far = model.FarRef.object(6) });
    try std.testing.expect(try node.interceptFulfilledRoute(here, 52, home_else.routed.id));
    const ask = node.nextAction().?;
    const ticket = ask.need_gift_id.ticket;

    // The sessions here are not open, so the origination fails closed into a
    // broken answer rather than a mis-encoded cross-connection reference; the
    // live positive proof is the `*-goblins-gift` matrix.
    const gift_id = [_]u8{0xCD} ** 32;
    try node.provideGiftId(ticket, &gift_id);
    const action = node.nextAction().?;
    try std.testing.expectEqual(
        model.AnswerName.fromWire(.from(52)),
        action.fail.dest.served_answer.answer,
    );
    try std.testing.expect(std.mem.startsWith(u8, action.fail.reason.bytes(), "handoff origination failed:"));

    // A settled ticket is retired: answering it again is a no-op.
    try node.provideGiftId(ticket, &gift_id);
    try std.testing.expect(node.nextAction() == null);
}

test "a fetched foreign import is enrolled under a node-unique route; two at one position never collide and each routes home (ADR-0069)" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{18} ** crypto.SEED_BYTES);
    defer node.deinit();

    const conn_a = try node.registerPeer(.{});
    const conn_b = try node.registerPeer(.{});

    // Two capabilities fetched over different connections land at the SAME wire
    // position (imports are numbered per session). Enrolling each yields a
    // distinct node-unique route, so the node-global collision the old
    // position-keyed home map had — where the second fetch clobbered the first —
    // cannot happen.
    const wire: model.Reference = .{ .far = model.FarRef.object(1) };
    try node.peer(conn_a).?.session_state.registerImport(.from(1));
    try node.peer(conn_b).?.session_state.registerImport(.from(1));
    const route_a = try node.enrollForeign(conn_a, wire);
    const route_b = try node.enrollForeign(conn_b, wire);
    const a = route_a.routed.id;
    const b = route_b.routed.id;
    try std.testing.expect(a != b);

    // Each route resolves to its OWN home and real wire reference. This
    // is the same swap the served-reply interceptor uses to keep a route off the
    // wire when a fetched capability is returned to its own owner.
    const ra = node.routeReference(conn_a, route_a).?;
    try std.testing.expectEqual(conn_a, ra.peer_id);
    try std.testing.expectEqual(@as(u64, 1), ra.target.far.import_position.int());
    const rb = node.routeReference(conn_b, route_b).?;
    try std.testing.expectEqual(conn_b, rb.peer_id);
    try std.testing.expectEqual(@as(u64, 1), rb.target.far.import_position.int());

    // In argument position each route is native on its home, foreign elsewhere.
    try std.testing.expect(!node.argIsForeign(conn_a, route_a));
    try std.testing.expect(node.argIsForeign(conn_b, route_a));
    try std.testing.expect(!node.argIsForeign(conn_b, route_b));
    try std.testing.expect(node.argIsForeign(conn_a, route_b));

    // A served reply returning a route on its OWN home is not re-gifted (the
    // interceptor lowers it); returned elsewhere it would be. Same-home returns
    // false and queues nothing — proving each route's home is its own connection,
    // not the last one enrolled.
    try std.testing.expect(!try node.interceptFulfilledRoute(conn_a, 70, a));
    try std.testing.expect(!try node.interceptFulfilledRoute(conn_b, 71, b));
    try std.testing.expect(node.nextAction() == null);

    // Reclamation + fail-closed: closing conn_a reclaims route_a's enrollment, and
    // using the retired route fails closed rather than leaking the local id
    // onto the wire. route_b, whose home is live, still routes.
    node.removePeer(conn_a);
    try std.testing.expect(node.routeReference(conn_b, route_a) == null);
    try std.testing.expectEqual(conn_b, node.routeReference(conn_b, route_b).?.peer_id);
}

test "lowerForConn swaps a route to its wire reference on its home and fails closed elsewhere (ADR-0069)" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{21} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const other = try node.registerPeer(.{});

    // A plain wire reference is the fast path:
    // it lowers to itself with no lookup, on any connection.
    const plain: model.Reference = .{ .far = model.FarRef.object(4) };
    try std.testing.expectEqual(@as(u64, 4), (try node.lowerForConn(home, plain)).far.import_position.int());
    try std.testing.expectEqual(@as(u64, 4), (try node.lowerForConn(other, plain)).far.import_position.int());
    // A near reference is not a route either; it passes through untouched.
    const near: model.Reference = .{ .near = .{ .export_position = .from(2) } };
    try std.testing.expect((try node.lowerForConn(home, near)) == .near);

    // A foreign-import route lowers to its real wire import on its home
    // connection — this is the swap the outbound chokepoint (`Peer.send`) makes so
    // the route never reaches the wire — and fails closed on any other connection,
    // where it has no wire name.
    try node.peer(home).?.session_state.registerImport(.from(7));
    const route = try node.enrollForeign(home, .{ .far = model.FarRef.object(7) });
    try std.testing.expectEqual(@as(u64, 7), (try node.lowerForConn(home, route)).far.import_position.int());
    try std.testing.expectError(error.RouteNotLowerable, node.lowerForConn(other, route));

    // Enrolling the first route latched the walk gate on; a node that never
    // fetched a foreign capability leaves it off so every send skips the walk.
    try std.testing.expect(node.route_lowering_active);

    // A fabricated routed id has no route and fails closed. The same integer in
    // a `.far` remains an ordinary wire import and never aliases it.
    const ghost: model.Reference = .{ .routed = .{ .id = .from(999) } };
    try std.testing.expectError(error.RouteNotLowerable, node.lowerForConn(home, ghost));
    const wire_same_id: model.Reference = .{ .far = model.FarRef.object(999) };
    try std.testing.expectEqual(@as(u64, 999), (try node.lowerForConn(home, wire_same_id)).far.import_position.int());
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

test "setExporterLocation preserves the previous route when replacement allocation fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var node = Node.init(allocator, [_]u8{0x44} ** crypto.SEED_BYTES);
    defer node.deinit();
    defer failing.fail_index = std.math.maxInt(usize);

    const conn = try node.registerPeer(.{});
    const first = try model.uri.parsePeer(allocator, "ocapn://127.0.0.1%3A7001.tcp");
    defer model.freePeerLocator(allocator, first);
    try node.setExporterLocation(conn, first);
    const preserved = try allocator.dupe(u8, node.exporter_locations.get(conn).?);
    defer allocator.free(preserved);

    const replacement = try model.uri.parsePeer(allocator, "ocapn://127.0.0.1%3A7002.tcp");
    defer model.freePeerLocator(allocator, replacement);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, node.setExporterLocation(conn, replacement));
    try std.testing.expectEqualSlices(u8, preserved, node.exporter_locations.get(conn).?);
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
    try std.testing.expectEqual(recipient, failed.fail.dest.answer.recipient_peer);
    try std.testing.expectEqual(@as(u64, 61), failed.fail.dest.answer.answer.int());
    try std.testing.expectEqualStrings("handoff redeem failed: exporter connection closed", failed.fail.reason.bytes());
    try std.testing.expect(node.nextAction() == null);

    failing.fail_index = std.math.maxInt(usize);
    try node.acceptGive(recipient, 62, "give-again", locator);
    const redial = node.nextAction().?;
    const redial_view = node.pendingDial(redial.dial.pending).?;
    try std.testing.expectEqualStrings("tcp", redial_view.transport);
    try std.testing.expectEqualStrings("127.0.0.1:9054", redial_view.designator);
}

test "enrollForeign gives one import one route identity, and forgets it when the import goes" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{23} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const wire_pos: u64 = 7;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));

    // Enrolling the same import twice names it the same way both times. Minting
    // a second route id would give one capability two identities — a caller
    // comparing two fetches of the same name would see different references —
    // and would leave a routing row behind on every enrollment, so a loop that
    // re-fetches would grow the node's table without bound.
    const first = try node.enrollForeign(home, .{ .far = model.FarRef.object(wire_pos) });
    const second = try node.enrollForeign(home, .{ .far = model.FarRef.object(wire_pos) });
    try std.testing.expectEqual(first.routed.id, second.routed.id);
    // One row, not two.
    try std.testing.expectEqual(@as(usize, 1), node.foreign_imports.count());

    // A different import on the same session is a different capability.
    try node.peer(home).?.session_state.registerImport(.from(8));
    const other = try node.enrollForeign(home, .{ .far = model.FarRef.object(8) });
    try std.testing.expect(other.routed.id != first.routed.id);

    // Releasing the import forgets its route id. The partner may put a different
    // capability at that position next, and handing out the old id for it
    // would route to the capability that is gone.
    node.peer(home).?.session_state.releaseImportRetain(.from(wire_pos));
    try std.testing.expect(node.peer(home).?.session_state.foreignRouteIdFor(.from(wire_pos)) == null);
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const after_reuse = try node.enrollForeign(home, .{ .far = model.FarRef.object(wire_pos) });
    try std.testing.expect(after_reuse.routed.id != first.routed.id);
}

test "a prepared foreign enrollment rolls back before publication" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, [_]u8{31} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    const position = model.ImportPosition.from(7);
    try node.peer(home).?.session_state.registerImport(position);

    const prepared = try node.prepareForeignEnrollment(home, .{ .far = model.FarRef.object(position.int()) });
    const rollback = prepared.rollback orelse return error.MissingRollbackAuthority;
    try std.testing.expectEqual(@as(usize, 1), node.foreign_imports.count());
    try std.testing.expectEqual(rollback.route_id, node.peer(home).?.session_state.foreignRouteIdFor(position).?);
    try std.testing.expect(node.route_lowering_active);

    node.rollbackForeignEnrollment(rollback);
    try std.testing.expectEqual(@as(usize, 0), node.foreign_imports.count());
    try std.testing.expect(node.peer(home).?.session_state.foreignRouteIdFor(position) == null);
    try std.testing.expect(node.routeCapability(rollback.route_id) == null);
    try std.testing.expect(!node.route_lowering_active);
}

test "foreign enrollment requires a live import row" {
    var node = Node.init(std.testing.allocator, [_]u8{32} ** crypto.SEED_BYTES);
    defer node.deinit();

    const home = try node.registerPeer(.{});
    try std.testing.expectError(
        error.UnknownImport,
        node.prepareForeignEnrollment(home, .{ .far = model.FarRef.object(7) }),
    );
    try std.testing.expectEqual(@as(usize, 0), node.foreign_imports.count());
    try std.testing.expect(!node.route_lowering_active);
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
    const route_id = enrolled.routed.id;
    try std.testing.expect(node.routeCapability(route_id) != null);
    try std.testing.expect(node.redeemedRouteId(enrolled) == null);

    // A partial release leaves both the import and its route live.
    home_peer.session_state.releaseImportRetain(.from(position));
    node.retireReleasedRoute(route_id);
    try std.testing.expect(node.routeCapability(route_id) != null);

    // The final release removes the import row. The old route must
    // stop routing before the partner can put a different object at position 7.
    home_peer.session_state.releaseImportRetain(.from(position));
    try std.testing.expect(node.routeCapability(route_id) == null);

    // Reuse can race a low-level embedder's route cleanup. The new row records
    // a different id, so the old route remains closed before it is retired.
    try home_peer.session_state.registerImport(.from(position));
    const replacement = try node.enrollForeign(home, .{ .far = model.FarRef.object(position) });
    try std.testing.expect(replacement.routed.id != route_id);
    try std.testing.expect(node.routeCapability(replacement.routed.id) != null);
    try std.testing.expect(node.routeCapability(route_id) == null);

    node.retireReleasedRoute(route_id);
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
    // when it decides whether a route names a promise a third party can wait on.
    // Two callers can name one position with different kinds — the wire form is
    // the same either way — and idempotency means the second one gets the first
    // one's route. So the reference it gets back has to carry the row's kind and
    // not its own request, or the id and the reference describing it would
    // disagree about where the route points.
    const enrolled = try node.enrollForeign(home, .{ .far = model.FarRef.promise(wire_pos) });
    try std.testing.expectEqual(model.RefKind.promise, enrolled.routed.kind);

    const disagreeing = try node.enrollForeign(home, .{ .far = model.FarRef.object(wire_pos) });
    try std.testing.expectEqual(enrolled.routed.id, disagreeing.routed.id);
    try std.testing.expectEqual(model.RefKind.promise, disagreeing.routed.kind);
    try std.testing.expectEqual(@as(usize, 1), node.foreign_imports.count());

    // Host capability lifting turns that disagreement into
    // `ImportKindConflict`, so an owning-tier caller never receives a handle
    // whose kind differs from the observation that produced it. This is the
    // node's half: report the row, never the request.
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

    // Reclaiming the row must not reclaim the id. A redeemed route
    // keeps naming its exporter session after that session dies, and routing
    // reads the missing peer to fail the route closed; handing the same id to a
    // later session would forward the capability onto that one instead.
    const first = try node.registerPeer(.{});
    node.removePeer(first);
    const second = try node.registerPeer(.{});
    try std.testing.expect(first != second);
    try std.testing.expect(node.peer(first) == null);
    try std.testing.expect(node.peer(second) != null);
}
