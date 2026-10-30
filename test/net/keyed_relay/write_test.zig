//! Relay write admission remains authoritative when the carrier cannot flush.
//! A caller retries only bytes the stream has not adopted.

const std = @import("std");
const glowcap = @import("glowcap");
const net = glowcap.net;
const fixture = @import("../../support/relay_stream.zig");
const Stream = fixture.Stream;
const would_block = net.multiplexed_resident.would_block;

test "relay write admits a buffered prefix exactly once under carrier backpressure" {
    var buffer: [2048]u8 = undefined;
    var carrier: fixture.Backpressure = .{ .writer = .fixed(&buffer) };
    var stream: Stream = undefined;
    fixture.initStream(&stream, &carrier);
    try std.testing.expectEqual(@as(isize, 3), stream.tryWriteSome("one"));
    try std.testing.expect(stream.hasPendingWrite());
    try std.testing.expectEqual(would_block, stream.tryWriteSome("two"));
    try std.testing.expectEqual(@as(usize, 9), carrier.writer.end);
    carrier.blocked = false;
    try std.testing.expectEqual(@as(isize, 3), stream.tryWriteSome("two"));
    try std.testing.expect(!stream.hasPendingWrite());
    try std.testing.expectEqual(@as(usize, 18), carrier.sent_len);
    for ([_][]const u8{ "one", "two" }, 0..) |payload, i| {
        const wire = carrier.sent[i * 9 ..][0..9];
        try std.testing.expectEqual(@as(u8, 0x82), wire[0]);
        try std.testing.expectEqual(@as(u8, 0x83), wire[1]);
        for (payload, 0..) |byte, j|
            try std.testing.expectEqual(byte, wire[6 + j] ^ wire[2 + j % 4]);
    }
    try std.testing.expectEqual(@as(?glowcap.foundation.FailureChain, null), stream.takeFailure());
}
