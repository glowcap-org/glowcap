//! Redeem through the action queue: select-or-dial enlivens ride live
//! sessions or park on staged dials, failed paths reuse their ticket,
//! sturdyref peer mismatch refuses before fetch, and feedBytes
//! publication settles a send. Withdraw and missing-gifter cases live
//! in `redeem/withdraw_test.zig`.

const std = @import("std");
const pancake = @import("pancake");
const test_host = @import("../../support/core_host.zig");

const model = pancake.ocapn.model;
const driver = pancake.driver;

const Host = driver.core.Host;

const harness = @import("harness.zig");
const PublicationProbe = harness.PublicationProbe;
const frame_cap = harness.frame_cap;
const Widget = harness.Widget;
const Pair = harness.Pair;
const shuttleAll = harness.shuttleAll;
const tcpLocator = harness.tcpLocator;
const publishAndOpenAccepted = harness.publishAndOpenAccepted;
const tcpSturdyref = harness.tcpSturdyref;
const ParkedDial = harness.ParkedDial;
const drainActions = harness.drainActions;
const pumpToQuiescence = harness.pumpToQuiescence;
const CapturedRef = harness.CapturedRef;
const CapturedString = harness.CapturedString;
const openPair = harness.openPair;
const TraceLog = harness.TraceLog;

test "core host: listen refuses a foreign near target before routing" {
    const allocator = std.testing.allocator;
    var caller = test_host.init(allocator, [_]u8{0x38} ** 32, Host.Options.withFrameCap(frame_cap));
    defer caller.deinit();
    var owner = test_host.init(allocator, [_]u8{0x39} ** 32, Host.Options.withFrameCap(frame_cap));
    defer owner.deinit();
    var partner = test_host.init(allocator, [_]u8{0x3a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer partner.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &owner, &partner, "127.0.0.1:7095", &dials);
    try std.testing.expectError(
        driver.core.HostError.ForeignSession,
        caller.listenTo(pair.a, .{ .near = model.NearRef.object(1) }),
    );
}

test "core host: publication refuses callback reentry before Vat spawn" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x3b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, [_]u8{0x3c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &host, "127.0.0.1:7096", &dials);

    var refused = false;
    _ = try pair.b.served.publish(&host.vat, "probe", PublicationProbe, .{
        .host = &host,
        .refused = &refused,
    });
    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "probe"), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &host }, &.{pair}, &dials);
    const probe = try fetched.require();
    _ = try client.send(pair.a, probe, .{ .verb = "publish", .args = &.{} });
    try pumpToQuiescence(allocator, &.{ &client, &host }, &.{pair}, &dials);

    try std.testing.expect(refused);
    try std.testing.expectEqual(@as(?u64, null), try host.publishedPosition(pair.b, "nested"));
}

test "core host: foreign release validates before trace close" {
    const allocator = std.testing.allocator;
    var caller = test_host.init(allocator, [_]u8{0x3d} ** 32, Host.Options.withFrameCap(frame_cap));
    defer caller.deinit();
    var owner = test_host.init(allocator, [_]u8{0x3e} ** 32, Host.Options.withFrameCap(frame_cap));
    defer owner.deinit();
    var partner = test_host.init(allocator, [_]u8{0x3f} ** 32, Host.Options.withFrameCap(frame_cap));
    defer partner.deinit();
    var caller_log = TraceLog{};
    try caller.setTrace(.{ .ctx = &caller_log, .emit = TraceLog.emit });
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &owner, &partner, "127.0.0.1:7097", &dials);
    try std.testing.expectError(driver.core.HostError.ForeignSession, caller.releaseSession(pair.a));
    try std.testing.expectEqual(@as(usize, 0), caller_log.n);
    try owner.releaseSession(pair.a);
    try partner.releaseSession(pair.b);
}

test "core host: select-or-dial enlivens over a live session, and parks on a staged dial" {
    // ADR-0098 step 4 at the byte-fed tier: the same select-or-dial the native
    // HostRuntime performs, driven here by an embedder that only answers actions.
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |d| allocator.free(d.designator);
        dials.deinit(allocator);
    }

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7801", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

    // SELECT: the sturdyref names a peer this host already dialed, so the
    // enliven rides that session and no dial is ever staged.
    const selected = try client.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7801", "widget"));
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);
    var settled = CapturedRef{};
    try client.vowOn(selected, .{ .ctx = &settled, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    _ = try settled.require();
    try std.testing.expectEqual(@as(usize, 0), dials.items.len);

    // DIAL: an unreached peer parks the enliven on a staged dial, which
    // reaches the embedder as the ordinary `dial` action — one ticket space,
    // so the embedder's dial arm is unchanged.
    var second = test_host.init(allocator, [_]u8{0x0c} ** 32, Host.Options.withFrameCap(frame_cap));
    defer second.deinit();
    const parked_vow = try client.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7802", "widget"));
    try std.testing.expect(parked_vow != selected);
    // The vow is parked, not rowed: an observer is refused exactly as it is
    // for a dedup-cache hit, and the outcome arrives as an action.
    try std.testing.expectError(
        driver.core.HostError.NoSuchVow,
        client.vowOn(parked_vow, .{ .ctx = &settled, .func = CapturedRef.record }),
    );
    _ = try drainActions(allocator, &.{ &client, &server }, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    try std.testing.expectEqualStrings("127.0.0.1:7802", dials.items[0].designator);

    // The embedder opens the connection it was told to and reports it; the
    // parked enliven then runs over that fresh session.
    const accepted = try publishAndOpenAccepted(&second, "tcp", "127.0.0.1:7802", &.{});
    _ = try accepted.served.publish(&accepted.host.vat, "widget", Widget, .{});
    const dialed = try client.openDialedLocator(tcpLocator("127.0.0.1:7802"));
    const second_pair = Pair{ .ah = &client, .a = dialed, .bh = &second, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &second }, &.{second_pair}, &dials);
    const ticket = dials.items[0].ticket;
    allocator.free(dials.items[0].designator);
    _ = dials.orderedRemove(0);
    try client.exporterDialed(ticket, dialed);

    // The pre-minted vow settles through the action queue, naming the widget.
    // Drain by hand: the shared `drainActions` swallows completions, and this
    // one is the whole point.
    var saw_parked = false;
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        const moved = try shuttleAll(&.{ pair, second_pair });
        var acted = false;
        for ([_]*Host{ &client, &second }) |host| {
            while (try host.nextAction()) |action| {
                acted = true;
                switch (action) {
                    .settled => |s| if (s.vow_id == parked_vow) {
                        try std.testing.expect(s.value == .reference);
                        saw_parked = true;
                    },
                    else => {},
                }
            }
        }
        if (!moved and !acted) break;
    }
    try std.testing.expect(saw_parked);
}

test "core host: a select-or-dial enliven breaks when its staged dial fails" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |d| allocator.free(d.designator);
        dials.deinit(allocator);
    }

    const parked_vow = try client.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7803", "widget"));
    _ = try drainActions(allocator, &.{&client}, &dials);
    try std.testing.expectEqual(@as(usize, 1), dials.items.len);
    const ticket = dials.items[0].ticket;
    allocator.free(dials.items[0].designator);
    _ = dials.orderedRemove(0);

    // The embedder could not open it: the parked vow breaks rather than
    // stranding, and it breaks host-scoped — no session ever existed.
    try client.dialFailed(ticket, "connection refused");
    var broke = false;
    while (try client.nextAction()) |action| {
        switch (action) {
            .failed => |f| if (f.vow_id == parked_vow) {
                try std.testing.expect(f.peer_id == null);
                try std.testing.expectEqual(driver.core.VowFailure.broken, f.failure);
                broke = true;
            },
            else => {},
        }
    }
    try std.testing.expect(broke);
}

test "core host: a failed pending path reuses its ticket for the next locator" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x0d} ** 32, Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const alternative = try model.uri.writePeer(allocator, .{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:7811",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(alternative);
    var entries = [_]model.HintEntry{.{
        .name = model.transport.hint_alt_locators,
        .value = .{ .string = alternative },
    }};
    const sturdyref = model.SturdyRef{
        .peer = .{
            .transport = model.transport.tcp,
            .designator = "127.0.0.1:7810",
            .hints = .{ .entries = &entries },
        },
        .swissnum = "widget",
    };

    const vow_id = try host.enlivenSelectOrDial(sturdyref);
    const first = (try host.nextAction()).?;
    try std.testing.expect(first == .dial);
    const ticket = first.dial.ticket;
    try std.testing.expectEqualStrings("127.0.0.1:7810", host.pendingDial(ticket).?.designator);

    // The Host action remains transport-blind: reporting failure is enough for
    // Node to advance the active view and queue the same ticket again.
    try host.dialFailed(ticket, "primary unreachable");
    const retry = (try host.nextAction()).?;
    try std.testing.expect(retry == .dial);
    try std.testing.expectEqual(ticket, retry.dial.ticket);
    try std.testing.expectEqualStrings("127.0.0.1:7811", host.pendingDial(ticket).?.designator);

    try host.dialFailed(ticket, "alternative unreachable");
    const failed = (try host.nextAction()).?;
    try std.testing.expect(failed == .failed);
    try std.testing.expectEqual(vow_id, failed.failed.vow_id);
    try std.testing.expectEqual(driver.core.VowFailure.broken, failed.failed.failure);
    try std.testing.expectEqualStrings("alternative unreachable", failed.failed.message);
}

test "core host: sturdyref peer mismatch and accepted TCP assertion refuse before fetch" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
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

test "core host: feedBytes rejects an outer length over cap before its body" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(8));
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7010", &.{});
    try std.testing.expectError(error.FrameTooLarge, host.feedBytes(session, "9:"));
}

test "core host: publish, fetch, and a settled send over fed bytes" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, [_]u8{0x0a} ** 32, Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, [_]u8{0x0b} ** 32, Host.Options.withFrameCap(frame_cap));
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
