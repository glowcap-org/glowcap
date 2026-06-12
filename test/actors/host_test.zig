//! The OCapN/actor seam over the wire: one vat publishes an actor; another vat
//! eventual-sends (`<-`) to it through a *far* ref and observes the promise. The
//! send routes over the peer as an `op:deliver`, the published actor runs a turn
//! and resolves the answer, and the inbound resolution fires the far promise's
//! listener — all through the actor API, no hand-built wire messages.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;

const Counter = struct {
    n: i64,
    pub fn handle(self: *Counter, turn: *Turn, msg: Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "add")) {
            self.n += msg.arg(0).integer;
            return .{ .integer = self.n };
        }
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        return error.NoSuchMethod;
    }
};

fn captureInt(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const slot: *i64 = @ptrCast(@alignCast(ctx.?));
    slot.* = switch (resolution) {
        .fulfilled => |value| value.integer,
        .broken => -1,
    };
}

/// Shuttle one peer's pending outbound frame to the other.
fn shuttle(from: *engine.Peer, to: *engine.Peer) !void {
    _ = try from.step();
    if (from.takeOutbound()) |frame| try to.feedInbound(frame);
    _ = try to.step();
}

test "eventual-send to a far ref routes over the wire and resolves the promise" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();

    // p2's vat publishes a counter at export 7; p1 holds it as import 7.
    var server = actors.Vat.initOver(allocator, &pair.p2);
    defer server.deinit();
    const counter = try server.spawn(Counter, .{ .n = 10 });
    try server.bindExport(counter, 7);
    try pair.p1.importObject(7);

    // p1's vat eventual-sends counter.add(5) to the far ref — no wire message by
    // hand, just `send` to a far Ref.
    var client = actors.Vat.initOver(allocator, &pair.p1);
    defer client.deinit();
    const remote: actors.Ref = .{ .far = model.FarRef.object(7) };
    const promise = try client.send(remote, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });

    var result: i64 = 0;
    try client.on(promise, .{ .ctx = &result, .func = captureInt });

    // Deliver flows p1 -> p2; the server vat runs the actor and resolves.
    try shuttle(&pair.p1, &pair.p2);
    {
        var event = pair.p2.pollEvent() orelse return error.ExpectedDeliver;
        defer event.deinit();
        try std.testing.expect(try server.serve(&event));
    }
    // Resolution flows p2 -> p1; the client vat fires the far promise's listener.
    try shuttle(&pair.p2, &pair.p1);
    {
        var event = pair.p1.pollEvent() orelse return error.ExpectedResolve;
        defer event.deinit();
        try std.testing.expect(try client.serve(&event));
    }

    try std.testing.expectEqual(@as(i64, 15), result);
}

test "near-call to a far ref is rejected — only send reaches a far object" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    const remote: actors.Ref = .{ .far = model.FarRef.object(1) };
    try std.testing.expectError(error.NotNearCallable, vat.near(remote, .{ .verb = "get" }));
}

/// Replay one captured deliver frame into the host peer and serve every
/// surfaced event through the vat, exactly as a driver pumps inbound traffic.
fn replayAndServe(host: *engine.Peer, vat: *actors.Vat, frame: *const pancake.foundation.Frame) !void {
    try host.recvBorrowed(frame.view());
    while (host.pollEvent()) |event_in| {
        var event = event_in;
        defer event.deinit();
        if (!try vat.serve(&event)) return error.EventNotServed;
    }
}

test "serve materializes inbound deliver args in the turn arena: a steady-state hosted turn costs the vat allocator nothing" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();

    // Only the hosting vat's allocator traffic is counted; the peers keep
    // their own allocator, so the engine's owned-frame copy stays out of the
    // measurement.
    var counting = CountingAllocator{ .backing = allocator };
    var server = actors.Vat.initOver(counting.allocator(), &pair.p2);
    defer server.deinit();
    const counter = try server.spawn(Counter, .{ .n = 0 });
    try server.bindExport(counter, 7);
    try pair.p1.importObject(7);

    var client = actors.Vat.initOver(allocator, &pair.p1);
    defer client.deinit();

    // Capture one answer-less deliver (`tell` requests no reply, so serving
    // it queues nothing outbound) and replay the same frame for every turn.
    try client.tell(.{ .far = model.FarRef.object(7) }, .{ .verb = "add", .args = &.{.{ .integer = 1 }} });
    _ = try pair.p1.step();
    var frame = pair.p1.takeOutbound() orelse return error.ExpectedFrame;
    defer frame.deinit();

    // Warm up: grow the turn arena's capacity and the vat's tables.
    const warmup = 8;
    for (0..warmup) |_| try replayAndServe(&pair.p2, &server, &frame);

    // Steady state: the args slice and verb symbol bump-allocate from the turn
    // arena, which resets with retained capacity at each outermost turn, so a
    // hosted turn makes zero allocations on the vat allocator.
    const turns = 16;
    counting.allocs = 0;
    for (0..turns) |_| try replayAndServe(&pair.p2, &server, &frame);
    try std.testing.expectEqual(@as(usize, 0), counting.allocs);

    // And every replayed turn really ran the actor.
    try std.testing.expectEqual(
        @as(i64, warmup + turns),
        (try server.near(counter, .{ .verb = "get" })).integer,
    );
}

test "binding two actors to the same export position fails loud instead of orphaning the first" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();

    var server = actors.Vat.initOver(allocator, &pair.p2);
    defer server.deinit();
    const first = try server.spawn(Counter, .{ .n = 1 });
    const second = try server.spawn(Counter, .{ .n = 2 });

    try server.bindExport(first, 7);
    // Which local object answers export position 7 is authority: a second bind to
    // the same position would silently orphan `first`, so it is rejected.
    try std.testing.expectError(actors.Error.AlreadyPublished, server.bindExport(second, 7));
}
