//! Separate actor lanes for receiving observations and cancelling their context.
const std = @import("std");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const fields = @import("fields.zig");
const profile = @import("profile.zig");

pub const ObservationEndpointRecord = struct {
    context: loam.ObjectId,
    role: Role,
    /// The observer's fronts.
    pub const Role = enum { receive, cancel };
    pub const role_count = @typeInfo(Role).@"enum".field_names.len;
    pub const max_encoded_bytes = 64;
    pub const format_version: u64 = 1;
    pub const max_edges = 1;
    const label = "access:observer";
    pub fn encodeAlloc(self: ObservationEndpointRecord, allocator: std.mem.Allocator) ![]u8 {
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }
    pub fn decode(view: loam.View) !ObservationEndpointRecord {
        if (view.schema != profile.observation_endpoint or view.schema_version != format_version or view.payload.len > max_encoded_bytes or view.edge_count != 1) return error.InvalidRecord;
        var iterator = view.edges();
        const context = try fields.readEdge(&iterator, view.id.store);
        const bytes = view.payload;
        var cursor: usize = 0;
        try s.readByte(bytes, &cursor, '<');
        if (!std.mem.eql(u8, try s.readSymbol(bytes, &cursor), label)) return error.InvalidRecord;
        if (try s.readPositiveInt(bytes, &cursor) != format_version) return error.UnsupportedVersion;
        const role = try s.readBool(bytes, &cursor);
        try s.readByte(bytes, &cursor, '>');
        try s.expectEnd(bytes, cursor);
        return .{ .context = context, .role = if (role) .cancel else .receive };
    }
    fn write(sink: anytype, self: ObservationEndpointRecord) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, label);
        try s.writePositiveInt(sink, format_version);
        try s.writeBool(sink, self.role == .cancel);
        try s.endRecord(sink);
    }
};
