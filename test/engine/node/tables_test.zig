//! The router's own tables: the action FIFO's order and reservations,
//! registering, adopting, and detaching peers, node-owned advertised locators,
//! per-registration export ranges, and the handoff scheduler's wakes.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const codec = pancake.ocapn.codec;
const engine = pancake.ocapn.engine;
const crypto = pancake.foundation.crypto;
const LiveBytesAllocator = @import("../../support/alloc_metrics.zig").LiveBytesAllocator;

const Node = engine.Node;

test "Node action extraction preserves the inline Node footprint" {
    try std.testing.expectEqual(@as(usize, 928), @sizeOf(Node));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Node));
}

test "Node action facade preserves its supported function shapes" {
    try std.testing.expect(@TypeOf(Node.hasAction) == fn (*const Node) bool);
    try std.testing.expect(@TypeOf(Node.peekAction) == fn (*const Node) ?Node.Action);
    try std.testing.expect(@TypeOf(Node.consumePeekedAction) == fn (*Node) error{NoPendingAction}!void);
    try std.testing.expect(@TypeOf(Node.nextAction) == fn (*Node) ?Node.Action);
    try std.testing.expect(@TypeOf(Node.FailureReason.bytes) == fn (Node.FailureReason) []const u8);
}

const harness = @import("harness.zig");
const pendingWithdrawAnswer = harness.pendingWithdrawAnswer;
const peerUri = harness.peerUri;
const peerUriWithAlternatives = harness.peerUriWithAlternatives;
const takeWithdrawCount = harness.takeWithdrawCount;
const testGiveBytes = harness.testGiveBytes;
const mintRedeemedRoute = harness.mintRedeemedRoute;
const openKeyedSessionWithCounterpart = harness.openKeyedSessionWithCounterpart;

test "consume without a peeked Node action is a typed refusal" {
    var node = Node.init(std.testing.allocator, @as([crypto.SEED_BYTES]u8, @splat(0x51)));
    defer node.deinit();

    try std.testing.expectError(error.NoPendingAction, node.consumePeekedAction());
}

test "Node action drain retires each owned failure payload exactly once" {
    var live = LiveBytesAllocator{ .backing = std.testing.allocator };
    const allocator = live.allocator();
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x52)));
    try node.actions.queue.reserve(allocator, 1);
    const baseline = live.liveBytes();
    const dest: Node.FailureDestination = .{ .deferred = .{
        .recipient_peer = engine.PeerHandle.from(1),
        .id = 2,
    } };

    node.actions.queue.pushReserved(.{ .fail = .{
        .dest = dest,
        .reason = .{ .owned = try allocator.dupe(u8, "consume") },
    } });
    try std.testing.expect(node.peekAction() != null);
    try node.consumePeekedAction();
    try std.testing.expectEqual(baseline, live.liveBytes());

    try node.actions.queue.reserve(allocator, 1);
    node.actions.queue.pushReserved(.{ .fail = .{
        .dest = dest,
        .reason = .{ .owned = try allocator.dupe(u8, "borrow") },
    } });
    try std.testing.expect(node.nextAction() != null);
    try std.testing.expect(live.liveBytes() > baseline);
    try std.testing.expect(node.nextAction() == null);
    try std.testing.expectEqual(baseline, live.liveBytes());

    try node.actions.queue.reserve(allocator, 1);
    node.actions.queue.pushReserved(.{ .fail = .{
        .dest = dest,
        .reason = .{ .owned = try allocator.dupe(u8, "teardown") },
    } });
    node.deinit();
    try std.testing.expectEqual(@as(usize, 0), live.liveBytes());
}

const ReleaseProjection = struct {
    releases: usize = 0,
    last_target: ?u64 = null,

    fn seam(self: *@This()) engine.bootstrap.gifts.LocalObjectProjection {
        return .{
            .ctx = self,
            .resolve_name = resolveName,
            .capture = capture,
            .project = project,
            .rollback = rollback,
            .release_target = releaseTarget,
        };
    }

    fn resolveName(_: ?*anyopaque, _: engine.PeerHandle, _: []const u8) !?model.ExportPosition {
        return null;
    }

    fn capture(_: ?*anyopaque, _: engine.PeerHandle, _: model.ExportPosition) ?u64 {
        return null;
    }

    fn project(_: ?*anyopaque, _: engine.PeerHandle, _: u64) !engine.bootstrap.gifts.ProjectedLocalTarget {
        return error.NotProjectable;
    }

    fn rollback(_: ?*anyopaque, _: engine.PeerHandle, _: u64, _: engine.bootstrap.gifts.ProjectedLocalTarget) void {}

    fn releaseTarget(ctx: ?*anyopaque, target: u64) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.releases += 1;
        self.last_target = target;
    }
};

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
    const rows = 2 * engine.testing.queue_retain_bytes / @sizeOf(u64);
    try fifo.reserve(allocator, rows);
    const reserved = fifo.list.capacity;
    try std.testing.expect(reserved * @sizeOf(u64) > engine.testing.queue_retain_bytes);

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
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(8)));

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

test "detaching borrowed peers releases Node-projected gift roots exactly once" {
    const allocator = std.testing.allocator;

    {
        var projection: ReleaseProjection = .{};
        var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x19)));
        defer node.deinit();
        node.setLocalObjectProjection(projection.seam());
        var adopted = engine.Peer.initNegotiating(allocator);
        defer adopted.deinit();
        const id = try node.registerPeerOver(&adopted);
        try adopted.giftRegistry().depositLocalTarget(
            allocator,
            adopted.session_state.limits,
            node.localObjectProjection(),
            "removed",
            0xfeed,
        );

        node.removePeer(id);
        try std.testing.expectEqual(@as(usize, 1), projection.releases);
        try std.testing.expectEqual(@as(?u64, 0xfeed), projection.last_target);
        try std.testing.expect(!adopted.giftRegistry().giftLive("removed"));
        try std.testing.expect(adopted.node_services == null);
    }

    {
        var projection: ReleaseProjection = .{};
        var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x1a)));
        node.setLocalObjectProjection(projection.seam());
        var adopted = engine.Peer.initNegotiating(allocator);
        defer adopted.deinit();
        _ = try node.registerPeerOver(&adopted);
        try adopted.giftRegistry().depositLocalTarget(
            allocator,
            adopted.session_state.limits,
            node.localObjectProjection(),
            "node-deinit",
            0xcafe,
        );

        node.deinit();
        try std.testing.expectEqual(@as(usize, 1), projection.releases);
        try std.testing.expectEqual(@as(?u64, 0xcafe), projection.last_target);
        try std.testing.expect(!adopted.giftRegistry().giftLive("node-deinit"));
        try std.testing.expect(adopted.node_services == null);
    }
}

test "failed adopted registration severs the borrowed Node services link" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x18)));
    defer node.deinit();
    var adopted = engine.Peer.initNegotiating(allocator);
    defer adopted.deinit();

    try std.testing.expectError(error.OutOfMemory, node.registerPeerOver(&adopted));
    try std.testing.expect(adopted.node_services == null);
}

test "peer handle exhaustion rejects owned and borrowed registration before acquiring resources" {
    var live = LiveBytesAllocator{ .backing = std.testing.allocator };
    const allocator = live.allocator();
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x1b)));
    defer node.deinit();
    node.next_peer_handle = std.math.maxInt(u64);

    const owned_baseline = live.liveBytes();
    try std.testing.expectError(error.CapabilitySpaceExhausted, node.registerPeer(.{}));
    try std.testing.expectEqual(owned_baseline, live.liveBytes());
    try std.testing.expectEqual(@as(usize, 0), node.peers.count());
    try std.testing.expectEqual(@as(usize, 0), node.export_base_return_reservations);

    var adopted = engine.Peer.initNegotiating(allocator);
    defer adopted.deinit();
    const original_export_base = adopted.session_state.export_base;
    const borrowed_baseline = live.liveBytes();
    try std.testing.expectError(error.CapabilitySpaceExhausted, node.registerPeerOver(&adopted));
    try std.testing.expectEqual(borrowed_baseline, live.liveBytes());
    try std.testing.expect(adopted.node_services == null);
    try std.testing.expectEqual(original_export_base, adopted.session_state.export_base);
    try std.testing.expectEqual(@as(usize, 0), node.peers.count());
    try std.testing.expectEqual(@as(usize, 0), node.export_base_return_reservations);
}

test "advertised locators are node-owned snapshots keyed by transport" {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x31)));
    defer node.deinit();

    var transport = [_]u8{ 'i', 'r', 'o', 'h' };
    var designator = [_]u8{ 'n', 'o', 'd', 'e', '-', 'a' };
    var hint_name = [_]u8{ 'd', 'i', 'r', 'e', 'c', 't', '-', 'a', 'd', 'd', 'r', 'e', 's', 's', 'e', 's' };
    var hint_value = [_]u8{ '1', '2', '7', '.', '0', '.', '0', '.', '1' };
    var hints = [_]model.HintEntry{.{
        .name = &hint_name,
        .value = .{ .string = &hint_value },
    }};
    try node.setAdvertisedLocator(.{
        .transport = &transport,
        .designator = &designator,
        .hints = .{ .entries = &hints },
    });

    transport[0] = 'x';
    designator[0] = 'X';
    hint_name[0] = 'X';
    hint_value[0] = '9';
    hints[0].value = .{ .integer = 7 };

    const first = node.advertisedLocator("iroh").?;
    try std.testing.expectEqualStrings("iroh", first.transport);
    try std.testing.expectEqualStrings("node-a", first.designator);
    try std.testing.expectEqualStrings("direct-addresses", first.hints.entries[0].name);
    try std.testing.expectEqualStrings("127.0.0.1", first.hints.entries[0].value.string);
    try std.testing.expect(node.advertisedLocator("xroh") == null);
    try std.testing.expectEqualStrings("node-a", node.acceptableLocator().?.designator);

    // A borrowed snapshot is legal input to replacement. The transaction must
    // select the new owned key before releasing the allocation this view names.
    try node.setAdvertisedLocator(first);
    const republished = node.advertisedLocator("iroh").?;
    try std.testing.expectEqualStrings("iroh", republished.transport);
    try std.testing.expectEqualStrings("node-a", republished.designator);
    try std.testing.expectEqualStrings("node-a", node.acceptableLocator().?.designator);

    // Publishing another transport cannot invalidate this borrowed value.
    try node.setAdvertisedLocator(.{
        .transport = "webrtc",
        .designator = "peer-b",
        .hints = model.Hints.emptyFalse(),
    });
    try std.testing.expectEqualStrings("node-a", republished.designator);
    try std.testing.expectEqualStrings("peer-b", node.acceptableLocator().?.designator);

    // An automatically prepared dial route is retained without replacing the
    // route deployment policy selected explicitly.
    try node.ensureAdvertisedLocator(.{
        .transport = "tcp",
        .designator = "127.0.0.1:0",
        .hints = model.Hints.emptyFalse(),
    });
    try std.testing.expectEqualStrings("peer-b", node.acceptableLocator().?.designator);

    try node.setAdvertisedLocator(.{
        .transport = "iroh",
        .designator = "node-c",
        .hints = model.Hints.emptyFalse(),
    });
    const replacement = node.advertisedLocator("iroh").?;
    try std.testing.expectEqualStrings("node-c", replacement.designator);
    try std.testing.expectEqual(model.Hints.WireForm.boolean_false, replacement.hints.wire_form);
    try std.testing.expectEqualStrings("peer-b", node.advertisedLocator("webrtc").?.designator);
    try std.testing.expectEqualStrings("node-c", node.acceptableLocator().?.designator);

    node.removeAdvertisedLocator("iroh");
    try std.testing.expect(node.advertisedLocator("iroh") == null);
    try std.testing.expect(node.acceptableLocator() == null);
    // Ensuring a retained fallback selects it only because removal left no
    // acceptable location; selection never depends on hash-map order.
    try node.ensureAdvertisedLocator(.{
        .transport = "webrtc",
        .designator = "ignored-existing-value",
        .hints = model.Hints.emptyFalse(),
    });
    try std.testing.expectEqualStrings("peer-b", node.acceptableLocator().?.designator);
    node.removeAdvertisedLocator("iroh");
}

test "advertised locator replacement is transactional across allocator failures" {
    var fail_offset: usize = 0;
    var reached_success = false;
    while (fail_offset < 16) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x32)));
        defer node.deinit();

        try node.setAdvertisedLocator(.{
            .transport = "iroh",
            .designator = "old-node",
            .hints = .{ .entries = &.{.{
                .name = "direct-addresses",
                .value = .{ .string = "old-address" },
            }} },
        });
        failing.fail_index = failing.alloc_index + fail_offset;

        const result = node.setAdvertisedLocator(.{
            .transport = "iroh",
            .designator = "new-node",
            .hints = .{ .entries = &.{.{
                .name = "direct-addresses",
                .value = .{ .string = "new-address" },
            }} },
        });
        if (result) |_| {
            reached_success = true;
            try std.testing.expectEqualStrings("new-node", node.advertisedLocator("iroh").?.designator);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            const preserved = node.advertisedLocator("iroh").?;
            try std.testing.expectEqualStrings("old-node", preserved.designator);
            try std.testing.expectEqualStrings("old-address", preserved.hints.entries[0].value.string);
            try std.testing.expectEqualStrings("old-node", node.acceptableLocator().?.designator);
        }
    }
    try std.testing.expect(reached_success);
}

test "handoff scheduler releases its backing at total quiescence" {
    var live = LiveBytesAllocator{ .backing = std.testing.allocator };
    const allocator = live.allocator();
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x19)));
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
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(9)));
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
    var node = engine.Node.init(allocator, @as([32]u8, @splat(0x71)));
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

    // Export ranges remain disjoint from one another; capability routes are a
    // separate type and impose no numeric ceiling on them.
    try std.testing.expect(node.peer(a).?.session_state.export_position_end <= node.export_base_end);
    try std.testing.expect(adopted.session_state.export_position_end <= node.export_base_end);

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
    var node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(7)));
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
