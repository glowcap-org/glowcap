//! Listener fan-out allocation budget and the fire-vs-GC race semantics.
//!
//! Locks the wire-path cost of firing `op:listen` listeners when an inbound
//! answer resolves: the fires carry **zero** resolution-payload copies. Each
//! fire queues a POD carrier (`engine.Outbound.listener_fire`). Queue-time
//! session accounting runs on a borrowed stack message over the *stored*
//! resolution, and `Peer.step` borrows the store back through `peekResolution`
//! to encode. One stored resolution serves N listeners with no clone anywhere;
//! each one-shot callback is immediately followed by the `op:gc-exports` that
//! releases its listener import. The only allocations in the fire window are
//! those frame encodes plus fixed queue bookkeeping, pinned exactly below.
//!
//! `op:gc-answers` releases the partner's pipelining position; it does not
//! cancel a listener already accepted under `op:listen`. A queued fire owns a
//! reference to the exact answer incarnation, so GC and legal position reuse
//! neither silence it nor redirect it to the replacement row.
//!
//! A regression in *either* direction of the budget fails: it is an exact
//! contract, not an upper bound.

const std = @import("std");
const glowcap = @import("glowcap");

const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;
const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;
const peer_fixture = @import("../support/peer_fixture.zig");

/// A next peer. Settlement itself stays internal; only registered listener
/// callbacks cross the wire.
fn preSpecPeer(gpa: std.mem.Allocator) engine.Peer {
    return peer_fixture.openPeer(gpa);
}

/// `op:deliver` to local export 7, answer-pos 42: the question whose answer the
/// listeners below anchor on.
const deliver_opening_answer = "<10'op:deliver<11'desc:export7+>[]42+>";

/// One inbound `op:listen` on answer 42 nominating partner import-object `P` as
/// the listener (the partner introduces its listener object as a descriptor we
/// import; the fire reaches it as a far deliver).
fn listenFrame(comptime position: []const u8) []const u8 {
    return "<9'op:listen<11'desc:answer42+><18'desc:import-object" ++ position ++ "+>3+>";
}

test "resolving an answer with three listeners copies the resolution payload zero times" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    const gpa = counter.allocator();
    var peer = preSpecPeer(gpa);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Install answer 42 and three listeners on it, draining the surfaced
    // events, all before the measured window.
    try peer.recvBorrowed(.{ .bytes = deliver_opening_answer, .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = listenFrame("9"), .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = listenFrame("10"), .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = listenFrame("11"), .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }

    // The owned resolution the application resolves the answer with, exactly
    // as handed to `Peer.send`. Allocated before the window (the dupe is the
    // caller's, not the fan-out's); ownership moves into the answer store.
    const payload = try gpa.dupe(u8, "ok");
    const resolution: model.Resolution = .{ .fulfill = .{ .bytes = payload } };

    // The measured window: record the settlement, queue and encode all
    // three listener fires. Every stage is pinned separately so a drift names
    // its own culprit — and none of the counts below is a payload copy.
    counter.allocs = 0;
    try peer.send(.{ .resolve = .{ .answer = .from(42), .resolution = resolution } });
    // 1: `pending_send` first-growth for the queued resolve carrier. The
    // resolution *moved* into the answer's payload row, which the listen
    // installs already created — zero store allocations, zero copies.
    try std.testing.expectEqual(@as(usize, 1), counter.allocs);

    // Apply the settlement, drain the listener table, and queue the three POD
    // fire carriers. Next has no wire `op:resolve`.
    counter.allocs = 0;
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    // 2: the drained-listener slice `takePipelinedListeners` hands back (1,
    // freed inside the drain), and one `pending_send` backing growth for the
    // three POD carriers (1). No payload byte is copied.
    try std.testing.expectEqual(@as(usize, 2), counter.allocs);

    // Encode the three callback/release pairs, each callback borrowing the
    // stored resolution.
    counter.allocs = 0;
    while ((try peer.step()) != .idle) {}
    // 8: six frame encodes at the codec's pinned 1 each (callback plus listener
    // release), and two `outbound` backing growths while publishing three
    // atomic pairs. Zero per-listener payload clones — a reintroduced clone
    // path would add 3+ here and fail.
    try std.testing.expectEqual(@as(usize, 8), counter.allocs);

    // Three callback/release pairs left, one pair per listener. Settlement
    // itself is session-local in next.
    var frames: usize = 0;
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        defer frame.deinit();
        frames += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), frames);
}

test "a bootstrap listener fires without import accounting or wire release" {
    const allocator = std.testing.allocator;
    var peer = preSpecPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer.recvBorrowed(.{ .bytes = deliver_opening_answer, .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = listenFrame("0"), .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
    try std.testing.expect(!peer.session_state.hasImport(.from(session.BOOTSTRAP_POSITION)));

    try peer.sendCopying(.{ .resolve = .{
        .answer = .from(42),
        .resolution = .{ .fulfill = .{ .integer = 7 } },
    } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    var callback = peer.takeOutbound() orelse return error.MissingListenerCallback;
    defer callback.deinit();
    const body = try glowcap.ocapn.codec.syrup.decodeBodyForProfile(
        peer.session_state.captp_version,
        callback.view(),
    );
    try std.testing.expectEqual(
        @as(u64, session.BOOTSTRAP_POSITION),
        body.deliver.target.near.export_position.int(),
    );
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expect(!peer.session_state.hasImport(.from(session.BOOTSTRAP_POSITION)));
}

test "answer listener preparation restores after OOM and retries from the settlement carrier" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var peer = preSpecPeer(allocator);
    defer peer.deinit();
    defer failing.fail_index = std.math.maxInt(usize);
    try peer.session_state.registerExport(.from(7));

    try peer.recvBorrowed(.{ .bytes = deliver_opening_answer, .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = listenFrame("9"), .shape = .byte });
    try peer.recvBorrowed(.{
        .bytes = "<10'op:deliver<11'desc:export7+>[]43+>",
        .shape = .byte,
    });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(42), .resolution = .{ .fulfill = .{
        .reference = .{ .promise = .{ .answer_position = .from(43) } },
    } } } });

    // Detaching the source listener and creating answer 43's lazy payload both
    // succeed; growing its listener list fails. The preparation token removes
    // that otherwise-empty payload and the settlement carrier remains retryable.
    failing.fail_index = failing.alloc_index + 2;
    try std.testing.expectError(error.OutOfMemory, peer.step());
    try std.testing.expect(peer.takeOutbound() == null);
    failing.fail_index = std.math.maxInt(usize);
    const target_43 = peer.session_state.answerTargetNamed(.fromWire(.from(43))).?;
    try std.testing.expect(peer.session_state.answerPayloadForTarget(target_43) == null);
    const target = peer.session_state.answerTargetNamed(.fromWire(.from(42))).?;
    const payload = peer.session_state.answerPayloadForTarget(target).?;
    const restored = try peer.session_state.takeAnswerPayloadListeners(payload);
    try std.testing.expectEqual(@as(usize, 1), restored.len);
    peer.session_state.restoreAnswerPayloadListeners(payload, restored);

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try peer.send(.{ .resolve = .{ .answer = .from(43), .resolution = .{
        .fulfill = .{ .bytes = try allocator.dupe(u8, "eventual") },
    } } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var callback = peer.takeOutbound().?;
    defer callback.deinit();
    const body = try glowcap.ocapn.codec.syrup.decodeBodyForProfile(
        peer.session_state.captp_version,
        callback.view(),
    );
    try std.testing.expectEqualStrings("eventual", (try body.deliver.args.at(1)).bytes);
    var release = peer.takeOutbound().?;
    defer release.deinit();
    try std.testing.expect(peer.takeOutbound() == null);
}

test "listener promise chains borrow the terminal answer store" {
    const allocator = std.testing.allocator;
    var peer = preSpecPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer.recvBorrowed(.{ .bytes = "<10'op:deliver<11'desc:export7+>[]7+>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }
    try peer.send(.{ .resolve = .{ .answer = .from(7), .resolution = .{
        .fulfill = .{ .bytes = try allocator.dupe(u8, "terminal") },
    } } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    try peer.recvBorrowed(.{ .bytes = deliver_opening_answer, .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = listenFrame("9"), .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(42), .resolution = .{ .fulfill = .{
        .reference = .{ .promise = .{ .answer_position = .from(7) } },
    } } } });

    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var callback = peer.takeOutbound().?;
    defer callback.deinit();
    const body = try glowcap.ocapn.codec.syrup.decodeBodyForProfile(
        peer.session_state.captp_version,
        callback.view(),
    );
    try std.testing.expectEqualStrings("terminal", (try body.deliver.args.at(1)).bytes);
    var release = peer.takeOutbound().?;
    defer release.deinit();
    try std.testing.expect(peer.takeOutbound() == null);
}

test "a late listener on a stored promise cycle receives one terminal break" {
    const allocator = std.testing.allocator;
    var peer = preSpecPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer.recvBorrowed(.{ .bytes = deliver_opening_answer, .shape = .byte });
    try peer.recvBorrowed(.{
        .bytes = "<10'op:deliver<11'desc:export7+>[]43+>",
        .shape = .byte,
    });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }

    try peer.sendCopying(.{ .resolve = .{ .answer = .from(42), .resolution = .{ .fulfill = .{
        .reference = .{ .promise = .{ .answer_position = .from(43) } },
    } } } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(43), .resolution = .{ .fulfill = .{
        .reference = .{ .promise = .{ .answer_position = .from(42) } },
    } } } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    // The cycle is already durable when the listener arrives. Holding it on
    // either settled row would leave a callback that can never fire; walking
    // forever is equally invalid. The listener gets one explicit break.
    try peer.recvBorrowed(.{ .bytes = listenFrame("9"), .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    var callback = peer.takeOutbound().?;
    defer callback.deinit();
    const body = try glowcap.ocapn.codec.syrup.decodeBodyForProfile(
        peer.session_state.captp_version,
        callback.view(),
    );
    try std.testing.expectEqualStrings("break", (try body.deliver.args.at(0)).symbol);
    try std.testing.expectEqualStrings(
        "promise resolution cycle",
        (try body.deliver.args.at(1)).symbol,
    );
    var release = peer.takeOutbound().?;
    defer release.deinit();
    try std.testing.expect(peer.takeOutbound() == null);
}

test "a late listener cannot follow a stored promise into a reused answer position" {
    const allocator = std.testing.allocator;
    var peer = preSpecPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer.recvBorrowed(.{ .bytes = deliver_opening_answer, .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = "<10'op:deliver<11'desc:export7+>[]43+>", .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(42), .resolution = .{ .fulfill = .{
        .reference = .{ .promise = .{ .answer_position = .from(43) } },
    } } } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    try peer.recvBorrowed(.{ .bytes = "<13'op:gc-answers[43+]>", .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = "<10'op:deliver<11'desc:export7+>[]43+>", .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
    try peer.sendCopying(.{ .resolve = .{ .answer = .from(43), .resolution = .{
        .fulfill = .{ .bytes = "replacement" },
    } } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());

    try peer.recvBorrowed(.{ .bytes = listenFrame("9"), .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    var callback = peer.takeOutbound().?;
    defer callback.deinit();
    const body = try glowcap.ocapn.codec.syrup.decodeBodyForProfile(
        peer.session_state.captp_version,
        callback.view(),
    );
    try std.testing.expectEqualStrings(
        "promise resolution target was released",
        (try body.deliver.args.at(1)).symbol,
    );
    try std.testing.expect(std.mem.indexOf(u8, callback.bytes(), "replacement") == null);
    var release = peer.takeOutbound().?;
    defer release.deinit();
    try std.testing.expect(peer.sessionIsOpen());
}

test "live object export listen fires with zero payload copies" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    const gpa = counter.allocator();
    var peer = preSpecPeer(gpa);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Install listener on live export 7; drain the surfaced listen event first.
    try peer.recvBorrowed(.{
        .bytes = "<9'op:listen<11'desc:export7+><18'desc:import-object9+>3+>",
        .shape = .byte,
    });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }

    // Measured window: encode the queued POD fire carrier and its listener
    // release. No owned fulfill symbol dupe and no args spine.
    counter.allocs = 0;
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    // 3: callback and release frame encodes (2) plus one `outbound` growth (1).
    // The POD carrier queued on recv paid its own `pending_send` growth outside
    // this window.
    try std.testing.expectEqual(@as(usize, 3), counter.allocs);

    var frame = peer.takeOutbound().?;
    defer frame.deinit();
    var release = peer.takeOutbound().?;
    defer release.deinit();
    try std.testing.expect(peer.takeOutbound() == null);
}

test "a listener accepted before answer GC still publishes exactly once" {
    const allocator = std.testing.allocator;
    var peer = preSpecPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer.recvBorrowed(.{ .bytes = deliver_opening_answer, .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = listenFrame("9"), .shape = .byte });
    var original_target: ?session.AnswerTarget = null;
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        if (event.kind() == .deliver) original_target = event.deliverAnswerTarget();
        event.deinit();
    }

    // Releasing the pipelining name before the application replies cannot
    // revoke the accepted listener. The surfaced event carries the exact
    // incarnation token the application returns with its result.
    try peer.recvBorrowed(.{ .bytes = "<13'op:gc-answers[42+]>", .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }

    // Resolve that detached incarnation with a payload mentioning local
    // export 8. Recording installs export 8 at its local baseline; the first
    // step queues the listener callback and its wire mention retain.
    try peer.sendAnswerTargetResolutionCopying(original_target.?, .{
        .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(8) } } },
    });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try std.testing.expectEqual(@as(u64, 2), peer.session_state.exportRefcount(.from(8)));
    try std.testing.expect(peer.takeOutbound() == null);

    // The retained answer incarnation supplies the callback payload exactly
    // once even though its wire name is already free.
    while ((try peer.step()) != .idle) {}
    var callback = peer.takeOutbound().?;
    defer callback.deinit();
    var release = peer.takeOutbound().?;
    defer release.deinit();
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expect(peer.sessionIsOpen());

    // The callback really published the queue-time wire mention; no retain is
    // stranded behind a silently dropped carrier.
    try std.testing.expectEqual(@as(u64, 2), peer.session_state.exportRefcount(.from(8)));

    // Subsequent traffic still flows: a fresh deliver to the live export
    // surfaces its event as ever.
    try peer.recvBorrowed(.{ .bytes = "<10'op:deliver<11'desc:export7+>[]43+>", .shape = .byte });
    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
}

test "answer-position reuse neither cancels nor redirects an accepted listener fire" {
    const allocator = std.testing.allocator;
    var peer = preSpecPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    try peer.recvBorrowed(.{ .bytes = deliver_opening_answer, .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = listenFrame("9"), .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }

    // Settle answer 42; the step queues listener 9's callback, stamped with
    // this answer row's identity.
    try peer.send(.{ .resolve = .{ .answer = .from(42), .resolution = .{
        .fulfill = .{ .bytes = try allocator.dupe(u8, "old") },
    } } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try std.testing.expect(peer.takeOutbound() == null);

    // The partner releases answer 42 and legally reuses the position for a new
    // question while the old listener fire is still queued.
    try peer.recvBorrowed(.{ .bytes = "<13'op:gc-answers[42+]>", .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = deliver_opening_answer, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }

    // We resolve the new question before the stale fire encodes, so the
    // reused row holds "new" — the payload the stale fire must never ship
    // under the dead row's accounting.
    try peer.send(.{ .resolve = .{ .answer = .from(42), .resolution = .{
        .fulfill = .{ .bytes = try allocator.dupe(u8, "new") },
    } } });

    // Only the old listener callback and its listener release cross the wire;
    // the next-profile settlement for the replacement row is local. The
    // callback payload must remain "old", never the replacement row's "new"
    // value.
    while ((try peer.step()) != .idle) {}
    var frames: usize = 0;
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        defer frame.deinit();
        frames += 1;
        const body = try glowcap.ocapn.codec.syrup.decodeBodyForProfile(
            peer.session_state.captp_version,
            frame.view(),
        );
        switch (body) {
            .deliver => {
                try std.testing.expectEqualStrings("old", (try body.deliver.args.at(1)).bytes);
                try std.testing.expect(std.mem.indexOf(u8, frame.bytes(), "new") == null);
            },
            .gc_export => {
                try std.testing.expectEqual(@as(u64, 9), try body.gc_export.positions.at(0));
                try std.testing.expectEqual(@as(u64, 1), try body.gc_export.deltas.at(0));
            },
            else => return error.UnexpectedOutbound,
        }
    }
    try std.testing.expectEqual(@as(usize, 2), frames);
    try std.testing.expect(peer.sessionIsOpen());
}

test "answer-position reuse keeps stored settlements on their exact incarnation" {
    const allocator = std.testing.allocator;
    var peer = preSpecPeer(allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Question 1 opens answer 42; resolve it but do NOT drain. Its retained
    // settlement carrier owns row A's payload while the wire name is reusable.
    try peer.recvBorrowed(.{ .bytes = deliver_opening_answer, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
    try peer.send(.{ .resolve = .{ .answer = .from(42), .resolution = .{
        .fulfill = .{ .bytes = try allocator.dupe(u8, "old") },
    } } });

    // The partner releases answer 42 and legally asks a new question at the
    // same position. A fresh row B is installed while row A's carrier remains
    // queued ahead of everything.
    try peer.recvBorrowed(.{ .bytes = "<13'op:gc-answers[42+]>", .shape = .byte });
    try peer.recvBorrowed(.{ .bytes = deliver_opening_answer, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }

    // Resolve the new question before row A drains. Each payload must remain
    // bound to its own incarnation.
    try peer.send(.{ .resolve = .{ .answer = .from(42), .resolution = .{
        .fulfill = .{ .bytes = try allocator.dupe(u8, "new") },
    } } });

    // Next has no callback for either listener-free answer, so draining emits
    // no frames. The live position must still expose row B's value, never row A.
    while ((try peer.step()) != .idle) {}
    var resolves: usize = 0;
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        defer frame.deinit();
        resolves += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), resolves);
    try std.testing.expectEqualStrings(
        "new",
        peer.session_state.peekResolution(.from(42)).?.fulfill.bytes,
    );
    try std.testing.expect(peer.sessionIsOpen());
}
