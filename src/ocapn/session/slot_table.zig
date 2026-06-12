//! Position-keyed reference-count table.
//!
//! CapTP addresses exports, imports, and answer-positions by dense, monotonic
//! integer position. This table spends the position directly as a key: O(1)
//! `contains` / `count` / `register` / `decrement`, O(live) memory — no linear
//! scan over a `{ position, count }` list, and a GC sweep is one O(live) pass rather
//! than a per-position re-count.
//!
//! ## Why a hash, not a raw `position -> count` vector
//!
//! Export positions are locally allocated and monotonic, so a flat index vector
//! would be safe and ideal for them. But import positions and inbound answer
//! positions are *partner-allocated*: a hostile peer can name `import_position =
//! 1 << 63`, and a raw index vector would try to grow to that length — a memory
//! DoS. An integer-keyed hash keeps the O(1) win without letting a partner's
//! sparse position explode the backing store, so the no-footgun structure (and the
//! resilience caps that bound row count) survive. The table is uniform across
//! trusted and untrusted positions for one clear contract.
//!
//! ## No generational handles
//!
//! Positions are monotonic within a session and never reused, so there is no
//! slot-reuse / ABA hazard to guard. A bare position key suffices; no
//! generation counter is carried.

const std = @import("std");

/// Wire-delta reference-count table (ADR-0008) keyed by CapTP position. Each
/// position is installed live at count 1; `op:gc-*` decrements by the wire
/// delta and the row is removed at zero. Underflow or an unknown position is a loud
/// error, never a silent clamp.
pub const SlotTable = struct {
    counts: std.AutoHashMapUnmanaged(u64, u64) = .empty,

    pub const Error = error{
        /// A decrement drove a count below zero, or named a position the table
        /// never held — surfaced loudly per ADR-0008 wire-delta accounting.
        GcUnderflow,
    };

    pub const empty: SlotTable = .{};

    pub fn deinit(self: *SlotTable, allocator: std.mem.Allocator) void {
        self.counts.deinit(allocator);
    }

    /// Number of live positions — the row count the resilience caps bound.
    pub fn len(self: *const SlotTable) usize {
        return self.counts.count();
    }

    pub fn contains(self: *const SlotTable, position: u64) bool {
        return self.counts.contains(position);
    }

    /// Current refcount for `position`, or 0 if the position is not live.
    pub fn count(self: *const SlotTable, position: u64) u64 {
        return self.counts.get(position) orelse 0;
    }

    /// Register `position` live at count 1 if absent; idempotent no-op otherwise.
    pub fn register(self: *SlotTable, allocator: std.mem.Allocator, position: u64) !void {
        const gop = try self.counts.getOrPut(allocator, position);
        if (!gop.found_existing) gop.value_ptr.* = 1;
    }

    /// Retain one wire reference to `position`: insert at count 1, or increment
    /// an already-live row. Used for partner-introduced imports where repeated
    /// references in one or more messages must later be released by matching
    /// `op:gc-exports` wire-deltas.
    pub fn retain(self: *SlotTable, allocator: std.mem.Allocator, position: u64) !void {
        const gop = try self.counts.getOrPut(allocator, position);
        if (gop.found_existing) {
            gop.value_ptr.* += 1;
        } else {
            gop.value_ptr.* = 1;
        }
    }

    /// Decrement `position` by `delta`, removing the row at zero. Underflow, or
    /// an unknown position with `delta > 0`, returns `Error.GcUnderflow`.
    pub fn decrement(self: *SlotTable, position: u64, delta: u64) Error!void {
        const entry = self.counts.getPtr(position) orelse {
            if (delta == 0) return;
            return Error.GcUnderflow;
        };
        if (delta > entry.*) return Error.GcUnderflow;
        entry.* -= delta;
        if (entry.* == 0) _ = self.counts.remove(position);
    }
};
