//! Goblins accepts a resolver capability reused by independent deliveries
//! (captp.rkt's incoming op:deliver and maybe-install-import!). Each answer
//! owns its callback and its import retain, including after answer GC.
const std = @import("std");
const glowcap = @import("glowcap");
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const codec = glowcap.ocapn.codec;

test "V1.0 shared resolver retains each answer callback independently" {
    for ([_]bool{ false, true }) |virtual| {
        var peer = engine.testing.initRawOpenPeer(std.testing.allocator);
        defer peer.deinit();
        try peer.session_state.registerExport(.from(7));
        var answers: [2]engine.AnswerTarget = undefined;
        for (&answers, 0..) |*answer, i| {
            var frame = try codec.syrup.encodeMessageForProfile(std.testing.allocator, .v1_0, .{ .deliver = .{
                .target = .{ .far = model.FarRef.object(7) },
                .args = &.{},
                .answer = if (virtual) null else .from(i + 11),
                .resolve_me_desc = .{ .near = model.NearRef.object(99) },
            } });
            defer frame.deinit();
            try peer.recvBorrowed(frame.view());
            var event = peer.pollEvent().?;
            defer event.deinit();
            answer.* = event.deliverAnswerTarget().?;
        }
        try std.testing.expectEqual(@as(u64, 2), peer.session_state.imports.count(.from(99)));
        if (!virtual) {
            // The first callback remains owed after its pipelining name dies.
            try peer.recvBorrowed(.{ .bytes = "<13'op:gc-answers[11+]>", .shape = .byte });
            var event = peer.pollEvent().?;
            event.deinit();
        }
        for (answers, 0..) |answer, i| {
            try peer.sendAnswerTargetResolutionCopying(answer, .{ .fulfill = .{ .integer = @intCast(i) } });
            while ((try peer.step()) != .idle) {}
            var callback = peer.takeOutbound().?;
            defer callback.deinit();
            const body = try codec.syrup.decodeBodyForProfile(.v1_0, callback.view());
            try std.testing.expectEqual(@as(u64, 99), body.deliver.target.near.export_position.int());
            try std.testing.expectEqual(@as(i64, @intCast(i)), (try body.deliver.args.at(1)).integer);
            var release = peer.takeOutbound().?;
            defer release.deinit();
            const gc = (try codec.syrup.decodeBodyForProfile(.v1_0, release.view())).gc_export;
            try std.testing.expectEqual(@as(u64, 99), try gc.positions.at(0));
            try std.testing.expectEqual(@as(u64, 1), try gc.deltas.at(0));
            try std.testing.expect(peer.takeOutbound() == null);
            try std.testing.expectEqual(@as(u64, 1 - i), peer.session_state.imports.count(.from(99)));
        }
        try std.testing.expect(peer.sessionIsOpen());
    }
}
