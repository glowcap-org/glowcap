const std = @import("std");
const pancake = @import("pancake");

const foundation = pancake.foundation;

test "peer ids are fixed 32-byte values" {
    const bytes = [_]u8{0x01} ** 32;
    const peer_id = foundation.PeerId.fromBytes(bytes);

    try std.testing.expectEqualSlices(u8, &bytes, peer_id.asBytes());
}

test "session ids compare by value" {
    const a_bytes = [_]u8{0xaa} ** 32;
    const b_bytes = [_]u8{0xbb} ** 32;

    const a = foundation.SessionId.fromBytes(a_bytes);
    const a_again = foundation.SessionId.fromBytes(a_bytes);
    const b = foundation.SessionId.fromBytes(b_bytes);

    try std.testing.expect(a.eql(a_again));
    try std.testing.expect(!a.eql(b));
}
