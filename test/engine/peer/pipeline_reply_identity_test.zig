//! A queued call's reply belongs to its original answer incarnation even when
//! its caller releases and reuses the wire answer before the target settles.
const std = @import("std");
const glowcap = @import("glowcap");
const peer_fixture = @import("../../support/peer_fixture.zig");

const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;

fn receive(peer: *engine.Peer, message: model.Message) !void {
    var frame = try codec.dispatch.encodeMessageForProfile(
        peer.session_state.codec,
        peer.allocator,
        peer.session_state.captp_version,
        message,
    );
    defer frame.deinit();
    try peer.recvBorrowed(frame.view());
}

fn discardEvents(peer: *engine.Peer) void {
    while (peer.pollEvent()) |value| {
        var event = value;
        event.deinit();
    }
}

fn pump(peer: *engine.Peer) !void {
    while (try peer.step() == .progress) {}
}

fn expectOriginalCallback(peer: *engine.Peer, broken: bool) !void {
    var callbacks: usize = 0;
    while (peer.takeOutbound()) |value| {
        var frame = value;
        defer frame.deinit();
        const body = try codec.dispatch.decodeBodyForProfile(
            peer.session_state.codec,
            peer.session_state.captp_version,
            frame.view(),
        );
        if (body != .deliver) continue;
        callbacks += 1;
        try std.testing.expect(body.deliver.target == .near);
        // Resolver 100 belongs to the replacement and must never receive this.
        try std.testing.expectEqual(@as(u64, 99), body.deliver.target.near.export_position.int());
        try std.testing.expectEqualStrings(if (broken) "break" else "fulfill", (try body.deliver.args.at(0)).symbol);
        const result = try body.deliver.args.at(1);
        if (broken) {
            try std.testing.expectEqualStrings("source broke", result.symbol);
        } else {
            try std.testing.expectEqualStrings("old result", result.bytes);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), callbacks);
}

test "queued replies survive their own answer GC and reuse for local delivery and break" {
    const allocator = std.testing.allocator;
    inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec_id| {
        inline for (.{ model.CaptpVersion.next, model.CaptpVersion.v1_0 }) |profile| {
            for ([_]bool{ false, true }) |reuse| {
                for ([_]bool{ false, true }) |broken| {
                    var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = profile });
                    defer peer.deinit();
                    peer.session_state.codec = codec_id;
                    try peer.session_state.registerExport(.from(7));
                    try peer.session_state.registerExport(.from(9));
                    try peer.session_state.installInboundAnswer(.from(42));

                    try receive(&peer, .{ .deliver = .{
                        .target = .{ .promise = .{ .answer_position = .from(42) } },
                        .args = &.{.{ .bytes = "old call" }},
                        .answer = .from(43),
                        .resolve_me_desc = .{ .near = model.NearRef.object(99) },
                    } });
                    try std.testing.expect(peer.pollEvent() == null);
                    const original = peer.session_state.answerTargetNamed(.fromWire(.from(43))).?;

                    try receive(&peer, .{ .gc_answer = .{ .positions = &.{43} } });
                    discardEvents(&peer);
                    try std.testing.expect(peer.session_state.inboundAnswer(.from(43)) == null);

                    if (reuse) {
                        try receive(&peer, .{ .deliver = .{
                            .target = .{ .far = model.FarRef.object(7) },
                            .args = &.{.{ .bytes = "replacement call" }},
                            .answer = .from(43),
                            .resolve_me_desc = .{ .near = model.NearRef.object(100) },
                        } });
                        var replacement = peer.pollEvent() orelse return error.MissingReplacementCall;
                        defer replacement.deinit();
                        try std.testing.expect(replacement.deliverAnswerTarget().?.row_id != original.row_id);
                    }

                    try peer.sendAnswerResolutionCopying(.fromWire(.from(42)), if (broken)
                        .{ .@"break" = .{ .message = "source broke" } }
                    else
                        .{ .fulfill = .{ .reference = .{ .near = model.NearRef.object(9) } } });
                    try pump(&peer);
                    if (!broken) {
                        var replay = peer.pollEvent() orelse return error.MissingQueuedCall;
                        defer replay.deinit();
                        try std.testing.expectEqualStrings("old call", (try replay.view().deliver.args.at(0)).bytes);
                        const reply = replay.deliverAnswerTarget() orelse return error.MissingOriginalReplyTarget;
                        try std.testing.expectEqualDeep(original, reply);
                        try peer.sendAnswerTargetResolutionCopying(reply, .{ .fulfill = .{ .bytes = "old result" } });
                        try pump(&peer);
                    }
                    try expectOriginalCallback(&peer, broken);
                    if (reuse) {
                        try std.testing.expectEqual(session.AnswerStatus.pending, peer.session_state.inboundAnswer(.from(43)).?.status);
                    } else {
                        try std.testing.expect(peer.session_state.inboundAnswer(.from(43)) == null);
                    }
                    try std.testing.expect(peer.pollEvent() == null);
                    try std.testing.expect(peer.sessionIsOpen());
                }
            }
        }
    }
}

test "releasing an unsubscribed baseline queued reply does not abort its later drain" {
    const allocator = std.testing.allocator;
    inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec_id| {
        for ([_]bool{ false, true }) |reuse| {
            for ([_]bool{ false, true }) |broken| {
                var peer = peer_fixture.openPeerWith(allocator, .{ .captp_version = .v1_0 });
                defer peer.deinit();
                peer.session_state.codec = codec_id;
                try peer.session_state.registerExport(.from(7));
                try peer.session_state.registerImport(.from(9));
                try peer.session_state.installInboundAnswer(.from(42));
                try receive(&peer, .{ .deliver = .{
                    .target = .{ .promise = .{ .answer_position = .from(42) } },
                    .args = &.{.{ .bytes = "old call" }},
                    .answer = .from(43),
                } });
                try std.testing.expect(peer.pollEvent() == null);
                try receive(&peer, .{ .gc_answer = .{ .positions = &.{43} } });
                discardEvents(&peer);
                try std.testing.expect(peer.session_state.inboundAnswer(.from(43)) == null);
                if (reuse) {
                    try receive(&peer, .{ .deliver = .{
                        .target = .{ .far = model.FarRef.object(7) },
                        .args = &.{.{ .bytes = "replacement call" }},
                        .answer = .from(43),
                    } });
                    discardEvents(&peer);
                }

                try peer.sendAnswerResolutionCopying(.fromWire(.from(42)), if (broken)
                    .{ .@"break" = .{ .message = "source broke" } }
                else
                    .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(9) } } });
                try pump(&peer);
                var forwarded: usize = 0;
                while (peer.takeOutbound()) |value| {
                    var frame = value;
                    defer frame.deinit();
                    const body = try codec.dispatch.decodeBodyForProfile(codec_id, .v1_0, frame.view());
                    if (body != .deliver) continue;
                    forwarded += 1;
                    try std.testing.expect(!broken);
                    try std.testing.expect(body.deliver.target == .near);
                    try std.testing.expectEqual(@as(u64, 9), body.deliver.target.near.export_position.int());
                    try std.testing.expectEqualStrings("old call", (try body.deliver.args.at(0)).bytes);
                    try std.testing.expect(body.deliver.answer == null);
                    try std.testing.expect(body.deliver.resolve_me_desc == null);
                }
                try std.testing.expectEqual(@as(usize, if (broken) 0 else 1), forwarded);
                if (reuse) {
                    try std.testing.expectEqual(session.AnswerStatus.pending, peer.session_state.inboundAnswer(.from(43)).?.status);
                } else {
                    try std.testing.expect(peer.session_state.inboundAnswer(.from(43)) == null);
                }
                try std.testing.expect(peer.pollEvent() == null);
                try std.testing.expect(peer.sessionIsOpen());
            }
        }
    }
}
