//! Inline gives through the Host: one nested promise identity per give,
//! immediate pipelining through the exporter, and a staged gift whose
//! failure settles its vow.

const std = @import("std");
const pancake = @import("pancake");
const test_host = @import("../../support/core_host.zig");
const promise_capture = @import("../../support/capture.zig");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = pancake.ocapn.engine;
const crypto = pancake.foundation.crypto;
const stream_framing = pancake.foundation.stream_framing;

const harness = @import("harness.zig");
const frame_cap = harness.frame_cap;
const Widget = harness.Widget;
const FairCounter = harness.FairCounter;
const Vendor = harness.Vendor;
const Introducer = harness.Introducer;
const host_pair = harness.host_pair;
const handshake_support = harness.handshake_support;
const Pair = harness.Pair;
const shuttle = harness.shuttle;
const shuttleAll = harness.shuttleAll;
const tcpLocator = harness.tcpLocator;
const publishAndOpenAccepted = harness.publishAndOpenAccepted;
const publishAndOpenAcceptedOver = harness.publishAndOpenAcceptedOver;
const tcpSturdyref = harness.tcpSturdyref;
const onionLocator = harness.onionLocator;
const onionSturdyref = harness.onionSturdyref;
const ParkedDial = harness.ParkedDial;
const drainActions = harness.drainActions;
const pumpToQuiescence = harness.pumpToQuiescence;
const CapturedRef = harness.CapturedRef;
const CapturedString = harness.CapturedString;
const openPair = harness.openPair;
const retireClosingSession = harness.retireClosingSession;
const retireClosedSession = harness.retireClosedSession;
const Tagged = harness.Tagged;
const keyedDesignator = harness.keyedDesignator;
const TraceLog = harness.TraceLog;

fn signedGiveForLifecycleTest(allocator: std.mem.Allocator) ![]u8 {
    const location = try engine.encodePeerLocatorRecord(allocator, .{
        .transport = "tcp",
        .designator = "127.0.0.1:9099",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(location);
    const secret = crypto.SecretKey.fromSeed(@as([crypto.SEED_BYTES]u8, @splat(0x77)));
    return engine.handoff_gifter.buildSignedGive(
        allocator,
        secret,
        &(@as([32]u8, @splat(0x01))),
        location,
        &(@as([32]u8, @splat(0x02))),
        &(@as([32]u8, @splat(0x03))),
        &(@as([32]u8, @splat(0x04))),
    );
}

test "core local capability verbs share admission and publication identity" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x47)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7098", &.{});

    const published = try host.publish(session, "widget", Widget, .{});
    const looked_up = (try host.publishedCapability(session, "widget")) orelse
        return error.MissingPublishedCapability;
    try std.testing.expect(published.eql(looked_up));
    try host.releaseCapability(looked_up, 1);

    const spawned = try host.spawn(session, Widget, .{});
    const exports_before = session.served.port.exports.count();
    var local_reply = CapturedString{};
    const local_vow = try host.queueSendCapability(session, spawned, .{ .verb = "poke", .args = &.{} });
    try host.vowOn(local_vow, .{ .ctx = &local_reply, .func = CapturedString.record });
    try host.flushSession(session);
    try std.testing.expectEqualStrings("poked over fed bytes", local_reply.text());
    try std.testing.expectEqual(exports_before, session.served.port.exports.count());
    try host.releaseCapability(spawned, 1);

    try host.beginSessionClose(session, .cancel, 0);
    try std.testing.expectError(error.SessionCondemned, host.publish(session, "late", Widget, .{}));
    try std.testing.expectError(error.SessionCondemned, host.spawn(session, Widget, .{}));
    try std.testing.expectError(error.SessionCondemned, host.publishedCapability(session, "widget"));
    try host.releaseCapability(published, 1);
}

test "failed application operation leaves a provisional exporter retireable" {
    const allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var client = test_host.init(failing.allocator(), @as([32]u8, @splat(0x48)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x49)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var introducer = test_host.init(allocator, @as([32]u8, @splat(0x4f)), Host.Options.withFrameCap(frame_cap));
    defer introducer.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7099", &dials);
    const introducing_pair = try openPair(allocator, &client, &introducer, "127.0.0.1:7097", &dials);

    const give = try signedGiveForLifecycleTest(allocator);
    defer allocator.free(give);
    try client.node.acceptGive(introducing_pair.a.peer_handle, 45, give, "ocapn://127.0.0.1%3A7099.tcp");
    const dial = client.node.nextAction() orelse return error.MissingDial;
    try std.testing.expect(dial == .dial);
    try client.node.exporterDialed(dial.dial.pending, pair.a.peer_handle);
    const withdraw_flush = client.node.nextAction() orelse return error.MissingFlush;
    try std.testing.expect(withdraw_flush == .flush);

    var pending_withdraws = client.node.redeems.withdrawals.rows.keyIterator();
    const withdraw = pending_withdraws.next() orelse return error.MissingWithdraw;
    try std.testing.expect(try client.node.claimResolve(pair.a.peer_handle, withdraw.answer, .not_capability));
    const failure = client.node.nextAction() orelse return error.MissingFailure;
    try std.testing.expect(failure == .fail);

    failing.fail_index = failing.alloc_index;
    var pending: driver.core.Served.PendingSend = undefined;
    try std.testing.expectError(error.OutOfMemory, client.beginSendNamed(
        pair.a,
        &pending,
        "anything",
        .{ .verb = "call", .args = &.{} },
        .{ .ctx = null, .func = struct {
            fn fire(_: ?*anyopaque, _: actors.Resolution) void {}
        }.fire },
    ));
    failing.fail_index = std.math.maxInt(usize);

    const retire = client.node.nextAction() orelse return error.MissingRetirement;
    try std.testing.expect(retire == .retire_exporter);
    try std.testing.expect(client.node.claimExporterRetirement(retire.retire_exporter));
}

test "core host: Error remains fulfilled data across recursive lower and lift" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x48)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var partner = test_host.init(allocator, @as([32]u8, @splat(0x49)), Host.Options.withFrameCap(frame_cap));
    defer partner.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |dial| allocator.free(dial.designator);
        dials.deinit(allocator);
    }
    const pair = try openPair(allocator, &host, &partner, "127.0.0.1:7099", &dials);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const values = [_]driver.core.Value{.{ .list = &.{
        .{ .@"error" = .{ .message = "failure is a value" } },
    } }};
    const lowered = try host.lowerValues(pair.a, arena_state.allocator(), &values);
    try std.testing.expect(lowered[0] == .list);
    try std.testing.expect(lowered[0].list[0] == .@"error");
    try std.testing.expectEqualStrings("failure is a value", lowered[0].list[0].@"error".message);

    const lifted = try host.liftValues(pair.a, arena_state.allocator(), lowered);
    try std.testing.expect(lifted[0] == .list);
    try std.testing.expect(lifted[0].list[0] == .@"error");
    try std.testing.expectEqualStrings("failure is a value", lifted[0].list[0].@"error".message);

    const fulfilled: driver.core.Reply = .{ .fulfilled = lifted[0].list[0] };
    const broken: driver.core.Reply = .{ .broken = "failure is an outcome" };
    try std.testing.expect(fulfilled == .fulfilled);
    try std.testing.expect(broken == .broken);
}

test "core host: an inline give becomes one nested promise identity and terminally breaks" {
    const allocator = std.testing.allocator;
    var options = Host.Options.withFrameCap(frame_cap);
    options.limits.queue_cap = 3;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x4a)), options);
    defer host.deinit();
    var partner = test_host.init(allocator, @as([32]u8, @splat(0x4b)), Host.Options.withFrameCap(frame_cap));
    defer partner.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |dial| allocator.free(dial.designator);
        dials.deinit(allocator);
    }
    const pair = try openPair(allocator, &host, &partner, "127.0.0.1:7100", &dials);
    const session = pair.a;

    const signed = try signedGiveForLifecycleTest(allocator);
    defer allocator.free(signed);
    const give = try pancake.ocapn.codec.signed.decodeGiveOwned(allocator, signed);
    defer model.freeHandoffGive(allocator, give);
    var handoff: model.Handoff = .{ .give = give };
    const nested = [_]model.Argument{.{ .tagged = .{
        .tag = "introduced",
        .value = &.{.{ .handoff = &handoff }},
    } }};
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const lifted = try host.liftValues(session, arena_state.allocator(), &nested);
    try std.testing.expectEqual(@as(usize, 1), lifted.len);
    try std.testing.expect(lifted[0] == .tagged);
    try std.testing.expectEqualStrings("introduced", lifted[0].tagged.tag);
    try std.testing.expectEqual(@as(usize, 1), lifted[0].tagged.value.len);
    try std.testing.expect(lifted[0].tagged.value[0] == .capability);
    const promise = lifted[0].tagged.value[0].capability;
    const projected = try host.lowerCapability(session, promise);
    try std.testing.expect(projected == .near);
    try std.testing.expectEqual(model.RefKind.promise, projected.near.kind);
    const backing_answer = session.served.port.peer.session_state.answerForLocalPromiseExport(
        projected.near.export_position,
    ) orelse return error.MissingPromiseAnswer;

    // The queued value tree owns every nested capability until the eventual
    // delivery commits or breaks. Releasing the caller's copy must not make a
    // later redemption observe a stale handle.
    const argument_cap = try host.spawn(session, Widget, .{});
    const nested_argument = [_]driver.core.Value{.{ .list = &.{.{ .capability = argument_cap }} }};
    const pipelined_vow = try host.queueSendValues(
        session,
        promise,
        "poke",
        &nested_argument,
        arena_state.allocator(),
    );
    try host.releaseCapability(argument_cap, 1);
    try std.testing.expect(host.localActorFor(argument_cap) != null);
    var pipelined = promise_capture.CapturedRef{};
    try host.vowOn(pipelined_vow, .{ .ctx = &pipelined, .func = promise_capture.CapturedRef.record });

    const listen_vow = try host.queueListenToCapability(session, promise);
    var listened = promise_capture.CapturedRef{};
    try host.vowOn(listen_vow, .{ .ctx = &listened, .func = promise_capture.CapturedRef.record });
    try host.tellValues(session, promise, "poke", &.{}, arena_state.allocator());
    try std.testing.expectError(
        error.QueueCapExceeded,
        host.queueListenToCapability(session, promise),
    );

    // Value projection returns before redemption completes. The one network
    // effect belongs to that Host identity, and exhaustion terminally breaks
    // the identity instead of leaving an action-only failure behind.
    var dial_ticket: ?engine.Node.PendingId = null;
    while (try host.nextAction()) |action| switch (action) {
        .dial => |dial| dial_ticket = dial.ticket,
        .flush => while (try session.takeOutbound()) |frame_value| {
            var frame = frame_value;
            frame.deinit();
        },
        else => return error.UnexpectedAction,
    };
    try std.testing.expect(dial_ticket != null);
    try host.dialFailed(dial_ticket.?, "exporter unavailable");
    try std.testing.expect(pipelined.broken);
    try std.testing.expect(listened.broken);
    try std.testing.expectEqualStrings(
        "handoff redeem failed: exporter unavailable",
        pipelined.reason_buf[0..pipelined.reason_len],
    );
    try std.testing.expect(session.served.port.peer.session_state.inboundAnswerNamed(backing_answer) == null);
    try std.testing.expect(
        session.served.port.peer.session_state.answerForLocalPromiseExport(projected.near.export_position) == null,
    );
    try std.testing.expect(host.localActorFor(argument_cap) == null);
    try std.testing.expectError(
        error.PromiseBroken,
        host.sendCapability(session, promise, .{ .verb = "poke", .args = &.{} }),
    );
    try host.releaseCapability(promise, 1);
}

const NestedCallCapture = struct {
    text_buf: [128]u8 = undefined,
    text_len: usize = 0,
    reason_buf: [128]u8 = undefined,
    reason_len: usize = 0,
    broken: bool = false,

    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *NestedCallCapture = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| if (value == .string) {
                self.text_len = @min(value.string.len, self.text_buf.len);
                @memcpy(self.text_buf[0..self.text_len], value.string[0..self.text_len]);
            },
            .broken => |message| {
                self.broken = true;
                self.reason_len = @min(message.len, self.reason_buf.len);
                @memcpy(self.reason_buf[0..self.reason_len], message[0..self.reason_len]);
            },
            .give => self.broken = true,
        }
    }

    fn text(self: *const NestedCallCapture) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    fn reason(self: *const NestedCallCapture) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }
};

fn runNestedGivePipelining(close_introducer: bool) !void {
    const allocator = std.testing.allocator;
    var options = Host.Options.withFrameCap(frame_cap);
    options.captp_version = .next;
    var exporter = test_host.init(allocator, @as([32]u8, @splat(0x5e)), options);
    defer exporter.deinit();
    var gifter = test_host.init(allocator, @as([32]u8, @splat(0x56)), options);
    defer gifter.deinit();
    var recipient = test_host.init(allocator, @as([32]u8, @splat(0x5c)), options);
    defer recipient.deinit();
    var anchor = test_host.init(allocator, @as([32]u8, @splat(0x54)), options);
    defer anchor.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient, &anchor };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7111", &dials);
    _ = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "widget", Widget, .{});
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);

    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7112", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{
        .widget = try widget.require(),
    });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{
        .ctx = &introducer,
        .func = CapturedRef.record,
    });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);

    // Ask the existing origination authority for a real signed give, but hold
    // its top-level resolve frame. Re-embedding that exact give below isolates
    // the inbound "Passable anywhere" contract from the outbound rewrite pass.
    _ = try recipient.send(r_to_g.a, try introducer.require(), .{ .verb = "introduce", .args = &.{} });
    try std.testing.expect(try shuttle(r_to_g));
    const gift_id = @as([32]u8, @splat(0x6d));
    var provided = false;
    while (try gifter.nextAction()) |action| switch (action) {
        .flush => {},
        .need_gift_id => |needed| {
            try gifter.provideGiftId(needed.ticket, &gift_id);
            provided = true;
        },
        else => return error.UnexpectedAction,
    };
    try std.testing.expect(provided);
    try std.testing.expect(try shuttle(g_to_e));

    var owned_give: ?model.HandoffGive = null;
    while (try r_to_g.b.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        const body = try pancake.ocapn.codec.syrup.decodeBodyForProfile(
            r_to_g.b.served.port.peer.session_state.captp_version,
            frame.view(),
        );
        const payload = switch (body) {
            .resolve => |resolve| switch (resolve.resolution) {
                .fulfill => |value| value,
                .@"break" => continue,
            },
            .deliver => |deliver| blk: {
                if (try deliver.args.len() != 2) continue;
                const verb = try deliver.args.at(0);
                if (verb != .symbol or !std.mem.eql(u8, verb.symbol, "fulfill")) continue;
                break :blk try deliver.args.at(1);
            },
            else => continue,
        };
        const view = switch (payload) {
            .handoff => |handoff| switch (handoff) {
                .give => |give| give,
                .receive => continue,
            },
            else => continue,
        };
        owned_give = try view.toOwned(allocator);
        break;
    }
    const give = owned_give orelse return error.MissingGive;
    defer model.freeHandoffGive(allocator, give);

    var handoff: model.Handoff = .{ .give = give };
    const nested = [_]model.Argument{.{ .tagged = .{
        .tag = "introduced",
        .value = &.{.{ .handoff = &handoff }},
    } }};
    var lift_arena = std.heap.ArenaAllocator.init(allocator);
    defer lift_arena.deinit();
    const lifted = try recipient.liftValues(r_to_g.a, lift_arena.allocator(), &nested);
    const promise = lifted[0].tagged.value[0].capability;

    // The introducing session is not the redeemed route's home. Another live
    // session may immediately pipeline through the same Host identity; the
    // queued operation must not mistake that source for the exporter route.
    const r_to_anchor = try openPair(allocator, &recipient, &anchor, "127.0.0.1:7113", &dials);

    // The pending message owns this nested capability after the caller drops
    // its copy. Successful redemption must still lower the retained identity
    // on the exporter session before releasing it.
    const argument_cap = try recipient.spawn(r_to_anchor.a, Widget, .{});
    const arguments = [_]driver.core.Value{.{ .tagged = .{
        .tag = "argument",
        .value = &.{.{ .capability = argument_cap }},
    } }};
    var call_arena = std.heap.ArenaAllocator.init(allocator);
    defer call_arena.deinit();
    const pipelined_vow = try recipient.queueSendValues(
        r_to_anchor.a,
        promise,
        "poke",
        &arguments,
        call_arena.allocator(),
    );
    try recipient.releaseCapability(argument_cap, 1);
    var reply = NestedCallCapture{};
    try recipient.vowOn(pipelined_vow, .{ .ctx = &reply, .func = NestedCallCapture.record });

    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    try std.testing.expect(dials.items[0].host == &recipient);
    const ticket = dials.items[0].ticket;
    if (close_introducer) {
        try recipient.releaseSession(r_to_g.a);
        try gifter.releaseSession(r_to_g.b);
    }
    const accepted = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7111", &.{});
    const pending = recipient.pendingDial(ticket) orelse return error.MissingPendingDial;
    const dialed = try recipient.openDialedLocator(.{
        .transport = pending.transport,
        .designator = pending.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const r_to_e = Pair{ .ah = &recipient, .a = dialed, .bh = &exporter, .b = accepted };
    if (close_introducer) {
        try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_anchor, r_to_e }, &dials);
    } else {
        try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g, r_to_anchor, r_to_e }, &dials);
    }
    try recipient.exporterDialed(ticket, dialed);
    if (close_introducer) {
        try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_anchor, r_to_e }, &dials);
        try std.testing.expect(reply.broken);
        try std.testing.expect(std.mem.indexOf(u8, reply.reason(), "connection released") != null);
        try std.testing.expectEqual(
            @as(usize, 0),
            recipient.node.redeems.withdrawals.rows.count(),
        );
        try std.testing.expectError(
            error.PromiseBroken,
            recipient.routeCapability(r_to_anchor.a, promise, true),
        );
    } else {
        try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g, r_to_anchor, r_to_e }, &dials);
        const routed = try recipient.routeCapability(dialed, promise, true);
        try std.testing.expect(routed.session == dialed);
        try std.testing.expectEqualStrings("poked over fed bytes", reply.text());
    }
    try std.testing.expect(recipient.localActorFor(argument_cap) == null);
    try recipient.releaseCapability(promise, 1);
}

test "core host: a nested give pipelines immediately and settles through its exporter" {
    try runNestedGivePipelining(false);
}

test "core host: closing a nested give's introducing session breaks its pipeline once" {
    try runNestedGivePipelining(true);
}

test "core host: a staged inline gift owns its capability and failure settles its vow" {
    const allocator = std.testing.allocator;
    var options = Host.Options.withFrameCap(frame_cap);
    options.captp_version = .next;
    var exporter = test_host.init(allocator, @as([32]u8, @splat(0x31)), options);
    defer exporter.deinit();
    var gifter = test_host.init(allocator, @as([32]u8, @splat(0x32)), options);
    defer gifter.deinit();
    var recipient = test_host.init(allocator, @as([32]u8, @splat(0x33)), options);
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7061", &dials);
    _ = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "widget", Widget, .{});
    var widget_wire = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{
        .ctx = &widget_wire,
        .func = CapturedRef.record,
    });

    const g_to_r = try openPair(allocator, &gifter, &recipient, "127.0.0.1:7062", &dials);
    _ = try g_to_r.b.served.publish(&g_to_r.b.host.vat, "sink", Widget, .{});
    var sink_wire = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_r.a, "sink"), .{
        .ctx = &sink_wire,
        .func = CapturedRef.record,
    });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, g_to_r }, &dials);

    const widget = try gifter.liftCapability(g_to_e.a, try widget_wire.require());
    const sink = try gifter.liftCapability(g_to_r.a, try sink_wire.require());
    defer gifter.releaseCapability(sink, 1) catch {};
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const nested = [_]driver.core.Value{.{ .tagged = .{
        .tag = "delegated",
        .value = &.{.{ .list = &.{.{ .capability = widget }} }},
    } }};
    const staged_vow = try gifter.queueSendValues(g_to_r.a, sink, "poke", &nested, arena.allocator());
    var staged_reply = NestedCallCapture{};
    try gifter.vowOn(staged_vow, .{ .ctx = &staged_reply, .func = NestedCallCapture.record });

    // The accepted send, not the caller, now owns the delayed occurrence.
    // Dropping the caller's only handle cannot retire its exporter route while
    // gift-id entropy is outstanding.
    try gifter.releaseCapability(widget, 1);
    try std.testing.expect(gifter.capabilitySession(widget) == g_to_e.a);

    var gift_ticket: ?u64 = null;
    while (try gifter.nextAction()) |action| switch (action) {
        .need_gift_id => |needed| gift_ticket = needed.ticket,
        .flush => |peer_handle| {
            const session = if (peer_handle == g_to_e.a.peer_handle)
                g_to_e.a
            else if (peer_handle == g_to_r.a.peer_handle)
                g_to_r.a
            else
                continue;
            while (try session.takeOutbound()) |frame_value| {
                var frame = frame_value;
                frame.deinit();
            }
        },
        else => return error.UnexpectedAction,
    };
    try std.testing.expect(gift_ticket != null);
    try std.testing.expect(gifter.capabilitySession(widget) == g_to_e.a);

    try gifter.giftIdFailed(gift_ticket.?);
    try std.testing.expect(staged_reply.broken);
    try std.testing.expect(std.mem.indexOf(u8, staged_reply.reason(), "GiftIdUnavailable") != null);
    try std.testing.expect(g_to_r.a.isTerminating());
    while (try gifter.nextAction()) |action| switch (action) {
        .flush => |peer_handle| {
            const session = if (peer_handle == g_to_e.a.peer_handle)
                g_to_e.a
            else if (peer_handle == g_to_r.a.peer_handle)
                g_to_r.a
            else
                continue;
            while (try session.takeOutbound()) |frame_value| {
                var frame = frame_value;
                frame.deinit();
            }
        },
        .close => {},
        else => return error.UnexpectedAction,
    };
    try std.testing.expect(gifter.capabilitySession(widget) == null);
}
