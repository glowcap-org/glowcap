//! Outbound-resolve allocation budget.
//!
//! Locks the wire-path cost of *recording* an outbound `op:resolve`: the
//! resolution is **moved** into the inbound answer's store, never copied. A
//! resolve we send carries no resolution copy at all — `recordSend` consumes the
//! caller's owned resolution (`applySentResolve` into `Session.storeResolution`) and
//! the queued outbound carrier holds only the settled answer position, so
//! `Peer.step` reads the resolution back from the store to encode. The single
//! durable owner is the store; there is no second owner to copy for.
//!
//! Why a move is safe where a borrow would not be: the store owns the resolution
//! from record to GC, and the encoder reads it through `peekResolution` at emit —
//! so an inbound `op:gc-answers` that drops the row between record and emit
//! (`stepInner` interleaves inbound dispatch between them) leaves nothing to
//! encode rather than a dangling pointer. The carrier holds only a `u64`.
//!
//! The measured window therefore sees exactly one allocation — the answer's
//! lazily-created payload row — and **zero** resolution copies. If a clone ever
//! creeps back onto this path, the count rises and this fails; that is the whole
//! point of pinning it.

const std = @import("std");
const pancake = @import("pancake");

const engine = pancake.ocapn.engine;
const model = pancake.ocapn.model;
const session = pancake.ocapn.session;
const CountingAllocator = @import("../support/alloc_metrics.zig").CountingAllocator;
const peer_fixture = @import("../support/peer_fixture.zig");

test "recording an outbound resolve moves the resolution into the store, copying nothing" {
    var counter = CountingAllocator{ .backing = std.testing.allocator };
    const gpa = counter.allocator();
    var peer = peer_fixture.openPeer(gpa);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // The inbound answer the resolve settles: a question the partner posed
    // (`op:deliver` to our export 7) that we now owe. Installed and drained
    // before the window so its install traffic is not counted.
    try peer.recvBorrowed(.{ .bytes = "<10'op:deliver<11'desc:export7+>[]11+f>", .shape = .byte });
    {
        var event = peer.pollEvent().?;
        event.deinit();
    }

    // An *owned* resolution, exactly as a caller hands to `Peer.send`: the move
    // transfers this heap into the store, which frees it at teardown. (Allocated
    // before the window so the dupe is not counted; never freed here, ownership
    // is transferred by `recordSend`.)
    const payload = try gpa.dupe(u8, "ok");
    const resolution: model.Resolution = .{ .fulfill = .{ .bytes = payload } };

    counter.allocs = 0;
    try peer.session_state.recordSend(.{ .resolve = .{ .answer = .from(11), .resolution = resolution } });

    // One allocation: the answer's lazily-created payload row. Zero resolution
    // copies, the resolution moved. A reintroduced clone would read 2 here.
    try std.testing.expectEqual(@as(usize, 1), counter.allocs);
}
