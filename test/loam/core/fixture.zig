//! Shared inputs for Loam record and transaction tests.
const std = @import("std");
const loam = @import("glowcap").loam;
pub const core = loam.core;
pub const schemas = [_]core.Schema{.{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 }};
pub const limits: core.Store.Limits = .{ .records = .{ .max_record_bytes = 1024, .max_edges = 8 }, .cache_slots = 2, .max_leases = 2, .resident_bytes = 2048, .max_changes = 8, .staging_bytes = 8192 };
pub const id: core.StoreId = @fromBackingInt(44);
pub const Fixture = struct {
    backend: loam.Volatile,
    store: core.Store,

    pub fn init(allocator: std.mem.Allocator) !Fixture {
        var backend = try loam.Volatile.init(allocator, id, 1024 * 1024);
        errdefer backend.deinit();
        const meta = try backend.open();
        const store = try core.Store.init(allocator, meta, &schemas, limits);
        return .{ .backend = backend, .store = store };
    }

    pub fn deinit(self: *Fixture) void {
        self.store.deinit() catch unreachable;
        self.backend.close() catch unreachable;
        self.backend.deinit();
    }
};
pub fn record(object: core.ObjectId, payload: []const u8) core.Record {
    return .{ .id = object, .revision = 0, .schema = 7, .payload = payload };
}
pub fn commit(store: *core.Store, backend: anytype) !void {
    return finish(store, backend, try store.prepare());
}
pub fn collectionStep(store: *core.Store, backend: anytype, work: usize) !void {
    return finish(store, backend, try store.prepareCollection(work));
}
pub fn collect(store: *core.Store, backend: anytype) !void {
    for (0..4096) |_| {
        try collectionStep(store, backend, 2);
        if (store.metadata.collection.phase == .idle) return;
    }
    return error.CollectionDidNotFinish;
}
fn finish(store: *core.Store, backend: anytype, ticket: core.Ticket) !void {
    const outcome = backend.commit(try store.beginWrite(ticket));
    try store.completeWrite(ticket, outcome);
    switch (outcome) {
        .committed => {},
        .unchanged => |err| return err,
        .unknown => return error.OutcomeUnknown,
    }
}
pub fn load(store: *core.Store, backend: anytype, object: core.ObjectId) !core.Lease {
    return switch (try store.acquire(object)) {
        .ready => |lease| lease,
        .read => |read| blk: {
            try store.completeRead(read.ticket, backend.read(read));
            break :blk (try store.acquire(object)).ready;
        },
    };
}
