//! A mutation retains exact request bytes, result bytes and their durable edges.
//! The facet mask marks result edges that replay as a facet guarded by the
//! invoking endpoint instead of as the edge's own authority.
const std = @import("std");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const fields = @import("fields.zig");
const profile = @import("profile.zig");

pub const MutationRecord = struct {
    intent: []const u8,
    result: []const u8,
    /// Bit `i` set: edge `i` replays as a dependent facet of the invoking
    /// endpoint.
    facets: u64 = 0,
    pub const max_encoded_bytes = 64 * 1024;
    pub const max_edges = 64;
    pub const format_version: u64 = 1;
    const label = "access:mutation";
    const header_bytes = syrup.render.measureRecord(writeHeader, .{}) catch unreachable;
    pub const Facets = @FieldType(MutationRecord, "facets");
    comptime {
        std.debug.assert(max_edges <= @bitSizeOf(Facets));
    }

    /// The mask bit for receipt edge `index`.
    pub fn facetBit(index: usize) Facets {
        return @as(Facets, 1) << @intCast(index);
    }

    /// Whether receipt edge `index` replays as a dependent facet.
    pub fn hasFacet(facets: Facets, index: usize) bool {
        return index < max_edges and facets & facetBit(index) != 0;
    }

    pub fn encodedSizeBound(intent_bytes: usize, result_bytes: usize) !usize {
        // The mask is at most twenty decimal digits and its `+`.
        const body = try std.math.add(usize, try std.math.add(usize, try s.byteStringSize(intent_bytes), try s.byteStringSize(result_bytes)), 21);
        return @min(try std.math.add(usize, try std.math.add(usize, header_bytes, body), 1), max_encoded_bytes);
    }

    pub fn encodeAlloc(self: MutationRecord, allocator: std.mem.Allocator) ![]u8 {
        const length = try syrup.render.measureRecord(write, .{self});
        if (length > max_encoded_bytes) return error.RecordTooLarge;
        const bytes = try allocator.alloc(u8, length);
        errdefer allocator.free(bytes);
        try syrup.render.renderRecordInto(bytes, write, .{self});
        return bytes;
    }

    pub fn decode(view: loam.View) !MutationRecord {
        if (view.schema != profile.mutation or view.schema_version != format_version or view.payload.len > max_encoded_bytes or view.edge_count > max_edges) return error.InvalidRecord;
        var edges = view.edges();
        for (0..view.edge_count) |_| _ = try fields.readEdge(&edges, view.id.store);
        var cursor: usize = 0;
        try s.readByte(view.payload, &cursor, '<');
        if (!std.mem.eql(u8, try s.readSymbol(view.payload, &cursor), label)) return error.InvalidRecord;
        if (try s.readPositiveInt(view.payload, &cursor) != format_version) return error.UnsupportedVersion;
        const result: MutationRecord = .{ .intent = try s.readBytes(view.payload, &cursor), .result = try s.readBytes(view.payload, &cursor), .facets = try s.readPositiveInt(view.payload, &cursor) };
        if (view.edge_count < 64 and result.facets >> @intCast(view.edge_count) != 0) return error.InvalidRecord;
        try s.readByte(view.payload, &cursor, '>');
        try s.expectEnd(view.payload, cursor);
        return result;
    }

    fn write(sink: anytype, self: MutationRecord) !void {
        try writeHeader(sink);
        try s.writeBytes(sink, self.intent);
        try s.writeBytes(sink, self.result);
        try s.writePositiveInt(sink, self.facets);
        try s.endRecord(sink);
    }

    fn writeHeader(sink: anytype) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, label);
        try s.writePositiveInt(sink, format_version);
    }
};
