//! Separate actor lanes for receiving observations and cancelling their context.
const std = @import("std");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const profile = @import("profile.zig");

pub const ObservationEndpointRecord = struct {
    context: loam.ObjectId,
    role: enum { receive, cancel },
    pub const max_encoded_bytes = 64;
    pub fn encodeAlloc(self: ObservationEndpointRecord, allocator: std.mem.Allocator) ![]u8 {
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }
    pub fn decode(view: loam.View) !ObservationEndpointRecord {
        if (view.schema != profile.observation_endpoint or view.schema_version != 1 or view.payload.len > max_encoded_bytes or view.edge_count != 1) return error.InvalidRecord;
        var iterator = view.edges();
        const edge = iterator.next().?;
        if (edge.strength != .strong or edge.target.store != view.id.store) return error.InvalidRecord;
        const bytes = view.payload;
        var cursor: usize = 0;
        try s.readByte(bytes, &cursor, '<');
        if (!std.mem.eql(u8, try s.readSymbol(bytes, &cursor), "access:observer")) return error.InvalidRecord;
        if (try s.readPositiveInt(bytes, &cursor) != 1) return error.UnsupportedVersion;
        const role = try s.readBool(bytes, &cursor);
        try s.readByte(bytes, &cursor, '>');
        try s.expectEnd(bytes, cursor);
        return .{ .context = edge.target, .role = if (role) .cancel else .receive };
    }
    fn write(sink: anytype, self: ObservationEndpointRecord) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, "access:observer");
        try s.writePositiveInt(sink, 1);
        try s.writeBool(sink, self.role == .cancel);
        try s.endRecord(sink);
    }
};
