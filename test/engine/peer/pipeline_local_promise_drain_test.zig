//! Queued arguments remain capability roots throughout a multi-call drain.
const std = @import("std");
const glowcap = @import("glowcap");
const fixture = @import("../../support/peer_fixture.zig");
const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;

fn receive(peer: *engine.Peer, message: model.Message) !void {
    var frame = try codec.dispatch.encodeMessageForProfile(peer.session_state.codec, peer.allocator, peer.session_state.captp_version, message);
    defer frame.deinit();
    try peer.recvBorrowed(frame.view());
}

fn pump(peer: *engine.Peer) !void {
    for (0..64) |_| {
        if (try peer.step() != .progress) return;
    }
    return error.PumpDidNotQuiesce;
}

fn discardOutbound(peer: *engine.Peer) void {
    while (peer.takeOutbound()) |value| {
        var frame = value;
        frame.deinit();
    }
}

test "forwarding an earlier queued call preserves a later call's local promise argument" {
    inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec_id| {
        inline for (.{ model.CaptpVersion.next, model.CaptpVersion.v1_0 }) |profile| {
            var peer = fixture.openPeerWith(std.testing.allocator, .{ .captp_version = profile });
            defer peer.deinit();
            peer.session_state.codec = codec_id;
            const projection = try peer.session_state.allocateLocalPromiseProjection();
            try peer.session_state.installInboundAnswer(.from(42));
            try peer.session_state.registerImport(.from(9));

            // Give the partner one real wire mention before it sends P back
            // as an argument. No test-only retain substitutes for publication.
            try peer.sendBorrowed(.{ .deliver = .{
                .target = .{ .far = model.FarRef.object(9) },
                .args = &.{.{ .reference = .{ .near = model.NearRef.promise(projection.export_position.int()) } }},
            } });
            try pump(&peer);
            discardOutbound(&peer);

            try receive(&peer, .{ .deliver = .{
                .target = .{ .promise = .{ .answer_position = .from(42) } },
                .args = &.{ .{ .string = "first" }, .{ .reference = .{ .near = model.NearRef.object(88) } } },
            } });
            try receive(&peer, .{ .deliver = .{
                .target = .{ .promise = .{ .answer_position = .from(42) } },
                .args = &.{ .{ .string = "second" }, .{ .reference = .{ .far = model.FarRef.promise(projection.export_position.int()) } } },
            } });
            try peer.sendAnswerResolutionCopying(projection.answer_name, .{ .fulfill = .{ .bytes = "settled" } });
            try pump(&peer);
            discardOutbound(&peer);
            try receive(&peer, .{ .gc_export = .{
                .positions = &.{projection.export_position.int()},
                .deltas = &.{1},
            } });
            // The second queued call now owns P's only reachable reference.
            try std.testing.expect(peer.session_state.hasExport(projection.export_position));
            try std.testing.expectEqual(@as(u64, 1), peer.session_state.importRefcount(.from(88)));

            try peer.sendAnswerResolutionCopying(.fromWire(.from(42)), .{ .fulfill = .{
                .reference = .{ .far = model.FarRef.object(9) },
            } });
            // Releasing the first call's import triggers collection inside
            // this drain, before the second call has reached outbound admission.
            try pump(&peer);
            var calls: usize = 0;
            while (peer.takeOutbound()) |value| {
                var frame = value;
                defer frame.deinit();
                const body = try codec.dispatch.decodeBodyForProfile(codec_id, profile, frame.view());
                if (body != .deliver) continue;
                try std.testing.expectEqual(@as(u64, 9), body.deliver.target.near.export_position.int());
                try std.testing.expectEqualStrings(if (calls == 0) "first" else "second", (try body.deliver.args.at(0)).string);
                if (calls == 1) {
                    const argument = try body.deliver.args.at(1);
                    try std.testing.expect(argument.reference == .far);
                    try std.testing.expectEqual(projection.export_position, argument.reference.far.import_position.reinterpret(model.ExportPosition));
                }
                calls += 1;
            }
            try std.testing.expectEqual(@as(usize, 2), calls);
            try std.testing.expectEqual(@as(u64, 0), peer.session_state.importRefcount(.from(88)));
            try std.testing.expect(peer.session_state.inboundAnswerNamed(projection.answer_name) != null);

            // Forwarding transferred P into a new wire mention. Returning it
            // must reclaim the projection once the drained calls are gone.
            try receive(&peer, .{ .gc_export = .{
                .positions = &.{projection.export_position.int()},
                .deltas = &.{1},
            } });
            peer.session_state.collectLocalPromiseProjectionsNow();
            try std.testing.expect(!peer.session_state.hasExport(projection.export_position));
            try std.testing.expect(peer.session_state.inboundAnswerNamed(projection.answer_name) == null);
        }
    }
}
