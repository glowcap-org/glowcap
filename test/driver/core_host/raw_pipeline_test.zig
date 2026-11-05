//! Raw Actors replies copy a home import into the canonical Host owner without
//! consuming the raw caller's wire retain. Queued and late calls keep working.
const std = @import("std");
const glowcap = @import("glowcap");
const core = glowcap.driver.core;
const model = glowcap.ocapn.model;
const support = @import("../../support/core_host.zig");
const h = @import("harness.zig");
const a = std.testing.allocator;

const Counter = struct {
    calls: *usize,
    pub fn handle(self: *Counter, _: *glowcap.actors.Turn, _: glowcap.actors.Delivery) !model.Argument {
        self.calls.* += 1;
        return .{ .integer = @intCast(self.calls.*) };
    }
};

fn fetch(host: *core.Host, pair: h.Pair, swiss: []const u8, dials: *std.ArrayList(h.ParkedDial)) !model.Reference {
    var result: h.CapturedRef = .{};
    try host.vowOn(try host.fetch(pair.a, swiss), .{ .ctx = &result, .func = h.CapturedRef.record });
    try h.pumpToQuiescence(a, &.{ pair.ah, pair.bh }, &.{pair}, dials);
    return result.require();
}

// The questioner leaves its root give unobserved, keeping the original answer
// and avoiding the independent direct-route redemption lifecycle in this test.
fn drive(relay_pair: h.Pair, home_pair: h.Pair, dials: *std.ArrayList(h.ParkedDial)) !void {
    while (try relay_pair.a.takeOutbound()) |value| {
        var frame = value;
        defer frame.deinit();
        try relay_pair.bh.feed(relay_pair.b, frame.view());
    }
    try h.pumpToQuiescence(a, &.{ home_pair.ah, home_pair.bh }, &.{home_pair}, dials);
}

fn replies(pair: h.Pair, expected: u64, value: i64) !void {
    const resolver = pair.a.served.port.peer.session_state.resolverExportForAnswer(.from(expected)).?;
    var seen = false;
    while (try pair.b.takeOutbound()) |out| {
        var frame = out;
        defer frame.deinit();
        const body = try glowcap.ocapn.codec.dispatch.decodeBodyForProfile(pair.b.served.port.peer.session_state.codec, .next, frame.view());
        if (body == .deliver and body.deliver.target.exportPosition() == resolver) {
            try std.testing.expectEqualStrings("fulfill", (try body.deliver.args.at(0)).symbol);
            try std.testing.expectEqual(value, (try body.deliver.args.at(1)).integer);
            seen = true;
        }
    }
    try std.testing.expect(seen);
}

test "core host raw root reply preserves queued calls and pins the route after its original retain leaves" {
    for ([_]model.CodecId{ .syrup, .capnp }) |codec_id| try run(codec_id);
}

fn run(codec_id: model.CodecId) !void {
    var options = h.nextRouteOptions();
    options.codec = codec_id;
    var relay = support.init(a, @splat(0xB1), options);
    defer relay.deinit();
    const boundary = try relay.vat.spawn(h.Widget, .{});
    defer relay.vat.releaseActor(boundary.local);
    var home = support.init(a, @splat(0xB2), options);
    defer home.deinit();
    var recipient = support.init(a, @splat(0xB3), options);
    defer recipient.deinit();
    var dials: std.ArrayList(h.ParkedDial) = .empty;
    defer h.deinitParked(a, &dials);
    const home_pair = try h.openPair(a, &relay, &home, "127.0.0.1:7197", &dials);
    const recipient_pair = try h.openPair(a, &recipient, &relay, "127.0.0.1:7198", &dials);
    var called: usize = 0;
    _ = try home.publish("destination", Counter, .{ .calls = &called });
    const raw = try fetch(&relay, home_pair, "destination", &dials);
    const routed = relay.node.routeReference(home_pair.a.peer_handle, raw).?;
    const position = routed.target.far.import_position;
    const home_state = &home_pair.a.served.port.peer.session_state;
    try std.testing.expect(home_state.hostImportIdentity(position) == null);
    _ = try relay.publish("gift", h.Introducer, .{ .widget = raw });
    const vendor = try fetch(&recipient, recipient_pair, "gift", &dials);
    const vendor_local = try recipient.node.lowerForConn(recipient_pair.a.peer_handle, vendor);
    const port = &recipient_pair.a.served.port;
    const root = try port.send(&recipient.vat, .{ .far = vendor_local.far }, .{ .verb = "introduce", .args = &.{} });
    try port.peer.stepToIdle();
    try std.testing.expect(port.peer.session_state.claimOutboundAnswerRelease(root.far));
    const queued = try port.sendToAnswer(&recipient.vat, root.far, .{ .verb = "queued", .args = &.{} });
    try port.tellToAnswer(&recipient.vat, root.far, .{ .verb = "tell", .args = &.{} });
    try port.peer.stepToIdle();
    try drive(recipient_pair, home_pair, &dials);
    try std.testing.expectEqual(@as(usize, 2), called);
    try replies(recipient_pair, queued.far.position.int(), 1);
    try std.testing.expectEqual(@as(u64, 0), home_state.hostImportIdentity(position).?.lifted_retains);

    // The raw observer still owns its original retain. Its ordinary release
    // stays behind the answer's home-owned pin, preserving late-call authority.
    try home_pair.a.served.port.peer.sendBorrowed(.{ .gc_export = .{ .positions = &.{position.int()}, .deltas = &.{1} } });
    try home_pair.a.served.port.peer.stepToIdle();
    try std.testing.expectEqual(@as(u64, 0), home_state.importReleasable(position));
    try std.testing.expect(home_state.holdsImport(position));
    const late = try port.sendToAnswer(&recipient.vat, root.far, .{ .verb = "late", .args = &.{} });
    try port.peer.stepToIdle();
    try drive(recipient_pair, home_pair, &dials);
    try std.testing.expectEqual(@as(usize, 3), called);
    try replies(recipient_pair, late.far.position.int(), 3);
    try port.peer.sendBorrowed(.{ .gc_answer = .{ .positions = &.{root.far.position.int()} } });
    try port.peer.stepToIdle();
    try drive(recipient_pair, home_pair, &dials);
    // Retired actor destructors run at the next outer Vat boundary.
    _ = try relay.vat.near(boundary, .{ .verb = "poke", .args = &.{} });
    try h.pumpToQuiescence(a, &.{ &relay, &home }, &.{home_pair}, &dials);
    try std.testing.expect(home_state.hostImportIdentity(position) == null);
    try std.testing.expect(!home_state.holdsImport(position));
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);
}
