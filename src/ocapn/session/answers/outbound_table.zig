//! Outbound answers: the questions this side asked, at the positions it minted.
//!
//! The table is dense over position (`position_slab.zig`), and a position
//! whose row retires is the next one minted. The partner's `op:gc-answers`
//! grammar grants that reuse. Under V1.0 the partner still names our
//! position in its `op:resolve`, so a row released before its resolution
//! arrived withholds its position for the rest of the session rather than
//! letting a late resolve land on a new question. Under the next profile the
//! resolution reaches us through the resolver export we minted, which has its
//! own retirement, so the position frees at once.
//!
//! Every row carries the session's store stamp. `OutboundAnswerTarget` pairs
//! a position with that stamp, and `live` is the lookup for a holder that
//! kept the target across turns: it answers null once the row is gone or the
//! position carries a newer question.
const std = @import("std");
const model = @import("model");
const store = @import("store.zig");
const PositionSlab = @import("../position_slab.zig").PositionSlab;

const AnswerCell = store.AnswerCell;

/// One outbound answer's identity across turns: the position on the wire and
/// the stamp of the row that holds this question there.
pub const OutboundAnswerTarget = struct {
    position: model.AnswerPosition,
    row_id: u64,
};

pub const OutboundAnswerTable = struct {
    rows: PositionSlab(AnswerCell) = .empty,

    pub const Id = model.AnswerPosition;
    pub const empty: OutboundAnswerTable = .{};

    pub const Entry = struct { position: Id, cell: *const AnswerCell };

    pub const Iterator = struct {
        rows: PositionSlab(AnswerCell).Iterator,

        pub fn next(self: *Iterator) ?Entry {
            const entry = self.rows.next() orelse return null;
            return .{ .position = .from(entry.index), .cell = entry.row };
        }
    };

    fn indexOf(position: Id) ?u32 {
        return std.math.cast(u32, position.int());
    }

    pub fn deinit(self: *OutboundAnswerTable, allocator: std.mem.Allocator) void {
        for (self.rows.slots.items) |*slot| switch (slot.*) {
            .live => |*cell| _ = store.deinitAnswerCell(allocator, cell),
            else => {},
        };
        self.rows.deinit(allocator);
    }

    pub fn iterator(self: *const OutboundAnswerTable) Iterator {
        return .{ .rows = self.rows.iterator() };
    }

    pub fn len(self: *const OutboundAnswerTable) usize {
        return self.rows.len();
    }

    /// The row at `position` now, whichever question it carries. The wire
    /// arms read this way: a partner message names the position as it stands.
    pub fn getPtr(self: *OutboundAnswerTable, position: Id) ?*AnswerCell {
        const index = indexOf(position) orelse return null;
        return self.rows.getPtr(index);
    }

    pub fn get(self: *const OutboundAnswerTable, position: Id) ?*const AnswerCell {
        const index = indexOf(position) orelse return null;
        return self.rows.getConstPtr(index);
    }

    /// The row `target` named when it was taken, or null once that row
    /// retired or the position carries a newer question.
    pub fn live(self: *OutboundAnswerTable, target: OutboundAnswerTarget) ?*AnswerCell {
        const cell = self.getPtr(target.position) orelse return null;
        return if (cell.row_id == target.row_id) cell else null;
    }

    pub fn contains(self: *const OutboundAnswerTable, position: Id) bool {
        const index = indexOf(position) orelse return false;
        return self.rows.contains(index);
    }

    pub fn count(self: *const OutboundAnswerTable, position: Id) u64 {
        const index = indexOf(position) orelse return 0;
        const cell = self.rows.getConstPtr(index) orelse return 0;
        return cell.count;
    }

    /// Whether a send may name `position` as a fresh question.
    pub fn fresh(self: *const OutboundAnswerTable, position: Id) bool {
        const index = indexOf(position) orelse return false;
        return self.rows.installable(index);
    }

    /// The identity of the question at `position`: its live row, or the
    /// stamp a reservation holds until the send installs it.
    pub fn targetOf(self: *const OutboundAnswerTable, position: Id) ?OutboundAnswerTarget {
        const index = indexOf(position) orelse return null;
        if (self.rows.getConstPtr(index)) |cell| return .{ .position = position, .row_id = cell.row_id };
        const stamp = self.rows.reservedStamp(index) orelse return null;
        return .{ .position = position, .row_id = stamp };
    }

    /// The position the next `reserve` hands out.
    pub fn nextPosition(self: *const OutboundAnswerTable) Id {
        return .from(self.rows.nextIndex());
    }

    /// Mint the next position for a question stamped `stamp`. `install` fills
    /// it after the carrying send commits, `abandon` returns it before.
    pub fn reserve(self: *OutboundAnswerTable, allocator: std.mem.Allocator, stamp: u64) std.mem.Allocator.Error!OutboundAnswerTarget {
        const index = try self.rows.reserve(allocator, stamp);
        return .{ .position = .from(index), .row_id = stamp };
    }

    /// The stamp a reservation at `position` holds, when one does.
    pub fn reservedStamp(self: *const OutboundAnswerTable, position: Id) ?u64 {
        const index = indexOf(position) orelse return null;
        return self.rows.reservedStamp(index);
    }

    /// Hold room so `installAssumeCapacity` at `position` cannot fail. A
    /// reserved position already has its slot.
    pub fn ensureInstallable(self: *OutboundAnswerTable, allocator: std.mem.Allocator, position: Id) std.mem.Allocator.Error!void {
        // A position past the slab's index range is never fresh, and every
        // caller proved freshness first.
        const index = indexOf(position).?;
        std.debug.assert(self.rows.installable(index));
        try self.rows.ensureIndex(allocator, index);
    }

    /// Fill `position`: the reserved slot it was minted into, or the explicit
    /// slot `ensureInstallable` prepared.
    pub fn installAssumeCapacity(self: *OutboundAnswerTable, position: Id, cell: AnswerCell) void {
        const index = indexOf(position).?;
        if (self.rows.reservedStamp(index)) |stamp| std.debug.assert(stamp == cell.row_id);
        self.rows.installAtAssumeCapacity(index, cell);
    }

    pub fn install(self: *OutboundAnswerTable, allocator: std.mem.Allocator, position: Id, cell: AnswerCell) std.mem.Allocator.Error!void {
        try self.ensureInstallable(allocator, position);
        self.installAssumeCapacity(position, cell);
    }

    /// Return a reserved position the send never carried.
    pub fn abandonReserved(self: *OutboundAnswerTable, position: Id) void {
        self.rows.abandon(indexOf(position).?);
    }

    /// Retire a row the partner never saw, or whose question it has answered
    /// and may see reused.
    pub fn remove(self: *OutboundAnswerTable, position: Id) void {
        self.rows.remove(indexOf(position).?);
    }

    /// Retire a row the partner may still resolve by position.
    pub fn withhold(self: *OutboundAnswerTable, position: Id) void {
        self.rows.withhold(indexOf(position).?);
    }
};
