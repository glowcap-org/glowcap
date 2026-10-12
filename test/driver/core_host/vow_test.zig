//! Vows and unobserved completions: listener rows retire on settle while
//! public handles retire on release, failed dials
//! break the redeeming vow with the reason, unlistened settles ride the
//! action queue owned, a burst never strands on the reserved queue, and
//! fetch failures stay pre-commit.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const stream_framing = glowcap.foundation.stream_framing;

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
const vow_widget_pair = @import("vow/widget_pair.zig");
const openWidgetPair = vow_widget_pair.open;

test "core host fresh vow id exhaustion refuses before publishing a vow row" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x49)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7000", &.{});

    host.next_vow = std.math.maxInt(u64);
    try std.testing.expectError(
        error.CapabilitySpaceExhausted,
        host.queueFetch(session, "widget"),
    );
    try std.testing.expectEqual(@as(usize, 0), host.vows.count());
    try std.testing.expectEqual(std.math.maxInt(u64), host.next_vow);
}

test "core host: listener vows retire on settle and public vows remain sendable until release" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x4a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x4b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);
    // Stateless serving still owns unclaimed actor answers. Host vows claim
    // their own release, so this policy cannot retire a public pipeline target
    // or duplicate an observed vow's release.
    pair.a.served.serve_options.gc_stateless = true;
    const widget_local = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
    _ = try pair.b.served.publish(&pair.b.host.vat, "vendor", Vendor, .{ .widget = widget_local.nearRef() });
    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "widget"), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const widget_ref = try fetched.require();
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());

    // In-process listeners consume their rows at settle. Public handles stay
    // addressable until release, exactly like their answer positions.
    var public_vows: [2]u64 = undefined;
    var public_count: usize = 0;
    for (0..4) |i| {
        const vow = try client.send(pair.a, widget_ref, .{ .verb = "poke", .args = &.{} });
        var reply = CapturedString{};
        if (i % 2 == 0) {
            try client.vowOn(vow, .{ .ctx = &reply, .func = CapturedString.record });
        } else {
            public_vows[public_count] = vow;
            public_count += 1;
        }
        try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
        if (i % 2 == 0) try std.testing.expectEqualStrings("poked over fed bytes", reply.buf[0..reply.len]);
    }
    try std.testing.expectEqual(@as(usize, 2), client.vows.count());
    for (public_vows) |vow| try client.vowRelease(vow);
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());

    // Settlement does not release the answer position. Force a complete
    // round trip before addressing the vendor's settled answer, then prove
    // only explicit release makes that pipeline target unavailable.
    var fetched_vendor = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "vendor"), .{ .ctx = &fetched_vendor, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const make_vow = try client.send(pair.a, try fetched_vendor.require(), .{ .verb = "make", .args = &.{} });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectEqual(@as(usize, 1), client.vows.count());
    try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());

    const late_send = try client.vowSend(make_vow, .{ .verb = "poke", .args = &.{} });
    var late_reply = CapturedString{};
    try client.vowOn(late_send, .{ .ctx = &late_reply, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectEqualStrings("poked over fed bytes", late_reply.buf[0..late_reply.len]);

    try client.vowRelease(make_vow);
    try std.testing.expectError(
        driver.core.HostError.NoSuchVow,
        client.vowSend(make_vow, .{ .verb = "poke", .args = &.{} }),
    );
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    // One listener per vow, and a settled id is gone.
    const observed = try client.send(pair.a, widget_ref, .{ .verb = "poke", .args = &.{} });
    var first = CapturedString{};
    var second = CapturedString{};
    try client.vowOn(observed, .{ .ctx = &first, .func = CapturedString.record });
    try std.testing.expectError(actors.Error.AlreadyListening, client.vowOn(observed, .{ .ctx = &second, .func = CapturedString.record }));
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectError(driver.core.HostError.NoSuchVow, client.vowOn(observed, .{ .ctx = &second, .func = CapturedString.record }));
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());

    // A vow whose resolve never arrives is freed at release: the connection
    // break fires it broken through the retire chain.
    const parked = try client.send(pair.a, widget_ref, .{ .verb = "poke", .args = &.{} });
    var broken = CapturedRef{};
    try client.vowOn(parked, .{ .ctx = &broken, .func = CapturedRef.record });
    try client.releaseSession(pair.a);
    try std.testing.expect(broken.broken);
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
}

test "core host: observed remote vows release answer ownership in both profiles" {
    try expectObservedRemoteRelease(.v1_0, 0x52, "127.0.0.1:7003");
    try expectObservedRemoteRelease(.next, 0x54, "127.0.0.1:7004");
}

test "core host: promise-pipelined tell mints no answer or public vow" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x58)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x59)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7005", &dials);
    var hits: usize = 0;
    const counter = try pair.b.served.publish(&pair.b.host.vat, "counter", FairCounter, .{ .hits = &hits });
    _ = try pair.b.served.publish(&pair.b.host.vat, "vendor", Vendor, .{ .widget = counter.nearRef() });
    var vendor = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "vendor"), .{ .ctx = &vendor, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    const made = try client.send(pair.a, try vendor.require(), .{ .verb = "make" });
    const answers_before_tell = pair.a.served.port.peer.session_state.outbound_answers.len();
    try client.vowTellValues(made, "hit", &.{}, allocator);
    try std.testing.expectEqual(answers_before_tell, pair.a.served.port.peer.session_state.outbound_answers.len());
    try std.testing.expectEqual(@as(usize, 1), client.vows.count());

    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectEqual(@as(usize, 1), hits);
    try std.testing.expectEqual(@as(usize, 1), client.vows.count());
    try client.vowRelease(made);
}

fn expectObservedRemoteRelease(
    profile: model.CaptpVersion,
    seed: u8,
    designator: []const u8,
) !void {
    const allocator = std.testing.allocator;
    var options = Host.Options.withFrameCap(frame_cap);
    options.captp_version = profile;
    options.features = model.FeatureSet.full().forCaptpVersion(profile);
    var client = test_host.init(allocator, @as([32]u8, @splat(seed)), options);
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(seed + 1)), options);
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, designator, &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
    const client_state = &pair.a.served.port.peer.session_state;
    const server_state = &pair.b.served.port.peer.session_state;
    const client_answers = client_state.outbound_answers.len();
    const client_resolvers = client_state.outbound_resolver_link.len();
    const client_exports = client_state.exports.len();
    const server_answers = server_state.inbound_answers.len();

    const vow = try client.fetch(pair.a, "widget");
    var fetched = CapturedRef{};
    try client.vowOn(vow, .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    _ = try fetched.require();
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
    try std.testing.expectEqual(client_answers, client_state.outbound_answers.len());
    try std.testing.expectEqual(client_resolvers, client_state.outbound_resolver_link.len());
    try std.testing.expectEqual(client_exports, client_state.exports.len());
    try std.testing.expectEqual(server_answers, server_state.inbound_answers.len());
}

test "core host: releasing a pending or condemned vow retires its listener exactly once" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x4c)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x4d)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const opened = try openWidgetPair(allocator, &client, &server, &dials);
    const state = &opened.pair.a.served.port.peer.session_state;
    const baseline_answers = state.outbound_answers.len();
    const baseline_resolvers = state.outbound_resolver_link.len();
    const baseline_exports = state.exports.len();
    const pending = try client.send(opened.pair.a, opened.widget, .{ .verb = "poke", .args = &.{} });
    try std.testing.expectEqual(baseline_answers + 1, state.outbound_answers.len());
    try std.testing.expectEqual(@as(usize, 1), client.pendingVowCount());
    try client.vowRelease(pending);
    try client.vowRelease(pending);
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
    try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{opened.pair}, &dials);
    try std.testing.expectEqual(baseline_answers, state.outbound_answers.len());
    try std.testing.expectEqual(baseline_resolvers, state.outbound_resolver_link.len());
    try std.testing.expectEqual(baseline_exports, state.exports.len());

    const condemned = try client.send(opened.pair.a, opened.widget, .{ .verb = "poke", .args = &.{} });
    try client.beginSessionClose(opened.pair.a, .cancel, 0);
    try client.vowRelease(condemned);
    try client.vowRelease(condemned);
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
    try std.testing.expectEqual(@as(usize, 0), client.pendingVowCount());
}

test "core host: releasing an in-flight enliven clears dedup state for immediate retry" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x4e)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x4f)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7002", &dials);
    const sturdyref = tcpSturdyref("127.0.0.1:7002", "retryable");
    const baseline_operations = pair.a.pendingOperations();
    const baseline_answers = pair.a.served.port.peer.session_state.outbound_answers.len();

    const first = try client.enliven(pair.a, sturdyref);
    try std.testing.expectEqual(baseline_operations + 1, pair.a.pendingOperations());
    try client.vowRelease(first);
    try std.testing.expectEqual(baseline_operations, pair.a.pendingOperations());
    try std.testing.expectEqual(baseline_answers, pair.a.served.port.peer.session_state.outbound_answers.len());

    // The first release removed the session's in-flight swissnum marker. A
    // retry therefore mints a fresh wire question instead of observing a
    // stranded `AlreadyListening` state.
    const retry = try client.enliven(pair.a, sturdyref);
    try std.testing.expect(retry != first);
    try client.vowRelease(retry);
    try std.testing.expectEqual(baseline_operations, pair.a.pendingOperations());
    try std.testing.expectEqual(baseline_answers, pair.a.served.port.peer.session_state.outbound_answers.len());
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
}

test "core host: local listen release retires answer and resolver ownership" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x50)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x51)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const opened = try openWidgetPair(allocator, &client, &server, &dials);
    const state = &opened.pair.a.served.port.peer.session_state;
    const baseline_answers = state.outbound_answers.len();
    const baseline_resolvers = state.outbound_resolver_link.len();
    const baseline_exports = state.exports.len();

    const pending = try client.queueListenTo(opened.pair.a, opened.widget);
    const pending_answer = client.vows.get(pending).?.vow.far;
    const pending_resolver = state.outbound_resolver_link.getByValue(.{
        .application_answer = pending_answer,
    }).?;
    try std.testing.expectEqual(baseline_answers + 1, state.outbound_answers.len());
    try std.testing.expectEqual(baseline_resolvers + 1, state.outbound_resolver_link.len());
    try std.testing.expectEqual(@as(u64, 1), state.exports.wireHeld(pending_resolver));
    try client.vowRelease(pending);
    try std.testing.expectEqual(baseline_answers, state.outbound_answers.len());
    try std.testing.expectEqual(.pending, state.retiredResolverState(pending_resolver).?);
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{opened.pair}, &dials);
    try std.testing.expectEqual(@as(u64, 0), state.exports.wireHeld(pending_resolver));
    try std.testing.expect(state.retiredResolverState(pending_resolver) == null);
    try std.testing.expect(!state.exports.contains(pending_resolver));
    try std.testing.expectEqual(baseline_resolvers, state.outbound_resolver_link.len());
    try std.testing.expectEqual(baseline_exports, state.exports.len());

    const settled = try client.queueListenTo(opened.pair.a, opened.widget);
    const settled_answer = client.vows.get(settled).?.vow.far;
    const settled_resolver = state.outbound_resolver_link.getByValue(.{
        .application_answer = settled_answer,
    }).?;
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{opened.pair}, &dials);
    try std.testing.expectEqual(baseline_answers + 1, state.outbound_answers.len());
    try std.testing.expectEqual(@as(u64, 0), state.exports.wireHeld(settled_resolver));
    try client.vowRelease(settled);
    try std.testing.expect(!state.exports.contains(settled_resolver));
    try std.testing.expectEqual(baseline_answers, state.outbound_answers.len());
    try std.testing.expectEqual(baseline_resolvers, state.outbound_resolver_link.len());
    try std.testing.expectEqual(baseline_exports, state.exports.len());

    const observed = try client.queueListenTo(opened.pair.a, opened.widget);
    var observed_value = CapturedRef{};
    try client.vowOn(observed, .{ .ctx = &observed_value, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{opened.pair}, &dials);
    _ = try observed_value.require();
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
    try std.testing.expectEqual(baseline_answers, state.outbound_answers.len());
    try std.testing.expectEqual(baseline_resolvers, state.outbound_resolver_link.len());
    try std.testing.expectEqual(baseline_exports, state.exports.len());
}

test "core host: a failed dial breaks the redeeming vow with the reason" {
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, @as([32]u8, @splat(0x0e)), Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, @as([32]u8, @splat(0x06)), Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, @as([32]u8, @splat(0x0c)), Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7001", &dials);
    _ = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "widget", Widget, .{});
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);

    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7002", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = widget.ref.? });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);

    const introduce_vow = try recipient.send(r_to_g.a, introducer.ref.?, .{ .verb = "introduce", .args = &.{} });
    var redeemed = CapturedRef{};
    try recipient.vowOn(introduce_vow, .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);

    // The exporter is unreachable: the dial's failure breaks the vow.
    try recipient.dialFailed(dials.items[0].ticket, 0, "exporter unreachable");
    try std.testing.expect(redeemed.broken);
    try std.testing.expect(redeemed.ref == null);
}

test "core host: an unlistened settle rides the action queue owned, valid until the next nextAction frees it" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x5a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x5b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const opened = try openWidgetPair(allocator, &client, &server, &dials);

    // No listener anywhere: the settle must surface as a queued completion.
    const vow = try client.send(opened.pair.a, opened.widget, .{ .verb = "poke", .args = &.{} });
    _ = try shuttleAll(&.{opened.pair}); // the deliver reaches the server
    _ = try shuttleAll(&.{opened.pair}); // the resolve settles the vow

    // Drain by hand: the popped completion's deep-cloned value stays valid
    // across this whole iteration, the next `nextAction` call frees it,
    // while the public target row remains retained until release.
    var settle_count: usize = 0;
    while (try client.nextAction()) |action| {
        switch (action) {
            .flush => {},
            .settled => |s| {
                try std.testing.expectEqual(vow, s.vow_id);
                try std.testing.expect(s.value == .string);
                try std.testing.expectEqualStrings("poked over fed bytes", s.value.string);
                settle_count += 1;
            },
            else => return error.UnexpectedAction,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), settle_count);
    try std.testing.expectEqual(@as(usize, 1), client.vows.count());
    try std.testing.expectError(actors.Error.AlreadySettled, client.vowOn(vow, .{ .ctx = null, .func = CapturedString.record }));
    try client.vowRelease(vow);
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
    try std.testing.expectError(driver.core.HostError.NoSuchVow, client.vowOn(vow, .{ .ctx = null, .func = CapturedString.record }));

    // An unlistened break rides the queue too: the reply can never arrive
    // once the far vows break, and the completion carries the reason owned.
    const parked = try client.send(opened.pair.a, opened.widget, .{ .verb = "poke", .args = &.{} });
    try client.breakFarVows(opened.pair.a, "transport gone");
    var fail_count: usize = 0;
    while (try client.nextAction()) |action| {
        switch (action) {
            .flush => {},
            .failed => |f| {
                try std.testing.expectEqual(parked, f.vow_id);
                try std.testing.expectEqual(driver.core.VowFailure.broken, f.failure);
                try std.testing.expect(std.mem.indexOf(u8, f.message.bytes(), "transport gone") != null);
                fail_count += 1;
            },
            else => return error.UnexpectedAction,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), fail_count);
}

test "core host: an unlistened fetch completion owns a routable Host capability" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x6a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x6b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

    // No listener: the enrollment mapping still runs before the completion is
    // queued, so the drained value owns the canonical Host capability.
    const fetch_vow = try client.fetch(pair.a, "widget");
    _ = try shuttleAll(&.{pair});
    _ = try shuttleAll(&.{pair});
    var observed = false;
    while (try client.nextAction()) |action| {
        switch (action) {
            .flush => {},
            .settled => |s| {
                try std.testing.expectEqual(fetch_vow, s.vow_id);
                try std.testing.expect(s.value == .capability);
                const target = client.capabilities.resolve(s.value.capability).?;
                try std.testing.expect(target == .remote);
                try std.testing.expectEqual(pair.a.peer_handle, target.remote.peer_handle);
                observed = true;
            },
            else => return error.UnexpectedAction,
        }
    }
    try std.testing.expect(observed);
}

test "core host: transport loss retires session authority and refuses later work" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x7a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x7b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);

    const parked = try client.fetch(pair.a, "never-answered");
    try client.transportClosed(pair.a, "transport gone");
    try std.testing.expect(pair.a.isTerminating());
    try std.testing.expectError(driver.core.HostError.SessionCondemned, client.fetch(pair.a, "too-late"));

    var failed = false;
    while (try client.nextAction()) |action| switch (action) {
        .flush, .close => {},
        .failed => |failure| {
            try std.testing.expectEqual(parked, failure.vow_id);
            try std.testing.expectEqual(driver.core.VowFailure.closed, failure.failure);
            try std.testing.expect(std.mem.indexOf(u8, failure.message.bytes(), "transport gone") != null);
            failed = true;
        },
        else => return error.UnexpectedAction,
    };
    try std.testing.expect(failed);

    // Repeated physical-close reports are idempotent until explicit release.
    try client.transportClosed(pair.a, "transport gone again");
}

test "core host: direct session release classifies its pending vows as closed" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x7c)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x7d)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7002", &dials);

    const parked = try client.fetch(pair.a, "never-answered");
    try client.releaseSession(pair.a);

    var failed = false;
    while (try client.nextAction()) |action| switch (action) {
        .failed => |failure| {
            try std.testing.expectEqual(parked, failure.vow_id);
            try std.testing.expectEqual(driver.core.VowFailure.closed, failure.failure);
            failed = true;
        },
        .flush, .resume_work => {},
        else => return error.UnexpectedAction,
    };
    try std.testing.expect(failed);
}

test "core host: a burst of unlistened settles never strands — every completion lands on the reserved queue" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x7a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x7b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const opened = try openWidgetPair(allocator, &client, &server, &dials);

    // Queue the whole burst before a single reply frame moves, so every
    // settle fires inside one feed window against a queue already carrying
    // that feed's flush actions.
    const burst = 8;
    var vows: [burst]u64 = undefined;
    for (&vows) |*slot| {
        slot.* = try client.send(opened.pair.a, opened.widget, .{ .verb = "poke", .args = &.{} });
    }
    _ = try shuttleAll(&.{opened.pair});
    _ = try shuttleAll(&.{opened.pair});

    var seen: [burst]bool = @splat(false);
    while (try client.nextAction()) |action| {
        switch (action) {
            .flush => {},
            .settled => |s| {
                for (vows, 0..) |id, i| {
                    if (id == s.vow_id) {
                        try std.testing.expect(!seen[i]);
                        seen[i] = true;
                    }
                }
                try std.testing.expectEqualStrings("poked over fed bytes", s.value.string);
            },
            else => return error.UnexpectedAction,
        }
    }
    for (seen) |hit| try std.testing.expect(hit);
    try std.testing.expectEqual(@as(usize, burst), client.vows.count());
    for (vows) |vow| try client.vowRelease(vow);
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
}
