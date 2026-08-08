//! Inbound set-uniqueness scratch must not accumulate across delivers.
//!
//! The borrowed inbound-deliver path validates a set argument by materializing
//! its elements into the session's `recv_scratch` arena to hash them for
//! duplicate refusal (`session.validate.checkInboundSetUniqueness`). That arena
//! is turn-scratch: `Session.validateInboundDeliverView` must reset it every turn,
//! exactly as the other recv entry points do. Without the reset a partner
//! streaming set-carrying `op:deliver` frames grows `recv_scratch` for the
//! session's whole life — attacker-controlled unbounded growth on the hottest
//! inbound path. This test pins the reset: the per-turn allocation budget is a
//! flat constant, so a dropped reset (scratch retained turn over turn) fails.

const std = @import("std");
const pancake = @import("pancake");

const engine = pancake.ocapn.engine;
const session = pancake.ocapn.session;
const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;

/// A no-answer (`#f` answer position) `op:deliver` to local export 7 carrying one
/// set argument `{1, 2}` (two integers, canonically ascending). The set drives
/// `checkInboundSetUniqueness`, which bumps `recv_scratch`; with no answer
/// position the turn installs no inbound answer row, so a steady stream mutates
/// no session table and the only per-turn heap cost is the owned-frame copy the
/// retained event requires.
const deliver_set_to_live_export = "<10'op:deliver<11'desc:export7+>[#1+2+$]ff>";

fn driveOneTurn(peer: *engine.Peer) !void {
    try peer.recvBorrowed(.{ .bytes = deliver_set_to_live_export, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
}

test "a stream of set-carrying delivers holds a flat per-turn scratch budget" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    var peer = engine.Peer.init(counter.allocator());
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // Warm up: grow the inbound/event backing arrays and the `recv_scratch`
    // arena's retained block so the measured window sees only per-turn wire-path
    // traffic reusing warmed capacity.
    const warmup = 8;
    for (0..warmup) |_| try driveOneTurn(&peer);

    const turns = 16;
    counter.allocs = 0;
    for (0..turns) |_| try driveOneTurn(&peer);

    try std.testing.expectEqual(@as(usize, 0), counter.allocs % turns);
    const per_turn = counter.allocs / turns;

    // Budget for a one-set-arg inbound deliver to a live export: a single
    // allocation, the owned-frame copy the retained event requires. The set's
    // uniqueness-fold scratch is reclaimed each turn by the `recv_scratch` reset
    // in `validateInboundDeliverView`, so it reuses the warmed arena block and
    // adds nothing after warmup. A dropped reset leaves scratch accumulating and
    // this budget grows.
    const budget = 1;
    try std.testing.expectEqual(@as(usize, budget), per_turn);
}

/// Build one `op:deliver` to live export 7 whose sole argument is a set of `n`
/// distinct symbols. The names are fixed-width and zero-padded, so their Syrup
/// encodings are strictly ascending by construction — the order the wire form
/// requires — with no sort. A large `n` forces `checkInboundSetUniqueness` to
/// materialize every element into `recv_scratch`, growing it many kilobytes
/// past its steady bound for that single turn.
fn buildBigSetDeliver(allocator: std.mem.Allocator, n: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "<10'op:deliver<11'desc:export7+>[#");
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var name: [9]u8 = undefined;
        try out.appendSlice(allocator, try std.fmt.bufPrint(&name, "5's{d:0>4}", .{i}));
    }
    try out.appendSlice(allocator, "$]ff>");
    return out.toOwnedSlice(allocator);
}

test "a big-set inbound frame trims recv_scratch back under its steady bound" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // One inbound deliver carrying a set of 200 distinct symbols drives the
    // borrowed deliver path (`validateInboundDeliverView`); the set-uniqueness
    // fold materializes every element into `recv_scratch`, growing it to many
    // kilobytes for that single turn.
    const frame = try buildBigSetDeliver(std.testing.allocator, 200);
    defer std.testing.allocator.free(frame);
    try peer.recvBorrowed(.{ .bytes = frame, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }

    // The turn's reset must trim the scratch back to its steady bound rather
    // than pin the burst's peak for the session's life. With `.retain_capacity`
    // it would stay at the multi-kilobyte peak and this fails; the
    // `.retain_with_limit` reset returns the burst capacity.
    try std.testing.expect(peer.session_state.recv_scratch.queryCapacity() <= session.Session.steady_recv_scratch_bytes);
}
