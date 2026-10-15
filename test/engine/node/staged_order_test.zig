//! A send the Node is still staging holds its place in the recipient's queue
//! (ADR-0201): carriers queued behind it wait, a failed batch releases them in
//! order, and a closing recipient discards the row instead of waiting on it.

const std = @import("std");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const crypto = glowcap.foundation.crypto;

const Node = engine.Node;

const harness = @import("harness.zig");
const openKeyedSessionWithCounterpart = harness.openKeyedSessionWithCounterpart;

const Fixture = struct {
    node: Node,
    recipient_id: engine.PeerHandle,
    recipient: *engine.Peer,
    counterparts: [2]engine.Peer,
    answer: ?model.AnswerPosition,

    fn deinit(self: *Fixture) void {
        for (&self.counterparts) |*counterpart| counterpart.deinit();
        self.node.deinit();
    }
};

/// Queue a deliver carrying an exporter's object (staged until its gift id
/// arrives) and then a plain deliver, both to the recipient's import 2.
fn queueGiftThenPlain(fixture: *Fixture, profile: model.CaptpVersion, provisional: bool) !void {
    const allocator = std.testing.allocator;
    fixture.node = Node.init(allocator, @as([crypto.SEED_BYTES]u8, @splat(0x91)));
    fixture.recipient_id = try fixture.node.registerPeer(.{ .captp_version = profile });
    const exporter_id = try fixture.node.registerPeer(.{ .captp_version = profile });
    fixture.recipient = fixture.node.peer(fixture.recipient_id).?;
    const exporter = fixture.node.peer(exporter_id).?;
    fixture.counterparts[0] = try openKeyedSessionWithCounterpart(allocator, &fixture.node, fixture.recipient, @as([crypto.SEED_BYTES]u8, @splat(0x92)));
    fixture.counterparts[1] = try openKeyedSessionWithCounterpart(allocator, &fixture.node, exporter, @as([crypto.SEED_BYTES]u8, @splat(0x93)));

    try fixture.recipient.session_state.registerImport(.from(2));
    try exporter.session_state.registerImport(.from(4));
    const foreign = try fixture.node.enrollForeign(exporter_id, .{ .far = model.FarRef.object(4) });
    fixture.answer = if (provisional) .from(try fixture.recipient.allocateAnswer()) else null;
    if (provisional) fixture.recipient.openProvisional();
    try fixture.recipient.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(2) },
        .args = &.{.{ .reference = foreign }},
        .answer = fixture.answer,
    } });
    try fixture.recipient.sendBorrowed(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(2) },
        .args = &.{.{ .symbol = "plain" }},
    } });
}

test "a send queued behind a staged gift waits, and its failure releases it" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        var fixture: Fixture = undefined;
        try queueGiftThenPlain(&fixture, profile, false);
        defer fixture.deinit();
        const recipient = fixture.recipient;

        try std.testing.expectEqual(engine.StepOutcome.idle, try recipient.step());
        try std.testing.expect(recipient.takeOutbound() == null);

        const ticket = fixture.node.nextAction().?.need_gift_id.ticket;
        try fixture.node.giftIdFailed(ticket);
        try std.testing.expectEqual(fixture.recipient_id, fixture.node.nextAction().?.flush);

        try recipient.stepToIdle();
        var frame = recipient.takeOutbound().?;
        defer frame.deinit();
        const deliver = (try codec.dispatch.decodeBodyForProfile(
            recipient.session_state.codec,
            recipient.session_state.captp_version,
            frame.view(),
        )).deliver;
        try std.testing.expectEqualStrings("plain", (try deliver.args.at(0)).symbol);
        try std.testing.expect(recipient.takeOutbound() == null);
    }
}

test "a closing recipient discards a staged row instead of waiting on it" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        var fixture: Fixture = undefined;
        try queueGiftThenPlain(&fixture, profile, false);
        defer fixture.deinit();
        const recipient = fixture.recipient;

        recipient.closeSession();
        try recipient.stepToIdle();
        try std.testing.expect(recipient.pending_send.isEmpty());
    }
}

test "retracting a staged gift retires its queued release without sending either" {
    for ([_]model.CaptpVersion{ .v1_0, .next }) |profile| {
        var fixture: Fixture = undefined;
        try queueGiftThenPlain(&fixture, profile, true);
        defer fixture.deinit();
        const recipient = fixture.recipient;
        const answer = fixture.answer.?;
        const release = try recipient.reserveAnswerRelease();
        recipient.publishAnswerRelease(release, answer);
        const Retractions = struct {
            count: usize = 0,
            fn record(ctx: *anyopaque, _: model.AnswerPosition) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                self.count += 1;
            }
        };
        var retractions: Retractions = .{};
        recipient.retractProvisional(&retractions, Retractions.record);
        while (fixture.node.nextAction()) |action| switch (action) {
            .fail => |failure| {
                try std.testing.expectEqual(answer, failure.dest.answer.answer);
                retractions.count += 1;
            },
            .flush, .need_gift_id => {},
            else => return error.UnexpectedAction,
        };
        try std.testing.expectEqual(@as(usize, 1), retractions.count);
        try recipient.stepToIdle();
        try std.testing.expect(recipient.takeOutbound() == null);
        try std.testing.expect(!recipient.canObserveAnswer(answer));
        try std.testing.expect(recipient.session_state.outboundAnswer(answer) == null);
        try std.testing.expectEqual(@as(usize, 0), recipient.pending_send_bytes);
        try std.testing.expectEqual(@as(usize, 0), recipient.pending_send_reservations);
    }
}
