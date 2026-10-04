//! Pending collector effects, separate from live-custody authority. One cycle
//! owns bounded ID storage and worker scratch; receipts retire submitted debt.
const std = @import("std");
const records = @import("loam_records");

pub const Custody = struct {
    allocator: std.mem.Allocator,
    roots: std.ArrayList(records.ObjectId) = .empty,
    scratch: []u8,
    limit: usize,

    /// One record buffer per cycle. Root capacity grows only as admitted debt
    /// requires, never beyond the configured bound, and is reused after shading.
    pub fn init(allocator: std.mem.Allocator, limit: usize, record_bytes: usize) !Custody {
        const scratch = try allocator.alloc(u8, record_bytes);
        return .{ .allocator = allocator, .scratch = scratch, .limit = limit };
    }

    pub fn deinit(self: *Custody) void {
        self.roots.deinit(self.allocator);
        self.allocator.free(self.scratch);
        self.* = undefined;
    }

    /// Reservation changes capacity only; failed acquisition publishes no debt.
    pub fn reserve(self: *Custody, count: usize) !void {
        if (count > self.limit - self.roots.items.len) return error.RetentionCapacity;
        const required = self.roots.items.len + count;
        if (required <= self.roots.capacity) return;
        const growth = std.math.mul(usize, self.roots.capacity, 2) catch self.limit;
        try self.roots.ensureTotalCapacityPrecise(self.allocator, @min(self.limit, @max(required, @max(16, growth))));
    }

    pub fn append(self: *Custody, id: records.ObjectId) void {
        self.roots.appendAssumeCapacity(id);
    }

    pub fn reserveRecord(self: *Custody, view: records.View) !void {
        var count: usize = 1;
        var edges = view.edges();
        while (edges.next()) |edge| if (edge.strength == .strong) {
            count += 1;
        };
        try self.reserve(count);
    }

    /// A historical portrait's strong edges must be shaded even if its current
    /// stored replacement no longer names them. Call after reservation succeeds.
    pub fn appendRecord(self: *Custody, view: records.View) void {
        self.append(view.id);
        var edges = view.edges();
        while (edges.next()) |edge| if (edge.strength == .strong) self.append(edge.target);
    }

    /// Admission is frozen while the immutable batch borrows this journal.
    /// Clearing/finishing batches submit zero and acknowledge no obligations.
    pub fn acknowledge(self: *Custody, count: usize) void {
        if (count == 0) return;
        std.debug.assert(count == self.roots.items.len);
        self.roots.clearRetainingCapacity();
    }
};
