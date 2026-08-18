//! The byte-fed host under a `local_turn_budget`: the fan-out embedder's
//! amplification cap, with its attribution contract. A budget breach inside
//! the fed connection's own dispatch fails that feed (the embedder closes the
//! connection, the iroh loop's shipped posture). A breach discovered inside
//! the pump. When the fed connection's work flooded a sibling connection's
//! vat, that must not fail the fed verb or the fed connection. The flooded
//! sibling is condemned with a typed `resource_exhausted` abort and a `close`
//! action names it for the embedder, while the connection that fed the pump
//! keeps serving. Sans-io: hosts are wired by moving frames between
//! `takeOutbound` and `feed` by hand.

const std = @import("std");
const pancake = @import("pancake");
const test_host = @import("../support/core_host.zig");
const promise_capture = @import("../support/capture.zig");

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

const EventServeOutOfMemory = struct {
    pub fn hook(ctx: ?*anyopaque, _: *driver.core.Served, _: *engine.Event) anyerror!bool {
        const calls = @as(*usize, @ptrCast(@alignCast(ctx.?)));
        calls.* += 1;
        return error.OutOfMemory;
    }
};

test "finite host quantum emits resume actions for host-global internal work" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x0d} ** 32, .{ .host_work_quantum = 1 });
    defer host.deinit();

    // These no-op retirement actions model the Node's internal action chain:
    // none names a live session, so no FLUSH/CLOSE or other external action is
    // created. The action queue itself is the only remaining work.
    try host.node.actions.reserve(allocator, 3);
    const absent = engine.PeerId.from(999);
    host.node.actions.pushReserved(.{ .retire_exporter = absent });
    host.node.actions.pushReserved(.{ .retire_exporter = absent });
    host.node.actions.pushReserved(.{ .retire_exporter = absent });

    var resumes: usize = 0;
    while (try host.nextAction()) |action| {
        switch (action) {
            .resume_work => resumes += 1,
            else => return error.UnexpectedExternalAction,
        }
    }

    // The first quantum is entered by the initial nextAction call; only the
    // two subsequent slices require an explicit continuation notice.
    try std.testing.expectEqual(@as(usize, 2), resumes);
    try std.testing.expect(!host.node.hasAction());
}

test "finite host quantum does not starve Node work behind a hot session" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x2d} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, [_]u8{0x2e} ** 32, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .host_work_quantum = 1,
    });
    defer host.deinit();
    const pair = try openPair(&client, &host, "127.0.0.1:7100");

    const counter = try host.vat.spawn(Counter, .{});
    for (0..4) |_| try host.vat.tellFromIngress(
        pair.b.served.port.ingress,
        counter,
        .{ .verb = "hit", .args = &.{} },
    );
    host.next_work_lane = .session;
    driver.core.testing.markDirty(&host, pair.b.peer_id);

    try host.node.actions.reserve(allocator, 1);
    host.node.actions.pushReserved(.{ .retire_exporter = engine.PeerId.from(1234) });

    // The first slice serves one local turn. The persisted lane cursor makes
    // the next slice retire the Node action even though three turns remain.
    try std.testing.expectEqual(
        driver.core.DrainResult.yielded,
        try driver.core.drainActions(&host, NoopActionIo{}, NoopActionExec{}),
    );
    try std.testing.expect(host.node.hasAction());
    try std.testing.expectEqual(
        driver.core.DrainResult.yielded,
        try driver.core.drainActions(&host, NoopActionIo{}, NoopActionExec{}),
    );
    try std.testing.expect(!host.node.hasAction());
}

const NoopActionIo = struct {
    pub fn randomSecure(_: @This(), _: []u8) !void {
        return error.UnexpectedEntropyRequest;
    }
};

const RetryEntropy = struct {
    fail_next: *bool,

    pub fn randomSecure(self: @This(), bytes: []u8) !void {
        if (self.fail_next.*) {
            self.fail_next.* = false;
            return error.EntropyUnavailable;
        }
        @memset(bytes, 0x5a);
    }
};

const NoopActionExec = struct {
    pub fn flush(_: @This(), _: engine.PeerId) !void {}
    pub fn close(_: @This(), _: engine.PeerId) !void {}
    pub fn dial(_: @This(), _: @FieldType(driver.core.HostAction, "dial")) !void {}
    pub fn cancelDial(_: @This(), _: @FieldType(driver.core.HostAction, "cancel_dial")) !void {}
    pub fn complete(_: @This(), _: driver.core.HostAction) !void {}
};

const RetryDialExec = struct {
    fail_next: *bool,

    pub fn flush(_: @This(), _: engine.PeerId) !void {}
    pub fn close(_: @This(), _: engine.PeerId) !void {}
    pub fn dial(self: @This(), _: @FieldType(driver.core.HostAction, "dial")) !void {
        if (self.fail_next.*) {
            self.fail_next.* = false;
            return error.DialUnavailable;
        }
    }
    pub fn cancelDial(_: @This(), _: @FieldType(driver.core.HostAction, "cancel_dial")) !void {}
    pub fn complete(_: @This(), _: driver.core.HostAction) !void {}
};

const RetryCancelExec = struct {
    host: *Host,
    fail_next: *bool,

    pub fn flush(_: @This(), _: engine.PeerId) !void {}
    pub fn close(_: @This(), _: engine.PeerId) !void {}
    pub fn dial(_: @This(), _: @FieldType(driver.core.HostAction, "dial")) !void {}
    pub fn cancelDial(self: @This(), cancel: @FieldType(driver.core.HostAction, "cancel_dial")) !void {
        if (self.fail_next.*) {
            self.fail_next.* = false;
            return error.CancelUnavailable;
        }
        try self.host.dialCancelled(cancel.ticket);
    }
    pub fn complete(self: @This(), action: driver.core.HostAction) !void {
        self.host.freeAction(action);
    }
};

const RetryPrepareExec = struct {
    host: *Host,
    fail_next: *bool,

    pub fn prepare(self: @This(), action: driver.core.HostAction) !void {
        if (action != .settled and action != .failed) return;
        if (self.fail_next.*) {
            self.fail_next.* = false;
            return error.PublicationUnavailable;
        }
    }
    pub fn flush(_: @This(), _: engine.PeerId) !void {}
    pub fn close(_: @This(), _: engine.PeerId) !void {}
    pub fn dial(_: @This(), _: @FieldType(driver.core.HostAction, "dial")) !void {}
    pub fn cancelDial(_: @This(), _: @FieldType(driver.core.HostAction, "cancel_dial")) !void {}
    pub fn complete(self: @This(), action: driver.core.HostAction) !void {
        self.host.freeAction(action);
    }
};

test "standard host action drain yields between finite-quantum slices" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x0e} ** 32, .{ .host_work_quantum = 1 });
    defer host.deinit();

    try host.node.actions.reserve(allocator, 3);
    const absent = engine.PeerId.from(1000);
    host.node.actions.pushReserved(.{ .retire_exporter = absent });
    host.node.actions.pushReserved(.{ .retire_exporter = absent });
    host.node.actions.pushReserved(.{ .retire_exporter = absent });

    // One drain turn consumes exactly one continuation boundary. The
    // embedder can return to its reactor before asking for the next slice.
    try std.testing.expectEqual(
        driver.core.DrainResult.yielded,
        try driver.core.drainActions(&host, NoopActionIo{}, NoopActionExec{}),
    );
    try std.testing.expect(host.node.hasAction());
    try std.testing.expectEqual(
        driver.core.DrainResult.yielded,
        try driver.core.drainActions(&host, NoopActionIo{}, NoopActionExec{}),
    );
    try std.testing.expectEqual(
        driver.core.DrainResult.drained,
        try driver.core.drainActions(&host, NoopActionIo{}, NoopActionExec{}),
    );
    try std.testing.expect(!host.node.hasAction());
}

test "standard host action drain retains a gift-id request when entropy fails" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x1e} ** 32, .{});
    defer host.deinit();

    const recipient = try host.node.registerPeer(.{});
    const exporter = try host.node.registerPeer(.{});
    try host.node.peer(exporter).?.session_state.registerImport(.from(4));
    const gift = try host.node.enrollForeign(exporter, .{ .far = model.FarRef.object(4) });
    try std.testing.expect(try host.node.interceptFulfilledRoute(recipient, 77, gift.routed.id));

    var fail_next = true;
    try std.testing.expectError(
        error.EntropyUnavailable,
        driver.core.drainActions(&host, RetryEntropy{ .fail_next = &fail_next }, NoopActionExec{}),
    );
    const parked = (try host.peekAction()) orelse return error.MissingGiftIdAction;
    try std.testing.expect(host.node.hasPendingGift(parked.need_gift_id.ticket));

    try std.testing.expectEqual(
        driver.core.DrainResult.drained,
        try driver.core.drainActions(&host, RetryEntropy{ .fail_next = &fail_next }, NoopActionExec{}),
    );
    try std.testing.expect((try host.peekAction()) == null);
}

test "standard host action drain retries a dial whose executor fails" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x1f} ** 32, .{});
    defer host.deinit();

    _ = try host.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7095"));
    const ticket = ((try host.peekAction()) orelse return error.MissingDialAction).dial.ticket;

    var fail_next = true;
    try std.testing.expectError(
        error.DialUnavailable,
        driver.core.drainActions(&host, NoopActionIo{}, RetryDialExec{ .fail_next = &fail_next }),
    );
    const parked = (try host.peekAction()) orelse return error.MissingDialAction;
    try std.testing.expectEqual(ticket, parked.dial.ticket);

    try std.testing.expectEqual(
        driver.core.DrainResult.drained,
        try driver.core.drainActions(&host, NoopActionIo{}, RetryDialExec{ .fail_next = &fail_next }),
    );
    try std.testing.expect((try host.peekAction()) == null);

    try host.dialFailed(ticket, "test dial retired");
    const failed = (try host.takeAction()) orelse return error.MissingDialFailure;
    defer host.freeAction(failed);
    try std.testing.expect(failed == .failed);
}

test "standard host action drain retains a completion when publication preparation fails" {
    var host = test_host.init(std.testing.allocator, [_]u8{0x3f} ** 32, .{});
    defer host.deinit();

    _ = try host.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7099"));
    const ticket = ((try host.peekAction()) orelse return error.MissingDialAction).dial.ticket;
    var dial_failed = false;
    try std.testing.expectEqual(
        driver.core.DrainResult.drained,
        try driver.core.drainActions(&host, NoopActionIo{}, RetryDialExec{ .fail_next = &dial_failed }),
    );
    try host.dialFailed(ticket, "test completion");

    var prepare_failed = true;
    const exec = RetryPrepareExec{ .host = &host, .fail_next = &prepare_failed };
    try std.testing.expectError(
        error.PublicationUnavailable,
        driver.core.drainActions(&host, NoopActionIo{}, exec),
    );
    try std.testing.expect((try host.peekAction()).? == .failed);
    try std.testing.expectEqual(
        driver.core.DrainResult.drained,
        try driver.core.drainActions(&host, NoopActionIo{}, exec),
    );
    try std.testing.expect((try host.peekAction()) == null);
}

test "standard host action drain retries cancellation until physical acknowledgement" {
    var host = test_host.init(std.testing.allocator, [_]u8{0x21} ** 32, .{});
    defer host.deinit();

    _ = try host.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7098"));
    var dial_failed = false;
    try std.testing.expectEqual(
        driver.core.DrainResult.drained,
        try driver.core.drainActions(&host, NoopActionIo{}, RetryDialExec{ .fail_next = &dial_failed }),
    );
    try std.testing.expectEqual(@as(usize, 1), host.node.pendingDialCount());

    host.beginClose(.cancel, 0);
    var cancel_failed = true;
    const exec = RetryCancelExec{ .host = &host, .fail_next = &cancel_failed };
    try std.testing.expectError(
        error.CancelUnavailable,
        driver.core.drainActions(&host, NoopActionIo{}, exec),
    );
    const parked = (try host.peekAction()) orelse return error.MissingDialCancellation;
    try std.testing.expect(parked == .cancel_dial);
    try std.testing.expectEqual(@as(usize, 1), host.node.pendingDialCount());

    try std.testing.expectEqual(
        driver.core.DrainResult.drained,
        try driver.core.drainActions(&host, NoopActionIo{}, exec),
    );
    try std.testing.expectEqual(@as(usize, 0), host.node.pendingDialCount());
    try std.testing.expectEqual(Host.LifecyclePhase.closed, host.lifecyclePhase());
}

test "borrowed action refusal retries in place without reordering" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x20} ** 32, .{});
    defer host.deinit();

    _ = try host.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7096"));
    _ = try host.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7097"));

    const first = ((try host.nextAction()) orelse return error.MissingFirstDial).dial.ticket;
    try std.testing.expect(host.retryBorrowedAction());
    try std.testing.expectEqual(first, (try host.peekAction()).?.dial.ticket);
    const retried = (try host.takeAction()) orelse return error.MissingRetriedAction;
    defer host.freeAction(retried);
    try std.testing.expectEqual(first, retried.dial.ticket);
    const second = ((try host.nextAction()) orelse return error.MissingSecondDial).dial.ticket;
    try std.testing.expect(first != second);
    try std.testing.expect((try host.nextAction()) == null);

    try host.dialFailed(first, "test dial retired");
    try host.dialFailed(second, "test dial retired");
    while (try host.takeAction()) |action| host.freeAction(action);
}

fn tcpSturdyref(designator: []const u8) model.SturdyRef {
    return .{
        .peer = .{
            .transport = model.transport.tcp,
            .designator = designator,
            .hints = model.Hints.emptyFalse(),
        },
        .swissnum = "retry-test",
    };
}

test "event serve OOM condemns the consumed event instead of retrying it" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0f} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, [_]u8{0x10} ** 32, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .host_work_quantum = 1,
    });
    defer host.deinit();
    const pair = try openPair(&client, &host, "127.0.0.1:7099");

    _ = try pair.b.served.publish(&host.vat, "counter", Counter, .{});
    const target = try fetchRef(pair, "counter");
    var serve_attempts: usize = 0;
    pair.b.served.serve_options = .{
        .hook_ctx = &serve_attempts,
        .before_serve = EventServeOutOfMemory.hook,
    };

    try client.tell(pair.a, target, .{ .verb = "hit", .args = &.{} });
    var frame = (try pair.a.takeOutbound()) orelse return error.MissingDeliver;
    defer frame.deinit();
    try pair.b.served.port.peer.recvBorrowed(frame.view());

    // `flushSession` enters the finite Host pump. The event has already been
    // removed by pollEvent when the hook fails, so the Host must condemn it.
    try host.flushSession(pair.b);
    try std.testing.expectEqual(@as(usize, 1), serve_attempts);
    try std.testing.expect(!pair.b.served.port.peer.hasEvent());
    try std.testing.expect(pair.b.isTerminating());

    var saw_close = false;
    while (try host.nextAction()) |action| switch (action) {
        .close => |peer_id| {
            try std.testing.expectEqual(pair.b.peer_id, peer_id);
            saw_close = true;
        },
        else => {},
    };
    try std.testing.expect(saw_close);
}

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
/// budget admits on its Port ingress, so the breach belongs to the fed
/// connection's own dispatch.
const SelfFlood = struct {
    amp: actors.Ref,
    pub fn handle(self: *SelfFlood, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "flood")) return error.NoSuchMethod;
        var i: usize = 0;
        while (i < flood_turns) : (i += 1) {
            try turn.tell(self.amp, .{ .verb = "hit", .args = &.{} });
        }
        return .{ .boolean = true };
    }
};

/// A behavior whose one inbound `flood` floods a *sibling* connection's ingress
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

const host_pair = @import("../support/host_pair.zig");
const Pair = host_pair.Pair;
const pumpToQuiescence = host_pair.pumpToQuiescence;
const openPair = host_pair.openPair;

const CapturedRef = promise_capture.CapturedRef;
const CapturedInt = promise_capture.CapturedInt;

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
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x0b} ** 32, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = budget,
    });
    defer server.deinit();

    const pair = try openPair(&client, &server, "127.0.0.1:7001");
    const amp = try pair.b.host.vat.spawn(Counter, .{});
    _ = try pair.b.served.publish(&pair.b.host.vat, "trigger", SelfFlood, .{ .amp = amp });

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
    var client_a = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client_a.deinit();
    var client_b = test_host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client_b.deinit();
    var server = test_host.init(allocator, [_]u8{0x0b} ** 32, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = budget,
    });
    defer server.deinit();

    const pair_a = try openPair(&client_a, &server, "127.0.0.1:7001");
    const pair_b = try openPair(&client_b, &server, "127.0.0.1:7002");

    // The sibling's amplification target, and the fed connection's trigger
    // that floods it through the host's enqueueing `tell`.
    const amp = try pair_b.b.served.publish(&pair_b.b.host.vat, "amp", Counter, .{});
    _ = try pair_a.b.served.publish(&pair_a.b.host.vat, "trigger", SiblingFlood, .{
        .host = &server,
        .sibling = pair_b.b,
        .target = amp.nearRef(),
    });
    _ = try pair_a.b.served.publish(&pair_a.b.host.vat, "echo", Counter, .{});

    const trigger = try fetchRef(pair_a, "trigger");
    _ = try client_a.send(pair_a.a, trigger, .{ .verb = "flood", .args = &.{} });
    const condemned_ingress = pair_b.b.served.port.ingress;

    // Feed the flood by hand: the fed verb must SUCCEED — the breach belongs
    // to the sibling the flood landed on, not to the connection that fed it.
    var flood_frame = (try pair_a.a.takeOutbound()) orelse return error.NoDeliverQueued;
    defer flood_frame.deinit();
    try server.feed(pair_a.b, flood_frame.view());

    // Condemnation owns cleanup before the fallible abort/CLOSE notification:
    // the Port can no longer enqueue and no queued ingress survives for an
    // embedder release to clean up later.
    try std.testing.expectError(
        actors.Error.UnknownIngress,
        server.vat.tellFromIngress(condemned_ingress, amp.ref, .{ .verb = "hit" }),
    );

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
        driver.core.HostError.SessionCondemned,
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
