//! Withdraw and missing-gifter redeem through the action queue.
//!
//! Closing the gifter session destroys deposited gifts, a failure
//! listener can keep a redeem-opened exporter, an early withdraw
//! waits for a distinct deposit or breaks on gifter close, and a
//! live exporter session is reused instead of dialing a duplicate.

const std = @import("std");
const pancake = @import("pancake");
const test_host = @import("../../../support/core_host.zig");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const engine = pancake.ocapn.engine;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;

const harness = @import("../harness.zig");
const frame_cap = harness.frame_cap;
const Widget = harness.Widget;
const Introducer = harness.Introducer;
const Pair = harness.Pair;
const shuttle = harness.shuttle;
const publishAndOpenAccepted = harness.publishAndOpenAccepted;
const ParkedDial = harness.ParkedDial;
const pumpToQuiescence = harness.pumpToQuiescence;
const CapturedRef = harness.CapturedRef;
const CapturedString = harness.CapturedString;
const openPair = harness.openPair;

/// One generation of a host-wide giftable. The reply is the tag its row carries,
/// so a call says *which* registration answered rather than only that one did.
const FailedRedeemListener = struct {
    host: *Host,
    session: ?*HostSession = null,
    adopt_exporter: bool,
    adopted: bool = false,
    captured: CapturedRef = .{},

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *FailedRedeemListener = @ptrCast(@alignCast(ctx.?));
        CapturedRef.record(&self.captured, resolution);
        if (!self.adopt_exporter or resolution != .broken) return;
        const session = self.session orelse return;
        // `tell` is intentionally callback-safe. It claims application
        // ownership synchronously, while its encode work waits for the host
        // pump's outer unwind.
        self.host.tell(
            session,
            .{ .far = model.FarRef.object(0) },
            .{ .verb = "keep-open", .args = &.{} },
        ) catch return;
        self.adopted = true;
    }
};

fn runMissingGifterRedeem(adopt_in_failure_listener: bool) !void {
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, @as([32]u8, @splat(0x0e)), Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, @as([32]u8, @splat(0x06)), Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, @as([32]u8, @splat(0x0c)), Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7011", &dials);
    _ = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "widget", Widget, .{});
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &gifter, &exporter }, &.{g_to_e}, &dials);

    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7012", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = try widget.require() });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &gifter, &recipient }, &.{r_to_g}, &dials);

    const introduction = try recipient.send(r_to_g.a, try introducer.require(), .{ .verb = "introduce", .args = &.{} });
    var listener = FailedRedeemListener{
        .host = &recipient,
        .adopt_exporter = adopt_in_failure_listener,
    };
    try recipient.vowOn(introduction, .{ .ctx = &listener, .func = FailedRedeemListener.fire });

    // Deliver only the call to the gifter. Its reply cannot leave until the
    // embedder answers the gift-id request, at which point the two handoff legs
    // are independently queued on r_to_g and g_to_e.
    try std.testing.expect(try shuttle(r_to_g));
    const gift_id = @as([32]u8, @splat(0x5a));
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

    // Deliver the deposit, but hold back the signed give. The gift belongs to
    // the Exporter-side Peer for this Gifter–Exporter session.
    try std.testing.expect(try shuttle(g_to_e));
    try std.testing.expect(g_to_e.b.served.port.peer.giftRegistry().giftLive(&gift_id));

    const exporter_peer = g_to_e.b.served.port.peer;
    const gifter_key = exporter_peer.session_state.partnerSessionKey().?;
    const exporter_key = exporter_peer.session_state.localSessionKey().?;
    const gifter_side_name = try engine.handoff_names.sideName(gifter_key);
    const exporter_side_name = try engine.handoff_names.sideName(exporter_key);
    const session_name = engine.handoff_names.sessionName(gifter_side_name, exporter_side_name);

    // Closing the required session destroys its Peer-owned registry. The Host
    // directory can no longer resolve either the key or the gift table.
    try exporter.releaseSession(g_to_e.b);
    try gifter.releaseSession(g_to_e.a);
    const resolver = exporter.node.gifterSessionResolver().?;
    try std.testing.expect(resolver.resolve(resolver.ctx, gifter_side_name, &session_name) == null);

    // Now release the held give. The recipient can still connect to the
    // exporter, but redemption fails closed because OCapN requires the original
    // Gifter–Exporter session to remain open.
    try pumpToQuiescence(allocator, &.{ &gifter, &recipient }, &.{r_to_g}, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];
    const accepted = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7011", &.{});
    const pending = recipient.pendingDial(parked.ticket, 0) orelse return error.MissingPendingDial;
    const dialed = try recipient.openDialedLocator(.{
        .transport = pending.locator.transport,
        .designator = pending.locator.designator,
        .hints = model.Hints.emptyFalse(),
    });
    listener.session = dialed;
    const r_to_e = Pair{ .ah = &recipient, .a = dialed, .bh = &exporter, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &exporter, &gifter, &recipient }, &.{ r_to_g, r_to_e }, &dials);
    _ = try recipient.exporterDialed(parked.ticket, 0, dialed);
    try pumpToQuiescence(allocator, &.{ &exporter, &gifter, &recipient }, &.{ r_to_g, r_to_e }, &dials);

    try std.testing.expect(listener.captured.broken);
    try std.testing.expectEqualStrings(
        "handoff redeem failed: gifter session is not open",
        listener.captured.reason_buf[0..listener.captured.reason_len],
    );
    if (adopt_in_failure_listener) {
        try std.testing.expect(listener.adopted);
        try std.testing.expect(!dialed.isTerminating());
    } else {
        // The recipient opened r_to_e solely for this redemption. With no
        // capability produced, the Host retires it instead of leaving an
        // application-invisible session cached indefinitely.
        try std.testing.expect(dialed.isTerminating());
    }
}

test "core host: closing the gifter session destroys its deposited gifts and breaks later withdraw" {
    try runMissingGifterRedeem(false);
}

test "core host: failure-listener activity preserves a redeem-opened exporter" {
    try runMissingGifterRedeem(true);
}

const EarlyWithdrawOutcome = enum { deposit, close };

fn runEarlyWithdrawComposition(outcome: EarlyWithdrawOutcome) !void {
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, @as([32]u8, @splat(0x0e)), Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, @as([32]u8, @splat(0x06)), Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, @as([32]u8, @splat(0x0c)), Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7021", &dials);
    _ = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "widget", Widget, .{});
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &gifter, &exporter }, &.{g_to_e}, &dials);

    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7022", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = try widget.require() });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &gifter, &recipient }, &.{r_to_g}, &dials);

    const introduction = try recipient.send(r_to_g.a, try introducer.require(), .{ .verb = "introduce", .args = &.{} });
    var redeemed = CapturedRef{};
    try recipient.vowOn(introduction, .{ .ctx = &redeemed, .func = CapturedRef.record });

    // Let the gifter originate both legs, then deliver only the signed give.
    // The deposit remains queued on g_to_e while the recipient opens its own
    // exporter session and sends the withdrawal first.
    try std.testing.expect(try shuttle(r_to_g));
    const gift_id = @as([32]u8, @splat(0x6b));
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
    try pumpToQuiescence(allocator, &.{ &gifter, &recipient }, &.{r_to_g}, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);

    const parked = dials.items[0];
    const accepted = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7021", &.{});
    const pending = recipient.pendingDial(parked.ticket, 0) orelse return error.MissingPendingDial;
    const dialed = try recipient.openDialedLocator(.{
        .transport = pending.locator.transport,
        .designator = pending.locator.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const r_to_e = Pair{ .ah = &recipient, .a = dialed, .bh = &exporter, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &exporter, &recipient }, &.{r_to_e}, &dials);
    _ = try recipient.exporterDialed(parked.ticket, 0, dialed);
    try pumpToQuiescence(allocator, &.{ &exporter, &recipient }, &.{r_to_e}, &dials);

    try std.testing.expectEqual(@as(usize, 1), exporter.node.handoffWaiterCount(g_to_e.b.peer_handle));
    try std.testing.expect(!g_to_e.b.served.port.peer.giftRegistry().giftLive(&gift_id));
    try std.testing.expect(!redeemed.broken);

    switch (outcome) {
        .deposit => {
            // Deliver the already-queued deposit on the distinct gifter Port.
            // Its inbound commit marks the exact Node dependency; the same
            // Host pump wakes the receiver Port, settles the parked withdraw,
            // and exposes the flush that carries the resolution.
            try pumpToQuiescence(
                allocator,
                &.{ &exporter, &gifter, &recipient },
                &.{ g_to_e, r_to_g, r_to_e },
                &dials,
            );
            try std.testing.expect((try redeemed.require()) == .routed);
            try std.testing.expectEqual(@as(usize, 0), exporter.node.handoffWaiterCount(g_to_e.b.peer_handle));
            try std.testing.expect(!g_to_e.b.served.port.peer.giftRegistry().giftLive(&gift_id));
        },
        .close => {
            // No deposit or unrelated frame follows. Removing the required
            // live Gifter–Exporter session is itself handoff progress:
            // releaseSession's pump re-drives the parked Receiver–Exporter
            // Peer, which re-resolves and breaks.
            try exporter.releaseSession(g_to_e.b);
            try gifter.releaseSession(g_to_e.a);
            try pumpToQuiescence(allocator, &.{ &exporter, &gifter, &recipient }, &.{ r_to_g, r_to_e }, &dials);

            try std.testing.expect(redeemed.broken);
            try std.testing.expectEqualStrings("handoff redeem failed: gifter session is not open", redeemed.reason_buf[0..redeemed.reason_len]);
        },
    }
}

test "core host: a distinct gifter deposit wakes and settles an early withdraw" {
    try runEarlyWithdrawComposition(.deposit);
}

test "core host: closing the gifter session wakes and breaks an early withdraw" {
    try runEarlyWithdrawComposition(.close);
}

test "core host: a redeem reuses a live exporter session instead of dialing a duplicate" {
    // Regression (ADR-0012): when the recipient already holds a live open
    // session to the exporter, redeeming a give that names that exporter must
    // REUSE the session, not surface a dial the Host's session-pair uniqueness
    // rule would then refuse and break the redeem on. The node's URI-keyed
    // exporter cache misses the pre-existing session; the Host's dial index is
    // the authority, consulted at the node-action seam before any dial is
    // surfaced.
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

    // Gifter dials the exporter and fetches the widget (the give's future home).
    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7001", &dials);
    _ = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "widget", Widget, .{});
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const widget_ref = try widget.require();

    // Recipient dials the gifter and fetches the introducer.
    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7002", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = widget_ref });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    const introducer_ref = try introducer.require();

    // The trigger: the recipient already holds a live open session to the
    // exporter at the very designator the give will name. This lower-level
    // fixture projects the same actor on that Port before withdrawal.
    const r_to_e = try openPair(allocator, &recipient, &exporter, "127.0.0.1:7001", &dials);
    _ = try r_to_e.b.served.publish(&r_to_e.b.host.vat, "widget", Widget, .{});
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);

    const all_pairs = [_]Pair{ g_to_e, r_to_g, r_to_e };

    // Introduce: the give is minted and claimed, and because a live session to
    // the exporter already exists it redeems in place — no dial is surfaced.
    const introduce_vow = try recipient.send(r_to_g.a, introducer_ref, .{ .verb = "introduce", .args = &.{} });
    var redeemed = CapturedRef{};
    try recipient.vowOn(introduce_vow, .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);

    // With the bug the redeem parks a dial that refuses `SessionPairExists` and
    // the vow never settles; the fix reuses the session, so zero dials surface.
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);
    const token_ref = try redeemed.require();
    try std.testing.expect(token_ref == .routed);

    // Crossing the new Host boundary consumes the redeemed Node route: one
    // stale-capable route becomes one import-incarnation-checked Host handle.
    const route_id = token_ref.routed.id;
    const host_ref = try recipient.liftCapability(r_to_g.a, token_ref);
    try std.testing.expect(recipient.node.routeCapability(route_id) == null);
    const lowered = try recipient.lowerCapability(r_to_e.a, host_ref);

    // The Host handle lowers through the reused exporter session to the widget.
    const poke_vow = try recipient.send(r_to_e.a, lowered, .{ .verb = "poke", .args = &.{} });
    var poked = CapturedString{};
    try recipient.vowOn(poke_vow, .{ .ctx = &poked, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("poked over fed bytes", poked.buf[0..poked.len]);
}
