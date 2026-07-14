//! Head-indexed action FIFO: the one pop mechanism behind `engine.Node`'s
//! serve-step queue and `driver_core.Host`'s embedder queue. Rows are plain
//! values; the FIFO owns the backing storage and nothing inside a row, so
//! each owner keeps its own free choreography (a deferred last-popped free,
//! a teardown sweep over `unpopped`) where its lifetime contract is visible.
//!
//! Popping advances a head index instead of shifting rows; when the queue
//! drains, `clearRetainingCapacity` rewinds it so steady capacity amortizes,
//! and a long-dead prefix past `compact_threshold` is compacted forward so a
//! producer that never drains to empty cannot grow the list without bound.

const std = @import("std");

pub fn ActionFifo(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Rows pushed and not yet popped live at `list.items[head..]`.
        list: std.ArrayListUnmanaged(T) = .empty,
        head: usize = 0,

        /// Popped-prefix length that triggers compaction on the next pop.
        const compact_threshold: usize = 32;

        pub fn push(self: *Self, allocator: std.mem.Allocator, row: T) !void {
            try self.list.append(allocator, row);
        }

        /// Reserve room for `rows` more pushes so a later `pushReserved`
        /// cannot fail — the fallible half of an infallible-fire contract.
        pub fn reserve(self: *Self, allocator: std.mem.Allocator, rows: usize) !void {
            try self.list.ensureUnusedCapacity(allocator, rows);
        }

        /// Push into capacity `reserve` already secured.
        pub fn pushReserved(self: *Self, row: T) void {
            self.list.appendAssumeCapacity(row);
        }

        /// Pop the front row, owning nothing: the caller (or its deferred
        /// free) owns the row's payload. Null when empty, which also rewinds
        /// the drained list to reuse its capacity.
        pub fn pop(self: *Self) ?T {
            if (self.head >= self.list.items.len) {
                self.list.clearRetainingCapacity();
                self.head = 0;
                return null;
            }
            if (self.head >= compact_threshold) {
                const remaining = self.list.items.len - self.head;
                std.mem.copyForwards(T, self.list.items[0..remaining], self.list.items[self.head..]);
                self.list.items.len = remaining;
                self.head = 0;
            }
            const row = self.list.items[self.head];
            self.head += 1;
            return row;
        }

        /// The rows pushed and never popped, in order: the owner's teardown
        /// sweep frees their payloads, and a queue-time dedup scans them.
        pub fn unpopped(self: *const Self) []const T {
            return self.list.items[self.head..];
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.list.deinit(allocator);
        }
    };
}
