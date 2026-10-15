//! Proves the adapter owns aliased read inputs at the LMDB call boundary.
//! The C hook rejects a key that still overlaps the preceding returned row.
//! This models allowed invalidation. It does not reproduce a natural eviction.
const std = @import("std");
const Lmdb = @import("loam_lmdb").Lmdb;
const fixture = @import("engine_fixture");
const f = @import("loam_test_support");

extern "c" fn loam_test_borrow_arm(bytes: [*]const u8, length: usize) void;
extern "c" fn loam_test_borrow_stop() void;
extern "c" fn loam_test_borrow_checks() c_uint;

test "LMDB get preserves a key borrowed from its preceding value" {
    try check(.get);
}

test "LMDB next preserves its preceding borrowed key as the next floor" {
    try check(.floor);
}

test "LMDB next preserves a prefix borrowed from its preceding key" {
    try check(.prefix);
}

fn check(operation: enum { get, floor, prefix }) !void {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try Lmdb.open(tmp.path, .{ .mode = .{ .create = f.id } });
    defer db.close() catch unreachable;
    {
        var write = try db.beginWrite();
        defer write.abort();
        try write.put("source", "row/a");
        try write.put("row/a", "first");
        try write.put("row/b", "second");
        try std.testing.expectEqual(.committed, try write.commit());
    }
    var read = try db.beginRead();
    defer read.end();
    defer loam_test_borrow_stop();
    switch (operation) {
        .get => {
            const key = (try read.get("source")).?;
            loam_test_borrow_arm(key.ptr, key.len);
            try std.testing.expectEqualStrings("first", (try read.get(key)).?);
        },
        .floor => {
            const row = (try read.next("row/", null)).?;
            loam_test_borrow_arm(row.key.ptr, row.key.len);
            const next = (try read.next("row/", row.key)).?;
            try std.testing.expectEqualStrings("row/b", next.key);
            try std.testing.expectEqualStrings("second", next.value);
        },
        .prefix => {
            const row = (try read.next("row/", null)).?;
            loam_test_borrow_arm(row.key.ptr, row.key.len);
            const first = (try read.next(row.key[0..4], null)).?;
            try std.testing.expectEqualStrings("row/a", first.key);
            try std.testing.expectEqualStrings("first", first.value);
        },
    }
    try std.testing.expectEqual(@as(c_uint, 1), loam_test_borrow_checks());
}
