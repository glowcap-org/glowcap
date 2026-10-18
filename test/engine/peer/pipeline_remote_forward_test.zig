//! Engine remote pipeline forwarding against the draft delivery contract:
//! a queued call must reach the resolved object and keep its original reply.
const std = @import("std");
const glowcap = @import("glowcap");
const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const session = glowcap.ocapn.session;
const fixture = @import("../../support/peer_fixture.zig");

fn receive(peer: *engine.Peer, message: model.Message) !void {
    var frame = try codec.dispatch.encodeMessageForProfile(peer.session_state.codec, peer.allocator, peer.session_state.captp_version, message);
    defer frame.deinit();
    try peer.recvBorrowed(frame.view());
}

fn drainUntilCall(peer: *engine.Peer, target: u64) !model.Message {
    var turns: usize = 0;
    while (turns < 24) : (turns += 1) {
        _ = try peer.step();
        while (peer.takeOutbound()) |out| {
            var frame = out;
            defer frame.deinit();
            const body = try codec.dispatch.decodeBodyForProfile(peer.session_state.codec, peer.session_state.captp_version, frame.view());
            if (body == .deliver and body.deliver.target == .near and body.deliver.target.near.export_position.int() == target)
                return body.toOwned(peer.allocator);
        }
    }
    return error.ForwardedCallMissing;
}

fn checkForward(profile: model.CaptpVersion, codec_id: model.CodecId, wire_answer: bool, release_first: bool, mode: model.ListenMode) !void {
    var peer = fixture.openPeerWith(std.testing.allocator, .{ .captp_version = profile });
    defer peer.deinit();
    peer.session_state.codec = codec_id;
    try peer.session_state.installInboundAnswer(.from(42));
    try peer.session_state.registerImport(.from(9));
    // A question in the opposite direction deliberately has the same number.
    try peer.session_state.installOutboundAnswer(.from(43));
    try receive(&peer, .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{ .{ .string = "ping" }, .{ .reference = .{ .near = model.NearRef.object(77) } }, .{ .reference = .{ .near = model.NearRef.object(77) } } },
        .answer = if (wire_answer) .from(43) else null,
        .resolve_me_desc = .{ .near = model.NearRef.object(99) },
        .listen_mode = mode,
    } });
    if (mode == .shortening_only) try receive(&peer, .{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(43) } },
        .listener = .{ .near = model.NearRef.object(100) },
        .mode = .settling_only,
    } });
    try peer.sendBorrowed(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(9) } } },
    } });
    const forwarded = try drainUntilCall(&peer, 9);
    defer model.freeMessage(peer.allocator, forwarded);
    try std.testing.expectEqual(@as(?model.AnswerPosition, null), forwarded.deliver.answer);
    try std.testing.expect(forwarded.deliver.resolve_me_desc.? == .far);
    const resolver = forwarded.deliver.resolve_me_desc.?.far.import_position.int();
    try std.testing.expectEqualStrings("ping", forwarded.deliver.args[0].string);
    try std.testing.expectEqual(@as(u64, 0), peer.session_state.importRefcount(.from(77)));
    if (wire_answer and release_first) {
        try receive(&peer, .{ .gc_answer = .{ .positions = &.{43} } });
        try peer.session_state.installInboundAnswer(.from(43));
    }
    try receive(&peer, .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(resolver) },
        .args = &.{ .{ .symbol = "fulfill" }, .{ .list = &.{ .{ .string = "pong" }, .{ .reference = .{ .near = model.NearRef.object(88) } }, .{ .reference = .{ .near = model.NearRef.object(88) } } } } },
    } });
    const reply = try drainUntilCall(&peer, if (mode == .shortening_only) 100 else 99);
    defer model.freeMessage(peer.allocator, reply);
    try std.testing.expectEqualStrings("fulfill", reply.deliver.args[0].symbol);
    try std.testing.expectEqualStrings("pong", reply.deliver.args[1].list[0].string);
    try std.testing.expectEqual(@as(u64, 2), peer.session_state.importRefcount(.from(88)));
    try std.testing.expectEqual(@as(u64, 0), peer.session_state.importReleasable(.from(88)));
    if (wire_answer and !release_first) try receive(&peer, .{ .gc_answer = .{ .positions = &.{43} } });
    var released_result: u64 = 0;
    for (0..24) |_| {
        _ = try peer.step();
        while (peer.takeOutbound()) |out| {
            var frame = out;
            defer frame.deinit();
            const body = try codec.dispatch.decodeBodyForProfile(codec_id, profile, frame.view());
            if (body == .gc_export) {
                var positions = body.gc_export.positions.iterator();
                var deltas = body.gc_export.deltas.iterator();
                while (try positions.next()) |position| {
                    const delta = (try deltas.next()).?;
                    if (position == 88) released_result += delta;
                }
            }
        }
    }
    try std.testing.expectEqual(@as(u64, 2), released_result);
    try std.testing.expectEqual(@as(u64, 0), peer.session_state.importRefcount(.from(88)));
    try std.testing.expectEqual(@as(usize, 0), peer.session_state.import_release_outbox.?.active_batches);
    try std.testing.expectEqual(session.AnswerStatus.pending, peer.session_state.outboundAnswer(.from(43)).?.status);
    if (wire_answer and release_first)
        try std.testing.expectEqual(session.AnswerStatus.pending, peer.session_state.inboundAnswer(.from(43)).?.status);
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        defer event.deinit();
        try std.testing.expect(event.kind() != .resolve);
    }
}

test "remote pipelined replies preserve direction and incarnation in both profiles and codecs" {
    inline for (.{ model.CaptpVersion.v1_0, model.CaptpVersion.next }) |profile| {
        inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec_id| {
            try checkForward(profile, codec_id, false, false, .shortening_or_settling);
            try checkForward(profile, codec_id, true, false, .shortening_or_settling);
            try checkForward(profile, codec_id, true, true, .shortening_or_settling);
            if (profile == .next) try checkForward(profile, codec_id, true, false, .shortening_only);
        }
    }
}

fn prepareOwnedResult(allocator: std.mem.Allocator) !void {
    var state = session.Session.init(allocator);
    defer state.deinit();
    try state.registerImport(.from(88));
    try state.registerImport(.from(88));
    const releases = session.ImportRelease;
    const batch = (try releases.prepare(&state, &.{ .from(88), .from(88) })).?;
    batch.adopt(&state);
    batch.ready();
    try std.testing.expectEqual(@as(u64, 0), state.importReleasable(.from(88)));
}

test "stored forwarding import release preparation is leak free at every allocation refusal" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, prepareOwnedResult, .{});
}

test "stored forwarding import release retries allocator refusal without spending its ownership" {
    const FailAfterAllocator = @import("harness.zig").FailAfterAllocator;
    var failing = FailAfterAllocator{ .backing = std.testing.allocator, .fail_after = std.math.maxInt(usize) };
    var peer = fixture.openPeer(failing.allocator());
    defer peer.deinit();
    try peer.session_state.registerImport(.from(88));
    try peer.session_state.registerImport(.from(88));
    const releases = session.ImportRelease;
    const batch = (try releases.prepare(&peer.session_state, &.{ .from(88), .from(88) })).?;
    batch.adopt(&peer.session_state);
    batch.ready();
    const charge = peer.session_state.retained_sent_answer_bytes;
    failing.fail_after = failing.allocation_count;
    try std.testing.expectError(error.OutOfMemory, peer.step());
    try std.testing.expect(!peer.sessionIsClosed());
    try std.testing.expectEqual(charge, peer.session_state.retained_sent_answer_bytes);
    try std.testing.expectEqual(@as(u64, 2), peer.session_state.importRefcount(.from(88)));
    try std.testing.expect(peer.session_state.import_release_outbox.?.head == batch);
    failing.fail_after = std.math.maxInt(usize);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var frame = peer.takeOutbound().?;
    defer frame.deinit();
    const body = try codec.dispatch.decodeBodyForProfile(peer.session_state.codec, .next, frame.view());
    try std.testing.expect(body == .gc_export);
    try std.testing.expectEqual(@as(usize, 2), body.gc_export.positions.len());
    try std.testing.expectEqual(@as(u64, 88), try body.gc_export.positions.at(0));
    try std.testing.expectEqual(@as(u64, 88), try body.gc_export.positions.at(1));
    try std.testing.expectEqual(@as(usize, 0), peer.session_state.retained_sent_answer_bytes);
    try std.testing.expectEqual(@as(u64, 0), peer.session_state.importRefcount(.from(88)));
}

test "stored forwarding import release shares the retained byte and live answer bounds" {
    var state = session.Session.init(std.testing.allocator);
    defer state.deinit();
    const releases = session.ImportRelease;
    state.limits.max_retained_sent_answer_bytes = 0;
    try std.testing.expectError(error.RetainedAnswerCapExceeded, releases.prepare(&state, &.{.from(88)}));
    try std.testing.expect(state.import_release_outbox == null);
    state.limits.max_retained_sent_answer_bytes = 1 << 24;
    state.limits.max_inbound_answers = 0;
    try std.testing.expectError(error.QueueCapExceeded, releases.prepare(&state, &.{.from(88)}));
    try std.testing.expectEqual(@as(usize, 0), state.retained_sent_answer_bytes);
    try std.testing.expectEqual(@as(usize, 0), state.import_release_outbox.?.active_batches);
}

test "a collected baseline reply still forwards the original call without borrowing a replacement question" {
    inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec_id| {
        var peer = fixture.openPeerWith(std.testing.allocator, .{ .captp_version = .v1_0 });
        defer peer.deinit();
        peer.session_state.codec = codec_id;
        try peer.session_state.installInboundAnswer(.from(42));
        try peer.session_state.registerImport(.from(9));
        try receive(&peer, .{ .deliver = .{
            .target = .{ .promise = .{ .answer_position = .from(42) } },
            .args = &.{.{ .string = "ping" }},
            .answer = .from(43),
        } });
        try receive(&peer, .{ .gc_answer = .{ .positions = &.{43} } });
        try peer.session_state.installInboundAnswer(.from(43));
        try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(42), .resolution = .{ .fulfill = .{ .reference = .{ .far = model.FarRef.object(9) } } } } });
        const forwarded = try drainUntilCall(&peer, 9);
        defer model.freeMessage(peer.allocator, forwarded);
        try std.testing.expect(forwarded.deliver.answer == null);
        try std.testing.expect(forwarded.deliver.resolve_me_desc == null);
        try std.testing.expectEqual(session.AnswerStatus.pending, peer.session_state.inboundAnswer(.from(43)).?.status);
        try std.testing.expect(!peer.sessionIsClosed());
        try std.testing.expect(peer.session_state.import_release_outbox == null);
        while (peer.pollEvent()) |event_in| {
            var event = event_in;
            event.deinit();
        }
    }
}

test "ready import releases respect pressure after already admitted work drains" {
    var peer = fixture.openPeer(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerImport(.from(9));
    try peer.sendBorrowed(.{ .deliver = .{ .target = .{ .far = model.FarRef.object(9) }, .args = &.{.{ .string = "pending" }} } });
    try peer.session_state.registerImport(.from(88));
    const releases = session.ImportRelease;
    const batch = (try releases.prepare(&peer.session_state, &.{.from(88)})).?;
    batch.adopt(&peer.session_state);
    batch.ready();
    peer.outbound_budget = 1;
    // Completion of an admitted carrier must not wait behind a new producer.
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try std.testing.expectError(error.OutboundBackpressure, peer.step());
    try std.testing.expectEqual(@as(u64, 1), peer.session_state.importRefcount(.from(88)));
    try std.testing.expect(peer.session_state.import_release_outbox.?.head == batch);
    var pending = peer.takeOutbound().?;
    pending.deinit();
    // An empty queue still refuses a release frame larger than its budget.
    try std.testing.expectError(error.OutboundBackpressure, peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
    peer.outbound_budget = std.math.maxInt(usize);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var released = peer.takeOutbound().?;
    released.deinit();
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expectEqual(@as(u64, 0), peer.session_state.importRefcount(.from(88)));
}

test "ready import releases flush an otherwise held answer release" {
    var peer = fixture.openPeer(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.installOutboundAnswer(.from(43));
    const reservation = try peer.reserveAnswerRelease();
    peer.publishAnswerRelease(reservation, peer.session_state.outboundAnswerTarget(.from(43)).?);
    try peer.session_state.registerImport(.from(88));
    const releases = session.ImportRelease;
    const batch = (try releases.prepare(&peer.session_state, &.{.from(88)})).?;
    batch.adopt(&peer.session_state);
    batch.ready();
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try std.testing.expect(peer.session_state.outboundAnswer(.from(43)) == null);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try std.testing.expectEqual(@as(u64, 0), peer.session_state.importRefcount(.from(88)));
    while (peer.takeOutbound()) |out| {
        var frame = out;
        frame.deinit();
    }
}

// Once an owned callback crosses dispatch, partial admission is terminal.
// Refusal must remain the exact observable failure rather than pretending
// that an accepted callback can be retried against its mutated Session.
test "forwarding callback allocation refusal closes its consumed frame with the exact failure" {
    const FailAfterAllocator = @import("harness.zig").FailAfterAllocator;
    inline for (.{ model.CaptpVersion.next, model.CaptpVersion.v1_0 }) |profile| {
        inline for (.{ model.CodecId.syrup, model.CodecId.capnp }) |codec_id| {
            var failures: usize = 0;
            var succeeded = false;
            for (0..64) |offset| {
                var failing = FailAfterAllocator{ .backing = std.testing.allocator, .fail_after = std.math.maxInt(usize) };
                var peer = fixture.openPeerWith(failing.allocator(), .{ .captp_version = profile });
                defer peer.deinit();
                peer.session_state.codec = codec_id;
                try peer.session_state.installInboundAnswer(.from(42));
                try peer.session_state.registerImport(.from(9));
                try receive(&peer, .{ .deliver = .{
                    .target = .{ .promise = .{ .answer_position = .from(42) } },
                    .args = &.{.{ .string = "ping" }},
                    .answer = .from(43),
                    .resolve_me_desc = .{ .near = model.NearRef.object(99) },
                } });
                try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(42), .resolution = .{
                    .fulfill = .{ .reference = .{ .far = model.FarRef.object(9) } },
                } } });
                const call = try drainUntilCall(&peer, 9);
                defer model.freeMessage(peer.allocator, call);
                const resolver = call.deliver.resolve_me_desc.?.far.import_position;
                const callback = try codec.dispatch.encodeMessageForProfile(codec_id, peer.allocator, profile, .{ .deliver = .{
                    .target = .{ .far = model.FarRef.object(resolver.int()) },
                    .args = &.{ .{ .symbol = "fulfill" }, .{ .list = &.{ .{ .string = "stored reply" }, .{ .reference = .{ .near = model.NearRef.object(88) } } } } },
                } });
                try peer.feedOwned(callback);
                failing.fail_after = failing.allocation_count + offset;
                if (peer.step()) |outcome| {
                    try std.testing.expectEqual(engine.StepOutcome.progress, outcome);
                    try std.testing.expect(!peer.sessionIsClosed());
                    succeeded = true;
                    break;
                } else |err| {
                    try std.testing.expectEqual(error.OutOfMemory, err);
                    try std.testing.expect(peer.sessionIsClosed());
                    const failure = peer.lastAbort() orelse return error.MissingFailure;
                    try std.testing.expectEqualStrings("OutOfMemory", failure.error_name);
                    failures += 1;
                }
            }
            try std.testing.expect(succeeded);
            try std.testing.expect(failures > 0);
        }
    }
}
