//! Steady-state wire-path allocation budget.
//!
//! Locks the number of heap allocations a single `op:deliver` to an
//! already-live local export costs once the session has reached steady state
//! (tables warmed, event/queue backing arrays grown). This is the measurement
//! anchor for the borrowed-validate / owned-on-retain receive path: the only
//! per-turn heap allocation should be the owned-frame copy the frame-based event
//! model requires for a retained event.
//!
//! A regression in *either* direction fails: the budget is an exact contract,
//! not an upper bound.

const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;
const engine = pancake.ocapn.engine;
const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;

/// A no-answer (`#f` answer position) `op:deliver` to local export 7 carrying one
/// inline bytes argument — the fire-and-forget one-way send. The argument
/// exercises the borrowed-validate path without retained owned message
/// materialization, so the budget measures the irreducible owned-frame copy
/// rather than transient validation clones. With no answer position every turn
/// installs no inbound answer row, so a steady stream mutates no table; a
/// distinct-answer deliver would both grow the answer table per turn and, on a
/// reused position, trip the live-answer-reuse refusal.
const deliver_to_live_export = "<10'op:deliver<11'desc:export7+>[5:hello]ff>";

/// Drive one wire turn: dispatch the borrowed deliver and drain every surfaced
/// event (releasing each owned frame), matching how a host pumps the peer. The
/// final empty poll lets the peer reclaim its event-queue slots, so a long-lived
/// session reuses backing capacity instead of growing one entry per turn.
fn driveOneTurn(peer: *engine.Peer) !void {
    try peer.recvBorrowed(.{ .bytes = deliver_to_live_export, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
}

test "steady-state deliver to a live export holds its allocation budget" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var peer = engine.Peer.init(counter.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Warm up: grow the inbound/event backing arrays so the measured window sees
    // only per-turn wire-path traffic.
    const warmup = 8;
    for (0..warmup) |_| try driveOneTurn(&peer);

    const turns = 16;
    counter.allocs = 0;
    for (0..turns) |_| try driveOneTurn(&peer);

    try std.testing.expectEqual(@as(usize, 0), counter.allocs % turns);
    const per_turn = counter.allocs / turns;

    // Budget for a one-arg inbound deliver to a live export: a single allocation,
    // the owned-frame copy the retained event requires (`ownedFrameFromView`).
    // `Session.recordRecvView` validates and applies authority straight from the
    // borrowed codec projection. This is the irreducible steady-state floor under
    // the frame-based event model; a regression in either direction fails.
    const budget = 1;
    try std.testing.expectEqual(@as(usize, budget), per_turn);
}

/// The same fire-and-forget deliver, but the single argument is a far reference
/// (`desc:import-object 99`) the partner introduces. After the first turn
/// registers import 99, every later turn finds it already held, so the measured
/// window sees only the steady per-turn cost of a capability-carrying deliver.
const deliver_introducing_far_ref = "<10'op:deliver<11'desc:export7+>[<18'desc:import-object99+>]ff>";

fn driveOneCapTurn(peer: *engine.Peer) !void {
    try peer.recvBorrowed(.{ .bytes = deliver_introducing_far_ref, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
}

test "steady-state capability-carrying deliver holds its allocation budget" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var peer = engine.Peer.init(counter.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Warm up so the first turn's import registration and backing growth land
    // outside the measured window; import 99 is held for every measured turn.
    const warmup = 8;
    for (0..warmup) |_| try driveOneCapTurn(&peer);

    const turns = 16;
    counter.allocs = 0;
    for (0..turns) |_| try driveOneCapTurn(&peer);

    try std.testing.expectEqual(@as(usize, 0), counter.allocs % turns);
    const per_turn = counter.allocs / turns;

    // Three allocations for a capability-carrying deliver, above the one-arg
    // floor: the owned frame the retained event requires, the gpa-backed
    // introduced-mention list that rides the event for post-dispatch stateless
    // GC (`inbound.zig`, on `self.allocator` so it outlives the turn), and the
    // owned handoff of that list onto the event. Import 99 is already held, so
    // there is no per-turn registration. This is an exact contract, not an
    // upper bound; a fourth allocation here is a regression.
    const budget = 3;
    try std.testing.expectEqual(@as(usize, budget), per_turn);
}
