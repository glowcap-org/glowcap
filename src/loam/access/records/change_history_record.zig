//! Bounded chronological batch retention through ordinary strong Loam edges.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const fields = @import("fields.zig");
const profile = @import("profile.zig");

pub const ChangeHistoryRecord = struct {
    owner: core.OwnerId,
    next_sequence: u64 = 1,
    count: usize = 0,
    batches: [capacity]loam.ObjectId = undefined,

    pub const capacity = 32;
    pub const max_encoded_bytes = 128;

    pub fn encodeAlloc(self: ChangeHistoryRecord, allocator: std.mem.Allocator) ![]u8 {
        try self.validate();
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    pub fn edges(self: *const ChangeHistoryRecord, buffer: *[capacity]loam.Edge) ![]const loam.Edge {
        try self.validate();
        for (self.batches[0..self.count], buffer[0..self.count]) |batch, *edge| edge.* = .{ .target = batch };
        return buffer[0..self.count];
    }

    pub fn decode(view: loam.View) !ChangeHistoryRecord {
        if (view.schema != profile.change_history or view.schema_version != 1 or view.payload.len > max_encoded_bytes) return error.InvalidRecord;
        const bytes = view.payload;
        var cursor: usize = 0;
        try s.readByte(bytes, &cursor, '<');
        if (!std.mem.eql(u8, try s.readSymbol(bytes, &cursor), "access:change-history")) return error.InvalidRecord;
        if (try s.readPositiveInt(bytes, &cursor) != 1) return error.UnsupportedVersion;
        var result: ChangeHistoryRecord = .{
            .owner = @fromBackingInt(try fields.readWide(bytes, &cursor)),
            .next_sequence = try s.readPositiveInt(bytes, &cursor),
            .count = std.math.cast(usize, try s.readPositiveInt(bytes, &cursor)) orelse return error.InvalidRecord,
        };
        try result.validate();
        var retained = view.edges();
        for (result.batches[0..result.count], 0..) |*batch, index| {
            const edge = retained.next() orelse return error.InvalidRecord;
            if (edge.strength != .strong or edge.target.store != view.id.store) return error.InvalidRecord;
            for (result.batches[0..index]) |prior| if (prior.eql(edge.target)) return error.InvalidRecord;
            batch.* = edge.target;
        }
        if (retained.next() != null) return error.InvalidRecord;
        try s.readByte(bytes, &cursor, '>');
        try s.expectEnd(bytes, cursor);
        return result;
    }

    pub fn firstSequence(self: *const ChangeHistoryRecord) u64 {
        return self.next_sequence - self.count;
    }

    pub fn append(self: *ChangeHistoryRecord, object: loam.ObjectId) !u64 {
        try self.validate();
        if (self.next_sequence == std.math.maxInt(u64)) return error.RevisionExhausted;
        for (self.batches[0..self.count]) |prior| if (prior.eql(object)) return error.InvalidRecord;
        if (self.count == capacity) {
            std.mem.copyForwards(loam.ObjectId, self.batches[0 .. capacity - 1], self.batches[1..capacity]);
            self.count -= 1;
        }
        self.batches[self.count] = object;
        self.count += 1;
        const sequence = self.next_sequence;
        self.next_sequence += 1;
        return sequence;
    }

    fn validate(self: ChangeHistoryRecord) !void {
        if (self.count > capacity or self.next_sequence <= self.count) return error.InvalidRecord;
    }

    fn write(sink: anytype, self: ChangeHistoryRecord) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, "access:change-history");
        try s.writePositiveInt(sink, 1);
        try fields.writeWide(sink, @backingInt(self.owner));
        try s.writePositiveInt(sink, self.next_sequence);
        try s.writePositiveInt(sink, self.count);
        try s.endRecord(sink);
    }
};
