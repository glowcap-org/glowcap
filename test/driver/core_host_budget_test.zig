//! The byte-fed host under a `local_turn_budget`: the fan-out embedder's
//! amplification cap, with its attribution contract. A budget breach inside
//! the fed connection's own dispatch fails that feed (the embedder closes the
//! connection, the iroh loop's shipped posture). A breach discovered inside
//! the pump — the fed connection's work flooded a *sibling* connection's
//! vat — must not fail the fed verb or the fed connection: the flooded
//! sibling is condemned with a typed `resource_exhausted` abort and a `close`
//! action names it for the embedder, while the connection that fed the pump
//! keeps serving. Sans-io: hosts are wired by moving frames between
//! `takeOutbound` and `feed` by hand.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;

const frame_cap = 4096;
const budget: usize = 4;
/// One more turn than the budget admits, queued by a single inbound message.
const flood_turns: usize = budget + 2;

/// The amplification target: each queued `hit` is one local turn.
const Counter = struct {
    hits: i64 = 0,
    pub fn handle(self: *Counter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "hit")) return error.NoSuchMethod;
        self.hits += 1;
        return .{ .integer = self.hits };
    }
};

/// A behavior whose one inbound `flood` queues more local turns than the
/// budget admits — on its *own* vat, so the breach belongs to the fed
/// connection's own dispatch.
const SelfFlood = struct {
    amp: actors.Ref,
    pub fn handle(self: *SelfFlood, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "flood")) return error.NoSuchMethod;
        var i: usize = 0;
        while (i < flood_turns) : (i += 1) {
            try turn.vat.tell(self.amp, .{ .verb = "hit", .args = &.{} });
        }
        return .{ .boolean = true };
    }
};

/// A behavior whose one inbound `flood` floods a *sibling* connection's vat
/// through the host's enqueueing `tell` (legal under the callback latch).
const SiblingFlood = struct {
    host: *Host,
    sibling: *HostSession,
    target: model.Reference,
    pub fn handle(self: *SiblingFlood, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "flood")) return error.NoSuchMethod;
        var i: usize = 0;
        while (i < flood_turns) : (i += 1) {
            try self.host.tell(self.sibling, self.target, .{ .verb = "hit", .args = &.{} });
        }
        return .{ .boolean = true };
    }
};

const Pair = struct { ah: *Host, a: *HostSession, bh: *Host, b: *HostSession };

/// Move every queued frame across the pair, both directions; a feed error
/// surfaces to the caller (the assertion under test).
fn shuttle(pair: Pair) !bool {
    var moved = false;
    while (try pair.a.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        try pair.bh.feed(pair.b, frame.view());
        moved = true;
    }
    while (try pair.b.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        try pair.ah.feed(pair.a, frame.view());
        moved = true;
    }
    return moved;
}

fn pumpToQuiescence(pairs: []const Pair) !void {
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        var moved = false;
        for (pairs) |pair| {
            if (try shuttle(pair)) moved = true;
        }
        if (!moved) return;
    }
    return error.PumpDidNotQuiesce;
}

fn tcpLocator(designator: []const u8) model.PeerLocator {
    return .{ .transport = "tcp", .designator = designator, .hints = model.Hints.emptyFalse() };
}

fn openPair(dialer: *Host, acceptor: *Host, designator: []const u8) !Pair {
    const accepted = try acceptor.openAccepted("tcp", designator, &.{});
    const dialed = try dialer.openDialedLocator(tcpLocator(designator));
    const pair = Pair{ .ah = dialer, .a = dialed, .bh = acceptor, .b = accepted };
    try pumpToQuiescence(&.{pair});
    try std.testing.expect(dialed.sessionOpen());
    try std.testing.expect(accepted.sessionOpen());
    return pair;
}

const CapturedRef = struct {
    ref: ?model.Reference = null,
    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *CapturedRef = @ptrCast(@alignCast(ctx.?));
        if (resolution == .fulfilled and resolution.fulfilled == .reference)
            self.ref = resolution.fulfilled.reference;
    }
};

const CapturedInt = struct {
    value: ?i64 = null,
    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *CapturedInt = @ptrCast(@alignCast(ctx.?));
        if (resolution == .fulfilled and resolution.fulfilled == .integer)
            self.value = resolution.fulfilled.integer;
    }
};

/// Fetch `name` over `pair` (client side `a`) and settle it to a far ref.
fn fetchRef(pair: Pair, name: []const u8) !model.Reference {
    var fetched = CapturedRef{};
    const vow = try pair.ah.fetch(pair.a, name);
    try pair.ah.vowOn(vow, .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(&.{pair});
    return fetched.ref orelse error.FetchDidNotSettle;
}

test "a fed frame whose own dispatch amplifies past the budget fails that feed" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x0b} ** 32, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = budget,
    });
    defer server.deinit();

    const pair = try openPair(&client, &server, "127.0.0.1:7001");
    const amp = try pair.b.served.vat.spawn(Counter, .{});
    _ = try pair.b.served.publish("trigger", SelfFlood, .{ .amp = amp });

    const trigger = try fetchRef(pair, "trigger");
    _ = try client.send(pair.a, trigger, .{ .verb = "flood", .args = &.{} });

    // The flood deliver is the client's one queued frame; feeding it drives
    // the fed connection's own turns past the budget inside the latched
    // dispatch, which keeps today's failDispatch semantics: the feed fails.
    var frame = (try pair.a.takeOutbound()) orelse return error.NoDeliverQueued;
    defer frame.deinit();
    try std.testing.expectError(
        error.LocalTurnLimitExceeded,
        server.feed(pair.b, frame.view()),
    );
}

test "a fed connection flooding a sibling condemns the sibling with a close action; the fed verb and connection survive" {
    const allocator = std.testing.allocator;
    var client_a = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client_a.deinit();
    var client_b = Host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client_b.deinit();
    var server = Host.init(allocator, [_]u8{0x0b} ** 32, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = budget,
    });
    defer server.deinit();

    const pair_a = try openPair(&client_a, &server, "127.0.0.1:7001");
    const pair_b = try openPair(&client_b, &server, "127.0.0.1:7002");

    // The sibling's amplification target, and the fed connection's trigger
    // that floods it through the host's enqueueing `tell`.
    const amp = try pair_b.b.served.publish("amp", Counter, .{});
    _ = try pair_a.b.served.publish("trigger", SiblingFlood, .{
        .host = &server,
        .sibling = pair_b.b,
        .target = amp.nearRef(),
    });
    _ = try pair_a.b.served.publish("echo", Counter, .{});

    const trigger = try fetchRef(pair_a, "trigger");
    _ = try client_a.send(pair_a.a, trigger, .{ .verb = "flood", .args = &.{} });

    // Feed the flood by hand: the fed verb must SUCCEED — the breach belongs
    // to the sibling the flood landed on, not to the connection that fed it.
    var flood_frame = (try pair_a.a.takeOutbound()) orelse return error.NoDeliverQueued;
    defer flood_frame.deinit();
    try server.feed(pair_a.b, flood_frame.view());

    // The pump condemned the sibling and queued the embedder's close signal.
    var saw_close = false;
    while (try server.nextAction()) |action| {
        if (action == .close) {
            try std.testing.expect(action.close == pair_b.b.peer_id);
            saw_close = true;
        }
    }
    try std.testing.expect(saw_close);
    try std.testing.expectError(
        driver.core.HostError.ConnectionCondemned,
        server.fetch(pair_b.b, "amp"),
    );

    // The sibling's outbound carries the typed resource_exhausted abort;
    // its partner hears why it is being closed.
    var saw_abort = false;
    while (try pair_b.b.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        client_b.feed(pair_b.a, frame.view()) catch {};
        if (pair_b.a.served.last_abort) |info| {
            try std.testing.expectEqual(model.AbortKind.resource_exhausted, info.kind);
            saw_abort = true;
        }
    }
    try std.testing.expect(saw_abort);

    // The fed connection still serves: an ordinary call settles after the
    // sibling's condemnation.
    const echo = try fetchRef(pair_a, "echo");
    var reply = CapturedInt{};
    const vow = try client_a.send(pair_a.a, echo, .{ .verb = "hit", .args = &.{} });
    try client_a.vowOn(vow, .{ .ctx = &reply, .func = CapturedInt.record });
    try pumpToQuiescence(&.{pair_a});
    try std.testing.expectEqual(@as(i64, 1), reply.value orelse return error.EchoDidNotSettle);
}
