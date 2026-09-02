//! Pipelining fail-closed: local-delivery depth bounds and resets, a closed
//! session refuses instead of queuing, a cycle breaks its dependents, and
//! exceeding the cap aborts with resource_exhausted.

const std = @import("std");
const glowcap = @import("glowcap");

const codec = glowcap.ocapn.codec;
const foundation = glowcap.foundation;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const session = glowcap.ocapn.session;
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

test "a multi-hop pipeline cycle breaks its dependent call without closing the session" {
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
        .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(2) } } } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    {
        var f = p2.takeOutbound().?;
        f.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), p2.session_state.inboundAnswer(.from(2)).?.queued_calls);

    // p2 now resolves answer 2 back to promise(1), closing the cycle. The one
    // bounded exact-incarnation walk breaks answer 99 rather than bouncing the
    // call or converting one bad promise graph into a session-wide abort.
    try p2.sendCopying(.{ .resolve = .{
        .answer = .from(2),
        .resolution = .{ .fulfill = .{ .reference = .{ .promise = .{ .answer_position = .from(1) } } } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p2.step());
    const wire = try peer_fixture.drainOutbound(&p2, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "promise resolution cycle") != null);
    try std.testing.expectEqual(session.AnswerStatus.broken, p2.session_state.inboundAnswer(.from(99)).?.status);
    try std.testing.expectEqual(session.State.open, p2.session_state.state);
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

    // The resolver callback and its one-shot import release were committed
    // before the local drain refused; the abort follows that adjacent pair.
    {
        var resolve_frame = p2.takeOutbound().?;
        resolve_frame.deinit();
    }
    {
        var release_frame = p2.takeOutbound().?;
        defer release_frame.deinit();
        const release = try codec.syrup.decodeBody(release_frame.view());
        try std.testing.expect(release == .gc_export);
    }
    var abort_frame = p2.takeOutbound().?;
    defer abort_frame.deinit();
    const decoded = try codec.syrup.decodeBody(abort_frame.view());
    try std.testing.expect(decoded == .abort);
    try std.testing.expectEqual(model.AbortKind.resource_exhausted, decoded.abort.kind);
    try std.testing.expect(p2.takeOutbound() == null);
}

test "V1 settlement pressure after callback publication is terminal and never replays" {
    var saw_post_publication_oom = false;

    for (0..24) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var peer = engine.testing.initRawOpenPeer(failing.allocator());
        defer {
            failing.fail_index = std.math.maxInt(usize);
            peer.deinit();
        }
        try peer.session_state.registerExport(.from(7));
        try peer.session_state.registerImport(.from(88));

        // Answer 42 has a V1 resolver callback. The second call pipelines on
        // it, so settling 42 must publish the callback before dispatching the
        // retained call against import 88.
        try peer.recvBorrowed(.{
            .bytes = "<10'op:deliver<11'desc:export7+>[]42+<19'desc:import-promise2000+>>",
            .shape = .byte,
        });
        {
            var event = peer.pollEvent().?;
            event.deinit();
        }
        try peer.recvBorrowed(.{
            .bytes = "<10'op:deliver<11'desc:answer42+>[<18'desc:import-object77+>]43+<19'desc:import-promise99+>>",
            .shape = .byte,
        });
        try peer.sendCopying(.{ .resolve = .{ .answer = .from(42), .resolution = .{ .fulfill = .{
            .reference = .{ .far = model.FarRef.object(88) },
        } } } });

        failing.fail_index = failing.alloc_index + offset;
        const result = peer.step();
        failing.fail_index = std.math.maxInt(usize);
        if (result) |_| {
            while (peer.takeOutbound()) |frame_in| {
                var frame = frame_in;
                frame.deinit();
            }
            continue;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }

        var published: usize = 0;
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            frame.deinit();
            published += 1;
        }
        if (published == 0) continue;

        saw_post_publication_oom = true;
        try std.testing.expectEqual(@as(usize, 2), published);
        try std.testing.expectEqual(session.State.closed, peer.session_state.state);
        try std.testing.expectEqualStrings("OutOfMemory", peer.lastAbort().?.error_name);
        try std.testing.expectEqual(engine.StepOutcome.idle, try peer.step());
        try std.testing.expect(peer.takeOutbound() == null);
        break;
    }

    try std.testing.expect(saw_post_publication_oom);
}

const SettledPipelineIngress = enum { packet, stream };

fn receiveSettledPipeline(
    peer: *engine.Peer,
    ingress: SettledPipelineIngress,
    wire: []const u8,
) !void {
    switch (ingress) {
        .packet => try peer.recvPacket(wire),
        .stream => _ = try peer.recvStreamPrefix(wire),
    }
}

fn expectSettledPipelineIngressFailsTerminal(ingress: SettledPipelineIngress) !void {
    var saw_preownership_oom = false;
    var saw_postcommit_oom = false;
    var saw_success = false;

    for (0..64) |offset| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var peer = engine.testing.initRawOpenPeer(failing.allocator());
        defer {
            failing.fail_index = std.math.maxInt(usize);
            peer.deinit();
        }
        try peer.session_state.registerExport(.from(7));
        try peer.session_state.registerExport(.from(9));

        try peer.recvBorrowed(.{
            .bytes = "<10'op:deliver<11'desc:export7+>[]42+<19'desc:import-promise2000+>>",
            .shape = .byte,
        });
        var source = peer.pollEvent().?;
        source.deinit();
        try peer.sendCopying(.{ .resolve = .{
            .answer = .from(42),
            .resolution = .{ .fulfill = .{ .reference = .{
                .near = model.NearRef.object(9),
            } } },
        } });

        const wire = "<10'op:deliver<11'desc:answer42+>[<18'desc:import-object77+>]43+<19'desc:import-promise99+>>";
        failing.fail_index = failing.alloc_index + offset;
        const attempt = receiveSettledPipeline(&peer, ingress, wire);
        failing.fail_index = std.math.maxInt(usize);

        if (attempt) |_| {
            saw_success = true;
            var delivered = peer.pollEvent() orelse return error.MissingLocalDelivery;
            delivered.deinit();
            if (saw_postcommit_oom) break;
            continue;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }

        const authority_moved = peer.session_state.hasInboundAnswer(.from(43)) or
            peer.session_state.hasImport(.from(77)) or
            peer.session_state.hasImport(.from(99));
        if (authority_moved) {
            saw_postcommit_oom = true;
            try std.testing.expectEqual(session.State.closed, peer.session_state.state);
            try std.testing.expect(peer.pollEvent() == null);
        } else if (peer.session_state.state == .open) {
            // The owned-frame allocation failed before this ingress consumed
            // the caller's bytes. Retrying remains legal because no authority
            // from the frame moved.
            saw_preownership_oom = true;
        }
    }

    try std.testing.expect(saw_preownership_oom);
    try std.testing.expect(saw_postcommit_oom);
    try std.testing.expect(saw_success);
}

test "packet ingress closes after settled-pipeline post-commit OOM" {
    try expectSettledPipelineIngressFailsTerminal(.packet);
}

test "stream ingress closes after settled-pipeline post-commit OOM" {
    try expectSettledPipelineIngressFailsTerminal(.stream);
}
