//! Rows a message-scoped record holds in place until more arrive than fit.
//!
//! A message usually mentions one or two positions, so a record built for one
//! message should cost nothing to build and nothing to drop. The two types
//! here keep their first few rows inside the record itself and move every row
//! to the allocator only when a message carries more than that. A record that
//! spills stays spilled for its lifetime, which is one message. The rows live
//! inside the struct, so a caller takes `items` or an iterator from the
//! record's final address, never from a copy.

const std = @import("std");
const identity_hash = @import("identity_hash.zig");

/// An ordered list whose first `inline_capacity` rows sit in the struct.
pub fn List(comptime T: type, comptime inline_capacity: usize) type {
    return struct {
        const Self = @This();

        held: [inline_capacity]T = undefined,
        held_len: usize = 0,
        /// Owns every row once `spilled` is set.
        heap: std.ArrayListUnmanaged(T) = .empty,
        spilled: bool = false,

        pub const empty: Self = .{};

        /// `empty`, written in place: only the bookkeeping fields, so the
        /// unwritten rows cost a wide record nothing per fill.
        pub inline fn init(self: *Self) void {
            self.held_len = 0;
            self.heap = .empty;
            self.spilled = false;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.heap.deinit(allocator);
            self.* = undefined;
        }

        pub inline fn items(self: *const Self) []const T {
            return if (self.spilled) self.heap.items else self.held[0..self.held_len];
        }

        pub fn count(self: *const Self) usize {
            return self.items().len;
        }

        /// Make room for `additional` rows, so the appends that follow cannot
        /// fail. Rows that still fit in place cost no allocation.
        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
            if (self.spilled) return self.heap.ensureUnusedCapacity(allocator, additional);
            if (additional <= inline_capacity - self.held_len) return;
            try self.spill(allocator, additional);
        }

        pub fn append(self: *Self, allocator: std.mem.Allocator, item: T) std.mem.Allocator.Error!void {
            if (!self.spilled) {
                if (self.held_len < inline_capacity) {
                    self.appendHeld(item);
                    return;
                }
                try self.spill(allocator, 1);
            }
            try self.heap.append(allocator, item);
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            if (self.spilled) {
                self.heap.appendAssumeCapacity(item);
            } else {
                if (inline_capacity == 0) unreachable;
                std.debug.assert(self.held_len < inline_capacity);
                self.appendHeld(item);
            }
        }

        fn appendHeld(self: *Self, item: T) void {
            self.held[self.held_len] = item;
            self.held_len += 1;
        }

        /// Move the held rows to the allocator once, with room for what is
        /// coming. Nothing changes if the allocation refuses.
        fn spill(self: *Self, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
            const total = std.math.add(usize, self.held_len, additional) catch return error.OutOfMemory;
            try self.heap.ensureTotalCapacity(allocator, total);
            self.heap.appendSliceAssumeCapacity(self.held[0..self.held_len]);
            self.held_len = 0;
            self.spilled = true;
        }
    };
}

/// A table whose first `inline_capacity` rows sit in the struct and are found
/// by a short scan, which is cheaper than a hash while the rows fit in a cache
/// line. Past that every row lives in a hash map that names who chooses its
/// keys, as every table does (`identity_hash.Provenance`).
pub fn Table(
    comptime K: type,
    comptime V: type,
    comptime inline_capacity: usize,
    comptime provenance: identity_hash.Provenance,
) type {
    return struct {
        const Self = @This();
        pub const Heap = identity_hash.MapOf(provenance, K, V);
        pub const GetOrPut = struct { value_ptr: *V, found_existing: bool };
        pub const Entry = struct { key_ptr: *K, value_ptr: *V };

        keys: [inline_capacity]K = undefined,
        values: [inline_capacity]V = undefined,
        held_len: usize = 0,
        /// Owns every row once `spilled` is set.
        heap: Heap,
        spilled: bool = false,

        /// A table of keys this process allocates.
        pub const empty: Self = .{ .heap = .empty };

        /// A table of keys the peer chooses, hashed under `multiplier` once it
        /// spills.
        pub fn keyed(multiplier: u64) Self {
            return .{ .heap = .keyed(multiplier) };
        }

        /// `keyed`, written in place: only the bookkeeping fields, so the
        /// unwritten rows cost a wide record nothing per fill.
        pub inline fn initKeyed(self: *Self, multiplier: u64) void {
            self.held_len = 0;
            self.heap = .keyed(multiplier);
            self.spilled = false;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.heap.deinit(allocator);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return if (self.spilled) self.heap.count() else self.held_len;
        }

        pub fn contains(self: *Self, key: K) bool {
            return self.getPtr(key) != null;
        }

        pub fn getPtr(self: *Self, key: K) ?*V {
            if (self.spilled) return self.heap.getPtr(key);
            if (inline_capacity == 0) return null;
            // A handful of rows: compare each one rather than hash the key.
            for (self.keys[0..self.held_len], 0..) |held, index| {
                if (identity_hash.eql(held, key)) return &self.values[index];
            }
            return null;
        }

        /// Make room for `additional` rows, so the puts that follow cannot
        /// fail. Rows that still fit in place cost no allocation.
        pub fn ensureUnusedCapacity(self: *Self, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
            if (self.spilled) {
                const total = try reservationSize(self.count(), additional);
                return self.heap.ensureTotalCapacity(allocator, total);
            }
            if (additional <= inline_capacity - self.held_len) return;
            try self.spill(allocator, additional);
        }

        /// Find the row for `key` or add one whose value the caller then sets.
        pub fn getOrPut(self: *Self, allocator: std.mem.Allocator, key: K) std.mem.Allocator.Error!GetOrPut {
            if (!self.spilled) {
                if (self.getPtr(key)) |value_ptr| return .{ .value_ptr = value_ptr, .found_existing = true };
                if (self.held_len < inline_capacity) return .{ .value_ptr = self.putHeld(key), .found_existing = false };
                try self.spill(allocator, 1);
            }
            const row = try self.heap.getOrPut(allocator, key);
            return .{ .value_ptr = row.value_ptr, .found_existing = row.found_existing };
        }

        /// `getOrPut` after `ensureUnusedCapacity` covered this row.
        pub fn getOrPutAssumeCapacity(self: *Self, key: K) GetOrPut {
            if (!self.spilled) {
                if (self.getPtr(key)) |value_ptr| return .{ .value_ptr = value_ptr, .found_existing = true };
                if (inline_capacity == 0) unreachable;
                std.debug.assert(self.held_len < inline_capacity);
                return .{ .value_ptr = self.putHeld(key), .found_existing = false };
            }
            const row = self.heap.getOrPutAssumeCapacity(key);
            return .{ .value_ptr = row.value_ptr, .found_existing = row.found_existing };
        }

        fn putHeld(self: *Self, key: K) *V {
            self.keys[self.held_len] = key;
            self.held_len += 1;
            return &self.values[self.held_len - 1];
        }

        /// Move the held rows into the map once, with room for what is
        /// coming. Nothing changes if the allocation refuses.
        fn spill(self: *Self, allocator: std.mem.Allocator, additional: usize) std.mem.Allocator.Error!void {
            const total = try reservationSize(self.held_len, additional);
            try self.heap.ensureTotalCapacity(allocator, total);
            for (self.keys[0..self.held_len], self.values[0..self.held_len]) |key, value| {
                self.heap.putAssumeCapacityNoClobber(key, value);
            }
            self.held_len = 0;
            self.spilled = true;
        }

        /// The backing map rounds capacity to a power of two and computes
        /// capacity * load percentage in u32. Refuse before either can overflow.
        fn reservationSize(current: usize, additional: usize) std.mem.Allocator.Error!u32 {
            const load = std.hash_map.default_max_load_percentage;
            const max_capacity = std.math.floorPowerOfTwo(u32, std.math.maxInt(u32) / load);
            const max_rows = max_capacity * load / 100;
            const total = std.math.add(usize, current, additional) catch return error.OutOfMemory;
            if (total > max_rows) return error.OutOfMemory;
            return @intCast(total);
        }

        pub const Iterator = struct {
            table: *Self,
            index: usize = 0,
            heap_it: Heap.Iterator,

            pub fn next(self: *Iterator) ?Entry {
                if (self.table.spilled) {
                    const entry = self.heap_it.next() orelse return null;
                    return .{ .key_ptr = entry.key_ptr, .value_ptr = entry.value_ptr };
                }
                if (inline_capacity == 0) return null;
                if (self.index >= self.table.held_len) return null;
                defer self.index += 1;
                return .{ .key_ptr = &self.table.keys[self.index], .value_ptr = &self.table.values[self.index] };
            }
        };

        pub fn iterator(self: *Self) Iterator {
            return .{ .table = self, .heap_it = self.heap.iterator() };
        }
    };
}
