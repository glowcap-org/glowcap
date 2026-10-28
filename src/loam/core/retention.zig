//! Bounded live roots. Tokens describe local custody, not remote authority.
const std = @import("std");
const records = @import("loam_records");
pub const Retention = struct { store: records.StoreId, incarnation: u64, slot: usize, sequence: u64 };
const Entry = struct { id: records.ObjectId = undefined, sequence: u64 = 0 };
pub const Prepared = struct { token: Retention, id: records.ObjectId };
pub const Registry = struct {
    entries: []Entry,
    /// The free slots as a stack, so choosing one takes constant time. The
    /// top `free_count` are free, and the next installation takes the top.
    free: []usize,
    free_count: usize,
    sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Registry {
        const entries = try allocator.alloc(Entry, capacity);
        errdefer allocator.free(entries);
        const free = try allocator.alloc(usize, capacity);
        @memset(entries, .{});
        // Slot zero on top, so slots fill in order.
        for (free, 0..) |*slot, i| slot.* = capacity - 1 - i;
        return .{ .entries = entries, .free = free, .free_count = capacity };
    }

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) !void {
        for (self.entries) |entry| if (entry.sequence != 0) return error.Busy;
        allocator.free(self.entries);
        allocator.free(self.free);
    }

    /// Validate and choose a slot without publishing custody. The Store reserves
    /// collector capacity between this preparation and infallible installation.
    pub fn prepare(self: *Registry, meta: anytype, id: records.ObjectId) !Prepared {
        if (id.store != meta.store or id.incarnation == 0 or id.sequence == 0) return error.InvalidObject;
        if (self.free_count == 0) return error.RetentionCapacity;
        const sequence = try std.math.add(u64, self.sequence, 1);
        const slot = self.free[self.free_count - 1];
        return .{ .id = id, .token = .{ .store = meta.store, .incarnation = meta.incarnation, .slot = slot, .sequence = sequence } };
    }

    pub fn install(self: *Registry, prepared: Prepared) Retention {
        std.debug.assert(self.entries[prepared.token.slot].sequence == 0 and prepared.token.sequence > self.sequence);
        std.debug.assert(self.free_count != 0 and self.free[self.free_count - 1] == prepared.token.slot);
        self.free_count -= 1;
        self.entries[prepared.token.slot] = .{ .id = prepared.id, .sequence = prepared.token.sequence };
        self.sequence = prepared.token.sequence;
        return prepared.token;
    }

    pub fn release(self: *Registry, meta: anytype, token: Retention) !void {
        if (token.store != meta.store or token.incarnation != meta.incarnation or token.slot >= self.entries.len or token.sequence == 0 or self.entries[token.slot].sequence != token.sequence) return error.InvalidRetention;
        self.entries[token.slot].sequence = 0;
        self.free[self.free_count] = token.slot;
        self.free_count += 1;
    }
};
