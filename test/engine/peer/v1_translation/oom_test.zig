//! Allocation-failure rollback for V1.0 translation: a failed admission or
//! encode leaves no published frame and no resolver authority, and a retry
//! publishes exactly once.

const std = @import("std");
const glowcap = @import("glowcap");

const codec = glowcap.ocapn.codec;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const session = glowcap.ocapn.session;
const peer_fixture = @import("../../../support/peer_fixture.zig");

fn drainCallbackPair(peer: *engine.Peer, resolver_position: u64) !void {
    var callback = peer.takeOutbound() orelse return error.MissingResolverCallback;
    callback.deinit();
    var release = peer.takeOutbound() orelse return error.MissingResolverRelease;
    defer release.deinit();
    const body = try codec.syrup.decodeBody(release.view());
    try std.testing.expect(body == .gc_export);
    try std.testing.expectEqual(resolver_position, try body.gc_export.positions.at(0));
    try std.testing.expectEqual(@as(u64, 1), try body.gc_export.deltas.at(0));
}

test "settled-answer encode OOM leaves its carrier queued and emits exactly once" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var peer = engine.testing.initRawOpenPeer(failing.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Queue 130 store-backed carriers, then consume 64. The next encode runs
    // with a long dead prefix, proving the borrowed-front path does not need to
    // mutate or compact the FIFO before its fallible consequence succeeds.
    for (0..130) |offset| {
        const answer = 1_000 + offset;
        const wire = try std.fmt.allocPrint(
            std.testing.allocator,
            "<10'op:deliver<11'desc:export7+>[]{d}+<19'desc:import-promise{d}+>>",
            .{ answer, 2_000 + offset },
        );
        defer std.testing.allocator.free(wire);
        try peer.recvBorrowed(.{ .bytes = wire, .shape = .byte });
        var event = peer.pollEvent().?;
        event.deinit();
        try peer.sendBorrowed(.{ .resolve = .{
            .answer = .from(answer),
            .resolution = .{ .fulfill = .{ .integer = @intCast(offset) } },
        } });
    }
    for (0..64) |offset| {
        try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        try drainCallbackPair(&peer, 2_000 + offset);
    }

    // Fail before the 65th POD carrier is consumed. The answer store still
    // owns the resolution, and the FIFO must still own the same front carrier.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, peer.step());
    try std.testing.expect(peer.takeOutbound() == null);

    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try drainCallbackPair(&peer, 2_064);

    // Drain the suffix and prove the retained carrier neither duplicated nor
    // displaced anything after the retry.
    for (65..130) |offset| {
        try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        try drainCallbackPair(&peer, 2_000 + offset);
    }
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
}

test "V1.0 answered-deliver admission OOM rolls back resolver authority and retries" {
    var saw_post_mint_oom = false;
    var saw_success = false;

    for (0..32) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var peer = engine.testing.initRawOpenPeer(failing.allocator());
        defer peer.deinit();
        defer failing.fail_index = std.math.maxInt(usize);
        try peer.session_state.registerImport(.from(7));

        const answer = model.AnswerPosition.from(42);
        const minted_before = peer.session_state.exports.rows.capacityUsed();
        const deliver: model.Message = .{ .deliver = .{
            .target = .{ .far = model.FarRef.object(7) },
            .args = &.{.{ .bytes = "payload" }},
            .answer = answer,
        } };

        // Admission mints the resolver and encodes the frame, so an
        // allocation failure lands on the send and leaves nothing behind.
        failing.fail_index = failing.alloc_index + offset;
        const attempt = peer.sendBorrowed(deliver);
        failing.fail_index = std.math.maxInt(usize);

        if (attempt) |_| {
            saw_success = true;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(peer.pending_send.isEmpty());
            try std.testing.expect(peer.session_state.outboundAnswer(answer) == null);
            try std.testing.expectEqual(
                @as(?model.ExportPosition, null),
                peer.session_state.resolverExportForAnswer(answer),
            );
            // A retracted mint returns its slot to the free list, but the
            // vector it grew keeps the slot, so growth shows the sweep
            // crossed the resolver mint.
            if (peer.session_state.exports.rows.capacityUsed() > minted_before)
                saw_post_mint_oom = true;

            // The refusal committed nothing, so the same send retries,
            // mints one fresh resolver, and queues exactly one answered deliver.
            try peer.sendBorrowed(deliver);
        }

        try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        const resolver = peer.session_state.resolverExportForAnswer(answer) orelse
            return error.MissingRetriedResolver;
        try std.testing.expect(peer.session_state.exportRefcount(resolver) != 0);
        var frame = peer.takeOutbound() orelse return error.MissingRetriedDeliver;
        frame.deinit();
        try std.testing.expect(peer.takeOutbound() == null);
        try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    }

    try std.testing.expect(saw_post_mint_oom);
    try std.testing.expect(saw_success);
}

test "V1.0 projection encode OOM publishes neither half and retries atomically" {
    var saw_post_mint_oom = false;
    var saw_success = false;

    for (0..40) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var peer = engine.testing.initRawOpenPeer(failing.allocator());
        defer peer.deinit();
        defer failing.fail_index = std.math.maxInt(usize);
        try peer.session_state.registerImport(.from(9));

        const answer = model.AnswerPosition.from(5);
        const minted_before = peer.session_state.exports.rows.capacityUsed();
        try peer.sendBorrowed(.{ .get = .{
            .receiver = .{ .far = model.FarRef.object(9) },
            .field = "name",
            .answer = answer,
        } });

        failing.fail_index = failing.alloc_index + offset;
        const attempt = peer.step();
        failing.fail_index = std.math.maxInt(usize);

        if (attempt) |outcome| {
            saw_success = true;
            try std.testing.expectEqual(engine.StepOutcome.progress, outcome);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            // The projection and mandatory listener are one publication: an
            // allocator failure may expose neither, and no resolver link may
            // survive for a mention the partner never received.
            try std.testing.expect(peer.takeOutbound() == null);
            try std.testing.expectEqual(
                @as(?model.ExportPosition, null),
                peer.session_state.resolverExportForAnswer(answer),
            );
            // A retracted mint returns its slot to the free list, but the
            // vector it grew keeps the slot, so growth shows the sweep
            // crossed the resolver mint.
            if (peer.session_state.exports.rows.capacityUsed() > minted_before)
                saw_post_mint_oom = true;

            try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        }

        _ = peer.session_state.resolverExportForAnswer(answer) orelse
            return error.MissingProjectionResolver;
        var projection = peer.takeOutbound() orelse return error.MissingProjectionFrame;
        projection.deinit();
        var listener = peer.takeOutbound() orelse return error.MissingProjectionListener;
        listener.deinit();
        try std.testing.expect(peer.takeOutbound() == null);
        try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    }

    try std.testing.expect(saw_post_mint_oom);
    try std.testing.expect(saw_success);
}

test "V1.0 resolver-only registration rolls back its virtual answer on OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var peer = engine.Peer.init(failing.allocator());
    defer {
        failing.fail_index = std.math.maxInt(usize);
        peer.deinit();
    }
    peer.session_state.captp_version = .v1_0;

    const message: model.Message = .{ .deliver = .{
        .target = .{ .near = model.NearRef.object(session.bootstrap_position) },
        .args = &.{},
        .resolve_me_desc = .{ .far = model.FarRef.object(7) },
    } };
    const deliver = model.view.Body.fromOwned(&message).deliver;
    const virtual = model.AnswerName.fromVirtual(.from(1));

    // The answer-table allocation succeeds; the following import-table
    // allocation fails. Neither half of the resolver-only authority may remain.
    try std.testing.expectError(error.OutOfMemory, peer.session_state.prepareDeliveryResolver(&deliver));
    try std.testing.expect(!peer.session_state.hasInboundAnswerNamed(virtual));
    try std.testing.expect(!peer.session_state.holdsImport(.from(7)));
    try std.testing.expect(peer.session_state.resolverForInboundAnswer(virtual) == null);

    // Preparation committed nothing, including the virtual-answer cursor. A
    // clean retry therefore commits the same identity, not a skipped tombstone.
    failing.fail_index = std.math.maxInt(usize);
    var prepared = (try peer.session_state.prepareDeliveryResolver(&deliver)).?;
    const retried = prepared.virtualAnswer().?;
    // The frame's introduced-import transaction takes the resolver's retain
    // before the commit adopts it; this unit test stands in for that step.
    try peer.session_state.registerImport(.from(7));
    prepared.commit(&peer.session_state);
    try std.testing.expectEqual(virtual.virtual.int(), retried.int());
    try std.testing.expect(peer.session_state.hasInboundAnswerNamed(.fromVirtual(retried)));
    try std.testing.expectEqual(
        @as(?model.ImportPosition, .from(7)),
        peer.session_state.resolverForInboundAnswer(.fromVirtual(retried)),
    );
}

test "resolver-only frames publish no authority on allocator refusal in either profile" {
    inline for (.{ model.CaptpVersion.v1_0, model.CaptpVersion.next }) |profile| {
        var saw_late_failure = false;
        var saw_success = false;

        for (0..32) |offset| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            var peer = engine.testing.initRawOpenPeer(failing.allocator());
            defer peer.deinit();
            peer.session_state.captp_version = profile;
            try peer.session_state.registerExport(.from(7));

            const first_allocation = failing.alloc_index;
            failing.fail_index = first_allocation + offset;
            const attempt = peer.recvBorrowed(.{
                .bytes = if (profile == .v1_0) "<10'op:deliver<11'desc:export7+>[]f<19'desc:import-promise99+>>" else "<10'op:deliver<11'desc:export7+>[]f<19'desc:import-promise99+>3+>",
                .shape = .byte,
            });
            failing.fail_index = std.math.maxInt(usize);

            if (attempt) |_| {
                saw_success = true;
                try std.testing.expect(peer.session_state.hasInboundAnswerNamed(.fromVirtual(.from(1))));
                if (profile == .v1_0) {
                    try std.testing.expectEqual(@as(?model.ImportPosition, .from(99)), peer.session_state.resolverForInboundAnswer(.fromVirtual(.from(1))));
                } else {
                    const target = peer.session_state.answerTargetNamed(.fromVirtual(.from(1))).?;
                    const payload = peer.session_state.answerPayloadForTarget(target).?;
                    try std.testing.expectEqual(@as(usize, 1), payload.listeners.len());
                    try std.testing.expectEqual(@as(u64, 1), peer.session_state.importRefcount(.from(99)));
                }
                var event = peer.pollEvent() orelse return error.MissingDeliverEvent;
                event.deinit();
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                if (offset > 2) saw_late_failure = true;
                try std.testing.expect(peer.pollEvent() == null);
                try std.testing.expect(!peer.session_state.hasInboundAnswerNamed(.fromVirtual(.from(1))));
                try std.testing.expect(!peer.session_state.hasImport(.from(99)));
                try std.testing.expect(peer.session_state.resolverForInboundAnswer(.fromVirtual(.from(1))) == null);
                try std.testing.expectEqual(@as(u64, 1), peer.session_state.next_virtual_inbound_answer);
            }
        }

        try std.testing.expect(saw_late_failure);
        try std.testing.expect(saw_success);
    }
}

test "V1.0 pipelined deliver commits queue imports answer and resolver together" {
    var saw_late_failure = false;
    var saw_success = false;

    for (0..40) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var peer = engine.testing.initRawOpenPeer(failing.allocator());
        defer peer.deinit();
        try peer.session_state.installInboundAnswer(.from(42));

        const first_allocation = failing.alloc_index;
        failing.fail_index = first_allocation + offset;
        const attempt = peer.recvBorrowed(.{
            .bytes = "<10'op:deliver<11'desc:answer42+>[<18'desc:import-object77+>]43+<19'desc:import-promise99+>>",
            .shape = .byte,
        });
        failing.fail_index = std.math.maxInt(usize);

        if (attempt) |_| {
            saw_success = true;
            try std.testing.expect(peer.pollEvent() == null);
            try std.testing.expectEqual(@as(usize, 1), peer.session_state.inboundAnswer(.from(42)).?.queued_calls);
            try std.testing.expect(peer.session_state.hasInboundAnswer(.from(43)));
            try std.testing.expect(peer.session_state.hasImport(.from(77)));
            try std.testing.expect(peer.session_state.hasImport(.from(99)));
            try std.testing.expectEqual(
                @as(?model.ImportPosition, .from(99)),
                peer.session_state.resolverForInboundAnswer(.fromWire(.from(43))),
            );
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            if (offset > 3) saw_late_failure = true;
            try std.testing.expect(peer.pollEvent() == null);
            try std.testing.expectEqual(@as(usize, 0), peer.session_state.inboundAnswer(.from(42)).?.queued_calls);
            try std.testing.expect(!peer.session_state.hasInboundAnswer(.from(43)));
            try std.testing.expect(!peer.session_state.hasImport(.from(77)));
            try std.testing.expect(!peer.session_state.hasImport(.from(99)));
            try std.testing.expect(peer.session_state.resolverForInboundAnswer(.fromWire(.from(43))) == null);
        }
    }

    try std.testing.expect(saw_late_failure);
    try std.testing.expect(saw_success);
}

test "next pipelined deliver prepares shortening with queue authority atomically" {
    var inbound = try codec.syrup.encodeMessageForProfile(std.testing.allocator, .next, .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .reference = .{ .near = model.NearRef.promise(77) } }},
        .answer = .from(43),
        .resolve_me_desc = .{ .near = model.NearRef.object(99) },
    } });
    defer inbound.deinit();
    var saw_late_failure = false;
    var saw_success = false;

    for (0..48) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var peer = peer_fixture.openPeer(failing.allocator());
        defer {
            failing.fail_index = std.math.maxInt(usize);
            peer.deinit();
        }
        try peer.session_state.installInboundAnswer(.from(42));
        const baseline_exports = peer.session_state.exports.len();

        failing.fail_index = failing.alloc_index + offset;
        const attempt = peer.recvBorrowed(inbound.view());
        failing.fail_index = std.math.maxInt(usize);

        if (attempt) |_| {
            saw_success = true;
            try std.testing.expectEqual(
                @as(usize, 1),
                peer.session_state.inboundAnswer(.from(42)).?.queued_calls,
            );
            try std.testing.expect(peer.session_state.hasInboundAnswer(.from(43)));
            try std.testing.expect(peer.session_state.hasImport(.from(77)));
            try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
            var listener = peer.takeOutbound() orelse return error.MissingShorteningListener;
            listener.deinit();
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            if (offset > 3) saw_late_failure = true;
            try std.testing.expectEqual(
                @as(usize, 0),
                peer.session_state.inboundAnswer(.from(42)).?.queued_calls,
            );
            try std.testing.expect(!peer.session_state.hasInboundAnswer(.from(43)));
            try std.testing.expect(!peer.session_state.hasImport(.from(77)));
            try std.testing.expectEqual(baseline_exports, peer.session_state.exports.len());
            try std.testing.expect(peer.pollEvent() == null);
        }
    }

    try std.testing.expect(saw_late_failure);
    try std.testing.expect(saw_success);
}

test "a next answered operation publishes no partial subscription on OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var peer = peer_fixture.openPeer(failing.allocator());
    defer peer.deinit();
    defer failing.fail_index = std.math.maxInt(usize);
    try peer.session_state.registerImport(.from(7));

    const deliver: model.Message = .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{.{ .bytes = "answer me" }},
        .answer = .from(42),
    } };

    // Refuse admission before its complete inline subscription is published.
    // No row, answer, or resolver may survive the refusal.
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, peer.sendBorrowed(deliver));
    try std.testing.expect(peer.pending_send.isEmpty());
    try std.testing.expect(peer.session_state.outboundAnswer(.from(42)) == null);
    try std.testing.expect(peer.takeOutbound() == null);

    failing.fail_index = std.math.maxInt(usize);
    try peer.sendBorrowed(deliver);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var operation = peer.takeOutbound().?;
    defer operation.deinit();
    try std.testing.expect(peer.takeOutbound() == null);
    const operation_body = try codec.syrup.decodeBodyForProfile(.next, operation.view());
    try std.testing.expect(operation_body == .deliver);
    try std.testing.expectEqual(@as(u64, 42), operation_body.deliver.answer.?.int());
    try std.testing.expect(operation_body.deliver.resolve_me_desc != null);
    try std.testing.expectEqual(model.ListenMode.shortening_or_settling, operation_body.deliver.listen_mode);
}
