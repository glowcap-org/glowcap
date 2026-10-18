//! Record staging copies into the Store's existing bounded transaction buffer.
const loam = @import("loam_core");
const core = @import("loam_access_core");
const records = @import("loam_access_records");
const read = @import("read.zig");
const Row = read.Read.Row;

/// Whether a staged record is a root of its owner's reachable set, or lives
/// only while some root reaches it.
pub const Rooting = enum {
    rooted,
    reachable,

    /// The rooting a stored row already holds, for re-putting it.
    pub fn ofStored(rooted: bool) Rooting {
        return if (rooted) .rooted else .reachable;
    }
};

pub fn put(store: *loam.Store, object: loam.ObjectId, schema: u64, payload: []const u8, edges: []const loam.Edge, expected: ?u64, rooting: Rooting) !void {
    const version = for (records.profile.schemas) |entry| {
        if (entry.id == schema) break entry.version;
    } else return error.UnsupportedSchema;
    try store.putCopying(.{ .id = object, .revision = 0, .schema = schema, .schema_version = version, .payload = payload, .edges = edges, .rooted = rooting == .rooted }, expected);
}

pub fn putEncoded(store: *loam.Store, object: loam.ObjectId, schema: u64, value: anytype, edges: []const loam.Edge, expected: ?u64, rooting: Rooting) !void {
    const payload = try value.encodeAlloc(store.allocator);
    defer store.allocator.free(payload);
    try put(store, object, schema, payload, edges, expected, rooting);
}

pub fn putResource(store: *loam.Store, object: loam.ObjectId, value: records.ResourceRecord, parent: ?loam.ObjectId, expected: ?u64) !void {
    var edges: [records.ResourceRecord.max_edges]loam.Edge = undefined;
    try putEncoded(store, object, records.profile.resource, value, try value.edges(parent, &edges), expected, .reachable);
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

/// The owner header, expected at this transaction's own proposal or at the
/// committed revision the view read. `header` is the view's own or becomes
/// it once put: the record is wide, so it moves by pointer.
pub fn putOwner(view: *read.Read, header: *const records.OwnerRecord) !void {
    const expected = if (try view.store.proposed(view.owner_object)) |proposal| proposal.expected else view.header_revision;
    var edges: [records.OwnerRecord.max_edges]loam.Edge = undefined;
    try putEncoded(view.store, view.owner_object, records.profile.owner, header.*, header.edges(&edges), expected, .rooted);
    if (header != &view.header) view.header = header.*;
    view.transaction = view.store.ticket;
}

/// A row's edges in `buffer`, for re-putting the row with some of them
/// changed. A row with more edges than the buffer is not this record kind.
pub fn copyEdges(view: loam.RecordView, buffer: []loam.Edge) error{InvalidRecord}!usize {
    if (view.edge_count > buffer.len) return error.InvalidRecord;
    var iterator = view.edges();
    var count: usize = 0;
    while (iterator.next()) |edge| : (count += 1) buffer[count] = edge;
    return count;
}
