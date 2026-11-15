//! A stepped Host holds a session's reads while its queued outbound is at its
//! waterline (ADR-0017). The core refuses new input there, and that refusal
//! is a retry signal, so the runtime leaves the unread input in the resident
//! and the session open, then resumes it when the outbound drains. A scripted
//! resident delivers a partner's fetches and refuses writes on demand, so a
//! test chooses when the write window is closed.

const std = @import("std");

const raw_partner = @import("raw_partner.zig");
const pressure_rig = @import("pressure_rig.zig");
const Rig = pressure_rig.Rig;
const max_rounds = pressure_rig.max_rounds;
const waterline = pressure_rig.waterline;

test "a stepped Host stops reading at its waterline, keeps the session, and answers every fetch once the window opens" {
    try stopsReadingAtWaterline(false);
}

test "a stepped Host stops reading at its waterline the same way when its resident lends the bytes" {
    try stopsReadingAtWaterline(true);
}

fn stopsReadingAtWaterline(lending: bool) !void {
    const fetches = 60;
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = fetches, .lending = lending });
    defer rig.destroy();
    const reply_bytes = try rig.fillToWaterline();
    try std.testing.expect(reply_bytes != 0);
    try std.testing.expect(rig.queued() >= waterline);
    // The read that crossed the waterline was the last one taken. The next
    // offer is reported once, held by `holdRead` in the resident, and left
    // there, which reports nothing more for it.
    rig.offerNext();
    const taken = rig.next;
    try std.testing.expect(taken < fetches);
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), rig.resident.inbound.len);

    // Further steps take no more input and queue no more replies, and the
    // embedder is not woken for input the session cannot take.
    const held = rig.queued();
    try std.testing.expect(held <= waterline + reply_bytes);
    for (0..10) |_| {
        _ = try rig.stepQuiet();
        try std.testing.expectEqual(held, rig.queued());
        try std.testing.expectEqual(@as(usize, 1), rig.resident.inbound.len);
        try std.testing.expect(rig.session.sessionOpen());
        try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
        try std.testing.expect(try rig.quiet());
    }
    try std.testing.expectEqual(taken, rig.next);

    // The window opens: the held input moves, the rest follows, and every
    // reply leaves.
    rig.resident.write_open = true;
    for (0..max_rounds) |_| {
        rig.offerNext();
        _ = try rig.step();
        if (rig.next == fetches and rig.resident.inbound.len == 0 and rig.queued() == 0 and !rig.session.feed_resume_pending) break;
    } else return error.NeverDrained;
    try std.testing.expect(rig.session.sessionOpen());
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
    try rig.expectAnswersInOrder();
}

test "a stepped Host holds the whole frames one read left in the tail while its window is closed" {
    const fetches = 60;
    const rig = try Rig.create(std.testing.allocator, fetches);
    defer rig.destroy();
    rig.resident.write_open = false;
    rig.burst = .{rig.frames.items};
    rig.resident.offer(&rig.burst);
    _ = try rig.step();
    try std.testing.expect(rig.session.feed_tail.len != 0);

    // The window refuses the first reply, which stays pending outside the
    // queue, so the sweep dispatches held frames until the queue is back at
    // the line. Then nothing moves.
    var settled = false;
    for (0..max_rounds) |_| {
        const queued = rig.queued();
        const tail = rig.session.feed_tail.len;
        _ = try rig.step();
        if (rig.queued() == queued and rig.session.feed_tail.len == tail) {
            settled = true;
            break;
        }
    }
    try std.testing.expect(settled);
    try std.testing.expect(rig.session.outboundPressured());
    try std.testing.expect(rig.session.feed_tail.len != 0);
    const held = rig.queued();
    const tail = rig.session.feed_tail.len;
    for (0..10) |_| {
        _ = try rig.stepQuiet();
        try std.testing.expectEqual(held, rig.queued());
        try std.testing.expectEqual(tail, rig.session.feed_tail.len);
        try std.testing.expect(rig.session.sessionOpen());
    }
    try std.testing.expect(try rig.quiet());

    rig.resident.write_open = true;
    for (0..max_rounds) |_| {
        _ = try rig.step();
        if (rig.session.feed_tail.len == 0 and !rig.session.feed_resume_pending and rig.queued() == 0) break;
    } else return error.NeverDrained;
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
    try rig.expectAnswersInOrder();
}

test "the step after the window opens wakes the embedder and takes the input a pressured read left in the resident" {
    const fetches = 60;
    const rig = try Rig.create(std.testing.allocator, fetches);
    defer rig.destroy();
    _ = try rig.fillToWaterline();
    rig.offerNext();
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), rig.resident.inbound.len);
    try std.testing.expect(try rig.quiet());

    // The writable record drains the queue. No read record follows, because
    // the resident reported its one already, so the step's own nudge is the
    // only thing that can bring the deferred read back.
    rig.resident.write_open = true;
    try std.testing.expect(try rig.step() != null);
    try std.testing.expectEqual(@as(usize, 0), rig.queued());
    try std.testing.expectEqual(@as(usize, 1), rig.resident.inbound.len);
    try std.testing.expect(try raw_partner.readable(rig.ready_fd));

    // That step moved the held read, which is progress no source reports.
    try std.testing.expect(try rig.runtime.stepAny(0) != null);
    try std.testing.expectEqual(@as(usize, 0), rig.resident.inbound.len);
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
}

test "an open window never holds a read, however many replies one readiness event queues" {
    try openWindowHoldsNoRead(false);
}

test "an open window never holds a lent read either" {
    try openWindowHoldsNoRead(true);
}

fn openWindowHoldsNoRead(lending: bool) !void {
    const fetches = 60;
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = fetches, .lending = lending });
    defer rig.destroy();
    // Every fetch is its own read, and the one record the resident reports
    // covers them all. The replies they queue pass the waterline many times
    // over, and the open window takes each before the next read.
    rig.resident.offer(rig.packets.items);
    rig.next = fetches;
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 0), rig.resident.inbound.len);
    try std.testing.expect(!rig.runtime.wires.get(rig.session.peer_handle).?.link.read_deferred);
    try std.testing.expect(rig.queued() < waterline);
    for (0..max_rounds) |_| {
        if (rig.queued() == 0) break;
        _ = try rig.step();
    }
    try rig.expectAnswersInOrder();
}

test "a blocking drive finishes a read the waterline held in the resident without another readiness record" {
    const fetches = 200;
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = fetches, .blocking = true });
    defer rig.destroy();
    // The first read pauses the core at its waterline, and the second waits
    // in the resident behind it. The resident reports its record once, and
    // the drain that empties the queue is the only thing that can bring the
    // held read back, so a drive that parks there waits out its budget.
    // One fetch measures a reply, so the flag can ask for nearly all of them.
    rig.resident.offer(rig.packets.items[0..1]);
    _ = try rig.step();
    const reply_bytes = rig.resident.written.items.len;
    try std.testing.expect(reply_bytes != 0);
    rig.resident.written_target = reply_bytes * (fetches - 5);
    const rest = rig.frames.items[rig.packets.items[0].len..];
    const reads = [_][]const u8{ rest[0 .. rest.len / 2], rest[rest.len / 2 ..] };
    rig.resident.offer(&reads);
    _ = try rig.resident.wake.nudge();
    const io = rig.threaded.io();
    const started = std.Io.Clock.awake.now(io);
    try rig.runtime.pumpUntilFlag(rig.session, &rig.resident.written_reached, .{ .ms = 10_000 });
    const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try std.testing.expect(elapsed_ms < 5000);
    try std.testing.expectEqual(@as(usize, 0), rig.resident.inbound.len);
}
