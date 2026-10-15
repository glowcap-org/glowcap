//! The record/emit invariant: a settled inbound answer always holds its stored
//! resolution.
//!
//! A resolve we send is *recorded* (its inbound answer's status flips to
//! settled, `applySentResolve`) the instant `Peer.send` queues it, but the frame is
//! *emitted*, and its calls, projections, and listeners drained, only on a
//! later `step` (`settleSentResolve`). Because repeated `Peer.step` calls drain
//! every queued inbound frame before emitting any outbound one, that window is
//! as wide as a whole inbound batch: an `op:listen`, projection op, or
//! pipelined `op:deliver` that lands against the answer while its resolve sits
//! unemitted runs against a "settled" answer.
//!
//! Storing the resolution only at emit time would leave a window in which an
//! answer reads settled with *no* resolution on hand. Three consumers would
//! each need a special case: the listener path, the projection path, and the
//! pipelined-deliver path. `applySentResolve` stores the resolution the same
//! moment it flips the status, so the window cannot be observed: settled
//! implies a stored resolution, always.
//!
//! These scenarios drive each consumer into the window at the pure engine layer:
//! a resolve queued but not stepped. The class is caught here, by
//! `zig build test`, and never again only by a binding's async timing.

const std = @import("std");
const glowcap = @import("glowcap");

const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;

const peer_fixture = @import("../support/peer_fixture.zig");

test "a projection anchoring while the receiver's resolve is queued still settles" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+>");

    // Record (queue) the receiver's resolve but do NOT step: the frame sits
    // unemitted on `pending_send`, so answer 11 reads settled before its
    // emit-time drain. Storing the resolution at record time is what lets the
    // op:get below find 11's value rather than a settled-but-resolutionless row.
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .@"struct" = &.{
        .{ .key = "name", .value = .{ .string = "tabby" } },
    } } } } });

    try peer_fixture.receiveAnsweredOperation(&peer, "<6'op:get<11'desc:answer11+>4\"name12+>");

    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(wire.len != 0);
    try std.testing.expectEqualStrings("tabby", peer.session_state.peekResolution(.from(12)).?.fulfill.string);
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.inboundAnswer(.from(12)).?.status);
}

test "a chained projection whose inner answer's resolve is still queued reaches the element" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Answer 11 is fully settled and drained.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+>");
    try peer.sendBorrowed(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .tagged = .{
        .tag = "row",
        .value = &.{ .{ .string = "alice" }, .{ .string = "bob" } },
    } } } } });
    {
        const drained = try peer_fixture.drainOutbound(&peer, allocator);
        allocator.free(drained);
    }

    // untag(11 -> 12) settles 12 by recording a resolve (queued, unemitted).
    // index(12 -> 13) then anchors on 12 inside that same window, the exact
    // shape `untag(...).index(...)` takes on the wire. Index sees 12's
    // unwrapped List and 13 reaches element 0.
    try peer_fixture.receiveAnsweredOperation(&peer, "<8'op:untag<11'desc:answer11+>3\"row12+>");
    try peer_fixture.receiveAnsweredOperation(&peer, "<8'op:index<11'desc:answer12+>0+13+>");

    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(wire.len != 0);
    try std.testing.expectEqualStrings("alice", peer.session_state.peekResolution(.from(13)).?.fulfill.string);
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.inboundAnswer(.from(13)).?.status);
}

test "a pipelined op:deliver arriving while its answer's resolve is queued delivers, not breaks" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));

    // p1 delivers to p2's export, allocating answer 42 (p2 owes it).
    try p1.sendBorrowed(.{ .deliver = .{
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

    // p1 pipelines a call against answer 42.
    try p1.sendBorrowed(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    const pipelined = p1.takeOutbound().?;

    // p2 records its resolve of answer 42 (queued, unemitted) and only THEN
    // takes the pipelined call inbound. `Peer.step` drains inbound before
    // outbound, so the call dispatches while 42's resolve still sits on
    // `pending_send`. The call sees the near value and delivers locally, not
    // against a synthetic "pipelined target already broken".
    try p2.sendBorrowed(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(9) } } } },
    } });
    try p2.feedOwned(pipelined);
    while ((try p2.step()) == .progress) {}
    while (p2.takeOutbound()) |frame_value| {
        var frame = frame_value;
        frame.deinit();
    }

    var local_event = p2.pollEvent().?;
    defer local_event.deinit();
    try std.testing.expectEqual(engine.EventKind.deliver, local_event.kind());
    const view = local_event.view();
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(43)), view.deliver.answer);
    try std.testing.expectEqualStrings("ping", (try view.deliver.args.at(0)).bytes);
}

test "a failed immediate pipeline dispatch keeps its inbound commit and closes" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();

    try peer.session_state.registerExport(.from(9));
    try peer.session_state.installInboundAnswer(.from(42));
    peer.session_state.limits.max_local_deliveries = 0;
    const shortening_resolver = model.ExportPosition.from(peer.session_state.next_export_position);

    // Record a local target while leaving the resolve queued. The inbound
    // pipelined deliver therefore dispatches immediately against this value.
    try peer.sendBorrowed(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(9) } } } },
    } });

    var inbound = try codec.syrup.encodeMessageForProfile(allocator, .next, .{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .reference = .{ .near = model.NearRef.promise(77) } }},
        .answer = .from(43),
    } });
    defer inbound.deinit();

    try std.testing.expectError(error.LocalDeliveryCapExceeded, peer.recvBorrowed(inbound.view()));
    try std.testing.expectEqual(session.State.closed, peer.session_state.state);
    try std.testing.expect(peer.session_state.inboundAnswer(.from(43)) != null);
    try std.testing.expect(peer.session_state.hasImport(.from(77)));
    try std.testing.expect(peer.session_state.sourceForShorteningResolver(shortening_resolver) != null);

    var abort_frame = peer.takeOutbound() orelse return error.MissingAbort;
    defer abort_frame.deinit();
    const abort = try codec.syrup.decodeBodyForProfile(.next, abort_frame.view());
    try std.testing.expect(abort == .abort);
    try std.testing.expectEqual(model.AbortKind.resource_exhausted, abort.abort.kind);
    try std.testing.expect(peer.takeOutbound() == null);
}

test "an op:listen arriving while its answer's resolve is queued fires with the real value" {
    const allocator = std.testing.allocator;
    var p1 = engine.Peer.init(allocator);
    defer p1.deinit();
    var p2 = engine.Peer.init(allocator);
    defer p2.deinit();

    try p1.session_state.registerImport(.from(7));
    try p2.session_state.registerExport(.from(7));
    // p1's listener object is its own export 9; p2 reaches it when it fires.
    try p1.session_state.registerExport(.from(9));

    // p1 delivers to p2's export, allocating answer 42.
    try p1.sendBorrowed(.{ .deliver = .{
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

    // p1 listens on the promise (answer 42), nominating its export 9.
    try p1.sendBorrowed(.{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .mode = .settling_only,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    const listen_frame = p1.takeOutbound().?;

    // p2 records its resolve of answer 42 (queued, unemitted), then takes the
    // listen inbound. The listen installs while 42's resolve is unemitted; the
    // stored resolution lets it fire at once with "ok" rather than against a
    // synthetic break (or get stranded waiting on an emit-time fire).
    try p2.sendBorrowed(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .bytes = "ok" } },
    } });
    try p2.feedOwned(listen_frame);
    while ((try p2.step()) == .progress) {}

    // Feed everything p2 emitted to p1 and find the listener-fire deliver to
    // p1's export 9 carrying the fulfilled value.
    var saw_fire = false;
    while (p2.takeOutbound()) |frame_value| {
        try p1.feedOwned(frame_value);
    }
    while ((try p1.step()) == .progress) {
        while (p1.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            if (event.kind() != .deliver) continue;
            const view = event.view();
            if (view.* != .deliver or view.deliver.target != .near) continue;
            if (view.deliver.target.near.export_position.int() != 9) continue;
            try std.testing.expectEqualStrings("fulfill", (try view.deliver.args.at(0)).symbol);
            try std.testing.expectEqualStrings("ok", (try view.deliver.args.at(1)).bytes);
            saw_fire = true;
        }
    }
    try std.testing.expect(saw_fire);
}
