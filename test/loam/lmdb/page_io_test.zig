//! LMDB pages read by system call keep each snapshot intact while writes
//! update the cache, and a borrowed value survives eviction.
const std = @import("std");
const Lmdb = @import("loam_lmdb").Lmdb;
const fixture = @import("engine_fixture");
const f = @import("loam_test_support");

const original: [8192]u8 = @splat('A');

const Reader = struct {
    db: *Lmdb,
    fresh: bool = false,
    ready: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn run(self: *Reader) void {
        self.read() catch |err| {
            self.failure = err;
            self.ready.store(true, .release);
        };
    }

    fn read(self: *Reader) !void {
        if (self.fresh) {
            while (true) {
                try self.current();
                self.ready.store(true, .release);
                if (self.stop.load(.acquire)) return;
            }
        }
        var txn = try self.db.beginRead();
        defer txn.end();
        while (true) {
            try std.testing.expectEqualStrings(&original, (try txn.get("row")).?);
            self.ready.store(true, .release);
            if (self.stop.load(.acquire)) return;
            std.atomic.spinLoopHint();
        }
    }
    fn current(self: *Reader) !void {
        var txn = try self.db.beginRead();
        defer txn.end();
        try std.testing.expectEqualStrings(&original, (try txn.get("stable")).?);
    }
};

test "LMDB page cache keeps concurrent snapshots and updates reused large-value pages" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try Lmdb.open(tmp.path, .{ .mode = .{ .create = f.id } });
    defer db.close() catch unreachable;
    {
        var write = try db.beginWrite();
        defer write.abort();
        try write.put("row", &original);
        try write.put("stable", &original);
        _ = try write.commit();
    }
    var reader: Reader = .{ .db = &db };
    var fresh: Reader = .{ .db = &db, .fresh = true };
    {
        const thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
        defer {
            reader.stop.store(true, .release);
            thread.join();
        }
        const other = try std.Thread.spawn(.{}, Reader.run, .{&fresh});
        defer {
            fresh.stop.store(true, .release);
            other.join();
        }
        while (!reader.ready.load(.acquire) or !fresh.ready.load(.acquire)) std.atomic.spinLoopHint();
        try cycle(&db);
    }
    if (reader.failure) |err| return err;
    if (fresh.failure) |err| return err;
    // Ending the old reader lets LMDB reuse those cached physical pages.
    try cycle(&db);
}

fn cycle(db: *Lmdb) !void {
    var payload: [32768]u8 = undefined;
    for (0..96) |iteration| {
        const length: usize = switch (iteration % 3) {
            0 => 64,
            1 => 8192,
            else => payload.len,
        };
        @memset(&payload, @intCast(iteration));
        var write = try db.beginWrite();
        defer write.abort();
        try write.put("row", payload[0..length]);
        try write.put("neighbor", payload[0..64]);
        if (iteration % 2 == 0) try write.remove("neighbor");
        try std.testing.expectEqual(.committed, try write.commit());
        var read = try db.beginRead();
        defer read.end();
        try std.testing.expectEqualStrings(payload[0..length], (try read.get("row")).?);
        if (iteration % 2 == 0) {
            try std.testing.expect((try read.get("neighbor")) == null);
        } else try std.testing.expectEqualStrings(payload[0..64], (try read.get("neighbor")).?);
    }
}

test "LMDB page cache eviction keeps a value another transaction borrowed" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try Lmdb.open(tmp.path, .{ .mode = .{ .create = f.id }, .map_bytes = 1024 * 1024 * 1024 });
    defer db.close() catch unreachable;
    const page = (try db.inspect()).page_bytes;
    // Above the inline-node limit, but small enough for one overflow page.
    const payload = try std.testing.allocator.alloc(u8, page / 2 + 128);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'E');
    // More distinct overflow extents than the pinned MDB_ERPAGE_SIZE table.
    const rows = 17000;
    var next: usize = 0;
    while (next < rows) {
        var write = try db.beginWrite();
        defer write.abort();
        const end = @min(rows, next + 128);
        while (next < end) : (next += 1) {
            var key: [8]u8 = undefined;
            std.mem.writeInt(u64, &key, next, .big);
            std.mem.writeInt(u64, payload[0..8], (next * 37 + 17) % rows, .big);
            try write.put(&key, payload);
        }
        try std.testing.expectEqual(.committed, try write.commit());
    }
    var held = try db.beginRead();
    defer held.end();
    const borrowed = (try held.get(&@as([8]u8, @splat(0)))).?;
    next = 0;
    while (next < rows) {
        var read = try db.beginRead();
        defer read.end();
        const end = @min(rows, next + 128);
        while (next < end) : (next += 1) {
            var key: [8]u8 = undefined;
            std.mem.writeInt(u64, &key, next, .big);
            std.mem.writeInt(u64, payload[0..8], (next * 37 + 17) % rows, .big);
            try std.testing.expectEqualSlices(u8, payload, (try read.get(&key)).?);
        }
    }
    std.mem.writeInt(u64, payload[0..8], 17, .big);
    try std.testing.expectEqualSlices(u8, payload, borrowed);
    // One transaction must cross both cache limits while each seek consumes
    // its preceding borrowed key. A lookup may evict that key's own page.
    var scan = try db.beginRead();
    defer scan.end();
    var after: ?[]const u8 = null;
    next = 0;
    while (try scan.next("", after)) |row| {
        // Metadata is the only non-binary-key row in this fixture.
        if (row.key.len != 8) break;
        try std.testing.expectEqual(@as(u64, next), std.mem.readInt(u64, row.key[0..8], .big));
        after = row.key;
        next += 1;
    }
    try std.testing.expectEqual(@as(usize, rows), next);
    // Each large value names a distant row. Reuse that borrowed slice as a
    // lookup key while crossing the transaction's own cache purge threshold.
    var lookup = try db.beginRead();
    defer lookup.end();
    for (0..rows) |index| {
        var key: [8]u8 = undefined;
        std.mem.writeInt(u64, &key, index, .big);
        const link = (try lookup.get(&key)).?;
        const target = (try lookup.get(link[0..8])).?;
        const linked = (index * 37 + 17) % rows;
        try std.testing.expectEqual(@as(u64, (linked * 37 + 17) % rows), std.mem.readInt(u64, target[0..8], .big));
    }
    try std.testing.expectEqualSlices(u8, payload, borrowed);
}
