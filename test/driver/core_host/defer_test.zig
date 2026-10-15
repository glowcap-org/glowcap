//! Deferral and the wire-shaped callback (ADR-0102): a foreign-session
//! reply breaks one vow, listen vows settle once and break with their
//! session, a behavior defers onto a resolver vow and re-enters top-level,
//! and the action-queue ceiling covers everything at once.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");
const promise_capture = @import("../../support/capture.zig");

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
const nextRouteOptions = harness.nextRouteOptions;

test "wire-shaped callback: a foreign-session reply breaks one vow, not the session" {
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

    // This stays below the owning Host-value boundary: the raw
    // actor replies with a position from another session. With no Host identity
    // carrying its home, the gifter intercept declines it.
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
    // foreign raw reply from becoming an `InvalidReference` that tears the
    // whole session down: the next call on that session still works.
    try std.testing.expect(r_to_g.a.sessionOpen());
    var poked = CapturedString{};
    const poke_vow = try gifter.send(g_to_e.a, raw, .{ .verb = "poke", .args = &.{} });
    try gifter.vowOn(poke_vow, .{ .ctx = &poked, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &hosts, &.{ g_to_e, r_to_g }, &dials);
    try std.testing.expectEqualStrings("poked over fed bytes", poked.buf[0..poked.len]);
}

test "listen: a host vow settles on the partner's notification, and is spent once" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x0b)), Host.Options.withFrameCap(frame_cap));
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
    // naming the same object, proof the round trip ran, not that a promise
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
    var client = test_host.init(allocator, @as([32]u8, @splat(0x0a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x0b)), Host.Options.withFrameCap(frame_cap));
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

/// A behavior that defers its answer onto a resolver vow (ADR-0102) and
/// parks the resolver id for the test body, the stand-in for a worker that
/// completes off-turn.
const Deferring = struct {
    host: *Host,
    session: *HostSession,
    out_resolver: *u64,

    pub fn handle(self: *Deferring, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "work")) return error.NoSuchMethod;
        self.out_resolver.* = try self.host.deferTurn(self.session, turn);
        return .{ .void = {} };
    }
};

test "core host: a behavior defers onto a resolver vow and the settle re-enters top-level (ADR-0102)" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x2a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x2b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |d| allocator.free(d.designator);
        dials.deinit(allocator);
    }
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7821", &dials);

    var minted_resolver: u64 = 0;
    _ = try pair.b.served.publish(&pair.b.host.vat, "worker", Deferring, .{
        .host = &server,
        .session = pair.b,
        .out_resolver = &minted_resolver,
    });

    var worker = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "worker"), .{ .ctx = &worker, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const worker_ref = try worker.require();

    var reply = CapturedString{};
    try client.vowOn(
        try client.send(pair.a, worker_ref, .{ .verb = "work", .args = &.{} }),
        .{ .ctx = &reply, .func = CapturedString.record },
    );
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    // The behavior returned and every wire quiesced, yet the answer is still
    // open: the deferral holds it for the resolver.
    try std.testing.expect(minted_resolver != 0);
    try std.testing.expect(reply.len == 0 and !reply.broken);
    server.beginClose(.{ .finish = .unbounded }, 0);
    try std.testing.expectEqual(Host.LifecyclePhase.finishing, server.lifecyclePhase());

    // Direct Zig callers obey the same plain-data boundary as the C binding
    // and worker mailbox. Rejection happens before settlement, so the one-shot
    // resolver remains usable by the eventual plain result.
    const foreign_ref = model.Argument{ .reference = .{ .far = model.FarRef.object(1) } };
    try std.testing.expectError(error.ForeignArgument, server.resolverFulfill(minted_resolver, foreign_ref));
    const nested = [_]model.Argument{.{ .list = &.{foreign_ref} }};
    try std.testing.expectError(
        error.ForeignArgument,
        server.resolverFulfill(minted_resolver, .{ .tagged = .{ .tag = "nested", .value = &nested } }),
    );
    var handoff = model.Handoff{ .give = .{
        .recipient_key = "",
        .exporter = .{ .transport = "tcp", .designator = "127.0.0.1:1" },
        .gifter_exporter_session = "",
        .gifter_side = "",
        .gift_id = "",
        .signature = "",
    } };
    try std.testing.expectError(
        error.ForeignArgument,
        server.resolverFulfill(minted_resolver, .{ .handoff = &handoff }),
    );

    // The already-admitted worker completes during finish. Its answer flushes
    // to the partner before the Host starts terminal session close.
    try server.resolverFulfill(minted_resolver, .{ .string = "computed" });
    try std.testing.expectEqual(Host.LifecyclePhase.finishing, server.lifecyclePhase());
    const answer_flush = (try server.nextAction()) orelse return error.MissingFlush;
    try std.testing.expect(answer_flush == .flush);
    _ = try shuttleAll(&.{pair});
    try std.testing.expectEqualStrings("computed", reply.text());
    try retireClosingSession(&server, pair.b);

    // One attempt: the resolver and its hidden vow row are consumed.
    try std.testing.expectError(actors.Error.AlreadySettled, server.resolverBreak(minted_resolver, "late"));
    // An id never minted is a different refusal from a consumed authority.
    for ([_]u64{ 0, server.next_resolver, std.math.maxInt(u64) }) |id| {
        try std.testing.expectError(error.NoSuchResolver, server.resolverBreak(id, "unminted"));
        try std.testing.expectError(error.NoSuchResolver, server.resolverFulfill(id, .{ .void = {} }));
    }
}

test "core host: next Syrup traces an unresolved projected tell before settlement" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x5c)), nextRouteOptions());
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x5d)), nextRouteOptions());
    defer server.deinit();
    var trace = TraceLog{};
    try client.setTrace(.{ .ctx = &trace, .emit = TraceLog.emit });
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7825", &dials);

    var resolver_id: u64 = 0;
    _ = try pair.b.served.publish(&server.vat, "worker", Deferring, .{
        .host = &server,
        .session = pair.b,
        .out_resolver = &resolver_id,
    });
    var worker = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "worker"), .{ .ctx = &worker, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    const source = try client.send(pair.a, try worker.require(), .{ .verb = "work", .args = &.{} });
    const untagged = try client.vowUntag(source, "task");
    const projected = try client.vowIndex(untagged, 1);
    // The downstream projection owns its dependency. Releasing the public
    // intermediate handle must not sever an already-issued chain.
    try client.vowRelease(untagged);
    var label = CapturedString{};
    try client.vowOn(projected, .{ .ctx = &label, .func = CapturedString.record });
    try client.vowTellValues(projected, "pipeline-sentinel", &.{}, allocator);
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    try std.testing.expect(resolver_id != 0);
    try std.testing.expect(label.len == 0 and !label.broken);
    try std.testing.expect(trace.contains("msg out pipeline-sentinel"));
    const row = [_]model.Argument{
        .{ .string = "assigned" },
        .{ .string = "alice" },
        .{ .integer = 7 },
    };
    const tagged_values = [_]model.Argument{.{ .list = &row }};
    try server.resolverFulfill(resolver_id, .{
        .tagged = .{ .tag = "task", .value = &tagged_values },
    });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    try std.testing.expectEqualStrings("alice", label.text());
    try client.releaseSession(pair.a);
    try server.releaseSession(pair.b);
}

test "core session release cancels a deferred answer before freeing its Port" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x2c)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x2d)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7824", &dials);

    var resolver_id: u64 = 0;
    _ = try pair.b.served.publish(&server.vat, "worker", Deferring, .{
        .host = &server,
        .session = pair.b,
        .out_resolver = &resolver_id,
    });
    var worker = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "worker"), .{ .ctx = &worker, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    _ = try client.send(pair.a, try worker.require(), .{ .verb = "work", .args = &.{} });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    try std.testing.expect(resolver_id != 0);
    try std.testing.expectEqual(@as(usize, 1), server.pending_operations);
    try std.testing.expectEqual(@as(usize, 1), server.resolver_index.count());
    try server.releaseSession(pair.b);

    try std.testing.expectEqual(@as(usize, 0), server.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), server.resolver_index.count());
    try std.testing.expectEqual(@as(usize, 0), server.vows.count());
    try std.testing.expectError(actors.Error.AlreadySettled, server.resolverBreak(resolver_id, "late"));
    try client.releaseSession(pair.a);
}

test "core host: local and foreign deferrals publish no Host or Vat authority" {
    const Refusing = struct {
        host: *Host,
        session: *HostSession,
        expected: anyerror,
        refused: *bool,

        pub fn handle(self: *@This(), turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
            _ = msg;
            _ = self.host.deferTurn(self.session, turn) catch |err| {
                if (err != self.expected) return err;
                self.refused.* = true;
                return .{ .void = {} };
            };
            return error.UnexpectedDeferral;
        }
    };

    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x42)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x43)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7822", &dials);

    const next_vow = server.next_vow;
    const next_resolver = server.next_resolver;
    var local_refused = false;
    const local = try server.vat.spawn(Refusing, .{
        .host = &server,
        .session = pair.b,
        .expected = actors.Error.NotLocal,
        .refused = &local_refused,
    });
    _ = try server.vat.near(local, .{ .verb = "local", .args = &.{} });
    try std.testing.expect(local_refused);
    try std.testing.expectEqual(next_vow, server.next_vow);
    try std.testing.expectEqual(next_resolver, server.next_resolver);
    try std.testing.expectEqual(@as(usize, 0), server.vows.count());
    try std.testing.expectEqual(@as(usize, 0), server.resolver_index.count());

    var foreign_refused = false;
    const foreign = try server.vat.spawn(Refusing, .{
        .host = &client,
        .session = pair.b,
        .expected = error.ForeignTurn,
        .refused = &foreign_refused,
    });
    _ = try server.vat.near(foreign, .{ .verb = "foreign", .args = &.{} });
    try std.testing.expect(foreign_refused);
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
    try std.testing.expectEqual(@as(usize, 0), client.resolver_index.count());
}

test "core host: a served tell cannot mint resolver authority" {
    const RefusingTell = struct {
        host: *Host,
        session: *HostSession,
        refused: *bool,

        pub fn handle(self: *@This(), turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
            _ = msg;
            _ = self.host.deferTurn(self.session, turn) catch |err| {
                if (err != error.NoAnswer) return err;
                self.refused.* = true;
                return .{ .void = {} };
            };
            return error.UnexpectedDeferral;
        }
    };

    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x44)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x45)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7823", &dials);

    var refused = false;
    _ = try pair.b.served.publish(&server.vat, "tell-worker", RefusingTell, .{
        .host = &server,
        .session = pair.b,
        .refused = &refused,
    });
    var worker = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "tell-worker"), .{ .ctx = &worker, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    const next_vow = server.next_vow;
    const next_resolver = server.next_resolver;
    try client.tell(pair.a, try worker.require(), .{ .verb = "tell", .args = &.{} });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);

    try std.testing.expect(refused);
    try std.testing.expectEqual(next_vow, server.next_vow);
    try std.testing.expectEqual(next_resolver, server.next_resolver);
    try std.testing.expectEqual(@as(usize, 0), server.vows.count());
    try std.testing.expectEqual(@as(usize, 0), server.resolver_index.count());
}

test "core host: the action-queue ceiling covers parked enlivens, a fresh session, and every vow with no drain between" {
    // The reservation ceiling has one owner (`Host.reserveActions`), and this
    // is what it is for: pile up every class of already-promised notification
    // at once, two parked select-or-dial enlivens, a session minted after
    // them, and live vows on top, with no action drain in between to relieve
    // the queue. Every settle must still land, because each was reserved
    // before its promise existed.
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x5a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x5b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |d| allocator.free(d.designator);
        dials.deinit(allocator);
    }

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7841", &dials);
    _ = try pair.b.served.publish(&pair.b.host.vat, "widget", Widget, .{});

    // Two enlivens for peers this host has never dialed: both park, both
    // pre-mint a vow id, and both reserve their own completion slot.
    const parked_one = try client.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7842", "widget"));
    const parked_two = try client.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7843", "widget"));
    try std.testing.expect(parked_one != parked_two);

    // A live vow on the open session, and a session minted while both
    // enlivens are still parked, the mint reserves the two notifications its
    // own session owes without disturbing what the parked pair already hold.
    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "widget"), .{ .ctx = &fetched, .func = CapturedRef.record });
    var third = test_host.init(allocator, @as([32]u8, @splat(0x5c)), Host.Options.withFrameCap(frame_cap));
    defer third.deinit();
    const spare = try publishAndOpenAccepted(&third, "tcp", "127.0.0.1:7844", &.{});
    const spare_dialed = try client.openDialedLocator(tcpLocator("127.0.0.1:7844"));
    const spare_pair = Pair{ .ah = &client, .a = spare_dialed, .bh = &third, .b = spare };

    // Only now drain. Both dials surface, and answering them settles both
    // parked vows through the queue that was reserved for them all along.
    try pumpToQuiescence(allocator, &.{ &client, &server, &third }, &.{ pair, spare_pair }, &dials);
    _ = try fetched.require();
    try std.testing.expectEqual(@as(usize, 2), dials.items.len);

    for (dials.items) |d| allocator.free(d.designator);
    const tickets = [_]glowcap.ocapn.engine.Node.PendingId{ dials.items[0].ticket, dials.items[1].ticket };
    dials.clearRetainingCapacity();
    // Fail both dials: the break is the same queued completion a success
    // would take, and it needs the same reserved slot.
    for (tickets) |ticket| try client.dialFailed(ticket, 0, "unreachable in this scenario");

    var settled_ids: [2]bool = .{ false, false };
    while (try client.nextAction()) |action| {
        switch (action) {
            .failed => |f| {
                if (f.vow_id == parked_one) settled_ids[0] = true;
                if (f.vow_id == parked_two) settled_ids[1] = true;
            },
            else => {},
        }
    }
    try std.testing.expect(settled_ids[0] and settled_ids[1]);
}

// ── The live trace tap (driver_core.trace) ───────────────────────────────────
// One sink per host hears the open (with the real codec and the partner's
// name), the message verbs both directions, and the close, with no sink
// installed costing every emit site one null check. The bindings' enable_trace
// veneers stand on this seam, so this scenario is the family's root proof.

test "owning-thread resolver values project capabilities for wire and local callers" {
    for ([_]bool{ false, true }) |local| try resolverCapability(local);
}

fn resolverCapability(local: bool) !void {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x91)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x92)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var exporter = test_host.init(allocator, @as([32]u8, @splat(0x93)), Host.Options.withFrameCap(frame_cap));
    defer exporter.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer {
        for (dials.items) |dial| allocator.free(dial.designator);
        dials.deinit(allocator);
    }
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7861", &dials);
    const other = try openPair(allocator, &server, &exporter, "127.0.0.1:7862", &dials);
    const direct = try openPair(allocator, &client, &exporter, "127.0.0.1:7862", &dials);
    const hosts = [_]*Host{ &client, &server, &exporter };
    const pairs = [_]Pair{ pair, other, direct };
    _ = try other.b.served.publish(&exporter.vat, "widget", Widget, .{});
    var imported = CapturedRef{};
    try server.vowOn(try server.fetch(other.a, "widget"), .{ .ctx = &imported, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &pairs, &dials);
    const foreign = try server.liftCapability(other.a, try imported.require());
    defer server.releaseCapabilityTerminal(foreign, null);
    var resolver: u64 = 0;
    const hosted = try pair.b.served.publish(&server.vat, "worker", Deferring, .{ .host = &server, .session = pair.b, .out_resolver = &resolver });
    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "worker"), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &hosts, &pairs, &dials);
    const caller = if (local) &server else &client;
    const session = if (local) pair.b else pair.a;
    const target = if (local) hosted.nearRef() else try fetched.require();
    const held_target = try caller.liftCapability(session, target);
    defer caller.releaseCapabilityTerminal(held_target, null);
    const answer = try caller.callCapability(allocator, session, held_target, "work", &.{}, 4096);
    defer answer.deinit();
    try pumpToQuiescence(allocator, &hosts, &pairs, &dials);
    try std.testing.expect(resolver != 0);
    const actor = try server.vat.spawn(Widget, .{});
    const capability = try server.liftLocalActor(actor);
    const exports = pair.b.served.port.exports.count();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const invalid = server.capabilities.refFromRaw(std.math.maxInt(u64));
    const refused = driver.core.Value{ .list = &.{ .{ .capability = capability }, .{ .capability = invalid } } };
    try std.testing.expectError(error.UnknownCapability, server.resolverFulfillValue(resolver, refused, arena.allocator()));
    try std.testing.expectEqual(exports, pair.b.served.port.exports.count());
    try std.testing.expectEqual(@as(usize, 1), server.resolver_index.count());
    const nested = driver.core.Value{ .list = &.{ .{ .capability = capability }, .{ .capability = foreign } } };
    try server.resolverFulfillValue(resolver, nested, arena.allocator());
    try std.testing.expectError(actors.Error.AlreadySettled, server.resolverFulfillValue(resolver, .void, arena.allocator()));
    try server.releaseCapability(capability, 1);
    try pumpToQuiescence(allocator, &hosts, &pairs, &dials);
    try std.testing.expect(answer.result() == .ready);
    if (local) try std.testing.expectEqual(exports, pair.b.served.port.exports.count());
    for (answer.result().ready.list) |value| {
        const poke = try caller.callCapability(allocator, session, value.capability, "poke", &.{}, 512);
        defer poke.deinit();
        try pumpToQuiescence(allocator, &hosts, &pairs, &dials);
        try std.testing.expect(poke.result() == .ready);
        try std.testing.expectEqualStrings("poked over fed bytes", poke.result().ready.string);
    }
}
