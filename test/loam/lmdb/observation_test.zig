//! Native scoped observation keeps the volatile contract across cold reopen.
const std = @import("std");
const h = @import("../access/hosting_fixture.zig");
const cases = @import("../access/observation_cases.zig");
const Lmdb = @import("loam_lmdb").Lmdb;

test "loam LMDB access observation privacy quota and live CapTP delivery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", h.a);
    defer h.a.free(path);
    const terminated = try h.a.dupeSentinel(u8, path, 0);
    defer h.a.free(terminated);
    var db = try Lmdb.open(terminated, .{ .mode = .{ .create = h.f.store_id } });
    defer db.close() catch unreachable;
    var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    try cases.scoped(&store, &db);
    try cases.quota(&store, &db);
    try cases.submitted(&store, &db);
    try cases.controlInventory(&store, &db);
    try cases.composed(&store, &db);
    try @import("../access/observation_hosted_cases.zig").live(&store, &db);
}

test "loam LMDB access observation restores a context bound cursor after reopening" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", h.a);
    defer h.a.free(path);
    const terminated = try h.a.dupeSentinel(u8, path, 0);
    defer h.a.free(terminated);
    var context: h.loam.core.ObjectId = undefined;
    var cursor: h.c.storage.Observation.Cursor = undefined;
    var data: h.Data = undefined;
    {
        var db = try Lmdb.open(terminated, .{ .mode = .{ .create = h.f.store_id } });
        defer db.close() catch unreachable;
        var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        data = try h.seed(&store, &db);
        var caps = try h.c.storage.Capabilities.init(h.a, &store, .{});
        defer caps.deinit() catch unreachable;
        const lease = try h.c.load(&store, &db, data.use);
        const endpoint = try h.loam.access.records.EndpointRecord.decode(try store.currentView(lease));
        try store.release(lease);
        context = try cases.register(&caps, &db, endpoint.descriptor, data.resource, @splat(11));
        cursor = (try cases.poll(&caps, &db, context, null)).cursor;
    }
    {
        var db = try Lmdb.open(terminated, .{ .mode = .{ .open = h.f.store_id } });
        defer db.close() catch unreachable;
        var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        var caps = try h.c.storage.Capabilities.init(h.a, &store, .{});
        defer caps.deinit() catch unreachable;
        const unchanged = try cases.poll(&caps, &db, context, cursor);
        try std.testing.expect(!unchanged.changed);
        try std.testing.expectEqualDeep(cursor, unchanged.cursor);
        _ = try h.f.change(&store, &db, data.owner, .{ .pause = data.grant });
        const paused = try cases.poll(&caps, &db, context, cursor);
        try std.testing.expect(paused.changed and paused.snapshot.use.access == .paused);
        try std.testing.expect(try cases.cancel(&store, &db, context, false));
    }
    {
        var db = try Lmdb.open(terminated, .{ .mode = .{ .open = h.f.store_id } });
        defer db.close() catch unreachable;
        var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        var caps = try h.c.storage.Capabilities.init(h.a, &store, .{});
        defer caps.deinit() catch unreachable;
        try std.testing.expectError(error.ObservationClosed, cases.poll(&caps, &db, context, cursor));
    }
}
