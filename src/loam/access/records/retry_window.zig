//! One endpoint's bounded sequence space survives receipt eviction and restart.
const std = @import("std");
const loam = @import("loam_records");
const s = @import("syrup").RecordSyntax;

pub const RetryWindow = struct {
    next: u64 = 1,
    count: u8 = 0,
    receipts: [capacity]loam.ObjectId = undefined,
    pub const capacity = 8;

    pub fn validate(self: RetryWindow) !void {
        if (self.count > capacity or self.next <= self.count or self.next > std.math.maxInt(i64)) return error.InvalidRecord;
    }

    /// Null is the next operation. A retained sequence names its exact receipt.
    /// The persisted floor refuses expired requests rather than reminting them.
    pub fn lookup(self: RetryWindow, sequence: u64) !?loam.ObjectId {
        try self.validate();
        if (sequence == 0 or sequence > self.next) return error.OperationOutOfOrder;
        const floor = self.next - self.count;
        if (sequence < floor) return error.ReceiptExpired;
        if (sequence == self.next) {
            if (self.next == std.math.maxInt(i64)) return error.SequenceExhausted;
            return null;
        }
        return self.receipts[@intCast(sequence - floor)];
    }

    pub fn append(self: *RetryWindow, receipt: loam.ObjectId) !void {
        _ = try self.lookup(self.next);
        if (self.count == capacity) {
            std.mem.copyForwards(loam.ObjectId, self.receipts[0 .. capacity - 1], self.receipts[1..capacity]);
            self.count -= 1;
        }
        self.receipts[self.count] = receipt;
        self.count += 1;
        self.next += 1;
    }

    pub fn write(self: RetryWindow, sink: anytype) !void {
        try s.writePositiveInt(sink, self.next);
        try s.writePositiveInt(sink, self.count);
    }

    pub fn read(bytes: []const u8, cursor: *usize, edges: anytype, store: loam.StoreId) !RetryWindow {
        var result: RetryWindow = .{ .next = try s.readPositiveInt(bytes, cursor) };
        result.count = std.math.cast(u8, try s.readPositiveInt(bytes, cursor)) orelse return error.InvalidRecord;
        try result.validate();
        for (result.receipts[0..result.count]) |*id| {
            const edge = edges.next() orelse return error.InvalidRecord;
            if (edge.strength != .strong or edge.target.store != store) return error.InvalidRecord;
            id.* = edge.target;
        }
        return result;
    }
};
