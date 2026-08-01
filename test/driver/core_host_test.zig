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
const crypto = pancake.foundation.crypto;

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

test "core host: inbound OOM leaves a borrowed hello retryable" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var host = Host.init(allocator, [_]u8{0x31} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var peer = Host.init(std.testing.allocator, [_]u8{0x32} ** 32, Host.Options.withFrameCap(frame_cap));
    defer peer.deinit();

    const accepted = try host.openAccepted("tcp", "127.0.0.1:7091", &.{});
    const dialed = try peer.openDialedLocator(tcpLocator("127.0.0.1:7091"));
    defer peer.releaseSession(dialed) catch unreachable;
    var hello = (try dialed.takeOutbound()) orelse return error.MissingHello;
    defer hello.deinit();

    // Fail the next inbound allocation. The hello must remain unapplied and
    // its borrowed frame retryable; parked-withdraw scheduler reservation is
    // exercised separately on the adopted-Peer admission path.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, host.feed(accepted, hello.view()));
    try std.testing.expect(!accepted.sessionOpen());

    // The same borrowed frame remains retryable. Once allocation is restored,
    // it applies normally and the session opens.
    failing.fail_index = std.math.maxInt(usize);
    try host.feed(accepted, hello.view());
    try std.testing.expect(accepted.sessionOpen());
    try host.releaseSession(accepted);
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

/// The exporter's vendor: replies with a capability to an object it hosts, so
/// a caller comes by that capability through an ordinary call instead of
/// through `fetch`. `fetch` is the one path that enrolls its result on its
/// own, so this is how a test gets a capability that has no routing token yet.
const Vendor = struct {
    widget: model.Reference,
    pub fn handle(self: *Vendor, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "make")) return error.NoSuchMethod;
        return .{ .reference = self.widget };
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
const shuttle = host_pair.shuttle;
const shuttleAll = host_pair.shuttleAll;
const tcpLocator = host_pair.tcpLocator;

fn tcpSturdyref(designator: []const u8, swissnum: []const u8) model.SturdyRef {
    return .{ .peer = tcpLocator(designator), .swissnum = swissnum };
}

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

test "core host: verified session directory authenticates an early handoff gifter" {
    const allocator = std.testing.allocator;
    var gifter = Host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var exporter = Host.init(allocator, [_]u8{0x0d} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7003", &dials);
    const exporter_peer = pair.b.served.port.peer;
    const gifter_key = exporter_peer.session_state.partnerSessionKey().?;
    const exporter_key = exporter_peer.session_state.localSessionKey().?;
    const gifter_side = try engine.handoff_names.sideName(gifter_key);
    const exporter_side = try engine.handoff_names.sideName(exporter_key);
    const session_name = engine.handoff_names.sessionName(gifter_side, exporter_side);

    const resolver = exporter.node.gifterSessionResolver().?;
    const resolved = resolver.resolve(resolver.ctx, gifter_side, &session_name) orelse
        return error.MissingGifterKey;
    try std.testing.expectEqualSlices(u8, gifter_key, &resolved.key);
    try std.testing.expectEqual(exporter_peer.giftRegistry(), resolved.gifts);
    var wrong_session = session_name;
    wrong_session[0] ^= 0xff;
    try std.testing.expect(resolver.resolve(resolver.ctx, gifter_side, &wrong_session) == null);

    try exporter.releaseSession(pair.b);
    try std.testing.expect(resolver.resolve(resolver.ctx, gifter_side, &session_name) == null);
    try gifter.releaseSession(pair.a);
}

test "core host: sturdyref peer mismatch and accepted TCP assertion refuse before fetch" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);

    try std.testing.expectError(
        driver.core.HostError.PeerIdentityMismatch,
        client.enliven(pair.a, tcpSturdyref("127.0.0.1:7999", "same-swiss")),
    );
    try std.testing.expect((try pair.a.takeOutbound()) == null);

    const claimed = tcpSturdyref(driver.unreachable_client_designator, "same-swiss");
    try std.testing.expectError(
        driver.core.HostError.PeerIdentityUnverified,
        server.enliven(pair.b, claimed),
    );
    try std.testing.expect((try pair.b.takeOutbound()) == null);

    const opted = try server.enlivenWithPolicy(pair.b, claimed, .assertion_only);
    try std.testing.expectEqual(driver.core.PeerProvenance.assertion_only, opted.provenance);
    var fetch_frame = (try pair.b.takeOutbound()) orelse return error.MissingFetch;
    fetch_frame.deinit();
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
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

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

/// One generation of a host-wide giftable. The reply is the tag its row carries,
/// so a call says *which* registration answered rather than only that one did.
const Tagged = struct {
    row: *TaggedRow,
    pub fn handle(self: *Tagged, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "mutate")) {
            self.row.tag = "mutated-original";
        } else if (!std.mem.eql(u8, msg.verb, "tag")) return error.NoSuchMethod;
        return .{ .string = self.row.tag };
    }

    pub fn deinit(self: *Tagged, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.row.freed.* = true;
    }
};

/// The `ctx` behind one giftable registration, which every actor it published
/// borrows. `free` records the release instead of doing one, so a test can say
/// when the host let go.
const TaggedRow = struct {
    tag: []const u8,
    freed: *bool,
};

test "core host: a replaced giftable keeps answering at the position it already granted" {
    // `publishGiftable` replacement changes discovery, not a live capability. The
    // displaced actor remains exported at its existing position and still
    // reads the state it was spawned with. Hence: hold a capability to the
    // first registration, replace the name, and call the capability.
    const allocator = std.testing.allocator;
    var first_freed = false;
    var second_freed = false;
    var first = TaggedRow{ .tag = "first", .freed = &first_freed };
    var second = TaggedRow{ .tag = "second", .freed = &second_freed };
    {
        var client = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
        defer client.deinit();
        var server = Host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
        defer server.deinit();
        var dials: std.ArrayList(ParkedDial) = .empty;
        defer dials.deinit(allocator);

        const pair = try openPair(allocator, &client, &server, "127.0.0.1:7061", &dials);
        _ = try server.publishGiftable("inbox", Tagged, .{ .row = &first });
        const first_position = (try server.publishedPosition(pair.b, "inbox")).?;

        // The client takes a routable capability to the first registration while
        // it is still the one the name resolves to.
        var held = CapturedRef{};
        const fetch_vow = try client.fetch(pair.a, "inbox");
        try client.vowOn(fetch_vow, .{ .ctx = &held, .func = CapturedRef.record });
        try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
        const first_cap = try held.require();

        _ = try server.publishGiftable("inbox", Tagged, .{ .row = &second });
        const second_position = (try server.publishedPosition(pair.b, "inbox")).?;
        try std.testing.expect(first_position != second_position);
        try std.testing.expect(!first_freed);

        // The held capability still reaches the first registration's actor, and
        // the actor still reads the ctx it was published with.
        const old_vow = try client.send(pair.a, first_cap, .{ .verb = "tag", .args = &.{} });
        var old_reply = CapturedString{};
        try client.vowOn(old_vow, .{ .ctx = &old_reply, .func = CapturedString.record });
        try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
        try std.testing.expectEqualStrings("first", old_reply.buf[0..old_reply.len]);

        // A fetch by name now resolves to the replacement, so the name moved even
        // though the capability did not.
        var fresh = CapturedRef{};
        const second_fetch = try client.fetch(pair.a, "inbox");
        try client.vowOn(second_fetch, .{ .ctx = &fresh, .func = CapturedRef.record });
        try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
        const second_cap = try fresh.require();
        const new_vow = try client.send(pair.a, second_cap, .{ .verb = "tag", .args = &.{} });
        var new_reply = CapturedString{};
        try client.vowOn(new_vow, .{ .ctx = &new_reply, .func = CapturedString.record });
        try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
        try std.testing.expectEqualStrings("second", new_reply.buf[0..new_reply.len]);
    }
    // Both Vat actors are released at Host teardown, including the one no
    // longer reachable through the alias.
    try std.testing.expect(first_freed);
    try std.testing.expect(second_freed);
}

test "core host: a deposited gift keeps its exact actor across alias replacement and a second exporter Port" {
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

    var original_freed = false;
    var replacement_freed = false;
    var original = TaggedRow{ .tag = "original", .freed = &original_freed };
    var replacement = TaggedRow{ .tag = "replacement", .freed = &replacement_freed };
    _ = try exporter.publishGiftable("widget", Tagged, .{ .row = &original });

    // Gifter dials the exporter and fetches the widget: the node records the
    // capability's foreign home, which is what the give will name. Fetch lazily
    // projects the Host-Vat actor onto this first exporter Port.
    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7001", &dials);
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const widget_ref = try widget.require();

    // Mutate through the capability on the gifter-facing Port. The later call
    // through the recipient-facing Port must observe this same actor state.
    var mutated = CapturedString{};
    try gifter.vowOn(try gifter.send(g_to_e.a, widget_ref, .{ .verb = "mutate", .args = &.{} }), .{ .ctx = &mutated, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    try std.testing.expectEqualStrings("mutated-original", mutated.buf[0..mutated.len]);

    // Recipient dials the gifter and fetches the introducer.
    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7002", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = widget_ref });
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

    // The deposit has crossed the gifter-facing exporter Port and captured the
    // original actor. Move the public alias before the recipient opens its own
    // exporter Port. A withdraw-time name lookup would now redirect the gift.
    _ = try exporter.publishGiftable("widget", Tagged, .{ .row = &replacement });

    // The test is the dial executor: open the recipient's own connection to
    // the exporter, drive it open, and report it back. The withdraw, its
    // settle, and the vow's fulfillment all pump inside the report. No alias is
    // projected on this Port until either the exact gift or a fresh fetch asks.
    const e_accepts_r = try exporter.openAccepted("tcp", "127.0.0.1:7001", &.{});
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

    // The redeemed capability reaches the actor deposited before replacement,
    // not whichever actor the alias names at withdrawal time.
    const exact_vow = try recipient.send(r_to_g.a, token_ref, .{ .verb = "tag", .args = &.{} });
    var exact = CapturedString{};
    try recipient.vowOn(exact_vow, .{ .ctx = &exact, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("mutated-original", exact.buf[0..exact.len]);

    // Discovery did move: a fresh fetch over that same recipient-facing Port
    // resolves the replacement. The test distinguishes capability identity
    // from the mutable public name in both directions.
    var discovered = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_e, "widget"), .{ .ctx = &discovered, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    const replacement_ref = try discovered.require();
    const replacement_vow = try recipient.send(r_to_e, replacement_ref, .{ .verb = "tag", .args = &.{} });
    var replacement_reply = CapturedString{};
    try recipient.vowOn(replacement_vow, .{ .ctx = &replacement_reply, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("replacement", replacement_reply.buf[0..replacement_reply.len]);
}

test "core host: closing the gifter session destroys its deposited gifts and breaks later withdraw" {
    const allocator = std.testing.allocator;
    var exporter = Host.init(allocator, [_]u8{0x0e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = Host.init(allocator, [_]u8{0x06} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = Host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
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
    var redeemed = CapturedRef{};
    try recipient.vowOn(introduction, .{ .ctx = &redeemed, .func = CapturedRef.record });

    // Deliver only the call to the gifter. Its reply cannot leave until the
    // embedder answers the gift-id request, at which point the two handoff legs
    // are independently queued on r_to_g and g_to_e.
    try std.testing.expect(try shuttle(r_to_g));
    const gift_id = [_]u8{0x5a} ** 32;
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
    const accepted = try exporter.openAccepted("tcp", "127.0.0.1:7011", &.{});
    const pending = recipient.pendingDial(parked.ticket) orelse return error.MissingPendingDial;
    const dialed = try recipient.openDialedLocator(.{
        .transport = pending.transport,
        .designator = pending.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const r_to_e = Pair{ .ah = &recipient, .a = dialed, .bh = &exporter, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &exporter, &gifter, &recipient }, &.{ r_to_g, r_to_e }, &dials);
    try recipient.exporterDialed(parked.ticket, dialed);
    try pumpToQuiescence(allocator, &.{ &exporter, &gifter, &recipient }, &.{ r_to_g, r_to_e }, &dials);

    try std.testing.expect(redeemed.broken);
    try std.testing.expectEqualStrings("handoff redeem failed: gifter session is not open", redeemed.reason_buf[0..redeemed.reason_len]);
}

const EarlyWithdrawOutcome = enum { deposit, close };

fn runEarlyWithdrawComposition(outcome: EarlyWithdrawOutcome) !void {
    const allocator = std.testing.allocator;
    var exporter = Host.init(allocator, [_]u8{0x0e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = Host.init(allocator, [_]u8{0x06} ** 32, Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = Host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
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
    const gift_id = [_]u8{0x6b} ** 32;
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
    const accepted = try exporter.openAccepted("tcp", "127.0.0.1:7021", &.{});
    const pending = recipient.pendingDial(parked.ticket) orelse return error.MissingPendingDial;
    const dialed = try recipient.openDialedLocator(.{
        .transport = pending.transport,
        .designator = pending.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const r_to_e = Pair{ .ah = &recipient, .a = dialed, .bh = &exporter, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &exporter, &recipient }, &.{r_to_e}, &dials);
    try recipient.exporterDialed(parked.ticket, dialed);
    try pumpToQuiescence(allocator, &.{ &exporter, &recipient }, &.{r_to_e}, &dials);

    try std.testing.expectEqual(@as(usize, 1), exporter.node.handoffWaiterCount(g_to_e.b.peer_id));
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
            try std.testing.expect((try redeemed.require()) == .far);
            try std.testing.expectEqual(@as(usize, 0), exporter.node.handoffWaiterCount(g_to_e.b.peer_id));
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
    try std.testing.expect(token_ref == .far);

    // Crossing the new Host boundary consumes the redeemed Node token: one
    // stale-capable route becomes one import-incarnation-checked Host handle.
    const token = token_ref.far.import_position.int();
    const host_ref = try recipient.liftCapability(r_to_g.a, token_ref);
    try std.testing.expect(recipient.node.routeToken(token) == null);
    const lowered = try recipient.lowerCapability(r_to_e.a, host_ref);

    // The Host handle lowers through the reused exporter session to the widget.
    const poke_vow = try recipient.send(r_to_e.a, lowered, .{ .verb = "poke", .args = &.{} });
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
    nested_listen: CapturedRef = .{},

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
            refusedReentered(host.enliven(conn, tcpSturdyref("127.0.0.1:7001", "widget")));
        const vow = host.send(conn, self.token, .{ .verb = "poke", .args = &.{} }) catch return;
        host.vowOn(vow, .{ .ctx = &self.nested_reply, .func = CapturedString.record }) catch return;
        host.tell(conn, self.token, .{ .verb = "poke", .args = &.{} }) catch return;
        // A settle callback is where you learn a promise, so `listenTo` is
        // enqueueing, not top-level (ADR-0095).
        const listen_vow = host.listenTo(conn, self.token) catch return;
        host.vowOn(listen_vow, .{ .ctx = &self.nested_listen, .func = CapturedRef.record }) catch return;
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
    try std.testing.expectError(condemned_err, a.enliven(condemned, tcpSturdyref(designator, "widget")));
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

test "core host: partner-side index empties after enroll, learn, condemn, and release" {
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
    try std.testing.expectEqual(@as(usize, 1), host.partner_by_side.count());
    try host.feed(second, hello.view());
    try std.testing.expect(second.condemned);
    try host.releaseSession(second);
    try std.testing.expectEqual(@as(usize, 1), host.partner_by_side.count());
    try host.releaseSession(first);
    try std.testing.expectEqual(@as(usize, 0), host.partner_by_side.count());
    try std.testing.expectEqual(@as(usize, 0), host.dialed_by_designator.count());
    try peer.releaseSession(peer_dialed);
}

test "core host: a burst of accepts before any start-session indexes every partner side without overflow" {
    // Regression (ADR-0012): `partner_by_side` reserves at its own insert
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
    try std.testing.expectEqual(@as(usize, 0), host.partner_by_side.count());

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
    try std.testing.expectEqual(@as(usize, n), host.partner_by_side.count());

    for (0..n) |i| {
        try host.releaseSession(accepted[i]);
        try peers[i].releaseSession(dialed[i]);
    }
    try std.testing.expectEqual(@as(usize, 0), host.partner_by_side.count());
}

test "core host: crossed dials with mismatched designator spellings keep one key-ordered session" {
    const allocator = std.testing.allocator;

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
    try std.testing.expectEqual(@as(usize, 0), a.partner_by_side.count());
    try std.testing.expectEqual(@as(usize, 0), b.partner_by_side.count());
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
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
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
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
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
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

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
        _ = try accepted.served.driveFed(&accepted.host.vat);
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
    const a_session = try host.openAccepted("tcp", "127.0.0.1:7101", &.{});
    const b_session = try host.openAccepted("tcp", "127.0.0.1:7102", &.{});
    const a = a_session.peer_id;
    const b = b_session.peer_id;
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

test "reserved session notifications remain allocation-free after mint" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host = Host.init(failing.allocator(), [_]u8{0x2b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const session = try host.openAccepted("tcp", "127.0.0.1:7103", &.{});

    // A queued frame and a terminal verdict can both need notification after
    // protocol ownership has moved. Mint reserved these two slots; neither
    // enqueue may consult the allocator in that irreversible window.
    failing.fail_index = failing.alloc_index;
    try host.testingQueueUniqueSessionAction(.flush, session.peer_id);
    try host.testingQueueUniqueSessionAction(.close, session.peer_id);
    try std.testing.expect(!failing.has_induced_failure);

    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect((try host.takeAction()).? == .flush);
    try std.testing.expect((try host.takeAction()).? == .close);

    // A reservation is reusable capacity, not a one-shot tail index. Repeated
    // pop/push cycles must compact the dead prefix without allocating or ever
    // reaching appendAssumeCapacity at the physical end of the backing.
    failing.fail_index = failing.alloc_index;
    for (0..256) |_| {
        try host.testingQueueUniqueSessionAction(.flush, session.peer_id);
        try std.testing.expect((try host.takeAction()).? == .flush);
    }
    try std.testing.expect(!failing.has_induced_failure);
}

test "abort encode OOM still closes authority and exposes close notification" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host = Host.init(failing.allocator(), [_]u8{0x3b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const session = try host.openAccepted("tcp", "127.0.0.1:7104", &.{});

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(
        error.OutOfMemory,
        host.testingCondemn(session, .resource_exhausted, "allocation pressure"),
    );
    try std.testing.expect(session.condemned);
    try std.testing.expectEqual(pancake.ocapn.session.State.closed, session.served.port.peer.session_state.state);

    failing.fail_index = std.math.maxInt(usize);
    var saw_close = false;
    while (try host.takeAction()) |action| switch (action) {
        .close => |peer_id| {
            try std.testing.expectEqual(session.peer_id, peer_id);
            saw_close = true;
        },
        else => {},
    };
    try std.testing.expect(saw_close);
}

test "release cleanup OOM remains resumable through the action drain" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var host = Host.init(failing.allocator(), [_]u8{0x4b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const remaining = try host.openAccepted("tcp", "127.0.0.1:7105", &.{});
    const released = try host.openAccepted("tcp", "127.0.0.1:7106", &.{});

    try remaining.served.port.peer.sendCopying(.{ .abort = .{
        .kind = .graceful_shutdown,
        .message = "queued before release",
    } });
    host.testingMarkDirty(remaining.peer_id);

    // `releaseSession` has committed the other shell before its cleanup pump.
    // Encode OOM is therefore swallowed, but the dirty row must survive for
    // the documented action-drain retry rather than requiring an unrelated
    // future Host verb.
    failing.fail_index = failing.alloc_index;
    try host.releaseSession(released);
    try std.testing.expect(failing.has_induced_failure);

    failing.fail_index = std.math.maxInt(usize);
    const action = (try host.takeAction()) orelse return error.MissingRetriedFlush;
    try std.testing.expect(action == .flush);
    try std.testing.expectEqual(remaining.peer_id, action.flush);
    var frame = (try remaining.takeOutbound()) orelse return error.MissingRetriedFrame;
    frame.deinit();
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
/// A capability names one object on one session. The wire says so with an
/// integer export position, and that integer means nothing outside the session
/// that minted it — so handing a partner a capability that belongs to a
/// different session is not a shorthand for anything, it is a category error.
///
/// The suite below crosses sessions deliberately, because every other test in
/// this tree drives one session at a time and therefore cannot see this class
/// at all. `sendRedeeming` is what made crossing natural: it hands an
/// application a second session beside a reply, and hosting the reply inbox on
/// the wrong one of the two is a one-word mistake.
const Pad = struct {
    pub fn handle(self: *Pad, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        _ = msg;
        return .{ .string = "pad" };
    }
};

test "cross-session: a capability minted on one session is refused as an argument on another" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var other = Host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer other.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const first = try openPair(allocator, &client, &server, "127.0.0.1:7401", &dials);
    const second = try openPair(allocator, &client, &other, "127.0.0.1:7402", &dials);
    _ = try first.b.served.publish(&first.b.host.vat, "widget", Widget, .{});

    // Mint a capability on the SECOND session, then pad the FIRST session's
    // export table so the same integer position is occupied there too. The
    // padding is what turns a loud refusal into a silent substitution: without
    // a colliding row the position is simply absent and any existence check
    // catches it, which is why this class hides.
    const foreign = try second.a.served.spawn(&second.a.host.vat, Pad, .{});
    var pads: [8]driver.core.Capability = undefined;
    for (&pads) |*p| p.* = try first.a.served.spawn(&first.a.host.vat, Pad, .{});

    // The property being proven: no pad on this session can ever wear the
    // foreign capability's number, so the reference is absent here rather than
    // ambiguous, and the held-export check refuses it. Assert that rather than
    // trusting it, since a stride that stopped being applied would make this
    // test pass for the wrong reason.
    for (pads) |p| {
        try std.testing.expect(p.position != foreign.position);
    }

    const widget_ref = blk: {
        var fetched = CapturedRef{};
        const fetch_vow = try client.fetch(first.a, "widget");
        try client.vowOn(fetch_vow, .{ .ctx = &fetched, .func = CapturedRef.record });
        try pumpToQuiescence(allocator, &.{ &client, &server, &other }, &.{ first, second }, &dials);
        break :blk try fetched.require();
    };

    // Hand the far side a capability that lives on the other session. There is
    // no reading of this that is correct: the position names one of the first
    // session's pads, never the object the caller is holding. It must be
    // refused rather than quietly redirected.
    const result = client.send(first.a, widget_ref, .{
        .verb = "poke",
        .args = &.{.{ .reference = foreign.nearRef() }},
    });
    try std.testing.expectError(error.SendRejected, result);
}

test "cross-session: a capability minted on one session is refused as a send target on another" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var other = Host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer other.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const first = try openPair(allocator, &client, &server, "127.0.0.1:7411", &dials);
    const second = try openPair(allocator, &client, &other, "127.0.0.1:7412", &dials);

    // Addressing the other session's object is the same category error as
    // passing it: the position names one of this session's own objects, or
    // nothing. Either way it is not the actor being held.
    const foreign = try second.a.served.spawn(&second.a.host.vat, Pad, .{});
    var pads: [4]driver.core.Capability = undefined;
    for (&pads) |*p| p.* = try first.a.served.spawn(&first.a.host.vat, Pad, .{});

    try std.testing.expectError(
        error.NoSuchActor,
        client.send(first.a, foreign.nearRef(), .{ .verb = "poke", .args = &.{} }),
    );
}

test "cross-session: a capability minted under one host is refused on another host's session" {
    const allocator = std.testing.allocator;
    // Two hosts in one process is the ordinary shape, not an exotic one: a
    // binding's `connect` with no explicit host mints a fresh one per call, so
    // an application that dials twice holds capabilities from two hosts.
    var left = Host.init(allocator, [_]u8{0x11} ** 32, Host.Options.withFrameCap(frame_cap));
    defer left.deinit();
    var left_partner = Host.init(allocator, [_]u8{0x12} ** 32, Host.Options.withFrameCap(frame_cap));
    defer left_partner.deinit();
    var right = Host.init(allocator, [_]u8{0x13} ** 32, Host.Options.withFrameCap(frame_cap));
    defer right.deinit();
    var right_partner = Host.init(allocator, [_]u8{0x14} ** 32, Host.Options.withFrameCap(frame_cap));
    defer right_partner.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const l = try openPair(allocator, &left, &left_partner, "127.0.0.1:7421", &dials);
    const r = try openPair(allocator, &right, &right_partner, "127.0.0.1:7422", &dials);

    const under_left = try l.a.served.spawn(&l.a.host.vat, Pad, .{});
    var pads: [4]driver.core.Capability = undefined;
    for (&pads) |*p| p.* = try r.a.served.spawn(&r.a.host.vat, Pad, .{});
    for (pads) |p| {
        try std.testing.expect(p.position != under_left.position);
    }

    try std.testing.expectError(
        error.NoSuchActor,
        right.send(r.a, under_left.nearRef(), .{ .verb = "poke", .args = &.{} }),
    );
}

test "cross-session: an adopted peer gets its own export range too" {
    const allocator = std.testing.allocator;
    // The completion loop owns its peers inline and hands them to the host
    // through `openAcceptedOver`, so an adopted session never passes through
    // the owned mint. That is the path with the most connections on it, and
    // the one an application most plausibly holds two sessions of at once — so
    // it is the path a session-numbering fix least affords to miss.
    var host = Host.init(allocator, [_]u8{0x50} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var first = engine.Peer.initNegotiating(allocator);
    defer first.deinit();
    var second = engine.Peer.initNegotiating(allocator);
    defer second.deinit();

    const a = try host.openAcceptedOver(&first, "tcp", "127.0.0.1:7451", &.{});
    const b = try host.openAcceptedOver(&second, "tcp", "127.0.0.1:7452", &.{});

    const from_a = try a.served.spawn(&a.host.vat, Pad, .{});
    const from_b = try b.served.spawn(&b.host.vat, Pad, .{});
    try std.testing.expect(from_a.position != from_b.position);

    // And neither session holds the other's position, which is what makes the
    // held-export check refuse a capability offered to the wrong one.
    try std.testing.expect(a.served.refForExport(from_b.position) == null);
    try std.testing.expect(b.served.refForExport(from_a.position) == null);
}

test "cross-session: a released session's export range comes back for reuse" {
    const allocator = std.testing.allocator;
    // The ranges are carved out of one integer, so they are a fixed budget. A
    // host that never took a released session's range back would spend its
    // whole slot just by churning connections, and an attacker who can open and
    // close them reaches that on purpose. Reuse is what makes the slot a bound
    // on how many sessions are live at once rather than on how many the host
    // may ever open.
    var host = Host.init(allocator, [_]u8{0x51} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var first = engine.Peer.initNegotiating(allocator);
    defer first.deinit();
    const a = try host.openAcceptedOver(&first, "tcp", "127.0.0.1:7461", &.{});
    const released_base = first.session_state.export_base;
    const counter_after_first = host.node.next_export_base;
    try host.releaseSession(a);

    var second = engine.Peer.initNegotiating(allocator);
    defer second.deinit();
    _ = try host.openAcceptedOver(&second, "tcp", "127.0.0.1:7462", &.{});
    try std.testing.expectEqual(released_base, second.session_state.export_base);
    // And the counter did not move: the reuse is what paid for this session.
    try std.testing.expectEqual(counter_after_first, host.node.next_export_base);
}

test "cross-session: a reused export range is the oldest freed, not the newest" {
    const allocator = std.testing.allocator;
    // Reusing the range just freed would put a new session on a released one's
    // numbers immediately, which is the narrowest possible gap between a stale
    // capability and a live object wearing its position. Oldest-first puts
    // every other freed range in between.
    var host = Host.init(allocator, [_]u8{0x52} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var first = engine.Peer.initNegotiating(allocator);
    defer first.deinit();
    var second = engine.Peer.initNegotiating(allocator);
    defer second.deinit();
    const a = try host.openAcceptedOver(&first, "tcp", "127.0.0.1:7463", &.{});
    const b = try host.openAcceptedOver(&second, "tcp", "127.0.0.1:7464", &.{});
    const oldest = first.session_state.export_base;
    const newer = second.session_state.export_base;
    try host.releaseSession(a);
    try host.releaseSession(b);

    var third = engine.Peer.initNegotiating(allocator);
    defer third.deinit();
    var fourth = engine.Peer.initNegotiating(allocator);
    defer fourth.deinit();
    _ = try host.openAcceptedOver(&third, "tcp", "127.0.0.1:7465", &.{});
    _ = try host.openAcceptedOver(&fourth, "tcp", "127.0.0.1:7466", &.{});
    try std.testing.expectEqual(oldest, third.session_state.export_base);
    try std.testing.expectEqual(newer, fourth.session_state.export_base);
}

test "cross-session: a host that has spent its export slot refuses rather than naming the next host's" {
    const allocator = std.testing.allocator;
    // The counter walks one range at a time through a slot the host's identity
    // picked. Carrying past the end would hand this host the *next* host's
    // numbers, which aliases that host's sessions one for one — the very thing
    // the ranges exist to stop — and at the last slot would run export
    // positions into the range the node keeps for its own redeemed tokens, so a
    // position would read as a token. Refusing the mint is the fail-closed
    // answer; reuse above is what keeps an honest host from ever arriving here.
    var host = Host.init(allocator, [_]u8{0x53} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    // Every position this node can hand out stays under its own token base.
    try std.testing.expect(host.node.export_base_end <= engine.Node.REDEEMED_TOKEN_BASE);

    host.node.next_export_base = host.node.export_base_end;
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    try std.testing.expectError(
        error.ExportRangeExhausted,
        host.openAcceptedOver(&peer, "tcp", "127.0.0.1:7467", &.{}),
    );
    // Refused, not carried: the counter is still inside this node's slot.
    try std.testing.expectEqual(host.node.export_base_end, host.node.next_export_base);
}

test "core host: a claimed designator cannot condemn our own dial to it" {
    const allocator = std.testing.allocator;

    // The tiebreak matches an inbound partner's *claimed* location against the
    // dials we have outstanding. A signature proves the partner holds its
    // session key; it proves nothing about where the partner says it lives. On
    // a transport whose designator is a key, the two must agree, or any peer
    // that can open a connection could name a designator we are dialing and
    // make us condemn our own verified outbound session to it, repeatedly, for
    // an exporter it never has to reach or hold a key for.
    var victim = Host.init(allocator, [_]u8{0x77} ** 32, Host.Options.withFrameCap(frame_cap));
    defer victim.deinit();
    var us = Host.init(allocator, [_]u8{0x01} ** 32, Host.Options.withFrameCap(frame_cap));
    defer us.deinit();
    var attacker = Host.init(allocator, [_]u8{0xff} ** 32, Host.Options.withFrameCap(frame_cap));
    defer attacker.deinit();

    // The attacker only wins the tiebreak when our identifier sorts lower, so
    // the scenario needs that ordering to be the interesting one.
    const our_pid = crypto.derivePublicIdentifier(us.node.secretKey().publicKey());
    const attacker_pid = crypto.derivePublicIdentifier(attacker.node.secretKey().publicKey());
    try std.testing.expect(std.mem.order(u8, &our_pid.bytes, &attacker_pid.bytes) == .lt);

    // The victim's keyed designator: the identity we are dialing.
    var victim_designator: [64]u8 = undefined;
    _ = try std.fmt.bufPrint(&victim_designator, "{x}", .{victim.node.secretKey().publicKey().bytes});

    const keyed_locator: pancake.ocapn.model.PeerLocator = .{
        .transport = "keyed-tcp",
        .designator = &victim_designator,
        .hints = pancake.ocapn.model.Hints.emptyFalse(),
    };
    const our_dial = try us.openDialedLocator(keyed_locator);

    // The attacker dials us claiming the victim's designator as its own
    // location, signing with its own key, which is the only key it has.
    try attacker.setSelfDesignator(&victim_designator);
    const our_accepted = try us.openAccepted("tcp", "127.0.0.1:9100", &.{});
    const attacker_dial = try attacker.openDialedLocator(tcpLocator("127.0.0.1:9100"));
    var claim = (try attacker_dial.takeOutbound()) orelse return error.MissingAttackerHello;
    defer claim.deinit();

    try us.feed(our_accepted, claim.view());

    // The claim is ignored, so the dial to the real victim stands.
    try std.testing.expect(!our_dial.condemned);

    try us.releaseSession(our_accepted);
    try us.releaseSession(our_dial);
    try attacker.releaseSession(attacker_dial);
}

/// The partner identity a handshake proves, and the one question an application
/// actually asks of it: is the locator this caller claims its own?
///
/// `Host.partnerIdentity` reports what the `op:start-session` signature covered,
/// and it refuses rather than reporting anything a signature did not cover. The
/// tests below pin both halves, because the refusals are the whole reason a
/// caller can treat a success as proof. A failure here means an application
/// that trusts `partnerIdentity` is trusting a claim instead of a signature.
///
/// These were validated by injection rather than by passing on a healthy tree.
/// Dropping the `verify_partner_handshake` check made the unverified-session
/// test hand back a key nothing had proved, which is the hole that refusal
/// exists to close. Comparing the designator against raw key bytes instead of
/// canonical hex failed the keyed-tcp test. Reporting an absent key as an empty
/// success failed the not-yet-spoken test. Each defect was caught by exactly one
/// test, and the tree went green again when each was reverted.
///
/// What they do not measure: nothing here drives `iroh`, `webrtc`, or
/// `keyed-relay`, so the key-designator claim is proved for `keyed-tcp` alone
/// and rests on the shared `designatorSchemeForTransport` table for the rest.
/// The designator a key-designator transport spells for the host built on
/// `seed`: that host's Ed25519 public key in canonical hex.
fn keyedDesignator(seed: [32]u8) [crypto.PeerKey.designator_len]u8 {
    return crypto.SecretKey.fromSeed(seed).publicKey().toDesignator();
}

test "partner identity: a verified tcp session reports the key its handshake proved" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    const server_seed = [_]u8{0x0b} ** 32;
    var server = Host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);

    // The dialer learned the acceptor's key by verifying its signature, so the
    // key it reports is the one the seed derives rather than anything the
    // partner merely asserted.
    const seen = try client.partnerIdentity(pair.a);
    const expected_key = crypto.SecretKey.fromSeed(server_seed).publicKey();
    try std.testing.expectEqualSlices(u8, expected_key.asBytes(), seen.session_key);
    try std.testing.expectEqualStrings("127.0.0.1:7001", seen.designator);

    // `tcp` designates a socket address. The signature covers it, but the key
    // does not determine it, so the key question has no claim to make here and
    // false is the correct answer rather than a failure.
    try std.testing.expect(!seen.designatorIsSessionKey());
}

test "partner identity: a keyed-tcp partner proves it owns the designator it advertised" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x1a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    const server_seed = [_]u8{0x1b} ** 32;
    var server = Host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const designator = keyedDesignator(server_seed);
    const accepted = try server.openAccepted("keyed-tcp", &designator, "127.0.0.1:7002");
    const dialed = try client.openDialedLocator(.{
        .transport = "keyed-tcp",
        .designator = &designator,
        .hints = model.Hints.emptyFalse(),
    });
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());

    // This is the check an application makes before believing a locator a
    // caller hands it: the advertised name is exactly the key the caller
    // proved it holds.
    const seen = try client.partnerIdentity(pair.a);
    try std.testing.expectEqualStrings(&designator, seen.designator);
    try std.testing.expect(seen.designatorIsSessionKey());

    // The comparison is over canonical hex, not raw key bytes: the designator
    // is twice the key's length, so a raw-bytes comparison cannot match.
    try std.testing.expectEqual(seen.session_key.len * 2, seen.designator.len);
}

test "partner identity: a session that does not verify its partner reports no identity" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x2a} ** 32, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .verify_partner = false,
    });
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x2b} ** 32, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .verify_partner = false,
    });
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7003", &dials);

    try std.testing.expectEqual(@as(usize, 0), client.partner_by_side.count());
    try std.testing.expectEqual(@as(usize, 0), client.partner_by_side.count());
    try std.testing.expectEqual(@as(usize, 0), server.partner_by_side.count());
    try std.testing.expectEqual(@as(usize, 0), server.partner_by_side.count());

    // The handshake completed and a key did arrive, so there are bytes here to
    // hand back. They are refused anyway: nothing checked them, and a caller
    // that could read them would have no way to tell them from proof.
    try std.testing.expectError(error.PartnerUnverified, client.partnerIdentity(pair.a));
}

test "partner identity: a session whose partner has not spoken yet reports no identity" {
    const allocator = std.testing.allocator;
    var server = Host.init(allocator, [_]u8{0x3b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();

    // Accepted, but no partner bytes have been fed, so no `op:start-session`
    // has arrived and there is no key yet.
    const accepted = try server.openAccepted("tcp", "127.0.0.1:7004", "");
    try std.testing.expectError(error.HandshakeIncomplete, server.partnerIdentity(accepted));
}

test "enroll: only a capability this session actually holds gets a routing token" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7601", &dials);
    const widget = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
    _ = try pair.b.served.publish(&pair.b.host.vat, "vendor", Vendor, .{ .widget = widget.nearRef() });

    // Come by a capability the way `fetch` does not cover: ask for one and
    // hold what the reply hands back.
    var vendor = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "vendor"), .{ .ctx = &vendor, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    var made = CapturedRef{};
    const make_vow = try client.send(pair.a, try vendor.require(), .{ .verb = "make", .args = &.{} });
    try client.vowOn(make_vow, .{ .ctx = &made, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    const raw = try made.require();
    try std.testing.expect(raw == .far);
    const position = raw.far.import_position.int();
    try std.testing.expect(model.ImportName.classify(position) == .wire);

    const token = try client.enrollCapability(pair.a, position, .object);
    try std.testing.expect(model.ImportName.classify(token) == .token);

    // Idempotent per import: one object keeps one identity, so a caller that
    // enrolls twice cannot hand two tokens for the same capability to two
    // recipients and have them compare unequal.
    try std.testing.expectEqual(token, try client.enrollCapability(pair.a, position, .object));

    // A token is already routable. Enrolling it again would double-wrap it
    // into a reference no session can lower, so it passes through unchanged.
    try std.testing.expectEqual(token, try client.enrollCapability(pair.a, token, .object));

    // A position with no import row names nothing here. Minting a token for it
    // would route a later gift to a capability the partner never exported, and
    // there would be nowhere to remember the token, so a second enroll would
    // mint a second identity for one object.
    try std.testing.expectError(error.ForeignArgument, client.enrollCapability(pair.a, 9_999, .object));

    // The rule is the row, not reachability. The partner's bootstrap is
    // addressable on a session that has never fetched, and is still refused
    // there; the fetch above is what gave *this* session its row for it, and
    // that same position enrolls fine here.
    var stranger = Host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer stranger.deinit();
    const fresh = try openPair(allocator, &client, &stranger, "127.0.0.1:7602", &dials);
    try std.testing.expectError(error.ForeignArgument, client.enrollCapability(fresh.a, 0, .object));
    try std.testing.expect(try client.enrollCapability(pair.a, 0, .object) != 0);
}

test "enroll: the kind the caller names is what routing reads off the token" {
    // A partner can hand over a promise it has not settled, and only as a
    // delivered argument or a reply — the position arrives with no record of
    // being unsettled, because a far reference goes on the wire the same way
    // either way. So the kind is the caller's to supply, and this is what
    // depends on it: the introducing-session proxy claims a fulfilled *promise*
    // token and declines everything else, so a promise enrolled as an object
    // would reach a third party as a bare position it cannot wait on.
    const allocator = std.testing.allocator;
    var introducer_host = Host.init(allocator, [_]u8{0x1a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer introducer_host.deinit();
    var exporter = Host.init(allocator, [_]u8{0x1b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var recipient = Host.init(allocator, [_]u8{0x1c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &introducer_host, &exporter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    // Two distinct capabilities on one session, so the two enrollments differ
    // in kind rather than in position.
    const i_to_e = try openPair(allocator, &introducer_host, &exporter, "127.0.0.1:7621", &dials);
    const first = try i_to_e.b.served.publish(&i_to_e.b.host.vat, "first", Widget, .{});
    const second = try i_to_e.b.served.publish(&i_to_e.b.host.vat, "second", Widget, .{});
    _ = try i_to_e.b.served.publish(&i_to_e.b.host.vat, "vend-first", Vendor, .{ .widget = first.nearRef() });
    _ = try i_to_e.b.served.publish(&i_to_e.b.host.vat, "vend-second", Vendor, .{ .widget = second.nearRef() });

    var as_promise = CapturedRef{};
    try introducer_host.vowOn(
        try introducer_host.fetch(i_to_e.a, "vend-first"),
        .{ .ctx = &as_promise, .func = CapturedRef.record },
    );
    var as_object = CapturedRef{};
    try introducer_host.vowOn(
        try introducer_host.fetch(i_to_e.a, "vend-second"),
        .{ .ctx = &as_object, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &hosts, &.{i_to_e}, &dials);

    var promise_held = CapturedRef{};
    try introducer_host.vowOn(
        try introducer_host.send(i_to_e.a, try as_promise.require(), .{ .verb = "make", .args = &.{} }),
        .{ .ctx = &promise_held, .func = CapturedRef.record },
    );
    var object_held = CapturedRef{};
    try introducer_host.vowOn(
        try introducer_host.send(i_to_e.a, try as_object.require(), .{ .verb = "make", .args = &.{} }),
        .{ .ctx = &object_held, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &hosts, &.{i_to_e}, &dials);

    const promise_token = try introducer_host.enrollCapability(
        i_to_e.a,
        (try promise_held.require()).far.import_position.int(),
        .promise,
    );
    const object_token = try introducer_host.enrollCapability(
        i_to_e.a,
        (try object_held.require()).far.import_position.int(),
        .object,
    );

    // A recipient session to introduce onto: the proxy needs a session that is
    // not the capability's home.
    const r_to_i = try openPair(allocator, &recipient, &introducer_host, "127.0.0.1:7622", &dials);

    // The promise-kind token is claimed and rewritten to a near promise the
    // recipient can listen on; the object-kind token is left for the gifter
    // intercept beside it.
    const proxied = try introducer_host.node.proxyForeignPromiseFulfill(r_to_i.b.peer_id, promise_token);
    try std.testing.expect(proxied != null);
    try std.testing.expect(proxied.? == .near);
    try std.testing.expectEqual(model.RefKind.promise, proxied.?.near.kind);
    try std.testing.expect(try introducer_host.node.proxyForeignPromiseFulfill(r_to_i.b.peer_id, object_token) == null);
}

test "enroll: one position cannot be enrolled under both kinds" {
    // Enrolling is idempotent per import, so a second enroll of one position is
    // answered with the first one's token. The kind, though, lives on the row
    // that token names, and routing reads it there. So a second caller naming
    // the same position with the other kind cannot be given what it asked for,
    // and it must not be handed the row's kind under its own spelling either:
    // that would tell an application its promise had been enrolled as a promise
    // when the row says object, and the introducing-session proxy would then
    // decline the token it was told to expect a settlement through. The
    // disagreement is refused instead.
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x2a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x2b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7631", &dials);
    const widget = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
    _ = try pair.b.served.publish(&pair.b.host.vat, "vendor", Vendor, .{ .widget = widget.nearRef() });
    var vendor = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "vendor"), .{ .ctx = &vendor, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    var made = CapturedRef{};
    try client.vowOn(
        try client.send(pair.a, try vendor.require(), .{ .verb = "make", .args = &.{} }),
        .{ .ctx = &made, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const position = (try made.require()).far.import_position.int();

    // A fresh enroll cannot conflict: the row is created with the kind asked
    // for, so the first call decides what this position is.
    const token = try client.enrollCapability(pair.a, position, .promise);

    // Same position, same kind: still idempotent, still one token.
    try std.testing.expectEqual(token, try client.enrollCapability(pair.a, position, .promise));

    // Same position, the other kind: refused, and typed, so an embedder can
    // tell this apart from a position it does not hold.
    try std.testing.expectError(
        error.EnrolledKindConflict,
        client.enrollCapability(pair.a, position, .object),
    );

    // The refusal changed nothing. The row still holds the kind it was created
    // with, and the token still answers to it.
    try std.testing.expectEqual(token, try client.enrollCapability(pair.a, position, .promise));

    // A token passes through unchanged whatever kind accompanies it: it is
    // already routable, and the row it was minted from holds the kind, so there
    // is nothing here to record or to disagree with.
    try std.testing.expectEqual(token, try client.enrollCapability(pair.a, token, .object));
}

test "enroll: a capability from a call reply gifts once it is enrolled" {
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

    // The exporter hosts a widget and a vendor that hands it out. The gifter
    // reaches the widget through an ordinary call to the vendor, which is the
    // shape `fetch` does not cover: a capability returned from a call, or
    // lifted from a delivered argument, arrives with no routing token.
    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7611", &dials);
    const hosted = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "widget", Widget, .{});
    _ = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "vendor", Vendor, .{ .widget = hosted.nearRef() });

    var vendor = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "vendor"), .{ .ctx = &vendor, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const vendor_ref = try vendor.require();

    var made = CapturedRef{};
    const make_vow = try gifter.send(g_to_e.a, vendor_ref, .{ .verb = "make", .args = &.{} });
    try gifter.vowOn(make_vow, .{ .ctx = &made, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);

    // The premise this verb exists for, asserted rather than assumed: a call
    // reply settles with a plain wire position. Nothing recorded its home, so
    // the gifter intercept has nothing to look it up by.
    const raw = try made.require();
    try std.testing.expect(raw == .far);
    const raw_position = raw.far.import_position.int();
    try std.testing.expect(model.ImportName.classify(raw_position) == .wire);

    // Enrolling records the home, which is the whole of what was missing.
    const token = try gifter.enrollCapability(g_to_e.a, raw_position, .object);
    try std.testing.expect(model.ImportName.classify(token) == .token);
    const token_arg: model.Reference = .{ .far = model.FarRef.object(token) };

    // From here the existing three-party machinery runs untouched: the
    // gifter's ordinary reply with a foreign-homed capability becomes a signed
    // give, and the recipient redeems it.
    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7612", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = token_arg });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    const introducer_ref = try introducer.require();

    var redeemed = CapturedRef{};
    const introduce_vow = try recipient.send(r_to_g.a, introducer_ref, .{ .verb = "introduce", .args = &.{} });
    try recipient.vowOn(introduce_vow, .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);

    // One dial, naming the exporter: the give carried a real home because the
    // enrollment gave it one.
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];
    try std.testing.expect(parked.host == &recipient);

    const e_accepts_r = try exporter.openAccepted("tcp", "127.0.0.1:7611", &.{});
    _ = try e_accepts_r.served.publish(&e_accepts_r.host.vat, "widget", Widget, .{});
    const redeem_view = recipient.pendingDial(parked.ticket) orelse return error.MissingPendingDial;
    const r_to_e = try recipient.openDialedLocator(.{
        .transport = redeem_view.transport,
        .designator = redeem_view.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const redeem_pair = Pair{ .ah = &recipient, .a = r_to_e, .bh = &exporter, .b = e_accepts_r };
    const all_pairs = [_]Pair{ g_to_e, r_to_g, redeem_pair };
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try recipient.exporterDialed(parked.ticket, r_to_e);
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);

    // The capability the recipient ends up holding reaches the exporter's own
    // object, over the recipient's own connection. That is the claim: a
    // capability that never came from `fetch` was handed to a third party.
    const redeemed_ref = try redeemed.require();
    var poked = CapturedString{};
    const poke_vow = try recipient.send(r_to_g.a, redeemed_ref, .{ .verb = "poke", .args = &.{} });
    try recipient.vowOn(poke_vow, .{ .ctx = &poked, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("poked over fed bytes", poked.buf[0..poked.len]);
}

test "enroll: forgetting to enroll breaks the one reply, not the whole session" {
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

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7621", &dials);
    const hosted = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "widget", Widget, .{});
    _ = try g_to_e.b.served.publish(&g_to_e.b.host.vat, "vendor", Vendor, .{ .widget = hosted.nearRef() });
    var vendor = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "vendor"), .{ .ctx = &vendor, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    var made = CapturedRef{};
    const make_vow = try gifter.send(g_to_e.a, try vendor.require(), .{ .verb = "make", .args = &.{} });
    try gifter.vowOn(make_vow, .{ .ctx = &made, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const raw = try made.require();

    // The introducer replies with the capability *without* enrolling it, so
    // the node was never told its home and the gifter intercept declines. The
    // reply is then a position that means nothing on the recipient's session.
    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7622", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = raw });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);

    var broke = false;
    const introduce_vow = try recipient.send(r_to_g.a, try introducer.require(), .{ .verb = "introduce", .args = &.{} });
    try recipient.vowOn(introduce_vow, .{ .ctx = &broke, .func = promise_capture.captureBroken });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);

    // The caller learns this introduction failed, and nothing was gifted.
    try std.testing.expect(broke);
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);

    // The session survives it. Refusing the one reply is what keeps a
    // forgotten enrollment from becoming an `InvalidReference` that tears the
    // whole connection down: the next call on the same session still works.
    try std.testing.expect(r_to_g.a.sessionOpen());
    var poked = CapturedString{};
    const poke_vow = try gifter.send(g_to_e.a, raw, .{ .verb = "poke", .args = &.{} });
    try gifter.vowOn(poke_vow, .{ .ctx = &poked, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expectEqualStrings("poked over fed bytes", poked.buf[0..poked.len]);
}

test "listen: a host vow settles on the partner's notification, and is spent once" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7701", &dials);
    const widget = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
    _ = try pair.b.served.publish(&pair.b.host.vat, "vendor", Vendor, .{ .widget = widget.nearRef() });

    // Come by a reference through a reply, so the client holds a raw wire
    // position rather than a token: that is what a listen target looks like.
    var vendor = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "vendor"), .{ .ctx = &vendor, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    var made = CapturedRef{};
    try client.vowOn(
        try client.send(pair.a, try vendor.require(), .{ .verb = "make", .args = &.{} }),
        .{ .ctx = &made, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const held = try made.require();

    // Listening on it asks the partner how it settles. CapTP answers a listen
    // on an already-settled capability at once, so the notification comes back
    // naming the same object — proof the round trip ran, not that a promise
    // stayed pending.
    var settled = CapturedRef{};
    const vow = try client.listenTo(pair.a, held);
    try client.vowOn(vow, .{ .ctx = &settled, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const notified = try settled.require();
    try std.testing.expect(notified == .far);
    try std.testing.expectEqual(held.far.import_position, notified.far.import_position);

    // The vow is spent: its row retired when it settled, so a late observer is
    // refused rather than parked on a fire that already happened.
    try std.testing.expectError(
        error.NoSuchVow,
        client.vowOn(vow, .{ .ctx = &settled, .func = CapturedRef.record }),
    );

    // A target this session does not hold names nothing here, refused before
    // anything reaches the wire.
    try std.testing.expectError(
        error.InvalidReference,
        client.listenTo(pair.a, .{ .far = model.FarRef.promise(9_999) }),
    );
}

test "listen: an unsettled listen vow breaks when its session goes" {
    const allocator = std.testing.allocator;
    var client = Host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = Host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7702", &dials);
    const widget = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
    _ = try pair.b.served.publish(&pair.b.host.vat, "vendor", Vendor, .{ .widget = widget.nearRef() });
    var vendor = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "vendor"), .{ .ctx = &vendor, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    var made = CapturedRef{};
    try client.vowOn(
        try client.send(pair.a, try vendor.require(), .{ .verb = "make", .args = &.{} }),
        .{ .ctx = &made, .func = CapturedRef.record },
    );
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    // Listen, but never shuttle the frame: the partner never answers, so the
    // vow is still outstanding when the session goes, and releasing it must
    // break the vow rather than strand its observer.
    var broke = false;
    const vow = try client.listenTo(pair.a, try made.require());
    try client.vowOn(vow, .{ .ctx = &broke, .func = promise_capture.captureBroken });
    try client.releaseSession(pair.a);
    try std.testing.expect(broke);
    try server.releaseSession(pair.b);
}
