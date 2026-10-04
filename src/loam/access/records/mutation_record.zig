//! A mutation retains exact request bytes, result bytes and their durable edges.
const std = @import("std");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const profile = @import("profile.zig");

pub const MutationRecord = struct {
    intent: []const u8,
    result: []const u8,
    pub const max_encoded_bytes = 64 * 1024;
    pub const max_edges = 64;

    pub fn encodeAlloc(self: MutationRecord, allocator: std.mem.Allocator) ![]u8 {
        const length = try syrup.render.measureRecord(write, .{self});
        if (length > max_encoded_bytes) return error.RecordTooLarge;
        const bytes = try allocator.alloc(u8, length);
        errdefer allocator.free(bytes);
        try syrup.render.renderRecordInto(bytes, write, .{self});
        return bytes;
    }

    pub fn decode(view: loam.View) !MutationRecord {
        if (view.schema != profile.mutation or view.schema_version != 1 or view.payload.len > max_encoded_bytes or view.edge_count > max_edges) return error.InvalidRecord;
        var edges = view.edges();
        while (edges.next()) |edge| if (edge.strength != .strong or edge.target.store != view.id.store) return error.InvalidRecord;
        var cursor: usize = 0;
        try s.readByte(view.payload, &cursor, '<');
        if (!std.mem.eql(u8, try s.readSymbol(view.payload, &cursor), "access:mutation")) return error.InvalidRecord;
        if (try s.readPositiveInt(view.payload, &cursor) != 1) return error.UnsupportedVersion;
        const result: MutationRecord = .{ .intent = try s.readBytesLimited(view.payload, &cursor, view.payload.len), .result = try s.readBytesLimited(view.payload, &cursor, view.payload.len) };
        try s.readByte(view.payload, &cursor, '>');
        try s.expectEnd(view.payload, cursor);
        return result;
    }

    fn write(sink: anytype, self: MutationRecord) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, "access:mutation");
        try s.writePositiveInt(sink, 1);
        try s.writeBytes(sink, self.intent);
        try s.writeBytes(sink, self.result);
        try s.endRecord(sink);
    }
};
