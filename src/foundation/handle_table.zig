//! Rows a handle addresses by index, under a generation that keeps a stale
//! handle from finding a later row.
//!
//! A table keyed by handles this process mints in sequence needs no hash: a
//! handle can name its row's index outright. What keeps a dense array from
//! replacing such a map is reclamation. A freed row must not lend its handle
//! a later meaning, because a stale handle held elsewhere (a redeemed route,
//! a queued action) has to fail closed. So a handle here is one word in two
//! halves: the low half is the row's index and the high half is the
//! generation of that row, which advances every time the row is freed. A
//! lookup is a bounds check and one compare. A row freed 2^32 times would
//! hand its first handle out again, so a row whose generation wraps retires
//! instead of rejoining the free chain, and no handle is ever minted twice.
//!
//! One table mints handles (`Owner`) and owns the index space. A table in
//! another layer that keeps its own row for the same handle (`Mirror`) places
//! it under the handle it was given and shares the index space without
//! minting. A handle type is a non-exhaustive `enum(u64)`, so the zero
//! handle, whose generation is zero, names no row in either table.

const std = @import("std");

const Index = u32;
const Generation = u32;

/// Marks the end of an owner's free chain, so this index is never a row.
const none: Index = std.math.maxInt(Index);

/// The rows an owner can mint before its handle space is spent.
pub const row_limit: usize = none;

/// The row a handle names.
pub fn index(handle: anytype) Index {
    return @truncate(@backingInt(handle));
}

/// The generation of the row a handle names.
pub fn generation(handle: anytype) Generation {
    return @truncate(@backingInt(handle) >> 32);
}

fn build(comptime H: type, row: Index, row_generation: Generation) H {
    return @fromBackingInt((@as(u64, row_generation) << 32) | row);
}

fn checkHandle(comptime H: type) void {
    const info = @typeInfo(H);
    if (info != .@"enum" or info.@"enum".tag_type != u64 or info.@"enum".mode != .nonexhaustive)
        @compileError("a handle is a non-exhaustive enum(u64): " ++ @typeName(H));
}

const Role = enum { owner, mirror };

/// The table that mints handles of type `H` for values of type `V`.
pub fn Owner(comptime H: type, comptime V: type) type {
    return Table(H, V, .owner);
}

/// A table that keeps its own `V` under handles another `Owner` minted.
pub fn Mirror(comptime H: type, comptime V: type) type {
    return Table(H, V, .mirror);
}

fn Table(comptime H: type, comptime V: type, comptime role: Role) type {
    checkHandle(H);
    return struct {
        const Self = @This();

        pub const Row = struct {
            generation: Generation,
            /// The next free row while this row sits in an owner's free chain.
            next_free: Index = none,
            value: ?V,
        };

        rows: std.ArrayListUnmanaged(Row) = .empty,
        /// An owner's free chain, most recently freed first, so a churning
        /// index space stays compact.
        free_head: Index = none,
        free_len: u32 = 0,
        len: u32 = 0,

        pub const empty: Self = .{};

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.rows.deinit(allocator);
            self.* = .{};
        }

        /// Live rows.
        pub fn count(self: *const Self) usize {
            return self.len;
        }

        /// Rows ever minted or reserved, live or free.
        pub fn rowCount(self: *const Self) usize {
            return self.rows.items.len;
        }

        /// The live row `handle` names, or null for a handle whose row was
        /// freed, was never minted, or was never placed here.
        pub fn get(self: *const Self, handle: H) ?V {
            const row = self.rowOf(handle) orelse return null;
            return row.value;
        }

        /// `get`, by address. The address holds until the next row is added.
        pub fn getPtr(self: *Self, handle: H) ?*V {
            const row = self.rowOf(handle) orelse return null;
            if (row.value == null) return null;
            return &row.value.?;
        }

        pub fn contains(self: *const Self, handle: H) bool {
            return self.get(handle) != null;
        }

        /// Free the row `handle` names. True when it was live.
        pub fn remove(self: *Self, handle: H) bool {
            return self.fetchRemove(handle) != null;
        }

        /// Free the row `handle` names and hand back its value. An owner
        /// advances the row's generation and chains it for the next mint. A
        /// mirror keeps the generation, because the owner decides when the
        /// index is spent, and only clears the value.
        pub fn fetchRemove(self: *Self, handle: H) ?V {
            const row = self.rowOf(handle) orelse return null;
            const value = row.value orelse return null;
            row.value = null;
            self.len -= 1;
            if (role == .owner) {
                // Generation zero is the never-minted mark. A row that reaches
                // it has spent every generation, so it retires: it is never
                // chained for a mint again, and its handles all miss.
                row.generation +%= 1;
                if (row.generation == 0) return value;
                row.next_free = self.free_head;
                self.free_head = index(handle);
                self.free_len += 1;
            }
            return value;
        }

        /// Walk every live value by address.
        pub fn valueIterator(self: *const Self) ValueIterator {
            return .{ .rows = self.rows.items };
        }

        pub const ValueIterator = struct {
            rows: []Row,
            at: usize = 0,

            pub fn next(self: *ValueIterator) ?*V {
                while (self.at < self.rows.len) {
                    const row = &self.rows[self.at];
                    self.at += 1;
                    if (row.value != null) return &row.value.?;
                }
                return null;
            }
        };

        /// Whether every index is spent, the precondition `mint` asserts.
        pub fn full(self: *const Self) bool {
            comptime std.debug.assert(role == .owner);
            return self.free_len == 0 and self.rows.items.len >= row_limit;
        }

        /// Mint a handle for `value` on the most recently freed row, or on a
        /// new one when none is free. The caller checked `full` first.
        pub fn mint(self: *Self, allocator: std.mem.Allocator, value: V) std.mem.Allocator.Error!H {
            comptime std.debug.assert(role == .owner);
            std.debug.assert(!self.full());
            if (self.free_head != none) {
                const at = self.free_head;
                const row = &self.rows.items[at];
                self.free_head = row.next_free;
                self.free_len -= 1;
                row.next_free = none;
                row.value = value;
                self.len += 1;
                return build(H, at, row.generation);
            }
            const at: Index = @intCast(self.rows.items.len);
            try self.rows.append(allocator, .{ .generation = 1, .value = value });
            self.len += 1;
            return build(H, at, 1);
        }

        /// Make room for the row `handle` names, so `placeReserved` cannot
        /// fail. Rows up to that index that hold nothing are added with
        /// generation zero, which no handle carries.
        pub fn reserve(self: *Self, allocator: std.mem.Allocator, handle: H) std.mem.Allocator.Error!void {
            comptime std.debug.assert(role == .mirror);
            const needed = @as(usize, index(handle)) + 1;
            if (self.rows.items.len >= needed) return;
            try self.rows.ensureTotalCapacity(allocator, needed);
            while (self.rows.items.len < needed)
                self.rows.appendAssumeCapacity(.{ .generation = 0, .value = null });
        }

        /// Place `value` under `handle` on a row `reserve` made room for. A
        /// row still holding a value under an older generation is an
        /// internal invariant failure: the owner freed that handle and this
        /// mirror never followed.
        pub fn placeReserved(self: *Self, handle: H, value: V) void {
            comptime std.debug.assert(role == .mirror);
            const row = &self.rows.items[index(handle)];
            std.debug.assert(row.value == null);
            row.generation = generation(handle);
            row.value = value;
            self.len += 1;
        }

        /// Clear every value and keep the rows, so a later `reserve` for a
        /// handle already seen allocates nothing.
        pub fn clearRetainingCapacity(self: *Self) void {
            comptime std.debug.assert(role == .mirror);
            for (self.rows.items) |*row| row.value = null;
            self.len = 0;
        }

        fn rowOf(self: *const Self, handle: H) ?*Row {
            const at = index(handle);
            if (at >= self.rows.items.len) return null;
            const row = &self.rows.items[at];
            if (row.generation != generation(handle)) return null;
            return row;
        }
    };
}
