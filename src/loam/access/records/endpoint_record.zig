//! A fixed content/resource binding around an exact durable capability edge.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const fields = @import("fields.zig");
const profile = @import("profile.zig");

pub const EndpointRecord = struct {
    descriptor: loam.ObjectId,
    content: ?struct { resource: core.ResourceId, object: loam.ObjectId } = null,
    publication: ?loam.ObjectId = null,
    next_derivation: u64 = 1,
    receipt_count: u8 = 0,
    receipts: [max_receipts]loam.ObjectId = undefined,
    pub const max_receipts = 8;
    pub const version = 2;
    pub const max_edges = 3 + max_receipts;
    pub const max_encoded_bytes = 192;

    pub fn encodeAlloc(self: EndpointRecord, allocator: std.mem.Allocator) ![]u8 {
        if (self.receipt_count > max_receipts or self.next_derivation <= self.receipt_count) return error.InvalidRecord;
        if (self.content) |content| {
            if (content.resource.generation == 0 or content.object.store != self.descriptor.store) return error.InvalidRecord;
        }
        if (self.publication) |id| if (id.store != self.descriptor.store) return error.InvalidRecord;
        for (self.receipts[0..self.receipt_count]) |id| if (id.store != self.descriptor.store) return error.InvalidRecord;
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    pub fn decode(view: loam.View) !EndpointRecord {
        if (view.schema != profile.endpoint or view.schema_version != version or view.payload.len > max_encoded_bytes or view.edge_count < 1 or view.edge_count > max_edges) return error.InvalidRecord;
        var iterator = view.edges();
        const descriptor = iterator.next().?;
        if (descriptor.strength != .strong) return error.InvalidRecord;
        const b = view.payload;
        var c: usize = 0;
        try s.readByte(b, &c, '<');
        if (!std.mem.eql(u8, try s.readSymbol(b, &c), "access:endpoint")) return error.InvalidRecord;
        if (try s.readPositiveInt(b, &c) != version) return error.UnsupportedVersion;
        var result: EndpointRecord = .{ .descriptor = descriptor.target };
        if (try s.readBool(b, &c)) {
            const edge = iterator.next() orelse return error.InvalidRecord;
            if (edge.strength != .strong or edge.target.store != descriptor.target.store) return error.InvalidRecord;
            const resource = try fields.readId(core.ResourceId, b, &c);
            if (resource.generation == 0) return error.InvalidRecord;
            result.content = .{ .resource = resource, .object = edge.target };
        }
        if (try s.readBool(b, &c)) result.publication = (try nextEdge(&iterator, descriptor.target)).target;
        result.next_derivation = try s.readPositiveInt(b, &c);
        const count = try s.readPositiveInt(b, &c);
        if (count > max_receipts or result.next_derivation <= count) return error.InvalidRecord;
        result.receipt_count = @intCast(count);
        for (result.receipts[0..result.receipt_count]) |*id| id.* = (try nextEdge(&iterator, descriptor.target)).target;
        if (iterator.next() != null) return error.InvalidRecord;
        try s.readByte(b, &c, '>');
        try s.expectEnd(b, c);
        return result;
    }

    fn write(sink: anytype, self: EndpointRecord) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, "access:endpoint");
        try s.writePositiveInt(sink, version);
        try s.writeBool(sink, self.content != null);
        if (self.content) |content| try fields.writeId(sink, content.resource);
        try s.writeBool(sink, self.publication != null);
        try s.writePositiveInt(sink, self.next_derivation);
        try s.writePositiveInt(sink, self.receipt_count);
        try s.endRecord(sink);
    }

    pub fn edges(self: EndpointRecord, buffer: *[max_edges]loam.Edge) []const loam.Edge {
        var n: usize = 1;
        buffer[0] = .{ .target = self.descriptor };
        if (self.content) |content| {
            buffer[n] = .{ .target = content.object };
            n += 1;
        }
        if (self.publication) |id| {
            buffer[n] = .{ .target = id };
            n += 1;
        }
        for (self.receipts[0..self.receipt_count]) |id| {
            buffer[n] = .{ .target = id };
            n += 1;
        }
        return buffer[0..n];
    }

    fn nextEdge(iterator: anytype, descriptor: loam.ObjectId) !loam.Edge {
        const edge = iterator.next() orelse return error.InvalidRecord;
        if (edge.strength != .strong or edge.target.store != descriptor.store) return error.InvalidRecord;
        return edge;
    }
};
