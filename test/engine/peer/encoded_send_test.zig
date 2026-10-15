//! A deliver leaves the pending queue as its frame (ADR-0236). Admission
//! encodes it, so a borrowed tree is the caller's again when the send
//! returns, the step emits the same bytes, a retracted provisional send
//! gives back the exports, answer, and resolver it took, and a refused
//! admission commits nothing, so the same send retries.

const std = @import("std");
const glowcap = @import("glowcap");

const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const peer_fixture = @import("../../support/peer_fixture.zig");

const profiles = [_]model.CaptpVersion{ .v1_0, .next };

const Retractions = struct {
    count: usize = 0,
    fn record(ctx: *anyopaque, _: model.AnswerPosition) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.count += 1;
    }
};

fn answeredDeliver(args: []const model.Argument) model.Message {
    return .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = args,
        .answer = .from(42),
    } };
}

test "a far send's frame is queued at admission and step emits those bytes" {
    for (profiles) |profile| {
        var peer = peer_fixture.openPeerWith(std.testing.allocator, .{ .captp_version = profile });
        defer peer.deinit();
        try peer.session_state.registerImport(.from(7));

        var payload: [5]u8 = "hello".*;
        try peer.sendBorrowed(answeredDeliver(&.{.{ .bytes = &payload }}));
        const row = peer.pending_send.peek().?;
        try std.testing.expect(row.item == .encoded);
        const queued = try std.testing.allocator.dupe(u8, row.item.encoded.frame.bytes());
        defer std.testing.allocator.free(queued);
        try std.testing.expect(std.mem.indexOf(u8, queued, "hello") != null);
        // The caller's storage is its own again: mutating it changes nothing.
        payload = "bye!!".*;

        try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        var frame = peer.takeOutbound() orelse return error.MissingDeliver;
        defer frame.deinit();
        try std.testing.expectEqualSlices(u8, queued, frame.bytes());
        if (profile == .next) {
            var listener = peer.takeOutbound() orelse return error.MissingListener;
            defer listener.deinit();
            try std.testing.expect(std.mem.indexOf(u8, listener.bytes(), "op:listen") != null);
        }
        try std.testing.expect(peer.takeOutbound() == null);
        try std.testing.expect(peer.pending_send.isEmpty());
    }
}

test "a retracted provisional deliver returns its exports, answer, and resolver" {
    for (profiles) |profile| {
        var peer = peer_fixture.openPeerWith(std.testing.allocator, .{ .captp_version = profile });
        defer peer.deinit();
        try peer.session_state.registerImport(.from(7));
        const near = model.ExportPosition.from(try peer.exportNextObject());
        const before_count = peer.session_state.exportRefcount(near);
        const before_next = peer.session_state.next_export_position;

        peer.openProvisional();
        try peer.sendBorrowed(answeredDeliver(&.{
            .{ .reference = .{ .near = .{ .export_position = near } } },
            .{ .bytes = "freight" },
        }));
        const sent = peer.pending_send.peek().?.item.encoded;
        try std.testing.expectEqual(@as(usize, 1), sent.exports.len);
        try std.testing.expectEqual(near, sent.exports[0]);
        try std.testing.expectEqual(model.AnswerPosition.from(42), sent.answer.?);
        try std.testing.expect(sent.resolver != null);
        try std.testing.expect(peer.session_state.exportRefcount(near) > before_count);
        try std.testing.expect(peer.session_state.outboundAnswer(.from(42)) != null);

        var retractions: Retractions = .{};
        peer.retractProvisional(&retractions, Retractions.record);
        try std.testing.expectEqual(@as(usize, 1), retractions.count);
        try std.testing.expect(peer.pending_send.isEmpty());
        try std.testing.expectEqual(before_count, peer.session_state.exportRefcount(near));
        try std.testing.expect(peer.session_state.outboundAnswer(.from(42)) == null);
        try std.testing.expectEqual(
            @as(?model.ExportPosition, null),
            peer.session_state.outbound_resolver_link.getByValue(.{ .application_answer = .from(42) }),
        );
        try std.testing.expectEqual(@as(u64, 0), peer.session_state.exportRefcount(sent.resolver.?));
        // The position is spent, never reused for a later mint.
        try std.testing.expect(peer.session_state.next_export_position > before_next);
        try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    }
}

test "a refused admission commits nothing and the same send retries" {
    for (profiles) |profile| {
        // Every allocation admission makes, from the inventory through the
        // frame, the listener, and the list, fails in turn.
        var offset: usize = 0;
        var saw_success = false;
        while (!saw_success) : (offset += 1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var peer = peer_fixture.openPeerWith(failing.allocator(), .{ .captp_version = profile });
            defer peer.deinit();
            defer failing.fail_index = std.math.maxInt(usize);
            try peer.session_state.registerImport(.from(7));
            const near = model.ExportPosition.from(try peer.exportNextObject());
            const before_count = peer.session_state.exportRefcount(near);
            const deliver = answeredDeliver(&.{
                .{ .reference = .{ .near = .{ .export_position = near } } },
                .{ .bytes = "freight" },
            });

            failing.fail_index = failing.alloc_index + offset;
            const attempt = peer.sendBorrowed(deliver);
            failing.fail_index = std.math.maxInt(usize);
            if (attempt) |_| {
                saw_success = true;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(peer.pending_send.isEmpty());
                try std.testing.expectEqual(before_count, peer.session_state.exportRefcount(near));
                try std.testing.expect(peer.session_state.outboundAnswer(.from(42)) == null);
                try std.testing.expectEqual(
                    @as(?model.ExportPosition, null),
                    peer.session_state.outbound_resolver_link.getByValue(.{ .application_answer = .from(42) }),
                );
                try peer.sendBorrowed(deliver);
            }
            try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
            var frame = peer.takeOutbound() orelse return error.MissingDeliver;
            frame.deinit();
            if (profile == .next) {
                var listener = peer.takeOutbound() orelse return error.MissingListener;
                listener.deinit();
            }
            try std.testing.expect(peer.takeOutbound() == null);
        }
        try std.testing.expect(offset > 1);
    }
}

test "a deliver past the outbound budget is refused before it allocates" {
    var peer = peer_fixture.openPeer(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(7));
    peer.outbound_budget = 64;
    const big = try std.testing.allocator.alloc(u8, peer.outbound_budget + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');

    try std.testing.expectError(
        error.OutboundBackpressure,
        peer.sendBorrowed(answeredDeliver(&.{.{ .bytes = big }})),
    );
    try std.testing.expect(peer.pending_send.isEmpty());
    try std.testing.expect(peer.session_state.outboundAnswer(.from(42)) == null);
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
}
