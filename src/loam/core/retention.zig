//! Bounded live roots. Tokens describe local custody, not remote authority.
const std = @import("std");
const records = @import("loam_records");
pub const Retention = struct { store: records.StoreId, incarnation: u64, slot: usize, sequence: u64 };
const Entry = struct { id: records.ObjectId = undefined, sequence: u64 = 0 };
pub const Prepared = struct { token: Retention, id: records.ObjectId };
pub const Registry = struct {
    entries: []Entry,
    sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Registry {
        const entries = try allocator.alloc(Entry, capacity);
        @memset(entries, .{});
        return .{ .entries = entries };
    }

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) !void {
        for (self.entries) |entry| if (entry.sequence != 0) return error.Busy;
        allocator.free(self.entries);
    }

    /// Validate and choose a slot without publishing custody. The Store reserves
    /// collector capacity between this preparation and infallible installation.
    pub fn prepare(self: *Registry, meta: anytype, id: records.ObjectId) !Prepared {
        if (id.store != meta.store or id.incarnation == 0 or id.sequence == 0) return error.InvalidObject;
        for (self.entries, 0..) |entry, i| {
            if (entry.sequence != 0) continue;
            const sequence = try std.math.add(u64, self.sequence, 1);
            return .{ .id = id, .token = .{ .store = meta.store, .incarnation = meta.incarnation, .slot = i, .sequence = sequence } };
        }
        return error.RetentionCapacity;
    }

    pub fn install(self: *Registry, prepared: Prepared) Retention {
        std.debug.assert(self.entries[prepared.token.slot].sequence == 0 and prepared.token.sequence > self.sequence);
        self.entries[prepared.token.slot] = .{ .id = prepared.id, .sequence = prepared.token.sequence };
        self.sequence = prepared.token.sequence;
        return prepared.token;
    }

    pub fn release(self: *Registry, meta: anytype, token: Retention) !void {
        if (token.store != meta.store or token.incarnation != meta.incarnation or token.slot >= self.entries.len or token.sequence == 0 or self.entries[token.slot].sequence != token.sequence) return error.InvalidRetention;
        self.entries[token.slot].sequence = 0;
    }
};
