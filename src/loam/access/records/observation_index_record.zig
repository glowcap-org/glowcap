//! One owner bounds durable observation contexts independently of live calls.
const std = @import("std");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const fields = @import("fields.zig");
const profile = @import("profile.zig");

pub const ObservationIndexRecord = struct {
    count: usize = 0,
    contexts: [capacity]loam.ObjectId = undefined,
    pub const capacity = 32;
    pub const max_encoded_bytes = 64;
    pub const format_version: u64 = 1;
    pub const max_edges = capacity;
    const label = "access:observations";

    pub fn append(self: *ObservationIndexRecord, id: loam.ObjectId) !void {
        if (self.count >= capacity) return error.ObservationCapacity;
        for (self.contexts[0..self.count]) |prior| if (prior.eql(id)) return error.InvalidRecord;
        self.contexts[self.count] = id;
        self.count += 1;
    }

    pub fn remove(self: *ObservationIndexRecord, id: loam.ObjectId) !void {
        for (self.contexts[0..self.count], 0..) |prior, index| if (prior.eql(id)) {
            std.mem.copyForwards(loam.ObjectId, self.contexts[index .. self.count - 1], self.contexts[index + 1 .. self.count]);
            self.count -= 1;
            return;
        };
        return error.InvalidRecord;
    }

    pub fn encodeAlloc(self: ObservationIndexRecord, allocator: std.mem.Allocator) ![]u8 {
        if (self.count > capacity) return error.InvalidRecord;
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    pub fn edges(self: *const ObservationIndexRecord, buffer: *[capacity]loam.Edge) ![]const loam.Edge {
        if (self.count > capacity) return error.InvalidRecord;
        for (self.contexts[0..self.count], buffer[0..self.count]) |id, *edge| edge.* = .{ .target = id };
        return buffer[0..self.count];
    }

    pub fn decode(view: loam.View) !ObservationIndexRecord {
        if (view.schema != profile.observation_index or view.schema_version != format_version or view.payload.len > max_encoded_bytes or view.edge_count > capacity) return error.InvalidRecord;
        const bytes = view.payload;
        var cursor: usize = 0;
        try s.readByte(bytes, &cursor, '<');
        if (!std.mem.eql(u8, try s.readSymbol(bytes, &cursor), label)) return error.InvalidRecord;
        if (try s.readPositiveInt(bytes, &cursor) != format_version) return error.UnsupportedVersion;
        const count = try s.readPositiveInt(bytes, &cursor);
        if (count != view.edge_count) return error.InvalidRecord;
        var result: ObservationIndexRecord = .{};
        var iterator = view.edges();
        for (0..view.edge_count) |_| try result.append(try fields.readEdge(&iterator, view.id.store));
        try s.readByte(bytes, &cursor, '>');
        try s.expectEnd(bytes, cursor);
        return result;
    }

    fn write(sink: anytype, self: ObservationIndexRecord) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, label);
        try s.writePositiveInt(sink, format_version);
        try s.writePositiveInt(sink, self.count);
        try s.endRecord(sink);
    }
};
