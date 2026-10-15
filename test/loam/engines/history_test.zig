//! Native retention exercises the same owner paths and tracing as volatile.
const std = @import("std");
const h = @import("../access/hosting_fixture.zig");
const cases = @import("../access/history_cases.zig");
const fixture = @import("engine_fixture");

test "loam engine access history composes bounded batches and collects expired history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", h.a);
    defer h.a.free(path);
    const terminated = try h.a.dupeSentinel(u8, path, 0);
    defer h.a.free(terminated);
    var db = try fixture.open(terminated, .create, h.f.store_id);
    defer db.close() catch unreachable;
    var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    try @import("../access/history_stamp_cases.zig").stamps(&store, &db);
    try cases.composed(&store, &db);
    try cases.capacity(&store, &db);
    try cases.overflow(&store, &db, @import("loam_test_support").collect);
}

test "loam engine access history accepts depth 64 and refuses depth 65 before staging" {
    const stamps = @import("../access/history_stamp_cases.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", h.a);
    defer h.a.free(path);
    const terminated = try h.a.dupeSentinel(u8, path, 0);
    defer h.a.free(terminated);
    var db = try fixture.open(terminated, .create, h.f.store_id);
    defer db.close() catch unreachable;
    var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, stamps.depth_limits);
    defer store.deinit() catch unreachable;
    try stamps.depth(&store, &db);
}
