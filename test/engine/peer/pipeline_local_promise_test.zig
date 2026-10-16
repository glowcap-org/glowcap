//! Engine conformance: the pinned op:listen receiving contract forbids a
//! notification for another promise on the same peer until its result matches
//! the listen mode. Local projections pair an export with a virtual answer.
const std = @import("std");
const glowcap = @import("glowcap");
const peer_fixture = @import("../../support/peer_fixture.zig");
const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;

fn pump(peer: *engine.Peer) !void {
    for (0..64) |_| {
        if (try peer.step() != .progress) return;
    }
    return error.PumpDidNotQuiesce;
}

fn countCallbacks(peer: *engine.Peer, expected_position: ?u64) !usize {
    var count: usize = 0;
    while (peer.takeOutbound()) |value| {
        var frame = value;
        defer frame.deinit();
        const body = try codec.dispatch.decodeBodyForProfile(peer.session_state.codec, peer.session_state.captp_version, frame.view());
        if (body != .deliver) continue;
        count += 1;
        try std.testing.expectEqual(@as(u64, 99), body.deliver.target.near.export_position.int());
        try std.testing.expectEqualStrings("fulfill", (try body.deliver.args.at(0)).symbol);
        if (expected_position) |position| {
            const result = try body.deliver.args.at(1);
            try std.testing.expect(result == .reference);
            try std.testing.expectEqual(position, result.reference.position().?);
        }
    }
    return count;
}

fn exercise(profile: model.CaptpVersion, mode: model.ListenMode) !void {
    inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec_id| {
        for ([_]bool{ false, true }) |shortens| {
            var peer = peer_fixture.openPeerWith(std.testing.allocator, .{ .captp_version = profile });
            defer peer.deinit();
            peer.session_state.codec = codec_id;
            const projection = try peer.session_state.allocateLocalPromiseProjection();
            try peer.session_state.installInboundAnswer(.from(42));
            var listen = try codec.dispatch.encodeMessageForProfile(codec_id, peer.allocator, profile, .{ .listen = .{
                .target = .{ .promise = .{ .answer_position = .from(42) } },
                .listener = .{ .near = model.NearRef.object(99) },
                .mode = mode,
            } });
            defer listen.deinit();
            try peer.recvBorrowed(listen.view());
            while (peer.pollEvent()) |value| {
                var event = value;
                event.deinit();
            }

            try peer.sendAnswerResolutionCopying(.fromWire(.from(42)), .{ .fulfill = .{
                .reference = .{ .near = model.NearRef.promise(projection.export_position.int()) },
            } });
            try pump(&peer);
            // This is a valid session-owned unresolved promise, not a fresh
            // unpaired promise export. Its backing answer is still pending.
            try std.testing.expect(peer.session_state.inboundAnswerNamed(projection.answer_name) != null);
            try std.testing.expectEqual(@as(usize, 0), try countCallbacks(&peer, null));

            if (shortens) try peer.session_state.registerImport(.from(77)) else try peer.session_state.registerExport(.from(9));
            try peer.sendAnswerResolutionCopying(projection.answer_name, .{ .fulfill = .{ .reference = if (shortens)
                .{ .far = model.FarRef.promise(77) }
            else
                .{ .near = model.NearRef.object(9) } } });
            try pump(&peer);
            const should_fire = if (shortens) profile == .v1_0 or mode.wantsShortening() else mode.wantsSettling();
            try std.testing.expectEqual(@as(usize, @intFromBool(should_fire)), try countCallbacks(&peer, if (shortens) 77 else 9));
        }
    }
}

test "same-peer local promise chain preserves next shortening listener" {
    try exercise(.next, .shortening_only);
}

test "same-peer local promise chain preserves next combined listener" {
    try exercise(.next, .shortening_or_settling);
}

test "same-peer local promise chain preserves next settling listener" {
    try exercise(.next, .settling_only);
}

test "same-peer local promise chain preserves baseline combined listener" {
    try exercise(.v1_0, .shortening_or_settling);
}

test "same-peer local promise chain preserves baseline settling listener" {
    try exercise(.v1_0, .settling_only);
}

fn receive(peer: *engine.Peer, message: model.Message) !void {
    var frame = try codec.dispatch.encodeMessageForProfile(peer.session_state.codec, peer.allocator, peer.session_state.captp_version, message);
    defer frame.deinit();
    try peer.recvBorrowed(frame.view());
}

fn queuedCall(peer: *engine.Peer) !void {
    try receive(peer, .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .bytes = "queued" }},
        .answer = .from(43),
        .resolve_me_desc = .{ .near = model.NearRef.object(99) },
    } });
}

test "same-peer local promise chain reanchors queued calls until backing settlement" {
    inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec_id| {
        inline for (.{ model.CaptpVersion.next, model.CaptpVersion.v1_0 }) |profile| {
            var peer = peer_fixture.openPeerWith(std.testing.allocator, .{ .captp_version = profile });
            defer peer.deinit();
            peer.session_state.codec = codec_id;
            const projection = try peer.session_state.allocateLocalPromiseProjection();
            try peer.session_state.installInboundAnswer(.from(42));
            try peer.session_state.registerExport(.from(9));
            try queuedCall(&peer);
            try peer.sendAnswerResolutionCopying(.fromWire(.from(42)), .{
                .fulfill = .{
                    // Slot authority, rather than this object's descriptor kind,
                    // must identify the unresolved local promise.
                    .reference = .{ .near = model.NearRef.object(projection.export_position.int()) },
                },
            });
            try pump(&peer);
            try std.testing.expect(peer.pollEvent() == null);
            try peer.sendAnswerResolutionCopying(projection.answer_name, .{ .fulfill = .{
                .reference = .{ .near = model.NearRef.object(9) },
            } });
            try pump(&peer);
            var event = peer.pollEvent() orelse return error.MissingQueuedCall;
            defer event.deinit();
            try std.testing.expectEqual(@as(u64, 9), event.view().deliver.target.near.export_position.int());
            try std.testing.expectEqualStrings("queued", (try event.view().deliver.args.at(0)).bytes);
            try std.testing.expectEqual(@as(?model.AnswerPosition, .from(43)), event.view().deliver.answer);
        }
    }
}

test "same-peer local promise chain preserves late calls after backing settlement" {
    inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec_id| {
        var peer = peer_fixture.openPeer(std.testing.allocator);
        defer peer.deinit();
        peer.session_state.codec = codec_id;
        const projection = try peer.session_state.allocateLocalPromiseProjection();
        try peer.session_state.installInboundAnswer(.from(42));
        try peer.session_state.registerExport(.from(9));
        try peer.sendAnswerResolutionCopying(.fromWire(.from(42)), .{ .fulfill = .{
            .reference = .{ .near = model.NearRef.promise(projection.export_position.int()) },
        } });
        try pump(&peer);
        try peer.sendAnswerResolutionCopying(projection.answer_name, .{ .fulfill = .{
            .reference = .{ .near = model.NearRef.object(9) },
        } });
        try pump(&peer);
        try queuedCall(&peer);
        try pump(&peer);
        var event = peer.pollEvent() orelse return error.MissingLateQueuedCall;
        defer event.deinit();
        try std.testing.expectEqual(@as(u64, 9), event.view().deliver.target.near.export_position.int());
        try std.testing.expect(peer.session_state.inboundAnswerNamed(projection.answer_name) != null);
        try receive(&peer, .{ .gc_answer = .{ .positions = &.{42} } });
        try std.testing.expect(peer.session_state.inboundAnswerNamed(projection.answer_name) == null);
        try std.testing.expect(!peer.session_state.hasExport(projection.export_position));
    }
}

test "same-peer local promise chain detects cycles and enforces chain bound" {
    inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec_id| {
        for ([_]bool{ false, true }) |cycle| {
            var peer = peer_fixture.openPeer(std.testing.allocator);
            defer peer.deinit();
            peer.session_state.codec = codec_id;
            if (!cycle) peer.session_state.limits.max_resolution_chain = 1;
            const first = try peer.session_state.allocateLocalPromiseProjection();
            const second = try peer.session_state.allocateLocalPromiseProjection();
            try peer.session_state.installInboundAnswer(.from(42));
            try peer.session_state.registerExport(.from(9));
            try receive(&peer, .{ .listen = .{
                .target = .{ .promise = .{ .answer_position = .from(42) } },
                .listener = .{ .near = model.NearRef.object(99) },
                .mode = .shortening_or_settling,
            } });
            while (peer.pollEvent()) |value| {
                var event = value;
                event.deinit();
            }
            try peer.sendAnswerResolutionCopying(.fromWire(.from(42)), .{ .fulfill = .{
                .reference = .{ .near = model.NearRef.promise(first.export_position.int()) },
            } });
            try peer.sendAnswerResolutionCopying(first.answer_name, .{ .fulfill = .{
                .reference = .{ .near = model.NearRef.promise(second.export_position.int()) },
            } });
            try peer.sendAnswerResolutionCopying(second.answer_name, .{ .fulfill = .{
                .reference = .{ .near = if (cycle) model.NearRef.promise(first.export_position.int()) else model.NearRef.object(9) },
            } });
            try pump(&peer);
            var callbacks: usize = 0;
            while (peer.takeOutbound()) |value| {
                var frame = value;
                defer frame.deinit();
                const body = try codec.dispatch.decodeBodyForProfile(codec_id, .next, frame.view());
                if (body != .deliver) continue;
                callbacks += 1;
                try std.testing.expectEqualStrings("break", (try body.deliver.args.at(0)).symbol);
                try std.testing.expectEqualStrings(if (cycle) "promise resolution cycle" else "promise resolution chain exceeds max_resolution_chain", (try body.deliver.args.at(1)).symbol);
            }
            try std.testing.expectEqual(@as(usize, 1), callbacks);
            try receive(&peer, .{ .gc_answer = .{ .positions = &.{42} } });
            try std.testing.expect(peer.session_state.inboundAnswerNamed(first.answer_name) == null);
            try std.testing.expect(peer.session_state.inboundAnswerNamed(second.answer_name) == null);
            // Reclaiming the last projection retires the cold registry too.
            try std.testing.expect(peer.session_state.local_promises == null);
        }
    }
}

test "same-peer local promise chain retains nested capabilities until listener encoding" {
    inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec_id| {
        var peer = peer_fixture.openPeer(std.testing.allocator);
        defer peer.deinit();
        peer.session_state.codec = codec_id;
        const projection = try peer.session_state.allocateLocalPromiseProjection();
        try peer.session_state.installInboundAnswer(.from(42));
        try peer.sendAnswerResolutionCopying(.fromWire(.from(42)), .{ .fulfill = .{
            .list = &.{.{ .reference = .{ .near = model.NearRef.promise(projection.export_position.int()) } }},
        } });
        try pump(&peer);
        try peer.sendAnswerResolutionCopying(projection.answer_name, .{ .fulfill = .{ .bytes = "settled" } });
        try pump(&peer);
        try std.testing.expect(peer.session_state.hasExport(projection.export_position));
        try receive(&peer, .{ .listen = .{
            .target = .{ .promise = .{ .answer_position = .from(42) } },
            .listener = .{ .near = model.NearRef.object(99) },
            .mode = .shortening_or_settling,
        } });
        // The answer is now detached but its queued fire still borrows the
        // container. Collection must retain that discoverable payload root.
        try receive(&peer, .{ .gc_answer = .{ .positions = &.{42} } });
        try std.testing.expect(peer.session_state.hasExport(projection.export_position));
        try pump(&peer);
        var callbacks: usize = 0;
        while (peer.takeOutbound()) |value| {
            var frame = value;
            defer frame.deinit();
            const body = try codec.dispatch.decodeBodyForProfile(codec_id, .next, frame.view());
            if (body != .deliver) continue;
            callbacks += 1;
            const container = try body.deliver.args.at(1);
            const cap = try container.list.at(0);
            try std.testing.expectEqual(projection.export_position.int(), cap.reference.far.import_position.int());
        }
        try std.testing.expectEqual(@as(usize, 1), callbacks);
        // Publication transferred the root to its actual wire mention.
        try std.testing.expect(peer.session_state.hasExport(projection.export_position));
        try receive(&peer, .{ .gc_export = .{
            .positions = &.{projection.export_position.int()},
            .deltas = &.{1},
        } });
        try std.testing.expect(!peer.session_state.hasExport(projection.export_position));
        try std.testing.expect(peer.session_state.inboundAnswerNamed(projection.answer_name) == null);
    }
}

fn expectNestedCallback(peer: *engine.Peer, listener: u64, projection: model.ExportPosition) !void {
    var callbacks: usize = 0;
    while (peer.takeOutbound()) |value| {
        var frame = value;
        defer frame.deinit();
        const body = try codec.dispatch.decodeBodyForProfile(peer.session_state.codec, peer.session_state.captp_version, frame.view());
        if (body != .deliver) continue;
        callbacks += 1;
        try std.testing.expectEqual(listener, body.deliver.target.near.export_position.int());
        try std.testing.expectEqualStrings("fulfill", (try body.deliver.args.at(0)).symbol);
        const container = try body.deliver.args.at(1);
        const cap = try container.list.at(0);
        try std.testing.expectEqual(projection.int(), cap.reference.far.import_position.int());
    }
    try std.testing.expectEqual(@as(usize, 1), callbacks);
}

test "nested local promise stays discoverable between detached listener carriers" {
    inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec_id| {
        var peer = peer_fixture.openPeer(std.testing.allocator);
        defer peer.deinit();
        peer.session_state.codec = codec_id;
        const projection = try peer.session_state.allocateLocalPromiseProjection();
        try peer.session_state.installInboundAnswer(.from(42));
        const target = peer.session_state.answerTargetNamed(.fromWire(.from(42))).?;
        try peer.sendAnswerResolutionCopying(.fromWire(.from(42)), .{ .fulfill = .{
            .list = &.{.{ .reference = .{ .near = model.NearRef.promise(projection.export_position.int()) } }},
        } });
        try pump(&peer);
        try peer.sendAnswerResolutionCopying(projection.answer_name, .{ .fulfill = .{ .bytes = "settled" } });
        try pump(&peer);
        for ([_]u64{ 99, 100 }) |listener| try receive(&peer, .{ .listen = .{
            .target = .{ .promise = .{ .answer_position = .from(42) } },
            .listener = .{ .near = model.NearRef.object(listener) },
            .mode = .shortening_or_settling,
        } });
        try receive(&peer, .{ .gc_answer = .{ .positions = &.{42} } });
        const payload = peer.session_state.answerPayloadForTarget(target).?;
        // One registry owner plus two independently queued listener carriers.
        try std.testing.expectEqual(@as(u32, 3), payload.refs);
        try std.testing.expect(peer.session_state.detached_inbound_answers != null);

        try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        try expectNestedCallback(&peer, 99, projection.export_position);
        // Releasing the first carrier must preserve the registry while the
        // second still borrows this exact payload's nested capability tree.
        try std.testing.expect(peer.session_state.answerPayloadForTarget(target) == payload);
        try std.testing.expectEqual(@as(u32, 2), payload.refs);
        peer.session_state.collectLocalPromiseProjections();
        try std.testing.expect(peer.session_state.hasExport(projection.export_position));

        try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        try expectNestedCallback(&peer, 100, projection.export_position);
        try std.testing.expect(peer.session_state.answerPayloadForTarget(target) == null);
        try std.testing.expect(peer.session_state.detached_inbound_answers == null);
        try pump(&peer);
        try std.testing.expect(peer.takeOutbound() == null);
        // Both callbacks granted a real wire mention. Only their final
        // release can reclaim P after the detached registry has disappeared.
        try receive(&peer, .{ .gc_export = .{
            .positions = &.{projection.export_position.int()},
            .deltas = &.{2},
        } });
        try std.testing.expect(!peer.session_state.hasExport(projection.export_position));
        try std.testing.expect(peer.session_state.inboundAnswerNamed(projection.answer_name) == null);
    }
}
