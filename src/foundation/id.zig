const std = @import("std");

fn FixedId(comptime Name: []const u8) type {
    return struct {
        const Self = @This();

        bytes: [32]u8,

        pub fn fromBytes(bytes: [32]u8) Self {
            return .{ .bytes = bytes };
        }

        pub fn asBytes(self: *const Self) []const u8 {
            return self.bytes[0..];
        }

        pub fn eql(self: Self, other: Self) bool {
            return std.mem.eql(u8, self.asBytes(), other.asBytes());
        }

        pub fn label() []const u8 {
            return Name;
        }
    };
}

pub const PeerId = FixedId("PeerId");
pub const SessionId = FixedId("SessionId");
