//! Export rows: the positions this session mints, with their ADR-0004
//! wire-delta counts, dense over `position - base`.
//!
//! Name plate: `ExportTable`. Not `slot.zig` (the CapTP `Slot` sum alone) and
//! not `import_table.zig` (the partner's positions). CapTP keeps export,
//! import, and answer as separate position namespaces, and answer rows live
//! in `answers/`.
//!
//! Export positions are ours. The session mints them in sequence from its
//! base, so the table is a vector over `position - base`
//! (`position_slab.zig`), and a position whose wire-delta count reaches zero
//! is the next one minted. The partner agreed to that reuse when it released
//! the position: `op:gc-exports` is its statement that no mention is in
//! flight, and the stream is ordered, so nothing it sends afterward can mean
//! the old object. The bootstrap position sits below the base and keeps its status-allow: replacement state identity
//! own row.
//!
//! An export row holds the binding of the authoritative `slot.Slot` for its
//! position and rebuilds the cell from its index, so `Session.exportSlot`
//! reads the cell rather than synthesizing a kind from "row exists." The row
//! also says what the export is for when it is a resolver (ADR-0038).
const std = @import("std");
const model = @import("model");
const slot_ops = @import("slot.zig");
const PositionSlab = @import("position_slab.zig").PositionSlab;
const bootstrap_position = @import("mod.zig").bootstrap_position;

pub const Slot = slot_ops.Slot;
const ResolverPurpose = @import("promises/types.zig").ResolverPurpose;

/// One live export position: its wire-delta count, the binding its CapTP
/// cell carries, and what the export is for when it is a resolver
/// (ADR-0038). The row's index is its position and its mint is local, so the
/// cell is rebuilt from the binding (`slot`) rather than stored twice. The
/// purpose leaves with the row, so no table outlives the export it describes.
pub const ExportRow = struct {
    count: u64,
    purpose: ResolverPurpose = .none,
    binding: slot_ops.Binding,

    pub fn slot(self: *const ExportRow, position: ExportTable.Id) Slot {
        return slot_ops.local(self.binding, position.int());
    }
};

comptime {
    // The row is what every warmed session pays per export slot, so its size
    // is pinned: a count word, the purpose union at its tag plus the widest
    // arm, and the binding in the union's padding.
    if (@sizeOf(ExportRow) != 48) @compileError(std.fmt.comptimePrint(
        "ExportRow is {d} bytes, not 48: a wider row is a withdrawal from the warmed footprint budget",
        .{@sizeOf(ExportRow)},
    ));
}

/// Export rows: local-mint CapTP slots + wire-delta counts, dense over the
/// positions this session mints.
///
/// `base` is the first position the allocator hands out and `end` is one past
/// the last it may mint or admit, the span a Node assigns each session
/// (ADR-0027). `register`/`retain` take no cap: every row is one of our own
/// sends, and the partner cannot add one.
pub const ExportTable = struct {
    rows: PositionSlab(ExportRow) = .empty,
    /// The bootstrap position sits below `base` and outside wire-delta GC, so
    /// its row is the constant `bootstrap_row` and only its presence varies.
    bootstrap: bool = false,
    base: u64 = bootstrap_position + 1,
    /// Positions past `base` this session may mint or admit. The vector's
    /// index is 32 bits, so a wider span could never be minted anyway.
    span: u32 = std.math.maxInt(u32),

    pub const bootstrap_row: ExportRow = .{ .count = 1, .binding = .value };

    pub const Id = model.ExportPosition;
    pub const Error = error{GcUnderflow};
    pub const AllocateError = std.mem.Allocator.Error || error{ExportRangeExhausted};
    pub const empty: ExportTable = .{};

    pub const Entry = struct { position: Id, row: *const ExportRow };

    pub const Iterator = struct {
        bootstrap: bool,
        base: u64,
        rows: PositionSlab(ExportRow).Iterator,

        pub fn next(self: *Iterator) ?Entry {
            if (self.bootstrap) {
                self.bootstrap = false;
                return .{ .position = .from(bootstrap_position), .row = &bootstrap_row };
            }
            const entry = self.rows.next() orelse return null;
            return .{ .position = .from(self.base + entry.index), .row = entry.row };
        }
    };

    pub fn ranged(base: u64, span: u64) ExportTable {
        std.debug.assert(base > bootstrap_position);
        return .{ .base = base, .span = std.math.cast(u32, span) orelse std.math.maxInt(u32) };
    }

    /// Move to a host-assigned range before any position is minted. Asserted
    /// rather than tolerated: moving a live range would rename a position the
    /// partner already holds.
    pub fn setRange(self: *ExportTable, base: u64, span: u64) void {
        std.debug.assert(self.rows.capacityUsed() == 0);
        std.debug.assert(base > bootstrap_position);
        self.base = base;
        self.span = std.math.cast(u32, span) orelse std.math.maxInt(u32);
    }

    pub fn deinit(self: *ExportTable, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.bootstrap = false;
    }

    /// Whether `position` is one this session may mint or admit.
    pub fn inRange(self: *const ExportTable, position: Id) bool {
        return position.int() >= self.base and position.int() - self.base < self.span;
    }

    /// One past the last position this session may mint or admit.
    pub fn end(self: *const ExportTable) u64 {
        return self.base +| self.span;
    }

    /// The position the next `allocate` hands out.
    pub fn nextPosition(self: *const ExportTable) Id {
        return .from(self.base + self.rows.nextIndex());
    }

    fn indexOf(self: *const ExportTable, position: Id) ?u32 {
        if (!self.inRange(position)) return null;
        return std.math.cast(u32, position.int() - self.base);
    }

    pub fn iterator(self: *const ExportTable) Iterator {
        return .{ .bootstrap = self.bootstrap, .base = self.base, .rows = self.rows.iterator() };
    }

    pub fn len(self: *const ExportTable) usize {
        return self.rows.len() + @intFromBool(self.bootstrap);
    }

    fn rowPtr(self: *const ExportTable, position: Id) ?*const ExportRow {
        if (position.int() == bootstrap_position) return if (self.bootstrap) &bootstrap_row else null;
        const index = self.indexOf(position) orelse return null;
        return self.rows.getConstPtr(index);
    }

    /// A minted row. The bootstrap row is constant and has no mutable form.
    fn mintedRowPtr(self: *ExportTable, position: Id) ?*ExportRow {
        const index = self.indexOf(position) orelse return null;
        return self.rows.getPtr(index);
    }

    pub fn contains(self: *const ExportTable, position: Id) bool {
        return self.rowPtr(position) != null;
    }

    pub fn count(self: *const ExportTable, position: Id) u64 {
        const row = self.rowPtr(position) orelse return 0;
        return row.count;
    }

    pub fn slotOf(self: *const ExportTable, position: Id) ?Slot {
        const row = self.rowPtr(position) orelse return null;
        return row.slot(position);
    }

    /// Hold room for `additional` fresh positions minted by `allocate`.
    pub fn ensureUnusedCapacity(self: *ExportTable, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
        try self.rows.ensureUnusedCapacity(allocator, additional);
    }

    pub fn wireHeld(self: *const ExportTable, position: Id) u64 {
        const total = self.count(position);
        return if (total == 0) 0 else total - 1;
    }

    /// What `position`'s export is for, when it is a resolver: null for a
    /// position that is not an export of ours or is an ordinary one.
    pub fn purpose(self: *const ExportTable, position: Id) ?ResolverPurpose {
        const row = self.rowPtr(position) orelse return null;
        return if (row.purpose == .none) null else row.purpose;
    }

    /// The purpose on `position`'s row, for a transition in place. The
    /// caller reads the arm it expects; an ordinary export holds `.none`.
    pub fn purposePtr(self: *ExportTable, position: Id) ?*ResolverPurpose {
        const row = self.mintedRowPtr(position) orelse return null;
        return &row.purpose;
    }

    /// Give a live export without a purpose one. Presence and the bare row
    /// are the caller's invariant: a purpose is set on the export its mint
    /// just registered, or on a listener export allocated for it.
    pub fn setPurpose(self: *ExportTable, position: Id, purpose_in: ResolverPurpose) void {
        std.debug.assert(purpose_in != .none);
        const row = self.mintedRowPtr(position) orelse unreachable;
        std.debug.assert(row.purpose == .none);
        row.purpose = purpose_in;
    }

    /// Move a resolver's purpose to `next`, returning the one it replaced.
    pub fn replacePurpose(self: *ExportTable, position: Id, next: ResolverPurpose) ResolverPurpose {
        std.debug.assert(next != .none);
        const row = self.mintedRowPtr(position) orelse unreachable;
        const old = row.purpose;
        std.debug.assert(old != .none);
        row.purpose = next;
        return old;
    }

    /// Take the purpose off `position`'s row, if the row holds one.
    pub fn clearPurpose(self: *ExportTable, position: Id) ?ResolverPurpose {
        const row = self.mintedRowPtr(position) orelse return null;
        if (row.purpose == .none) return null;
        const old = row.purpose;
        row.purpose = .none;
        return old;
    }

    pub const releasable = wireHeld;

    /// Install `position` as an object at count 1 if absent. Idempotent: an
    /// existing row is kept. An explicit position past the frontier grows the
    /// vector through it, and the slots below become the next mints.
    pub fn register(self: *ExportTable, allocator: std.mem.Allocator, position: Id) std.mem.Allocator.Error!void {
        return self.registerCell(allocator, position, .{ .local_value = position.int() });
    }

    /// Install `position` with `cell` at count 1 if absent. Idempotent.
    pub fn registerCell(self: *ExportTable, allocator: std.mem.Allocator, position: Id, cell: Slot) std.mem.Allocator.Error!void {
        std.debug.assert(slot_ops.mintOf(cell) == .local);
        std.debug.assert(slot_ops.position(cell) == position.int());
        if (position.int() == bootstrap_position) {
            std.debug.assert(slot_ops.bindingOf(cell) == bootstrap_row.binding);
            self.bootstrap = true;
            return;
        }
        std.debug.assert(self.inRange(position));
        // `span` is a u32, so an in-range offset fits.
        const index: u32 = @intCast(position.int() - self.base);
        if (self.rows.contains(index)) return;
        std.debug.assert(self.rows.installable(index));
        try self.rows.installAt(allocator, index, .{ .count = 1, .binding = slot_ops.bindingOf(cell) });
    }

    /// Mint the next position as `kind`, with `mentions` wire retains beyond
    /// our own. A released position is minted before the frontier moves.
    pub fn allocate(self: *ExportTable, allocator: std.mem.Allocator, kind: model.RefKind, mentions: u64) AllocateError!Id {
        const index = self.rows.nextIndex();
        if (index >= self.span) return error.ExportRangeExhausted;
        const position: Id = .from(self.base + index);
        const binding: slot_ops.Binding = switch (kind) {
            .object => .value,
            .promise => .unresolved,
        };
        try self.rows.ensureUnusedCapacity(allocator, 1);
        const minted = self.rows.reserveAssumeCapacity(0);
        std.debug.assert(minted == index);
        self.rows.install(index, .{ .count = 1 + mentions, .binding = binding });
        return position;
    }

    /// Retain one more wire reference to a live `position`. Presence is the
    /// caller's invariant: every retain follows the registration that
    /// installed the row, hence the assert.
    pub fn retain(self: *ExportTable, position: Id) void {
        const row = self.mintedRowPtr(position) orelse unreachable;
        std.debug.assert(row.count != std.math.maxInt(u64));
        row.count += 1;
    }

    /// Decrement `position` by `delta`, retiring the row at zero. Underflow, or
    /// an unknown position with `delta > 0`, is `Error.GcUnderflow`.
    pub fn decrement(self: *ExportTable, position: Id, delta: u64) Error!void {
        if (position.int() == bootstrap_position) {
            if (delta > @as(u64, @intFromBool(self.bootstrap))) return error.GcUnderflow;
            if (delta != 0) self.bootstrap = false;
            return;
        }
        const row = self.mintedRowPtr(position) orelse {
            if (delta == 0) return;
            return error.GcUnderflow;
        };
        if (delta > row.count) return error.GcUnderflow;
        row.count -= delta;
        if (row.count == 0) self.rows.remove(self.indexOf(position).?);
    }
};
