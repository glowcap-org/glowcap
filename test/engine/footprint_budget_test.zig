//! Per-session memory footprint budget: the runtime half of step 2.
//!
//! The 500k-connection destination is a budget every struct on the session path
//! answers to. Its inline half is held by the compiler: `engine.Peer` carries a
//! `comptime` ceiling on `@sizeOf(Peer)`. This test holds the other half, the
//! heap a session grows once it has actually carried traffic, because that cost
//! is runtime, not `comptime`.
//!
//! A warmed session is one that has registered an export and driven one inbound
//! `op:deliver` turn: a connection that has settled after exchanging a message,
//! the honest "what does one real connection cost" shape. The budget is the total
//! per-connection footprint, the inline `Peer` struct plus the warmed session
//! heap, and the contract is:
//!
//!   total per-connection core state stays at or under 2 KiB (2048 bytes).
//!
//! The arithmetic that makes 2 KiB the number: 2048 bytes times 500_000 sessions
//! is 1.024 GB, under 1 GiB of protocol-core state for half a million warmed
//! sessions. That is the core's obligation. It is not the whole per-connection
//! cost. The outbound queue dominates it (`steady_outbound_bytes`, 16 KiB per
//! buffer across the front/back pair), and the live socket measurement is
//! step 5, but the core must never be what makes 500k impossible, and this gate
//! is what proves it does not drift there silently.
//!
//! `zig build bench-peer-scaling` reports the live measured numbers and the 500k
//! extrapolation for idle, warmed, and active sessions. This test is the gate the
//! report's warmed number must keep passing.

const std = @import("std");
const pancake = @import("pancake");

const engine = pancake.ocapn.engine;
const foundation = pancake.foundation;
const LiveBytesAllocator = @import("../support/alloc_metrics.zig").LiveBytesAllocator;
const copyFromBorrowed = @import("../support/frame.zig").copyFromBorrowed;

/// One inbound no-answer (`#f` answer position) `op:deliver` to live local
/// export 7 carrying one inline bytes argument. Driving it once grows a peer's
/// event/queue and table backing arrays to their warmed size, so the measured
/// footprint reflects a connection that has carried traffic, not a bare
/// `init`. Same warmed turn the steady-state allocation budget pins.
const deliver_to_live_export = "<10'op:deliver<11'desc:export7+>[5:hello]ff>";

/// The committed per-connection core-state ceiling. The inline struct budget is
/// the compiler-held half (`engine.peer_session_struct_budget_bytes`); this is
/// the warmed total, struct plus session heap. Crossing it is a design event that
/// raises the budget here and in docs/ladder.md step 2 (the ladder owns the
/// numbers), with the bytes justified, not a number to quietly nudge up.
const warmed_total_budget_bytes: u64 = 2048;

fn warmPeer(peer: *engine.Peer) !void {
    try peer.session_state.registerExport(.from(7));
    try peer.recvBorrowed(.{ .bytes = deliver_to_live_export, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
}

test "a warmed session holds its per-connection footprint budget" {
    const backing = std.testing.allocator;

    // Stand up many peers simultaneously under one live-bytes tracker so the
    // allocator's chunked growth amortizes across the set: the quotient is then
    // the marginal heap one more warmed connection adds, not one peer's rounding.
    const sample: u64 = 1024;
    var tracker = LiveBytesAllocator{ .backing = backing };
    const tracked = tracker.allocator();

    // The peer array lives in untracked memory, so only each peer's own session
    // heap counts toward the footprint, never this bookkeeping slice.
    const peers = try backing.alloc(engine.Peer, sample);
    defer backing.free(peers);

    const before = tracker.liveBytes();
    var created: u64 = 0;
    errdefer {
        var j: u64 = 0;
        while (j < created) : (j += 1) peers[j].deinit();
    }
    while (created < sample) {
        const peer = &peers[created];
        peer.* = engine.Peer.init(tracked);
        // Count the peer before warming it, so a warm-up failure's errdefer
        // deinits the just-initialized peer instead of leaking it.
        created += 1;
        try warmPeer(peer);
    }
    const after = tracker.liveBytes();

    var i: u64 = 0;
    while (i < sample) : (i += 1) peers[i].deinit();

    const heap_per_peer = (after - before) / sample;
    const bytes_per_conn = @sizeOf(engine.Peer) + heap_per_peer;

    if (bytes_per_conn > warmed_total_budget_bytes) {
        std.debug.print(
            "footprint regression: warmed session is {d} B/conn (struct {d} + heap {d}), over the {d}-byte budget, see docs/ladder.md step 2\n",
            .{ bytes_per_conn, @sizeOf(engine.Peer), heap_per_peer, warmed_total_budget_bytes },
        );
        return error.FootprintBudgetExceeded;
    }
}

test "a burst-drained session releases its burst queue capacity back under the warmed budget" {
    // One chatty chunk must not pin its burst capacity for the connection's
    // life: the engine queues retain steady capacity on drain-reset but *free*
    // anything above their steady bound (`Queue.steady_queue_bytes`), so a
    // peer that has weathered a burst settles back to warmed size. Kilobytes
    // pinned per queue would be gigabytes at the 500k destination.
    const backing = std.testing.allocator;
    var tracker = LiveBytesAllocator{ .backing = backing };
    const tracked = tracker.allocator();

    var peer = engine.Peer.init(tracked);
    defer peer.deinit();
    try warmPeer(&peer);

    // One burst: many small answerless delivers (tells) fed as owned frames,
    // then fully drained — frames through `step`, events through `pollEvent`,
    // encoded output through `takeOutbound` — so every queue crosses its
    // drain-reset. Tells avoid growing the inbound-answer table; the gate is
    // queue capacity release, not answer-row retention.
    const burst = 512;
    const tell = "<10'op:deliver<11'desc:export7+>[5:hello]ff>";
    for (0..burst) |_| {
        const frame = try copyFromBorrowed(tracked, tell, .byte);
        try peer.feedOwned(frame);
    }
    while ((try peer.step()) != .idle) {}
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }

    // The single tracked owner is this peer, so live bytes are its exact
    // retained heap: the warmed session tables plus whatever queue capacity
    // survived the drain. The same 2 KiB budget the warmed test holds applies;
    // pinned burst capacity would blow it several times over.
    const bytes_per_conn = @sizeOf(engine.Peer) + tracker.liveBytes();
    if (bytes_per_conn > warmed_total_budget_bytes) {
        std.debug.print(
            "burst-drain regression: session retains {d} B/conn after a {d}-frame burst, over the {d}-byte budget\n",
            .{ bytes_per_conn, burst, warmed_total_budget_bytes },
        );
        return error.FootprintBudgetExceeded;
    }
}
