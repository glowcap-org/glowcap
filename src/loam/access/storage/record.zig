//! Record staging copies into the Store's existing bounded transaction buffer.
const loam = @import("loam_core");

pub fn put(store: *loam.Store, object: loam.ObjectId, schema: u64, payload: []const u8, edges: []const loam.Edge, expected: ?u64, rooted: bool) !void {
    try store.putCopying(.{ .id = object, .revision = 0, .schema = schema, .payload = payload, .edges = edges, .rooted = rooted }, expected);
}

pub fn putEncoded(store: *loam.Store, object: loam.ObjectId, schema: u64, value: anytype, edges: []const loam.Edge, expected: ?u64, rooted: bool) !void {
    const payload = try value.encodeAlloc(store.allocator);
    defer store.allocator.free(payload);
    try put(store, object, schema, payload, edges, expected, rooted);
}
