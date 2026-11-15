//! A session the embedder has not attended parks the partner's input on its
//! wire. The embedder's own verbs can queue outbound on that session up to
//! its waterline before it attends, so the parked input meets a session that
//! refuses new input. The input waits parked until the outbound drains.

const std = @import("std");

const pressure_rig = @import("pressure_rig.zig");
const Rig = pressure_rig.Rig;
const max_rounds = pressure_rig.max_rounds;
const waterline = pressure_rig.waterline;

/// Step until every fetch is read and the queue is empty.
fn drain(rig: *Rig) !void {
    for (0..max_rounds) |_| {
        _ = try rig.step();
        const wire = rig.runtime.wires.get(rig.session.peer_handle).?;
        if (rig.resident.inbound.len == 0 and wire.link.parked.items.len == 0 and
            !wire.link.read_deferred and rig.queued() == 0 and !rig.session.feed_resume_pending) return;
    }
    return error.NeverDrained;
}

fn expectHeld(rig: *Rig) !void {
    const wire = rig.runtime.wires.get(rig.session.peer_handle).?;
    try std.testing.expect(!rig.session.isTerminating());
    try std.testing.expect(!wire.closed);
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
    try std.testing.expect(wire.link.parked.items.len != 0);
    const parked = wire.link.parked.items.len;
    const queued = rig.queued();
    for (0..5) |_| {
        _ = try rig.stepQuiet();
        try std.testing.expectEqual(parked, wire.link.parked.items.len);
        try std.testing.expectEqual(queued, rig.queued());
    }
    try std.testing.expect(try rig.quiet());
}

test "attending a pressured session keeps its wire open and its parked input held until the window opens" {
    const rig = try Rig.createWith(std.testing.allocator, 20, false, waterline);
    defer rig.destroy();
    try rig.parkAndPressure(20);
    try rig.runtime.attendSession(rig.session);
    try expectHeld(rig);

    rig.resident.write_open = true;
    try drain(rig);
    try std.testing.expect(rig.session.sessionOpen());
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
    try rig.expectAnswersInOrder();
}

test "attending a session pressured at the default waterline keeps its wire open" {
    const rig = try Rig.createWith(std.testing.allocator, 20, false, null);
    defer rig.destroy();
    try rig.parkAndPressure(20);
    try rig.runtime.attendSession(rig.session);
    try expectHeld(rig);

    rig.resident.write_open = true;
    try drain(rig);
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
    try rig.expectAnswersInOrder();
}

test "parked input is answered before input the partner sends after it" {
    const rig = try Rig.createWith(std.testing.allocator, 20, false, waterline);
    defer rig.destroy();
    try rig.parkAndPressure(10);
    try rig.runtime.attendSession(rig.session);
    // The rest of the partner's fetches wait in the resident behind the
    // parked ones, and the core takes none of them.
    rig.resident.offer(rig.packets.items[10..]);
    for (0..5) |_| _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 10), rig.resident.inbound.len);
    try expectHeld(rig);

    rig.resident.write_open = true;
    try drain(rig);
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
    try rig.expectAnswersInOrder();
}

test "a partner that departs while parked input waits behind a refused write wakes the embedder, and the next step closes the wire" {
    const rig = try Rig.createWith(std.testing.allocator, 20, false, waterline);
    defer rig.destroy();
    try rig.parkAndPressure(20);
    try rig.runtime.attendSession(rig.session);
    try expectHeld(rig);

    rig.resident.departs_on_close = true;
    rig.resident.signal_closed = true;
    rig.resident.read_armed = true;
    _ = try rig.step();
    // The held wire stays open, but no writable event is owed after the
    // departure, so the embedder is woken to let the sweep close it.
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
    try std.testing.expect(!try rig.quiet());
    _ = try rig.stepQuiet();
    try std.testing.expectEqual(@as(usize, 1), rig.observed.close_events);
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionLost), rig.observed.close_failure);
}
