//! Projected promise pipelines use the embedder's private local callable,
//! while listeners still receive a directly redeemable handoff.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const Node = engine.Node;
const harness = @import("harness.zig");
const projection_support = @import("../../support/projection.zig");
const openKeyedSessionWithCounterpart = harness.openKeyedSessionWithCounterpart;

const PipelineEmbedding = struct {
    node: *Node,
    near: ?model.NearRef = null,
    route: ?model.CapabilityRouteId = null,
    refuse: bool = false,

    fn prepare(ctx: ?*anyopaque, recipient: engine.PeerHandle, route: model.CapabilityRouteId, _: ?u64) engine.node_services.OutboundStagingError!Node.PipelineProjection.Result {
        const self: *PipelineEmbedding = @ptrCast(@alignCast(ctx.?));
        if (self.refuse) return error.OutOfMemory;
        const position = try self.node.peer(recipient).?.session_state.allocateExport();
        self.near = model.NearRef.object(position.int());
        self.route = route;
        return .{ .near = self.near.?, .target = route.int() };
    }
};

test "a relayed resolution carrying a capability is introduced by handoff, not broken" {
    try relayPipeline(false, false);
}

test "pipeline callable construction refusal cancels its promised retirement seat" {
    try relayPipeline(true, false);
}

test "pipeline callable staging retires its reserved seat when the source session disappears" {
    try relayPipeline(false, true);
}

fn relayPipeline(refuse: bool, source_loss: bool) !void {
    const allocator = std.testing.allocator;
    var node = Node.init(allocator, @as([crypto.seed_bytes]u8, @splat(31)));
    defer node.deinit();
    var embedding = PipelineEmbedding{ .node = &node, .refuse = refuse };
    node.pipeline_projection = .{ .ctx = &embedding, .prepare = PipelineEmbedding.prepare };

    const home = try node.registerPeer(.{});
    const recipient = try node.registerPeer(.{});
    var home_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(home).?, @as([crypto.seed_bytes]u8, @splat(37)));
    defer home_counterpart.deinit();
    // The recipient must be a keyed open session too: a give is addressed to
    // the recipient's session key and signed under the gifter-to-exporter one.
    var recipient_counterpart = try openKeyedSessionWithCounterpart(allocator, &node, node.peer(recipient).?, @as([crypto.seed_bytes]u8, @splat(39)));
    defer recipient_counterpart.deinit();

    const wire_pos: u64 = 4;
    try node.peer(home).?.session_state.registerImport(.from(wire_pos));
    const route = try node.enrollForeign(home, model.FarRef.promise(wire_pos));
    const rewritten = (try node.proxyForeignPromiseFulfill(recipient, route.routed.id)).?;
    const import_pos = rewritten.near.export_position.int();
    // Hold the projection as the partner would once its message is sent.
    node.peer(recipient).?.session_state.exports.retain(.from(import_pos));
    // Arming the proxy queues the home session's flush: the `op:listen` it
    // enqueued rides a session no verb here is driving. This test steps that
    // peer by hand below, so the notice is drained rather than acted on.
    try std.testing.expectEqual(home, node.nextAction().?.flush);

    // The recipient listens on the promise it was introduced to, the way a
    // real partner does: sender `.far` becomes a wire `<desc:export>`, which
    // this side receives as `.near`. Without this there is no fire to carry
    // the give, and storing it would prove nothing a partner could observe.
    node.peer(recipient).?.session_state.exports.retain(.from(import_pos));
    try recipient_counterpart.session_state.registerImport(.from(import_pos));
    try recipient_counterpart.session_state.registerExport(.from(9));
    try recipient_counterpart.sendBorrowed(.{ .listen = .{
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

    // A call accepted before settlement must reach the same object the
    // listener's give names. A tell has no reply that could mask its loss.
    try recipient_counterpart.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(import_pos) },
        .args = &.{.{ .symbol = "pipeline-call" }},
    } });
    try recipient_counterpart.stepToIdle();
    try node.peer(recipient).?.feedOwned(recipient_counterpart.takeOutbound().?);
    try node.peer(recipient).?.stepToIdle();

    try std.testing.expectEqual(engine.StepOutcome.progress, try node.peer(home).?.step());
    const listener = blk: {
        var frame = node.peer(home).?.takeOutbound().?;
        defer frame.deinit();
        const view = try glowcap.ocapn.codec.syrup.decodeBody(frame.view());
        break :blk view.listen.listener.far.import_position.int();
    };

    // The home promise settles to a capability rather than to bytes. The
    // number means something only in the home conversation, so it cannot be
    // stored on the recipient as it stands. The protocol's answer is to
    // introduce it: the node asks for gift-id entropy rather than settling.
    const gifted: u64 = 9;
    try node.peer(home).?.session_state.registerImport(.from(gifted));
    const gifted_route = try node.enrollForeign(home, model.FarRef.object(gifted));
    try std.testing.expect(node.consumeProjectedProxyListenerFire(home, listener, .{
        .fulfill = .{ .reference = gifted_route },
    }));
    if (refuse) {
        const failed = projection_support.resolution(&node.peer(recipient).?.session_state, .from(import_pos)).?;
        try std.testing.expect(failed.* == .@"break");
        try std.testing.expectEqual(@as(usize, 0), node.peer(recipient).?.events.reservations);
        try std.testing.expectEqual(@as(usize, 0), node.inline_passable_batches.rows.count());
        return;
    }
    try std.testing.expect(projection_support.resolution(&node.peer(recipient).?.session_state, .from(import_pos)) == null);

    const ask = node.nextAction().?;
    const gift_id = @as([32]u8, @splat(0xC3));
    if (source_loss) {
        try std.testing.expectEqual(@as(usize, 1), node.peer(recipient).?.events.reservations);
        node.removePeer(recipient);
        try std.testing.expect(!node.hasPendingGift(ask.need_gift_id.ticket));
        try node.provideGiftId(ask.need_gift_id.ticket, &gift_id);
        return;
    }
    try node.provideGiftId(ask.need_gift_id.ticket, &gift_id);

    // The recipient's promise now settles with a signed give it can redeem by
    // dialing the exporter, which is the reachable outcome a break was not.
    const settled = projection_support.resolution(&node.peer(recipient).?.session_state, .from(import_pos)).?;
    try std.testing.expect(settled.* == .fulfill);
    try std.testing.expect(settled.fulfill == .handoff);
    try std.testing.expect(settled.fulfill.handoff.* == .give);

    // Storing it is not the claim that matters, reaching the recipient is.
    // Drain the fire the listener installed above and read the give back off
    // the wire, which is the only evidence a real partner would ever see.
    while ((try node.peer(recipient).?.step()) != .idle) {}
    // Collect the published promise before serving its already-accepted call.
    // Retirement must follow that call in the same event FIFO, and the
    // private callable has never granted separate wire authority.
    try std.testing.expectEqual(@as(u64, 0), node.peer(recipient).?.session_state.exports.wireHeld(embedding.near.?.export_position));
    try node.peer(recipient).?.session_state.recordRecv(.{ .gc_export = .{
        .positions = &.{import_pos},
        .deltas = &.{2},
    } });
    node.peer(recipient).?.session_state.collectLocalPromiseProjectionsNow();
    // A sans-io Node surfaces local invocation to its composition. This
    // fixture forwards that invocation; Host supplies the owning actor path.
    var replay = node.peer(recipient).?.pollEvent() orelse return error.MissingPipeline;
    defer replay.deinit();
    var invocation = try replay.decodeOwned(allocator);
    defer model.freeMessage(allocator, invocation);
    try std.testing.expectEqual(embedding.near.?.export_position, invocation.deliver.target.near.export_position);
    const destination = node.routeReference(recipient, .{ .routed = .{ .id = embedding.route.?, .kind = .object } }).?;
    invocation.deliver.target = destination.target;
    try node.peer(destination.peer_handle).?.sendBorrowed(invocation);
    var retirement = node.peer(recipient).?.pollEvent() orelse return error.MissingRetirement;
    defer retirement.deinit();
    try std.testing.expect(retirement.kind() == .release_pipeline_export);
    try std.testing.expectEqual(embedding.near.?.export_position, retirement.payload.release_pipeline_export.near.export_position);
    try std.testing.expectEqual(@as(usize, 0), node.peer(recipient).?.events.reservations);
    var fired = false;
    while (node.peer(recipient).?.takeOutbound()) |frame_const| {
        var frame = frame_const;
        defer frame.deinit();
        const view = try glowcap.ocapn.codec.syrup.decodeBody(frame.view());
        if (view != .deliver) continue;
        if (try view.deliver.args.len() != 2) continue;
        const tag = try view.deliver.args.at(0);
        if (tag != .symbol or !std.mem.eql(u8, tag.symbol, "fulfill")) continue;
        const payload = try view.deliver.args.at(1);
        try std.testing.expect(payload == .handoff);
        const handoff = try payload.handoff.project();
        try std.testing.expect(handoff == .give);
        try std.testing.expectEqualStrings(&gift_id, handoff.give.gift_id);
        fired = true;
    }
    try std.testing.expect(fired);

    // And the exporter side of the handoff is real: the deposit naming the
    // gifted capability is on the home wire under the same gift id.
    try node.peer(home).?.stepToIdle();
    var deposited = false;
    var called = false;
    while (node.peer(home).?.takeOutbound()) |frame_const| {
        var frame = frame_const;
        defer frame.deinit();
        const view = try glowcap.ocapn.codec.syrup.decodeBody(frame.view());
        // A deposit is a bootstrap deliver, not an `op:handoff`: the gifter
        // asks the exporter's bootstrap object to hold the capability under
        // the gift id, and the exporter answers a later `withdraw-gift`.
        if (view != .deliver) continue;
        const verb = try view.deliver.args.at(0);
        if (verb == .symbol and std.mem.eql(u8, verb.symbol, "pipeline-call")) {
            try std.testing.expectEqual(gifted, view.deliver.target.near.export_position.int());
            called = true;
            continue;
        }
        if (try view.deliver.args.len() != 3) continue;
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
    try std.testing.expect(called);

    // And the home session is untouched. It fulfilled a promise, which the
    // protocol permits; tearing it down would punish it for our limit.
    try std.testing.expect(node.peer(home).?.sessionIsOpen());
    // Extracted wire and private events own no Peer/Session/Node borrow.
    node.removePeer(recipient);
    try std.testing.expectEqualStrings("pipeline-call", (try replay.view().deliver.args.at(0)).symbol);
    try std.testing.expect(retirement.kind() == .release_pipeline_export);
}

test "pipeline retirement event reservations survive idle trims and publish without allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var peer = engine.Peer.init(failing.allocator());
    defer peer.deinit();
    try peer.events.reserve(peer.allocator);
    const event: engine.Event = .{
        .payload = .{ .release_pipeline_export = .{ .near = model.NearRef.object(7), .target = 8 } },
        .codec = .syrup,
        .captp_version = peer.session_state.captp_version,
        .allocator = peer.allocator,
    };
    // Grow beyond the ordinary queue's retained-byte budget, then observe it
    // empty twice. Neither observation may spend the promised future seat.
    for (0..64) |_| try peer.events.push(peer.allocator, event);
    while (peer.pollEvent()) |owned| {
        var item = owned;
        item.deinit();
    }
    try std.testing.expect(peer.pollEvent() == null);
    failing.fail_index = failing.alloc_index;
    peer.events.pushReserved(event);
    var retired = peer.pollEvent().?;
    retired.deinit();
    try std.testing.expectEqual(@as(usize, 0), peer.events.reservations);
}
