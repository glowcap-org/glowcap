//! A resident reports a clean end of stream as readable and closed in one
//! record, and the buffered bytes stay readable until the read reaches the
//! end. A stepped Host that leaves the read for later therefore leaves the
//! close with it: the requests the partner sent before closing are still
//! dispatched, and the close is clean. A closed bit with no readable bit is
//! the resident's fault signal and closes at once.

const std = @import("std");
const glowcap = @import("glowcap");

const pressure_rig = @import("pressure_rig.zig");
const Rig = pressure_rig.Rig;
const max_rounds = pressure_rig.max_rounds;
const net_would_block = glowcap.net.multiplexed_resident.would_block;

fn stepUntilClosed(rig: *Rig) !void {
    for (0..max_rounds) |_| {
        _ = try rig.step();
        if (rig.observed.close_events != 0) return;
    }
    return error.NeverClosed;
}

test "a hello, its requests, and a clean close in one record dispatch every request and close cleanly" {
    const fetches = 40;
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = fetches, .opens_on_read = true });
    defer rig.destroy();
    rig.resident.read_result = 0;
    rig.resident.signal_closed = true;
    rig.resident.offer(&rig.burst);
    try stepUntilClosed(rig);
    try std.testing.expectEqual(@as(usize, 1), rig.observed.close_events);
    try std.testing.expectEqual(@as(?anyerror, null), rig.observed.close_failure);
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_tail);
    try rig.expectAnswersInOrder();
}

test "a close that arrives with the window reopening dispatches every held request and closes cleanly" {
    const fetches = 60;
    const rig = try Rig.create(std.testing.allocator, fetches);
    defer rig.destroy();
    _ = try rig.fillToWaterline();
    rig.offerNext();
    _ = try rig.step();
    for (0..5) |_| {
        _ = try rig.step();
        try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
        try std.testing.expect(rig.session.sessionOpen());
    }
    try std.testing.expect(rig.resident.inbound.len != 0);

    // The record that reports the window also reports the end of the stream,
    // so the owed writable event releases the hold before the read finishes.
    rig.resident.write_open = true;
    rig.resident.read_result = 0;
    rig.resident.offer(rig.packets.items[rig.next - 1 ..]);
    rig.next = fetches;
    rig.resident.signal_closed = true;
    try stepUntilClosed(rig);
    try std.testing.expectEqual(@as(?anyerror, null), rig.observed.close_failure);
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_tail);
    try std.testing.expectEqual(@as(usize, 0), rig.resident.inbound.len);
    // The session accepted one answer per request, and the partner never
    // released one, so the count is the requests dispatched. The replies still
    // queued when the end of stream closed the wire leave with it, as they do
    // when the end arrives in a read that was never held.
    try std.testing.expectEqual(fetches, rig.observed.close_inbound_answers);
}

test "a window that reopened silently releases the hold when the closed edge arrives with no writable bit" {
    const fetches = 60;
    const rig = try Rig.create(std.testing.allocator, fetches);
    defer rig.destroy();
    _ = try rig.fillToWaterline();
    rig.offerNext();
    _ = try rig.step();
    const wire = rig.runtime.wires.get(rig.session.peer_handle).?;
    try std.testing.expect(wire.link.pending != null and rig.session.outboundPressured());
    try std.testing.expect(rig.resident.inbound.len != 0);

    // The window opens without a writable record, then the partner's clean
    // end arrives as readable and closed alone.
    rig.resident.write_open = true;
    rig.resident.want_write = false;
    rig.resident.read_result = 0;
    rig.resident.signal_closed = true;
    rig.resident.offer(rig.packets.items[rig.next - 1 ..]);
    rig.next = fetches;
    try stepUntilClosed(rig);
    try std.testing.expectEqual(@as(?anyerror, null), rig.observed.close_failure);
    try std.testing.expectEqual(@as(usize, 0), rig.resident.inbound.len);
    try std.testing.expectEqual(fetches, rig.observed.close_inbound_answers);
    // The pending write drained into the reopened window.
    try std.testing.expect(rig.resident.written.items.len != 0);
}

test "a partner that departs while a read waits for a window that never reopens closes the connection lost" {
    const fetches = 60;
    const rig = try Rig.create(std.testing.allocator, fetches);
    defer rig.destroy();
    _ = try rig.fillToWaterline();
    rig.offerNext();
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), rig.resident.inbound.len);
    try std.testing.expect(rig.session.outboundPressured());

    rig.resident.departs_on_close = true;
    rig.resident.signal_closed = true;
    rig.resident.read_armed = true;
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), rig.observed.close_events);
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionLost), rig.observed.close_failure);
}

test "a close deferred behind the open pause closes the connection lost once the held requests reach the waterline" {
    const fetches = 60;
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = fetches, .opens_on_read = true });
    defer rig.destroy();
    rig.resident.write_open = false;
    rig.resident.departs_on_close = true;
    rig.resident.signal_closed = true;
    rig.resident.offer(&rig.burst);
    try stepUntilClosed(rig);
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionLost), rig.observed.close_failure);
    // The requests ahead of the waterline were dispatched and answered into
    // the refused window.
    try std.testing.expect(rig.resident.write_blocks != 0);
}

test "a resident that answers would-block after its closed edge ends the stream once every buffered request is read" {
    const fetches = 20;
    const rig = try Rig.create(std.testing.allocator, fetches);
    defer rig.destroy();
    rig.resident.signal_closed = true;
    rig.resident.offer(rig.packets.items);
    rig.next = fetches;
    try std.testing.expectEqual(net_would_block, rig.resident.read_result);
    try stepUntilClosed(rig);
    try std.testing.expectEqual(@as(?anyerror, null), rig.observed.close_failure);
    try std.testing.expectEqual(@as(usize, 0), rig.resident.inbound.len);
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_tail);
}

test "a fault signalled while a read waits for the window closes the connection lost" {
    const rig = try Rig.create(std.testing.allocator, 60);
    defer rig.destroy();
    _ = try rig.fillToWaterline();
    rig.offerNext();
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), rig.resident.inbound.len);
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);

    rig.resident.signal_closed = true;
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), rig.observed.close_events);
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionLost), rig.observed.close_failure);
}

test "a departure that precedes the pressure wakes the embedder once the resumed tail meets the refused window" {
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = 60, .opens_on_read = true });
    defer rig.destroy();
    rig.resident.write_open = false;
    rig.resident.departs_on_close = true;
    rig.resident.signal_closed = true;
    rig.resident.offer(&rig.burst);
    // The record reports the end of the stream with the read left at the open
    // pause. The core's tail then resumes into the refused window. Whatever
    // step leaves the wire open and holding input must leave the embedder
    // woken, because no writable event follows a departure.
    for (0..max_rounds) |_| {
        _ = try rig.step();
        if (rig.observed.close_events != 0) break;
        try std.testing.expect(!try rig.quiet());
    } else return error.NeverClosed;
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionLost), rig.observed.close_failure);
}
