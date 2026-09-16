//! Native storage contract tests, independent of CapTP conformance.
const std = @import("std");
const core = @import("loam_core");
const Lmdb = @import("loam_lmdb").Lmdb;

test "loam LMDB creates and reopens an exclusively owned store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const terminated = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(terminated);
    const id: core.StoreId = @fromBackingInt(42);
    var db = try Lmdb.open(terminated, .{ .mode = .{ .create = id } });
    try std.testing.expectError(error.CustodyUnavailable, Lmdb.open(terminated, .{ .mode = .{ .open = id } }));
    const incarnation = db.metadata.incarnation;
    const lock_before = try tmp.dir.statFile(std.testing.io, "loam-owner.lock", .{});
    try db.close();
    const lock_after = try tmp.dir.statFile(std.testing.io, "loam-owner.lock", .{});
    try std.testing.expectEqual(lock_before.inode, lock_after.inode);
    db = try Lmdb.open(terminated, .{ .mode = .{ .open = id } });
    defer db.close() catch unreachable;
    try std.testing.expect(db.metadata.incarnation > incarnation);
}

const f = @import("loam_test_support");
const Temp = struct {
    dir: std.testing.TmpDir,
    path: [:0]u8,

    fn init() !Temp {
        var dir = std.testing.tmpDir(.{});
        errdefer dir.cleanup();
        const path = try std.Io.Dir.realPathFileAlloc(dir.dir, std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(path);
        return .{ .dir = dir, .path = try std.testing.allocator.dupeSentinel(u8, path, 0) };
    }

    fn deinit(self: *Temp) void {
        std.testing.allocator.free(self.path);
        self.dir.cleanup();
    }
};

test "loam LMDB restores cyclic records roots exact totals and stable identities" {
    var tmp = try Temp.init();
    defer tmp.deinit();
    var db = try Lmdb.open(tmp.path, .{ .mode = .{ .create = f.id } });
    var store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
    try store.begin();
    const a = try store.allocateId();
    const b = try store.allocateId();
    var record = f.record(a, "root");
    record.rooted = true;
    record.edges = &.{.{ .target = b }};
    try store.putCopying(record, null);
    record = f.record(b, "child");
    record.edges = &.{.{ .target = a }};
    try store.putCopying(record, null);
    try f.commit(&store, &db);
    const totals = store.metadata;
    try store.deinit();
    try db.close();
    db = try Lmdb.open(tmp.path, .{ .mode = .{ .open = f.id } });
    defer db.close() catch unreachable;
    store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
    defer store.deinit() catch unreachable;
    try std.testing.expectEqual(totals.objects, store.metadata.objects);
    try std.testing.expectEqual(totals.record_bytes, store.metadata.record_bytes);
    try std.testing.expectEqual(totals.roots, store.metadata.roots);
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    const lease = try f.load(&store, &db, a);
    const view = try store.view(lease);
    try std.testing.expect(view.id.eql(a));
    var edges = view.edges();
    try std.testing.expect(edges.next().?.target.eql(b));
    try store.release(lease);
    try store.begin();
    const fresh = try store.allocateId();
    try std.testing.expect(fresh.incarnation != a.incarnation);
    try store.abort();
}

test "loam LMDB abort and missing acknowledgement preserve atomic records and receipt" {
    var tmp = try Temp.init();
    defer tmp.deinit();
    var db = try Lmdb.open(tmp.path, .{ .mode = .{ .create = f.id } });
    defer db.close() catch unreachable;
    var store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
    defer store.deinit() catch unreachable;
    try store.begin();
    const a = try store.allocateId();
    const b = try store.allocateId();
    try store.putCopying(f.record(a, "one"), null);
    try store.putCopying(f.record(b, "two"), null);
    var ticket = try store.prepare();
    var pending = try db.beginCommit(try store.beginWrite(ticket));
    pending.abort();
    try store.completeWrite(ticket, .unknown);
    try store.resolve(ticket, try db.recover(try store.recoveryBatch()));
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
    try store.begin();
    const fresh_a = try store.allocateId();
    const fresh_b = try store.allocateId();
    try store.putCopying(f.record(fresh_a, "one"), null);
    try store.putCopying(f.record(fresh_b, "two"), null);
    ticket = try store.prepare();
    const outcome = db.commit(try store.beginWrite(ticket));
    try std.testing.expect(outcome == .committed);
    try store.completeWrite(ticket, .unknown);
    try std.testing.expectError(error.RecoveryRequired, store.acquire(fresh_a));
    try store.resolve(ticket, try db.recover(try store.recoveryBatch()));
    try std.testing.expectEqual(@as(u64, 2), store.metadata.objects);
    const lease = try f.load(&store, &db, fresh_b);
    defer store.release(lease) catch unreachable;
    try std.testing.expectEqualStrings("two", (try store.view(lease)).payload);
}

test "loam LMDB map exhaustion aborts the entire write and remains readable" {
    var tmp = try Temp.init();
    defer tmp.deinit();
    var db = try Lmdb.open(tmp.path, .{ .mode = .{ .create = f.id }, .map_bytes = 1024 * 1024 });
    defer db.close() catch unreachable;
    const schemas = [_]core.Schema{.{ .id = 7, .version = 1, .max_payload = 128 * 1024, .max_edges = 0 }};
    var limits = f.limits;
    limits.records.max_record_bytes = 129 * 1024;
    limits.resident_bytes = 129 * 1024;
    limits.staging_bytes = 2 * 1024 * 1024;
    var store = try core.Store.init(std.testing.allocator, db.metadata, &schemas, limits);
    defer store.deinit() catch unreachable;
    const payload = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x5a);
    try store.begin();
    for (0..8) |_| {
        const id = try store.allocateId();
        try store.putCopying(f.record(id, payload), null);
    }
    try std.testing.expectError(error.StorageCapacity, f.commit(&store, &db));
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.revision);
    try store.begin();
    const id = try store.allocateId();
    try store.putCopying(f.record(id, "after full"), null);
    try f.commit(&store, &db);
    const lease = try f.load(&store, &db, id);
    defer store.release(lease) catch unreachable;
    try std.testing.expectEqualStrings("after full", (try store.view(lease)).payload);
    const before = try db.inspect();
    try db.grow(4 * 1024 * 1024);
    try std.testing.expectEqualStrings("after full", (try store.currentView(lease)).payload);
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), (try db.inspect()).map_bytes);
    try std.testing.expectEqual(before.high_water_bytes, (try db.inspect()).high_water_bytes);
    try store.begin();
    for (0..8) |_| {
        const grown_id = try store.allocateId();
        try store.putCopying(f.record(grown_id, payload), null);
    }
    try f.commit(&store, &db);
    try std.testing.expectEqual(@as(u64, 9), store.metadata.objects);
    try std.testing.expect((try db.inspect()).high_water_bytes > before.map_bytes);
}

test "loam LMDB open distinguishes absence identity mismatch and existing creation" {
    var tmp = try Temp.init();
    defer tmp.deinit();
    try std.testing.expectError(error.MissingStore, Lmdb.open(tmp.path, .{ .mode = .{ .open = f.id } }));
    var db = try Lmdb.open(tmp.path, .{ .mode = .{ .create = f.id } });
    try db.close();
    try std.testing.expectError(error.AlreadyExists, Lmdb.open(tmp.path, .{ .mode = .{ .create = f.id } }));
    try std.testing.expectError(error.StoreMismatch, Lmdb.open(tmp.path, .{ .mode = .{ .open = @fromBackingInt(999) } }));
    db = try Lmdb.open(tmp.path, .{ .mode = .{ .open = f.id } });
    try db.close();
}

test "loam LMDB close retains an active transaction and stops new work" {
    var tmp = try Temp.init();
    defer tmp.deinit();
    var db = try Lmdb.open(tmp.path, .{ .mode = .{ .create = f.id } });
    var store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
    try store.begin();
    const id = try store.allocateId();
    try store.putCopying(f.record(id, "pending"), null);
    const ticket = try store.prepare();
    const batch = try store.beginWrite(ticket);
    var pending = try db.beginCommit(batch);
    try std.testing.expectError(error.Busy, db.inspect());
    try std.testing.expectError(error.Busy, db.grow(512 * 1024 * 1024));
    try std.testing.expectError(error.Busy, db.close());
    try std.testing.expectError(error.Closed, db.beginCommit(batch));
    pending.abort();
    try store.completeWrite(ticket, .{ .unchanged = error.Canceled });
    try store.deinit();
    try db.close();
}

test "loam LMDB map growth rejects shrink and failed remapping closes admission" {
    var tmp = try Temp.init();
    defer tmp.deinit();
    var db = try Lmdb.open(tmp.path, .{ .mode = .{ .create = f.id }, .map_bytes = 1024 * 1024 });
    const before = try db.inspect();
    try std.testing.expectError(error.InvalidLimits, db.grow(before.map_bytes));
    try std.testing.expectError(error.InvalidLimits, db.grow(before.map_bytes / 2));
    try std.testing.expectError(error.InvalidLimits, db.grow(before.map_bytes + 1));
    // No process can map almost its entire address range beside its own code.
    const impossible = std.math.maxInt(usize) - std.math.maxInt(usize) % before.page_bytes;
    try std.testing.expectError(error.ReopenRequired, db.grow(impossible));
    try std.testing.expectError(error.Closed, db.inspect());
    try std.testing.expectError(error.Closed, db.grow(before.map_bytes * 2));
    try db.close();
    db = try Lmdb.open(tmp.path, .{ .mode = .{ .open = f.id }, .map_bytes = before.map_bytes });
    defer db.close() catch unreachable;
    try std.testing.expectEqual(before.map_bytes, (try db.inspect()).map_bytes);
    try std.testing.expect(db.metadata.incarnation > 1);
}

test "loam LMDB tracing survives reopen and a lost sweep acknowledgement" {
    var tmp = try Temp.init();
    defer tmp.deinit();
    var db = try Lmdb.open(tmp.path, .{ .mode = .{ .create = f.id } });
    var store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
    try store.begin();
    const root = try store.allocateId();
    const child = try store.allocateId();
    const garbage = try store.allocateId();
    var r = f.record(root, "root");
    r.rooted = true;
    r.edges = &.{.{ .target = child }};
    try store.putCopying(r, null);
    r = f.record(child, "child");
    r.edges = &.{.{ .target = root }};
    try store.putCopying(r, null);
    r = f.record(garbage, "cycle");
    r.edges = &.{.{ .target = garbage }};
    try store.putCopying(r, null);
    try f.commit(&store, &db);
    while (store.metadata.collection.phase != .sweep) try f.collectionStep(&store, &db, 1);
    // Reopening must restart tracing, including a newly reconstructed live root.
    try store.deinit();
    try db.close();
    db = try Lmdb.open(tmp.path, .{ .mode = .{ .open = f.id } });
    defer db.close() catch unreachable;
    store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
    defer store.deinit() catch unreachable;
    try std.testing.expectEqual(.clearing, store.metadata.collection.phase);
    const held = try store.retain(garbage);
    try f.collect(&store, &db);
    try std.testing.expectEqual(@as(u64, 3), store.metadata.objects);
    try store.releaseRetention(held);
    const ticket = try store.prepareCollection(64);
    const batch = try store.beginWrite(ticket);
    var pending = try db.beginCommit(batch);
    try std.testing.expect(pending.finish() == .committed);
    try store.completeWrite(ticket, .unknown);
    try store.resolve(ticket, try db.recover(try store.recoveryBatch()));
    try std.testing.expectEqual(@as(u64, 2), store.metadata.objects);
    const lease = try f.load(&store, &db, root);
    defer store.release(lease) catch unreachable;
    try std.testing.expectEqualStrings("root", (try store.view(lease)).payload);
}

test "loam LMDB insertion barrier traces mapped edges after black record mutation" {
    var tmp = try Temp.init();
    defer tmp.deinit();
    var db = try Lmdb.open(tmp.path, .{ .mode = .{ .create = f.id } });
    defer db.close() catch unreachable;
    var store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
    defer store.deinit() catch unreachable;
    try store.begin();
    const root = try store.allocateId();
    var ids: [7]core.ObjectId = undefined;
    for (&ids) |*id| id.* = try store.allocateId();
    var r = f.record(root, "root");
    r.rooted = true;
    try store.putCopying(r, null);
    for (ids, 0..) |id, i| {
        r = f.record(id, "chain");
        if (i + 1 < ids.len) r.edges = &.{.{ .target = ids[i + 1] }};
        try store.putCopying(r, null);
    }
    try f.commit(&store, &db);
    while (store.metadata.collection.phase != .sweep) try f.collectionStep(&store, &db, 1);
    try f.collectionStep(&store, &db, 1);
    try store.begin();
    r = f.record(root, "changed");
    r.rooted = true;
    r.edges = &.{.{ .target = ids[0] }};
    try store.putCopying(r, 1);
    try f.commit(&store, &db);
    try f.collect(&store, &db);
    try std.testing.expectEqual(@as(u64, 8), store.metadata.objects);
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
}
