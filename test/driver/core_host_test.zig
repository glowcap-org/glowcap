//! `driver_core.Host` end to end with no socket anywhere: hosts are wired
//! by moving frames between `takeOutbound` and `feed` by hand, and every host
//! effect (a dial, gift-id entropy) is answered through the action queue,
//! the byte-fed contract the C driver archive and the bindings ride
//! (ADR-0072). The capstone is the full three-party handoff: a gifter's
//! ordinary reply becomes a signed give through the host-internal
//! origination, the recipient's host surfaces one `dial` action, and the
//! settled vow carries a routable token that reaches the exporter's object.

const std = @import("std");
const pancake = @import("pancake");
const promise_capture = @import("../support/capture.zig");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = pancake.ocapn.engine;

const frame_cap = 4096;

test "Host admission frame cap defaults to the canonical session limit" {
    // Single-source lock: a default-constructed Host admits the same frame size
    // the driver C ABI publishes as PANCAKE_DEFAULT_FRAME_CAP, so a native Zig
    // embedder and a C embedder agree on the default admission cap. If someone
    // re-hardcodes this default to a bare literal, this fails instead of
    // silently shrinking a Zig host's admissible frame below the advertised C
    // default.
    try std.testing.expectEqual(
        (engine.SessionLimits{}).max_frame_bytes,
        (Host.Options{}).frameCap(),
    );
}

/// The gifted object, published by the exporter.
const Widget = struct {
    pub fn handle(self: *Widget, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "poke")) return error.NoSuchMethod;
        return .{ .string = "poked over fed bytes" };
    }
};

/// The gifter's introducer: replies with the foreign capability it fetched.
/// The host's own origination interceptor turns that reply into a give.
const Introducer = struct {
    widget: model.Reference,
    pub fn handle(self: *Introducer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "introduce")) return error.NoSuchMethod;
        return .{ .reference = self.widget };
    }
};

/// A wired pair: one host's connection whose outbound is the other's inbound.
const host_pair = @import("../support/host_pair.zig");
const Pair = host_pair.Pair;
const shuttleAll = host_pair.shuttleAll;
const tcpLocator = host_pair.tcpLocator;

/// One dial request parked for the test to execute, designator duped clear of
/// the action queue's popped-view lifetime.
const ParkedDial = struct { host: *Host, ticket: pancake.ocapn.engine.Node.PendingId, designator: []u8 };

/// Drain every host's action queue: gift-id requests are answered inline with
/// deterministic bytes (entropy is the embedder's job), flush notices are
/// no-ops here (the shuttle polls every queue anyway), and dial requests park
/// on `dials` for the test to execute explicitly.
fn drainActions(allocator: std.mem.Allocator, hosts: []const *Host, dials: *std.ArrayList(ParkedDial)) !bool {
    var did_work = false;
    for (hosts) |host| {
        while (try host.nextAction()) |action| {
            switch (action) {
                .flush => {},
                .need_gift_id => |n| {
                    const gift_id = [_]u8{0x5a} ** 32;
                    try host.provideGiftId(n.ticket, &gift_id);
                    did_work = true;
                },
                .dial => |d| {
                    // Ticket-only action: pending row owns the dial view (no re-parse).
                    // Every dial in this file targets a tcp locator with a
                    // socket-address designator.
                    const view = host.pendingDial(d.ticket) orelse return error.MissingPendingDial;
                    try std.testing.expectEqualStrings("tcp", view.transport);
                    try std.testing.expect(view.designator.len != 0);
                    try dials.append(allocator, .{
                        .host = host,
                        .ticket = d.ticket,
                        .designator = try allocator.dupe(u8, view.designator),
                    });
                    did_work = true;
                },
                // An unlistened vow's completion; the tests in this file that
                // route completions drain `nextAction` by hand instead.
                .settled, .failed => {},
                // Only a budgeted host condemns and closes; no test in this
                // file sets a `local_turn_budget`.
                .close => {},
            }
        }
    }
    return did_work;
}

/// Pump shuttles and action drains until the whole network is quiescent.
fn pumpToQuiescence(
    allocator: std.mem.Allocator,
    hosts: []const *Host,
    pairs: []const Pair,
    dials: *std.ArrayList(ParkedDial),
) !void {
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        const moved = try shuttleAll(pairs);
        const acted = try drainActions(allocator, hosts, dials);
        if (!moved and !acted) return;
    }
    return error.PumpDidNotQuiesce;
}

const CapturedRef = promise_capture.CapturedRef;
const CapturedString = promise_capture.CapturedString;

/// Open a dialed/accepted pair between two hosts and drive the keyed
/// handshake open over fed bytes.
fn openPair(
    allocator: std.mem.Allocator,
    dialer: *Host,
    acceptor: *Host,
    designator: []const u8,
    dials: *std.ArrayList(ParkedDial),
) !Pair {
    const accepted = try acceptor.openAccepted("tcp", designator, &.{});
    const dialed = try dialer.openDialedLocator(tcpLocator(designator));
    const pair = Pair{ .ah = dialer, .a = dialed, .bh = acceptor, .b = accepted };
    try pumpToQuiescence(allocator, &.{ dialer, acceptor }, &.{pair}, dials);
    try std.testing.expect(dialed.sessionOpen());
    try std.testing.expect(accepted.sessionOpen());
    return pair;
}

test "core host: two hosts complete the keyed handshake over fed bytes" {
    const allocator = std.testing.allocator;
    var a = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer a.deinit();
    var b = Host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer b.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    _ = try openPair(allocator, &a, &b, "127.0.0.1:7001", &dials);
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);
}

test "core host: feedBytes fails closed on incomplete-at-cap" {
    const allocator = std.testing.allocator;
    var host = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(8));
    defer host.deinit();
    const conn = try host.openAccepted("tcp", "127.0.0.1:7010", &.{});
    const junk = [_]u8{ '<', '1', '0', '\'', 'o', 'p', ':', 'd' };
    try std.testing.expectError(error.FrameTooLarge, host.feedBytes(conn, &junk));
}

test "core host: publish, fetch, and a settled send over fed bytes" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);
    _ = try pair.b.served.publish("widget", Widget, .{});

    // Fetch arrives already enrolled as a node-unique token; the in-process
    // listener chains onto the fetch's own vow.
    var fetched = CapturedRef{};
    const fetch_vow = try client.fetch(pair.a, "widget");
    try client.vowOn(fetch_vow, .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const widget_ref = try fetched.require();

    // A send through the token settles with the exporter's reply.
    const vow = try client.send(pair.a, widget_ref, .{ .verb = "poke", .args = &.{} });
    var reply = CapturedString{};
    try client.vowOn(vow, .{ .ctx = &reply, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectEqualStrings("poked over fed bytes", reply.buf[0..reply.len]);
}

test "core host: the full three-party handoff runs over fed bytes and one dial action" {
    const allocator = std.testing.allocator;
    var exporter = Host.init(allocator, [_]u8{0x0e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = Host.init(allocator, [_]u8{0x06} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = Host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    // Gifter dials the exporter and fetches the widget: the node records the
    // capability's foreign home, which is what the give will name.
    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7001", &dials);
    _ = try g_to_e.b.served.publish("widget", Widget, .{});
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const widget_ref = try widget.require();

    // Recipient dials the gifter and fetches the introducer.
    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7002", &dials);
    _ = try r_to_g.b.served.publish("introducer", Introducer, .{ .widget = widget_ref });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    const introducer_ref = try introducer.require();

    // The introduction: the gifter's reply fulfills with a foreign-homed
    // capability, the gifter host originates the give (gift-id entropy
    // answered through its action queue), and the recipient host claims the
    // give and surfaces exactly one dial action naming the exporter.
    const introduce_vow = try recipient.send(r_to_g.a, introducer_ref, .{ .verb = "introduce", .args = &.{} });
    var redeemed = CapturedRef{};
    try recipient.vowOn(introduce_vow, .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);

    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];
    try std.testing.expect(parked.host == &recipient);
    try std.testing.expect(std.mem.indexOf(u8, parked.designator, "127.0.0.1") != null);

    // The test is the dial executor: open the recipient's own connection to
    // the exporter, drive it open, and report it back. The withdraw, its
    // settle, and the vow's fulfillment all pump inside the report. The
    // exporter publishes the widget on this session too: a swissnum-named
    // gift resolves against the *withdraw* session's bootstrap registry (the
    // per-connection publish the C tier's host-level giftable verb automates).
    const e_accepts_r = try exporter.openAccepted("tcp", "127.0.0.1:7001", &.{});
    _ = try e_accepts_r.served.publish("widget", Widget, .{});
    // Production Bridge dials from pendingDial parts — no URI re-parse.
    const redeem_view = recipient.pendingDial(parked.ticket) orelse return error.MissingPendingDial;
    const r_to_e = try recipient.openDialedLocator(.{
        .transport = redeem_view.transport,
        .designator = redeem_view.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const redeem_pair = Pair{ .ah = &recipient, .a = r_to_e, .bh = &exporter, .b = e_accepts_r };
    const all_pairs = [_]Pair{ g_to_e, r_to_g, redeem_pair };
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expect(r_to_e.sessionOpen());
    try recipient.exporterDialed(parked.ticket, r_to_e);
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);

    const token_ref = try redeemed.require();
    try std.testing.expect(token_ref == .far);

    // The token routes: a send through it reaches the exporter's widget
    // directly, over the recipient's own connection.
    const poke_vow = try recipient.send(r_to_g.a, token_ref, .{ .verb = "poke", .args = &.{} });
    var poked = CapturedString{};
    try recipient.vowOn(poke_vow, .{ .ctx = &poked, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("poked over fed bytes", poked.buf[0..poked.len]);
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
    var exporter = Host.init(allocator, [_]u8{0x0e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = Host.init(allocator, [_]u8{0x06} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = Host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    // Gifter dials the exporter and fetches the widget (the give's future home).
    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7001", &dials);
    _ = try g_to_e.b.served.publish("widget", Widget, .{});
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const widget_ref = try widget.require();

    // Recipient dials the gifter and fetches the introducer.
    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7002", &dials);
    _ = try r_to_g.b.served.publish("introducer", Introducer, .{ .widget = widget_ref });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    const introducer_ref = try introducer.require();

    // The trigger: the recipient already holds a live open session to the
    // exporter at the very designator the give will name. The exporter
    // publishes the widget on that session so the withdraw resolves against it.
    const r_to_e = try openPair(allocator, &recipient, &exporter, "127.0.0.1:7001", &dials);
    _ = try r_to_e.b.served.publish("widget", Widget, .{});
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
    try std.testing.expect(token_ref == .far);

    // The token routes through the reused session to the exporter's widget.
    const poke_vow = try recipient.send(r_to_g.a, token_ref, .{ .verb = "poke", .args = &.{} });
    var poked = CapturedString{};
    try recipient.vowOn(poke_vow, .{ .ctx = &poked, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("poked over fed bytes", poked.buf[0..poked.len]);
}

/// True when `result` is exactly the reentry refusal — any success or other
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

    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        _ = resolution;
        const self: *ReentryProbe = @ptrCast(@alignCast(ctx.?));
        self.ran = true;
        const host = self.host;
        const conn = self.session;
        self.all_refused =
            refusedReentered(host.feed(conn, .{ .bytes = "", .shape = .byte })) and
            refusedReentered(host.feedBytes(conn, "x")) and
            refusedReentered(host.nextAction()) and
            refusedReentered(host.takeAction()) and
            refusedReentered(conn.takeOutbound()) and
            refusedReentered(host.openDialedLocator(tcpLocator("127.0.0.1:7009"))) and
            refusedReentered(host.openAccepted("tcp", "127.0.0.1:7009", &.{})) and
            refusedReentered(host.releaseSession(conn)) and
            refusedReentered(host.exporterDialed(0, conn)) and
            refusedReentered(host.dialFailed(0, "no")) and
            refusedReentered(host.provideGiftId(0, "")) and
            refusedReentered(host.breakFarVows(conn, "no")) and
            refusedReentered(host.fetch(conn, "widget")) and
            refusedReentered(host.enliven(conn, "widget"));
        const vow = host.send(conn, self.token, .{ .verb = "poke", .args = &.{} }) catch return;
        host.vowOn(vow, .{ .ctx = &self.nested_reply, .func = CapturedString.record }) catch return;
        host.tell(conn, self.token, .{ .verb = "poke", .args = &.{} }) catch return;
        host.setExporterLocation(conn, null) catch return;
        self.enqueued_ok = true;
    }
};

test "core host: inside a callback every top-level verb refuses and every enqueueing verb lands at the unwind" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x2a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x2b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);
    _ = try pair.b.served.publish("widget", Widget, .{});

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
}

test "core host: a crossed-hellos loser refuses every verb condemned; release still works" {
    const allocator = std.testing.allocator;
    var a = Host.init(allocator, [_]u8{0x3a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer a.deinit();
    var b = Host.init(allocator, [_]u8{0x3b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer b.deinit();

    // Both sides dial the same partner designator: a's outbound dial is
    // registered when b's hello (signing that same designator as its own
    // dialable address) arrives on a's accepted connection, so the tiebreak
    // condemns exactly one of a's two connections.
    const designator = "127.0.0.1:7001";
    try b.setSelfDesignator(designator);
    const a_dialed = try a.openDialedLocator(tcpLocator(designator));
    const a_accepted = try a.openAccepted("tcp", "127.0.0.1:7002", &.{});
    const b_dialed = try b.openDialedLocator(tcpLocator("127.0.0.1:7002"));

    var hello = (try b_dialed.takeOutbound()) orelse return error.MissingHello;
    defer hello.deinit();
    try a.feed(a_accepted, hello.view());
    const condemned = if (a_accepted.condemned) a_accepted else a_dialed;
    try std.testing.expect(condemned.condemned);

    // Every verb that rides the condemned connection refuses, uniformly.
    const target = model.Reference{ .far = model.FarRef.object(1) };
    const condemned_err = driver.core.HostError.ConnectionCondemned;
    try std.testing.expectError(condemned_err, a.feed(condemned, .{ .bytes = "", .shape = .byte }));
    try std.testing.expectError(condemned_err, a.feedBytes(condemned, "x"));
    try std.testing.expectError(condemned_err, a.send(condemned, target, .{ .verb = "poke", .args = &.{} }));
    try std.testing.expectError(condemned_err, a.tell(condemned, target, .{ .verb = "poke", .args = &.{} }));
    try std.testing.expectError(condemned_err, a.fetch(condemned, "widget"));
    try std.testing.expectError(condemned_err, a.enliven(condemned, "widget"));
    try std.testing.expectError(condemned_err, a.exporterDialed(0, condemned));
    try std.testing.expectError(condemned_err, a.breakFarVows(condemned, "gone"));
    try std.testing.expectError(condemned_err, a.setExporterLocation(condemned, null));

    // The queued typed abort still drains — the embedder writes it before
    // closing — and the release path stays ungated.
    var abort_frame = (try condemned.takeOutbound()) orelse return error.MissingAbort;
    abort_frame.deinit();
    try a.releaseSession(condemned);
}

test "core host: a second dial to the same partner refuses SessionPairExists" {
    const allocator = std.testing.allocator;
    var host = Host.init(allocator, [_]u8{0x3c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const designator = "127.0.0.1:7011";
    const first = try host.openDialedLocator(tcpLocator(designator));
    try std.testing.expectError(driver.core.HostError.SessionPairExists, host.openDialedLocator(tcpLocator(designator)));

    // Crossed hellos may still open an accepted session beside the dial.
    _ = try host.openAccepted("tcp", "127.0.0.1:7012", &.{});

    // After release, a fresh dial to the same partner is admitted again.
    try host.releaseSession(first);
    const again = try host.openDialedLocator(tcpLocator(designator));
    try host.releaseSession(again);
}

test "core host: accepted tcp session's declared designator does not squat dial availability" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x3d} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x3e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    try client.setSelfDesignator("127.0.0.1:7013");
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7014", &dials);
    // Server learned the client's self-declared tcp designator; that claim is
    // not verified ownership of the address, so a dial to it is admitted.
    // Post-handshake partner-key refuse settles the duplicate when the new
    // session's start-session arrives (ADR-0012).
    const back = try server.openDialedLocator(tcpLocator("127.0.0.1:7013"));
    try std.testing.expect(!back.condemned);
    try client.releaseSession(pair.a);
    try server.releaseSession(pair.b);
    try server.releaseSession(back);
}

test "core host: keyed dial to a verified partner session key refuses SessionPairExists" {
    const allocator = std.testing.allocator;
    const crypto = pancake.foundation.crypto;

    const partner_seed = [_]u8{0x51} ** 32;
    const partner_key = crypto.SecretKey.fromSeed(partner_seed).publicKey();
    const designator = partner_key.toDesignator();
    var uri_buf: [96]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buf, "ocapn://{s}.iroh", .{designator[0..]});

    var dialer = Host.init(allocator, [_]u8{0x52} ** 32, Host.Options.withFrameCap(frame_cap));
    defer dialer.deinit();
    var acceptor = Host.init(allocator, partner_seed, Host.Options.withFrameCap(frame_cap));
    defer acceptor.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const accepted = try acceptor.openAccepted("iroh", designator[0..], &.{});
    const loc = try model.uri.parsePeer(allocator, uri);
    defer model.freePeerLocator(allocator, loc);
    const first = try dialer.openDialedLocator(loc);
    const pair = Pair{ .ah = &dialer, .a = first, .bh = &acceptor, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &dialer, &acceptor }, &.{pair}, &dials);
    try std.testing.expect(first.sessionOpen());

    // Same key designator while the verified session is live: dial-time refuse.
    const loc_again = try model.uri.parsePeer(allocator, uri);
    defer model.freePeerLocator(allocator, loc_again);
    try std.testing.expectError(
        driver.core.HostError.SessionPairExists,
        dialer.openDialedLocator(loc_again),
    );
    try dialer.releaseSession(first);
    try acceptor.releaseSession(accepted);
}

test "core host: dual accept settlement condemns the second session to the same partner key" {
    const allocator = std.testing.allocator;
    var host = Host.init(allocator, [_]u8{0x3f} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var peer = Host.init(allocator, [_]u8{0x40} ** 32, Host.Options.withFrameCap(frame_cap));
    defer peer.deinit();

    const first = try host.openAccepted("tcp", "127.0.0.1:7015", &.{});
    const second = try host.openAccepted("tcp", "127.0.0.1:7016", &.{});
    // One peer hello fed to both accepted sessions: the first keeps the
    // partner key; the second is condemned at start-session (ADR-0012).
    const peer_dialed = try peer.openDialedLocator(tcpLocator("127.0.0.1:7015"));
    var hello = (try peer_dialed.takeOutbound()) orelse return error.MissingHello;
    defer hello.deinit();
    try host.feed(first, hello.view());
    try std.testing.expect(!first.condemned);
    try std.testing.expect(first.sessionOpen());
    try host.feed(second, hello.view());
    try std.testing.expect(second.condemned);
    try std.testing.expect(!second.sessionOpen());
    try host.releaseSession(first);
    try host.releaseSession(second);
    try peer.releaseSession(peer_dialed);
}

test "core host: partner-key index empties after enroll, learn, condemn, and release" {
    const allocator = std.testing.allocator;
    var host = Host.init(allocator, [_]u8{0x53} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var peer = Host.init(allocator, [_]u8{0x54} ** 32, Host.Options.withFrameCap(frame_cap));
    defer peer.deinit();

    const first = try host.openAccepted("tcp", "127.0.0.1:7020", &.{});
    const second = try host.openAccepted("tcp", "127.0.0.1:7021", &.{});
    const peer_dialed = try peer.openDialedLocator(tcpLocator("127.0.0.1:7020"));
    var hello = (try peer_dialed.takeOutbound()) orelse return error.MissingHello;
    defer hello.deinit();
    try host.feed(first, hello.view());
    try std.testing.expectEqual(@as(usize, 1), host.partner_by_key.count());
    try host.feed(second, hello.view());
    try std.testing.expect(second.condemned);
    try std.testing.expectEqual(@as(usize, 1), host.partner_by_key.count());
    try host.releaseSession(second);
    try std.testing.expectEqual(@as(usize, 1), host.partner_by_key.count());
    try host.releaseSession(first);
    try std.testing.expectEqual(@as(usize, 0), host.partner_by_key.count());
    try std.testing.expectEqual(@as(usize, 0), host.dialed_by_designator.count());
    try peer.releaseSession(peer_dialed);
}

test "core host: a burst of accepts before any start-session indexes every partner key without overflow" {
    // Regression (ADR-0012): `partner_by_key` reserves at its own insert
    // (`indexPartnerKey`), not at mint. A partner key is unknown until that
    // partner's `op:start-session` arrives, so every session minted before a
    // single start-session is fed stays un-indexed — a mint-time reservation
    // would never grow the map across those mints and would overflow
    // `putAssumeCapacity` once the burst passed the map's usable capacity.
    const allocator = std.testing.allocator;
    const n = 8; // past AutoHashMap's minimal usable capacity, the old overflow point
    var host = Host.init(allocator, [_]u8{0x60} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var peers: [n]Host = undefined;
    var peers_inited: usize = 0;
    defer for (peers[0..peers_inited]) |*p| p.deinit();

    var accepted: [n]*HostSession = undefined;
    var dialed: [n]*HostSession = undefined;

    // Mint every accepted session (and its dialing partner) first: the whole
    // burst is un-indexed before one start-session is fed.
    for (0..n) |i| {
        peers[i] = Host.init(allocator, [_]u8{@as(u8, @intCast(0x61 + i))} ** 32, Host.Options.withFrameCap(frame_cap));
        peers_inited += 1;
        var buf: [24]u8 = undefined;
        const designator = try std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{7100 + i});
        accepted[i] = try host.openAccepted("tcp", designator, &.{});
        dialed[i] = try peers[i].openDialedLocator(tcpLocator(designator));
    }
    try std.testing.expectEqual(@as(usize, 0), host.partner_by_key.count());

    // Feed each partner's hello: each learns a distinct partner key and indexes
    // a fresh row. Under the mint-reservation bug the 7th insert overflowed the
    // 6 usable slots the single effective reservation had pinned.
    for (0..n) |i| {
        var hello = (try dialed[i].takeOutbound()) orelse return error.MissingHello;
        defer hello.deinit();
        try host.feed(accepted[i], hello.view());
        try std.testing.expect(accepted[i].sessionOpen());
        try std.testing.expect(!accepted[i].condemned);
    }
    try std.testing.expectEqual(@as(usize, n), host.partner_by_key.count());

    for (0..n) |i| {
        try host.releaseSession(accepted[i]);
        try peers[i].releaseSession(dialed[i]);
    }
    try std.testing.expectEqual(@as(usize, 0), host.partner_by_key.count());
}

test "core host: crossed dials with mismatched designator spellings keep one key-ordered session" {
    const allocator = std.testing.allocator;
    const crypto = pancake.foundation.crypto;

    // Lower-keyed host A, higher-keyed host B — both ends must keep the session
    // B opened (A's accepted / B's dialed) when designator spelling misses
    // tiebreakInbound (ADR-0068 / ADR-0012).
    var a = Host.init(allocator, [_]u8{0x01} ** 32, Host.Options.withFrameCap(frame_cap));
    defer a.deinit();
    var b = Host.init(allocator, [_]u8{0xff} ** 32, Host.Options.withFrameCap(frame_cap));
    defer b.deinit();

    const a_pid = crypto.derivePublicIdentifier(a.node.secretKey().publicKey());
    const b_pid = crypto.derivePublicIdentifier(b.node.secretKey().publicKey());
    try std.testing.expect(std.mem.order(u8, &a_pid.bytes, &b_pid.bytes) == .lt);

    // Accept designators differ from the addresses the peer will dial, so
    // crossed-hellos registry lookup misses and refuseDuplicatePartnerKey is
    // the only collapse.
    const a_accept = try a.openAccepted("tcp", "10.0.0.1:9000", &.{});
    const b_accept = try b.openAccepted("tcp", "10.0.0.1:8001", &.{});
    const a_dialed = try a.openDialedLocator(tcpLocator("127.0.0.1:8001"));
    const b_dialed = try b.openDialedLocator(tcpLocator("127.0.0.1:9000"));

    var a_hello = (try a_dialed.takeOutbound()) orelse return error.MissingAHello;
    defer a_hello.deinit();
    var b_hello = (try b_dialed.takeOutbound()) orelse return error.MissingBHello;
    defer b_hello.deinit();
    var a_accept_hello = (try a_accept.takeOutbound()) orelse return error.MissingAAcceptHello;
    defer a_accept_hello.deinit();
    var b_accept_hello = (try b_accept.takeOutbound()) orelse return error.MissingBAcceptHello;
    defer b_accept_hello.deinit();

    // Cross-feed: each dialed hello lands on the peer's accepted session, and
    // each accepted hello lands on the peer's dialed session.
    try b.feed(b_accept, a_hello.view());
    try a.feed(a_accept, b_hello.view());
    try b.feed(b_dialed, a_accept_hello.view());
    try a.feed(a_dialed, b_accept_hello.view());

    // A is lower-keyed → keep accepted, condemn dialed. B is higher → keep dialed.
    try std.testing.expect(!a_accept.condemned);
    try std.testing.expect(a_dialed.condemned);
    try std.testing.expect(!a_dialed.sessionOpen());
    try std.testing.expect(!b_dialed.condemned);
    try std.testing.expect(b_accept.condemned);
    try std.testing.expect(!b_accept.sessionOpen());

    try a.releaseSession(a_accept);
    try a.releaseSession(a_dialed);
    try b.releaseSession(b_accept);
    try b.releaseSession(b_dialed);
    try std.testing.expectEqual(@as(usize, 0), a.partner_by_key.count());
    try std.testing.expectEqual(@as(usize, 0), b.partner_by_key.count());
}

test "core host: vow rows retire on settle; the map stays empty and release frees the rest" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x4a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x4b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);
    _ = try pair.b.served.publish("widget", Widget, .{});
    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "widget"), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const widget_ref = try fetched.require();
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());

    // Settlement retires each row, listener or not: the map never grows with
    // completed calls.
    for (0..4) |i| {
        const vow = try client.send(pair.a, widget_ref, .{ .verb = "poke", .args = &.{} });
        var reply = CapturedString{};
        if (i % 2 == 0) try client.vowOn(vow, .{ .ctx = &reply, .func = CapturedString.record });
        try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
        if (i % 2 == 0) try std.testing.expectEqualStrings("poked over fed bytes", reply.buf[0..reply.len]);
    }
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());

    // One listener per vow, and a settled id is simply gone.
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

test "core host: a failed dial breaks the redeeming vow with the reason" {
    const allocator = std.testing.allocator;
    var exporter = Host.init(allocator, [_]u8{0x0e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = Host.init(allocator, [_]u8{0x06} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = Host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7001", &dials);
    _ = try g_to_e.b.served.publish("widget", Widget, .{});
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);

    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7002", &dials);
    _ = try r_to_g.b.served.publish("introducer", Introducer, .{ .widget = widget.ref.? });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);

    const introduce_vow = try recipient.send(r_to_g.a, introducer.ref.?, .{ .verb = "introduce", .args = &.{} });
    var redeemed = CapturedRef{};
    try recipient.vowOn(introduce_vow, .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);

    // The exporter is unreachable: the dial's failure breaks the vow.
    try recipient.dialFailed(dials.items[0].ticket, "exporter unreachable");
    try std.testing.expect(redeemed.broken);
    try std.testing.expect(redeemed.ref == null);
}

/// Open a pair, publish the widget, and fetch it with an in-process listener —
/// the shared preamble of the queue-drain scenarios below.
fn openWidgetPair(
    allocator: std.mem.Allocator,
    client: *Host,
    server: *Host,
    dials: *std.ArrayList(ParkedDial),
) !struct { pair: Pair, widget: model.Reference } {
    const pair = try openPair(allocator, client, server, "127.0.0.1:7001", dials);
    _ = try pair.b.served.publish("widget", Widget, .{});
    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "widget"), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ client, server }, &.{pair}, dials);
    return .{ .pair = pair, .widget = try fetched.require() };
}

test "core host: an unlistened settle rides the action queue owned, valid until the next nextAction frees it" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x5a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x5b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const opened = try openWidgetPair(allocator, &client, &server, &dials);

    // No listener anywhere: the settle must surface as a queued completion.
    const vow = try client.send(opened.pair.a, opened.widget, .{ .verb = "poke", .args = &.{} });
    _ = try shuttleAll(&.{opened.pair}); // the deliver reaches the server
    _ = try shuttleAll(&.{opened.pair}); // the resolve settles the vow

    // Drain by hand: the popped completion's deep-cloned value stays valid
    // across this whole iteration — the next `nextAction` call frees it —
    // and the row is already retired.
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
                try std.testing.expect(std.mem.indexOf(u8, f.message, "transport gone") != null);
                fail_count += 1;
            },
            else => return error.UnexpectedAction,
        }
    }
    try std.testing.expectEqual(@as(usize, 1), fail_count);
}

test "core host: an unlistened fetch completion carries the node-enrolled token" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x6a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x6b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);
    _ = try pair.b.served.publish("widget", Widget, .{});

    // No listener: the enrollment mapping still runs before the completion is
    // queued, so the drained value is the routable token, never a raw import.
    const fetch_vow = try client.fetch(pair.a, "widget");
    _ = try shuttleAll(&.{pair});
    _ = try shuttleAll(&.{pair});
    var token: ?model.Reference = null;
    while (try client.nextAction()) |action| {
        switch (action) {
            .flush => {},
            .settled => |s| {
                try std.testing.expectEqual(fetch_vow, s.vow_id);
                try std.testing.expect(s.value == .reference);
                token = s.value.reference;
            },
            else => return error.UnexpectedAction,
        }
    }
    const reference = token orelse return error.FetchDidNotSettle;
    try std.testing.expect(reference == .far);
    try std.testing.expect(reference.far.import_position.int() >= pancake.ocapn.engine.Node.REDEEMED_TOKEN_BASE);
}

test "core host: a burst of unlistened settles never strands — every completion lands on the reserved queue" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x7a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x7b} ** 32, Host.Options.withFrameCap(frame_cap));
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

    var seen = [_]bool{false} ** burst;
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
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
}

test "core host: a settle under OOM never strands a vow and never trips the reserved completion queue" {
    // Sweep a failing allocator across every allocation index of the settle
    // window: the setup (handshake, publish, fetch, the burst of sends) runs
    // unarmed, then the reply frames are fed with the allocator armed to
    // fail at `offset` and every allocation after it. For every offset the
    // invariant is the same: no `appendAssumeCapacity` panic (the completion
    // queue is reserved at mint) and every minted vow stays accounted — its
    // completion drained, or its row still live because the feed failed
    // before the resolve applied. A silently vanished vow is a strand.
    var offset: usize = 0;
    while (true) : (offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        var saw_oom = false;
        {
            var client = Host.init(allocator, [_]u8{0x9a} ** 32, Host.Options.withFrameCap(frame_cap));
            defer client.deinit();
            var server = Host.init(allocator, [_]u8{0x9b} ** 32, Host.Options.withFrameCap(frame_cap));
            defer server.deinit();
            var dials: std.ArrayList(ParkedDial) = .empty;
            defer dials.deinit(std.testing.allocator);
            const opened = try openWidgetPair(std.testing.allocator, &client, &server, &dials);

            const burst = 4;
            var vows: [burst]u64 = undefined;
            for (&vows) |*slot| {
                slot.* = try client.send(opened.pair.a, opened.widget, .{ .verb = "poke", .args = &.{} });
            }

            // Arm: the next `offset` allocations succeed, everything after
            // fails — the replies are fed (and the settles fire) inside this
            // window.
            failing.fail_index = failing.alloc_index + offset;
            var failed_run = false;
            _ = shuttleAll(&.{opened.pair}) catch {
                failed_run = true;
            };
            if (!failed_run) _ = shuttleAll(&.{opened.pair}) catch {
                failed_run = true;
            };
            // A run may only fail because the sweep induced it.
            if (failed_run) try std.testing.expect(failing.has_induced_failure);
            saw_oom = failing.has_induced_failure;

            // Disarm and account for every vow: a drained completion or a
            // still-live row, never neither.
            failing.fail_index = std.math.maxInt(usize);
            var seen = [_]bool{false} ** burst;
            while (try client.nextAction()) |action| {
                switch (action) {
                    .settled => |s| for (vows, 0..) |id, i| {
                        if (id == s.vow_id) seen[i] = true;
                    },
                    .failed => |f| for (vows, 0..) |id, i| {
                        if (id == f.vow_id) seen[i] = true;
                    },
                    else => {},
                }
            }
            for (vows, seen) |id, hit| {
                if (!hit) try std.testing.expect(client.vows.contains(id));
            }
        }
        if (!saw_oom) break;
        // The window is a bounded handful of allocations; a sweep that never
        // completes means something regressed into an allocation storm.
        try std.testing.expect(offset < 512);
    }
}

test "designatorSchemeForTransport maps iroh and keyed-tcp to key" {
    try std.testing.expectEqual(driver.core.DesignatorScheme.key, driver.core.designatorSchemeForTransport("iroh"));
    try std.testing.expectEqual(driver.core.DesignatorScheme.key, driver.core.designatorSchemeForTransport("keyed-tcp"));
    try std.testing.expectEqual(driver.core.DesignatorScheme.address, driver.core.designatorSchemeForTransport("tcp"));
}

test "byte-fed iroh dial pin: matching key opens; squatter key is PartnerKeyMismatch" {
    const allocator = std.testing.allocator;
    const crypto = pancake.foundation.crypto;

    const honest_seed = [_]u8{0x41} ** 32;
    const honest = crypto.SecretKey.fromSeed(honest_seed);
    const designator = honest.publicKey().toDesignator();
    var uri_buf: [96]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buf, "ocapn://{s}.iroh", .{designator[0..]});

    // Happy path: acceptor Host seed ≡ dialed iroh designator → pin holds.
    {
        var dialer = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
        defer dialer.deinit();
        var acceptor = Host.init(allocator, honest_seed, Host.Options.withFrameCap(frame_cap));
        defer acceptor.deinit();
        var dials: std.ArrayList(ParkedDial) = .empty;
        defer dials.deinit(allocator);

        // iroh accepts may omit direct-addresses (discovery); keyed-tcp may not.
        const accepted = try acceptor.openAccepted("iroh", designator[0..], &.{});
        const loc = try model.uri.parsePeer(allocator, uri);
        defer model.freePeerLocator(allocator, loc);
        const dialed = try dialer.openDialedLocator(loc);
        const pair = Pair{ .ah = &dialer, .a = dialed, .bh = &acceptor, .b = accepted };
        try pumpToQuiescence(allocator, &.{ &dialer, &acceptor }, &.{pair}, &dials);
        try std.testing.expect(dialed.sessionOpen());
        try std.testing.expect(accepted.sessionOpen());
    }

    // Negative: acceptor signs with a different key under the dialed designator.
    {
        const squatter_seed = [_]u8{0x42} ** 32;
        var dialer = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
        defer dialer.deinit();
        var acceptor = Host.init(allocator, squatter_seed, Host.Options.withFrameCap(frame_cap));
        defer acceptor.deinit();

        const accepted = try acceptor.openAccepted("iroh", designator[0..], &.{});
        const loc = try model.uri.parsePeer(allocator, uri);
        defer model.freePeerLocator(allocator, loc);
        const dialed = try dialer.openDialedLocator(loc);
        // Drive the acceptor's hello onto the dialer: the pin refuses before
        // the session opens.
        _ = try accepted.served.driveFed();
        var hello = (try accepted.takeOutbound()) orelse return error.NoAcceptorHello;
        defer hello.deinit();
        try std.testing.expectError(error.PartnerKeyMismatch, dialer.feed(dialed, hello.view()));
        try std.testing.expect(!dialed.sessionOpen());
    }
}

test "queueUniqueSessionAction keeps one flush and one close per conn" {
    const allocator = std.testing.allocator;
    var host = Host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const a: engine.PeerId = @enumFromInt(1);
    const b: engine.PeerId = @enumFromInt(2);
    try host.testingQueueUniqueSessionAction(.flush, a);
    try host.testingQueueUniqueSessionAction(.flush, a);
    try host.testingQueueUniqueSessionAction(.close, a);
    try host.testingQueueUniqueSessionAction(.close, a);
    try host.testingQueueUniqueSessionAction(.flush, b);
    var flushes: usize = 0;
    var closes: usize = 0;
    while (try host.nextAction()) |action| {
        switch (action) {
            .flush => |id| {
                flushes += 1;
                try std.testing.expect(id == a or id == b);
            },
            .close => |id| {
                closes += 1;
                try std.testing.expectEqual(a, id);
            },
            else => try std.testing.expect(false),
        }
    }
    try std.testing.expectEqual(@as(usize, 2), flushes);
    try std.testing.expectEqual(@as(usize, 1), closes);
}

test "a keyed dial to a malformed designator refuses without freeing it twice" {
    // `keyed-tcp` pins the session to the key its designator names, so a
    // designator that is not canonical Ed25519 hex is refused after the shell
    // has been minted. The refusal path unwinds the mint, and the dialed
    // designator has exactly one owner, so this is a plain error rather than a
    // second free of bytes the shell already released. Reachable straight from
    // `pancake_host_session_open_dialed_locator`, which passes an embedder's
    // transport and designator through untouched.
    const allocator = std.testing.allocator;
    var host = Host.init(allocator, [_]u8{0x21} ** 32, .{});
    defer host.deinit();

    try std.testing.expectError(error.InvalidAddress, host.openDialedLocator(.{
        .transport = "keyed-tcp",
        .designator = "not-a-key",
        .hints = model.Hints.emptyFalse(),
    }));

    // The refusal left nothing behind: the same designator dials again.
    try std.testing.expectError(error.InvalidAddress, host.openDialedLocator(.{
        .transport = "keyed-tcp",
        .designator = "not-a-key",
        .hints = model.Hints.emptyFalse(),
    }));
}
