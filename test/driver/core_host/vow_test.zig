//! Vows and unobserved completions: rows retire on settle, failed dials
//! break the redeeming vow with the reason, unlistened settles ride the
//! action queue owned, a burst never strands on the reserved queue, and
//! fetch failures stay pre-commit.

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

test "core host fresh vow id exhaustion refuses before publishing a vow row" {
    const allocator = std.testing.allocator;
    var host = test_host.init(allocator, @as([32]u8, @splat(0x49)), Host.Options.withFrameCap(frame_cap));
    defer host.deinit();
    const session = try publishAndOpenAccepted(&host, "tcp", "127.0.0.1:7000", &.{});

    host.next_vow = std.math.maxInt(u64);
    try std.testing.expectError(
        error.CapabilitySpaceExhausted,
        host.queueFetch(session, "widget"),
    );
    try std.testing.expectEqual(@as(usize, 0), host.vows.count());
    try std.testing.expectEqual(std.math.maxInt(u64), host.next_vow);
}

test "core host: vow rows retire on settle; the map stays empty and release frees the rest" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x4a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x4b)), Host.Options.withFrameCap(frame_cap));
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
    var client = test_host.init(allocator, @as([32]u8, @splat(0x5a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x5b)), Host.Options.withFrameCap(frame_cap));
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
                try std.testing.expectEqual(driver.core.VowFailure.broken, f.failure);
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
    var client = test_host.init(allocator, @as([32]u8, @splat(0x6a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x6b)), Host.Options.withFrameCap(frame_cap));
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
    try std.testing.expect(reference == .routed);
}

test "core host: transport loss retires session authority and refuses later work" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x7a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x7b)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7001", &dials);

    const parked = try client.fetch(pair.a, "never-answered");
    try client.transportClosed(pair.a, "transport gone");
    try std.testing.expect(pair.a.isTerminating());
    try std.testing.expectError(driver.core.HostError.SessionCondemned, client.fetch(pair.a, "too-late"));

    var failed = false;
    while (try client.nextAction()) |action| switch (action) {
        .flush, .close => {},
        .failed => |failure| {
            try std.testing.expectEqual(parked, failure.vow_id);
            try std.testing.expectEqual(driver.core.VowFailure.closed, failure.failure);
            try std.testing.expect(std.mem.indexOf(u8, failure.message, "transport gone") != null);
            failed = true;
        },
        else => return error.UnexpectedAction,
    };
    try std.testing.expect(failed);

    // Repeated physical-close reports are idempotent until explicit release.
    try client.transportClosed(pair.a, "transport gone again");
}

test "core host: direct session release classifies its pending vows as closed" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x7c)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x7d)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7002", &dials);

    const parked = try client.fetch(pair.a, "never-answered");
    try client.releaseSession(pair.a);

    var failed = false;
    while (try client.nextAction()) |action| switch (action) {
        .failed => |failure| {
            try std.testing.expectEqual(parked, failure.vow_id);
            try std.testing.expectEqual(driver.core.VowFailure.closed, failure.failure);
            failed = true;
        },
        .flush, .resume_work => {},
        else => return error.UnexpectedAction,
    };
    try std.testing.expect(failed);
}

test "core host: a burst of unlistened settles never strands — every completion lands on the reserved queue" {
    const allocator = std.testing.allocator;
    var client = test_host.init(allocator, @as([32]u8, @splat(0x7a)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x7b)), Host.Options.withFrameCap(frame_cap));
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

    var seen: [burst]bool = @splat(false);
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
            var client = test_host.init(allocator, @as([32]u8, @splat(0x9a)), Host.Options.withFrameCap(frame_cap));
            defer client.deinit();
            var server = test_host.init(allocator, @as([32]u8, @splat(0x9b)), Host.Options.withFrameCap(frame_cap));
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
            var seen: [burst]bool = @splat(false);
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

test "core host: fetch allocation failures are pre-commit and a committed vow id is never lost" {
    var offset: usize = 0;
    var saw_precommit_oom = false;
    while (true) : (offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        var client = test_host.init(allocator, @as([32]u8, @splat(0xa8)), Host.Options.withFrameCap(frame_cap));
        defer client.deinit();
        var server = test_host.init(std.testing.allocator, @as([32]u8, @splat(0xa9)), Host.Options.withFrameCap(frame_cap));
        defer server.deinit();
        var dials: std.ArrayList(ParkedDial) = .empty;
        defer dials.deinit(std.testing.allocator);
        const pair = try openPair(std.testing.allocator, &client, &server, "127.0.0.1:7106", &dials);

        try std.testing.expectEqual(@as(usize, 0), pair.a.served.queuedOutboundBytes());
        const held_bootstrap_before = pair.a.served.port.peer.session_state.holdsImport(.from(engine.BOOTSTRAP_POSITION));
        failing.fail_index = failing.alloc_index + offset;

        const result = client.fetch(pair.a, "allocation-transaction");
        if (result) |vow_id| {
            // An allocation may have failed while the post-commit encode pump
            // ran. The operation still succeeds with its live id; callers must
            // never be invited to replay a committed fetch.
            try std.testing.expect(client.vows.contains(vow_id));
            failing.fail_index = std.math.maxInt(usize);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            saw_precommit_oom = true;
            // Every returned OOM precedes the fetch: no carrier, Host vow, or
            // bootstrap-import retain crossed the transaction boundary.
            try std.testing.expectEqual(@as(usize, 0), pair.a.served.queuedOutboundBytes());
            try std.testing.expectEqual(@as(usize, 0), client.vows.count());
            try std.testing.expectEqual(
                held_bootstrap_before,
                pair.a.served.port.peer.session_state.holdsImport(.from(engine.BOOTSTRAP_POSITION)),
            );
        }

        failing.fail_index = std.math.maxInt(usize);
        try std.testing.expect(offset < 64);
    }
    try std.testing.expect(saw_precommit_oom);
}
