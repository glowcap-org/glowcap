//! Crossed-hellos tiebreak state (ADR-0030): the outbound-dial table an
//! accepted session's inbound `op:start-session` is compared against, unlocked
//! because one thread drives one host by contract. `openDialedLocator`
//! registers the outbound before its hello moves. The host condemns the losing
//! session immediately rather than deferring a flag to a later pump. Public for
//! its unit tests. Embedders never touch it, since the host runs the tiebreak.
//!
//! The tiebreak is **two operations over two different values**, and keeping
//! them apart is the whole design (ADR-0097):
//!
//!   1. **Matching** asks which two connection attempts are racing. That is a
//!      question about the dial target, so the key is its transport and the
//!      partner's claimed designator. A session signature binds that claim to
//!      the fresh session key but does not prove ownership of the locator. The
//!      host separately decides whether channel evidence authenticated a peer.
//!   2. **Ordering** asks which of the two racing sessions survives. That is a
//!      question about *session identity*, so it compares the OCapN session
//!      identifiers derived from the two connections' `session_pubkey`s, ours
//!      on the outbound, the partner's on the inbound.
//!
//! These values do not coincide: each session has a fresh signing key, while
//! a locator designator names the dial target. A single conflated key would
//! silently perform the wrong operation. The field names here keep the two axes
//! visible at each call site.

const std = @import("std");

const model = @import("model");

const foundation = @import("foundation");
const crypto = foundation.crypto;

const host_mod = @import("host.zig");
const host_pump = @import("host/pump.zig");
const sessions_mod = @import("sessions.zig");

pub const DialTarget = struct {
    transport: []const u8,
    designator: []const u8,

    pub fn eql(a: DialTarget, b: DialTarget) bool {
        return std.mem.eql(u8, a.transport, b.transport) and
            std.mem.eql(u8, a.designator, b.designator);
    }
};

pub const CrossedHellos = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct {
        /// One allocation backing both slices in `target`.
        target_bytes: []u8,
        /// The matching axis: the complete locator identity this outbound dial
        /// is trying to reach. Authentication is a separate Host fact.
        target: DialTarget,
        /// The ordering axis: the OCapN session identifier derived from *this
        /// outbound session attempt's* own key.
        our_session_id: foundation.PeerId,
    };

    /// The tiebreak verdict for a crossed inbound: the side whose identifier
    /// is *not* lower aborts its inbound session, so both peers keep the
    /// session the higher-keyed peer opened.
    pub const Verdict = struct { abort_inbound: bool };

    pub fn registerOutbound(
        self: *CrossedHellos,
        allocator: std.mem.Allocator,
        target: DialTarget,
        our_session_id: foundation.PeerId,
    ) !void {
        const byte_len = std.math.add(usize, target.transport.len, target.designator.len) catch
            return error.OutOfMemory;
        const bytes = try allocator.alloc(u8, byte_len);
        errdefer allocator.free(bytes);
        @memcpy(bytes[0..target.transport.len], target.transport);
        @memcpy(bytes[target.transport.len..], target.designator);
        try self.entries.append(allocator, .{
            .target_bytes = bytes,
            .target = .{
                .transport = bytes[0..target.transport.len],
                .designator = bytes[target.transport.len..],
            },
            .our_session_id = our_session_id,
        });
    }

    /// Match an inbound start-session against the registered outbound dials by
    /// complete dial target, then order the two racing sessions by their session
    /// identifiers. Null when no dial to `target` is outstanding (no
    /// collision), so the caller does nothing.
    pub fn checkInbound(
        self: *const CrossedHellos,
        target: DialTarget,
        inbound_session_id: foundation.PeerId,
    ) ?Verdict {
        for (self.entries.items) |entry| {
            if (entry.target.eql(target)) {
                const order = std.mem.order(u8, &entry.our_session_id.bytes, &inbound_session_id.bytes);
                return .{ .abort_inbound = order != .lt };
            }
        }
        return null;
    }

    /// Remove exactly one entry for `target`: one row is appended
    /// per dial, so a sweep would drop a sibling dial's still-live entry.
    pub fn unregister(self: *CrossedHellos, allocator: std.mem.Allocator, target: DialTarget) void {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.target.eql(target)) {
                allocator.free(entry.target_bytes);
                _ = self.entries.orderedRemove(i);
                return;
            }
        }
    }

    pub fn deinit(self: *CrossedHellos, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.target_bytes);
        self.entries.deinit(allocator);
    }
};

/// Run the crossed-hellos tiebreak for an inbound start-session on an accepted
/// CapTP session (ADR-0030): with an outbound dial registered to the same
/// partner, the not-lower side condemns its accepted session, and the strictly
/// lower side condemns its own dialed one. Both act immediately with no
/// deferred flag, because one thread drives the host.
pub fn tiebreakInbound(self: *host_mod.Host, session: *host_mod.HostSession, ss: model.view.StartSession) !void {
    const partner_key = try crypto.PeerKey.fromSlice(ss.session_pubkey);
    const partner_pid = crypto.derivePublicIdentifier(partner_key);
    const designator = ss.acceptable_location.designator;
    // The designator here is a claim, not a proof. The handshake signature
    // establishes that the partner holds `session_pubkey` and made this locator
    // claim; it does not establish ownership of the durable key or address the
    // claim names. On the transports whose designator *is* the identity, the
    // two must agree, or any peer able to open a connection could name a
    // designator we are dialing and have us abort our own verified outbound
    // session to it, repeatedly and against an exporter it never has to reach
    // or hold a key for. `liveSessionForDial` already refuses to trust this
    // same field as a dial match key for the same reason.
    //
    // An address designator stays an unverifiable claim, and it still decides
    // the tiebreak, because the OCapN suite's crossed-hellos test requires it:
    // an address transport has nothing else to match on at hello time. Refusing
    // to act on it there is not ours to choose. Dropping it makes that test
    // hang waiting for the abort. So on an address transport a peer that can
    // open a connection and name an address we are dialing can condemn our dial
    // to it. ADR-0030 models that exposure, and it is why a designator that
    // *is* an identity is the one that gets checked; see `docs/boundaries.md`.
    if (try self.designatorScheme(ss.acceptable_location.transport) == .key) {
        const claimed = crypto.PeerKey.fromDesignator(designator) orelse return;
        if (!std.mem.eql(u8, &claimed.bytes, &partner_key.bytes)) return;
    }
    const dial_target: DialTarget = .{
        .transport = ss.acceptable_location.transport,
        .designator = designator,
    };
    const verdict = self.hellos.checkInbound(dial_target, partner_pid) orelse return;
    if (verdict.abort_inbound) {
        // Not lower: this accepted session is the loser; the pair keeps
        // the session our own dial opened.
        try host_pump.condemn(self, session, .crossed_hellos, "crossed hellos: higher-keyed side aborting its inbound session");
        return;
    }
    // Strictly lower: our own dial to this partner is the loser; the pair
    // keeps this accepted session. `dialed_by_target` is the O(1)
    // index (populated at enroll); do not rescan every live session.
    if (sessions_mod.liveIndexedSession(self, self.dialed_by_target.get(dial_target))) |candidate| {
        try host_pump.condemn(self, candidate, .crossed_hellos, "crossed hellos: lower-keyed side aborting its outbound session");
    }
}
