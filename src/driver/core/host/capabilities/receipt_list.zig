//! A transaction's rollback receipts: on the stack while they fit the
//! inline capacity, spilled whole into the transaction's arena past it, so
//! the ordinary bounded value tree allocates nothing for them.

const std = @import("std");

pub fn ReceiptList(comptime Receipt: type, comptime inline_capacity: usize) type {
    return struct {
        const Self = @This();

        inline_items: [inline_capacity]Receipt = undefined,
        len: usize = 0,
        spill: std.ArrayListUnmanaged(Receipt) = .empty,

        /// Reserve room for one more receipt, moving the inline receipts
        /// into `arena` the first time the inline capacity is exceeded.
        pub fn ensureOne(self: *Self, arena: std.mem.Allocator) !void {
            if (self.spill.capacity != 0) {
                try self.spill.ensureUnusedCapacity(arena, 1);
                return;
            }
            if (self.len < inline_capacity) return;
            try self.spill.ensureTotalCapacityPrecise(arena, inline_capacity + 1);
            self.spill.appendSliceAssumeCapacity(self.inline_items[0..self.len]);
        }

        pub fn appendAssumeCapacity(self: *Self, receipt: Receipt) void {
            if (self.spill.capacity != 0)
                self.spill.appendAssumeCapacity(receipt)
            else
                self.inline_items[self.len] = receipt;
            self.len += 1;
        }

        pub fn items(self: *const Self) []const Receipt {
            return if (self.spill.capacity != 0) self.spill.items else self.inline_items[0..self.len];
        }

        /// Free a spill that grew in a caller allocator rather than an arena.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.spill.deinit(allocator);
        }
    };
}
