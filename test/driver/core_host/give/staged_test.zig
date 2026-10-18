//! Staged inline gifts retain their nested capability until the accepted send
//! settles, and gift-id failure breaks only that operation.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../../support/core_host.zig");

const driver = glowcap.driver;
const model = glowcap.ocapn.model;
const Host = driver.core.Host;
const harness = @import("../harness.zig");
const frame_cap = harness.frame_cap;
const Widget = harness.Widget;
const ParkedDial = harness.ParkedDial;
const CapturedRef = harness.CapturedRef;
const openPair = harness.openPair;
const pumpToQuiescence = harness.pumpToQuiescence;
const NestedCallCapture = @import("capture.zig").NestedCallCapture;

test "core host: a staged inline gift owns its capability and failure settles its vow" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| try stagedGiftOutcome(profile, .observed, false);
}

test "core host: a staged inline gift permits release before preparation completes" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        for ([_]bool{ false, true }) |success| try stagedGiftOutcome(profile, .released, success);
    }
}

test "core host: a staged inline gift keeps release custody after call cancellation" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        for ([_]bool{ false, true }) |success| try stagedGiftOutcome(profile, .cancelled, success);
    }
}

const Owner = enum { observed, released, cancelled };

fn stagedGiftOutcome(profile: model.CaptpVersion, owner: Owner, success: bool) !void {
    const allocator = std.testing.allocator;
    var options = Host.Options.withFrameCap(frame_cap);
    options.captp_version = profile;
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
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget_wire, .func = CapturedRef.record });

    const g_to_r = try openPair(allocator, &gifter, &recipient, "127.0.0.1:7062", &dials);
    _ = try g_to_r.b.served.publish(&g_to_r.b.host.vat, "sink", Widget, .{});
    var sink_wire = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_r.a, "sink"), .{ .ctx = &sink_wire, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, g_to_r }, &dials);

    const widget = try gifter.liftCapability(g_to_e.a, try widget_wire.require());
    const sink = try gifter.liftCapability(g_to_r.a, try sink_wire.require());
    const recipient_answers = g_to_r.a.served.port.peer.session_state.outbound_answers.len();
    defer gifter.releaseCapability(sink, 1) catch {};
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const nested = [_]driver.core.Value{.{ .tagged = .{
        .tag = "delegated",
        .value = &.{.{ .list = &.{.{ .capability = widget }} }},
    } }};
    var call: ?*Host.Call = null;
    defer if (call) |held| held.deinit();
    const staged_vow = if (owner == .cancelled) blk: {
        const id = gifter.vow_ids.next;
        call = try gifter.callCapability(allocator, g_to_r.a, sink, "poke", &nested, 1024);
        break :blk id;
    } else try gifter.queueSendValues(g_to_r.a, sink, "poke", &nested, arena.allocator());
    var staged_reply = NestedCallCapture{};
    if (owner == .observed) try gifter.vowOn(staged_vow, .{ .ctx = &staged_reply, .func = NestedCallCapture.record });

    // Gift preparation owns the answer before a Session row exists. Removing
    // an observer must leave that notification available to its next owner.
    const port = &g_to_r.a.served.port;
    try std.testing.expect(@sizeOf(@TypeOf(port.peer.pending_send.peek().?.item.staged)) <= 32);
    const wire_vow = gifter.vows.get(staged_vow).?.vow;
    try std.testing.expect(port.peer.session_state.outbound_answers.getPtr(wire_vow.far.position) == null);
    try std.testing.expect(port.peer.canObserveAnswer(wire_vow.far));
    const listener = port.takeListener(&gifter.vat, wire_vow).?;
    try std.testing.expect(port.takeListener(&gifter.vat, wire_vow) == null);
    try port.on(&gifter.vat, wire_vow, listener);
    try std.testing.expectError(error.AlreadyListening, port.on(&gifter.vat, wire_vow, listener));

    // The accepted send owns the delayed occurrence after the caller releases
    // its last direct capability handle.
    try gifter.releaseCapability(widget, 1);
    try std.testing.expect(gifter.capabilitySession(widget) == g_to_e.a);

    var gift_ticket: ?u64 = null;
    while (try harness.popAction(&gifter)) |action| switch (action) {
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

    if (owner != .observed) {
        if (call) |held| {
            held.deinit();
            call = null;
        } else {
            const budget = port.peer.outbound_budget;
            port.peer.outbound_budget = 0;
            try std.testing.expectError(error.OutboundBackpressure, gifter.vowRelease(staged_vow));
            port.peer.outbound_budget = budget;
            try std.testing.expect(gifter.vows.contains(staged_vow));
            try std.testing.expect(port.peer.canObserveAnswer(wire_vow.far));
            try gifter.vowRelease(staged_vow);
        }
        try std.testing.expectEqual(@as(usize, 0), gifter.vows.count());
        try std.testing.expect(!port.peer.canObserveAnswer(wire_vow.far));
    }
    if (success) {
        const gift_id = @as([32]u8, @splat(0x5a));
        try gifter.provideGiftId(gift_ticket.?, &gift_id);
    } else {
        try gifter.giftIdFailed(gift_ticket.?);
    }
    try std.testing.expectEqual(owner == .observed, staged_reply.broken);
    try std.testing.expect(!port.peer.canObserveAnswer(wire_vow.far));
    try std.testing.expectError(error.AlreadySettled, port.on(&gifter.vat, wire_vow, .{
        .ctx = &staged_reply,
        .func = NestedCallCapture.record,
    }));
    if (owner == .observed) try std.testing.expect(std.mem.indexOf(u8, staged_reply.reason(), "GiftIdUnavailable") != null);
    try std.testing.expect(!g_to_r.a.isTerminating());
    try std.testing.expect(g_to_r.a.sessionOpen());
    var deliveries: usize = 0;
    var releases: usize = 0;
    while (try harness.popAction(&gifter)) |action| switch (action) {
        .flush => |peer_handle| {
            const session = if (peer_handle == g_to_e.a.peer_handle)
                g_to_e.a
            else if (peer_handle == g_to_r.a.peer_handle)
                g_to_r.a
            else
                continue;
            while (try session.takeOutbound()) |frame_value| {
                var frame = frame_value;
                defer frame.deinit();
                if (session == g_to_r.a) {
                    const state = &port.peer.session_state;
                    const body = try glowcap.ocapn.codec.dispatch.decodeBodyForProfile(
                        state.codec,
                        state.captp_version,
                        frame.view(),
                    );
                    switch (body) {
                        .deliver => deliveries += 1,
                        .gc_answer => releases += 1,
                        else => {},
                    }
                }
            }
        },
        else => return error.UnexpectedAction,
    };
    try std.testing.expectEqual(@as(usize, @intFromBool(success)), deliveries);
    try std.testing.expectEqual(@as(usize, @intFromBool(success)), releases);
    try std.testing.expect(gifter.capabilitySession(widget) == null);
    try std.testing.expectEqual(@as(usize, 0), gifter.vows.count());
    try std.testing.expectEqual(@as(usize, 0), port.peer.pending_send_bytes);
    try std.testing.expectEqual(@as(usize, 0), port.peer.pending_send_reservations);
    try std.testing.expectEqual(
        recipient_answers,
        g_to_r.a.served.port.peer.session_state.outbound_answers.len(),
    );
}
