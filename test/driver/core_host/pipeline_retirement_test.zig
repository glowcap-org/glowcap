//! Host pipeline ownership: answer retirement releases the private actor root
//! and its independently retained destination. Event disposal alone has no
//! actor effect. Closing the owning Port must release a discarded effect.
const std = @import("std");
const glowcap = @import("glowcap");
const core = glowcap.driver.core;
const model = glowcap.ocapn.model;
const support = @import("../../support/core_host.zig");
const capture = @import("../../support/capture.zig");
const h = @import("harness.zig");
const a = std.testing.allocator;

const Gift = struct {
    target: core.Capability,

    pub fn handle(self: *Gift, turn: *core.HostTurn, _: ?[]const u8, args: core.Args) !core.Value {
        defer turn.releaseArguments(args);
        return .{ .capability = self.target };
    }
};

fn fetch(host: *core.Host, pair: h.Pair, swiss: []const u8, dials: *std.ArrayList(h.ParkedDial)) !model.Reference {
    var result: capture.CapturedRef = .{};
    try host.vowOn(try host.fetch(pair.a, swiss), .{ .ctx = &result, .func = capture.CapturedRef.record });
    try h.pumpToQuiescence(a, &.{ pair.ah, pair.bh }, &.{pair}, dials);
    return result.require();
}

/// Drive only the answering Host. The questioner deliberately leaves its
/// reply unconsumed: feeding a give to its Host would start redemption, a
/// different lifecycle from the relay's private callable being measured.
fn deliverToRelay(pair: h.Pair, dials: *std.ArrayList(h.ParkedDial)) !void {
    while (try pair.a.takeOutbound()) |value| {
        var frame = value;
        defer frame.deinit();
        try pair.bh.feed(pair.b, frame.view());
    }
    while (try h.drainActions(a, &.{pair.bh}, dials)) {}
    // The reply has left its source queue, releasing its notification carrier.
    // A questioner may GC its answer without waiting to consume that reply.
    while (try pair.b.takeOutbound()) |value| {
        var frame = value;
        frame.deinit();
    }
}

test "core host pipeline retirement releases the private actor and destination after answer GC" {
    try retirement(.serve);
}

test "core host pipeline retirement discarded event releases the destination at Port teardown" {
    try retirement(.discard);
}

fn retirement(effect: enum { serve, discard }) !void {
    // Next has explicit wire answer names, so this test can keep the exact
    // question until it deliberately sends its ordinary op:gc-answers.
    var relay = support.init(a, @splat(0xA1), h.nextRouteOptions());
    defer relay.deinit();
    const boundary = try relay.vat.spawn(h.Widget, .{});
    defer relay.vat.releaseActor(boundary.local);
    var home = support.init(a, @splat(0xA2), h.nextRouteOptions());
    defer home.deinit();
    var recipient = support.init(a, @splat(0xA3), h.nextRouteOptions());
    defer recipient.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer h.deinitParked(a, &dials);
    const home_pair = try h.openPair(a, &relay, &home, "127.0.0.1:7195", &dials);
    const recipient_pair = try h.openPair(a, &recipient, &relay, "127.0.0.1:7196", &dials);
    _ = try home.publish("destination", h.Widget, .{});
    const target = try relay.liftCapability(home_pair.a, try fetch(&relay, home_pair, "destination", &dials));
    defer relay.releaseCapabilityTerminal(target, null);
    _ = try relay.publish("gift", core.Hosting(Gift), .{ .inner = .{ .target = target } });
    const vendor = try fetch(&recipient, recipient_pair, "gift", &dials);
    const vendor_local = try recipient.node.lowerForConn(recipient_pair.a.peer_handle, vendor);
    const retained = relay.capabilities.retainCount(target).?;

    // Use the actual Port send and claim its release responsibility before
    // receiving the reply. No Host observer automatically retires this answer.
    const vow = try recipient_pair.a.served.port.send(&recipient.vat, .{ .far = vendor_local.far }, .{ .verb = "get", .args = &.{} });
    try recipient_pair.a.served.port.peer.stepToIdle();
    try std.testing.expect(recipient_pair.a.served.port.peer.session_state.claimOutboundAnswerRelease(vow.far));
    try deliverToRelay(recipient_pair, &dials);
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);

    const peer = recipient_pair.b.served.port.peer;
    const row = peer.session_state.inbound_answers.getPtr(.fromWire(vow.far.position)) orelse return error.MissingAnswer;
    const payload = row.payload orelse return error.MissingPayload;
    const pipeline = payload.pipeline_target orelse return error.MissingPipelineTarget;
    const export_position = pipeline.near.export_position;
    const actor_id = recipient_pair.b.served.port.exports.get(export_position.int()) orelse return error.MissingPrivateActor;
    try std.testing.expectEqual(@as(u64, 0), peer.session_state.exports.wireHeld(export_position));
    try std.testing.expectEqual(@as(u32, 1), relay.vat.actors.get(actor_id).?.roots);
    try std.testing.expectEqual(@as(?u64, retained + 1), relay.capabilities.retainCount(target));

    try recipient_pair.a.served.port.peer.sendBorrowed(.{ .gc_answer = .{ .positions = &.{vow.far.position.int()} } });
    try recipient_pair.a.served.port.peer.stepToIdle();
    if (effect == .serve) {
        try deliverToRelay(recipient_pair, &dials);
        try std.testing.expect(!recipient_pair.b.served.port.exports.contains(export_position.int()));
    } else {
        // Stop at the engine-to-embedding boundary so disposal is measured
        // separately from Port dispatch. Only the GC frame is in flight.
        var frames: usize = 0;
        while (try recipient_pair.a.takeOutbound()) |frame| {
            try peer.feedOwned(frame);
            frames += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), frames);
        try peer.stepToIdle();
        var retirements: usize = 0;
        while (peer.pollEvent()) |value| {
            var event = value;
            defer event.deinit();
            switch (event.kind()) {
                .release_pipeline_export => retirements += 1,
                .gc_answer => {},
                else => return error.UnexpectedEvent,
            }
        }
        try std.testing.expectEqual(@as(usize, 1), retirements);
        try std.testing.expectEqual(actor_id, recipient_pair.b.served.port.exports.get(export_position.int()).?);
        try std.testing.expectEqual(@as(?u64, retained + 1), relay.capabilities.retainCount(target));
        try relay.releaseSession(recipient_pair.b);
    }
    // Actor boxes retire at an outermost Vat boundary; enter that boundary
    // before measuring the Forwarder's destructor and target retain.
    _ = try relay.vat.near(boundary, .{ .verb = "poke", .args = &.{} });
    try std.testing.expect(!relay.vat.actors.contains(actor_id));
    try std.testing.expectEqual(@as(?u64, retained), relay.capabilities.retainCount(target));
}
