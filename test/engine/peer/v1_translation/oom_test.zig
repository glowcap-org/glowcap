//! Encode-OOM rollback for V1.0 translation: a failed encode leaves no
//! published frame and no resolver authority, and a retry publishes exactly
//! once.

const std = @import("std");
const pancake = @import("pancake");

const codec = pancake.ocapn.codec;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const peer_fixture = @import("../../../support/peer_fixture.zig");

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
        try peer.sendCopying(.{ .resolve = .{
            .answer = .from(answer),
            .resolution = .{ .fulfill = .{ .integer = @intCast(offset) } },
        } });
    }
    for (0..64) |_| {
        try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        var outbound = peer.takeOutbound().?;
        outbound.deinit();
    }

    // Fail before the 65th POD carrier is consumed. The answer store still
    // owns the resolution, and the FIFO must still own the same front carrier.
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, peer.step());
    try std.testing.expect(peer.takeOutbound() == null);

    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var outbound = peer.takeOutbound() orelse return error.MissingRetriedResolve;
    outbound.deinit();

    // Drain the suffix and prove the retained carrier neither duplicated nor
    // displaced anything after the retry.
    var remaining: usize = 65;
    while (remaining != 0) : (remaining -= 1) {
        try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        var next = peer.takeOutbound() orelse return error.MissingQueuedResolve;
        next.deinit();
    }
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
}

test "V1.0 answered-deliver encode OOM rolls back resolver authority and retries" {
    var saw_post_mint_oom = false;
    var saw_success = false;

    for (0..32) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var peer = engine.testing.initRawOpenPeer(failing.allocator());
        defer peer.deinit();
        defer failing.fail_index = std.math.maxInt(usize);
        try peer.session_state.registerImport(.from(7));

        const answer = model.AnswerPosition.from(42);
        const first_resolver = peer.session_state.next_export_position;
        try peer.sendCopying(.{ .deliver = .{
            .target = .{ .far = model.FarRef.object(7) },
            .args = &.{.{ .bytes = "payload" }},
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
            try std.testing.expect(peer.takeOutbound() == null);
            try std.testing.expectEqual(
                @as(?model.ExportPosition, null),
                peer.session_state.outbound_resolver_link.getByValue(.{ .application_answer = answer }),
            );
            if (peer.session_state.next_export_position > first_resolver)
                saw_post_mint_oom = true;

            // The same staged carrier remains authoritative. Retrying mints one
            // fresh resolver and publishes exactly one answered deliver.
            try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        }

        const resolver = peer.session_state.outbound_resolver_link.getByValue(.{ .application_answer = answer }) orelse
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
        const first_resolver = peer.session_state.next_export_position;
        try peer.sendCopying(.{ .get = .{
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
                peer.session_state.outbound_resolver_link.getByValue(.{ .application_answer = answer }),
            );
            if (peer.session_state.next_export_position > first_resolver)
                saw_post_mint_oom = true;

            try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        }

        _ = peer.session_state.outbound_resolver_link.getByValue(.{ .application_answer = answer }) orelse
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
        .target = .{ .near = model.NearRef.object(session.BOOTSTRAP_POSITION) },
        .args = &.{},
        .resolve_me_desc = .{ .far = model.FarRef.object(7) },
    } };
    const deliver = model.view.Body.fromOwned(&message).deliver;
    const virtual = model.AnswerName.fromVirtual(.from(1));

    // The answer-table allocation succeeds; the following import-table
    // allocation fails. Neither half of the resolver-only authority may remain.
    try std.testing.expectError(error.OutOfMemory, engine.v1_0.registerPartnerResolver(&peer, deliver));
    try std.testing.expect(!peer.session_state.hasInboundAnswerNamed(virtual));
    try std.testing.expect(!peer.session_state.holdsImport(.from(7)));
    try std.testing.expect(peer.session_state.resolverForInboundAnswer(virtual) == null);

    // Monotonic positions are not reused after rollback. A clean retry installs
    // exactly one complete answer/resolver pair at the next virtual position.
    failing.fail_index = std.math.maxInt(usize);
    const retried = (try engine.v1_0.registerPartnerResolver(&peer, deliver)).?;
    try std.testing.expectEqual(virtual.virtual.int() + 1, retried.int());
    try std.testing.expect(peer.session_state.hasInboundAnswerNamed(.fromVirtual(retried)));
    try std.testing.expectEqual(
        @as(?model.ImportPosition, .from(7)),
        peer.session_state.resolverForInboundAnswer(.fromVirtual(retried)),
    );
}

test "a next answered operation publishes no partial pair on OOM" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var peer = peer_fixture.openPeer(failing.allocator());
    defer peer.deinit();
    defer failing.fail_index = std.math.maxInt(usize);
    try peer.session_state.registerImport(.from(7));

    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{.{ .bytes = "answer me" }},
        .answer = .from(42),
    } });

    // Let the operation frame allocate, then fail before the pair can be
    // published. The retry must still own and emit both messages.
    failing.fail_index = failing.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, peer.step());
    try std.testing.expect(peer.takeOutbound() == null);

    failing.fail_index = std.math.maxInt(usize);
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var operation = peer.takeOutbound().?;
    defer operation.deinit();
    var listener = peer.takeOutbound().?;
    defer listener.deinit();
    try std.testing.expect(peer.takeOutbound() == null);

    const operation_body = try codec.syrup.decodeBodyForProfile(.next, operation.view());
    const listener_body = try codec.syrup.decodeBodyForProfile(.next, listener.view());
    try std.testing.expect(operation_body == .deliver);
    try std.testing.expect(listener_body == .listen);
    try std.testing.expectEqual(@as(u64, 42), operation_body.deliver.answer.?.int());
    try std.testing.expectEqual(@as(u64, 42), listener_body.listen.target.promise.answer_position.int());
}
