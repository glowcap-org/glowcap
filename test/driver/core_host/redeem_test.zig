//! Redeem through the action queue: select-or-dial enlivens ride live
//! sessions or park on staged dials, failed paths reuse their ticket,
//! sturdyref peer mismatch refuses before fetch, and feedBytes
//! publication settles a send. Withdraw and missing-gifter cases live
//! in `redeem/withdraw_test.zig`.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const crypto = glowcap.foundation.crypto;

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
const keyedDesignator = harness.keyedDesignator;
const nextRouteOptions = harness.nextRouteOptions;

test "core host: parked direct key sturdyref requires authenticated channel identity" {
    const allocator = std.testing.allocator;
    const server_seed = @as([32]u8, @splat(0x67));
    var client = test_host.init(allocator, @as([32]u8, @splat(0x66)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const server_key = crypto.SecretKey.fromSeed(server_seed).publicKey().toDesignator();
    const accepted = try publishAndOpenAccepted(&server, model.transport.iroh, &server_key, &.{});
    _ = try accepted.served.publish(&accepted.host.vat, "widget", Widget, .{});
    try client.ensureAdvertisedLocator(model.transport.iroh);

    const vow_id = try client.enlivenSelectOrDial(.{
        .peer = .{
            .transport = model.transport.iroh,
            .designator = &server_key,
            .hints = model.Hints.emptyFalse(),
        },
        .swissnum = "widget",
    });
    const action = (try client.nextAction()).?;
    try std.testing.expect(action == .dial);
    const ticket = action.dial.ticket;

    const dialed = try client.openPendingDial(ticket, 0) orelse return error.MissingPendingDial;
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());
    _ = try client.exporterDialed(ticket, 0, dialed);
    try std.testing.expect(client.pendingDial(ticket, 0) == null);

    var refused = false;
    while (try client.nextAction()) |result| switch (result) {
        .failed => |failure| if (failure.vow_id == vow_id) {
            try std.testing.expectEqualStrings("PeerIdentityUnverified", failure.message);
            refused = true;
        },
        else => {},
    };
    try std.testing.expect(refused);
}

test "core host: id pending dial does not preselect an unverified concrete session" {
    const allocator = std.testing.allocator;
    const server_seed = @as([32]u8, @splat(0x63));
    var client = test_host.init(allocator, @as([32]u8, @splat(0x62)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, server_seed, Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const server_key = crypto.SecretKey.fromSeed(server_seed).publicKey().toDesignator();
    const accepted = try publishAndOpenAccepted(&server, model.transport.iroh, &server_key, &.{});
    try client.ensureAdvertisedLocator(model.transport.iroh);
    const dialed = try client.openDialedLocator(.{
        .transport = model.transport.iroh,
        .designator = &server_key,
        .hints = model.Hints.emptyFalse(),
    });
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());

    const id_locator = try std.fmt.allocPrint(
        allocator,
        "ocapn://{s}.id?via=ocapn%3A%2F%2F{s}.iroh",
        .{ server_key[0..], server_key[0..] },
    );
    defer allocator.free(id_locator);

    const staged = try client.node.stageDial(id_locator);
    const action = (try client.nextAction()).?;
    try std.testing.expect(action == .dial);
    try std.testing.expectEqual(staged.pending, action.dial.ticket);
    try std.testing.expect(client.pendingDial(staged.pending, 0) != null);

    const routed = try client.openPendingDial(staged.pending, 0) orelse return error.MissingPendingDial;
    defer client.releaseSession(routed) catch {};
    try std.testing.expect(routed != dialed);
    try std.testing.expect(routed.served.port.peer.demandedPartnerKey().?.eql(
        crypto.PeerKey.fromDesignator(server_key[0..]).?,
    ));
}

test "core host: session-scoped id sturdyrefs validate route bundle before fetch" {
    const allocator = std.testing.allocator;
    const client_seed = @as([32]u8, @splat(0x64));
    const server_seed = @as([32]u8, @splat(0x65));
    var client = test_host.init(allocator, client_seed, nextRouteOptions());
    defer client.deinit();
    var server = test_host.init(allocator, server_seed, nextRouteOptions());
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const server_key = keyedDesignator(server_seed);
    const client_key = keyedDesignator(client_seed);
    const accepted = try publishAndOpenAccepted(&server, model.transport.iroh, &server_key, &.{});
    _ = try accepted.served.publish(&accepted.host.vat, "widget", Widget, .{});
    try client.ensureAdvertisedLocator(model.transport.iroh);
    const dialed = try client.openDialedLocator(.{
        .transport = model.transport.iroh,
        .designator = &server_key,
        .hints = model.Hints.emptyFalse(),
    });
    try client.bindVerifiedChannelKey(dialed, &server_key);
    try server.bindVerifiedChannelKey(accepted, &client_key);
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(dialed.sessionOpen());
    try std.testing.expect(dialed.served.port.peer.session_state.features.multi_location);

    try std.testing.expectError(
        driver.core.HostError.PeerIdentityMismatch,
        client.enliven(dialed, .{
            .peer = .{
                .transport = model.transport.id,
                .designator = &server_key,
                .hints = model.Hints.emptyFalse(),
            },
            .swissnum = "widget",
        }),
    );

    const route = try std.fmt.allocPrint(allocator, "ocapn://{s}.iroh", .{server_key[0..]});
    defer allocator.free(route);
    const weak = "ocapn://baseline-service.onion";
    const fallback_hints = [_]model.HintEntry{
        .{ .name = model.transport.hint_via, .value = .{ .string = route } },
        .{ .name = model.transport.hint_alt_locators, .value = .{ .string = weak } },
    };
    const fallback_vow = try client.enliven(dialed, .{
        .peer = .{
            .transport = model.transport.id,
            .designator = &server_key,
            .hints = .{ .entries = &fallback_hints },
        },
        .swissnum = "widget",
    });
    var fallback_settled = CapturedRef{};
    try client.vowOn(fallback_vow, .{ .ctx = &fallback_settled, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    _ = try fallback_settled.require();
}

test "core host: listen refuses a foreign near target before routing" {
    const allocator = std.testing.allocator;
    var caller = test_host.init(allocator, @as([32]u8, @splat(0x38)), Host.Options.withFrameCap(frame_cap));
    defer caller.deinit();
    var owner = test_host.init(allocator, @as([32]u8, @splat(0x39)), Host.Options.withFrameCap(frame_cap));
    defer owner.deinit();
    var partner = test_host.init(allocator, @as([32]u8, @splat(0x3a)), Host.Options.withFrameCap(frame_cap));
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
    var client = test_host.init(allocator, @as([32]u8, @splat(0x3b)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var host = test_host.init(allocator, @as([32]u8, @splat(0x3c)), Host.Options.withFrameCap(frame_cap));
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
    var caller = test_host.init(allocator, @as([32]u8, @splat(0x3d)), Host.Options.withFrameCap(frame_cap));
    defer caller.deinit();
    var owner = test_host.init(allocator, @as([32]u8, @splat(0x3e)), Host.Options.withFrameCap(frame_cap));
    defer owner.deinit();
    var partner = test_host.init(allocator, @as([32]u8, @splat(0x3f)), Host.Options.withFrameCap(frame_cap));
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
    var client = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x0b)), Host.Options.withFrameCap(frame_cap));
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
    var second = test_host.init(allocator, @as([32]u8, @splat(0x0c)), Host.Options.withFrameCap(frame_cap));
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
    _ = try client.exporterDialed(ticket, 0, dialed);

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

test "core host: select-or-dial does not attach new work to a finishing address session" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x74)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x75)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7821", &dials);
    try client.beginSessionClose(pair.a, .{ .finish = .unbounded }, 0);

    _ = try client.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7821", "widget"));
    try std.testing.expectEqual(@as(usize, 1), client.node.pendingDialCount());
}

test "core host: a select-or-dial enliven breaks when its staged dial fails" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(frame_cap));
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
    try client.dialFailed(ticket, 0, "connection refused");
    var broke = false;
    while (try client.nextAction()) |action| {
        switch (action) {
            .failed => |f| if (f.vow_id == parked_vow) {
                try std.testing.expect(f.peer_handle == null);
                try std.testing.expectEqual(driver.core.VowFailure.broken, f.failure);
                broke = true;
            },
            else => {},
        }
    }
    try std.testing.expect(broke);
}

test "core host: parked enlivens group by ticket and settle independently" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x69)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const first = try host.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7804", "one"));
    const first_dial = (try host.nextAction()).?;
    try std.testing.expect(first_dial == .dial);
    const first_ticket = first_dial.dial.ticket;

    const second = try host.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7804", "two"));
    try std.testing.expect(try host.nextAction() == null);

    const third = try host.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7805", "three"));
    const second_dial = (try host.nextAction()).?;
    try std.testing.expect(second_dial == .dial);
    const second_ticket = second_dial.dial.ticket;
    try std.testing.expect(first_ticket != second_ticket);

    try host.dialFailed(first_ticket, 0, "first route unavailable");
    var first_failed = false;
    var second_failed = false;
    while (try host.nextAction()) |action| switch (action) {
        .failed => |failure| {
            if (failure.vow_id == first) first_failed = true;
            if (failure.vow_id == second) second_failed = true;
            try std.testing.expect(failure.vow_id != third);
        },
        else => return error.UnexpectedAction,
    };
    try std.testing.expect(first_failed);
    try std.testing.expect(second_failed);
    try std.testing.expect(host.pendingDial(first_ticket, 0) == null);
    try std.testing.expect(host.pendingDial(second_ticket, 0) != null);

    try host.dialFailed(second_ticket, 0, "second route unavailable");
    const final = (try host.nextAction()).?;
    try std.testing.expect(final == .failed);
    try std.testing.expectEqual(third, final.failed.vow_id);
}

test "core host: a failed handoff path reuses its ticket for the next locator" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x0d)), Host.Options.withFrameCap(frame_cap));
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
    const locator = try model.uri.writePeer(allocator, .{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:7810",
        .hints = .{ .entries = &entries },
    });
    defer allocator.free(locator);
    const staged = try host.node.stageDial(locator);
    const first = (try host.nextAction()).?;
    try std.testing.expect(first == .dial);
    const ticket = first.dial.ticket;
    try std.testing.expectEqual(staged.pending, ticket);
    try std.testing.expectEqualStrings("127.0.0.1:7810", host.pendingDial(ticket, 0).?.locator.designator);

    // The Host action remains transport-blind: reporting failure is enough for
    // Node to advance the active view and queue the same ticket again.
    try host.dialFailed(ticket, 0, "primary unreachable");
    const retry = (try host.nextAction()).?;
    try std.testing.expect(retry == .dial);
    try std.testing.expectEqual(ticket, retry.dial.ticket);
    try std.testing.expectEqualStrings("127.0.0.1:7811", host.pendingDial(ticket, 1).?.locator.designator);

    try host.dialFailed(ticket, 1, "alternative unreachable");
    try std.testing.expect(host.pendingDial(ticket, 0) == null);
    try std.testing.expect(try host.nextAction() == null);
}

test "core host: ordinary sturdyrefs retry alternative locators and settle" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x6a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x6b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const accepted = try publishAndOpenAccepted(&server, model.transport.tcp, "127.0.0.1:7813", &.{});
    _ = try accepted.served.publish(&accepted.host.vat, "widget", Widget, .{});
    try client.ensureAdvertisedLocator(model.transport.tcp);

    const alternative = try model.uri.writePeer(allocator, .{
        .transport = model.transport.tcp,
        .designator = "127.0.0.1:7813",
        .hints = model.Hints.emptyFalse(),
    });
    defer allocator.free(alternative);
    const hints = [_]model.HintEntry{.{
        .name = model.transport.hint_alt_locators,
        .value = .{ .string = alternative },
    }};
    const vow_id = try client.enlivenSelectOrDial(.{
        .peer = .{
            .transport = model.transport.tcp,
            .designator = "127.0.0.1:7812",
            .hints = .{ .entries = &hints },
        },
        .swissnum = "widget",
    });
    const first = (try client.nextAction()).?;
    try std.testing.expect(first == .dial);
    const ticket = first.dial.ticket;
    try std.testing.expectEqualStrings("127.0.0.1:7812", client.pendingDial(ticket, 0).?.locator.designator);

    try client.dialFailed(ticket, 0, "primary unreachable");
    const retry = (try client.nextAction()).?;
    try std.testing.expect(retry == .dial);
    try std.testing.expectEqual(ticket, retry.dial.ticket);
    const dialed = try client.openPendingDial(ticket, 1) orelse return error.MissingPendingDial;
    const pair = Pair{ .ah = &client, .a = dialed, .bh = &server, .b = accepted };
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(try client.exporterDialed(ticket, 1, dialed));

    var settled = false;
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        const moved = try shuttleAll(&.{pair});
        var acted = false;
        for ([_]*Host{ &client, &server }) |host| {
            while (try host.nextAction()) |action| {
                acted = true;
                switch (action) {
                    .settled => |result| if (result.vow_id == vow_id) {
                        try std.testing.expect(result.value == .reference);
                        settled = true;
                    },
                    .dial => return error.UnexpectedDial,
                    else => {},
                }
            }
        }
        if (!moved and !acted) break;
    }
    try std.testing.expect(settled);
}

test "core host: sturdyref peer mismatch and accepted TCP assertion refuse before fetch" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x0b)), Host.Options.withFrameCap(frame_cap));
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
    var host = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(8));
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7010", &.{});
    try std.testing.expectError(error.FrameTooLarge, host.feedBytes(session, "9:"));
}

test "core host: publish, fetch, and a settled send over fed bytes" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x0b)), Host.Options.withFrameCap(frame_cap));
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
