//! The edges of the sweep that holds a stepped session's input while its
//! outbound is at the waterline: the offer that meets the window, and a
//! message-framed wire's parked packets.

const std = @import("std");

const glowcap = @import("glowcap");
const driver = glowcap.driver;

const pressure_rig = @import("pressure_rig.zig");
const core_harness = @import("../core_host/harness.zig");
const CapturedRef = @import("../../support/capture.zig").CapturedRef;
const Rig = pressure_rig.Rig;
const max_rounds = pressure_rig.max_rounds;
const waterline = pressure_rig.waterline;

test "a failed offer of the queue to the window closes the wire with the write's error and every caller stops" {
    const rig = try Rig.createWith(std.testing.allocator, 5, false, waterline);
    defer rig.destroy();
    try rig.park(5);
    // The embedder's own verbs queue past the waterline with no step between,
    // so no write has met the window.
    while (!rig.session.outboundPressured()) _ = try rig.runtime.core.fetch(rig.session, "treasure");
    const base = rig.resident.write_attempts;
    rig.resident.write_fails = true;
    try rig.runtime.attendSession(rig.session);
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), rig.observed.close_events);
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionLost), rig.observed.close_failure);
    // The attend's replay makes the one offer, and nothing asks again after
    // the failure.
    const attempts = rig.resident.write_attempts;
    try std.testing.expectEqual(base + 1, attempts);
    for (0..5) |_| _ = try rig.stepQuiet();
    try std.testing.expectEqual(attempts, rig.resident.write_attempts);
}

test "a write the window refused is not offered again until it reports a writable window" {
    const rig = try Rig.create(std.testing.allocator, 60);
    defer rig.destroy();
    _ = try rig.fillToWaterline();
    rig.offerNext();
    _ = try rig.step();
    try std.testing.expectEqual(@as(usize, 1), rig.resident.inbound.len);
    const attempts = rig.resident.write_attempts;
    for (0..10) |_| _ = try rig.stepQuiet();
    try std.testing.expectEqual(attempts, rig.resident.write_attempts);
}

test "a message-framed wire replays its parked packets in order and stops at the first the waterline refuses" {
    const fetches = 40;
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = fetches, .attended = false, .message = true });
    defer rig.destroy();
    rig.resident.write_open = false;
    try rig.park(fetches);
    const wire = rig.runtime.wires.get(rig.session.peer_handle).?;
    const before = wire.link.parked.items.len;
    try rig.runtime.attendSession(rig.session);
    _ = try rig.step();
    // The core took packets until the queue reached the line, dropped them
    // from the buffer, and left the first refused packet and those after it.
    try std.testing.expect(rig.session.outboundPressured());
    try std.testing.expect(wire.link.parked.items.len != 0);
    try std.testing.expect(wire.link.parked.items.len < before);
    var left: usize = 0;
    var packets = wire.link.parkedPackets();
    while (packets.next()) |_| left += 1;
    try std.testing.expect(left != 0 and left < fetches);
    const held = wire.link.parked.items.len;
    for (0..5) |_| {
        _ = try rig.stepQuiet();
        try std.testing.expectEqual(held, wire.link.parked.items.len);
    }

    rig.resident.write_open = true;
    for (0..max_rounds) |_| {
        _ = try rig.step();
        if (wire.link.parked.items.len == 0 and rig.queued() == 0) break;
    } else return error.NeverDrained;
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
    try rig.expectAnswersInOrder();
}

test "the sweep's resume of an incomplete tail under a deferred read queues nothing and wakes no one" {
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = 4, .opens_on_read = true });
    defer rig.destroy();
    // The hello and the front of one frame arrive together. The open pauses
    // the read, so the core keeps the front in its tail.
    const cut = rig.hello[0].len + 5;
    rig.burst = .{rig.opening.items[0..cut]};
    rig.resident.offer(&rig.burst);
    _ = try rig.step();
    const session = rig.observed.session orelse return error.NeverOpened;
    const wire = rig.runtime.wires.get(session.peer_handle).?;
    try std.testing.expect(wire.link.read_deferred);
    try std.testing.expectEqual(@as(usize, 5), session.feed_tail.len);

    _ = try rig.stepQuiet();
    try std.testing.expect(!wire.link.read_deferred);
    try std.testing.expectEqual(@as(usize, 5), session.feed_tail.len);
    try std.testing.expect(!session.feed_resume_pending);
    try std.testing.expect(try rig.quiet());
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
}

test "the park bound leaves the session a pump is itself opening to that pump" {
    const rig = try Rig.create(std.testing.allocator, 1);
    defer rig.destroy();
    // The hello's read paused at the open, so one step finishes it.
    _ = try rig.stepQuiet();
    // The state is constructed: a read the sweep left deferred on an attended
    // wire is work no readiness source reports, and the bound polls for it.
    // This test proves only that the session a pump is itself opening is
    // left out of that poll.
    const wire = rig.runtime.wires.get(rig.session.peer_handle).?;
    wire.link.read_deferred = true;
    // The hint a sweep that saw the wire would have set.
    rig.runtime.held_input_possible = true;
    const bound = driver.HostRuntime.testing.parkBoundMs;
    try std.testing.expectEqual(@as(i32, 0), bound(&rig.runtime, 500, null));
    try std.testing.expectEqual(@as(i32, 500), bound(&rig.runtime, 500, rig.session));
}

/// A reference the partner exported, imported through one fetch the partner
/// answers. A send to it stages as a carrier no step has encoded.
fn importPartnerRef(rig: *Rig) !glowcap.ocapn.model.Reference {
    _ = try rig.partner.host.publish("gem", core_harness.Widget, .{});
    var captured: CapturedRef = .{};
    try rig.runtime.core.vowOn(try rig.runtime.core.fetch(rig.session, "gem"), .{ .ctx = &captured, .func = CapturedRef.record });
    _ = try rig.step();
    try rig.feedPartner(rig.resident.written.items, rig.resident.write_ends.items);
    rig.resident.written.clearRetainingCapacity();
    rig.resident.write_ends.clearRetainingCapacity();
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(rig.allocator);
    try rig.takeFrames(&reply);
    const packets = [1][]const u8{reply.items};
    rig.resident.offer(&packets);
    for (0..8) |_| {
        _ = try rig.step();
        if (captured.ref != null) break;
    }
    return captured.require();
}

/// The wire holds a deferred read behind a refused write. One stepSession
/// delivers the writable event, so the write goes out and the deferred read
/// stays. Then the embedder stages sends up to the waterline with no step.
fn deferredReadBehindStagedSends() !*Rig {
    const rig = try Rig.create(std.testing.allocator, 60);
    errdefer rig.destroy();
    const gem = try importPartnerRef(rig);
    _ = try rig.fillToWaterline();
    rig.offerNext();
    _ = try rig.step();
    const wire = rig.runtime.wires.get(rig.session.peer_handle).?;
    try std.testing.expect(wire.link.read_deferred and wire.link.pending != null);
    rig.resident.write_open = true;
    _ = try rig.resident.wake.nudge();
    _ = try rig.runtime.stepSession(rig.session, 0);
    try std.testing.expect(wire.link.read_deferred and wire.link.pending == null);
    try std.testing.expect(!rig.session.outboundPressured());
    while (!rig.session.outboundPressured()) _ = try rig.runtime.core.queueSend(rig.session, gem, .{ .verb = "poke", .args = &.{} });
    return rig;
}

fn elapsedMs(rig: *Rig, started: std.Io.Timestamp) i64 {
    return started.durationTo(std.Io.Clock.awake.now(rig.threaded.io())).toMilliseconds();
}

test "a stepSession with a long timeout polls when its drain frees a deferred read the sweep skipped" {
    const rig = try deferredReadBehindStagedSends();
    defer rig.destroy();
    const wire = rig.runtime.wires.get(rig.session.peer_handle).?;
    try std.testing.expect(rig.session.outboundPressured());
    const started = std.Io.Clock.awake.now(rig.threaded.io());
    _ = try rig.runtime.stepSession(rig.session, 10_000);
    try std.testing.expect(elapsedMs(rig, started) < 5000);
    // The drain freed the session but left the read, which no readiness
    // source reports, so the next step takes it.
    try std.testing.expect(!rig.session.outboundPressured());
    try std.testing.expect(wire.link.read_deferred);
    try std.testing.expectEqual(@as(usize, 1), rig.resident.inbound.len);
    _ = try rig.runtime.stepSession(rig.session, 0);
    try std.testing.expectEqual(@as(usize, 0), rig.resident.inbound.len);
}

/// Close once with the write's failure, then touch the wire no more: no write
/// is attempted, nothing is queued, and nothing is left unread by a feed.
fn expectClosedOnceAndQuiet(rig: *Rig, attempts: usize) !void {
    try std.testing.expectEqual(@as(usize, 1), rig.observed.close_events);
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionLost), rig.observed.close_failure);
    try std.testing.expectEqual(attempts, rig.resident.write_attempts);
    const queued = rig.queued();
    for (0..5) |_| _ = try rig.stepQuiet();
    try std.testing.expectEqual(@as(usize, 1), rig.observed.close_events);
    try std.testing.expectEqual(attempts, rig.resident.write_attempts);
    try std.testing.expectEqual(queued, rig.queued());
}

test "a failed offer inside the sweep closes the attended wire once and the sweep goes no further" {
    const rig = try Rig.create(std.testing.allocator, 60);
    defer rig.destroy();
    _ = try rig.fillToWaterline();
    rig.offerNext();
    _ = try rig.step();
    const wire = rig.runtime.wires.get(rig.session.peer_handle).?;
    try std.testing.expect(wire.link.read_deferred and wire.link.pending != null);
    // The writable event sends the refused write and leaves the deferred
    // read, so the wire holds input with nothing pending at the window.
    rig.resident.write_open = true;
    _ = try rig.step();
    try std.testing.expect(wire.link.read_deferred and wire.link.pending == null);
    while (!rig.session.outboundPressured()) _ = try rig.runtime.core.fetch(rig.session, "treasure");
    const attempts = rig.resident.write_attempts + 1;
    rig.resident.write_fails = true;
    _ = try rig.stepQuiet();
    try std.testing.expectEqual(@as(usize, 1), rig.observed.close_events);
    try expectClosedOnceAndQuiet(rig, attempts);
}

test "a failed offer inside the read closes the attended wire once and the read stops" {
    const rig = try Rig.create(std.testing.allocator, 60);
    defer rig.destroy();
    const base = rig.resident.write_attempts;
    rig.resident.write_fails = true;
    // One readable service takes chunk after chunk. The replies queue until
    // the waterline, and the read's next hold offers them to the failing
    // window.
    rig.resident.offer(rig.packets.items);
    _ = try rig.step();
    try std.testing.expect(rig.resident.inbound.len != 0);
    try expectClosedOnceAndQuiet(rig, base + 1);
}

test "attending a wire whose replay leaves a resumable tail raises the held-input hint" {
    const rig = try Rig.createWith(std.testing.allocator, 60, false, waterline);
    defer rig.destroy();
    try rig.park(60);
    // The state is constructed: the sweep that precedes a wait has run and
    // found nothing, and the embedder attends from a callback in the window.
    rig.runtime.held_input_possible = false;
    try rig.runtime.attendSession(rig.session);
    // The replay's feed reached the waterline and kept the rest in the tail.
    try std.testing.expect(rig.session.inboundResumable());
    try std.testing.expect(rig.runtime.held_input_possible);
}
