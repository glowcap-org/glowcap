//! SQLite capacity and maintenance: a write past the page count is refused and fits after grow, compact returns free pages to the file system, the log returns to its named size, and maintenance waits for no transaction.
const std = @import("std");
const core = @import("loam_core");
const sqlite = @import("loam_sqlite");
const Sqlite = sqlite.Sqlite;
const f = @import("loam_test_support");
const fixture = @import("engine_fixture");

const mebibyte = 1024 * 1024;

fn create(path: [:0]const u8, capacity: usize) !Sqlite {
    return Sqlite.open(path, .{ .capacity_bytes = capacity, .mode = .{ .create = f.id } });
}

fn putOne(db: *Sqlite, key: []const u8, value: []const u8) !void {
    var write = try db.beginWrite();
    defer write.abort();
    try write.put(key, value);
    try std.testing.expectEqual(core.backend.Commit.committed, try write.commit());
}

test "loam SQLite engine refuses a write past its capacity and accepts it after grow" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try create(tmp.path, mebibyte);
    defer db.close() catch unreachable;
    const big = try std.testing.allocator.alloc(u8, 2 * mebibyte);
    defer std.testing.allocator.free(big);
    @memset(big, 0x3c);

    var refused = try db.beginWrite();
    defer refused.abort();
    try std.testing.expectError(error.StorageCapacity, refused.put("big", big));
    try std.testing.expectEqual(mebibyte, (try db.inspect()).capacity_bytes);

    try std.testing.expectError(error.InvalidLimits, db.grow(mebibyte));
    try std.testing.expectError(error.InvalidLimits, db.grow(4 * mebibyte + 1));
    try db.grow(4 * mebibyte);
    try putOne(&db, "big", big);
    const grown = try db.inspect();
    try std.testing.expectEqual(4 * mebibyte, grown.capacity_bytes);
    try std.testing.expect(grown.file_bytes >= 2 * mebibyte);
    try std.testing.expectEqual(sqlite.page_bytes, grown.page_bytes);
}

test "loam SQLite engine compacts in place, shrinking the file and keeping every row" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try create(tmp.path, 16 * mebibyte);
    defer db.close() catch unreachable;
    try putOne(&db, "keep", "kept");
    const big = try std.testing.allocator.alloc(u8, 4 * mebibyte);
    defer std.testing.allocator.free(big);
    @memset(big, 0x7e);
    try putOne(&db, "churn", big);
    var drop = try db.beginWrite();
    defer drop.abort();
    try drop.remove("churn");
    try std.testing.expectEqual(core.backend.Commit.committed, try drop.commit());
    const before = try db.inspect();
    try std.testing.expect(before.free_bytes >= 3 * mebibyte);

    try db.compact();
    const after = try db.inspect();
    try std.testing.expectEqual(@as(usize, 0), after.free_bytes);
    try std.testing.expect(after.file_bytes < mebibyte);
    // The checkpoint truncated the log into the file, so the file system
    // sees the smaller size before close.
    const on_disk = try tmp.dir.dir.statFile(std.testing.io, sqlite.file_name, .{});
    try std.testing.expect(on_disk.size < mebibyte);

    var read = try db.beginRead();
    defer read.end();
    try std.testing.expectEqualStrings("kept", (try read.get("keep")).?);
    try std.testing.expect((try read.get("churn")) == null);
    try std.testing.expectEqualDeep(db.metadata, try core.backend.metadata(&read));
}

test "loam SQLite engine truncates a log a large write grew back to its named size" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try create(tmp.path, 16 * mebibyte);
    defer db.close() catch unreachable;
    const big = try std.testing.allocator.alloc(u8, sqlite.log_bytes + mebibyte);
    defer std.testing.allocator.free(big);
    @memset(big, 0x2b);
    // The large commit checkpoints the log, which keeps its length until
    // the next commit restarts it from the beginning.
    try putOne(&db, "big", big);
    const log_name = sqlite.file_name ++ "-wal";
    const grown = try tmp.dir.dir.statFile(std.testing.io, log_name, .{});
    try std.testing.expect(grown.size > sqlite.log_bytes);
    try putOne(&db, "small", "s");
    const restarted = try tmp.dir.dir.statFile(std.testing.io, log_name, .{});
    try std.testing.expect(restarted.size <= sqlite.log_bytes);
}

test "loam SQLite engine refuses maintenance while a transaction is open and admits it after" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try create(tmp.path, mebibyte);
    defer db.close() catch unreachable;
    var read = try db.beginRead();
    try std.testing.expectError(error.Busy, db.inspect());
    try std.testing.expectError(error.Busy, db.grow(2 * mebibyte));
    try std.testing.expectError(error.Busy, db.compact());
    read.end();
    var write = try db.beginWrite();
    try std.testing.expectError(error.Busy, db.compact());
    write.abort();
    try db.compact();
    try db.grow(2 * mebibyte);
}
