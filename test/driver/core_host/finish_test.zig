//! Finish waits for every kind of admitted work over fed bytes: a
//! handshake, a negotiating session's terminal release, an admitted vow, a
//! named-send chain, and a parked select-or-dial. Cancel escalates an
//! in-progress finish, drops queued application turns, and leaves a sibling
//! session open, and transport packages publish nothing before a conflict.

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

test "core host finish waits for an admitted session handshake" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x20)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try host.ensureAdvertisedLocator("tcp");
    const session = try host.openDialedLocator(tcpLocator("127.0.0.1:7086"));
    host.beginClose(.{ .finish = .unbounded }, 0);
    try std.testing.expectEqual(Host.LifecyclePhase.finishing, host.lifecyclePhase());

    // Draining the hello and its FLUSH action does not complete the admitted
    // open. The partner handshake, not an empty action queue, is the outcome.
    while (try host.nextAction()) |_| {}
    while (try session.takeOutbound()) |frame_value| {
        var frame = frame_value;
        frame.deinit();
    }
    try std.testing.expect((try host.nextAction()) == null);
    try std.testing.expectEqual(Host.LifecyclePhase.finishing, host.lifecyclePhase());

    host.beginClose(.cancel, 0);
    try retireClosingSession(&host, session);
}

test "core host finish observes a negotiating session's terminal release" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x2a)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try host.ensureAdvertisedLocator("tcp");
    const session = try host.openDialedLocator(tcpLocator("127.0.0.1:7085"));
    host.beginClose(.{ .finish = .unbounded }, 0);
    try std.testing.expectEqual(Host.LifecyclePhase.finishing, host.lifecyclePhase());

    try host.releaseSession(session);
    while (try host.nextAction()) |_| {}
    try std.testing.expectEqual(Host.LifecyclePhase.closed, host.lifecyclePhase());
}

test "core host close leaves terminal session shells for explicit release" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x2b)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    try host.ensureAdvertisedLocator("tcp");
    const session = try host.openDialedLocator(tcpLocator("127.0.0.1:7084"));
    host.beginClose(.cancel, 0);

    var saw_close = false;
    while (try host.nextAction()) |action| switch (action) {
        .flush => while (try session.takeOutbound()) |frame_value| {
            var frame = frame_value;
            frame.deinit();
        },
        .close => saw_close = true,
        else => {},
    };

    try std.testing.expect(saw_close);
    try std.testing.expectEqual(Host.LifecyclePhase.closed, host.lifecyclePhase());
    try host.checkOwnedSession(session);
    try host.releaseSession(session);
}

test "core host cancel resumes terminal work across finite scheduler quanta" {
    const allocator = std.testing.allocator;
    var first_client = test_host.init(allocator, @as([32]u8, @splat(0x2c)), Host.Options.withFrameCap(frame_cap));
    defer first_client.deinit();
    var second_client = test_host.init(allocator, @as([32]u8, @splat(0x2d)), Host.Options.withFrameCap(frame_cap));
    defer second_client.deinit();
    var host = test_host.init(allocator, @as([32]u8, @splat(0x2e)), .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .host_work_quantum = 1,
    });
    defer host.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const first = try openPair(allocator, &first_client, &host, "127.0.0.1:7082", &dials);
    const second = try openPair(allocator, &second_client, &host, "127.0.0.1:7083", &dials);

    host.beginClose(.cancel, 0);
    var close_count: usize = 0;
    while (try host.nextAction()) |action| switch (action) {
        .flush => |peer_handle| {
            const session = host.sessionForPeer(peer_handle) orelse continue;
            while (try session.takeOutbound()) |frame_value| {
                var frame = frame_value;
                frame.deinit();
            }
        },
        .close => close_count += 1,
        else => {},
    };

    try std.testing.expectEqual(@as(usize, 2), close_count);
    try std.testing.expectEqual(Host.LifecyclePhase.closed, host.lifecyclePhase());
    try host.releaseSession(first.b);
    try host.releaseSession(second.b);
}

test "core host finish waits for an admitted vow before closing its session" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x22)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x23)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7089", &dials);

    var outcome = CapturedString{};
    const vow = try client.fetch(pair.a, "missing-during-close");
    try client.vowOn(vow, .{ .ctx = &outcome, .func = CapturedString.record });
    client.beginClose(.{ .finish = .unbounded }, 0);
    try std.testing.expectEqual(Host.LifecyclePhase.finishing, client.lifecyclePhase());
    try std.testing.expectError(error.HostClosing, client.fetch(pair.a, "too-late"));

    // Consume the fetch's FLUSH notice without consuming its frame. The vow is
    // still live, so an empty action queue cannot advance finish yet. status-allow: pending state or quoted runtime label
    while (try client.nextAction()) |_| {}
    try std.testing.expectEqual(Host.LifecyclePhase.finishing, client.lifecyclePhase());

    _ = try shuttleAll(&.{pair});
    _ = try shuttleAll(&.{pair});
    try std.testing.expect(outcome.broken);
    try retireClosingSession(&client, pair.a);
}

test "core host finish waits for an admitted named-send chain" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x42)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x43)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7095", &dials);

    var pending: driver.PendingSend = undefined;
    defer pending.deinit();
    var outcome = CapturedString{};
    try client.beginSendNamed(
        pair.a,
        &pending,
        "missing-during-close",
        .{ .verb = "poke", .args = &.{} },
        .{ .ctx = &outcome, .func = CapturedString.record },
    );
    client.beginClose(.{ .finish = .unbounded }, 0);
    try std.testing.expectEqual(Host.LifecyclePhase.finishing, client.lifecyclePhase());

    while (try client.nextAction()) |_| {}
    try std.testing.expectEqual(Host.LifecyclePhase.finishing, client.lifecyclePhase());

    _ = try shuttleAll(&.{pair});
    _ = try shuttleAll(&.{pair});
    try std.testing.expect(outcome.broken);
    try retireClosingSession(&client, pair.a);
}

test "core host cancel escalates an in-progress finish" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x24)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x25)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7090", &dials);

    var broken = false;
    const vow = try client.fetch(pair.a, "never-delivered");
    try client.vowOn(vow, .{ .ctx = &broken, .func = promise_capture.captureBroken });
    while (try client.nextAction()) |_| {}
    while (try pair.a.takeOutbound()) |frame_value| {
        var frame = frame_value;
        frame.deinit();
    }

    client.beginClose(.{ .finish = .unbounded }, 0);
    client.beginClose(.{ .finish = .unbounded }, 1);
    try std.testing.expectEqual(Host.LifecyclePhase.finishing, client.lifecyclePhase());
    client.beginClose(.cancel, 1);
    try client.progressClose(1);

    try std.testing.expect(broken);
    try std.testing.expectEqual(Host.LifecyclePhase.terminating, client.lifecyclePhase());
    client.beginClose(.{ .finish = .unbounded }, 2);
    client.beginClose(.cancel, 2);
    try std.testing.expectEqual(Host.LifecyclePhase.terminating, client.lifecyclePhase());
    try retireClosingSession(&client, pair.a);
}

test "session finish waits for its admitted work and leaves a sibling open" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x2b)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var first_server = test_host.init(allocator, @as([32]u8, @splat(0x2c)), Host.Options.withFrameCap(frame_cap));
    defer first_server.deinit();
    var second_server = test_host.init(allocator, @as([32]u8, @splat(0x2d)), Host.Options.withFrameCap(frame_cap));
    defer second_server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const first = try openPair(allocator, &client, &first_server, "127.0.0.1:7091", &dials);
    const second = try openPair(allocator, &client, &second_server, "127.0.0.1:7092", &dials);

    var first_outcome = CapturedString{};
    const first_vow = try client.fetch(first.a, "missing-on-first");
    try client.vowOn(first_vow, .{ .ctx = &first_outcome, .func = CapturedString.record });
    try client.beginSessionClose(first.a, .{ .finish = .unbounded }, 0);
    try std.testing.expectEqual(HostSession.LifecyclePhase.finishing, first.a.lifecyclePhase());
    try std.testing.expectError(error.SessionClosing, client.fetch(first.a, "too-late"));

    var second_outcome = CapturedString{};
    const second_vow = try client.fetch(second.a, "missing-on-second");
    try client.vowOn(second_vow, .{ .ctx = &second_outcome, .func = CapturedString.record });

    var rounds: usize = 0;
    while (rounds < 16) : (rounds += 1) {
        if (!try shuttleAll(&.{ first, second })) break;
    }
    try std.testing.expect(first_outcome.broken);
    try std.testing.expect(second_outcome.broken);
    try std.testing.expect(first.a.isTerminating());
    try std.testing.expectEqual(HostSession.LifecyclePhase.active, second.a.lifecyclePhase());
    try retireClosedSession(&client, first.a);
    try std.testing.expectEqual(Host.LifecyclePhase.active, client.lifecyclePhase());
}

test "session cancel escalates finish without closing a sibling" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x2e)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var first_server = test_host.init(allocator, @as([32]u8, @splat(0x2f)), Host.Options.withFrameCap(frame_cap));
    defer first_server.deinit();
    var second_server = test_host.init(allocator, @as([32]u8, @splat(0x31)), Host.Options.withFrameCap(frame_cap));
    defer second_server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const first = try openPair(allocator, &client, &first_server, "127.0.0.1:7093", &dials);
    const second = try openPair(allocator, &client, &second_server, "127.0.0.1:7094", &dials);

    var broken = false;
    const vow = try client.fetch(first.a, "never-delivered");
    try client.vowOn(vow, .{ .ctx = &broken, .func = promise_capture.captureBroken });
    try client.beginSessionClose(first.a, .{ .finish = .unbounded }, 0);
    try client.beginSessionClose(first.a, .cancel, 0);
    try client.progressSessionCloses(0);

    try std.testing.expect(broken);
    try std.testing.expect(first.a.isTerminating());
    try std.testing.expectError(error.SessionCondemned, client.fetch(first.a, "too-late"));
    try std.testing.expectEqual(HostSession.LifecyclePhase.active, second.a.lifecyclePhase());
    try retireClosedSession(&client, first.a);
}

test "core host cancel drops queued application turns before driving terminal work" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x26)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x27)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7088", &dials);

    var hits: usize = 0;
    const actor = try client.vat.spawn(FairCounter, .{ .hits = &hits });
    try client.vat.tellFromIngress(pair.a.served.port.ingress, actor, .{ .verb = "hit", .args = &.{} });
    driver.core.testing.markDirty(&client, pair.a.peer_handle);
    const wake = (try client.nextAction()) orelse return error.MissingFlush;
    try std.testing.expect(wake == .flush);

    client.beginClose(.cancel, 0);
    try std.testing.expectEqual(@as(usize, 0), hits);
    try retireClosingSession(&client, pair.a);
}

test "core host cancel settles a parked select-or-dial without realizing its ticket" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x28)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const vow_id = try host.enlivenSelectOrDial(tcpSturdyref("127.0.0.1:7087", "widget"));
    const dial = (try host.nextAction()) orelse return error.MissingDial;
    try std.testing.expect(dial == .dial);
    const ticket = dial.dial.ticket;
    try std.testing.expect(host.pendingDial(ticket, 0) != null);

    host.beginClose(.cancel, 0);
    try std.testing.expect(host.pendingDial(ticket, 0) == null);
    try std.testing.expectEqual(Host.LifecyclePhase.terminating, host.lifecyclePhase());
    const cancel = (try host.nextAction()) orelse return error.MissingDialCancellation;
    try std.testing.expect(cancel == .cancel_dial);
    try std.testing.expectEqual(ticket, cancel.cancel_dial.ticket);
    try std.testing.expectEqual(Host.LifecyclePhase.terminating, host.lifecyclePhase());
    try host.dialCancelled(ticket, 0);
    const failed = (try host.nextAction()) orelse return error.MissingFailure;
    try std.testing.expect(failed == .failed);
    try std.testing.expectEqual(vow_id, failed.failed.vow_id);
    try std.testing.expectEqual(driver.core.VowFailure.closed, failed.failed.failure);
    try std.testing.expectEqualStrings("host closing", failed.failed.message.bytes());
    try std.testing.expect((try host.nextAction()) == null);
    try std.testing.expectEqual(Host.LifecyclePhase.closed, host.lifecyclePhase());
}

test "core host transport packages publish no prefix before a later conflict" {
    var host = test_host.init(std.testing.allocator, @as([32]u8, @splat(0x30)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();

    const profiles = [_]model.transport.Metadata{
        .{ .symbol = "x-transaction-first", .designator_scheme = .address },
        .{ .symbol = model.transport.tcp, .designator_scheme = .key },
    };
    var canonical = [_][]const u8{ "untouched-0", "untouched-1" };
    try std.testing.expectError(
        error.TransportSemanticsConflict,
        host.defineTransports(&profiles, &canonical),
    );
    try std.testing.expectError(error.UnknownTransport, host.transportProfile("x-transaction-first"));
    try std.testing.expectEqualStrings("untouched-0", canonical[0]);
    try std.testing.expectEqualStrings("untouched-1", canonical[1]);
}

test "core host transport package allocation failure leaves authority and outputs untouched" {
    var saw_failure = false;
    var reached_success = false;

    for (0..32) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        failing.fail_index = std.math.maxInt(usize);
        var host = test_host.init(failing.allocator(), @as([32]u8, @splat(0x2f)), Host.Options.withFrameCap(frame_cap));
        defer {
            failing.fail_index = std.math.maxInt(usize);
            host.deinit();
        }

        const profile: model.transport.Metadata = .{
            .symbol = "x-allocation-transaction",
            .designator_scheme = .address,
        };
        var canonical = [_][]const u8{"untouched"};
        failing.fail_index = failing.alloc_index + offset;
        if (host.defineTransports(&.{profile}, &canonical)) |_| {
            reached_success = true;
            try std.testing.expectEqualStrings(profile.symbol, canonical[0]);
            try std.testing.expect((try host.transportProfile(profile.symbol)).eql(profile));
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            saw_failure = true;
            try std.testing.expectEqualStrings("untouched", canonical[0]);
            try std.testing.expectError(error.UnknownTransport, host.transportProfile(profile.symbol));
        }
        if (reached_success) break;
    }

    try std.testing.expect(saw_failure);
    try std.testing.expect(reached_success);
}
