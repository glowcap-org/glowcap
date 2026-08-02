//! Crossed-hellos tiebreak state (ADR-0030): the outbound-dial table an
//! accepted session's inbound `op:start-session` is compared against, unlocked
//! because one thread drives one host by contract. `openDialedLocator`
//! registers the outbound before its hello moves; the host condemns the losing
//! session immediately rather than deferring a flag to a later pump. Public for
//! its unit tests; embedders never touch it — the host runs the tiebreak
//! itself.
//!
//! The tiebreak is **two operations over two different identities**, and
//! keeping them apart is the whole design (ADR-0097):
//!
//!   1. **Matching** asks which two connection attempts are racing. That is a
//!      question about the *durable peer*, so the key is the partner
//!      designator — the peer's own key on a key-designator transport, and its
//!      declared location on an address transport, with the stated weakness the
//!      host's caller documents.
//!   2. **Ordering** asks which of the two racing sessions survives. That is a
//!      question about *session identity*, so it compares the OCapN session
//!      identifiers derived from the two connections' `session_pubkey`s — ours
//!      on the outbound, the partner's on the inbound.
//!
//! They coincide today only because every session in a host is signed by the
//! host's durable key. Once each connection draws a fresh session key, matching
//! must keep using the durable designator while ordering picks up the new
//! per-connection identifiers, and a single conflated key would silently do the
//! wrong one. The field names here say which is which so that change is one
//! call site, not a rediscovery.

const std = @import("std");

const foundation = @import("foundation");

pub const CrossedHellos = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct {
        /// The matching axis: the durable peer this outbound dial is trying to
        /// reach.
        partner_durable: []const u8,
        /// The ordering axis: the OCapN session identifier derived from *this
        /// outbound connection's* own session key.
        our_session_id: foundation.PeerId,
    };

    /// The tiebreak verdict for a crossed inbound: the side whose identifier
    /// is *not* lower aborts its inbound session, so both peers keep the
    /// session the higher-keyed peer opened.
    pub const Verdict = struct { abort_inbound: bool };

    pub fn registerOutbound(
        self: *CrossedHellos,
        allocator: std.mem.Allocator,
        partner_durable: []const u8,
        our_session_id: foundation.PeerId,
    ) !void {
        const owned = try allocator.dupe(u8, partner_durable);
        errdefer allocator.free(owned);
        try self.entries.append(allocator, .{ .partner_durable = owned, .our_session_id = our_session_id });
    }

    /// Match an inbound start-session against the registered outbound dials by
    /// durable peer, then order the two racing sessions by their session
    /// identifiers. Null when no dial to `partner_durable` is outstanding (no
    /// collision), so the caller does nothing.
    pub fn checkInbound(
        self: *const CrossedHellos,
        partner_durable: []const u8,
        inbound_session_id: foundation.PeerId,
    ) ?Verdict {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.partner_durable, partner_durable)) {
                const order = std.mem.order(u8, &entry.our_session_id.bytes, &inbound_session_id.bytes);
                return .{ .abort_inbound = order != .lt };
            }
        }
        return null;
    }

    /// Remove exactly one entry for `partner_durable`: one row is appended
    /// per dial, so a sweep would drop a sibling dial's still-live entry.
    pub fn unregister(self: *CrossedHellos, allocator: std.mem.Allocator, partner_durable: []const u8) void {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.partner_durable, partner_durable)) {
                allocator.free(entry.partner_durable);
                _ = self.entries.orderedRemove(i);
                return;
            }
        }
    }

    pub fn deinit(self: *CrossedHellos, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.partner_durable);
        self.entries.deinit(allocator);
    }
};
