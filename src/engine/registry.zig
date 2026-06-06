//! Keeping it to one session per peer, which is the thing that makes cross-session
//! equality work (ADR-0013).
//!
//! Here's the trick behind distributed equality. If you never open a second
//! session to a peer you already have one with, then "are these two references the
//! same across sessions?" collapses to "are they the same `(import_id, kind)`
//! within a session?" The same target always lands in the same import row, so two
//! references to it compare equal. This registry is what enforces the one-session
//! part, by turning away the second one.
//!
//! You hold the registry, not the session. That follows the core's general stance
//! on cross-peer state: it's a value the adapter threads through, not shared
//! mutable session state. The session itself just watches. The adapter checks the
//! registry as a session goes from negotiating to open (`register` when it opens,
//! `unregister` when it closes), and the state machine never touches it. A peer
//! that negotiated without the equality feature simply opts out, and the adapter
//! just doesn't consult the registry for that session.

const std = @import("std");
const foundation = @import("../foundation/mod.zig");

pub const Error = error{
    /// `register` was called for a [`foundation.PeerId`] that already has an open
    /// session. The session-pair-uniqueness invariant
    /// (ADR-0013 § Session-pair uniqueness in `SessionRegistry`) is
    /// a loud refusal, never a silent second session.
    PeerAlreadyOpen,
};

/// A set of [`foundation.PeerId`]s with open sessions. Caller-owned; `deinit`
/// releases its backing storage.
pub const SessionRegistry = struct {
    peers: std.ArrayList(foundation.PeerId),

    pub const empty: SessionRegistry = .{ .peers = .empty };

    pub fn deinit(self: *SessionRegistry, allocator: std.mem.Allocator) void {
        self.peers.deinit(allocator);
    }

    /// Record an open session to `peer`. Returns [`Error.PeerAlreadyOpen`] when
    /// one already exists, enforcing session-pair uniqueness (ADR-0013).
    pub fn register(self: *SessionRegistry, allocator: std.mem.Allocator, peer: foundation.PeerId) !void {
        if (self.contains(peer)) return Error.PeerAlreadyOpen;
        try self.peers.append(allocator, peer);
    }

    /// Drop the open-session record for `peer`. Returns whether an entry was
    /// removed (false when none was registered).
    pub fn unregister(self: *SessionRegistry, peer: foundation.PeerId) bool {
        for (self.peers.items, 0..) |entry, index| {
            if (entry.eql(peer)) {
                _ = self.peers.orderedRemove(index);
                return true;
            }
        }
        return false;
    }

    /// Whether `peer` has an open session recorded.
    pub fn contains(self: *const SessionRegistry, peer: foundation.PeerId) bool {
        for (self.peers.items) |entry| {
            if (entry.eql(peer)) return true;
        }
        return false;
    }
};
