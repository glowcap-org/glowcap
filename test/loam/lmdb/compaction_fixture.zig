//! A reclaimed LMDB store retains a cyclic graph and exact logical metadata.
const std = @import("std");
const core = @import("loam_core");
const Lmdb = @import("loam_lmdb").Lmdb;
pub const id: core.StoreId = @fromBackingInt(927);
pub const schemas = [_]core.Schema{.{ .id = 7, .version = 1, .max_payload = 32 * 1024, .max_edges = 2 }};
pub const limits: core.Store.Limits = .{ .records = .{ .max_record_bytes = 33 * 1024, .max_edges = 2 }, .cache_slots = 2, .max_leases = 2, .resident_bytes = 66 * 1024, .max_changes = 2, .staging_bytes = 70 * 1024 };
pub const root: core.ObjectId = .{ .store = id, .incarnation = 1, .sequence = 1 };
pub const child: core.ObjectId = .{ .store = id, .incarnation = 1, .sequence = 2 };

pub fn seed(allocator: std.mem.Allocator, db: *Lmdb) !core.Metadata {
    var store = try core.Store.init(allocator, db.metadata, &schemas, limits);
    defer store.deinit() catch unreachable;
    try store.begin();
    const first = try store.allocateId();
    const second = try store.allocateId();
    try store.putCopying(.{ .id = first, .revision = 0, .schema = 7, .rooted = true, .payload = "root", .edges = &.{.{ .target = second }} }, null);
    try store.putCopying(.{ .id = second, .revision = 0, .schema = 7, .payload = "child", .edges = &.{.{ .target = first }} }, null);
    try commit(&store, db, try store.prepare());
    var payload: [32 * 1024]u8 = @splat(0x53);
    for (0..64) |_| {
        try store.begin();
        try store.putCopying(.{ .id = try store.allocateId(), .revision = 0, .schema = 7, .payload = &payload }, null);
        try commit(&store, db, try store.prepare());
    }
    for (0..4096) |_| {
        try commit(&store, db, try store.prepareCollection(2));
        if (store.metadata.collection.phase == .idle) return store.metadata;
    }
    return error.CollectionDidNotFinish;
}

fn commit(store: *core.Store, db: *Lmdb, ticket: core.Ticket) !void {
    const outcome = db.commit(try store.beginWrite(ticket));
    try store.completeWrite(ticket, outcome);
    switch (outcome) {
        .committed => {},
        .unchanged => |err| return err,
        .unknown => return error.OutcomeUnknown,
    }
}

pub fn verify(allocator: std.mem.Allocator, db: *Lmdb) !void {
    var store = try core.Store.init(allocator, db.metadata, &schemas, limits);
    defer store.deinit() catch unreachable;
    if (store.metadata.objects != 2 or store.metadata.roots != 1 or store.metadata.collection.phase != .idle) return error.InvalidRecoveredTotals;
    for ([_]core.ObjectId{ root, child }) |object| {
        const lease = switch (try store.acquire(object)) {
            .ready => |lease| lease,
            .read => |read| value: {
                try store.completeRead(read.ticket, db.read(read));
                break :value (try store.acquire(object)).ready;
            },
        };
        defer store.release(lease) catch unreachable;
        const view = try store.view(lease);
        if (!std.mem.eql(u8, if (object.eql(root)) "root" else "child", view.payload)) return error.InvalidRecoveredContent;
        var edges = view.edges();
        if (view.edge_count != 1 or !edges.next().?.target.eql(if (object.eql(root)) child else root)) return error.InvalidRecoveredGraph;
    }
    try store.begin();
    const fresh = try store.allocateId();
    if (fresh.incarnation <= root.incarnation) return error.IdentityReused;
    try store.abort();
}
