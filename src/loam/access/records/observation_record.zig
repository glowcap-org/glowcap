//! Durable observation authority and a context-specific cursor sealing key.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const fields = @import("fields.zig");
const profile = @import("profile.zig");
const endpoint_record = @import("observation_endpoint_record.zig");

pub const ObservationRecord = struct {
    owner: loam.ObjectId,
    descriptor: ?loam.ObjectId,
    target: ?core.ResourceId,
    key: [32]u8,
    started: u64 = 0,
    publications: Publications = @splat(null),
    /// A trusted hosting marker fences a runtime observer. Durable observers
    /// omit this field. Their capabilities survive Store and Host restart.
    lifetime: ?Lifetime = null,
    pub const Lifetime = struct { marker: loam.ObjectId, revision: u64 };
    /// The observer's endpoint publications, one per `ObservationEndpointRecord.Role`.
    pub const Publications = [endpoint_record.ObservationEndpointRecord.role_count]?loam.ObjectId;
    pub const max_encoded_bytes = 256;
    pub const max_edges = 5;
    pub const format_version: u64 = 1;
    const label = "access:observation";

    pub fn encodeAlloc(self: ObservationRecord, allocator: std.mem.Allocator) ![]u8 {
        if (self.target) |target| if (target.generation == 0) return error.InvalidRecord;
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    pub fn edges(self: ObservationRecord, buffer: *[max_edges]loam.Edge) []const loam.Edge {
        var count: usize = 0;
        if (self.descriptor) |descriptor| {
            buffer[count] = .{ .target = self.owner };
            count += 1;
            buffer[count] = .{ .target = descriptor };
            count += 1;
        }
        for (self.publications) |publication| if (publication) |id| {
            buffer[count] = .{ .target = id };
            count += 1;
        };
        if (self.lifetime) |lifetime| {
            buffer[count] = .{ .target = lifetime.marker };
            count += 1;
        }
        return buffer[0..count];
    }

    pub fn decode(view: loam.View) !ObservationRecord {
        if (view.schema != profile.observation or view.schema_version != format_version or view.payload.len > max_encoded_bytes) return error.InvalidRecord;
        const bytes = view.payload;
        var cursor: usize = 0;
        try s.readByte(bytes, &cursor, '<');
        if (!std.mem.eql(u8, try s.readSymbol(bytes, &cursor), label)) return error.InvalidRecord;
        if (try s.readPositiveInt(bytes, &cursor) != format_version) return error.UnsupportedVersion;
        var result: ObservationRecord = .{ .owner = view.id, .descriptor = null, .target = null, .key = undefined };
        var edges_it = view.edges();
        if (try s.readBool(bytes, &cursor)) {
            result.owner = try fields.readEdge(&edges_it, view.id.store);
            result.descriptor = try fields.readEdge(&edges_it, view.id.store);
        }
        if (try s.readBool(bytes, &cursor)) {
            result.target = try fields.readId(core.ResourceId, bytes, &cursor);
            if (result.target.?.generation == 0) return error.InvalidRecord;
        }
        const key = try s.readBytes(bytes, &cursor);
        if (key.len != result.key.len) return error.InvalidRecord;
        result.key = key[0..32].*;
        result.started = try s.readPositiveInt(bytes, &cursor);
        for (&result.publications) |*publication| if (try s.readBool(bytes, &cursor)) {
            publication.* = try fields.readEdge(&edges_it, view.id.store);
        };
        if (try s.readBool(bytes, &cursor)) {
            result.lifetime = .{ .marker = try fields.readEdge(&edges_it, view.id.store), .revision = try s.readPositiveInt(bytes, &cursor) };
            if (result.descriptor == null or result.lifetime.?.revision == 0) return error.InvalidRecord;
        }
        if (edges_it.next() != null) return error.InvalidRecord;
        try s.readByte(bytes, &cursor, '>');
        try s.expectEnd(bytes, cursor);
        return result;
    }

    fn write(sink: anytype, self: ObservationRecord) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, label);
        try s.writePositiveInt(sink, format_version);
        try s.writeBool(sink, self.descriptor != null);
        try s.writeBool(sink, self.target != null);
        if (self.target) |target| try fields.writeId(sink, target);
        try s.writeBytes(sink, &self.key);
        try s.writePositiveInt(sink, self.started);
        for (self.publications) |publication| try s.writeBool(sink, publication != null);
        try s.writeBool(sink, self.lifetime != null);
        if (self.lifetime) |lifetime| try s.writePositiveInt(sink, lifetime.revision);
        try s.endRecord(sink);
    }
};
