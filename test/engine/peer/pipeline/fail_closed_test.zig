//! Pipelining fail-closed: local-delivery depth bounds and resets, a closed
//! session refuses instead of queuing, a cycle cannot requeue, and exceeding
//! the cap aborts with resource_exhausted.

const std = @import("std");
const pancake = @import("pancake");

const codec = pancake.ocapn.codec;
const foundation = pancake.foundation;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const peer_fixture = @import("../../../support/peer_fixture.zig");

const harness = @import("../harness.zig");
const FailAfterAllocator = harness.FailAfterAllocator;
const CountingAllocator = harness.CountingAllocator;

test "local-delivery depth bounds one resolution and resets, so a long-lived peer never wedges" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    // Tighten the cap so the test exercises the per-resolution reset without
    // 4096 iterations. With the cap at 1, each resolution may drive exactly one
    // local delivery; before the fix `local_delivery_depth` was a peer-lifetime
    // counter, so the *second* resolution aborted with LocalDeliveryCapExceeded.
    p2.session_state.limits.max_local_deliveries = 1;

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));
    try p2.session_state.registerExport(.from(9));

    var answer: u64 = 100;
    var cycle: usize = 0;
    while (cycle < 4) : (cycle += 1) {
        // p1 calls p2's export, allocating `answer` (pending on p2).
        try p1.sendCopying(.{ .deliver = .{
            .target = .{ .far = .{ .import_position = .from(7) } },
            .args = &.{},
            .answer = .from(answer),
        } });
        try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
        try p2.feedOwned(p1.takeOutbound().?);
        try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
        {
            var event = p2.pollEvent().?;
            event.deinit();
        }

        // p1 pipelines a call against the unresolved answer.
        try p1.sendCopying(.{ .deliver = .{
            .target = .{ .promise = .{ .answer_position = .from(answer) } },
            .args = &.{.{ .bytes = "ping" }},
            .answer = .from(answer + 1),
        } });
        try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
        try p2.feedOwned(p1.takeOutbound().?);
        try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

        // p2 resolves `answer` to a local export: one local delivery. This must
        // not exceed the cap on any cycle, the depth resets per resolution.
        try p2.sendCopying(.{ .resolve = .{
            .answer = .from(answer),
            .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(9) } } } },
        } });
        try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
        {
            var resolve_frame = p2.takeOutbound().?;
            resolve_frame.deinit();
        }
        var local_event = p2.pollEvent().?;
        local_event.deinit();

        answer += 2;
    }
}

test "a closed session refuses a pipelined deliver instead of queuing it (fail closed)" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));

    // p1 calls p2's export, allocating answer 42 (pending on p2).
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

    // A fatal abort closes p2's session. close() flips state but does not clear
    // the pending answer table, so answer 42 still exists.
    p2.session_state.close();
    try std.testing.expect(p2.session_state.inboundAnswer(.from(42)) != null);

    // p1 pipelines a call against answer 42. A closed session admits nothing,
    // the engine must refuse it at the state gate, before the pipelined-enqueue
    // pre-mutation, rather than queuing a call onto a dead session.
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectError(error.SessionClosed, p2.step());

    // Nothing was queued onto the closed session.
    try std.testing.expectEqual(@as(usize, 0), p2.session_state.inboundAnswer(.from(42)).?.queued_calls);
}

test "a multi-hop pipeline cycle terminates: a batch cannot be requeued onto an already-resolved answer" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));

    // p1 makes two calls to p2's export, allocating answers 1 and 2 (both pending
    // on p2).
    inline for (.{ 1, 2 }) |answer| {
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

    // p1 pipelines a call against promise(answer 1).
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(1) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(99),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    try std.testing.expectEqual(@as(usize, 1), p2.session_state.inboundAnswer(.from(1)).?.queued_calls);

    // p2 resolves answer 1 to promise(2): the queued call moves onto answer 2.
    // Resolving answer 1 settles it.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(1),
        .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(2), .path = .{ .ops = &.{} } } } } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var f = p2.takeOutbound().?;
        f.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), p2.session_state.inboundAnswer(.from(2)).?.queued_calls);

    // p2 now resolves answer 2 back to promise(1) — the cycle's back-edge. Answer 1
    // is already resolved, so the batch cannot be requeued onto it: the drain fails
    // closed with InvalidReference and frees the batch (no infinite bounce, no leak,
    // no amplification). This is why a multi-hop cycle terminates without a
    // chain-history guard — resolving an answer settles it, and a settled answer
    // refuses a requeue.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(2),
        .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(1), .path = .{ .ops = &.{} } } } } },
    } });
    try std.testing.expectError(error.InvalidReference, p2.step());
}

test "exceeding the local-delivery cap fails closed with a resource_exhausted abort" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    // A cap of zero makes the very first local delivery the overflow.
    p2.session_state.limits.max_local_deliveries = 0;

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));
    try p2.session_state.registerExport(.from(9));

    // p1 calls p2's export, allocating answer 42 (pending on p2), then
    // pipelines a call against it.
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
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    try p2.feedOwned(p1.takeOutbound().?);
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());

    // Resolving answer 42 to a local export drives one local delivery, past
    // the cap. The bound is partner-drivable, so the refusal must fail closed
    // like an inbound violation: typed abort on the wire, session closed.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(9) } } } },
    } });
    try std.testing.expectError(error.LocalDeliveryCapExceeded, p2.step());
    try std.testing.expectEqual(session.State.closed, p2.session_state.state);

    // The resolve frame was encoded before the drain refused; the abort follows.
    {
        var resolve_frame = p2.takeOutbound().?;
        resolve_frame.deinit();
    }
    var abort_frame = p2.takeOutbound().?;
    defer abort_frame.deinit();
    const decoded = try codec.syrup.decodeBody(abort_frame.view());
    try std.testing.expect(decoded == .abort);
    try std.testing.expectEqual(model.AbortKind.resource_exhausted, decoded.abort.kind);
}
