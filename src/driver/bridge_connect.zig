//! Owned correlation payload for one completion-loop outbound connect.
//!
//! Application dials retain the complete locator until Host adoption. The
//! transport resolver consumes the same locator at connect time, while the
//! Host consumes its profile knowledge only after the socket exists; keeping
//! one owned value prevents those two projections from drifting. Redeem dials
//! retain only their Node ticket because the Node row already owns that
//! locator until settlement.

const std = @import("std");

const engine = @import("engine");
const model = @import("model");

pub const RedeemAttempt = struct {
    ticket: engine.Node.PendingId,
    route_index: usize,
};

pub const OutboundConnect = union(enum) {
    app_dial: model.PeerLocator,
    redeem: RedeemAttempt,

    pub fn initApplication(
        allocator: std.mem.Allocator,
        locator: model.PeerLocator,
    ) std.mem.Allocator.Error!OutboundConnect {
        return .{ .app_dial = try model.clonePeerLocator(allocator, locator) };
    }

    pub fn deinit(self: OutboundConnect, allocator: std.mem.Allocator) void {
        switch (self) {
            .app_dial => |locator| model.freePeerLocator(allocator, locator),
            .redeem => {},
        }
    }
};

/// Slot-indexed ownership for connections that the loop has admitted but the
/// Host has not fully classified. Application rows retain their locator until
/// adoption commits; redeem rows retain exact attempt identity through the
/// session-open edge so cancellation can still find an adopted handshake.
pub const Pending = struct {
    by_slot: std.AutoHashMapUnmanaged(usize, OutboundConnect) = .{},

    pub fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        var it = self.by_slot.valueIterator();
        while (it.next()) |pending| pending.deinit(allocator);
        self.by_slot.deinit(allocator);
    }

    pub fn get(self: *const Pending, slot: usize) ?OutboundConnect {
        return self.by_slot.get(slot);
    }

    /// Preflight one row before the loop admits a physical connection.
    pub fn reserve(self: *Pending, allocator: std.mem.Allocator) !void {
        try self.by_slot.ensureUnusedCapacity(allocator, 1);
    }

    /// Adopt `connect` after a successful loop admission. `reserve` makes this
    /// infallible so the slot and its correlation row commit together.
    pub fn commit(self: *Pending, slot: usize, connect: OutboundConnect) void {
        const gop = self.by_slot.getOrPutAssumeCapacity(slot);
        std.debug.assert(!gop.found_existing);
        gop.value_ptr.* = connect;
    }

    pub fn take(self: *Pending, slot: usize) ?OutboundConnect {
        return (self.by_slot.fetchRemove(slot) orelse return null).value;
    }

    pub fn retire(self: *Pending, allocator: std.mem.Allocator, slot: usize) bool {
        const removed = self.take(slot) orelse return false;
        removed.deinit(allocator);
        return true;
    }

    pub fn redeemSlot(self: *Pending, attempt: RedeemAttempt) ?usize {
        var it = self.by_slot.iterator();
        while (it.next()) |entry| switch (entry.value_ptr.*) {
            .redeem => |pending| if (std.meta.eql(pending, attempt))
                return entry.key_ptr.*,
            .app_dial => {},
        };
        return null;
    }
};
