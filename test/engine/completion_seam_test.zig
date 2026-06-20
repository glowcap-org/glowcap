//! The contract a hand-rolled completion-loop adapter depends on.
//!
//! A completion loop (io_uring / kqueue / IOCP) owns a bounded per-connection
//! byte buffer, receives reads of *arbitrary* size, and must apply whole frames
//! out of that buffer without a `std.Io.Reader` underneath it. The Peer seam for
//! that is `recvStreamPrefix` (apply one frame off a borrowed prefix, report
//! bytes consumed or `.incomplete`), `step` (encode queued sends), and
//! `takeOutbound` (pull owned outbound frames). These tests drive that seam with
//! no `std.Io` and no socket, the way the loop will, so the contract is pinned
//! before the loop exists: arbitrary chunk boundaries apply each frame exactly
//! once, the unconsumed tail stays valid for the next read, and compaction
//! drains several frames from one buffer. If a refactor breaks the seam, these
//! fail rather than the future loop.

const std = @import("std");
const pancake = @import("pancake");

const engine = pancake.ocapn.engine;

/// `op:deliver` to live local export 7, answer position 11, the same fixed
/// frame the alloc-budget test reuses, so re-applying it is idempotent on the
/// session tables and a steady stream of them never errors.
const deliver_to_export7 = "<10'op:deliver<11'desc:export7+>[5:hello]11+f>";

/// Apply every whole frame currently buffered, compacting the unconsumed tail to
/// the front of `buf` — exactly the loop's inner drain. Returns the number of
/// frames applied and the new valid length.
fn drainBuffered(peer: *engine.Peer, buf: []u8, valid_in: usize) !struct { applied: usize, valid: usize } {
    var valid = valid_in;
    var applied: usize = 0;
    while (valid > 0) {
        switch (try peer.recvStreamPrefix(buf[0..valid])) {
            .incomplete => break,
            .consumed => |n| {
                applied += 1;
                std.mem.copyForwards(u8, buf[0 .. valid - n], buf[n..valid]);
                valid -= n;
            },
        }
    }
    return .{ .applied = applied, .valid = valid };
}

fn drainDeliverEvents(peer: *engine.Peer) !usize {
    var events: usize = 0;
    while (peer.pollEvent()) |ev_in| {
        var ev = ev_in;
        defer ev.deinit();
        try std.testing.expectEqual(engine.EventKind.deliver, ev.kind());
        events += 1;
    }
    return events;
}

test "completion seam: a frame delivered one byte at a time applies exactly once" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    var buf: [256]u8 = undefined;
    var valid: usize = 0;
    var applied_total: usize = 0;
    var events_total: usize = 0;

    // Each iteration is one single-byte "read completion": append, then apply
    // whatever is now whole. Every strict prefix must be `.incomplete` (no error,
    // no state change) until the final byte completes the frame.
    for (deliver_to_export7) |byte| {
        buf[valid] = byte;
        valid += 1;
        const drained = try drainBuffered(&peer, &buf, valid);
        valid = drained.valid;
        applied_total += drained.applied;
        events_total += try drainDeliverEvents(&peer);
    }

    try std.testing.expectEqual(@as(usize, 1), applied_total);
    try std.testing.expectEqual(@as(usize, 1), events_total);
    try std.testing.expectEqual(@as(usize, 0), valid); // tail fully consumed

    // A deliver to a live export surfaces an event for the application; the core
    // queues no automatic outbound, so the loop arms no write.
    while ((try peer.step()) != .idle) {}
    try std.testing.expect(peer.takeOutbound() == null);
}

test "completion seam: two frames in one read drain via compaction" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    const wire = deliver_to_export7 ++ deliver_to_export7;
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..wire.len], wire);

    const drained = try drainBuffered(&peer, &buf, wire.len);
    try std.testing.expectEqual(@as(usize, 2), drained.applied);
    try std.testing.expectEqual(@as(usize, 0), drained.valid);
    try std.testing.expectEqual(@as(usize, 2), try drainDeliverEvents(&peer));
}

test "completion seam: a frame plus a partial next frame leaves the tail buffered" {
    var peer = engine.Peer.init(std.testing.allocator);
    defer peer.deinit();
    try peer.session_state.registerExport(.from(7));

    // One whole frame followed by a strict prefix of the next: the loop applies
    // the first and keeps the partial tail for the following read.
    const partial = deliver_to_export7[0 .. deliver_to_export7.len - 3];
    const wire = deliver_to_export7 ++ partial;
    var buf: [512]u8 = undefined;
    @memcpy(buf[0..wire.len], wire);

    const first = try drainBuffered(&peer, &buf, wire.len);
    try std.testing.expectEqual(@as(usize, 1), first.applied);
    try std.testing.expectEqual(partial.len, first.valid); // partial tail retained, intact
    try std.testing.expectEqualStrings(partial, buf[0..first.valid]);
    try std.testing.expectEqual(@as(usize, 1), try drainDeliverEvents(&peer));

    // Append the three missing bytes and the second frame completes.
    const rest = deliver_to_export7[deliver_to_export7.len - 3 ..];
    @memcpy(buf[first.valid .. first.valid + rest.len], rest);
    const second = try drainBuffered(&peer, &buf, first.valid + rest.len);
    try std.testing.expectEqual(@as(usize, 1), second.applied);
    try std.testing.expectEqual(@as(usize, 0), second.valid);
    try std.testing.expectEqual(@as(usize, 1), try drainDeliverEvents(&peer));
}
