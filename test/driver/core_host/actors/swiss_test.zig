//! Durable and mutable swiss namespaces stay disjoint: mutable binds refuse
//! the reserved prefix, a removed durable name misses, and a restarted Host
//! does not retarget the old sturdyref.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../../support/core_host.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;
const stream_framing = glowcap.foundation.stream_framing;

const harness = @import("../harness.zig");
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

test "core host: durable and mutable swiss namespaces are disjoint, and a removed durable name misses across restart" {
    // ADR-0098 evidence item 5. The reserved prefix is the cross-restart
    // invariant: mutable binds refuse it structurally, the durable mint
    // produces only names inside it, removal reclaims the row, and a fresh
    // Host (the restart) simply misses — no tombstone anywhere.
    const allocator = std.testing.allocator;
    var server = test_host.init(allocator, @as([32]u8, @splat(0x6a)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var client = test_host.init(allocator, @as([32]u8, @splat(0x6b)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    // Structural refusal at every mutable bind: the host-wide alias verb and
    // the session-level bootstrap bind both refuse the reserved prefix.
    var decoy_freed = false;
    var decoy_row = TaggedRow{ .tag = "decoy", .freed = &decoy_freed };
    try std.testing.expectError(
        error.ReservedDurableNamespace,
        server.publishGiftable("glowcap-durable-1-not-actually-minted", Tagged, .{ .row = &decoy_row }),
    );
    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7071", &dials);
    try std.testing.expectError(
        error.ReservedDurableNamespace,
        pair.b.served.publish(&pair.b.host.vat, "glowcap-durable-1-still-not-minted", Tagged, .{ .row = &decoy_row }),
    );

    // Mint a durable name and reach it over the wire like any published name.
    var kept_freed = false;
    var kept_row = TaggedRow{ .tag = "durable", .freed = &kept_freed };
    const minted = try server.publishDurable(@as([16]u8, @splat(0xab)), Tagged, .{ .row = &kept_row });
    try std.testing.expect(glowcap.ocapn.session.Session.isDurableSwiss(minted.slice()));
    var fetched = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, minted.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    _ = try fetched.require();

    // The two removal verbs refuse each other's namespace, and a durable
    // name is never reassignable: a second mint from the same entropy fails
    // loud instead of retargeting.
    try std.testing.expectError(error.ReservedDurableNamespace, server.unpublish(minted.slice()));
    try std.testing.expectError(error.NotDurableName, server.removeDurable("plain-alias"));
    var usurper_freed = false;
    var usurper_row = TaggedRow{ .tag = "usurper", .freed = &usurper_freed };
    try std.testing.expectError(
        error.DurableNameCollision,
        server.publishDurable(@as([16]u8, @splat(0xab)), Tagged, .{ .row = &usurper_row }),
    );

    // Removal reclaims the row: a fresh fetch of the old sturdyref misses,
    // and a fresh mint does not reuse the removed bytes.
    try server.removeDurable(minted.slice());
    var missed = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, minted.slice()), .{ .ctx = &missed, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client, &server }, &.{pair}, &dials);
    try std.testing.expect(missed.broken);
    const reminted = try server.publishDurable(@as([16]u8, @splat(0xcd)), Tagged, .{ .row = &kept_row });
    try std.testing.expect(!std.mem.eql(u8, reminted.slice(), minted.slice()));

    // The restart: a fresh Host with an empty durable registry. The old
    // sturdyref misses rather than retargets, and a mutable alias still
    // cannot squat the durable bytes.
    var restarted = test_host.init(allocator, @as([32]u8, @splat(0x6a)), Host.Options.withFrameCap(frame_cap));
    defer restarted.deinit();
    var client2 = test_host.init(allocator, @as([32]u8, @splat(0x6c)), Host.Options.withFrameCap(frame_cap));
    defer client2.deinit();
    try std.testing.expectError(
        error.ReservedDurableNamespace,
        restarted.publishGiftable(minted.slice(), Tagged, .{ .row = &decoy_row }),
    );
    const pair2 = try openPair(allocator, &client2, &restarted, "127.0.0.1:7072", &dials);
    var restart_miss = CapturedRef{};
    try client2.vowOn(try client2.fetch(pair2.a, minted.slice()), .{ .ctx = &restart_miss, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ &client2, &restarted }, &.{pair2}, &dials);
    try std.testing.expect(restart_miss.broken);
}
