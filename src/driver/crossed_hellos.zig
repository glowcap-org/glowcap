//! Crossed-hellos mitigation for concurrent outbound and inbound dials (ADR-0030).
//!
//! When two peers simultaneously open sessions to each other, the side with the
//! lexicographically lower Public Identifier aborts its inbound session; the
//! higher-keyed side aborts outbound. The adapter owns detection — the no-I/O core
//! only projects the typed `crossed_hellos` abort kind.

const std = @import("std");

const foundation = @import("../foundation/mod.zig");
const model = @import("../model/mod.zig");
const engine = @import("../engine/mod.zig");
const crypto = foundation.crypto;
const net_adapter = @import("../net_adapter/mod.zig");

pub const Result = struct { abort_inbound: bool };

/// Tracks outbound sessions keyed by partner locator designator so an inbound
/// `op:start-session` from the same peer can be compared. Caller-owned.
pub const Registry = struct {
    mutex: std.atomic.Mutex = .unlocked,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        partner_designator: []const u8,
        our_pid: foundation.PeerId,
        should_abort: bool = false,
    };

    fn spinLock(self: *Registry) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn registerOutbound(self: *Registry, allocator: std.mem.Allocator, partner_designator: []const u8, our_pid: foundation.PeerId) !void {
        self.spinLock();
        defer self.mutex.unlock();
        const owned = try allocator.dupe(u8, partner_designator);
        try self.entries.append(allocator, .{ .partner_designator = owned, .our_pid = our_pid });
    }

    pub fn checkInbound(self: *Registry, partner_designator: []const u8, inbound_partner_pid: foundation.PeerId) ?Result {
        self.spinLock();
        defer self.mutex.unlock();
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

    pub fn shouldAbortOutbound(self: *Registry, partner_designator: []const u8) bool {
        self.spinLock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.partner_designator, partner_designator)) return entry.should_abort;
        }
        return false;
    }

    pub fn unregister(self: *Registry, allocator: std.mem.Allocator, partner_designator: []const u8) void {
        self.spinLock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[i].partner_designator, partner_designator)) {
                allocator.free(self.entries.items[i].partner_designator);
                _ = self.entries.orderedRemove(i);
            } else i += 1;
        }
    }

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        self.spinLock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| allocator.free(entry.partner_designator);
        self.entries.deinit(allocator);
    }
};

/// After an inbound `op:start-session` event, consult `registry` and abort the
/// lower-keyed inbound session when a crossed-hellos collision is detected.
pub fn maybeAbortInbound(
    registry: *Registry,
    peer: *engine.Peer,
    conn: *net_adapter.Connection,
    event: *engine.Event,
) !void {
    const body = try event.view();
    const ss = switch (body) {
        .start_session => |start| start,
        else => return,
    };
    const partner_key = crypto.PeerKey.fromSlice(ss.session_pubkey) catch return;
    const partner_pid = crypto.derivePublicIdentifier(partner_key);
    const result = registry.checkInbound(ss.acceptable_location.designator, partner_pid) orelse return;
    if (result.abort_inbound) {
        try peer.sendCopying(.{ .abort = .{
            .kind = .crossed_hellos,
            .message = "crossed hellos: aborting lower-keyed inbound session",
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
    conn: *net_adapter.Connection,
) !void {
    if (!registry.shouldAbortOutbound(partner_designator)) return;
    try peer.sendCopying(.{ .abort = .{
        .kind = .crossed_hellos,
        .message = "crossed hellos: aborting lower-keyed outbound session",
    } });
    _ = conn.pump() catch {};
}
