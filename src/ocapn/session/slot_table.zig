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
const model = @import("model");

/// Wire-delta reference-count table (ADR-0008) keyed by CapTP position. Each
/// position is installed live at count 1; `op:gc-*` decrements by the wire
/// delta and the row is removed at zero. Underflow or an unknown position is a loud
/// error, never a silent clamp.
pub const SlotTable = struct {
    counts: std.AutoHashMapUnmanaged(u64, u64) = .empty,

    pub const Error = error{
        /// A decrement drove a count below zero, or named a position the table
        /// never held, surfaced loudly per ADR-0008 wire-delta accounting.
        GcUnderflow,
    };

    pub const empty: SlotTable = .{};

    pub fn deinit(self: *SlotTable, allocator: std.mem.Allocator) void {
        self.counts.deinit(allocator);
    }

    /// Number of live positions, the row count the resilience caps bound.
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

/// Export refcounts: positions this peer mints for objects it hands out.
///
/// Exports and imports share `SlotTable`'s wire-delta accounting but obey
/// different rules, and the two wrapper types below make that difference a
/// property of the type rather than a convention a caller must remember. An
/// export position is *locally allocated* (`Session.allocateExport`) and
/// monotonic, so its row count is bounded by our own sends; there is nothing a
/// partner can do to grow it without bound, and `register`/`retain` therefore
/// take no cap.
pub const ExportTable = struct {
    slots: SlotTable = .empty,

    pub const Id = model.ExportId;
    pub const Error = SlotTable.Error;
    pub const empty: ExportTable = .{};

    pub fn deinit(self: *ExportTable, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
    }

    pub fn len(self: *const ExportTable) usize {
        return self.slots.len();
    }

    pub fn contains(self: *const ExportTable, position: Id) bool {
        return self.slots.contains(position.int());
    }

    pub fn count(self: *const ExportTable, position: Id) u64 {
        return self.slots.count(position.int());
    }

    /// Install `position` live at count 1 if absent; idempotent otherwise.
    pub fn register(self: *ExportTable, allocator: std.mem.Allocator, position: Id) !void {
        return self.slots.register(allocator, position.int());
    }

    /// Take one wire reference to a locally-minted export (resolver callbacks
    /// and the like): insert at count 1, or increment an already-live row.
    pub fn retain(self: *ExportTable, allocator: std.mem.Allocator, position: Id) !void {
        return self.slots.retain(allocator, position.int());
    }

    pub fn decrement(self: *ExportTable, position: Id, delta: u64) Error!void {
        return self.slots.decrement(position.int(), delta);
    }
};

/// Import refcounts: positions a *partner* introduces for objects it exports.
///
/// Unlike an export, an import position is partner-allocated, so a hostile peer
/// could introduce unboundedly many distinct imports. `retain` therefore takes a
/// `max` and refuses a *new* id past it (ADR-0025), so the cap is enforced at the
/// one place a row is added rather than at each call site. An already-held id is
/// a refcount bump and never trips the cap, because it adds no row. There is no
/// `register`: imports are only ever retained.
pub const ImportTable = struct {
    slots: SlotTable = .empty,

    pub const Id = model.ImportId;
    /// Adding a new import row can hit the partner-import cap; everything else
    /// an import table does (decrement, lookup) shares `SlotTable`'s errors.
    pub const RetainError = std.mem.Allocator.Error || error{ImportCapExceeded};
    pub const empty: ImportTable = .{};

    pub fn deinit(self: *ImportTable, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
    }

    pub fn len(self: *const ImportTable) usize {
        return self.slots.len();
    }

    pub fn contains(self: *const ImportTable, position: Id) bool {
        return self.slots.contains(position.int());
    }

    pub fn count(self: *const ImportTable, position: Id) u64 {
        return self.slots.count(position.int());
    }

    /// Retain one wire reference to a partner-introduced import. A *new* id is
    /// bounded by `max` (`SessionLimits.max_imports`); an already-held id only
    /// increments its wire-delta refcount and is never refused, since a partner
    /// may reference the same export repeatedly and our later `op:gc-exports`
    /// must release the same total delta.
    pub fn retain(self: *ImportTable, allocator: std.mem.Allocator, position: Id, max: usize) RetainError!void {
        if (!self.slots.contains(position.int()) and self.slots.len() >= max) {
            return error.ImportCapExceeded;
        }
        return self.slots.retain(allocator, position.int());
    }

    pub fn decrement(self: *ImportTable, position: Id, delta: u64) SlotTable.Error!void {
        return self.slots.decrement(position.int(), delta);
    }
};
