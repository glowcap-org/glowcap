//! A session's own publication answers its partner first: a Host publication
//! made later under the same name reaches other sessions but cannot take the
//! name over inside the session that published it.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../../support/core_host.zig");

const Host = glowcap.driver.core.Host;

const harness = @import("../harness.zig");
const TaggedRow = harness.TaggedRow;
const Tagged = harness.Tagged;
const frame_cap = harness.frame_cap;
const ParkedDial = harness.ParkedDial;
const Pair = harness.Pair;
const openPair = harness.openPair;
const pumpToQuiescence = harness.pumpToQuiescence;
const CapturedRef = harness.CapturedRef;
const CapturedString = harness.CapturedString;

fn fetchTag(allocator: std.mem.Allocator, client: *Host, server: *Host, pair: Pair, dials: *std.ArrayList(ParkedDial)) ![]const u8 {
    var held = CapturedRef{};
    try client.vowOn(try client.fetch(pair.a, "inbox"), .{ .ctx = &held, .func = CapturedRef.record });
    try pumpToQuiescence(allocator, &.{ client, server }, &.{pair}, dials);
    const vow = try client.send(pair.a, try held.require(), .{ .verb = "tag", .args = &.{} });
    var reply = CapturedString{};
    try client.vowOn(vow, .{ .ctx = &reply, .func = CapturedString.record });
    try pumpToQuiescence(allocator, &.{ client, server }, &.{pair}, dials);
    return try allocator.dupe(u8, reply.buf[0..reply.len]);
}

test "core host: a later Host publication cannot take over a session's own name" {
    const allocator = std.testing.allocator;
    var session_freed = false;
    var host_freed = false;
    var session_row = TaggedRow{ .tag = "session", .freed = &session_freed };
    var host_row = TaggedRow{ .tag = "host", .freed = &host_freed };
    var server = test_host.init(allocator, @as([32]u8, @splat(0x7a)), Host.Options.withFrameCap(frame_cap));
    defer server.deinit();
    var client = test_host.init(allocator, @as([32]u8, @splat(0x7b)), Host.Options.withFrameCap(frame_cap));
    defer client.deinit();
    var other = test_host.init(allocator, @as([32]u8, @splat(0x7c)), Host.Options.withFrameCap(frame_cap));
    defer other.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const pair = try openPair(allocator, &client, &server, "127.0.0.1:7081", &dials);
    _ = try pair.b.served.publish(&server.vat, "inbox", Tagged, .{ .row = &session_row });
    _ = try server.publish("inbox", Tagged, .{ .row = &host_row });

    const own = try fetchTag(allocator, &client, &server, pair, &dials);
    defer allocator.free(own);
    try std.testing.expectEqualStrings("session", own);

    // Every other session still reaches the Host publication.
    const other_pair = try openPair(allocator, &other, &server, "127.0.0.1:7082", &dials);
    const shared = try fetchTag(allocator, &other, &server, other_pair, &dials);
    defer allocator.free(shared);
    try std.testing.expectEqualStrings("host", shared);
}
