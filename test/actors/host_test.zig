//! The OCapN/actor seam over the wire: one vat publishes an actor; another vat
//! eventual-sends (`<-`) to it through a *far* ref and observes the promise. The
//! send routes over the peer as an `op:deliver`, the published actor runs a turn
//! and resolves the answer, and the inbound resolution fires the far promise's
//! listener, all through the actor API, no hand-built wire messages.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const Turn = actors.Turn;
const Message = actors.Message;
const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;
const capture = @import("../support/capture.zig");
const cross_peer = @import("../support/cross_peer.zig");

const Counter = struct {
    n: i64,
    pub fn handle(self: *Counter, turn: *Turn, msg: Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "add")) {
            self.n += try msg.argInt(0);
            return .{ .integer = self.n };
        }
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        return error.NoSuchMethod;
    }
};

/// Shuttle one complete protocol leg to the other peer.
fn shuttle(from: *engine.Peer, to: *engine.Peer) !void {
    try cross_peer.pumpAll(from, to);
}

test "eventual-send to a far ref routes over the wire and resolves the promise" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();

    // p2's vat publishes a counter at export 7; p1 holds it as import 7.
    var server = actors.Vat.init(allocator);
    defer server.deinit();
    var server_port = actors.Port.init(allocator, &pair.p2);
    defer server_port.deinit(&server);
    const counter = try server.spawn(Counter, .{ .n = 10 });
    try server_port.bindExport(&server, counter, 7);
    // The pairing is hand-wired (p1 learns position 7 out-of-band, below), so
    // the bound position takes an explicit grant; a marshaled introduction
    // would have granted it instead.
    try pair.p2.exportObject(7);
    try pair.p1.importObject(7);

    // p1's vat eventual-sends counter.add(5) to the far ref, no wire message by
    // hand, just `send` to a far Ref.
    var client = actors.Vat.init(allocator);
    defer client.deinit();
    var client_port = actors.Port.init(allocator, &pair.p1);
    defer client_port.deinit(&client);
    const remote: actors.Ref = .{ .far = model.FarRef.object(7) };
    const promise = try client_port.send(&client, remote, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });

    var result: i64 = 0;
    try client_port.on(&client, promise, .{ .ctx = &result, .func = capture.captureInt });

    // Deliver flows p1 -> p2; the server vat runs the actor and resolves.
    try shuttle(&pair.p1, &pair.p2);
    var first_served = false;
    while (pair.p2.pollEvent()) |event_in| {
        var event = event_in;
        defer event.deinit();
        first_served = (try server_port.serve(&server, &event)) or first_served;
    }
    try std.testing.expect(first_served);
    // Resolution flows p2 -> p1; the client vat fires the far promise's listener.
    try shuttle(&pair.p2, &pair.p1);
    {
        var event = pair.p1.pollEvent() orelse return error.ExpectedResolve;
        defer event.deinit();
        try std.testing.expect(try client_port.serve(&client, &event));
    }

    try std.testing.expectEqual(@as(i64, 15), result);
}

test "near-call to a far ref is rejected, only send reaches a far object" {
    const allocator = std.testing.allocator;
    var vat = actors.Vat.init(allocator);
    defer vat.deinit();
    const remote: actors.Ref = .{ .far = model.FarRef.object(1) };
    try std.testing.expectError(error.NotNearCallable, vat.near(remote, .{ .verb = "get" }));
}

/// Replay one captured deliver frame into the host peer and serve every
/// surfaced event through the vat, exactly as a driver pumps inbound traffic.
fn replayAndServe(host: *engine.Peer, vat: *actors.Vat, port: *actors.Port, frame: *const pancake.foundation.Frame) !void {
    try host.recvBorrowed(frame.view());
    while (host.pollEvent()) |event_in| {
        var event = event_in;
        defer event.deinit();
        if (!try port.serve(vat, &event)) return error.EventNotServed;
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
    var server = actors.Vat.init(counting.allocator());
    defer server.deinit();
    var server_port = actors.Port.init(counting.allocator(), &pair.p2);
    defer server_port.deinit(&server);
    const counter = try server.spawn(Counter, .{ .n = 0 });
    try server_port.bindExport(&server, counter, 7);
    // Hand-wired pairing: the client addresses position 7 out-of-band, so the
    // bound position takes an explicit grant.
    try pair.p2.exportObject(7);
    try pair.p1.importObject(7);

    var client = actors.Vat.init(allocator);
    defer client.deinit();
    var client_port = actors.Port.init(allocator, &pair.p1);
    defer client_port.deinit(&client);

    // Capture one answer-less deliver (`tell` requests no reply, so serving
    // it queues nothing outbound) and replay the same frame for every turn.
    try client_port.tell(&client, .{ .far = model.FarRef.object(7) }, .{ .verb = "add", .args = &.{.{ .integer = 1 }} });
    _ = try pair.p1.step();
    var frame = pair.p1.takeOutbound() orelse return error.ExpectedFrame;
    defer frame.deinit();

    // Warm up: grow the turn arena's capacity and the vat's tables.
    const warmup = 8;
    for (0..warmup) |_| try replayAndServe(&pair.p2, &server, &server_port, &frame);

    // Steady state: the args slice and verb symbol bump-allocate from the turn
    // arena, which resets with retained capacity at each outermost turn, so a
    // hosted turn makes zero allocations on the vat allocator.
    const turns = 16;
    counting.allocs = 0;
    for (0..turns) |_| try replayAndServe(&pair.p2, &server, &server_port, &frame);
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

    var server = actors.Vat.init(allocator);
    defer server.deinit();
    var server_port = actors.Port.init(allocator, &pair.p2);
    defer server_port.deinit(&server);
    const first = try server.spawn(Counter, .{ .n = 1 });
    const second = try server.spawn(Counter, .{ .n = 2 });

    try server_port.bindExport(&server, first, 7);
    // Which local object answers export position 7 is authority: a second bind to
    // the same position would silently orphan `first`, so it is rejected.
    try std.testing.expectError(actors.Error.AlreadyPublished, server_port.bindExport(&server, second, 7));
}

/// Captures a `.give` resolution's projection into fixed buffers so the test
/// can assert on it after the bounded listener call returns.
const GiveCapture = struct {
    fired: bool = false,
    typed: bool = false,
    envelope: [512]u8 = undefined,
    envelope_len: usize = 0,
    uri: [128]u8 = undefined,
    uri_len: usize = 0,
    key: [64]u8 = undefined,
    key_len: usize = 0,

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *GiveCapture = @ptrCast(@alignCast(ctx.?));
        self.fired = true;
        switch (resolution) {
            .give => |give| {
                self.typed = true;
                self.envelope_len = @min(give.give_bytes.len, self.envelope.len);
                @memcpy(self.envelope[0..self.envelope_len], give.give_bytes[0..self.envelope_len]);
                self.uri_len = @min(give.exporter_locator_uri.len, self.uri.len);
                @memcpy(self.uri[0..self.uri_len], give.exporter_locator_uri[0..self.uri_len]);
                self.key_len = @min(give.recipient_key.len, self.key.len);
                @memcpy(self.key[0..self.key_len], give.recipient_key[0..self.key_len]);
            },
            .fulfilled, .broken => {},
        }
    }
};

test "a resolve carrying a handoff give fires the listener typed: verbatim envelope, dialable locator, recipient key" {
    const crypto = pancake.foundation.crypto;
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.pairedV1_0Syrup(allocator);
    defer pair.deinit();

    // The client vat asks a far object a question; the partner will answer it
    // with an introduction instead of a value.
    var client = actors.Vat.init(allocator);
    defer client.deinit();
    var client_port = actors.Port.init(allocator, &pair.p1);
    defer client_port.deinit(&client);
    try pair.p2.exportObject(7);
    try pair.p1.importObject(7);
    const remote: actors.Ref = .{ .far = model.FarRef.object(7) };
    const promise = try client_port.send(&client, remote, .{ .verb = "introduce", .args = &.{} });
    var captured = GiveCapture{};
    try client_port.on(&client, promise, .{ .ctx = &captured, .func = GiveCapture.fire });

    try shuttle(&pair.p1, &pair.p2);
    const answer = blk: {
        var event = pair.p2.pollEvent() orelse return error.ExpectedDeliver;
        defer event.deinit();
        const body = try event.view();
        break :blk body.deliver.answer orelse return error.ExpectedAnswer;
    };

    // A genuine signed give whose exporter location is a verbatim locator
    // record, exactly what a gifter node would have minted.
    const gifter_secret = crypto.SecretKey.fromSeed([_]u8{7} ** crypto.SEED_BYTES);
    const recipient_key = crypto.SecretKey.fromSeed([_]u8{9} ** crypto.SEED_BYTES).publicKey().asBytes();
    const exporter_key = crypto.SecretKey.fromSeed([_]u8{8} ** crypto.SEED_BYTES).publicKey().asBytes();
    const location = try engine.encodePeerLocatorRecord(allocator, .{
        .transport = "tcp",
        .designator = "127.0.0.1:9070",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(location);
    const gifter_side = try engine.handoff_recipient.sideName(gifter_secret.publicKey().asBytes());
    const exporter_side = try engine.handoff_recipient.sideName(exporter_key);
    const session = engine.handoff_recipient.sessionName(gifter_side, exporter_side);
    const gift_id = [_]u8{0x5a} ** 32;
    const give = try engine.handoff_gifter.buildSignedGive(
        allocator,
        gifter_secret,
        recipient_key,
        location,
        &session,
        &gifter_side,
        &gift_id,
    );
    defer allocator.free(give);

    try pair.p2.sendResolveHandoffGive(answer, give);
    try shuttle(&pair.p2, &pair.p1);
    {
        var event = pair.p1.pollEvent() orelse return error.ExpectedResolve;
        defer event.deinit();
        try std.testing.expect(try client_port.serve(&client, &event));
    }

    try std.testing.expect(captured.fired);
    try std.testing.expect(captured.typed);
    // The envelope is the verbatim signed give, byte-for-byte what the gifter
    // minted — the recipient relays it unaltered inside its handoff-receive.
    try std.testing.expectEqualStrings(give, captured.envelope[0..captured.envelope_len]);
    // The exporter location projects through the one URI grammar, dialable.
    try std.testing.expectEqualStrings("ocapn://127.0.0.1%3A9070.tcp", captured.uri[0..captured.uri_len]);
    try std.testing.expectEqualSlices(u8, recipient_key, captured.key[0..captured.key_len]);
}

/// A resolve interceptor that claims replies fulfilling with an integer over
/// 100, recording what it saw; smaller replies pass through untouched.
const ClaimBigReplies = struct {
    claimed: usize = 0,
    seen_answer: u64 = 0,

    fn fire(ctx: ?*anyopaque, answer: model.AnswerPosition, fulfilled: model.Argument) anyerror!actors.InterceptOutcome {
        const self: *ClaimBigReplies = @ptrCast(@alignCast(ctx.?));
        // `.claimed` claims the reply (the interceptor owns resolving it);
        // `.resolve` passes the value through for the vat to resolve as-is.
        if (fulfilled != .integer or fulfilled.integer <= 100) return .{ .resolve = fulfilled };
        self.claimed += 1;
        self.seen_answer = answer.int();
        return .claimed;
    }
};

test "a resolve interceptor claims a served reply before it reaches the wire, and an unclaimed reply flows" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();

    var server = actors.Vat.init(allocator);
    defer server.deinit();
    var server_port = actors.Port.init(allocator, &pair.p2);
    defer server_port.deinit(&server);
    const counter = try server.spawn(Counter, .{ .n = 200 });
    try server_port.bindExport(&server, counter, 7);
    // Hand-wired pairing: the client addresses position 7 out-of-band, so the
    // bound position takes an explicit grant.
    try pair.p2.exportObject(7);
    try pair.p1.importObject(7);

    var interceptor = ClaimBigReplies{};
    server_port.setResolveInterceptor(.{ .ctx = &interceptor, .func = ClaimBigReplies.fire });

    var client = actors.Vat.init(allocator);
    defer client.deinit();
    var client_port = actors.Port.init(allocator, &pair.p1);
    defer client_port.deinit(&client);
    const remote: actors.Ref = .{ .far = model.FarRef.object(7) };

    // First call replies 205: the interceptor claims it, so the client's
    // promise stays unsettled — nothing crossed the wire back.
    const claimed_promise = try client_port.send(&client, remote, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });
    var claimed_result: i64 = 0;
    try client_port.on(&client, claimed_promise, .{ .ctx = &claimed_result, .func = capture.captureInt });
    try shuttle(&pair.p1, &pair.p2);
    var second_served = false;
    while (pair.p2.pollEvent()) |event_in| {
        var event = event_in;
        defer event.deinit();
        second_served = (try server_port.serve(&server, &event)) or second_served;
    }
    try std.testing.expect(second_served);
    try std.testing.expectEqual(@as(usize, 1), interceptor.claimed);
    _ = try pair.p2.step();
    try std.testing.expect(pair.p2.takeOutbound() == null);
    try std.testing.expectEqual(@as(i64, 0), claimed_result);

    // Second call replies 5 (fresh counter at 0 plus 5, under the 100
    // threshold): unclaimed, the ordinary resolve flows and the listener fires.
    const small = try server.spawn(Counter, .{ .n = 0 });
    try server_port.bindExport(&server, small, 8);
    try pair.p2.exportObject(8);
    try pair.p1.importObject(8);
    const passed_promise = try client_port.send(&client, .{ .far = model.FarRef.object(8) }, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });
    var passed_result: i64 = 0;
    try client_port.on(&client, passed_promise, .{ .ctx = &passed_result, .func = capture.captureInt });
    try shuttle(&pair.p1, &pair.p2);
    {
        var event = pair.p2.pollEvent() orelse return error.ExpectedDeliver;
        defer event.deinit();
        try std.testing.expect(try server_port.serve(&server, &event));
    }
    try shuttle(&pair.p2, &pair.p1);
    {
        var event = pair.p1.pollEvent() orelse return error.ExpectedResolve;
        defer event.deinit();
        try std.testing.expect(try client_port.serve(&client, &event));
    }
    try std.testing.expectEqual(@as(usize, 1), interceptor.claimed);
    try std.testing.expectEqual(@as(i64, 5), passed_result);
}

/// Records a `.broken` resolution's message so the test can assert on the
/// break reason after the bounded listener call returns.
const BrokenCapture = struct {
    fired: bool = false,
    broken: bool = false,
    message: [64]u8 = undefined,
    message_len: usize = 0,

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *BrokenCapture = @ptrCast(@alignCast(ctx.?));
        self.fired = true;
        switch (resolution) {
            .broken => |message| {
                self.broken = true;
                self.message_len = @min(message.len, self.message.len);
                @memcpy(self.message[0..self.message_len], message[0..self.message_len]);
            },
            .fulfilled, .give => {},
        }
    }
};

test "an answered deliver to an exported-but-unbound position breaks the answer instead of stranding it" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();

    // The position is exported at peer level — the engine admits deliveries —
    // but no actor is bound to it (`peer.exportObject` without
    // `vat.bindExport`, the hand-wired embedder shape).
    var server = actors.Vat.init(allocator);
    defer server.deinit();
    var server_port = actors.Port.init(allocator, &pair.p2);
    defer server_port.deinit(&server);
    try pair.p2.exportObject(7);
    try pair.p1.importObject(7);

    var client = actors.Vat.init(allocator);
    defer client.deinit();
    var client_port = actors.Port.init(allocator, &pair.p1);
    defer client_port.deinit(&client);
    const remote: actors.Ref = .{ .far = model.FarRef.object(7) };
    const promise = try client_port.send(&client, remote, .{ .verb = "get" });
    var captured = BrokenCapture{};
    try client_port.on(&client, promise, .{ .ctx = &captured, .func = BrokenCapture.fire });

    // The server vat owns the event (it answers for the position) and breaks
    // the answer — a `false` here is the silent drop that stranded the
    // partner's promise forever.
    try shuttle(&pair.p1, &pair.p2);
    {
        var event = pair.p2.pollEvent() orelse return error.ExpectedDeliver;
        defer event.deinit();
        try std.testing.expect(try server_port.serve(&server, &event));
    }
    try shuttle(&pair.p2, &pair.p1);
    {
        var event = pair.p1.pollEvent() orelse return error.ExpectedResolve;
        defer event.deinit();
        try std.testing.expect(try client_port.serve(&client, &event));
    }
    try std.testing.expect(captured.fired);
    try std.testing.expect(captured.broken);
    try std.testing.expectEqualStrings("NoSuchActor", captured.message[0..captured.message_len]);
}
