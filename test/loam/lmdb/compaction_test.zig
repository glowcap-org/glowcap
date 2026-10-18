//! Copy, installation, custody and cancellation through the maintenance API.
const std = @import("std");
const Lmdb = @import("loam_lmdb").Lmdb;
const f = @import("compaction_fixture.zig");
const Temp = @import("engine_fixture").Temp;
extern "c" fn dup(c_int) c_int;
extern "c" fn close(c_int) c_int;

test "loam LMDB compaction preserves the complete store and shrinks reclaimed pages" {
    var tmp = try Temp.init();
    defer tmp.deinit();
    var db = try Lmdb.open(tmp.path, .{ .opening = .{ .id = f.id, .mode = .create }, .max_readers = 1 });
    const metadata = try f.seed(std.testing.allocator, &db);
    const before = try tmp.dir.dir.statFile(std.testing.io, "data.mdb", .{});
    const lock = try tmp.dir.dir.statFile(std.testing.io, "loam-owner.lock", .{});
    var replacement = try db.beginCompaction();
    try std.testing.expectError(error.Busy, db.beginCompaction());
    try std.testing.expectError(error.Busy, db.inspect());
    try std.testing.expectError(error.WrongPhase, replacement.install());
    try std.testing.expectError(error.CustodyUnavailable, Lmdb.open(tmp.path, .{ .opening = .{ .id = f.id, .mode = .open } }));
    try replacement.prepare();
    try std.testing.expectError(error.WrongPhase, replacement.prepare());
    try std.testing.expectEqual(before.inode, (try tmp.dir.dir.statFile(std.testing.io, "data.mdb", .{})).inode);
    try replacement.install();
    try std.testing.expectError(error.Closed, db.inspect());
    try std.testing.expectError(error.Busy, db.close());
    try std.testing.expectError(error.CustodyUnavailable, Lmdb.open(tmp.path, .{ .opening = .{ .id = f.id, .mode = .open } }));
    // Refuse the LMDB directory sync after rename, then retry with a live
    // descriptor. This exercises the unknown-outcome contract without a
    // production test hook or re-running the copy/installation effects.
    const retry_directory = dup(replacement.files.directory);
    try std.testing.expect(retry_directory >= 0);
    try std.testing.expectEqual(@as(c_int, 0), close(replacement.files.directory));
    replacement.files.directory = -1;
    try std.testing.expectError(error.InstallOutcomeUnknown, replacement.finish());
    try std.testing.expectError(error.Closed, db.inspect());
    replacement.files.directory = retry_directory;
    try replacement.finish();
    try std.testing.expectError(error.WrongPhase, replacement.finish());
    replacement.deinit();
    try std.testing.expectError(error.CustodyUnavailable, Lmdb.open(tmp.path, .{ .opening = .{ .id = f.id, .mode = .open } }));
    try db.close();
    const after = try tmp.dir.dir.statFile(std.testing.io, "data.mdb", .{});
    try std.testing.expect(after.inode != before.inode);
    try std.testing.expect(after.size < before.size);
    try std.testing.expectEqual(lock.inode, (try tmp.dir.dir.statFile(std.testing.io, "loam-owner.lock", .{})).inode);
    db = try Lmdb.open(tmp.path, .{ .opening = .{ .id = f.id, .mode = .open }, .max_readers = 1 });
    defer db.close() catch unreachable;
    // Normal reopening clears the submission receipt and starts a new identity
    // allocation sequence; every other durable metadata fact remains exact.
    const expected = try metadata.claim();
    try std.testing.expectEqualDeep(expected, db.metadata);
    try f.verify(std.testing.allocator, &db);
}

test "loam LMDB canceled copies and failed installation retain the original authority" {
    var tmp = try Temp.init();
    defer tmp.deinit();
    var db = try Lmdb.open(tmp.path, .{ .opening = .{ .id = f.id, .mode = .create } });
    _ = try f.seed(std.testing.allocator, &db);
    const before = try tmp.dir.dir.statFile(std.testing.io, "data.mdb", .{});
    var replacement = try db.beginCompaction();
    try replacement.prepare();
    replacement.deinit();
    _ = try db.inspect();
    // Removing the private copy forces a real rename refusal after source
    // closure, with no injected production failure mechanism.
    replacement = try db.beginCompaction();
    try replacement.prepare();
    try tmp.dir.dir.deleteFile(std.testing.io, "loam-compact.mdb");
    try std.testing.expectError(error.StorageFailure, replacement.install());
    try std.testing.expectError(error.Closed, db.inspect());
    replacement.deinit();
    try db.close();
    try std.testing.expectEqual(before.inode, (try tmp.dir.dir.statFile(std.testing.io, "data.mdb", .{})).inode);
    db = try Lmdb.open(tmp.path, .{ .opening = .{ .id = f.id, .mode = .open } });
    defer db.close() catch unreachable;
    try f.verify(std.testing.allocator, &db);
}
