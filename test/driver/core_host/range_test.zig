//! Cross-session authority: a capability minted on one session is refused
//! on every other, adopted peers get their own export ranges, released
//! ranges return oldest-first, and an exhausted host refuses rather than
//! naming a neighbour's object.

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
const SessionOpenFailingAllocator = harness.SessionOpenFailingAllocator;
const TaggedRow = harness.TaggedRow;
const PublicationProbe = harness.PublicationProbe;

/// A capability names one object on one session. The wire says so with an
/// integer export position, and that integer means nothing outside the session
/// that minted it, so handing a partner a capability that belongs to a
/// different session is not a shorthand for anything, it is a category error.
///
/// The suite below crosses sessions, because every other test in
/// this tree drives one session at a time and therefore cannot see this class
/// at all. `sendRedeeming` is what made crossing natural: it hands an
/// application a second session beside a reply, and hosting the reply inbox on
/// the wrong one of the two is a one-word mistake.
const Pad = struct {
    pub fn handle(self: *Pad, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = self;
        _ = turn;
        _ = msg;
        return .{ .string = "pad" };
    }
};

test "cross-session: a capability minted on one session is refused as an argument on another" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x0b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var other = test_host.init(allocator, @as([32]u8, @splat(0x0c)), Host.Options.withFrameCap(frame_cap));
    defer other.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const first = try openPair(allocator, &client, &server, "127.0.0.1:7401", &dials);
    const second = try openPair(allocator, &client, &other, "127.0.0.1:7402", &dials);
    _ = try first.b.served.publish(&first.b.host.vat, "widget", Widget, .{});

    // Mint a capability on the SECOND session, then pad the FIRST session's
    // export table so the same integer position is occupied there too. The
    // padding is what turns a loud refusal into a silent substitution: without
    // a colliding row the position is absent and any existence check
    // catches it, which is why this class hides.
    const foreign = try second.a.served.spawn(&second.a.host.vat, Pad, .{});
    var pads: [8]driver.core.Exported = undefined;
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
    var client = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x0b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var other = test_host.init(allocator, @as([32]u8, @splat(0x0c)), Host.Options.withFrameCap(frame_cap));
    defer other.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const first = try openPair(allocator, &client, &server, "127.0.0.1:7411", &dials);
    const second = try openPair(allocator, &client, &other, "127.0.0.1:7412", &dials);

    // Addressing the other session's object is the same category error as
    // passing it: the position names one of this session's own objects, or
    // nothing. Either way it is not the actor being held.
    const foreign = try second.a.served.spawn(&second.a.host.vat, Pad, .{});
    var pads: [4]driver.core.Exported = undefined;
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
    var left = test_host.init(allocator, @as([32]u8, @splat(0x11)), Host.Options.withFrameCap(frame_cap));
    defer left.deinit();
    var left_partner = test_host.init(allocator, @as([32]u8, @splat(0x12)), Host.Options.withFrameCap(frame_cap));
    defer left_partner.deinit();
    var right = test_host.init(allocator, @as([32]u8, @splat(0x13)), Host.Options.withFrameCap(frame_cap));
    defer right.deinit();
    var right_partner = test_host.init(allocator, @as([32]u8, @splat(0x14)), Host.Options.withFrameCap(frame_cap));
    defer right_partner.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const l = try openPair(allocator, &left, &left_partner, "127.0.0.1:7421", &dials);
    const r = try openPair(allocator, &right, &right_partner, "127.0.0.1:7422", &dials);

    const under_left = try l.a.served.spawn(&l.a.host.vat, Pad, .{});
    var pads: [4]driver.core.Exported = undefined;
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
    // through `publishAndOpenAcceptedOver`, so an adopted session never passes through
    // the owned mint. That is the path with the most connections on it, and
    // the one an application most plausibly holds two sessions of at once, so
    // it is the path a session-numbering fix least affords to miss.
    var host = test_host.init(allocator, @as([32]u8, @splat(0x50)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var first = engine.Peer.initNegotiating(allocator);
    defer first.deinit();
    var second = engine.Peer.initNegotiating(allocator);
    defer second.deinit();

    const a = try publishAndOpenAcceptedOver(&host, &first, "tcp", "127.0.0.1:7451", &.{});
    const b = try publishAndOpenAcceptedOver(&host, &second, "tcp", "127.0.0.1:7452", &.{});

    const from_a = try a.served.spawn(&a.host.vat, Pad, .{});
    const from_b = try b.served.spawn(&b.host.vat, Pad, .{});
    try std.testing.expect(from_a.position != from_b.position);

    // And neither session holds the other's position, so the held-export
    // check refuses a capability offered to the wrong one.
    try std.testing.expect(a.served.refForExport(from_b.position) == null);
    try std.testing.expect(b.served.refForExport(from_a.position) == null);
}

test "cross-session: a released session's export range comes back for reuse" {
    const allocator = std.testing.allocator;
    // The ranges are carved out of one integer, so they are a fixed budget. A
    // host that never took a released session's range back would spend its
    // whole slot just by churning connections, and a peer who can open and
    // close them reaches that. Reuse is what makes the slot a bound
    // on how many sessions are live at once rather than on how many the host
    // may ever open.
    var host = test_host.init(allocator, @as([32]u8, @splat(0x51)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var first = engine.Peer.initNegotiating(allocator);
    defer first.deinit();
    const a = try publishAndOpenAcceptedOver(&host, &first, "tcp", "127.0.0.1:7461", &.{});
    const released_base = first.session_state.export_base;
    const counter_after_first = host.node.next_export_base;
    try host.releaseSession(a);

    var second = engine.Peer.initNegotiating(allocator);
    defer second.deinit();
    _ = try publishAndOpenAcceptedOver(&host, &second, "tcp", "127.0.0.1:7462", &.{});
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
    var host = test_host.init(allocator, @as([32]u8, @splat(0x52)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    var first = engine.Peer.initNegotiating(allocator);
    defer first.deinit();
    var second = engine.Peer.initNegotiating(allocator);
    defer second.deinit();
    const a = try publishAndOpenAcceptedOver(&host, &first, "tcp", "127.0.0.1:7463", &.{});
    const b = try publishAndOpenAcceptedOver(&host, &second, "tcp", "127.0.0.1:7464", &.{});
    const oldest = first.session_state.export_base;
    const newer = second.session_state.export_base;
    try host.releaseSession(a);
    try host.releaseSession(b);

    var third = engine.Peer.initNegotiating(allocator);
    defer third.deinit();
    var fourth = engine.Peer.initNegotiating(allocator);
    defer fourth.deinit();
    _ = try publishAndOpenAcceptedOver(&host, &third, "tcp", "127.0.0.1:7465", &.{});
    _ = try publishAndOpenAcceptedOver(&host, &fourth, "tcp", "127.0.0.1:7466", &.{});
    try std.testing.expectEqual(oldest, third.session_state.export_base);
    try std.testing.expectEqual(newer, fourth.session_state.export_base);
}

test "cross-session: a host that has spent its export slot refuses rather than naming the next host's" {
    const allocator = std.testing.allocator;
    // The counter walks one range at a time through a slot the host's identity
    // picked. Carrying past the end would hand this host the *next* host's
    // numbers, which aliases that host's sessions one for one, the very thing
    // the ranges exist to stop. Refusing the mint is the fail-closed answer;
    // reuse above is what keeps an honest host from ever arriving here.
    var host = test_host.init(allocator, @as([32]u8, @splat(0x53)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try std.testing.expect(host.node.export_base_end > host.node.next_export_base);

    host.node.next_export_base = host.node.export_base_end;
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    try std.testing.expectError(
        error.ExportRangeExhausted,
        publishAndOpenAcceptedOver(&host, &peer, "tcp", "127.0.0.1:7467", &.{}),
    );
    // Refused, not carried: the counter is still inside this node's slot.
    try std.testing.expectEqual(host.node.export_base_end, host.node.next_export_base);
}
