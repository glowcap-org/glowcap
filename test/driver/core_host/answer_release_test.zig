//! When a questioner's answer release leaves the Host: it waits at the peer's
//! queue tail, rides ahead of the session's next message, and leaves alone
//! when the embedder flushes held releases at its park.

const std = @import("std");
const glowcap = @import("glowcap");
const test_host = @import("../../support/core_host.zig");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const driver = glowcap.driver;
const Host = driver.core.Host;

const harness = @import("harness.zig");
const frame_cap = harness.frame_cap;
const ParkedDial = harness.ParkedDial;
const openWidgetPair = @import("vow/widget_pair.zig").open;

/// Pop every queued action without the park's flush, so a held release
/// stays held: the drain an embedder runs before it decides to park.
fn drainWithoutPark(host: *Host) !void {
    while (try host.nextAction()) |action| switch (action) {
        .flush, .settled, .failed, .resume_work => {},
        else => return error.UnexpectedAction,
    };
}

const Kind = enum { gc_answer, deliver, listen };

/// Take the next frame, require `kind`, and return how many answers an
/// `op:gc-answers` names (null for the other kinds).
fn expectFrame(session: *driver.core.HostSession, kind: Kind) !?usize {
    var frame = (try session.takeOutbound()) orelse return error.MissingFrame;
    defer frame.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.next, frame.view());
    switch (kind) {
        .gc_answer => {
            if (body != .gc_answer) return error.UnexpectedFrame;
            return try body.gc_answer.positions.len();
        },
        .deliver => if (body != .deliver) return error.UnexpectedFrame,
        .listen => if (body != .listen) return error.UnexpectedFrame,
    }
    return null;
}

test "core host: answer releases ride the next message or leave at the park" {
    const allocator = std.testing.allocator;
    var options = Host.Options.withFrameCap(frame_cap);
    options.captp_version = .next;
    options.features = model.FeatureSet.full().forCaptpVersion(.next);
    var client = test_host.init(allocator, @as([32]u8, @splat(0x61)), options);
    defer client.deinit();
    var server = test_host.init(allocator, @as([32]u8, @splat(0x62)), options);
    defer server.deinit();
    var dials: std.ArrayList(ParkedDial) = .empty;
    defer dials.deinit(allocator);

    const opened = try openWidgetPair(allocator, &client, &server, &dials);
    const session = opened.pair.a;
    const peer = session.served.port.peer;
    const baseline_answers = peer.session_state.outbound_answers.len();

    // A settled call releases its answer inside the feed that settled it.
    const first = try client.send(session, opened.widget, .{ .verb = "poke", .args = &.{} });
    var captured = harness.CapturedString{};
    try client.vowOn(first, .{ .ctx = &captured, .func = harness.CapturedString.record });
    var rounds: usize = 0;
    while (captured.len == 0 and !captured.broken) : (rounds += 1) {
        if (rounds == 16) return error.CallDidNotSettle;
        _ = try harness.shuttleAll(&.{opened.pair});
        try drainWithoutPark(&client);
        try drainWithoutPark(&server);
    }
    try std.testing.expectEqual(@as(usize, 0), client.vows.count());
    // Released, but held: no frame leaves and the answer row stays until it does.
    try std.testing.expect(peer.holdsAnswerReleases());
    try std.testing.expect((try session.takeOutbound()) == null);
    try std.testing.expectEqual(baseline_answers + 1, peer.session_state.outbound_answers.len());

    // The next message carries it, ahead of itself.
    const second = try client.send(session, opened.widget, .{ .verb = "poke", .args = &.{} });
    try std.testing.expectEqual(@as(?usize, 1), try expectFrame(session, .gc_answer));
    try std.testing.expectEqual(@as(?usize, null), try expectFrame(session, .deliver));
    try std.testing.expectEqual(@as(?usize, null), try expectFrame(session, .listen));
    try std.testing.expect((try session.takeOutbound()) == null);
    try std.testing.expectEqual(baseline_answers + 1, peer.session_state.outbound_answers.len());
    try drainWithoutPark(&client);

    // The park sends a held release alone.
    try client.vowRelease(second);
    try std.testing.expect(peer.holdsAnswerReleases());
    try std.testing.expect((try session.takeOutbound()) == null);
    try std.testing.expect(try client.flushHeldReleases());
    try std.testing.expect(!try client.flushHeldReleases());
    try std.testing.expectEqual(@as(?usize, 1), try expectFrame(session, .gc_answer));
    try std.testing.expect((try session.takeOutbound()) == null);
    try std.testing.expectEqual(baseline_answers, peer.session_state.outbound_answers.len());
    try drainWithoutPark(&client);
}
