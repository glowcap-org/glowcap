//! Crossed-hellos tiebreak state (ADR-0030): the outbound-dial table an
//! accepted session's inbound `op:start-session` is compared against, unlocked
//! because one thread drives one host by contract. `openDialedLocator`
//! registers the outbound before its hello moves; the host condemns the losing
//! session immediately rather than deferring a flag to a later pump. Public for
//! its unit tests; embedders never touch it — the host runs the tiebreak
//! itself.
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
//!      identifiers derived from the two connections' `session_pubkey`s — ours
//!      on the outbound, the partner's on the inbound.
//!
//! These values do not coincide: each session has a fresh signing key, while
//! a locator designator names the dial target. A single conflated key would
//! silently perform the wrong operation. The field names here keep the two axes
//! visible at each call site.

const std = @import("std");

const foundation = @import("foundation");

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
