//! A dense table of the positions this side mints.
//!
//! Export positions and outbound answer positions are ours to hand out, so
//! their table is a vector indexed by position, with a free list threaded
//! through the retired slots. A retired position is the next one minted, so
//! the vector grows only as far as the positions open at once. A
//! partner-chosen position (an import, an inbound answer) never comes here:
//! an untrusted peer could name `1 << 63`, so those tables hash under a
//! secret (ADR-0037). ADR-0038 settles the shape and the stamped identity a
//! reader keeps across a position's reuse.
//!
//! A reused position is a new row. A holder that keeps a position past its
//! row's retirement keeps the row's stamp beside it and reads back through
//! the owning table's stamp-checked lookup, which answers null for a row
//! that is gone or replaced.
const std = @import("std");

/// The free list's terminator and the one index no slot can have.
pub const none: u32 = std.math.maxInt(u32);

pub fn PositionSlab(comptime Row: type) type {
    return struct {
        slots: std.ArrayListUnmanaged(Slot) = .empty,
        free_head: u32 = none,
        live_count: u32 = 0,

        const Self = @This();
        pub const empty: Self = .{};

        pub const Slot = union(enum) {
            /// Retired, or grown past and never minted: on the free list.
            free: Link,
            /// Minted and not yet installed, holding the stamp its row carries. status-allow: pending state or quoted runtime label
            reserved: u64,
            live: Row,
        };

        const Link = struct { next: u32, prev: u32 };

        pub const Entry = struct { index: u32, row: *const Row };

        pub const Iterator = struct {
            slots: []const Slot,
            index: u32 = 0,

            pub fn next(self: *Iterator) ?Entry {
                while (self.index < self.slots.len) {
                    const index = self.index;
                    self.index += 1;
                    switch (self.slots[index]) {
                        .live => |*row| return .{ .index = index, .row = row },
                        else => {},
                    }
                }
                return null;
            }
        };

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.slots.deinit(allocator);
            self.* = .{};
        }

        /// Live rows, the count the resilience caps bound.
        pub fn len(self: *const Self) usize {
            return self.live_count;
        }

        /// Every slot the vector holds, live or not.
        pub fn capacityUsed(self: *const Self) usize {
            return self.slots.items.len;
        }

        pub fn iterator(self: *const Self) Iterator {
            return .{ .slots = self.slots.items };
        }

        pub fn getPtr(self: *Self, index: u32) ?*Row {
            if (index >= self.slots.items.len) return null;
            return switch (self.slots.items[index]) {
                .live => |*row| row,
                else => null,
            };
        }

        pub fn getConstPtr(self: *const Self, index: u32) ?*const Row {
            if (index >= self.slots.items.len) return null;
            return switch (self.slots.items[index]) {
                .live => |*row| row,
                else => null,
            };
        }

        pub fn contains(self: *const Self, index: u32) bool {
            return self.getConstPtr(index) != null;
        }

        /// Whether a row may be installed at `index` by an explicit choice.
        pub fn installable(self: *const Self, index: u32) bool {
            if (index >= self.slots.items.len) return true;
            return switch (self.slots.items[index]) {
                .free, .reserved => true,
                .live => false,
            };
        }

        pub fn reservedStamp(self: *const Self, index: u32) ?u64 {
            if (index >= self.slots.items.len) return null;
            return switch (self.slots.items[index]) {
                .reserved => |stamp| stamp,
                else => null,
            };
        }

        /// The index the next `reserve` hands out.
        pub fn nextIndex(self: *const Self) u32 {
            if (self.free_head != none) return self.free_head;
            return @intCast(self.slots.items.len);
        }

        /// Hold room for `additional` reservations. One reservation is served
        /// by the free list when it has a slot. More than one grows the
        /// vector by the full count, which over-reserves by the free slots
        /// the next mints take first.
        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
            if (additional == 1 and self.free_head != none) return;
            if (self.slots.items.len + additional > none) return error.OutOfMemory;
            try self.slots.ensureUnusedCapacity(allocator, additional);
        }

        /// Mint the lowest free index, or grow by one. The slot holds `stamp`
        /// until `install` or `abandon`.
        pub fn reserve(self: *Self, allocator: std.mem.Allocator, stamp: u64) std.mem.Allocator.Error!u32 {
            try self.ensureUnusedCapacity(allocator, 1);
            return self.reserveAssumeCapacity(stamp);
        }

        pub fn reserveAssumeCapacity(self: *Self, stamp: u64) u32 {
            const index = self.takeFree() orelse blk: {
                const fresh: u32 = @intCast(self.slots.items.len);
                self.slots.appendAssumeCapacity(undefined);
                break :blk fresh;
            };
            self.slots.items[index] = .{ .reserved = stamp };
            return index;
        }

        /// Fill a reserved slot.
        pub fn install(self: *Self, index: u32, row: Row) void {
            std.debug.assert(self.slots.items[index] == .reserved);
            self.slots.items[index] = .{ .live = row };
            self.live_count += 1;
        }

        /// Grow through `index`, threading every new slot free, so a later
        /// `installAtAssumeCapacity` there cannot fail. An explicit position
        /// past the frontier reserves the slots below it, and the free list
        /// hands those out to the next reservations. The index is the exact
        /// need, so the vector grows to it and no further: the amortized
        /// growth belongs to `reserve`, whose need is open-ended.
        pub fn ensureIndex(self: *Self, allocator: std.mem.Allocator, index: u32) std.mem.Allocator.Error!void {
            if (index < self.slots.items.len) return;
            if (index == none) return error.OutOfMemory;
            try self.slots.ensureTotalCapacityPrecise(allocator, @as(usize, index) + 1);
            while (self.slots.items.len <= index) {
                const fresh: u32 = @intCast(self.slots.items.len);
                self.slots.appendAssumeCapacity(undefined);
                self.pushFree(fresh);
            }
        }

        /// Fill a free or reserved slot the caller chose.
        pub fn installAtAssumeCapacity(self: *Self, index: u32, row: Row) void {
            std.debug.assert(index < self.slots.items.len);
            switch (self.slots.items[index]) {
                .free => self.unlinkFree(index),
                .reserved => {},
                .live => unreachable,
            }
            self.slots.items[index] = .{ .live = row };
            self.live_count += 1;
        }

        pub fn installAt(self: *Self, allocator: std.mem.Allocator, index: u32, row: Row) std.mem.Allocator.Error!void {
            try self.ensureIndex(allocator, index);
            self.installAtAssumeCapacity(index, row);
        }

        /// Return a reserved slot to the free list.
        pub fn abandon(self: *Self, index: u32) void {
            std.debug.assert(self.slots.items[index] == .reserved);
            self.pushFree(index);
        }

        /// Retire a live row and free its position for the next mint.
        pub fn remove(self: *Self, index: u32) void {
            std.debug.assert(self.slots.items[index] == .live);
            self.live_count -= 1;
            self.pushFree(index);
        }

        fn pushFree(self: *Self, index: u32) void {
            if (self.free_head != none) self.slots.items[self.free_head].free.prev = index;
            self.slots.items[index] = .{ .free = .{ .next = self.free_head, .prev = none } };
            self.free_head = index;
        }

        fn takeFree(self: *Self) ?u32 {
            if (self.free_head == none) return null;
            const index = self.free_head;
            self.unlinkFree(index);
            return index;
        }

        fn unlinkFree(self: *Self, index: u32) void {
            const link = self.slots.items[index].free;
            if (link.prev != none) {
                self.slots.items[link.prev].free.next = link.next;
            } else {
                self.free_head = link.next;
            }
            if (link.next != none) self.slots.items[link.next].free.prev = link.prev;
        }
    };
}
