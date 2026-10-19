//! Callback-time Host reentry: cancel records intent and defers teardown
//! to unwind, and every top-level verb refuses while enqueueing verbs land
//! when the enclosing callback returns.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../../support/core_host.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const stream_framing = glowcap.foundation.stream_framing;

const harness = @import("../harness.zig");
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

/// True when `result` is exactly the reentry refusal, any success or other
/// error is a legality-classification bug.
fn refusedReentered(result: anytype) bool {
    if (result) |_| return false else |err| return err == driver.core.HostError.ReenteredHost;
}

/// A settle listener that probes the host from inside the callback window:
/// every top-level verb must refuse `ReenteredHost`, and every enqueueing
/// verb must succeed, its effects landing when the enclosing verb unwinds.
const ReentryProbe = struct {
    host: *Host,
    session: *HostSession,
    token: model.Reference,
    ran: bool = false,
    all_refused: bool = false,
    enqueued_ok: bool = false,
    nested_reply: CapturedString = .{},
    nested_listen: CapturedRef = .{},

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        _ = resolution;
        const self: *ReentryProbe = @ptrCast(@alignCast(ctx.?));
        self.ran = true;
        const host = self.host;
        const session = self.session;
        self.all_refused =
            refusedReentered(host.feed(session, .{ .bytes = "", .shape = .byte })) and
            refusedReentered(host.feedBytes(session, "x")) and
            refusedReentered(host.nextAction()) and
            refusedReentered(host.takeAction()) and
            refusedReentered(session.takeOutbound()) and
            refusedReentered(host.openDialedLocator(tcpLocator("127.0.0.1:7009"))) and
            refusedReentered(publishAndOpenAccepted(host, "tcp", "127.0.0.1:7009", &.{})) and
            refusedReentered(host.releaseSession(session)) and
            refusedReentered(host.exporterDialed(0, 0, session)) and
            refusedReentered(host.dialFailed(0, 0, "no")) and
            refusedReentered(host.provideGiftId(0, "")) and
            refusedReentered(host.breakFarVows(session, "no")) and
            refusedReentered(host.fetch(session, "widget")) and
            refusedReentered(host.enliven(session, tcpSturdyref("127.0.0.1:7001", "widget")));
        const vow = host.send(session, self.token, .{ .verb = "poke", .args = &.{} }) catch return;
        host.vowOn(vow, .{ .ctx = &self.nested_reply, .func = CapturedString.record }) catch return;
        host.tell(session, self.token, .{ .verb = "poke", .args = &.{} }) catch return;
        // A settle callback is where you learn a promise, so `listenTo` is
        // enqueueing, not top-level (ADR-0003).
        const listen_vow = host.listenTo(session, self.token) catch return;
        host.vowOn(listen_vow, .{ .ctx = &self.nested_listen, .func = CapturedRef.record }) catch return;
        host.setExporterLocation(session, null) catch return;
        self.enqueued_ok = true;
    }
};

/// A callback-time cancel probe: owner intent must become authoritative before
/// the callback continues, while terminal effects wait for its unwind.
const SessionCancelProbe = struct {
    host: *Host,
    session: *HostSession,
    token: model.Reference,
    ran: bool = false,
    intent_visible: bool = false,
    effects_deferred: bool = false,

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        _ = resolution;
        const self: *SessionCancelProbe = @ptrCast(@alignCast(ctx.?));
        self.ran = true;
        self.host.beginSessionClose(self.session, .cancel, 0) catch return;
        self.intent_visible = if (self.host.send(self.session, self.token, .{ .verb = "too-late", .args = &.{} })) |_| false else |err| err == driver.core.HostError.SessionCondemned;
        self.effects_deferred = self.session.lifecyclePhase() == .cancel_pending and
            !self.session.ingressCancelled() and self.session.lastAbort() == null;
    }
};

test "core host: callback-time session cancel records intent and defers teardown to unwind" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x1a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x1b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7061", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "widget"), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const widget_ref = try fetched.require();

    var probe = SessionCancelProbe{ .host = &client, .session = pair.a, .token = widget_ref };
    const vow = try client.send(pair.a, widget_ref, .{ .verb = "poke", .args = &.{} });
    try client.vowOn(vow, .{ .ctx = &probe, .func = SessionCancelProbe.fire });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    try std.testing.expect(probe.ran);
    try std.testing.expect(probe.intent_visible);
    try std.testing.expect(probe.effects_deferred);
    try std.testing.expect(pair.a.isTerminating());
    try std.testing.expect(pair.a.ingressCancelled());
    try client.releaseSession(pair.a);
}

test "core host: inside a callback every top-level verb refuses and every enqueueing verb lands at the unwind" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x2a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x2b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "widget"), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const widget_ref = try fetched.require();

    // The probe fires inside the feed that settles this vow.
    var probe = ReentryProbe{ .host = &client, .session = pair.a, .token = widget_ref };
    const vow = try client.send(pair.a, widget_ref, .{ .verb = "poke", .args = &.{} });
    try client.vowOn(vow, .{ .ctx = &probe, .func = ReentryProbe.fire });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    try std.testing.expect(probe.ran);
    try std.testing.expect(probe.all_refused);
    try std.testing.expect(probe.enqueued_ok);
    // The nested send encoded at the unwind and settled through the pump.
    try std.testing.expectEqualStrings("poked over fed bytes", probe.nested_reply.buf[0..probe.nested_reply.len]);
    // So did the nested listen: the partner answered its `op:listen`.
    _ = try probe.nested_listen.require();
}
