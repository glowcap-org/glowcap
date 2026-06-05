//! One-session-per-peer-pair registry — the session-pair-uniqueness invariant
//! that makes cross-session distributed equality load-bearing per
//! ADR-0013 § Session-pair uniqueness in `SessionRegistry`.
//!
//! By refusing a second session to a [`foundation.PeerId`] this peer already has
//! one open with, cross-session equality reduces to same-session equality on
//! `(import_id, kind)` (the [`model.referencesEqual`] evidence): the same target
//! always lands at the same import row, so two references to it compare equal.
//!
//! The registry is **caller-held**, mirroring the Zig core's cross-peer posture
//! (Invariant 14): cross-peer coordination state is a value the adapter threads
//! through, not shared mutable session state. The session stays a passive
//! observer — the adapter consults the registry at the `negotiating → open`
//! transition (`register` on open, `unregister` on close), never the session
//! state machine itself. A peer that negotiated `FeatureSet.equality = false`
//! opts out of the property; the adapter simply does not consult the registry
//! for that session.

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
