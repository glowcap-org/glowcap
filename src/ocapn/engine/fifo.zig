//! The head-indexed FIFO spine, and the action queue built on it.
//!
//! Popping advances a head index instead of shifting rows, and three things
//! follow from that: the head rewinds when the queue drains, a long dead prefix
//! slides forward so a producer that never drains to empty cannot grow the
//! backing without bound, and capacity a burst grew above the caller's steady
//! bound is returned at the drain rather than pinned for the owner's life.
//!
//! `popHead`, `compactHead`, and `reclaimDrained` are those rules, once. Both queue types in this
//! engine ride them: the peer's four per-connection queues and the reserved
//! FIFO below. They are separate types because their surfaces differ, one needs
//! `peek` and `backPtr` for the outbound spine, the other needs `unpopped` for
//! a teardown sweep and infallible reserved appends, but there is one
//! implementation of the part that is the same, so their compaction and
//! reclaim rules cannot drift apart again.
//!
//! The steady bound is the caller's, because it is a footprint decision and the
//! callers sit at different scales: four of these ride on every `engine.Peer` at
//! 500k connections, while the reserved queues are one per node and per host. It
//! is a byte count rather than a row count, so the bound means the same thing
//! whatever `T` is.
//!
//! Rows are plain values. The FIFO owns the backing storage and nothing inside
//! a row, so each owner keeps its own free choreography (a deferred last-popped
//! free, a teardown sweep over `unpopped`) where its lifetime contract is
//! visible.

const std = @import("std");

/// Slide the live suffix to the front so append can reuse capacity behind a
/// head-indexed queue. This is storage policy, independent of either queue's
/// element ownership and reservation contract.
pub fn compactHead(
    comptime T: type,
    list: *std.ArrayListUnmanaged(T),
    head: *usize,
) void {
    if (head.* == 0) return;
    const live = list.items.len - head.*;
    std.mem.copyForwards(T, list.items[0..live], list.items[head.*..]);
    list.shrinkRetainingCapacity(live);
    head.* = 0;
}

/// Dequeue the front row of a head-indexed queue, or null when it is drained.
///
/// This is the whole shared mechanism. On an empty observation the head rewinds
/// and burst capacity above `steady_bytes` is freed. The reclaim runs on every
/// empty observation rather than only when the head is ahead, because the slide
/// below can consume the last row with the head already at zero. On an ordinary
/// pop, a dead prefix that has grown to dominate the backing slides forward, so
/// a queue kept non-empty under sustained load holds capacity proportional to
/// its live depth instead of to everything ever pushed.
pub fn popHead(
    comptime T: type,
    list: *std.ArrayListUnmanaged(T),
    head: *usize,
    allocator: std.mem.Allocator,
    steady_bytes: usize,
) ?T {
    if (head.* >= list.items.len) {
        reclaimDrained(T, list, head, allocator, steady_bytes);
        return null;
    }
    const row = list.items[head.*];
    head.* += 1;
    if (head.* >= dead_prefix_rows_min and head.* * 2 >= list.items.len) compactHead(T, list, head);
    return row;
}

/// The dead prefix a pop lets grow before sliding the live rows forward.
/// Shorter, and a queue popped near its head would copy on most pops.
const dead_prefix_rows_min = 64;

/// Rewind a drained queue. The buffer stays between messages so steady
/// traffic allocates nothing, and goes back only when it grew past
/// `steady_bytes`, so one burst cannot pin that memory for the life of the
/// connection. The cost is one new allocation when the next burst arrives.
pub fn reclaimDrained(
    comptime T: type,
    list: *std.ArrayListUnmanaged(T),
    head: *usize,
    allocator: std.mem.Allocator,
    steady_bytes: usize,
) void {
    std.debug.assert(head.* >= list.items.len);
    list.clearRetainingCapacity();
    head.* = 0;
    if (list.capacity * @sizeOf(T) > steady_bytes) list.clearAndFree(allocator);
}

/// A steady bound that never sheds: the drain keeps whatever capacity it has.
///
/// For a queue whose capacity is reserved ahead of the push that spends it, the
/// reclaim is not an optimization to tune, it is a correctness break. The
/// action queues reserve at vow-mint time so a later settle's infallible
/// `pushReserved` cannot fail, and the embedder drains between those two
/// moments, so a drain that freed the reservation would leave
/// `appendAssumeCapacity` writing past the end. A queue that reserves ahead
/// passes this.
pub const retain_all: usize = std.math.maxInt(usize);

pub fn ActionFifo(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Rows pushed and not yet popped live at `list.items[head..]`. status-allow: pending state or quoted runtime label
        list: std.ArrayListUnmanaged(T) = .empty,
        head: usize = 0,

        pub fn push(self: *Self, allocator: std.mem.Allocator, row: T) !void {
            if (self.list.items.len == self.list.capacity) compactHead(T, &self.list, &self.head);
            try self.list.append(allocator, row);
        }

        /// Reserve room for `rows` more pushes so a later `pushReserved`
        /// cannot fail, the fallible half of an infallible-fire contract.
        pub fn reserve(self: *Self, allocator: std.mem.Allocator, rows: usize) !void {
            if (rows > self.list.capacity - self.list.items.len) compactHead(T, &self.list, &self.head);
            try self.list.ensureUnusedCapacity(allocator, rows);
        }

        /// Ensure the backing can hold `rows` live FIFO entries at once.
        pub fn ensureTotalCapacity(self: *Self, allocator: std.mem.Allocator, rows: usize) !void {
            if (rows > self.list.capacity) compactHead(T, &self.list, &self.head);
            try self.list.ensureTotalCapacity(allocator, rows);
        }

        /// Push into capacity `reserve` or `ensureTotalCapacity` already secured.
        pub fn pushReserved(self: *Self, row: T) void {
            if (self.list.items.len == self.list.capacity) compactHead(T, &self.list, &self.head);
            std.debug.assert(self.list.items.len < self.list.capacity);
            self.list.appendAssumeCapacity(row);
        }

        /// Borrow the next row without consuming it. Used when the consequence
        /// of an action is fallible: commit the consequence first, then pop.
        pub fn peek(self: *const Self) ?T {
            if (self.head >= self.list.items.len) return null;
            return self.list.items[self.head];
        }

        /// Pop the front row, owning nothing: the caller (or its deferred
        /// free) owns the row's payload. Null when empty, which also rewinds
        /// the drained list while retaining previously reserved backing. status-allow: ownership and operation ordering
        pub fn pop(self: *Self, allocator: std.mem.Allocator) ?T {
            // `retain_all`, not a byte bound: `reserve` runs at vow-mint time
            // and `pushReserved` spends it at settle time, with this drain in
            // between. Shedding here would free a reservation already promised
            // to an infallible append.
            return popHead(T, &self.list, &self.head, allocator, retain_all);
        }

        /// The rows pushed and never popped, in order: the owner's teardown
        /// sweep frees their payloads, and a queue-time dedup scans them.
        pub fn unpopped(self: *const Self) []const T {
            return self.list.items[self.head..];
        }

        /// Rows still owned by the FIFO.
        pub fn liveLen(self: *const Self) usize {
            return self.list.items.len - self.head;
        }

        /// Remove one live row by its offset within `unpopped`, preserving the
        /// order of every other row. Transaction rollback uses this after an
        /// infallible reserved push whose later work failed. It never allocates
        /// and never touches rows already handed to a consumer.
        pub fn removeUnpopped(self: *Self, offset: usize) T {
            std.debug.assert(offset < self.list.items.len - self.head);
            return self.list.orderedRemove(self.head + offset);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.list.deinit(allocator);
        }
    };
}
