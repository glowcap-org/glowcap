//! Cross-codec allocation budget parity.
//!
//! Locks the steady-state per-turn allocation count to the *same* value across
//! both codecs. A codec-neutral engine means the same logical `op:deliver`
//! through Syrup and through Cap'n Proto produces exactly one turning-point
//! heap allocation: the owned-frame copy `ownedFrameFromView` that the
//! frame-based event model requires, whether the wire bytes are Syrup-encoded
//! or Cap'n-Proto-encoded.
//!
//! If the counts diverge, one of the two codecs is not zero-copy on the
//! decode-validate-apply path, and the difference is a real bug: the session
//! is codec-neutral, so a divergence means one codec's view path adds a hidden
//! allocation the other does not. An `expectEqual` over the same fixture
//! written through each codec catches that asymmetry.
//!
//! A regression in *either* codec fails the expectEqual: the count is an exact
//! both-directions contract, not an upper bound.

const std = @import("std");
const glowcap = @import("glowcap");

const foundation = glowcap.foundation;
const model = glowcap.ocapn.model;
const codec = glowcap.ocapn.codec;
const engine = glowcap.ocapn.engine;
const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;

/// Syrup wire frame for a no-answer (`#f` answer position) `op:deliver` to
/// local export 7 carrying one `"hello"` bytes argument. Matches the fire-
/// and-forget fixture the existing `alloc_budget_test.zig` uses so both tests
/// measure the same semantic path. With no answer position every turn
/// installs no inbound answer row, so a steady stream mutates no table.
const deliver_syrup = "<10'op:deliver<11'desc:export7+>[5:hello]ff>";

/// The codec-neutral model equivalent: a `far` reference (sender's import 7)
/// that decodes (ADR-0006 flip) on the receiving side to a `near` (our export
/// 7), no answer (fire-and-forget). The Cap'n Proto encoder can encode this.
/// The Syrup encoder refuses `.near` targets, so Syrup uses the literal wire
/// form above.
const deliver_model = model.Message{
    .deliver = .{
        .target = .{ .far = model.FarRef.object(7) },
        .args = &.{.{ .bytes = "hello" }},
        .answer = null,
    },
};

/// Drive one wire turn: dispatch the borrowed frame and drain every surfaced
/// event (releasing each owned frame), matching how a host pumps the peer.
/// The final empty poll lets the peer reclaim its event-queue slots, so a
/// long-lived session reuses backing capacity instead of growing one entry per
/// turn.
fn driveOneTurn(peer: *engine.Peer, frame: foundation.FrameView) !void {
    try peer.recvBorrowed(frame);
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
}

test "steady-state deliver holds the same allocation budget through both codecs" {
    const allocator = std.testing.allocator;

    // Encode the Cap'n Proto wire frame from the model message.
    var frame_capnp = try codec.dispatch.encodeMessageForProfile(
        .capnp,
        allocator,
        model.CaptpVersion.v1_0,
        deliver_model,
    );
    defer frame_capnp.deinit();

    // ---- Syrup path ----
    // Uses the literal wire-frame delivery (the same one alloc_budget_test
    // uses), applied to a peer whose session runs the Syrup codec.
    var counter_syrup = CountingAllocator{ .backing = allocator };
    var peer_syrup = engine.Peer.init(counter_syrup.allocator());
    defer peer_syrup.deinit();
    try peer_syrup.session_state.registerExport(.from(7));

    // Warm up: grow the inbound/event backing arrays.
    const warmup: usize = 8;
    for (0..warmup) |_| try driveOneTurn(&peer_syrup, .{ .bytes = deliver_syrup, .shape = .byte });

    const turns: usize = 16;
    counter_syrup.allocs = 0;
    for (0..turns) |_| try driveOneTurn(&peer_syrup, .{ .bytes = deliver_syrup, .shape = .byte });
    const per_turn_syrup = counter_syrup.allocs / turns;

    // ---- Cap'n Proto path ----
    // Peer configured for Cap'n Proto codec so the engine dispatches the
    // inbound frame through the capnp decoder.
    var counter_capnp = CountingAllocator{ .backing = allocator };
    var peer_capnp = engine.Peer.initWithSession(
        counter_capnp.allocator(),
        glowcap.ocapn.session.Session.initWith(counter_capnp.allocator(), .{
            .codec = .capnp,
        }),
    );
    defer peer_capnp.deinit();
    try peer_capnp.session_state.registerExport(.from(7));

    for (0..warmup) |_| try driveOneTurn(&peer_capnp, frame_capnp.view());

    counter_capnp.allocs = 0;
    for (0..turns) |_| try driveOneTurn(&peer_capnp, frame_capnp.view());
    const per_turn_capnp = counter_capnp.allocs / turns;

    // Both codecs must produce the same per-turn allocation count. A divergence
    // means one codec's view path is not zero-copy where the other's is, or
    // that one encoding triggers a different retained-message path.
    try std.testing.expectEqual(per_turn_syrup, per_turn_capnp);

    // Both must land at the irreducible steady-state floor: one owned-frame
    // copy per turn (`ownedFrameFromView`), zero hidden allocations.
    const budget: usize = 1;
    try std.testing.expectEqual(@as(usize, budget), per_turn_syrup);
    try std.testing.expectEqual(@as(usize, budget), per_turn_capnp);
}
