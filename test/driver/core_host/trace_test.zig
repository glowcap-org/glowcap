//! The live trace and the profile matrix: opens, both directions, and
//! closes are reported exactly once, a pancake pair settles the next
//! profile over capnp beside a baseline session, feature offers ride the
//! signed hello, and both ends tag one message identically.

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

// ── The live trace tap (driver_core.trace) ───────────────────────────────────
// One sink per host hears the open (with the real codec and the partner's
// name), the message verbs both directions, and the close, with no sink
// installed costing every emit site one null check. The bindings' enable_trace
// veneers stand on this seam, so this scenario is the family's root proof.

/// Records each message's verb, direction, and wire tag, so a test can ask
/// whether two hosts tagged one frame the same way.
const DigestLog = struct {
    const Row = struct { verb: [32]u8 = undefined, verb_len: usize = 0, outbound: bool = false, digest: [driver.core.trace.digest_bytes]u8 = undefined };
    rows: [32]Row = undefined,
    n: usize = 0,

    fn emit(ctx: ?*anyopaque, event: driver.core.trace.Event) void {
        const self: *DigestLog = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .message => |m| {
                if (self.n == self.rows.len) return;
                var row = Row{ .outbound = m.outbound, .digest = m.digest };
                row.verb_len = @min(m.verb.len, row.verb.len);
                @memcpy(row.verb[0..row.verb_len], m.verb[0..row.verb_len]);
                self.rows[self.n] = row;
                self.n += 1;
            },
            else => {},
        }
    }

    fn find(self: *const DigestLog, verb: []const u8, outbound: bool) ?[driver.core.trace.digest_bytes]u8 {
        for (self.rows[0..self.n]) |row| {
            if (row.outbound != outbound) continue;
            if (!std.mem.eql(u8, row.verb[0..row.verb_len], verb)) continue;
            return row.digest;
        }
        return null;
    }

    /// The first two outbound tags for `verb`, or null when fewer than two
    /// were recorded.
    fn bothOutbound(self: *const DigestLog, verb: []const u8) ?[2][driver.core.trace.digest_bytes]u8 {
        var out: [2][driver.core.trace.digest_bytes]u8 = undefined;
        var seen: usize = 0;
        for (self.rows[0..self.n]) |row| {
            if (!row.outbound) continue;
            if (!std.mem.eql(u8, row.verb[0..row.verb_len], verb)) continue;
            out[seen] = row.digest;
            seen += 1;
            if (seen == 2) return out;
        }
        return null;
    }
};

test "core host: the live trace reports open, both message directions, and close" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x5a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x5b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var client_log = TraceLog{};
    var server_log = TraceLog{};
    try client.setTrace(.{ .ctx = &client_log, .emit = TraceLog.emit });
    try server.setTrace(.{ .ctx = &server_log, .emit = TraceLog.emit });
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7009", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

    var fetched = CapturedRef{};
    const fetch_vow = try client.fetch(pair.a, "widget");
    try client.vowOn(fetch_vow, .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const widget_ref = try fetched.require();

    const vow = try client.send(pair.a, widget_ref, .{ .verb = "poke", .args = &.{} });
    var reply = CapturedString{};
    try client.vowOn(vow, .{ .ctx = &reply, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expectEqualStrings("poked over fed bytes", reply.buf[0..reply.len]);

    // The dialer's first row is its open, naming the codec the core actually
    // negotiated and the designator it dialed; the send traced outbound.
    try std.testing.expect(client_log.n > 0);
    try std.testing.expect(std.mem.startsWith(u8, client_log.row(0), "open codec=syrup"));
    try std.testing.expect(client_log.contains("designator=127.0.0.1:7009"));
    // A designator alone does not name a location: the spec requires the
    // transport beside it. Provenance says whether the channel proved it.
    try std.testing.expect(client_log.contains("transport=tcp"));
    try std.testing.expect(client_log.contains("provenance=unauthenticated"));
    try std.testing.expect(client_log.contains("msg out poke"));

    // The acceptor heard the same verb inbound, on its own open session.
    try std.testing.expect(server_log.contains("open codec=syrup"));
    try std.testing.expect(server_log.contains("msg in poke"));

    // Release pairs the close with the open, exactly once per side.
    try client.releaseSession(pair.a);
    try server.releaseSession(pair.b);
    try std.testing.expect(client_log.contains("close"));
    try std.testing.expect(server_log.contains("close"));
}

test "core host: deinit closes every traced open exactly once" {
    const allocator = std.testing.allocator;
    var peer = test_host.init(allocator, @as([32]u8, @splat(0x40)), Host.Options.withFrameCap(frame_cap));
    defer peer.deinit();
    var host = test_host.init(allocator, @as([32]u8, @splat(0x41)), Host.Options.withFrameCap(frame_cap));
    var log = TraceLog{};
    try host.setTrace(.{ .ctx = &log, .emit = TraceLog.emit });
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    _ = try openPair(allocator, &peer, &host, "127.0.0.1:7098", &dials);
    host.deinit();
    var closes: usize = 0;
    for (0..log.n) |i| {
        if (std.mem.eql(u8, log.row(i), "close")) closes += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), closes);
}

test "core host: a pancake-to-pancake pair holds the next profile over capnp" {
    // The native pancake job — `engine.negotiation.Offer.native` prefers
    // `next` and Cap'n Proto together — run at the Host tier for the first
    // time. Only `engine.pairing` (in-process, no Host) had ever exercised
    // `next`, because `Host.Options` carried no version and every socket
    // session took the v1.0 floor. The profile is a wire difference, not a
    // label: on `next` an answer settles through the mandatory listener path,
    // while V1.0 settles through a `resolve_me_desc` callback. A handshake
    // that completes here is both ends agreeing on the version they put in
    // `op:start-session` and on the grammar that framed it.
    const allocator = std.testing.allocator;
    var opts = Host.Options.withFrameCap(frame_cap);
    opts.codec = .capnp;
    opts.captp_version = .next;
    var a = test_host.init(allocator, @as([32]u8, @splat(0x4a)), opts);
    defer a.deinit();
    var b = test_host.init(allocator, @as([32]u8, @splat(0x4b)), opts);
    defer b.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &a, &b, "127.0.0.1:7010", &dials);
    try std.testing.expect(pair.a.sessionOpen());
    try std.testing.expect(pair.b.sessionOpen());
    // Both ends recorded the negotiated profile, not the floor.
    try std.testing.expectEqual(
        model.CaptpVersion.next,
        pair.a.served.port.peer.session_state.captp_version,
    );
    try std.testing.expectEqual(
        model.CodecId.capnp,
        pair.b.served.port.peer.session_state.codec,
    );
}

test "core host: one host holds a next capnp session and a baseline session at once" {
    // The shape `apps/ocapnviz/src/fixtures/three-vat-handoff-mixed.ts` draws:
    // a pancake peer talking Cap'n Proto to another pancake peer while talking
    // the v1.0 Syrup baseline to a peer that speaks only that, on the same host
    // at the same time. Nothing in the tree could do this before: a host's
    // profile was stamped onto every session it minted, so a partner that
    // disagreed was refused rather than met where it stood.
    //
    // Neither side is told anything out of band. Each hello states what its
    // sender prefers, and each session settles its own pair from the two.
    const allocator = std.testing.allocator;
    var native_opts = Host.Options.withFrameCap(frame_cap);
    native_opts.codec = .capnp;
    native_opts.captp_version = .next;

    var hub = test_host.init(allocator, @as([32]u8, @splat(0x5a)), native_opts);
    defer hub.deinit();
    var native_peer = test_host.init(allocator, @as([32]u8, @splat(0x5b)), native_opts);
    defer native_peer.deinit();
    // A peer that knows only the baseline: the profile a Goblins vat speaks.
    var baseline_peer = test_host.init(allocator, @as([32]u8, @splat(0x5c)), Host.Options.withFrameCap(frame_cap));
    defer baseline_peer.deinit();

    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const native = try openPair(allocator, &hub, &native_peer, "127.0.0.1:7011", &dials);
    const baseline = try openPair(allocator, &hub, &baseline_peer, "127.0.0.1:7012", &dials);

    try std.testing.expect(native.a.sessionOpen());
    try std.testing.expect(baseline.a.sessionOpen());

    // Two sessions on one host, each on the profile its pair reached.
    const native_state = &native.a.served.port.peer.session_state;
    try std.testing.expectEqual(model.CaptpVersion.next, native_state.captp_version);
    try std.testing.expectEqual(model.CodecId.capnp, native_state.codec);

    const baseline_state = &baseline.a.served.port.peer.session_state;
    try std.testing.expectEqual(model.CaptpVersion.v1_0, baseline_state.captp_version);
    try std.testing.expectEqual(model.CodecId.syrup, baseline_state.codec);

    // The hub asked for the same thing on both, and got what each partner
    // could follow. That difference is the point: the preference is a
    // property of this peer, the active pair a property of the two.
    try std.testing.expectEqual(model.CaptpVersion.next, baseline_state.preferred.captp_version);
    try std.testing.expectEqual(model.CodecId.capnp, baseline_state.preferred.codec);

    // And the partner that knows only the baseline recorded the same session.
    const far_state = &baseline.b.served.port.peer.session_state;
    try std.testing.expectEqual(model.CaptpVersion.v1_0, far_state.captp_version);
    try std.testing.expectEqual(model.CodecId.syrup, far_state.codec);
}

test "core host: feature offers are carried by the signed hello and intersected" {
    const allocator = std.testing.allocator;
    var limited_opts = Host.Options.withFrameCap(frame_cap);
    limited_opts.features = model.FeatureSet.minimum();
    var limited = test_host.init(allocator, @as([32]u8, @splat(0x6d)), limited_opts);
    defer limited.deinit();

    var full = test_host.init(allocator, @as([32]u8, @splat(0x6e)), Host.Options.withFrameCap(frame_cap));
    defer full.deinit();

    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &limited, &full, "127.0.0.1:7015", &dials);
    try std.testing.expectEqual(model.FeatureSet.minimum(), pair.a.served.port.peer.session_state.features);
    try std.testing.expectEqual(model.FeatureSet.minimum(), pair.b.served.port.peer.session_state.features);
}

test "core host: the live trace reports each session's settled profile, not the host's preference" {
    // What a viewer draws has to be what the two peers agreed, or it draws the
    // configuration and calls it the wire. The ordering this depends on is not
    // obvious: a session reaches `open` inside apply, while the settle runs
    // just after it, so an open fact emitted between the two would carry the
    // preference. Both sessions here are opened by one host that prefers
    // `next` over Cap'n Proto, and only one partner can follow it.
    const allocator = std.testing.allocator;
    var native_opts = Host.Options.withFrameCap(frame_cap);
    native_opts.codec = .capnp;
    native_opts.captp_version = .next;

    var hub = test_host.init(allocator, @as([32]u8, @splat(0x6a)), native_opts);
    defer hub.deinit();
    var native_peer = test_host.init(allocator, @as([32]u8, @splat(0x6b)), native_opts);
    defer native_peer.deinit();
    var baseline_peer = test_host.init(allocator, @as([32]u8, @splat(0x6c)), Host.Options.withFrameCap(frame_cap));
    defer baseline_peer.deinit();

    var hub_log = TraceLog{};
    try hub.setTrace(.{ .ctx = &hub_log, .emit = TraceLog.emit });

    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const native = try openPair(allocator, &hub, &native_peer, "127.0.0.1:7013", &dials);
    const baseline = try openPair(allocator, &hub, &baseline_peer, "127.0.0.1:7014", &dials);
    try pumpToQuiescence(allocator, &.{ &hub, &native_peer, &baseline_peer }, &.{ native, baseline }, &dials);

    // The open fact is emitted the first time a session is *observed* open,
    // which is its first traffic rather than the handshake itself, so an idle
    // session contributes no row. One fetch each is enough to observe both.
    _ = try native.b.served.publish(&native.b.host.vat, "widget", Widget, .{});
    _ = try baseline.b.served.publish(&baseline.b.host.vat, "widget", Widget, .{});
    _ = try hub.fetch(native.a, "widget");
    _ = try hub.fetch(baseline.a, "widget");
    try pumpToQuiescence(allocator, &.{ &hub, &native_peer, &baseline_peer }, &.{ native, baseline }, &dials);

    // One host, two opens, two different profiles on the wire.
    try std.testing.expect(hub_log.contains("open codec=capnp captp=next"));
    try std.testing.expect(hub_log.contains("open codec=syrup captp=v1_0"));
}

test "core host: both peers of one session report the same wire name" {
    // The name a consumer merges two producers' feeds on. A session id is
    // host-local — every host starts counting at one — so two peers tracing
    // the same conversation say nothing to each other by it. The wire name is
    // the OCapN session identifier, derived from both session public keys with
    // the pair sorted, so the dialer and the accepter compute the same digits
    // and a viewer can tell one wire watched twice from two wires.
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x71)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x72)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var third = test_host.init(allocator, @as([32]u8, @splat(0x73)), Host.Options.withFrameCap(frame_cap));
    defer third.deinit();

    var client_log = TraceLog{};
    var server_log = TraceLog{};
    var third_log = TraceLog{};
    try client.setTrace(.{ .ctx = &client_log, .emit = TraceLog.emit });
    try server.setTrace(.{ .ctx = &server_log, .emit = TraceLog.emit });
    try third.setTrace(.{ .ctx = &third_log, .emit = TraceLog.emit });

    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7031", &dials);
    const other = try openPair(allocator, &client, &third, "127.0.0.1:7032", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});
    _ = try other.b.served.publish(&other.b.host.vat, "widget", Widget, .{});
    _ = try client.fetch(pair.a, "widget");
    _ = try client.fetch(other.a, "widget");
    try pumpToQuiescence(allocator, &.{ &client, &server, &third }, &.{ pair, other }, &dials);

    // The dialer saw both sessions; each accepter saw its own. Every accepter's
    // name is one the dialer also reported, which is the whole claim: two
    // producers watching one session say the same word for it.
    try std.testing.expectEqual(@as(usize, 2), client_log.wire_n);
    try std.testing.expect(client_log.sawWire(server_log.onlyWire()));
    try std.testing.expect(client_log.sawWire(third_log.onlyWire()));
    // Two sessions are two names, or election would fold unrelated wires.
    try std.testing.expect(!std.mem.eql(u8, server_log.onlyWire(), third_log.onlyWire()));
    try std.testing.expectEqual(@as(usize, 64), server_log.onlyWire().len);
    for (server_log.onlyWire()) |ch| {
        try std.testing.expect((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'));
    }
}

test "core host: a three-vat handoff holds native between the pancake pair and baseline with the third" {
    // The cast `apps/ocapnviz/src/fixtures/three-vat-handoff-mixed.ts` draws:
    // a pancake gifter introduces a peer that speaks only the v1.0 Syrup
    // baseline — a Goblins vat's profile — to a pancake exporter. Three
    // sessions, and the profile each runs on is a property of its pair:
    // gifter-to-exporter is native because both ends can be, and both of the
    // recipient's sessions are the baseline because it cannot.
    //
    // The handoff itself has to survive that split, and this is the case
    // `codec.signed` exists for: a give is minted on one session and redeemed
    // on another that negotiated independently, so its signed envelope is
    // Syrup whatever each session settled.
    const allocator = std.testing.allocator;
    var native_opts = Host.Options.withFrameCap(frame_cap);
    native_opts.codec = .capnp;
    native_opts.captp_version = .next;

    var exporter = test_host.init(allocator, @as([32]u8, @splat(0x7e)), native_opts);
    defer exporter.deinit();
    var gifter = test_host.init(allocator, @as([32]u8, @splat(0x76)), native_opts);
    defer gifter.deinit();
    // The Goblins-shaped peer: it knows only the baseline.
    var recipient = test_host.init(allocator, @as([32]u8, @splat(0x7c)), Host.Options.withFrameCap(frame_cap));
    defer recipient.deinit();

    const hosts = [_]*Host{ &exporter, &gifter, &recipient };
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |parked| allocator.free(parked.designator);
        dials.deinit(allocator);
    }

    var row_freed = false;
    var row = TaggedRow{ .tag = "greeter", .freed = &row_freed };
    _ = try exporter.publishGiftable("widget", Tagged, .{ .row = &row });

    // Gifter to exporter: both prefer native, so the session is native.
    const g_to_e = try openPair(allocator, &gifter, &exporter, "127.0.0.1:7021", &dials);
    var widget = CapturedRef{};
    try gifter.vowOn(try gifter.fetch(g_to_e.a, "widget"), .{ .ctx = &widget, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{g_to_e}, &dials);
    const widget_ref = try widget.require();

    // Recipient to gifter: the recipient can only do the baseline.
    const r_to_g = try openPair(allocator, &recipient, &gifter, "127.0.0.1:7022", &dials);
    _ = try r_to_g.b.served.publish(&r_to_g.b.host.vat, "introducer", Introducer, .{ .widget = widget_ref });
    var introducer = CapturedRef{};
    try recipient.vowOn(try recipient.fetch(r_to_g.a, "introducer"), .{ .ctx = &introducer, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    const introducer_ref = try introducer.require();

    const introduce_vow = try recipient.send(r_to_g.a, introducer_ref, .{ .verb = "introduce", .args = &.{} });
    var redeemed = CapturedRef{};
    try recipient.vowOn(introduce_vow, .{ .ctx = &redeemed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);

    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const parked = dials.items[0];

    // The redeem dial: two pancake hosts on the wire, but the recipient still
    // cannot do native, so this session settles on the baseline too.
    const e_accepts_r = try publishAndOpenAccepted(&exporter, "tcp", "127.0.0.1:7021", &.{});
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

    // The handoff completed across the profile split.
    const token_ref = try redeemed.require();
    try std.testing.expect(token_ref == .routed);
    const reached = try recipient.send(r_to_g.a, token_ref, .{ .verb = "tag", .args = &.{} });
    var tag = CapturedString{};
    try recipient.vowOn(reached, .{ .ctx = &tag, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &all_pairs, &dials);
    try std.testing.expectEqualStrings("greeter", tag.buf[0..tag.len]);

    // Each session runs the profile its own pair could reach.
    const pancake_pair = &g_to_e.a.served.port.peer.session_state;
    try std.testing.expectEqual(model.CaptpVersion.next, pancake_pair.captp_version);
    try std.testing.expectEqual(model.CodecId.capnp, pancake_pair.codec);

    inline for (.{ r_to_g.a, r_to_e }) |with_recipient| {
        const state = &with_recipient.served.port.peer.session_state;
        try std.testing.expectEqual(model.CaptpVersion.v1_0, state.captp_version);
        try std.testing.expectEqual(model.CodecId.syrup, state.codec);
    }

    // The exporter asked for native on every session it holds and got it on
    // one of the two. That difference is the point.
    try std.testing.expectEqual(
        model.CaptpVersion.next,
        e_accepts_r.served.port.peer.session_state.preferred.captp_version,
    );
    try std.testing.expectEqual(
        model.CaptpVersion.v1_0,
        e_accepts_r.served.port.peer.session_state.captp_version,
    );
}

test "core host: both ends of a wire tag one message identically" {
    // The property the whole merge rests on. A frame crosses one wire, so the
    // sender and the receiver hold the same bytes and derive the same tag
    // with no coordination — which is what lets a consumer recognise two
    // observers' records as one message instead of drawing it twice, and why
    // the endpoint need not pick a winner and throw the other view away.
    //
    // Derived, not claimed: a producer cannot assert that some other message
    // is this one without holding its bytes.
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x8a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x8b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();

    var client_log = DigestLog{};
    var server_log = DigestLog{};
    try client.setTrace(.{ .ctx = &client_log, .emit = DigestLog.emit });
    try server.setTrace(.{ .ctx = &server_log, .emit = DigestLog.emit });

    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7030", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "widget"), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const widget = try fetched.require();
    var reply = CapturedString{};
    try client.vowOn(
        try client.send(pair.a, widget, .{ .verb = "poke", .args = &.{} }),
        .{ .ctx = &reply, .func = CapturedString.record },
    );
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    // The dialer sent `poke` outbound; the acceptor saw the same frame
    // inbound. Two records of one message, and the tags agree.
    const sent = client_log.find("poke", true) orelse return error.NoOutboundPoke;
    const heard = server_log.find("poke", false) orelse return error.NoInboundPoke;
    try std.testing.expectEqualSlices(u8, &sent, &heard);

    // And the tag must cover the frame, not something coarser that happens to
    // agree across ends. Two sends of the SAME verb carrying different
    // arguments are different messages, and a tag over the verb alone — which
    // both ends would also agree on — cannot tell them apart.
    var second = CapturedString{};
    try client.vowOn(
        try client.send(pair.a, widget, .{ .verb = "poke", .args = &.{.{ .string = "again" }} }),
        .{ .ctx = &second, .func = CapturedString.record },
    );
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const both = client_log.bothOutbound("poke") orelse return error.OnlyOnePoke;
    try std.testing.expect(!std.mem.eql(u8, &both[0], &both[1]));
}
