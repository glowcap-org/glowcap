//! `driver_core.Host` end to end with no socket anywhere: hosts are wired
//! by moving frames between `takeOutbound` and `feed` by hand, and every host
//! effect (a dial, gift-id entropy) is answered through the action queue —
//! the byte-fed contract the C driver archive and the bindings ride
//! (ADR-0072). The capstone is the full three-party handoff: a gifter's
//! ordinary reply becomes a signed give through the host-internal
//! origination, the recipient's host surfaces one `dial` action, and the
//! settled vow carries a routable token that reaches the exporter's object.

const std = @import("std");
const pancake = @import("pancake");

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
        (Host.Options{}).frame_cap,
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
const Pair = struct { ah: *Host, a: *HostSession, bh: *Host, b: *HostSession };

/// One dial request parked for the test to execute, its locator duped clear of
/// the action queue's popped-view lifetime.
const ParkedDial = struct { host: *Host, ticket: pancake.ocapn.engine.Node.PendingId, locator: []u8 };

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
                    // The parsed pieces ride alongside the URI (host-owned,
                    // same popped-action lifetime); every dial in this file
                    // targets a tcp locator with a socket-address designator.
                    try std.testing.expectEqualStrings("tcp", d.transport);
                    try std.testing.expect(d.designator.len != 0);
                    try std.testing.expectEqual(@as(usize, 0), d.direct_addresses_hint.len);
                    try dials.append(allocator, .{
                        .host = host,
                        .ticket = d.ticket,
                        .locator = try allocator.dupe(u8, d.locator),
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

/// Move every queued frame across every wired pair, both directions. Returns
/// whether anything moved.
fn shuttleAll(pairs: []const Pair) !bool {
    var moved = false;
    for (pairs) |pair| {
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
    }
    return moved;
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

const CapturedRef = struct {
    ref: ?model.Reference = null,
    broken: bool = false,
    reason_buf: [128]u8 = undefined,
    reason_len: usize = 0,

    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *CapturedRef = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| switch (value) {
                .reference => |reference| self.ref = reference,
                else => {},
            },
            .broken => |reason| {
                self.broken = true;
                self.reason_len = @min(reason.len, self.reason_buf.len);
                @memcpy(self.reason_buf[0..self.reason_len], reason[0..self.reason_len]);
            },
            .give => self.broken = true,
        }
    }

    fn require(self: *const CapturedRef) !model.Reference {
        if (self.broken) {
            std.debug.print("vow broke: {s}\n", .{self.reason_buf[0..self.reason_len]});
            return error.VowBroke;
        }
        return self.ref orelse error.VowDidNotSettle;
    }
};

const CapturedString = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    broken: bool = false,

    fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *CapturedString = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| switch (value) {
                .string => |text| {
                    self.len = @min(text.len, self.buf.len);
                    @memcpy(self.buf[0..self.len], text[0..self.len]);
                },
                else => {},
            },
            .broken, .give => self.broken = true,
        }
    }
};

fn tcpLocator(designator: []const u8) model.PeerLocator {
    return .{ .transport = "tcp", .designator = designator, .hints = model.Hints.emptyFalse() };
}

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
    var a = Host.init(allocator, [_]u8{0x0a} ** 32, .{ .frame_cap = frame_cap });
    defer a.deinit();
    var b = Host.init(allocator, [_]u8{0x0b} ** 32, .{ .frame_cap = frame_cap });
    defer b.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    _ = try openPair(allocator, &a, &b, "127.0.0.1:7001", &dials);
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);
}

test "core host: feedBytes fails closed on incomplete-at-cap" {
    const allocator = std.testing.allocator;
    var host = Host.init(allocator, [_]u8{0x0a} ** 32, .{ .frame_cap = 8 });
    defer host.deinit();
    const conn = try host.openAccepted("tcp", "127.0.0.1:7010", &.{});
    const junk = [_]u8{ '<', '1', '0', '\'', 'o', 'p', ':', 'd' };
    try std.testing.expectError(error.FrameTooLarge, host.feedBytes(conn, &junk));
}

test "core host: publish, fetch, and a settled send over fed bytes" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x0a} ** 32, .{ .frame_cap = frame_cap });
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x0b} ** 32, .{ .frame_cap = frame_cap });
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
    var exporter = Host.init(allocator, [_]u8{0x0e} ** 32, .{ .frame_cap = frame_cap });
    defer exporter.deinit();
    var gifter = Host.init(allocator, [_]u8{0x06} ** 32, .{ .frame_cap = frame_cap });
    defer gifter.deinit();
    var recipient = Host.init(allocator, [_]u8{0x0c} ** 32, .{ .frame_cap = frame_cap });
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.locator);
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
    try std.testing.expect(std.mem.indexOf(u8, parked.locator, "127.0.0.1") != null);

    // The test is the dial executor: open the recipient's own connection to
    // the exporter, drive it open, and report it back. The withdraw, its
    // settle, and the vow's fulfillment all pump inside the report. The
    // exporter publishes the widget on this session too: a swissnum-named
    // gift resolves against the *withdraw* session's bootstrap registry (the
    // per-connection publish the C tier's host-level giftable verb automates).
    const e_accepts_r = try exporter.openAccepted("tcp", "127.0.0.1:7001", &.{});
    _ = try e_accepts_r.served.publish("widget", Widget, .{});
    const redeem_loc = try model.uri.parsePeer(allocator, parked.locator);
    defer model.freePeerLocator(allocator, redeem_loc);
    const r_to_e = try recipient.openDialedLocator(redeem_loc);
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
    var client = Host.init(allocator, [_]u8{0x2a} ** 32, .{ .frame_cap = frame_cap });
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x2b} ** 32, .{ .frame_cap = frame_cap });
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
    var a = Host.init(allocator, [_]u8{0x3a} ** 32, .{ .frame_cap = frame_cap });
    defer a.deinit();
    var b = Host.init(allocator, [_]u8{0x3b} ** 32, .{ .frame_cap = frame_cap });
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

test "core host: vow rows retire on settle; the map stays empty and release frees the rest" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x4a} ** 32, .{ .frame_cap = frame_cap });
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x4b} ** 32, .{ .frame_cap = frame_cap });
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
    var exporter = Host.init(allocator, [_]u8{0x0e} ** 32, .{ .frame_cap = frame_cap });
    defer exporter.deinit();
    var gifter = Host.init(allocator, [_]u8{0x06} ** 32, .{ .frame_cap = frame_cap });
    defer gifter.deinit();
    var recipient = Host.init(allocator, [_]u8{0x0c} ** 32, .{ .frame_cap = frame_cap });
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.locator);
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
    var client = Host.init(allocator, [_]u8{0x5a} ** 32, .{ .frame_cap = frame_cap });
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x5b} ** 32, .{ .frame_cap = frame_cap });
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
    var client = Host.init(allocator, [_]u8{0x6a} ** 32, .{ .frame_cap = frame_cap });
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x6b} ** 32, .{ .frame_cap = frame_cap });
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
    var client = Host.init(allocator, [_]u8{0x7a} ** 32, .{ .frame_cap = frame_cap });
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x7b} ** 32, .{ .frame_cap = frame_cap });
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
            var client = Host.init(allocator, [_]u8{0x9a} ** 32, .{ .frame_cap = frame_cap });
            defer client.deinit();
            var server = Host.init(allocator, [_]u8{0x9b} ** 32, .{ .frame_cap = frame_cap });
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
        var dialer = Host.init(allocator, [_]u8{0x0a} ** 32, .{ .frame_cap = frame_cap });
        defer dialer.deinit();
        var acceptor = Host.init(allocator, honest_seed, .{ .frame_cap = frame_cap });
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
        var dialer = Host.init(allocator, [_]u8{0x0a} ** 32, .{ .frame_cap = frame_cap });
        defer dialer.deinit();
        var acceptor = Host.init(allocator, squatter_seed, .{ .frame_cap = frame_cap });
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
    var host = Host.init(allocator, [_]u8{0x0b} ** 32, .{ .frame_cap = frame_cap });
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
