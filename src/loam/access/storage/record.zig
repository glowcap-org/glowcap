//! Record staging copies into the Store's existing bounded transaction buffer.
const loam = @import("loam_core");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const Row = @import("read.zig").Read.Row;

pub fn put(store: *loam.Store, object: loam.ObjectId, schema: u64, payload: []const u8, edges: []const loam.Edge, expected: ?u64, rooted: bool) !void {
    try store.putCopying(.{ .id = object, .revision = 0, .schema = schema, .payload = payload, .edges = edges, .rooted = rooted }, expected);
}

pub fn putEncoded(store: *loam.Store, object: loam.ObjectId, schema: u64, value: anytype, edges: []const loam.Edge, expected: ?u64, rooted: bool) !void {
    const payload = try value.encodeAlloc(store.allocator);
    defer store.allocator.free(payload);
    try put(store, object, schema, payload, edges, expected, rooted);
}

pub fn putResource(store: *loam.Store, object: loam.ObjectId, value: records.ResourceRecord, parent: ?loam.ObjectId, expected: ?u64) !void {
    var edges: [2]loam.Edge = undefined;
    try putEncoded(store, object, records.profile.resource, value, try value.edges(parent, &edges), expected, false);
}

/// Child-index replacement keeps the canonical parent's existing strong edge.
pub fn putChildren(store: *loam.Store, row: Row, children: ?loam.ObjectId, revision: core.Revision) !void {
    var value = try records.ResourceRecord.decode(row.view);
    value.children = children;
    value.revision = revision;
    var edges_it = row.view.edges();
    const parent = if (value.resource.parent != null) edges_it.next().?.target else null;
    try putResource(store, row.view.id, value, parent, row.expected);
}
