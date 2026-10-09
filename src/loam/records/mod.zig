//! Bounded storage records. The Syrup envelope owns schema and reference fields;
//! its checksum detects accidental corruption, not a hostile storage operator.
const std = @import("std");
const syrup = @import("syrup");
const syntax = syrup.RecordSyntax;

pub const StoreId = enum(u128) { _ };
pub const ObjectId = struct {
    store: StoreId,
    incarnation: u64,
    sequence: u64,

    pub fn eql(a: ObjectId, b: ObjectId) bool {
        return std.meta.eql(a, b);
    }

    pub fn key(self: ObjectId) [33]u8 {
        var bytes: [33]u8 = undefined;
        bytes[0] = 'o';
        std.mem.writeInt(u128, bytes[1..17], @backingInt(self.store), .big);
        std.mem.writeInt(u64, bytes[17..25], self.incarnation, .big);
        std.mem.writeInt(u64, bytes[25..33], self.sequence, .big);
        return bytes;
    }

    pub fn fromKey(bytes: []const u8) Error!ObjectId {
        if (bytes.len != 33 or bytes[0] != 'o') return error.Corrupt;
        const id: ObjectId = .{
            .store = @fromBackingInt(std.mem.readInt(u128, bytes[1..17], .big)),
            .incarnation = std.mem.readInt(u64, bytes[17..25], .big),
            .sequence = std.mem.readInt(u64, bytes[25..33], .big),
        };
        if (id.incarnation == 0 or id.sequence == 0) return error.Corrupt;
        return id;
    }
};
pub const Edge = struct {
    target: ObjectId,
    strength: enum { strong, weak } = .strong,
    /// The hosting layer interprets recipe records. Tracing follows the same
    /// strong dependency in either case; the portable core never restores it.
    restoration: enum { object, recipe } = .object,

    /// All persisted identities and flags have one fixed encoded width.
    pub fn encodedSize() usize {
        const id: ObjectId = .{ .store = @fromBackingInt(0), .incarnation = 1, .sequence = 1 };
        return syrup.render.measureRecord(Record.writeEdge, .{Edge{ .target = id }}) catch unreachable;
    }
};
pub const Schema = struct {
    id: u64,
    version: u32,
    max_payload: usize,
    max_edges: usize,
    /// Optional immutable 128-bit discovery name inside the payload. The
    /// storage transaction indexes it by schema; a name never changes targets.
    name_offset: ?usize = null,

    /// Maximum physical bytes for this schema, including envelope and checksum.
    /// Only scalar lengths are measured: no allocation, payload or edge walk.
    pub fn encodedSizeBound(self: Schema) error{Overflow}!usize {
        const id: ObjectId = .{ .store = @fromBackingInt(0), .incarnation = 1, .sequence = 1 };
        const header = syrup.render.measureRecord(Record.writeHeader, .{.{
            .id = id,
            .revision = std.math.maxInt(u64),
            .schema = self.id,
            .schema_version = self.version,
            .rooted = false,
        }}) catch unreachable;
        const edge = Edge.encodedSize();
        const tail = syrup.render.measureRecord(Record.writeEdges, .{@as([]const Edge, &.{})}) catch unreachable;
        var bytes = try std.math.add(usize, header, try syntax.byteStringSize(self.max_payload));
        bytes = try std.math.add(usize, bytes, try std.math.mul(usize, edge, self.max_edges));
        return std.math.add(usize, bytes, tail + 4);
    }
};
pub const Limits = struct { max_record_bytes: usize = 64 * 1024, max_edges: usize = 256 };
pub const Error = error{ Corrupt, UnsupportedSchema, RecordTooLarge, ForeignObject, InvalidRecord };

pub const Record = struct {
    id: ObjectId,
    revision: u64,
    schema: u64,
    schema_version: u32 = 1,
    rooted: bool = false,
    payload: []const u8,
    edges: []const Edge = &.{},

    /// Copies payload and edges into one owned encoded record. The caller frees
    /// the result. Encoding uses bounded two-pass Syrup rendering and a checksum.
    pub fn encodeAlloc(self: Record, allocator: std.mem.Allocator, limits: Limits, schemas: []const Schema) ![]u8 {
        const schema = try findSchema(schemas, self.schema, self.schema_version);
        if (self.revision == 0 or self.id.incarnation == 0 or self.id.sequence == 0) return error.InvalidRecord;
        if (self.payload.len > schema.max_payload or self.payload.len > limits.max_record_bytes or
            self.edges.len > schema.max_edges or self.edges.len > limits.max_edges) return error.RecordTooLarge;
        for (self.edges) |edge| {
            if (edge.target.store != self.id.store) return error.ForeignObject;
            if (edge.target.incarnation == 0 or edge.target.sequence == 0) return error.InvalidRecord;
        }
        const length = try syrup.render.measureRecord(write, .{self});
        if (length > limits.max_record_bytes -| 4) return error.RecordTooLarge;
        const result = try allocator.alloc(u8, length + 4);
        errdefer allocator.free(result);
        try syrup.render.renderRecordInto(result[0..length], write, .{self});
        std.mem.writeInt(u32, result[length..][0..4], std.hash.Crc32.hash(result[0..length]), .big);
        return result;
    }

    fn write(sink: anytype, self: Record) !void {
        try writeHeader(sink, self);
        try syntax.writeBytes(sink, self.payload);
        try writeEdges(sink, self.edges);
    }

    fn writeHeader(sink: anytype, self: anytype) !void {
        try syntax.beginRecord(sink);
        try syntax.writeSymbol(sink, "loam:record");
        try syntax.writePositiveInt(sink, 2);
        try syntax.writeBytes(sink, &self.id.key());
        try syntax.writePositiveInt(sink, self.revision);
        try syntax.writePositiveInt(sink, self.schema);
        try syntax.writePositiveInt(sink, self.schema_version);
        try syntax.writeBool(sink, self.rooted);
    }

    fn writeEdge(sink: anytype, edge: Edge) !void {
        try syntax.writeBytes(sink, &edge.target.key());
        try syntax.writeBool(sink, edge.strength == .strong);
        try syntax.writeBool(sink, edge.restoration == .recipe);
    }

    fn writeEdges(sink: anytype, edges: []const Edge) !void {
        try syntax.beginList(sink);
        for (edges) |edge| try writeEdge(sink, edge);
        try syntax.endList(sink);
        try syntax.endRecord(sink);
    }
};

/// All slices borrow the encoded record. Decode validates every edge before
/// returning; iteration performs no allocation and does not load its targets.
pub const View = struct {
    id: ObjectId,
    revision: u64,
    schema: u64,
    schema_version: u32,
    rooted: bool,
    payload: []const u8,
    edge_bytes: []const u8,
    edge_count: usize,

    pub fn decode(bytes: []const u8, limits: Limits, schemas: []const Schema) Error!View {
        if (bytes.len > limits.max_record_bytes) return error.RecordTooLarge;
        if (bytes.len < 4) return error.Corrupt;
        const body = bytes[0 .. bytes.len - 4];
        if (std.hash.Crc32.hash(body) != std.mem.readInt(u32, bytes[bytes.len - 4 ..][0..4], .big)) return error.Corrupt;
        return parse(body, limits, schemas) catch |err| switch (err) {
            error.UnsupportedSchema => error.UnsupportedSchema,
            error.RecordTooLarge => error.RecordTooLarge,
            else => error.Corrupt,
        };
    }

    pub fn edges(self: View) EdgeIterator {
        return .{ .bytes = self.edge_bytes };
    }

    /// Validated records have fixed-width edges. Selecting an occurrence
    /// decodes just that edge, without allocating or walking its predecessors.
    pub fn edgeAt(self: View, index: usize) !Edge {
        if (index >= self.edge_count) return error.NoSuchEdge;
        var iterator: EdgeIterator = .{ .bytes = self.edge_bytes, .cursor = index * Edge.encodedSize() };
        return iterator.next().?;
    }

    fn parse(bytes: []const u8, limits: Limits, schemas: []const Schema) !View {
        var cursor: usize = 0;
        try syntax.readByte(bytes, &cursor, '<');
        if (!std.mem.eql(u8, try syntax.readSymbol(bytes, &cursor), "loam:record")) return error.Corrupt;
        if (try syntax.readPositiveInt(bytes, &cursor) != 2) return error.Corrupt;
        const id = try ObjectId.fromKey(try syntax.readBytesLimited(bytes, &cursor, bytes.len));
        const revision = try syntax.readPositiveInt(bytes, &cursor);
        if (revision == 0) return error.Corrupt;
        const schema_id = try syntax.readPositiveInt(bytes, &cursor);
        const version = std.math.cast(u32, try syntax.readPositiveInt(bytes, &cursor)) orelse return error.Corrupt;
        const schema = try findSchema(schemas, schema_id, version);
        const rooted = try syntax.readBool(bytes, &cursor);
        const payload = try syntax.readBytesLimited(bytes, &cursor, bytes.len);
        if (payload.len > schema.max_payload) return error.RecordTooLarge;
        try syntax.readByte(bytes, &cursor, '[');
        const start = cursor;
        var count: usize = 0;
        const edge_width = Edge.encodedSize();
        while (cursor < bytes.len and bytes[cursor] != ']') {
            if (count >= @min(schema.max_edges, limits.max_edges)) return error.RecordTooLarge;
            const edge_start = cursor;
            const target = try ObjectId.fromKey(try syntax.readBytesLimited(bytes, &cursor, bytes.len));
            if (target.store != id.store) return error.Corrupt;
            _ = try syntax.readBool(bytes, &cursor);
            _ = try syntax.readBool(bytes, &cursor);
            if (cursor - edge_start != edge_width) return error.Corrupt;
            count += 1;
        }
        const end = cursor;
        try syntax.readByte(bytes, &cursor, ']');
        try syntax.readByte(bytes, &cursor, '>');
        try syntax.expectEnd(bytes, cursor);
        return .{ .id = id, .revision = revision, .schema = schema_id, .schema_version = version, .rooted = rooted, .payload = payload, .edge_bytes = bytes[start..end], .edge_count = count };
    }
};

pub const EdgeIterator = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn next(self: *EdgeIterator) ?Edge {
        if (self.cursor == self.bytes.len) return null;
        const key = syntax.readBytesLimited(self.bytes, &self.cursor, self.bytes.len) catch unreachable;
        const strong = syntax.readBool(self.bytes, &self.cursor) catch unreachable;
        const recipe = syntax.readBool(self.bytes, &self.cursor) catch unreachable;
        return .{ .target = ObjectId.fromKey(key) catch unreachable, .strength = if (strong) .strong else .weak, .restoration = if (recipe) .recipe else .object };
    }
};

fn findSchema(schemas: []const Schema, id: u64, version: u32) Error!Schema {
    for (schemas) |schema| if (schema.id == id and schema.version == version) return schema;
    return error.UnsupportedSchema;
}
