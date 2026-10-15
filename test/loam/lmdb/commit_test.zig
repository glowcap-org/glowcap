//! LMDB commit outcomes preserve refusal, uncertainty, and safe reopening.
const std = @import("std");
const core = @import("loam_core");
const Lmdb = @import("loam_lmdb").Lmdb;
const f = @import("loam_test_support");

/// LMDB clamps a map smaller than the used space to the used space, so a size
/// of one leaves no fresh page.
extern "c" fn mdb_env_set_mapsize(env: *anyopaque, size: usize) c_int;
extern "c" fn loam_test_commit_failure(code: c_int) void;

test "LMDB uncertain completion fences the adapter and reopen observes the committed data" {
    for ([_]std.posix.E{ .IO, .NOSPC, .FBIG, .NOMEM, .INVAL }) |code| {
        var dir = std.testing.tmpDir(.{});
        defer dir.cleanup();
        const path = try std.Io.Dir.realPathFileAlloc(dir.dir, std.testing.io, ".", std.testing.allocator);
        defer std.testing.allocator.free(path);
        const terminated = try std.testing.allocator.dupeSentinel(u8, path, 0);
        defer std.testing.allocator.free(terminated);
        var db = try Lmdb.open(terminated, .{ .mode = .{ .create = f.id } });
        var opened = true;
        defer if (opened) db.close() catch unreachable;
        var snapshot = try db.beginRead();
        var reading = true;
        defer if (reading) snapshot.end();
        var write = try db.beginWrite();
        defer write.abort();
        try write.put("uncertain", "persisted");
        loam_test_commit_failure(@intCast(@backingInt(code)));
        try std.testing.expectEqual(core.backend.Commit.unknown, try write.commit());
        write.abort();
        try std.testing.expectEqual(core.backend.Commit.unknown, try write.commit());
        if (db.beginRead()) |value| {
            var unexpected = value;
            unexpected.end();
            return error.TestExpectedError;
        } else |err| try std.testing.expectEqual(error.ReopenRequired, err);
        try std.testing.expectError(error.ReopenRequired, db.beginWrite());
        try std.testing.expectError(error.ReopenRequired, db.inspect());
        try std.testing.expectError(error.ReopenRequired, db.grow(512 * 1024 * 1024));
        try std.testing.expectError(error.ReopenRequired, db.beginCompaction());
        try std.testing.expect((try snapshot.get("uncertain")) == null);
        try std.testing.expectError(error.Busy, db.close());
        snapshot.end();
        reading = false;
        try db.close();
        opened = false;
        db = try Lmdb.open(terminated, .{ .mode = .{ .open = f.id } });
        opened = true;
        var read = try db.beginRead();
        defer read.end();
        try std.testing.expectEqualStrings("persisted", (try read.get("uncertain")).?);
    }
}

test "a commit that runs out of map is refused and the engine accepts a smaller write" {
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(dir.dir, std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const terminated = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(terminated);
    var db = try Lmdb.open(terminated, .{ .mode = .{ .create = f.id } });
    defer db.close() catch unreachable;

    // LMDB reuses a page one transaction freed only two transactions later.
    // Two committed writes leave one reusable page for the third write's put,
    // and that commit then needs a fresh page to rewrite the freelist, which
    // is the allocation that fails.
    for ([_][]const u8{ "one", "still one" }) |value| {
        var warm = try db.beginWrite();
        defer warm.abort();
        try warm.put("a", value);
        try std.testing.expectEqual(core.backend.Commit.committed, try warm.commit());
    }
    try std.testing.expectEqual(@as(c_int, 0), mdb_env_set_mapsize(@ptrCast(db.env), 1));
    const full = try db.inspect();
    try std.testing.expectEqual(full.high_water_bytes, full.map_bytes);

    var write = try db.beginWrite();
    defer write.abort();
    try std.testing.expectError(error.Busy, db.beginWrite());
    try write.put("b", "two");
    try std.testing.expectError(error.StorageCapacity, write.commit());
    try std.testing.expectError(error.Closed, write.commit());
    {
        var read = try db.beginRead();
        defer read.end();
        try std.testing.expect((try read.get("b")) == null);
        try std.testing.expectEqualStrings("still one", (try read.get("a")).?);
    }

    try db.grow(full.map_bytes + 64 * full.page_bytes);
    var retry = try db.beginWrite();
    defer retry.abort();
    try retry.put("b", "two");
    try std.testing.expectEqual(core.backend.Commit.committed, try retry.commit());
}

test {
    _ = @import("../engines/recovery_test.zig");
}
