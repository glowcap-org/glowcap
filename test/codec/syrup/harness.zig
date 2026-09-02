//! Fixture-byte comparison and little byte builders the Syrup suite shares.

const std = @import("std");
const glowcap = @import("glowcap");
const protocol_oracle = @import("../../oracle/protocol_oracle.zig");

pub fn expectFixtureBytes(name: []const u8, frame: glowcap.foundation.Frame) !void {
    const fixture = protocol_oracle.fixtureByName(name).?;
    try std.testing.expectEqualSlices(u8, fixture.bytes(), frame.bytes());
}

pub fn repeatedByte(comptime len: usize, byte: u8) [len]u8 {
    return @as([len]u8, @splat(byte));
}

pub fn hexToOwned(allocator: std.mem.Allocator, comptime hex: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}
