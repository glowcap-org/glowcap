//! Two kinds of identity, each a fixed 32 bytes. A `PeerId` names a peer. It's
//! the double-SHA256 hash that OCapN calls the public identifier. A `SessionId` names
//! one direct session.
//!
//! They're the same size, but they are not interchangeable, and the compiler
//! holds you to that: each is its own struct, so you can't slip a `PeerId` in
//! where a `SessionId` belongs. This file only carries the bytes. The `crypto`
//! module is what derives them.

const std = @import("std");

/// A peer's OCapN public identifier: the double-SHA256 of its public key's
/// gcrypt s-expression form. See `crypto.derivePublicIdentifier`.
pub const PeerId = struct {
    bytes: [32]u8,

    pub fn fromBytes(bytes: [32]u8) PeerId {
        return .{ .bytes = bytes };
    }

    pub fn asBytes(self: *const PeerId) []const u8 {
        return self.bytes[0..];
    }

    pub fn eql(self: PeerId, other: PeerId) bool {
        return std.mem.eql(u8, self.asBytes(), other.asBytes());
    }
};

/// One direct session's identity: the double-SHA256 over `"prot0"` and both
/// sides' sorted `PeerId`s. See `crypto.sessionIdFromPeerIds`.
pub const SessionId = struct {
    bytes: [32]u8,

    pub fn fromBytes(bytes: [32]u8) SessionId {
        return .{ .bytes = bytes };
    }

    pub fn asBytes(self: *const SessionId) []const u8 {
        return self.bytes[0..];
    }

    pub fn eql(self: SessionId, other: SessionId) bool {
        return std.mem.eql(u8, self.asBytes(), other.asBytes());
    }
};
