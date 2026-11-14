//! Inbound a wire holds while its session is unattended: a byte-stream wire
//! keeps the bytes as they arrived, a message-framed wire hands back the same
//! packets in order, and both stop at the runtime's cap with nothing parked
//! by the refused chunk. A packet read while the session is unattended parks,
//! and attending the session feeds it to the core, where a refusal closes
//! the wire.

const std = @import("std");
const glowcap = @import("glowcap");

const driver = glowcap.driver;
const net = glowcap.net;
const HostRuntime = driver.HostRuntime;

const fixtures = @import("residents.zig");
const ExternalAdoptionResident = fixtures.ExternalAdoptionResident;
const ObservedOpen = fixtures.ObservedOpen;
const Link = HostRuntime.Wire.Link;
const cap = HostRuntime.unattended_parked_cap_bytes;

test "a message-framed wire hands back its parked packets whole and in order" {
    const allocator = std.testing.allocator;
    var link: Link = .{ .index = 0, .conn = 0 };
    defer link.parked.deinit(allocator);

    const sent = [_][]const u8{ "a", "second packet", "\x00\x00\x00\x02", "z" };
    for (sent) |packet| try link.park(allocator, .message, packet);

    var packets = link.parkedPackets();
    for (sent) |packet| try std.testing.expectEqualSlices(u8, packet, packets.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), packets.next());
}

test "a byte-stream wire parks the bytes as they arrived" {
    const allocator = std.testing.allocator;
    var link: Link = .{ .index = 0, .conn = 0 };
    defer link.parked.deinit(allocator);

    try link.park(allocator, .byte_stream, "5:he");
    try link.park(allocator, .byte_stream, "llo");
    try std.testing.expectEqualSlices(u8, "5:hello", link.parked.items);
}

test "a byte-stream wire parks up to the cap and refuses the byte past it" {
    const allocator = std.testing.allocator;
    var link: Link = .{ .index = 0, .conn = 0 };
    defer link.parked.deinit(allocator);

    const full = try allocator.alloc(u8, cap);
    defer allocator.free(full);
    @memset(full, 7);
    try link.park(allocator, .byte_stream, full);
    try std.testing.expectError(error.ConnectionLost, link.park(allocator, .byte_stream, "x"));
    try std.testing.expectEqual(cap, link.parked.items.len);
}

test "a message-framed wire counts each packet's length against the cap" {
    const allocator = std.testing.allocator;
    var link: Link = .{ .index = 0, .conn = 0 };
    defer link.parked.deinit(allocator);

    // One-byte packets are the most packets a peer can park. The heap they
    // take is the cap, and the packet past it parks nothing.
    var parked: usize = 0;
    while (link.park(allocator, .message, "x")) : (parked += 1) {} else |err| {
        try std.testing.expectEqual(error.ConnectionLost, err);
    }
    try std.testing.expect(link.parked.items.len <= cap);
    try std.testing.expect(cap - link.parked.items.len < link.parked.items.len / parked);

    var packets = link.parkedPackets();
    var replayed: usize = 0;
    while (packets.next()) |packet| : (replayed += 1) try std.testing.expectEqualSlices(u8, "x", packet);
    try std.testing.expectEqual(parked, replayed);
}

test "a packet read while unattended parks, and attending feeds it to the core, where a refusal closes the wire" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var resident = ExternalAdoptionResident{
        .wake = try net.wake_channel.WakeChannel.open(),
        .read_result = net.multiplexed_resident.would_block,
    };
    defer resident.wake.deinit();

    var observed = ObservedOpen{};
    var runtime = try HostRuntime.init(allocator, threaded.io(), .{}, .ephemeral, observed.steppedOpts());
    defer runtime.deinit();
    const index = try runtime.addResident(.{
        .symbol = ExternalAdoptionResident.transport,
        .designator_scheme = .key,
        .wire_framing = .message,
        .max_packet_bytes = fixtures.frame_cap + 2048,
    }, resident.multiplexedResident());
    try runtime.startAdoptExternal(
        ExternalAdoptionResident.transport,
        ExternalAdoptionResident.conn_id,
        .dialed,
        41,
        .{
            .ctx = &observed,
            .reserve = ObservedOpen.reserve,
            .release = ObservedOpen.release,
            .opened = ObservedOpen.opened,
            .failed = ObservedOpen.failed,
        },
    );

    const wire = runtime.resident_wires.get(.{ .resident = index, .conn = ExternalAdoptionResident.conn_id }).?;
    runtime.markSessionUnattended(wire.session);
    try std.testing.expect(!wire.attended);

    // Each read is one packet, and neither reaches the core yet.
    const sent = [_][]const u8{ "not a frame", "held behind the refused packet" };
    resident.inbound = &sent;
    _ = try resident.wake.nudge();
    _ = try runtime.stepAny(0);
    var packets = wire.link.parkedPackets();
    for (sent) |packet| try std.testing.expectEqualSlices(u8, packet, packets.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), packets.next());
    try std.testing.expectEqual(@as(usize, 0), resident.close_calls);

    // The first packet reaches the core as one frame and is refused. The
    // wire closes, and the packet behind it is released with the wire.
    try runtime.attendSession(wire.session);
    try std.testing.expectEqual(@as(usize, 1), resident.close_calls);

    resident.close_ready = true;
    _ = try resident.wake.nudge();
    _ = try runtime.stepAny(0);
    try std.testing.expectEqual(error.MalformedFrame, observed.failure.?);
    try std.testing.expect(!observed.did_open);
    try std.testing.expectEqual(@as(usize, 0), runtime.resident_wires.count());
}
