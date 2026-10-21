//! A fixed content/resource binding around an exact durable capability edge.
const std = @import("std");
const core = @import("loam_access_core");
const loam = @import("loam_records");
const syrup = @import("syrup");
const s = syrup.RecordSyntax;
const fields = @import("fields.zig");
const profile = @import("profile.zig");
const Window = @import("retry_window.zig").RetryWindow;

pub const EndpointRecord = struct {
    pub const Binding = struct { resource: core.ResourceId, object: loam.ObjectId };
    descriptor: loam.ObjectId,
    content: ?Binding = null,
    /// Exact durable content authority administered by a control. This field
    /// never makes the endpoint usable. Role admission remains in its descriptor.
    administration: ?Binding = null,
    publication: ?loam.ObjectId = null,
    derivations: Window = .{},
    mutations: Window = .{},
    pub const max_receipts = Window.capacity;
    pub const format_version: u64 = 1;
    const label = "access:endpoint";
    pub const max_edges = 4 + 2 * max_receipts;
    pub const max_encoded_bytes = 256;

    pub fn encodeAlloc(self: EndpointRecord, allocator: std.mem.Allocator) ![]u8 {
        try self.derivations.validate();
        try self.mutations.validate();
        if (self.content) |content| {
            if (content.resource.generation == 0 or content.object.store != self.descriptor.store) return error.InvalidRecord;
        }
        if (self.administration) |binding| {
            if (self.content != null or binding.resource.generation == 0 or binding.object.store != self.descriptor.store) return error.InvalidRecord;
        }
        if (self.publication) |id| if (id.store != self.descriptor.store) return error.InvalidRecord;
        for ([_]Window{ self.derivations, self.mutations }) |window| {
            for (window.receipts[0..window.count]) |id| if (id.store != self.descriptor.store) return error.InvalidRecord;
        }
        return syrup.render.renderRecordExact(allocator, write, .{self});
    }

    pub fn decode(view: loam.View) !EndpointRecord {
        if (view.schema != profile.endpoint or view.schema_version != format_version or view.payload.len > max_encoded_bytes or view.edge_count < 1 or view.edge_count > max_edges) return error.InvalidRecord;
        const store = view.id.store;
        var iterator = view.edges();
        const descriptor = try fields.readEdge(&iterator, store);
        const b = view.payload;
        var c: usize = 0;
        try s.readByte(b, &c, '<');
        if (!std.mem.eql(u8, try s.readSymbol(b, &c), label)) return error.InvalidRecord;
        if (try s.readPositiveInt(b, &c) != format_version) return error.UnsupportedVersion;
        var result: EndpointRecord = .{ .descriptor = descriptor };
        if (try s.readBool(b, &c)) result.content = try readBinding(&iterator, store, b, &c);
        if (try s.readBool(b, &c)) {
            if (result.content != null) return error.InvalidRecord;
            result.administration = try readBinding(&iterator, store, b, &c);
        }
        if (try s.readBool(b, &c)) result.publication = try fields.readEdge(&iterator, store);
        result.derivations = try Window.read(b, &c, &iterator, store);
        result.mutations = try Window.read(b, &c, &iterator, store);
        if (iterator.next() != null) return error.InvalidRecord;
        try s.readByte(b, &c, '>');
        try s.expectEnd(b, c);
        return result;
    }

    fn write(sink: anytype, self: EndpointRecord) !void {
        try s.beginRecord(sink);
        try s.writeSymbol(sink, label);
        try s.writePositiveInt(sink, format_version);
        try s.writeBool(sink, self.content != null);
        if (self.content) |content| try fields.writeId(sink, content.resource);
        try s.writeBool(sink, self.administration != null);
        if (self.administration) |binding| try fields.writeId(sink, binding.resource);
        try s.writeBool(sink, self.publication != null);
        try self.derivations.write(sink);
        try self.mutations.write(sink);
        try s.endRecord(sink);
    }

    pub fn edges(self: EndpointRecord, buffer: *[max_edges]loam.Edge) []const loam.Edge {
        var n: usize = 1;
        buffer[0] = .{ .target = self.descriptor };
        if (self.content) |content| {
            buffer[n] = .{ .target = content.object };
            n += 1;
        }
        if (self.administration) |binding| {
            buffer[n] = .{ .target = binding.object };
            n += 1;
        }
        if (self.publication) |id| {
            buffer[n] = .{ .target = id };
            n += 1;
        }
        for ([_]Window{ self.derivations, self.mutations }) |window| {
            for (window.receipts[0..window.count]) |id| {
                buffer[n] = .{ .target = id };
                n += 1;
            }
        }
        return buffer[0..n];
    }

    /// A binding's edge precedes its resource identity in the payload.
    fn readBinding(iterator: *loam.EdgeIterator, store: loam.StoreId, bytes: []const u8, cursor: *usize) !Binding {
        const object = try fields.readEdge(iterator, store);
        const resource = try fields.readId(core.ResourceId, bytes, cursor);
        if (resource.generation == 0) return error.InvalidRecord;
        return .{ .resource = resource, .object = object };
    }
};
