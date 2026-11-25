//! A session the embedder has not yet attended dispatches nothing, so the
//! partner's departure ends it without feeding the core what is left of the
//! read. The driver's event queue surfaces an opened session unattended. The
//! sweep reads a departure that arrived with the opening record once the
//! session's open has committed, and a later departure is read as it arrives.
//! The close is observed after the open's observer has returned, and it
//! reports the clean end whether or not whole frames wait undispatched, so
//! it reads the same however the transport batched what the partner sent.
//! Only the front of a frame with nothing behind it is `TruncatedFrame`.

const std = @import("std");

const pressure_rig = @import("pressure_rig.zig");
const Rig = pressure_rig.Rig;
const max_rounds = pressure_rig.max_rounds;

/// Step until the close, then a few rounds more, so a second close would show.
fn stepThroughClose(rig: *Rig) !void {
    for (0..max_rounds) |_| {
        _ = try rig.step();
        if (rig.observed.close_events != 0) break;
    } else return error.NeverClosed;
    for (0..8) |_| _ = try rig.step();
}

fn expectClosedOnceAfterOpen(rig: *Rig, failure: ?anyerror) !void {
    try std.testing.expect(rig.observed.did_open);
    try std.testing.expect(!rig.observed.close_inside_open);
    try std.testing.expectEqual(@as(usize, 1), rig.observed.close_events);
    try std.testing.expectEqual(failure, rig.observed.close_failure);
}

test "a hello, its requests, and the partner's departure in one record end a session surfaced unattended cleanly" {
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = 5, .opens_on_read = true, .unattended_on_open = true });
    defer rig.destroy();
    rig.resident.read_result = 0;
    rig.resident.signal_closed = true;
    rig.resident.offer(&rig.burst);
    try stepThroughClose(rig);
    try expectClosedOnceAfterOpen(rig, null);
}

test "a hello with nothing behind it and the partner's departure in one record end a session surfaced unattended cleanly" {
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = 0, .opens_on_read = true, .unattended_on_open = true });
    defer rig.destroy();
    rig.resident.read_result = 0;
    rig.resident.signal_closed = true;
    rig.resident.offer(&rig.burst);
    try stepThroughClose(rig);
    try expectClosedOnceAfterOpen(rig, null);
}

test "a hello coalesced with the partner's next frames, then its departure in a later record, end a session surfaced unattended cleanly" {
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = 5, .opens_on_read = true, .unattended_on_open = true });
    defer rig.destroy();
    rig.resident.offer(&rig.burst);
    for (0..4) |_| _ = try rig.step();
    try std.testing.expect(rig.observed.did_open);
    // The frames behind the hello wait in the core's tail, resumable but not
    // for an unattended session.
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
    // The later record reads one more packet and then the end of the stream.
    rig.resident.offer(rig.packets.items[0..1]);
    rig.resident.read_result = 0;
    try stepThroughClose(rig);
    try expectClosedOnceAfterOpen(rig, null);
}

test "a hello coalesced with the partner's abort, then its departure in a later record, end a session surfaced unattended cleanly" {
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = 0, .opens_on_read = true, .unattended_on_open = true });
    defer rig.destroy();
    const bytes = try rig.helloThenAbort();
    rig.resident.offer(&.{bytes});
    for (0..4) |_| _ = try rig.step();
    try std.testing.expect(rig.observed.did_open);
    try std.testing.expectEqual(@as(usize, 0), rig.observed.close_events);
    // The later record reads one more packet and then the end of the stream.
    rig.resident.offer(&.{@as([]const u8, "x")});
    rig.resident.read_result = 0;
    try stepThroughClose(rig);
    try expectClosedOnceAfterOpen(rig, null);
}

test "a hello, the front of a frame, and the partner's departure end a session surfaced unattended with a truncated frame" {
    const rig = try Rig.build(std.testing.allocator, .{ .fetches = 0, .opens_on_read = true, .unattended_on_open = true });
    defer rig.destroy();
    var cut: std.ArrayList(u8) = .empty;
    defer cut.deinit(std.testing.allocator);
    for (rig.burst) |packet| try cut.appendSlice(std.testing.allocator, packet);
    // A prefix that promises nine bytes, and two of them.
    try cut.appendSlice(std.testing.allocator, "9:ab");
    rig.resident.read_result = 0;
    rig.resident.signal_closed = true;
    rig.resident.offer(&.{cut.items});
    try stepThroughClose(rig);
    try expectClosedOnceAfterOpen(rig, error.TruncatedFrame);
}
