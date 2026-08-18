//! Promise pipelining through one Peer: calls queue on unresolved answers
//! and deliver locally on settlement, and multi-hop delivers decompose into
//! single-hop chains.

const std = @import("std");
const pancake = @import("pancake");

const codec = pancake.ocapn.codec;
const foundation = pancake.foundation;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const peer_fixture = @import("../../support/peer_fixture.zig");

const harness = @import("harness.zig");
const FailAfterAllocator = harness.FailAfterAllocator;
const CountingAllocator = harness.CountingAllocator;

test "two peers exchange deliver, resolve, and gc-export frames" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    // p2 introduces its export 7 to p1 on the wire (an answer-less deliver
    // carrying the near mention), so p1's later release is a legal wire-delta
    // and p1 holds the import the introduction installed.
    try p1.session_state.registerExport(.from(9));
    try p2.session_state.registerImport(.from(9));
    try p2.session_state.registerExport(.from(7));
    try p2.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(9) } },
            .args = &.{.{ .reference = .{ .near = .{ .export_position = .from(7) } } }},
            .answer = null,
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try p1.feedOwned(p2.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try std.testing.expect(p1.session_state.hasImport(.from(7)));
    const granted = p2.session_state.exportRefcount(.from(7));

    try p1.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(42),
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    const deliver_frame = p1.takeOutbound().?;
    try p2.feedOwned(deliver_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try std.testing.expect(p2.session_state.inboundAnswer(.from(42)) != null);

    try p2.sendCopying(.{
        .resolve = .{
            .answer = .from(42),
            .resolution = .{ .fulfill = .{ .void = {} } },
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    const resolve_frame = p2.takeOutbound().?;
    try p1.feedOwned(resolve_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, p1.session_state.outboundAnswer(.from(42)).?.status);

    // p1 releases its import of p2's export@7 via op:gc-exports; the inbound
    // gc-exports on p2 returns the wire mention, and the export row survives
    // at its local baseline for re-export.
    try p1.sendCopying(.{ .gc_export = .{ .positions = &.{7}, .deltas = &.{1} } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    const gc_frame = p1.takeOutbound().?;
    try p2.feedOwned(gc_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try std.testing.expect(!p1.session_state.hasImport(.from(7)));
    try std.testing.expect(p2.session_state.hasExport(.from(7)));
    try std.testing.expectEqual(granted - 1, p2.session_state.exportRefcount(.from(7)));
}

test "a second inbound op:resolve for an already-settled outbound answer is refused" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));

    // p1 sends an answered deliver, installing outbound answer 42.
    try p1.sendCopying(.{
        .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{.{ .bytes = "hello" }},
            .answer = .from(42),
        },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    const deliver_frame = p1.takeOutbound().?;
    try p2.feedOwned(deliver_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

    // The partner resolves answer 42 once; p1's outbound answer settles.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .void = {} } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    const resolve_frame = p2.takeOutbound().?;
    try p1.feedOwned(resolve_frame);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try std.testing.expectEqual(
        session.AnswerStatus.fulfilled,
        p1.session_state.outboundAnswer(.from(42)).?.status,
    );

    // A second op:resolve for the same already-settled answer is a partner
    // protocol violation. It must be refused (a protocol_error abort), not
    // re-settle the answer or re-introduce the fulfill payload's imports.
    try std.testing.expectError(
        session.Error.UnexpectedMessage,
        p1.recvBorrowed(.{ .bytes = "<10'op:resolve42+<15'resolve:fulfill<4'void>>>", .shape = .byte }),
    );
    try std.testing.expectEqual(
        session.AnswerStatus.fulfilled,
        p1.session_state.outboundAnswer(.from(42)).?.status,
    );
}

test "a pipelined call queues until its answer resolves, then delivers locally" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));

    // p1 delivers to p2's export, allocating answer 42.
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }

    // p1 pipelines a call against the unresolved answer (a promise target).
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

    // The pipelined call is held on the answer's queue, not surfaced as an event.
    try std.testing.expect(p2.pollEvent() == null);
    try std.testing.expectEqual(@as(usize, 1), p2.session_state.inboundAnswer(.from(42)).?.queued_calls);

    // p2 resolves answer 42 to a local export (#9); the queued call drains into
    // a local delivery against that export, carrying its original args + answer.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(9) } } } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var resolve_frame = p2.takeOutbound().?;
        resolve_frame.deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), p2.session_state.inboundAnswer(.from(42)).?.queued_calls);

    var local_event = p2.pollEvent().?;
    defer local_event.deinit();
    try std.testing.expectEqual(engine.EventKind.deliver, local_event.kind());
    const view = try local_event.view();
    // A local delivery to our export is wire-shaped as `<desc:export>`, which
    // decodes (receiver perspective, ADR-0010) to `.near{export_position=9}` — exactly
    // the shape a deliver to our export 9 carries when it arrives off the wire.
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(43)), view.deliver.answer);
    try std.testing.expectEqualStrings("ping", (try view.deliver.args.at(0)).bytes);

    // p2 now owes the forwarded call's answer (#43) as a fresh inbound answer.
    try std.testing.expect(p2.session_state.inboundAnswer(.from(43)) != null);
}

test "a call to a local promise export queues on its backing answer" {
    const allocator = std.testing.allocator;
    var caller = engine.Peer.init(allocator);
    defer caller.deinit();
    var receiver = engine.Peer.init(allocator);
    defer receiver.deinit();

    const projection = try receiver.session_state.allocateLocalPromiseProjection();
    const promise_export = projection.export_position;
    const backing_answer = projection.answer_name;
    try std.testing.expect(backing_answer == .virtual);
    // Grant the caller one wire mention of the promise export. Its import table
    // is kindless by design; the reference carries `.promise` on the wire.
    try receiver.session_state.exports.retain(allocator, promise_export);
    try caller.session_state.registerImport(promise_export.reinterpret(model.ImportPosition));

    try caller.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.promise(promise_export.int()) },
        .args = &.{.{ .bytes = "queued" }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try caller.step());
    try receiver.feedOwned(caller.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try receiver.step());

    try std.testing.expect(receiver.pollEvent() == null);
    try std.testing.expectEqual(
        @as(usize, 1),
        receiver.session_state.inboundAnswerNamed(backing_answer).?.queued_calls,
    );

    try receiver.sendAnswerResolutionCopying(
        backing_answer,
        .{ .fulfill = .{ .reference = .{ .near = model.NearRef.object(9) } } },
    );
    try std.testing.expectEqual(engine.StepOutcome.progress, try receiver.step());

    var delivered = receiver.pollEvent().?;
    defer delivered.deinit();
    const view = try delivered.view();
    try std.testing.expect(view == .deliver);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings("queued", (try view.deliver.args.at(0)).bytes);
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(43)), view.deliver.answer);

    // Settlement alone cannot retire an export the caller still holds.
    try std.testing.expect(receiver.session_state.hasExport(promise_export));
    try std.testing.expect(receiver.session_state.inboundAnswerNamed(backing_answer) != null);

    try caller.sendCopying(.{ .gc_export = .{
        .positions = &.{promise_export.int()},
        .deltas = &.{1},
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try caller.step());
    try receiver.feedOwned(caller.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try receiver.step());
    try std.testing.expect(!receiver.session_state.hasExport(promise_export));
    try std.testing.expect(receiver.session_state.inboundAnswerNamed(backing_answer) == null);
    try std.testing.expect(receiver.session_state.answerForLocalPromiseExport(promise_export) == null);
    try std.testing.expectError(
        session.Error.InvalidReference,
        receiver.sendAnswerResolutionCopying(backing_answer, .{ .fulfill = .{ .void = {} } }),
    );
}

test "a local promise projection survives wire GC until its settlement drains" {
    const allocator = std.testing.allocator;
    var caller = engine.Peer.init(allocator);
    defer caller.deinit();
    var receiver = engine.Peer.init(allocator);
    defer receiver.deinit();

    const projection = try receiver.session_state.allocateLocalPromiseProjection();
    try receiver.session_state.exports.retain(allocator, projection.export_position);
    try caller.session_state.registerImport(projection.export_position.reinterpret(model.ImportPosition));

    try caller.sendCopying(.{ .gc_export = .{
        .positions = &.{projection.export_position.int()},
        .deltas = &.{1},
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try caller.step());
    try receiver.feedOwned(caller.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try receiver.step());
    try std.testing.expect(receiver.session_state.hasExport(projection.export_position));
    try std.testing.expect(receiver.session_state.inboundAnswerNamed(projection.answer_name) != null);

    try receiver.sendAnswerResolutionCopying(
        projection.answer_name,
        .{ .@"break" = .{ .message = "not available" } },
    );
    try std.testing.expectEqual(engine.StepOutcome.progress, try receiver.step());
    try std.testing.expect(!receiver.session_state.hasExport(projection.export_position));
    try std.testing.expect(receiver.session_state.inboundAnswerNamed(projection.answer_name) == null);
    try std.testing.expect(receiver.session_state.answerForLocalPromiseExport(projection.export_position) == null);
}

test "a multi-hop pipelined deliver decomposes into a chain of single-hop frames" {
    const allocator = std.testing.allocator;
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    // Open question 42 through the normal send path. A pipeline target is an
    // answer we actually hold, not merely an integer with answer syntax.
    try peer.session_state.registerImport(.from(7));
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var opening_frame = peer.takeOutbound().?;
    opening_frame.deinit();

    // Pipeline a 2-hop call: promise{42}.call(["a"]).call(["b"]) with outer
    // args ["c"], answer 100. Syrup has no path operand on `desc:answer`, so this
    // must drain as two intermediate single-hop frames plus the terminal.
    try peer.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42), .path = .{ .ops = &.{
            .{ .call = &.{.{ .bytes = "a" }} },
            .{ .call = &.{.{ .bytes = "b" }} },
        } } } },
        .args = &.{.{ .bytes = "c" }},
        .answer = .from(100),
    } });

    // Each frame targets the prior step's answer; the terminal carries the
    // caller's outer answer (100), the intermediates the freshly-allocated ones.
    var prev_answer: model.AnswerPosition = .from(42);
    const expected_args = [_][]const u8{ "a", "b", "c" };
    for (expected_args, 0..) |arg, idx| {
        try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
        var frame = peer.takeOutbound().?;
        defer frame.deinit();
        const view = try codec.syrup.decodeBody(frame.view());
        try std.testing.expect(view == .deliver);
        try std.testing.expect(view.deliver.target == .promise);
        try std.testing.expectEqual(prev_answer, view.deliver.target.promise.answer_position);
        try std.testing.expectEqualStrings(arg, (try view.deliver.args.at(0)).bytes);
        if (idx < expected_args.len - 1) {
            prev_answer = view.deliver.answer.?;
        } else {
            try std.testing.expectEqual(@as(?model.AnswerPosition, .from(100)), view.deliver.answer);
        }
    }

    // Chain fully drained, nothing further to encode.
    try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
}

test "a pipelined call re-queues when its answer resolves to another promise" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));

    // Two inbound answers p2 owes (#42 and #50), each from a delivery.
    for ([_]u64{ 42, 50 }) |answer| {
        try p1.sendCopying(.{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{},
            .answer = .from(answer),
        } });
        try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
        try p2.feedOwned(p1.takeOutbound().?);
        try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
        var event = p2.pollEvent().?;
        event.deinit();
    }

    // p1 pipelines a call against #42.
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

    // p2 resolves #42 to promise #50; the queued call re-queues onto #50.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(50) } } } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var resolve_frame = p2.takeOutbound().?;
        resolve_frame.deinit();
    }
    try std.testing.expect(p2.pollEvent() == null);
    try std.testing.expectEqual(@as(usize, 1), p2.session_state.inboundAnswer(.from(50)).?.queued_calls);

    // Resolving #50 to a local export finally drains the re-queued call.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(50),
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(9) } } } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var resolve_frame = p2.takeOutbound().?;
        resolve_frame.deinit();
    }

    var local_event = p2.pollEvent().?;
    defer local_event.deinit();
    const view = try local_event.view();
    // Local delivery to our export 9 decodes as `.near` post-flip (ADR-0010).
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqualStrings("ping", (try view.deliver.args.at(0)).bytes);
}

test "a pipelined call whose arg references an unheld export is rejected, like a direct deliver" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));
    // p1 claims to hold import 99, which p2 never exported, a desynced or
    // hostile partner naming a capability that does not exist on p2's side.
    try p1.session_state.registerImport(.from(99));

    // p1 calls p2's export, allocating answer 42 (now pending on p2).
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .far = .{ .import_position = .from(7) } },
        .args = &.{},
        .answer = .from(42),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var event = p2.pollEvent().?;
        event.deinit();
    }

    // p1 pipelines a call against answer 42 whose arg references far import 99.
    // On p2 that decodes (perspective flip, ADR-0010) to near export 99, which p2
    // does not hold. A direct deliver carrying that arg is rejected as
    // InvalidReference; the pipelined call must be rejected the same way instead
    // of slipping past validation onto the answer's queue.
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .reference = .{ .far = .{ .import_position = .from(99) } } }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);

    // p2 dispatches the pipelined frame and rejects it at validation, the call
    // never reaches the queue.
    try std.testing.expectError(error.InvalidReference, p2.step());
    try std.testing.expectEqual(@as(usize, 0), p2.session_state.inboundAnswer(.from(42)).?.queued_calls);
}
