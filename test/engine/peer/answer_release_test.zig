//! When a questioner's answer releases leave: releases with no message behind
//! them wait, ride ahead of the next message in one `op:gc-answers`, and
//! leave alone when the embedder flushes them at its park.

const std = @import("std");
const glowcap = @import("glowcap");
const peer_fixture = @import("../../support/peer_fixture.zig");

const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;

/// Send one call on import 1 with `answer`, encoded and taken off the wire
/// with the listener the next profile pairs with it.
fn callWithAnswer(peer: *engine.Peer, answer: u64) !void {
    try peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(1) } },
        .args = &.{},
        .answer = .from(answer),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var frames: usize = 0;
    while (peer.takeOutbound()) |taken| : (frames += 1) {
        var frame = taken;
        frame.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), frames);
}

fn releaseAnswer(peer: *engine.Peer, answer: u64) !void {
    const release = try peer.reserveAnswerRelease();
    peer.publishAnswerRelease(release, peer.session_state.outboundAnswerTarget(.from(answer)).?);
}

fn expectGcAnswers(peer: *engine.Peer, expected: []const u64) !void {
    var frame = peer.takeOutbound() orelse return error.MissingGcAnswers;
    defer frame.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.next, frame.view());
    try std.testing.expect(body == .gc_answer);
    try std.testing.expectEqual(expected.len, try body.gc_answer.positions.len());
    for (expected, 0..) |position, i| {
        try std.testing.expectEqual(position, try body.gc_answer.positions.at(i));
    }
}

test "answer releases wait for the next message and ride ahead of it in one op" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(1));
    try callWithAnswer(&peer, 42);
    try callWithAnswer(&peer, 43);

    try releaseAnswer(&peer, 42);
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.holdsAnswerReleases());
    try std.testing.expect(peer.takeOutbound() == null);
    try releaseAnswer(&peer, 43);
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expect(peer.session_state.outboundAnswer(.from(42)) != null);

    try peer.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(1) } },
        .args = &.{},
        .answer = null,
    } });
    try std.testing.expect(!peer.holdsAnswerReleases());
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try expectGcAnswers(&peer, &.{ 42, 43 });
    try std.testing.expect(peer.session_state.outboundAnswer(.from(42)) == null);
    try std.testing.expect(peer.session_state.outboundAnswer(.from(43)) == null);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var deliver = peer.takeOutbound() orelse return error.MissingDeliver;
    defer deliver.deinit();
    const body = try codec.syrup.decodeBodyForProfile(.next, deliver.view());
    try std.testing.expect(body == .deliver);
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
}

test "a flush sends waiting answer releases on their own" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(1));
    try std.testing.expect(!try peer.flushAnswerReleases());
    try callWithAnswer(&peer, 7);
    try callWithAnswer(&peer, 8);
    try releaseAnswer(&peer, 7);
    try releaseAnswer(&peer, 8);
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());

    try std.testing.expect(try peer.flushAnswerReleases());
    try expectGcAnswers(&peer, &.{ 7, 8 });
    try std.testing.expect(!peer.holdsAnswerReleases());
    try std.testing.expect(peer.session_state.outboundAnswer(.from(7)) == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
}
