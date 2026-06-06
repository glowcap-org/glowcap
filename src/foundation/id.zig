//! Two kinds of identity, each a fixed 32 bytes. A `PeerId` names a peer; it's
//! the SHA256² hash that OCapN calls the public identifier. A `SessionId` names
//! one direct session.
//!
//! They're the same size, but they are not interchangeable, and the compiler
//! holds you to that. Each is minted from the `FixedId` template with its own
//! name tag, so you can't slip a `PeerId` in where a `SessionId` belongs. This
//! file only carries the bytes. The `crypto` module is what derives them.

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

        /// This tag is the whole reason `PeerId` and `SessionId` stay separate
        /// types. Two structs with identical fields would otherwise collapse into
        /// one, and the compiler would happily take a `PeerId` where you meant a
        /// `SessionId`. Mentioning `Name` here gives each of them its own identity.
        pub const label: []const u8 = Name;
    };
}

pub const PeerId = FixedId("PeerId");
pub const SessionId = FixedId("SessionId");
