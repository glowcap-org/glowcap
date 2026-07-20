//! `Host.openAcceptedOver` and `Host.serveEvent`: the adoption seam a
//! peer-owning loop rides. The embedder pins an `engine.Peer` at a stable
//! address (here: the test frame), the host adopts it: node routing, keyed
//! hello, enrollment, everything `openAccepted` wires, and serves it per
//! polled event, while ownership never moves: `releaseSession` unregisters the
//! adopted peer without freeing it, and the embedder deinits it afterward
//! (the testing allocator makes a double free or a leak fail loud). This is
//! `engine.Node`'s registerPeerOver contract proven one level up, at the
//! host tier.

const std = @import("std");
const pancake = @import("pancake");
const promise_capture = @import("../support/capture.zig");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;

const frame_cap = 4096;

const Counter = struct {
    hits: i64 = 0,
    pub fn handle(self: *Counter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "hit")) return error.NoSuchMethod;
        self.hits += 1;
        return .{ .integer = self.hits };
    }
};

const CapturedRef = promise_capture.CapturedRef;
const CapturedInt = promise_capture.CapturedInt;

/// Move frames client → adopted conn (through `feed`) and back (client is an
/// ordinary host-owned connection).
const host_pair = @import("../support/host_pair.zig");

/// The adopted conn is an ordinary `Pair` leg: client host/session on one
/// side, the adopting host and its adopted session on the other.
fn pumpToQuiescence(client_host: *Host, client: *HostSession, server_host: *Host, adopted: *HostSession) !void {
    try host_pair.pumpToQuiescence(&.{.{ .ah = client_host, .a = client, .bh = server_host, .b = adopted }});
}

test "openAcceptedOver adopts an embedder-pinned peer: handshake, fetch, per-event serve, release without freeing" {
    const allocator = std.testing.allocator;

    var server = Host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var client = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();

    // The embedder-pinned peer: owned by this frame, adopted by the host,
    // freed here after releaseSession — never by the host or the node.
    var pinned = engine.Peer.initNegotiating(allocator);
    defer pinned.deinit();

    const adopted = try server.openAcceptedOver(&pinned, "tcp", "127.0.0.1:7001", &.{});
    const dialed = try client.openDialedLocator(.{
        .transport = "tcp",
        .designator = "127.0.0.1:7001",
        .hints = model.Hints.emptyFalse(),
    });
    try pumpToQuiescence(&client, dialed, &server, adopted);
    try std.testing.expect(adopted.sessionOpen());
    try std.testing.expect(dialed.sessionOpen());
    // The adopted shell serves the pinned peer, not a node-owned twin, and
    // the host posture landed on it.
    try std.testing.expect(adopted.served.peer == &pinned);
    try std.testing.expectEqual(@as(usize, frame_cap), pinned.session_state.limits.max_frame_bytes);

    // Publish and fetch over the adopted connection.
    _ = try adopted.served.publish("counter", Counter, .{});
    var fetched = CapturedRef{};
    const fetch_vow = try client.fetch(dialed, "counter");
    try client.vowOn(fetch_vow, .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(&client, dialed, &server, adopted);
    const counter = fetched.ref orelse return error.FetchDidNotSettle;

    // The per-event verb, driven the way a loop drives it: the embedder
    // applies the inbound frames to the pinned peer itself, polls one event,
    // and hands it to `Host.serveEvent`. Two delivers are queued so the
    // batch subtlety is pinned: the first serveEvent's unwind consumes the
    // whole batch, and the embedder's own pollEvent then finds null.
    var first_reply = CapturedInt{};
    var second_reply = CapturedInt{};
    const vow1 = try client.send(dialed, counter, .{ .verb = "hit", .args = &.{} });
    try client.vowOn(vow1, .{ .ctx = &first_reply, .func = CapturedInt.record });
    const vow2 = try client.send(dialed, counter, .{ .verb = "hit", .args = &.{} });
    try client.vowOn(vow2, .{ .ctx = &second_reply, .func = CapturedInt.record });

    var fed: usize = 0;
    while (try dialed.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        try pinned.recvBorrowed(frame.view());
        fed += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), fed);

    var served_events: usize = 0;
    while (pinned.pollEvent()) |event_value| {
        var event = event_value;
        defer event.deinit();
        try server.serveEvent(adopted, &event);
        served_events += 1;
    }
    // One hook firing served the two-deliver batch: the verb's unwind drained
    // the second event through the same serve spine.
    try std.testing.expectEqual(@as(usize, 1), served_events);

    try pumpToQuiescence(&client, dialed, &server, adopted);
    try std.testing.expectEqual(@as(i64, 1), first_reply.value orelse return error.FirstReplyMissing);
    try std.testing.expectEqual(@as(i64, 2), second_reply.value orelse return error.SecondReplyMissing);

    // Release the adopted connection: the node unregisters the slot but the
    // pinned peer stays the embedder's — the deferred `pinned.deinit()` above
    // frees it exactly once under the testing allocator.
    try server.releaseSession(adopted);
}
