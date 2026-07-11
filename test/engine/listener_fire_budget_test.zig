//! Listener fan-out allocation budget and the fire-vs-GC race semantics.
//!
//! Locks the wire-path cost of firing `op:listen` listeners when an inbound
//! answer resolves: the fires carry **zero** resolution-payload copies. Each
//! fire queues a POD carrier (`engine.Outbound.listener_fire`) — queue-time
//! session accounting runs on a borrowed stack message over the *stored*
//! resolution, and `Peer.step` borrows the store back through `peekResolution`
//! to encode. One stored resolution serves N listeners with no clone anywhere;
//! the only allocations in the fire window are the frame encodes the wire
//! requires plus fixed queue bookkeeping, pinned exactly below.
//!
//! The races the carrier accepts (and this file pins): an inbound
//! `op:gc-answers` dropping the answer row between queue and encode leaves the
//! fire moot — nothing emits, nothing dangles, the session stays open — the
//! same semantics the `settled_answer` resolve carrier ships; a dropped
//! fire's queue-time export retains stay stranded until session end (pinned
//! below via the export refcount); and a released answer position *reused* by
//! the partner before the fire encodes misses the carrier's row-identity
//! stamp, so the stale fire can never ship the reused row's payload under the
//! dead row's accounting.
//!
//! A regression in *either* direction of the budget fails: it is an exact
//! contract, not an upper bound.

const std = @import("std");
const pancake = @import("pancake");

const engine = pancake.ocapn.engine;
const model = pancake.ocapn.model;
const session = pancake.ocapn.session;
const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;
const peer_fixture = @import("../support/peer_fixture.zig");

/// A PreSpec peer, so the sent resolve encodes as a wire `op:resolve` (under
/// V1.0 a resolve with no resolver import is dropped and only the fires ship,
/// which would hide the resolve frame these contracts count).
fn preSpecPeer(gpa: std.mem.Allocator) engine.Peer {
    return peer_fixture.openPeer(gpa);
}

/// `op:deliver` to local export 7, answer-pos 42: the question whose answer the
/// listeners below anchor on.
const deliver_opening_answer = "<10'op:deliver<11'desc:export7+>[]42+f>";

/// One inbound `op:listen` on answer 42 nominating partner import-object `P` as
/// the listener (the partner introduces its listener object as a descriptor we
/// import; the fire reaches it as a far deliver).
fn listenFrame(comptime position: []const u8) []const u8 {
    return "<9'op:listen<11'desc:answer42+><18'desc:import-object" ++ position ++ "+>>";
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

    // The measured window: record the resolve, encode it, queue and encode all
    // three listener fires. Every stage is pinned separately so a drift names
    // its own culprit — and none of the counts below is a payload copy.
    counter.allocs = 0;
    try peer.send(.{ .resolve = .{ .answer = .from(42), .resolution = resolution } });
    // 1: `pending_send` first-growth for the queued resolve carrier. The
    // resolution *moved* into the answer's payload row, which the listen
    // installs already created — zero store allocations, zero copies.
    try std.testing.expectEqual(@as(usize, 1), counter.allocs);

    // Encode the resolve; its settle drains the listener table and queues the
    // three POD fire carriers.
    counter.allocs = 0;
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    // 4: the resolve frame encode (1 — the codec's pinned per-encode cost, a
    // single exact-measured buffer that becomes the frame), `outbound`
    // first-growth (1), the drained-listener slice `takePipelinedListeners`
    // hands back (1, freed inside the drain), and one `pending_send` backing
    // growth for the three POD carriers (1 — amortized queue bookkeeping,
    // retained under the engine's steady bound thereafter; not a payload byte
    // is copied).
    try std.testing.expectEqual(@as(usize, 4), counter.allocs);

    // Encode the three fires, each borrowing the stored resolution.
    counter.allocs = 0;
    while ((try peer.step()) != .idle) {}
    // 4: three fire frame encodes at the codec's pinned 1 each (a single
    // exact-measured buffer that becomes the frame) plus one `outbound`
    // growth. Zero per-listener payload clones — a reintroduced clone path
    // would add 3+ here and fail.
    try std.testing.expectEqual(@as(usize, 4), counter.allocs);

    // All four frames left: the resolve, then one fire per listener, each fire
    // the same `[Symbol("fulfill"), payload]` deliver shape as before the
    // carrier — only the allocation strategy changed.
    var frames: usize = 0;
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        defer frame.deinit();
        frames += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), frames);
}

test "a fire whose answer row is GC'd between queue and encode emits nothing and the session lives on" {
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

    // Resolve answer 42 with a payload that mentions local export 8 (the
    // export-on-resolve mint: recording the resolve installs export 8 at its
    // local baseline plus the wire mention, count 2). The first step encodes
    // the resolve and queues the listener fire, whose queue-time accounting
    // retains the mention again (count 3); the fire's encode is still pending.
    try peer.send(.{ .resolve = .{ .answer = .from(42), .resolution = .{
        .fulfill = .{ .reference = .{ .near = .{ .export_position = .from(8) } } },
    } } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    try std.testing.expectEqual(@as(u64, 3), peer.session_state.exportRefcount(.from(8)));
    {
        var resolve_frame = peer.takeOutbound().?;
        resolve_frame.deinit();
    }

    // The partner releases the answer row before the fire encodes: the stored
    // resolution dies with the row, so the queued fire is moot. (The gc frame
    // surfaces its own event; drain it so the post-race deliver below is the
    // next one polled.)
    try peer.recvBorrowed(.{ .bytes = "<13'op:gc-answers[42+]>", .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }

    // Stepping pops the fire carrier, finds no row, and emits nothing — no
    // crash, no frame, no dangling borrow.
    while ((try peer.step()) != .idle) {}
    try std.testing.expect(peer.takeOutbound() == null);
    try std.testing.expect(peer.sessionIsOpen());

    // The stranded-retain posture, observed: only one mention of export 8
    // ever reached the wire (the resolve frame), but the dropped fire's
    // queue-time retain stays recorded until session end — count 3 (baseline
    // + mention + stranded retain), not 2. Queue-time retains are
    // load-bearing (they pin payload exports across the queue→encode window
    // against a legal partner release), so the stranded count is the
    // accepted price of a fire that never emits.
    try std.testing.expectEqual(@as(u64, 3), peer.session_state.exportRefcount(.from(8)));

    // Subsequent traffic still flows: a fresh deliver to the live export
    // surfaces its event as ever.
    try peer.recvBorrowed(.{ .bytes = "<10'op:deliver<11'desc:export7+>[]43+f>", .shape = .byte });
    var event = peer.pollEvent().?;
    defer event.deinit();
    try std.testing.expectEqual(engine.EventKind.deliver, event.kind());
}

test "a fire staled by answer-position reuse drops instead of shipping the new question's payload" {
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

    // Resolve answer 42; the step encodes the resolve and queues listener 9's
    // fire, stamped with this answer row's identity.
    try peer.send(.{ .resolve = .{ .answer = .from(42), .resolution = .{
        .fulfill = .{ .bytes = try allocator.dupe(u8, "old") },
    } } });
    try std.testing.expectEqual(engine.StepOutcome.progress, try peer.step());
    {
        var resolve_frame = peer.takeOutbound().?;
        resolve_frame.deinit();
    }

    // The partner releases answer 42 and (illegitimately — positions are
    // never supposed to be reused) asks a new question at the same position.
    // A fresh row is installed; the stale fire's carrier still sits queued.
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

    // Draining emits exactly one frame: the new resolve. The stale fire pops
    // first (it queued first), finds a live row whose identity stamp
    // mismatches, and drops — listener 9 was the dead question's listener,
    // and the reused row has none.
    while ((try peer.step()) != .idle) {}
    var frames: usize = 0;
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        defer frame.deinit();
        frames += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), frames);
    try std.testing.expect(peer.sessionIsOpen());
}
