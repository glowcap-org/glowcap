//! Crossed-hellos tiebreak state (ADR-0030): the designator-keyed
//! outbound-dial table, unlocked because one thread drives one host by
//! contract. `openDialedLocator` registers the outbound before its hello
//! moves; an accepted CapTP session's inbound start-session is compared against
//! it, and the host condemns the losing session immediately rather than
//! deferring a flag to a later pump. Public for its unit tests; embedders
//! never touch it — the host runs the tiebreak itself.

const std = @import("std");

const foundation = @import("foundation");

pub const CrossedHellos = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct {
        partner_designator: []const u8,
        our_pid: foundation.PeerId,
    };

    /// The tiebreak verdict for a crossed inbound: the side whose identifier
    /// is *not* lower aborts its inbound session, so both peers keep the
    /// session the higher-keyed peer opened.
    pub const Verdict = struct { abort_inbound: bool };

    pub fn registerOutbound(self: *CrossedHellos, allocator: std.mem.Allocator, partner_designator: []const u8, our_pid: foundation.PeerId) !void {
        const owned = try allocator.dupe(u8, partner_designator);
        errdefer allocator.free(owned);
        try self.entries.append(allocator, .{ .partner_designator = owned, .our_pid = our_pid });
    }

    /// Compare an inbound start-session against the registered outbound dials;
    /// null when no dial to `partner_designator` is outstanding (no collision).
    pub fn checkInbound(self: *const CrossedHellos, partner_designator: []const u8, inbound_partner_pid: foundation.PeerId) ?Verdict {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.partner_designator, partner_designator)) {
                const order = std.mem.order(u8, &entry.our_pid.bytes, &inbound_partner_pid.bytes);
                return .{ .abort_inbound = order != .lt };
            }
        }
        return null;
    }

    /// Remove exactly one entry for `partner_designator`: one row is appended
    /// per dial, so a sweep would drop a sibling dial's still-live entry.
    pub fn unregister(self: *CrossedHellos, allocator: std.mem.Allocator, partner_designator: []const u8) void {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.partner_designator, partner_designator)) {
                allocator.free(entry.partner_designator);
                _ = self.entries.orderedRemove(i);
                return;
            }
        }
    }

    pub fn deinit(self: *CrossedHellos, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry.partner_designator);
        self.entries.deinit(allocator);
    }
};
