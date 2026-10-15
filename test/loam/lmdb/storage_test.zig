//! LMDB's physical storage behavior: the owner lock file, a full map, map growth, and refusals while a write is open.
const std = @import("std");
const core = @import("loam_core");
const Lmdb = @import("loam_lmdb").Lmdb;
const fixture = @import("engine_fixture");
const f = @import("loam_test_support");

test "loam LMDB keeps one owner lock file across close and reopen" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    const id: core.StoreId = @fromBackingInt(42);
    var db = try Lmdb.open(tmp.path, .{ .mode = .{ .create = id } });
    const lock_before = try tmp.dir.dir.statFile(std.testing.io, "loam-owner.lock", .{});
    try db.close();
    const lock_after = try tmp.dir.dir.statFile(std.testing.io, "loam-owner.lock", .{});
    try std.testing.expectEqual(lock_before.inode, lock_after.inode);
}

test "loam LMDB map exhaustion aborts the entire write and remains readable" {
    var tmp = try fixture.Temp.init();
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

test "loam LMDB close retains an active transaction and stops new work" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try Lmdb.open(tmp.path, .{ .mode = .{ .create = f.id } });
    var store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
    try store.begin();
    const id = try store.allocateId();
    try store.putCopying(f.record(id, "pending"), null);
    const ticket = try store.prepare();
    const batch = try store.beginWrite(ticket);
    var pending = try db.beginWrite();
    _ = try batch.apply(&pending);
    try std.testing.expectError(error.Busy, db.inspect());
    try std.testing.expectError(error.Busy, db.grow(512 * 1024 * 1024));
    try std.testing.expectError(error.Busy, db.beginCompaction());
    try std.testing.expectError(error.Busy, db.close());
    try std.testing.expectError(error.Closed, db.beginWrite());
    pending.abort();
    try store.completeWrite(ticket, .{ .unchanged = error.Canceled });
    try store.deinit();
    try db.close();
}

test "loam LMDB growth refuses invalid sizes and maps nothing for a large limit" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try Lmdb.open(tmp.path, .{ .mode = .{ .create = f.id }, .map_bytes = 1024 * 1024 });
    const before = try db.inspect();
    try std.testing.expectError(error.InvalidLimits, db.grow(before.map_bytes));
    try std.testing.expectError(error.InvalidLimits, db.grow(before.map_bytes / 2));
    try std.testing.expectError(error.InvalidLimits, db.grow(before.map_bytes + 1));
    // The limit must fit a signed file offset, even though nothing is mapped
    // at that size.
    if (@bitSizeOf(usize) >= @bitSizeOf(std.c.off_t)) {
        const impossible = std.math.maxInt(usize) - std.math.maxInt(usize) % before.page_bytes;
        try std.testing.expectError(error.InvalidLimits, db.grow(impossible));
    }
    try std.testing.expectEqual(before.map_bytes, (try db.inspect()).map_bytes);
    const large: usize = if (@bitSizeOf(usize) >= 64) 64 * 1024 * 1024 * 1024 else 1024 * 1024 * 1024;
    try db.grow(large);
    try std.testing.expectEqual(large, (try db.inspect()).map_bytes);
    try db.close();
    db = try Lmdb.open(tmp.path, .{ .mode = .{ .open = f.id }, .map_bytes = before.map_bytes });
    defer db.close() catch unreachable;
    try std.testing.expectEqual(before.map_bytes, (try db.inspect()).map_bytes);
    try std.testing.expect(db.metadata.incarnation > 1);
}
