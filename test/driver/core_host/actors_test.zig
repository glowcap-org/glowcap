//! Actors behind the byte-fed Host: a replaced giftable answers at its
//! granted position, deposits keep the exact actor across alias replacement,
//! unpublish removes discovery without revoking issued capabilities, and
//! become history is one history across Ports.

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
const SessionOpenFailingAllocator = harness.SessionOpenFailingAllocator;
const TaggedRow = harness.TaggedRow;
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
        var client = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(frame_cap));
        defer client.deinit();
        var server = test_host.init(allocator, @as([32]u8, @splat(0x0b)), Host.Options.withFrameCap(frame_cap));
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
    const e_accepts_r = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7001", &.{});
    // Production Bridge dials from pendingDial parts — no URI re-parse.
    const redeem_view = recipient.pendingDial(parked.ticket, 0) orelse return error.MissingPendingDial;
    const r_to_e = try recipient.openDialedLocator(.{
        .transport = redeem_view.locator.transport,
        .designator = redeem_view.locator.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const redeem_pair = Pair{ .ah = &recipient, .a = r_to_e, .bh = &exporter, .b = e_accepts_r };
    const all_pairs = [_]Pair{ g_to_e, r_to_g, redeem_pair };
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expect(r_to_e.sessionOpen());
    _ = try recipient.exporterDialed(parked.ticket, 0, r_to_e);
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);

    const token_ref = try redeemed.require();
    try std.testing.expect(token_ref == .routed);

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

test "core host: unpublish removes discovery on every session while issued capabilities and deposited gifts keep the exact actor" {
    // The alias-only unpublish scenario (ADR-0096): all three required
    // outcomes in one production Host. Fresh lookup of the removed alias
    // fails — including on a Port that fetched it before, because the
    // registry is the one discovery authority and a fetch leaves no
    // per-session alias copy behind — while a capability issued before
    // removal remains callable and a gift deposited before removal still
    // redeems the exact (mutated) actor.
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, @as([32]u8, @splat(0x1e)), Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, @as([32]u8, @splat(0x16)), Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, @as([32]u8, @splat(0x1c)), Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    var widget_freed = false;
    var widget_row = TaggedRow{ .tag = "original", .freed = &widget_freed };
    _ = try exporter.publishGiftable("widget", Tagged, .{ .row = &widget_row });

    // Gifter dials the exporter, fetches the widget (issuing a capability and
    // projecting the actor on this Port), and mutates it.
    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7021", &dials);
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const widget_ref = try widget.require();
    var mutated = CapturedString{};
    try gifter.vowOn(try gifter.send(g_to_e.a, widget_ref, .{ .verb = "mutate", .args = &.{} }), .{ .ctx = &mutated, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    try std.testing.expectEqualStrings("mutated-original", mutated.buf[0..mutated.len]);

    // The introduction deposits the gift on the gifter-facing exporter Port.
    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7022", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = widget_ref });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    const introduce_vow = try recipient.send(r_to_g.a, try introducer.require(), .{ .verb = "introduce", .args = &.{} });
    var redeemed = CapturedRef{};
    try recipient.vowOn(introduce_vow, .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];

    // Remove the alias after the deposit and before the recipient's own
    // exporter session exists. A second removal of the same name is a loud
    // miss, and the projection query observes the removal too.
    try exporter.unpublish("widget");
    try std.testing.expectError(error.UnknownPublication, exporter.unpublish("widget"));
    try std.testing.expectEqual(@as(?u64, null), try exporter.publishedPosition(g_to_e.b, "widget"));

    // Outcome 1a: a fresh fetch of the removed alias breaks on the Port that
    // fetched it before — discovery is registry-only, with no session copy.
    var stale_fetch = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &stale_fetch, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expect(stale_fetch.broken);

    // Outcome 2: the capability issued before removal remains callable and
    // still reads the mutated state.
    var issued = CapturedString{};
    try gifter.vowOn(try gifter.send(g_to_e.a, widget_ref, .{ .verb = "tag", .args = &.{} }), .{ .ctx = &issued, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expectEqualStrings("mutated-original", issued.buf[0..issued.len]);

    // Outcome 3: the deposited gift still redeems the exact actor over the
    // recipient's own exporter session, opened after the removal.
    const e_accepts_r = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7021", &.{});
    const redeem_view = recipient.pendingDial(parked.ticket, 0) orelse return error.MissingPendingDial;
    const r_to_e = try recipient.openDialedLocator(.{
        .transport = redeem_view.locator.transport,
        .designator = redeem_view.locator.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const redeem_pair = Pair{ .ah = &recipient, .a = r_to_e, .bh = &exporter, .b = e_accepts_r };
    const all_pairs = [_]Pair{ g_to_e, r_to_g, redeem_pair };
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expect(r_to_e.sessionOpen());
    _ = try recipient.exporterDialed(parked.ticket, 0, r_to_e);
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    const token_ref = try redeemed.require();
    var exact = CapturedString{};
    try recipient.vowOn(try recipient.send(r_to_g.a, token_ref, .{ .verb = "tag", .args = &.{} }), .{ .ctx = &exact, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("mutated-original", exact.buf[0..exact.len]);

    // Outcome 1b: the removed alias also misses on the fresh Port the redeem
    // opened, so no session ever resolves it again.
    var fresh_fetch = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_e, "widget"), .{ .ctx = &fresh_fetch, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expect(fresh_fetch.broken);

    // Alias-only: the actor survives the unpublish through its remaining
    // roots (the two exporter Ports' export bindings; the consumed gift's
    // root transferred to the withdraw projection).
    try std.testing.expect(!widget_freed);

    // A never-fetched alias has only its alias root: unpublish alone reclaims
    // it (ADR-0101), observed at the next Vat turn boundary.
    var unfetched_freed = false;
    var unfetched_row = TaggedRow{ .tag = "unfetched", .freed = &unfetched_freed };
    _ = try exporter.publishGiftable("unfetched", Tagged, .{ .row = &unfetched_row });
    try exporter.unpublish("unfetched");
    var boundary_freed = false;
    var boundary_row = TaggedRow{ .tag = "boundary", .freed = &boundary_freed };
    const boundary = try exporter.vat.spawn(Tagged, .{ .row = &boundary_row });
    _ = try exporter.vat.near(boundary, .{ .verb = "tag" });
    try std.testing.expect(unfetched_freed);

    // Closing the sessions that project the widget releases the last roots
    // (each session releases exactly its own retains), and the boundary turn
    // reclaims the actor before Host teardown.
    try exporter.releaseSession(g_to_e.b);
    try exporter.releaseSession(e_accepts_r);
    _ = try exporter.vat.near(boundary, .{ .verb = "tag" });
    try std.testing.expect(widget_freed);
}

/// Spawns one unnamed stateful actor per `make` and replies with it: how a
/// test obtains a capability to an actor no alias ever named (ADR-0096
/// evidence item 2).
const UnnamedMaker = struct {
    row: *TaggedRow,
    pub fn handle(self: *UnnamedMaker, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "make")) return error.NoSuchMethod;
        const cap = try driver.spawnAt(turn, Tagged, .{ .row = self.row });
        return cap.arg();
    }
};

test "core host: an unnamed local target deposits and withdraws as the exact mutated actor" {
    // ADR-0096 evidence item 2: no alias anywhere near the gifted object. The
    // exporter's maker spawns it unnamed inside a turn; the gifter reaches it
    // through an ordinary call reply, lifts and re-lowers it through its own
    // Host to make it routable, mutates it, and introduces it. Withdrawal
    // projects the exact actor.
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, @as([32]u8, @splat(0x2e)), Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, @as([32]u8, @splat(0x26)), Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, @as([32]u8, @splat(0x2c)), Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    var widget_freed = false;
    var widget_row = TaggedRow{ .tag = "original", .freed = &widget_freed };
    _ = try exporter.publishGiftable("maker", UnnamedMaker, .{ .row = &widget_row });

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7031", &dials);
    var maker = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "maker"), .{ .ctx = &maker, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);

    // The unnamed widget arrives in an ordinary call reply, and the gifter
    // mutates it over that same session.
    var made = CapturedRef{};
    try gifter.vowOn(try gifter.send(g_to_e.a, try maker.require(), .{ .verb = "make", .args = &.{} }), .{ .ctx = &made, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const made_ref = try made.require();
    var mutated = CapturedString{};
    try gifter.vowOn(try gifter.send(g_to_e.a, made_ref, .{ .verb = "mutate", .args = &.{} }), .{ .ctx = &mutated, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    try std.testing.expectEqualStrings("mutated-original", mutated.buf[0..mutated.len]);

    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7032", &dials);

    // Lifting the bare reply reference and lowering it onto the
    // recipient-facing session is what makes it routable for re-gifting —
    // the same lift/lower seam the owning facade fuses into its argument
    // walk. The result is a Node token whose home is the exporter session.
    const lifted = try gifter.liftCapability(g_to_e.a, made_ref);
    const widget_ref = try gifter.lowerCapability(r_to_g.b, lifted);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = widget_ref });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    var redeemed = CapturedRef{};
    try recipient.vowOn(try recipient.send(r_to_g.a, try introducer.require(), .{ .verb = "introduce", .args = &.{} }), .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];

    const e_accepts_r = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7031", &.{});
    const redeem_view = recipient.pendingDial(parked.ticket, 0) orelse return error.MissingPendingDial;
    const r_to_e = try recipient.openDialedLocator(.{
        .transport = redeem_view.locator.transport,
        .designator = redeem_view.locator.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const redeem_pair = Pair{ .ah = &recipient, .a = r_to_e, .bh = &exporter, .b = e_accepts_r };
    const all_pairs = [_]Pair{ g_to_e, r_to_g, redeem_pair };
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    _ = try recipient.exporterDialed(parked.ticket, 0, r_to_e);
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);

    // The withdrawn capability is the exact unnamed actor, mutated state and
    // all. No alias existed for any lookup to consult.
    const token_ref = try redeemed.require();
    var exact = CapturedString{};
    try recipient.vowOn(try recipient.send(r_to_g.a, token_ref, .{ .verb = "tag", .args = &.{} }), .{ .ctx = &exact, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("mutated-original", exact.buf[0..exact.len]);
}

/// A persistent becomer: `bump` installs the next state through `become`, so
/// two Ports observing one history is the discriminating cross-Port claim
/// (ADR-0096 evidence item 5's `become` half).
const Becomer = struct {
    pub const snapshot_persistent = true;
    n: i64,

    pub fn handle(self: *const Becomer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (std.mem.eql(u8, msg.verb, "get")) return .{ .integer = self.n };
        if (std.mem.eql(u8, msg.verb, "bump")) {
            try turn.become(Becomer, .{ .n = self.n + 1 });
            return .{ .integer = self.n + 1 };
        }
        return error.NoSuchMethod;
    }
};

test "core host: one actor's become history is observed across two Ports" {
    const allocator = std.testing.allocator;
    var server = test_host.init(allocator, @as([32]u8, @splat(0x3a)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var alice = test_host.init(allocator, @as([32]u8, @splat(0x3b)), Host.Options.withFrameCap(frame_cap));
    defer alice.deinit();
    var bob = test_host.init(allocator, @as([32]u8, @splat(0x3c)), Host.Options.withFrameCap(frame_cap));
    defer bob.deinit();
    const hosts = [_]*Host{ &server, &alice, &bob };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    _ = try server.publishGiftable("counter", Becomer, .{ .n = 0 });
    const a = try openPair(allocator, &alice, &server, "127.0.0.1:7041", &dials);
    const b = try openPair(allocator, &bob, &server, "127.0.0.1:7042", &dials);
    var a_cap = CapturedRef{};
    try alice.vowOn(try alice.fetch(a.a, "counter"), .{ .ctx = &a_cap, .func = CapturedRef.record });
    var b_cap = CapturedRef{};
    try bob.vowOn(try bob.fetch(b.a, "counter"), .{ .ctx = &b_cap, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);

    const CapturedInt = struct {
        value: ?i64 = null,
        fn record(ctx: ?*anyopaque, resolution: actors.Resolution) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (resolution == .fulfilled and resolution.fulfilled == .integer)
                self.value = resolution.fulfilled.integer;
        }
    };

    // Alice's bump becomes n=1; Bob reads the installed history, not a copy.
    var bumped = CapturedInt{};
    try alice.vowOn(try alice.send(a.a, try a_cap.require(), .{ .verb = "bump", .args = &.{} }), .{ .ctx = &bumped, .func = CapturedInt.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    try std.testing.expectEqual(@as(?i64, 1), bumped.value);
    var bob_read = CapturedInt{};
    try bob.vowOn(try bob.send(b.a, try b_cap.require(), .{ .verb = "get", .args = &.{} }), .{ .ctx = &bob_read, .func = CapturedInt.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    try std.testing.expectEqual(@as(?i64, 1), bob_read.value);

    // And the other direction: Bob's bump lands in the history Alice reads.
    var bob_bump = CapturedInt{};
    try bob.vowOn(try bob.send(b.a, try b_cap.require(), .{ .verb = "bump", .args = &.{} }), .{ .ctx = &bob_bump, .func = CapturedInt.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    try std.testing.expectEqual(@as(?i64, 2), bob_bump.value);
    var alice_read = CapturedInt{};
    try alice.vowOn(try alice.send(a.a, try a_cap.require(), .{ .verb = "get", .args = &.{} }), .{ .ctx = &alice_read, .func = CapturedInt.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    try std.testing.expectEqual(@as(?i64, 2), alice_read.value);
}

test "core host: a target reached directly and through handoff lifts to one Host identity" {
    // ADR-0096 evidence item 7, the positive remote half of target
    // pass-invariant equality: both paths explicitly use the same live
    // exporter session, so the canonical import row makes the two arrivals
    // one opaque identity.
    const allocator = std.testing.allocator;
    var exporter = test_host.init(allocator, @as([32]u8, @splat(0x4e)), Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var gifter = test_host.init(allocator, @as([32]u8, @splat(0x46)), Host.Options.withFrameCap(frame_cap));
    defer gifter.deinit();
    var recipient = test_host.init(allocator, @as([32]u8, @splat(0x4c)), Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();
    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    var widget_freed = false;
    var widget_row = TaggedRow{ .tag = "original", .freed = &widget_freed };
    _ = try exporter.publishGiftable("widget", Tagged, .{ .row = &widget_row });

    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7051", &dials);
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);

    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7052", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = try widget.require() });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    var redeemed = CapturedRef{};
    try recipient.vowOn(try recipient.send(r_to_g.a, try introducer.require(), .{ .verb = "introduce", .args = &.{} }), .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];

    const e_accepts_r = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7051", &.{});
    const redeem_view = recipient.pendingDial(parked.ticket, 0) orelse return error.MissingPendingDial;
    const r_to_e = try recipient.openDialedLocator(.{
        .transport = redeem_view.locator.transport,
        .designator = redeem_view.locator.designator,
        .hints = model.Hints.emptyFalse(),
    });
    const redeem_pair = Pair{ .ah = &recipient, .a = r_to_e, .bh = &exporter, .b = e_accepts_r };
    const all_pairs = [_]Pair{ g_to_e, r_to_g, redeem_pair };
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    _ = try recipient.exporterDialed(parked.ticket, 0, r_to_e);
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    const token_ref = try redeemed.require();

    // The same target, reached the other way: an ordinary fetch over the very
    // session the redeem opened.
    var direct = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_e, "widget"), .{ .ctx = &direct, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);

    // Both arrivals lift to one canonical opaque identity and compare Equal.
    const via_handoff = try recipient.liftCapability(r_to_g.a, token_ref);
    const via_fetch = try recipient.liftCapability(r_to_e, try direct.require());
    try std.testing.expect(via_handoff.eql(via_fetch));
}

test "core host: restore under two live sessions breaks only the missing target's answers" {
    // ADR-0096 evidence item 10. The Vat state rewinds; sessions, positions,
    // and authority do not. A target created after the snapshot vanishes on
    // restore: an answered delivery to its export breaks with the typed
    // missing-actor reason, a fresh answered delivery does the same rather
    // than retargeting, and both sessions keep serving.
    const allocator = std.testing.allocator;
    var server = test_host.init(allocator, @as([32]u8, @splat(0x5a)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var alice = test_host.init(allocator, @as([32]u8, @splat(0x5b)), Host.Options.withFrameCap(frame_cap));
    defer alice.deinit();
    var bob = test_host.init(allocator, @as([32]u8, @splat(0x5c)), Host.Options.withFrameCap(frame_cap));
    defer bob.deinit();
    const hosts = [_]*Host{ &server, &alice, &bob };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    var stable_freed = false;
    var stable_row = TaggedRow{ .tag = "stable", .freed = &stable_freed };
    _ = try server.publishGiftable("stable", Tagged, .{ .row = &stable_row });

    const a = try openPair(allocator, &alice, &server, "127.0.0.1:7043", &dials);
    const b = try openPair(allocator, &bob, &server, "127.0.0.1:7044", &dials);
    var stable_cap = CapturedRef{};
    try alice.vowOn(try alice.fetch(a.a, "stable"), .{ .ctx = &stable_cap, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);

    var snap = try server.vat.snapshot();
    defer snap.deinit();

    // Spawned after the snapshot and projected on Bob's Port.
    var late_freed = false;
    var late_row = TaggedRow{ .tag = "late", .freed = &late_freed };
    _ = try server.publishGiftable("late", Tagged, .{ .row = &late_row });
    var late_cap = CapturedRef{};
    try bob.vowOn(try bob.fetch(b.a, "late"), .{ .ctx = &late_cap, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    const late_ref = try late_cap.require();

    try server.vat.restore(&snap);

    // An answered delivery to the vanished target breaks its answer with the
    // typed reason; the session stays open.
    var broke = CapturedRef{};
    try bob.vowOn(try bob.send(b.a, late_ref, .{ .verb = "tag", .args = &.{} }), .{ .ctx = &broke, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    try std.testing.expect(broke.broken);
    try std.testing.expect(std.mem.indexOf(u8, broke.reason_buf[0..broke.reason_len], "NoSuchActor") != null);
    try std.testing.expect(b.a.sessionOpen() and b.b.sessionOpen());

    // The position never retargets: a second delivery breaks the same way.
    var still_broke = CapturedRef{};
    try bob.vowOn(try bob.send(b.a, late_ref, .{ .verb = "tag", .args = &.{} }), .{ .ctx = &still_broke, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    try std.testing.expect(still_broke.broken);

    // Both sessions keep serving: the surviving target answers on Alice's.
    var alive = CapturedString{};
    try alice.vowOn(try alice.send(a.a, try stable_cap.require(), .{ .verb = "tag", .args = &.{} }), .{ .ctx = &alive, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &.{ a, b }, &dials);
    try std.testing.expectEqualStrings("stable", alive.buf[0..alive.len]);
}
