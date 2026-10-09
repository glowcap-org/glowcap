//! FIFO/cursor storage policy shared by every queue on one Peer.
//!
//! The generic owns cursor advancement, retained-capacity trimming, optional
//! constant-time byte accounting, and rollback-at-the-back. Element-specific
//! ownership remains with the caller that knows how to retire `T`.

const std = @import("std");
const fifo = @import("../fifo.zig");

/// Capacity retained after a queue drains; larger burst backing is released.
/// At 500k connections, pinning even a few extra KiB per queue costs GiB, so a
/// burst cannot become the peer's permanent footprint. Capacity at or below
/// this bound remains allocation-free across steady turns; freeing a larger
/// burst costs one growth allocation only at the start of the next burst.
/// Allocation and footprint budget tests pin both sides of that contract.
pub const steady_retain_bytes: usize = 4096;

/// A FIFO with a drain cursor. Append/pop never shifts every row, and draining
/// rewinds or frees burst capacity according to `steady_retain_bytes`.
pub fn Queue(comptime T: type, comptime weightOf: ?*const fn (*const T) usize) type {
    return struct {
        items: std.ArrayList(T) = .empty,
        head: usize = 0,
        queued_weight: if (weightOf != null) usize else void = if (weightOf != null) 0 else {},

        const Self = @This();

        pub fn push(self: *Self, allocator: std.mem.Allocator, value: T) !void {
            if (self.items.items.len == self.items.capacity) fifo.compactHead(T, &self.items, &self.head);
            try self.items.append(allocator, value);
            self.addWeight(&value);
        }

        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, count: usize) !void {
            if (count > self.items.capacity - self.items.items.len) fifo.compactHead(T, &self.items, &self.head);
            try self.items.ensureUnusedCapacity(allocator, count);
        }

        pub fn pushAssumeCapacity(self: *Self, value: T) void {
            self.items.appendAssumeCapacity(value);
            self.addWeight(&value);
        }

        pub fn pop(self: *Self, allocator: std.mem.Allocator) ?T {
            const value = fifo.popHead(
                T,
                &self.items,
                &self.head,
                allocator,
                steady_retain_bytes,
            ) orelse return null;
            self.subtractWeight(&value);
            return value;
        }

        /// Remove a successfully consumed borrowed front row and perform drain
        /// housekeeping immediately.
        pub fn consumeFront(self: *Self, allocator: std.mem.Allocator) T {
            const value = self.pop(allocator) orelse unreachable;
            if (self.isEmpty()) std.debug.assert(self.pop(allocator) == null);
            return value;
        }

        /// Consume while retaining backing promised to unpublished queue
        /// reservations. The ordinary steady-footprint trim resumes as soon as
        /// the last reservation publishes or cancels.
        pub fn consumeFrontReserved(self: *Self, allocator: std.mem.Allocator) T {
            const value = fifo.popHead(
                T,
                &self.items,
                &self.head,
                allocator,
                fifo.retain_all,
            ) orelse unreachable;
            if (self.isEmpty()) std.debug.assert(fifo.popHead(
                T,
                &self.items,
                &self.head,
                allocator,
                fifo.retain_all,
            ) == null);
            return value;
        }

        pub fn trimDrained(self: *Self, allocator: std.mem.Allocator) void {
            std.debug.assert(self.isEmpty());
            std.debug.assert(fifo.popHead(
                T,
                &self.items,
                &self.head,
                allocator,
                steady_retain_bytes,
            ) == null);
        }

        /// Roll back the most-recent append without crossing the drain cursor.
        pub fn popBack(self: *Self) ?T {
            if (self.isEmpty()) return null;
            const value = self.items.pop().?;
            self.subtractWeight(&value);
            return value;
        }

        /// Remove the live row at `index` (counted from the drain cursor),
        /// keeping every other row in order.
        pub fn removePending(self: *Self, index: usize) void {
            const value = self.items.orderedRemove(self.head + index);
            self.subtractWeight(&value);
        }

        /// Borrow the newest live row until the next queue mutation.
        pub fn backPtr(self: *Self) ?*T {
            if (self.isEmpty()) return null;
            return &self.items.items[self.items.items.len - 1];
        }

        /// Borrow the front live row until the next queue mutation.
        pub fn peek(self: *const Self) ?*const T {
            if (self.isEmpty()) return null;
            return &self.items.items[self.head];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.head == self.items.items.len;
        }

        /// Live rows, for type-specific teardown before backing retirement.
        pub fn pending(self: *Self) []T {
            return self.items.items[self.head..];
        }

        pub fn weight(self: *const Self) usize {
            if (weightOf == null) @compileError("weight is available only on an accounted queue");
            return self.queued_weight;
        }

        fn addWeight(self: *Self, value: *const T) void {
            if (weightOf) |measure| {
                self.queued_weight = std.math.add(usize, self.queued_weight, measure(value)) catch unreachable;
            }
        }

        fn subtractWeight(self: *Self, value: *const T) void {
            if (weightOf) |measure| self.queued_weight -= measure(value);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.items.deinit(allocator);
        }
    };
}
