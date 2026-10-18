//! A refused SQLite write changed nothing and the store stays usable, a second writer is refused without waiting, and a foreign file is left alone.
const std = @import("std");
const core = @import("loam_core");
const sqlite = @import("loam_sqlite");
const Sqlite = sqlite.Sqlite;
const f = @import("loam_test_support");
const fixture = @import("engine_fixture");

const capacity = 1024 * 1024;

fn create(path: [:0]const u8) !Sqlite {
    return Sqlite.open(path, .{ .capacity_bytes = capacity, .opening = .{ .id = f.id, .mode = .create } });
}

test "loam SQLite engine passes the storage engine suite at one mebibyte" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try create(tmp.path);
    defer db.close() catch unreachable;
    try @import("../core/engine_scenario.zig").exercise(f, &db, db.metadata, .{ .capacity_bytes = capacity });
}

test "loam SQLite engine refuses a put past its page count, ends the transaction, and takes a smaller write" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try create(tmp.path);
    defer db.close() catch unreachable;
    var warm = try db.beginWrite();
    defer warm.abort();
    try warm.put("a", "one");
    try std.testing.expectEqual(core.backend.Commit.committed, try warm.commit());
    const before = db.metadata;

    const big = try std.testing.allocator.alloc(u8, capacity + 4096);
    defer std.testing.allocator.free(big);
    @memset(big, 0x5a);
    var write = try db.beginWrite();
    defer write.abort();
    try std.testing.expectError(error.StorageCapacity, write.put("b", big));
    try std.testing.expectError(error.Closed, write.get("a"));
    try std.testing.expectError(error.Closed, write.commit());
    {
        var read = try db.beginRead();
        defer read.end();
        try std.testing.expect((try read.get("b")) == null);
        try std.testing.expectEqualStrings("one", (try read.get("a")).?);
        try std.testing.expectEqualDeep(before, try core.backend.metadata(&read));
    }
    var retry = try db.beginWrite();
    defer retry.abort();
    try retry.put("b", "two");
    try std.testing.expectEqual(core.backend.Commit.committed, try retry.commit());
}

test "loam SQLite engine refuses a second writer at once and resumes when the first ends" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try create(tmp.path);
    defer db.close() catch unreachable;
    var first = try db.beginWrite();
    defer first.abort();
    try std.testing.expectError(error.Busy, db.beginWrite());
    first.abort();
    var second = try db.beginWrite();
    defer second.abort();
    try second.put("k", "v");
    try std.testing.expectEqual(core.backend.Commit.committed, try second.commit());
}

/// A connection outside the engine, as a foreign tool holding the file.
const Foreign = struct {
    db: *anyopaque,

    extern "c" fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*anyopaque, flags: c_int, vfs: ?[*:0]const u8) c_int;
    extern "c" fn sqlite3_exec(db: *anyopaque, sql: [*:0]const u8, callback: ?*const anyopaque, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
    extern "c" fn sqlite3_close(db: *anyopaque) c_int;
    extern "c" fn sqlite3_initialize() c_int;
    extern "c" fn sqlite3_prepare_v2(db: *anyopaque, sql: [*:0]const u8, length: c_int, stmt: *?*anyopaque, tail: ?*?[*:0]const u8) c_int;
    extern "c" fn sqlite3_step(stmt: *anyopaque) c_int;
    extern "c" fn sqlite3_column_int64(stmt: *anyopaque, column: c_int) i64;
    extern "c" fn sqlite3_finalize(stmt: *anyopaque) c_int;

    /// The library is built without automatic initialization, so a foreign
    /// connection initializes it before opening, as the engine does.
    fn open(directory: []const u8) !Foreign {
        try std.testing.expectEqual(@as(c_int, 0), sqlite3_initialize());
        var path: [std.fs.max_path_bytes:0]u8 = undefined;
        const text = try std.fmt.bufPrint(&path, "{s}/{s}\x00", .{ directory, sqlite.file_name });
        var db: ?*anyopaque = null;
        try std.testing.expectEqual(@as(c_int, 0), sqlite3_open_v2(@ptrCast(text.ptr), &db, 0x6, null));
        return .{ .db = db.? };
    }

    fn exec(self: Foreign, sql: [*:0]const u8) !void {
        try std.testing.expectEqual(@as(c_int, 0), sqlite3_exec(self.db, sql, null, null, null));
    }

    /// The one integer `sql` returns on `db`, which may be the engine's own.
    fn readInt(db: *anyopaque, sql: [*:0]const u8) !i64 {
        var stmt: ?*anyopaque = null;
        try std.testing.expectEqual(@as(c_int, 0), sqlite3_prepare_v2(db, sql, -1, &stmt, null));
        defer _ = sqlite3_finalize(stmt.?); // best-effort: the step result is the report
        try std.testing.expectEqual(@as(c_int, 100), sqlite3_step(stmt.?));
        return sqlite3_column_int64(stmt.?, 0);
    }

    fn close(self: Foreign) void {
        _ = sqlite3_close(self.db);
    }
};

test "loam SQLite engine flushes fully from the writer and bounds every connection's page cache" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try create(tmp.path);
    defer db.close() catch unreachable;
    try std.testing.expectEqual(@as(i64, 1), try Foreign.readInt(@ptrCast(db.writer.db), "PRAGMA fullfsync"));
    const cache_kib = -@as(i64, Sqlite.page_cache_bytes / 1024);
    try std.testing.expectEqual(cache_kib, try Foreign.readInt(@ptrCast(db.writer.db), "PRAGMA cache_size"));
    for (db.readers[0..db.reader_count]) |reader| {
        try std.testing.expectEqual(cache_kib, try Foreign.readInt(@ptrCast(reader.db), "PRAGMA cache_size"));
    }
}

test "loam SQLite engine refuses a writer while a foreign connection holds the write lock, without waiting" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try create(tmp.path);
    defer db.close() catch unreachable;
    const foreign = try Foreign.open(tmp.path);
    defer foreign.close();
    try foreign.exec("BEGIN IMMEDIATE");
    const started = std.Io.Clock.now(.real, std.testing.io);
    try std.testing.expectError(error.Busy, db.beginWrite());
    const elapsed = started.durationTo(std.Io.Clock.now(.real, std.testing.io));
    try std.testing.expect(elapsed.nanoseconds < std.Io.Duration.fromSeconds(1).nanoseconds);
    try foreign.exec("ROLLBACK");
    var write = try db.beginWrite();
    defer write.abort();
    try write.put("k", "v");
    try std.testing.expectEqual(core.backend.Commit.committed, try write.commit());
}

test "loam SQLite engine leaves a foreign database untouched and creates nothing when opening a missing store" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    try std.testing.expectError(error.MissingStore, Sqlite.open(tmp.path, .{ .opening = .{ .id = f.id, .mode = .open } }));
    try std.testing.expectError(error.FileNotFound, tmp.dir.dir.access(std.testing.io, sqlite.file_name, .{}));

    const foreign = try Foreign.open(tmp.path);
    try foreign.exec("CREATE TABLE theirs(x INTEGER); INSERT INTO theirs VALUES(7)");
    foreign.close();
    try std.testing.expectError(error.ForeignDatabase, create(tmp.path));
    try std.testing.expectError(error.ForeignDatabase, Sqlite.open(tmp.path, .{ .opening = .{ .id = f.id, .mode = .open } }));
    const again = try Foreign.open(tmp.path);
    defer again.close();
    try again.exec("SELECT x FROM theirs");
    // Header byte 18 is the write version: 1 for a rollback journal and 2
    // for a write-ahead log. The refused opens left it as the owner chose.
    var header: [100]u8 = undefined;
    const file = try tmp.dir.dir.openFile(std.testing.io, sqlite.file_name, .{});
    defer file.close(std.testing.io);
    try std.testing.expectEqual(@as(usize, header.len), try file.readPositionalAll(std.testing.io, &header, 0));
    try std.testing.expectEqual(@as(u8, 1), header[18]);
}

test "loam SQLite engine refuses to open an empty file and leaves it empty" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    const file = try tmp.dir.dir.createFile(std.testing.io, sqlite.file_name, .{});
    file.close(std.testing.io);
    try std.testing.expectError(error.MissingStore, Sqlite.open(tmp.path, .{ .opening = .{ .id = f.id, .mode = .open } }));
    try std.testing.expectEqual(@as(u64, 0), (try tmp.dir.dir.statFile(std.testing.io, sqlite.file_name, .{})).size);
    var db = try create(tmp.path);
    try db.close();
}

test "loam SQLite engine refuses a capacity past SQLite's page limit" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    try std.testing.expectError(error.InvalidLimits, Sqlite.open(tmp.path, .{ .capacity_bytes = std.math.maxInt(usize), .opening = .{ .id = f.id, .mode = .create } }));
    var db = try create(tmp.path);
    defer db.close() catch unreachable;
    try std.testing.expectError(error.InvalidLimits, db.grow(std.math.maxInt(usize) / sqlite.page_bytes * sqlite.page_bytes));
}
