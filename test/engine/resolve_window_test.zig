//! The record/emit invariant: a settled inbound answer always holds its stored
//! resolution.
//!
//! A resolve we send is *recorded* (its inbound answer's status flips to
//! settled, `applySentResolve`) the instant `Peer.send` queues it, but the frame is
//! *emitted* — and its calls / projections / listeners drained — only on a
//! later `step` (`settleSentResolve`). Because `stepInner` drains every inbound
//! frame before emitting any outbound one, that window is as wide as a whole
//! inbound batch: an `op:listen`, projection op, or pipelined `op:deliver` that
//! lands against the answer while its resolve sits unemitted runs against a
//! "settled" answer.
//!
//! The engine once stored the resolution only at emit time, so in that window
//! an answer read settled with *no* resolution on hand. Three consumers each
//! special-cased it, and each special-case was a separate bug surfaced by a
//! separate binding's timing: the listener path (Deno), the projection path
//! (Python, then Rust), and the pipelined-deliver path (latent, never tripped).
//! `applySentResolve` now stores the resolution the same moment it flips the
//! status, so the window cannot be observed: settled implies a stored
//! resolution, always.
//!
//! These scenarios drive each consumer into the window at the pure engine layer
//! — a resolve queued but not stepped — so the class is caught here, by
//! `zig build test`, and never again only by a binding's async timing.

const std = @import("std");
const pancake = @import("pancake");

const engine = pancake.ocapn.engine;
const model = pancake.ocapn.model;
const session = pancake.ocapn.session;

const peer_fixture = @import("../support/peer_fixture.zig");

test "a projection anchoring while the receiver's resolve is queued still settles" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");

    // Record (queue) the receiver's resolve but do NOT step: the frame sits
    // unemitted on `pending_send`, so answer 11 reads settled before its
    // emit-time drain. Storing the resolution at record time is what lets the
    // op:get below find 11's value rather than a settled-but-resolutionless row.
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .@"struct" = &.{
        .{ .key = "name", .value = .{ .string = "tabby" } },
    } } } } });

    try peer.recvBorrowed(.{ .bytes = "<6'op:get<11'desc:answer11+>4\"name12+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }

    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "<10'op:resolve12+<15'resolve:fulfill5\"tabby>>") != null);
    try std.testing.expectEqual(session.AnswerStatus.fulfilled, peer.session_state.inboundAnswer(.from(12)).?.status);
}

test "a chained projection whose inner answer's resolve is still queued reaches the element" {
    const allocator = std.testing.allocator;
    var peer = peer_fixture.openPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Answer 11 is fully settled and drained.
    try peer_fixture.receiveCallCreatingAnswer(&peer, "<10'op:deliver<11'desc:export7+>[]11+f>");
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(11), .resolution = .{ .fulfill = .{ .tagged = .{
        .tag = "row",
        .value = &.{ .{ .string = "alice" }, .{ .string = "bob" } },
    } } } } });
    {
        const drained = try peer_fixture.drainOutbound(&peer, allocator);
        allocator.free(drained);
    }

    // untag(11 -> 12) settles 12 by recording a resolve (queued, unemitted).
    // index(12 -> 13) then anchors on 12 inside that same window, the exact
    // shape `untag(...).index(...)` takes on the wire. Before the invariant 12
    // read settled with no stored resolution and the chain broke; now index
    // sees 12's unwrapped List and 13 reaches element 0.
    try peer.recvBorrowed(.{ .bytes = "<8'op:untag<11'desc:answer11+>3\"row12+>", .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = "<8'op:index<11'desc:answer12+>0+13+>", .shape = .byte });
    while (peer.pollEvent()) |event_value| {
        var event = event_value;
        event.deinit();
    }

    const wire = try peer_fixture.drainOutbound(&peer, allocator);
    defer allocator.free(wire);
    try std.testing.expect(std.mem.indexOf(u8, wire, "<10'op:resolve13+<15'resolve:fulfill5\"alice>>") != null);
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

    // p1 pipelines a call against answer 42.
    try p1.sendCopying(.{ .deliver = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .args = &.{.{ .bytes = "ping" }},
        .answer = .from(43),
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    const pipelined = p1.takeOutbound().?;

    // p2 records its resolve of answer 42 (queued, unemitted) and only THEN
    // takes the pipelined call inbound. `stepInner` drains inbound before
    // outbound, so the call dispatches while 42's resolve still sits on
    // `pending_send`. Before the invariant the call found 42 settled with no
    // stored resolution and was dispatched against a synthetic "pipelined
    // target already broken"; now it sees the near value and delivers locally.
    try p2.sendCopying(.{ .resolve = .{
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
    const view = try local_event.view();
    try std.testing.expect(view.deliver.target == .near);
    try std.testing.expectEqual(@as(u64, 9), view.deliver.target.near.export_position.int());
    try std.testing.expectEqual(@as(?model.AnswerPosition, .from(43)), view.deliver.answer);
    try std.testing.expectEqualStrings("ping", (try view.deliver.args.at(0)).bytes);
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

    // p1 listens on the promise (answer 42), nominating its export 9.
    try p1.sendCopying(.{ .listen = .{
        .target = .{ .promise = .{ .answer_position = .from(42) } },
        .listener = .{ .near = .{ .export_position = .from(9) } },
        .wants_partial = false,
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try p1.step());
    const listen_frame = p1.takeOutbound().?;

    // p2 records its resolve of answer 42 (queued, unemitted), then takes the
    // listen inbound. The listen installs while 42's resolve is unemitted; the
    // stored resolution lets it fire now with "ok" rather than against a
    // synthetic break (or get stranded waiting on an emit-time fire).
    try p2.sendCopying(.{ .resolve = .{
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
            const view = try event.view();
            if (view != .deliver or view.deliver.target != .near) continue;
            if (view.deliver.target.near.export_position.int() != 9) continue;
            try std.testing.expectEqualStrings("fulfill", (try view.deliver.args.at(0)).symbol);
            try std.testing.expectEqualStrings("ok", (try view.deliver.args.at(1)).bytes);
            saw_fire = true;
        }
    }
    try std.testing.expect(saw_fire);
}
