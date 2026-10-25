//! Inline gives through the Host: one nested promise identity per give,
//! immediate pipelining through the exporter, and a staged gift whose
//! failure settles its vow.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");
const promise_capture = @import("../../support/capture.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = glowcap.ocapn.engine;
const session_inspect = glowcap.ocapn.session.inspect;
const crypto = glowcap.foundation.crypto;
const stream_framing = glowcap.foundation.stream_framing;

const harness = @import("harness.zig");
const node_harness = @import("../../engine/node/harness.zig");

/// The one signed give every lifecycle case redeems, shared with the Node tests.
const signedGiveForLifecycleTest = node_harness.testGiveBytes;
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
const give_capture = @import("give/capture.zig");
const NestedCallCapture = give_capture.NestedCallCapture;

test "core local capability verbs share admission and publication identity" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x47)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7098", &.{});

    const published = try host.sessionPublish(session, "widget", Widget, .{});
    const looked_up = (try host.publishedCapability(session, "widget")) orelse
        return error.MissingPublishedCapability;
    try std.testing.expect(published.eql(looked_up));
    try host.releaseCapability(looked_up, 1);

    const spawned = try host.spawn(session, Widget, .{});
    const exports_before = session.served.port.exports.count();
    const resolved = (try host.resolveCapability(session, spawned)).resolved;
    try std.testing.expect(resolved.eql(spawned));
    try std.testing.expectEqual(@as(u64, 2), host.capabilities.retainCount(spawned).?);
    try std.testing.expectEqual(exports_before, session.served.port.exports.count());
    try host.releaseCapability(spawned, 1);
    var local_reply = CapturedString{};
    const local_vow = try host.queueSendCapability(session, resolved, .{ .verb = "poke", .args = &.{} });
    try host.vowOn(local_vow, .{ .ctx = &local_reply, .func = CapturedString.record });
    try host.flushSession(session);
    try std.testing.expectEqualStrings("poked over fed bytes", local_reply.text());
    try std.testing.expectEqual(exports_before, session.served.port.exports.count());
    try host.releaseCapability(resolved, 1);

    try host.beginSessionClose(session, .cancel, 0);
    try std.testing.expectError(error.SessionCondemned, host.sessionPublish(session, "late", Widget, .{}));
    try std.testing.expectError(error.SessionCondemned, host.spawn(session, Widget, .{}));
    try std.testing.expectError(error.SessionCondemned, host.resolveCapability(session, published));
    try std.testing.expectError(error.SessionCondemned, host.publishedCapability(session, "widget"));
    try host.releaseCapability(published, 1);
}

test "application-delivered give uses Host identity without fabricating wire rows" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x70)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var partner = test_host.init(allocator, @as([32]u8, @splat(0x71)), Host.Options.withFrameCap(frame_cap));
    defer partner.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |dial| allocator.free(dial.designator);
        dials.deinit(allocator);
    }
    const pair = try openPair(allocator, &host, &partner, "127.0.0.1:7109", &dials);
    const session = pair.a;

    const signed = try signedGiveForLifecycleTest(allocator);
    defer allocator.free(signed);
    const give = try glowcap.ocapn.codec.signed.decodeGiveOwned(allocator, signed);
    defer model.freeHandoffGive(allocator, give);

    const exports_before = session_inspect.exportCount(&session.served.port.peer.session_state);
    const answers_before = session_inspect.inboundAnswerCount(&session.served.port.peer.session_state);
    const pending = try host.acceptInlineGive(session, give);
    try std.testing.expectEqual(@as(usize, 1), host.capability_promises.count());
    try std.testing.expectEqual(exports_before, session_inspect.exportCount(&session.served.port.peer.session_state));
    try std.testing.expectEqual(answers_before, session_inspect.inboundAnswerCount(&session.served.port.peer.session_state));

    // This suite-shaped caller only needs the withdrawal to happen. Dropping
    // the eventual Host capability leaves one typed terminal recipient until
    // the dial outcome arrives; it does not leave a wire answer the partner
    // never learned how to release.
    try host.releaseCapability(pending, 1);
    var dial_ticket: ?engine.Node.PendingId = null;
    var dial_route_index: usize = 0;
    while (try host.nextAction()) |action| switch (action) {
        .dial => |value| {
            dial_ticket = value.ticket;
            dial_route_index = value.route_index;
        },
        .flush => {},
        else => return error.UnexpectedAction,
    };
    try host.dialFailed(dial_ticket orelse return error.MissingDial, dial_route_index, "fixture exporter unavailable");
    while (try host.nextAction()) |action| switch (action) {
        .flush => {},
        else => return error.UnexpectedAction,
    };

    try std.testing.expectEqual(@as(usize, 0), host.capability_promises.count());
    try std.testing.expectEqual(exports_before, session_inspect.exportCount(&session.served.port.peer.session_state));
    try std.testing.expectEqual(answers_before, session_inspect.inboundAnswerCount(&session.served.port.peer.session_state));
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
    const introducing_state = &introducing_pair.a.served.port.peer.session_state;
    try introducing_state.installOutboundAnswer(.from(45));
    try client.node.acceptGive(
        introducing_pair.a.peer_handle,
        introducing_state.outboundAnswerTarget(.from(45)).?,
        give,
        "ocapn://127.0.0.1%3A7099.tcp",
    );
    const dial = client.node.nextAction() orelse return error.MissingDial;
    try std.testing.expect(dial == .dial);
    _ = try client.node.exporterDialed(dial.dial.pending, 0, pair.a.peer_handle);
    const withdraw_flush = client.node.nextAction() orelse return error.MissingFlush;
    try std.testing.expect(withdraw_flush == .flush);

    var pending_withdraws = client.node.redeems.withdrawals.rows.keyIterator();
    const withdraw = pending_withdraws.next() orelse return error.MissingWithdraw;
    const withdraw_target = pair.a.served.port.peer.session_state.outboundAnswerTarget(.from(withdraw.answer)).?;
    try std.testing.expect(try client.node.claimResolve(pair.a.peer_handle, withdraw_target, .not_capability));
    const failure = client.node.nextAction() orelse return error.MissingFailure;
    try std.testing.expect(failure == .fail);

    failing.fail_index = failing.alloc_index;
    var pending: driver.core.PendingSend = undefined;
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

    const lifted = try host.liftValues(pair.a, arena_state.allocator(), .fromOwnedSlice(lowered));
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
    const baseline_operations = session.pendingOperations();
    const baseline_host_operations = host.pending_operations;

    const signed = try signedGiveForLifecycleTest(allocator);
    defer allocator.free(signed);
    const give = try glowcap.ocapn.codec.signed.decodeGiveOwned(allocator, signed);
    defer model.freeHandoffGive(allocator, give);
    var handoff: model.Handoff = .{ .give = give };
    const nested = [_]model.Argument{.{ .tagged = .{
        .tag = "introduced",
        .value = &.{.{ .handoff = &handoff }},
    } }};
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const lifted = try host.liftValues(session, arena_state.allocator(), .fromOwnedSlice(&nested));
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
    try host.dialFailed(dial_ticket.?, 0, "exporter unavailable");
    try std.testing.expect(pipelined.broken);
    try std.testing.expect(listened.broken);
    try std.testing.expectEqualStrings(
        "handoff redeem failed: exporter unavailable",
        pipelined.reason_buf[0..pipelined.reason_len],
    );
    session.served.port.peer.session_state.collectLocalPromiseProjectionsNow();
    try std.testing.expect(session.served.port.peer.session_state.inboundAnswerNamed(backing_answer) == null);
    try std.testing.expect(
        session.served.port.peer.session_state.answerForLocalPromiseExport(projected.near.export_position) == null,
    );
    try std.testing.expect(host.localActorFor(argument_cap) == null);
    try std.testing.expectEqual(baseline_operations, session.pendingOperations());
    try std.testing.expectEqual(baseline_host_operations, host.pending_operations);
    try std.testing.expectError(
        error.PromiseBroken,
        host.sendCapability(session, promise, .{ .verb = "poke", .args = &.{} }),
    );
    try host.releaseCapability(promise, 1);
}

test "core host: releasing queued promise operations cancels their exact ownership" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x52)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var partner = test_host.init(allocator, @as([32]u8, @splat(0x53)), Host.Options.withFrameCap(frame_cap));
    defer partner.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |dial| allocator.free(dial.designator);
        dials.deinit(allocator);
    }
    const pair = try openPair(allocator, &host, &partner, "127.0.0.1:7101", &dials);

    const signed = try signedGiveForLifecycleTest(allocator);
    defer allocator.free(signed);
    const give = try glowcap.ocapn.codec.signed.decodeGiveOwned(allocator, signed);
    defer model.freeHandoffGive(allocator, give);
    var handoff: model.Handoff = .{ .give = give };
    var lift_arena = std.heap.ArenaAllocator.init(allocator);
    defer lift_arena.deinit();
    const lifted = try host.liftValues(pair.a, lift_arena.allocator(), .fromOwnedSlice(&.{.{ .handoff = &handoff }}));
    const promise = lifted[0].capability;
    const promise_id = host.capabilities.resolve(promise).?.deferred;

    const argument = try host.spawn(pair.a, Widget, .{});
    const argument_retains = host.capabilities.retainCount(argument).?;
    const baseline_operations = pair.a.pendingOperations();
    var value_arena = std.heap.ArenaAllocator.init(allocator);
    defer value_arena.deinit();
    const send_vow = try host.queueSendValues(
        pair.a,
        promise,
        "poke",
        &.{.{ .capability = argument }},
        value_arena.allocator(),
    );
    const listen_vow = try host.queueListenToCapability(pair.a, promise);
    try std.testing.expectEqual(@as(usize, 2), host.capability_promises.get(promise_id).?.operations.items.len);
    try std.testing.expectEqual(argument_retains + 1, host.capabilities.retainCount(argument).?);
    try std.testing.expectEqual(baseline_operations + 2, pair.a.pendingOperations());

    try host.vowRelease(send_vow);
    try std.testing.expectEqual(@as(usize, 1), host.capability_promises.get(promise_id).?.operations.items.len);
    try std.testing.expectEqual(argument_retains, host.capabilities.retainCount(argument).?);
    try host.vowRelease(listen_vow);
    try std.testing.expectEqual(@as(usize, 0), host.capability_promises.get(promise_id).?.operations.items.len);
    try std.testing.expectEqual(baseline_operations, pair.a.pendingOperations());
    try std.testing.expectEqual(@as(usize, 0), host.vows.count());

    // Breaking redemption later has no queued operation left to dispatch and
    // cannot recreate either released public result.
    var ticket: ?engine.Node.PendingId = null;
    while (try host.nextAction()) |action| switch (action) {
        .dial => |dial| ticket = dial.ticket,
        .flush => {},
        else => return error.UnexpectedAction,
    };
    try host.dialFailed(ticket orelse return error.MissingDial, 0, "cancelled owner");
    try std.testing.expectEqual(@as(usize, 0), host.capability_promises.get(promise_id).?.operations.items.len);
    while (try host.nextAction()) |action| switch (action) {
        .flush => {},
        .settled => |settled| try std.testing.expect(settled.vow_id != send_vow and settled.vow_id != listen_vow),
        .failed => |failed| try std.testing.expect(failed.vow_id != send_vow and failed.vow_id != listen_vow),
        else => {},
    };

    try host.releaseCapability(argument, 1);
    try host.releaseCapability(promise, 1);
}

const PipeliningCase = struct {
    close_introducer: bool = false,
    application: bool = false,
    version: model.CaptpVersion = .next,
    callback_release: bool = false,
};

fn runNestedGivePipelining(case: PipeliningCase) !void {
    const close_introducer = case.close_introducer;
    const application = case.application;
    const version = case.version;
    const allocator = std.testing.allocator;
    var options = Host.Options.withFrameCap(frame_cap);
    options.captp_version = version;
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
        const body = try glowcap.ocapn.codec.syrup.decodeBodyForProfile(
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
            .handoff => |handoff| switch (try handoff.project()) {
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
    const lifted = try recipient.liftValues(r_to_g.a, lift_arena.allocator(), .fromOwnedSlice(&nested));
    const promise = lifted[0].tagged.value[0].capability;

    // The introducing session is not the redeemed route's home. Another live
    // session may immediately pipeline through the same Host identity; the
    // queued operation must not mistake that source for the exporter route.
    const r_to_anchor = try openPair(allocator, &recipient, &anchor, "127.0.0.1:7113", &dials);
    try std.testing.expect((try recipient.capabilitySession(promise)) == null);

    // Listening to the Host-owned handoff promise observes redemption itself.
    // When it becomes an object under glowcap-next, no second object-listen may
    // be emitted: next permits listens only on promises.
    const readiness_vow = try recipient.queueListenToCapability(r_to_anchor.a, promise);
    var ready = CapturedRef{};
    try recipient.vowOn(readiness_vow, .{ .ctx = &ready, .func = CapturedRef.record });
    const resolution = try recipient.resolveCapability(r_to_anchor.a, promise);
    var resolved_ready = CapturedRef{};
    try recipient.vowOn(resolution.pending, .{ .ctx = &resolved_ready, .func = CapturedRef.record });

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
    const pipelined_vow = if (application) try recipient.sendApplicationValues(
        promise,
        "poke",
        &arguments,
        call_arena.allocator(),
    ) else try recipient.queueSendValues(
        r_to_anchor.a,
        promise,
        "poke",
        &arguments,
        call_arena.allocator(),
    );
    try recipient.releaseCapability(argument_cap, 1);
    var reply = NestedCallCapture{};
    try recipient.vowOn(pipelined_vow, .{ .ctx = &reply, .func = NestedCallCapture.record });
    if (application) try recipient.tellApplicationValues(promise, "poke", &.{}, call_arena.allocator());

    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    try std.testing.expect(dials.items[0].host == &recipient);
    const ticket = dials.items[0].ticket;
    if (close_introducer) {
        try recipient.releaseSession(r_to_g.a);
        try gifter.releaseSession(r_to_g.b);
    }
    const accepted = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7111", &.{});
    const pending = recipient.pendingDial(ticket, 0) orelse return error.MissingPendingDial;
    const dialed = try recipient.openDialedLocator(.{
        .transport = pending.locator.transport,
        .designator = pending.locator.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const r_to_e = Pair{ .ah = &recipient, .a = dialed, .bh = &exporter, .b = accepted };
    if (close_introducer) {
        try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_anchor, r_to_e }, &dials);
    } else {
        try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g, r_to_anchor, r_to_e }, &dials);
    }
    _ = try recipient.exporterDialed(ticket, 0, dialed);
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
            recipient.routeCapability(r_to_anchor.a, promise, .object_only),
        );
        try std.testing.expect(ready.broken);
        try std.testing.expect((try recipient.capabilitySession(promise)) == null);
        try std.testing.expect(resolved_ready.broken);
        if (application) {
            try std.testing.expectError(error.PromiseBroken, recipient.sendApplicationValues(promise, "poke", &.{}, call_arena.allocator()));
            try std.testing.expectError(error.PromiseBroken, recipient.tellApplicationValues(promise, "poke", &.{}, call_arena.allocator()));
        }
    } else {
        try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g, r_to_anchor, r_to_e }, &dials);
        const routed = try recipient.routeCapability(dialed, promise, .object_only);
        try std.testing.expect(routed.session == dialed);
        try std.testing.expect((try recipient.capabilitySession(promise)) == dialed);
        const observed = try recipient.routeSend(dialed, try ready.require(), &.{});
        try std.testing.expect(observed.session == dialed);
        try std.testing.expect(observed.target == .far);
        try std.testing.expect(observed.target.far.kind == .object);
        const generic = try recipient.routeSend(dialed, try resolved_ready.require(), &.{});
        try std.testing.expectEqual(observed.target.far, generic.target.far);
        const settled = (try recipient.resolveCapability(r_to_anchor.a, promise)).resolved;
        try std.testing.expect((try recipient.routeCapability(dialed, settled, .object_only)).session == dialed);
        try recipient.releaseCapability(settled, 1);
        try std.testing.expectEqualStrings("poked over fed bytes", reply.text());
        if (application) {
            var settled_reply = NestedCallCapture{};
            const again = try recipient.sendApplicationValues(promise, "poke", &.{}, call_arena.allocator());
            try recipient.vowOn(again, .{ .ctx = &settled_reply, .func = NestedCallCapture.record });
            try recipient.tellApplicationValues(promise, "poke", &.{}, call_arena.allocator());
            try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g, r_to_anchor, r_to_e }, &dials);
            try std.testing.expectEqualStrings("poked over fed bytes", settled_reply.text());
        }
    }
    try std.testing.expect(recipient.localActorFor(argument_cap) == null);
    if (case.callback_release) {
        try @import("give/abandon_callback.zig").exercise(&recipient, dialed, r_to_g.a, &handoff, promise);
    } else try recipient.releaseCapability(promise, 1);
}

test "core host: a nested give pipelines immediately and settles through its exporter" {
    try runNestedGivePipelining(.{});
}

test "core host: closing a nested give's introducing session breaks its pipeline once" {
    try runNestedGivePipelining(.{ .close_introducer = true });
}

test "core host: application sends and tells pipeline through handed-off capabilities" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |version| {
        try runNestedGivePipelining(.{ .application = true, .version = version });
        try runNestedGivePipelining(.{ .close_introducer = true, .application = true, .version = version });
    }
}

test "core host: fulfilled promise release survives callback promise map growth" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |version|
        try runNestedGivePipelining(.{ .version = version, .callback_release = true });
}
