//! Buffered input stays readable across every carrier progress path, including
//! an inline write flush and a control-only read that yields its frame budget.

const std = @import("std");
const glowcap = @import("glowcap");
const relay = @import("c_abi_net_transport_relay");
const c = @import("c_abi_shared");
const fixture = @import("../../support/relay_stream.zig");
const State = relay.white_box.ConnectionState;
const would_block = glowcap.net.multiplexed_resident.would_block;
const readable = c.multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_READABLE;

test "relay readiness survives an inline write flushing deferred input" {
    var buffer: [2048]u8 = undefined;
    var carrier: fixture.Backpressure = .{ .writer = .fixed(&buffer) };
    carrier.reader = .fixed(&.{ 0x82, 4, 't', 'a', 'i', 'l' });
    var stream: fixture.Stream = undefined;
    fixture.initStream(&stream, &carrier);
    try std.testing.expectEqual(@as(isize, 7), stream.tryWriteSome("pending"));
    var state = State.init(.{ .stream = &stream });
    try std.testing.expectEqual(readable, state.events.swap(0, .acq_rel));
    var dest: [4]u8 = undefined;
    const deferred = state.tryReadLocked(&dest);
    try std.testing.expectEqual(would_block, deferred.count);
    try std.testing.expect(!deferred.signal_ready);
    carrier.blocked = false;
    const written = state.tryWriteLocked("out");
    try std.testing.expectEqual(@as(isize, 3), written.count);
    try std.testing.expect(written.signal_ready);
    try std.testing.expectEqual(readable, state.events.swap(0, .acq_rel));
    const resumed = state.tryReadLocked(&dest);
    try std.testing.expectEqual(@as(isize, 4), resumed.count);
    try std.testing.expectEqualStrings("tail", &dest);
}

test "relay readiness survives a control-only read yielding its frame budget" {
    const budget = glowcap.net.relay.white_box.max_frames_per_read;
    var wire: [2 * budget + 3]u8 = undefined;
    for (0..budget) |i| wire[i * 2 ..][0..2].* = .{ 0x8a, 0 };
    wire[2 * budget ..].* = .{ 0x82, 1, 'x' };
    var buffer: [2048]u8 = undefined;
    var carrier: fixture.Backpressure = .{ .writer = .fixed(&buffer) };
    carrier.reader = .fixed(&wire);
    var stream: fixture.Stream = undefined;
    fixture.initStream(&stream, &carrier);
    var state = State.init(.{ .stream = &stream });
    try std.testing.expectEqual(readable, state.events.swap(0, .acq_rel));
    var dest: [1]u8 = undefined;
    const yielded = state.tryReadLocked(&dest);
    try std.testing.expectEqual(would_block, yielded.count);
    try std.testing.expect(yielded.signal_ready);
    try std.testing.expectEqual(readable, state.events.swap(0, .acq_rel));
    const resumed = state.tryReadLocked(&dest);
    try std.testing.expectEqual(@as(isize, 1), resumed.count);
    try std.testing.expectEqual(@as(u8, 'x'), dest[0]);
}

test "relay readiness waits for incomplete headers and control payloads" {
    for ([_][]const u8{ &.{}, &.{0x82}, &.{ 0x82, 126, 0 }, &.{ 0x89, 2, 'h' } }) |wire| {
        var buffer: [2048]u8 = undefined;
        var carrier: fixture.Backpressure = .{ .writer = .fixed(&buffer), .blocked = false };
        carrier.reader = .fixed(wire);
        var stream: fixture.Stream = undefined;
        fixture.initStream(&stream, &carrier);
        var state = State.init(.{ .stream = &stream });
        try std.testing.expectEqual(@as(u32, 0), state.events.swap(0, .acq_rel));
        var dest: [1]u8 = undefined;
        const read = state.tryReadLocked(&dest);
        try std.testing.expectEqual(would_block, read.count);
        try std.testing.expect(!read.signal_ready);
        const written = state.tryWriteLocked("out");
        try std.testing.expectEqual(@as(isize, 3), written.count);
        try std.testing.expect(!written.signal_ready);
        try std.testing.expectEqual(@as(u32, 0), state.events.load(.acquire));
    }
}

test "relay readiness exposes a malformed buffered frame immediately" {
    var buffer: [2048]u8 = undefined;
    var carrier: fixture.Backpressure = .{ .writer = .fixed(&buffer) };
    carrier.reader = .fixed(&.{ 0x83, 0 });
    var stream: fixture.Stream = undefined;
    fixture.initStream(&stream, &carrier);
    var state = State.init(.{ .stream = &stream });
    try std.testing.expectEqual(readable, state.events.swap(0, .acq_rel));
    var dest: [1]u8 = undefined;
    const rejected = state.tryReadLocked(&dest);
    try std.testing.expectEqual(@as(isize, -1), rejected.count);
    try std.testing.expect(!rejected.signal_ready);
    try std.testing.expectEqualStrings("ProtocolViolation", state.claimFailure().?.primaryName());
}
