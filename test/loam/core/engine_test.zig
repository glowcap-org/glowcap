//! The in-memory engine passes the storage engine suite and refuses work until opened.
const std = @import("std");
const f = @import("fixture.zig");
const Volatile = @import("glowcap").loam.Volatile;
const exercise = @import("engine_scenario.zig").exercise;

test "loam in-memory engine passes the storage engine suite" {
    var engine = try Volatile.init(std.testing.allocator, f.id, 64 * 1024);
    defer engine.deinit();
    const metadata = try engine.open();
    try exercise(f, &engine, metadata, .{ .capacity_bytes = 64 * 1024 });
    try engine.close();
}

test "loam in-memory engine refuses transactions until opened" {
    var engine = try Volatile.init(std.testing.allocator, f.id, 4096);
    defer engine.deinit();
    try std.testing.expectError(error.Closed, engine.beginRead());
    try std.testing.expectError(error.Closed, engine.beginWrite());
}

test "loam in-memory engine protects borrowed rows with exclusive write admission" {
    var engine = try Volatile.init(std.testing.allocator, f.id, 4096);
    defer engine.deinit();
    _ = try engine.open();
    {
        var write = try engine.beginWrite();
        defer write.abort();
        try std.testing.expectError(error.Busy, engine.beginWrite());
        try std.testing.expectError(error.Busy, engine.beginRead());
        try write.put("row", "original");
        _ = try write.commit();
    }
    {
        var first = try engine.beginRead();
        defer first.end();
        const bytes = (try first.get("row")).?;
        var second = try engine.beginRead();
        defer second.end();
        try std.testing.expectError(error.Busy, engine.beginWrite());
        try std.testing.expectEqualStrings("original", bytes);
    }
    var write = try engine.beginWrite();
    defer write.abort();
    try write.put("row", "replacement");
    _ = try write.commit();
    var read = try engine.beginRead();
    defer read.end();
    try std.testing.expectEqualStrings("replacement", (try read.get("row")).?);
}
