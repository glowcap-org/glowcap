//! Crossed-hellos mitigation for concurrent outbound and inbound dials (ADR-0030).
//!
//! When two peers dial each other at once, each ends up holding both an outbound
//! and an inbound session to the same partner, and the pair must collapse to one.
//! The tiebreak is the byte order of the two Public Identifiers: the side whose
//! identifier is *not* lower aborts its inbound session, and the strictly
//! lower-keyed side aborts its outbound — so both peers keep the session the
//! higher-keyed peer opened, with no coordination beyond the comparison each runs
//! locally. The adapter owns detection — the no-I/O core only projects the typed
//! `crossed_hellos` abort kind.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const crypto = foundation.crypto;
const net = @import("net");

pub const Result = struct { abort_inbound: bool };

/// Tracks outbound sessions keyed by partner locator designator so an inbound
/// `op:start-session` from the same peer can be compared. Caller-owned. The
/// registry is shared across connections that may run on separate threads, so
/// every method locks the io-aware blocking `std.Io.Mutex`; the caller's `io`
/// is what drives the wait, never a busy spin.
pub const Registry = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        partner_designator: []const u8,
        our_pid: foundation.PeerId,
        should_abort: bool = false,
    };

    pub fn registerOutbound(self: *Registry, io: std.Io, allocator: std.mem.Allocator, partner_designator: []const u8, our_pid: foundation.PeerId) !void {
        // Dupe before taking the lock: the allocation can block or fail, and
        // neither belongs inside the critical section.
        const owned = try allocator.dupe(u8, partner_designator);
        errdefer allocator.free(owned);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.entries.append(allocator, .{ .partner_designator = owned, .our_pid = our_pid });
    }

    pub fn checkInbound(self: *Registry, io: std.Io, partner_designator: []const u8, inbound_partner_pid: foundation.PeerId) ?Result {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.partner_designator, partner_designator)) {
                const order = std.mem.order(u8, &entry.our_pid.bytes, &inbound_partner_pid.bytes);
                const abort_inbound = order != .lt;
                if (!abort_inbound) entry.should_abort = true;
                return .{ .abort_inbound = abort_inbound };
            }
        }
        return null;
    }

    pub fn shouldAbortOutbound(self: *Registry, io: std.Io, partner_designator: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.partner_designator, partner_designator)) return entry.should_abort;
        }
        return false;
    }

    pub fn unregister(self: *Registry, io: std.Io, allocator: std.mem.Allocator, partner_designator: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[i].partner_designator, partner_designator)) {
                allocator.free(self.entries.items[i].partner_designator);
                _ = self.entries.orderedRemove(i);
            } else i += 1;
        }
    }

    pub fn deinit(self: *Registry, io: std.Io, allocator: std.mem.Allocator) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (self.entries.items) |entry| allocator.free(entry.partner_designator);
        self.entries.deinit(allocator);
    }
};

/// After an inbound `op:start-session` event, consult `registry`: on a
/// crossed-hellos collision the not-lower side aborts its own inbound session, so
/// the pair keeps the session the higher-keyed peer opened.
pub fn maybeAbortInbound(
    registry: *Registry,
    peer: *engine.Peer,
    conn: *net.Connection,
    event: *engine.Event,
) !void {
    const body = try event.view();
    const ss = switch (body) {
        .start_session => |start| start,
        else => return,
    };
    const partner_key = crypto.PeerKey.fromSlice(ss.session_pubkey) catch return;
    const partner_pid = crypto.derivePublicIdentifier(partner_key);
    const result = registry.checkInbound(conn.io, ss.acceptable_location.designator, partner_pid) orelse return;
    if (result.abort_inbound) {
        try peer.sendCopying(.{ .abort = .{
            .kind = .crossed_hellos,
            .message = "crossed hellos: higher-keyed side aborting its inbound session",
        } });
        _ = conn.pump() catch {};
    }
}

/// Send the outbound abort when `registry` signals the lower-keyed side should
/// close its outbound dial.
pub fn maybeAbortOutbound(
    registry: *Registry,
    partner_designator: []const u8,
    peer: *engine.Peer,
    conn: *net.Connection,
) !void {
    if (!registry.shouldAbortOutbound(conn.io, partner_designator)) return;
    try peer.sendCopying(.{ .abort = .{
        .kind = .crossed_hellos,
        .message = "crossed hellos: lower-keyed side aborting its outbound session",
    } });
    _ = conn.pump() catch {};
}
