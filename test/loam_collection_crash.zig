//! SIGKILL around one sweeping transaction, followed by a fresh tracing cycle.
const std = @import("std");
const core = @import("loam_core");
const Lmdb = @import("loam_lmdb").Lmdb;
const f = @import("loam/core/fixture.zig");
extern "c" fn pause() c_int;

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    if (args.len != 3) return error.InvalidArguments;
    const mode = std.mem.span(args[1]);
    const path = std.mem.span(args[2]);
    const creating = std.mem.eql(u8, mode, "create");
    var db = try Lmdb.open(path, .{ .mode = if (creating) .{ .create = f.id } else .{ .open = f.id } });
    defer db.close() catch unreachable;
    var store = try core.Store.init(init.gpa, db.metadata, &f.schemas, f.limits);
    defer store.deinit() catch unreachable;
    if (creating) {
        try store.begin();
        var ids: [4]core.ObjectId = undefined;
        for (&ids) |*id| id.* = try store.allocateId();
        for (ids, 0..) |id, i| {
            var r = f.record(id, "cycle");
            r.rooted = i == 0;
            r.edges = &.{.{ .target = ids[i ^ 1] }};
            try store.putCopying(r, null);
        }
        try f.commit(&store, &db);
        return;
    }
    if (std.mem.startsWith(u8, mode, "verify-")) {
        const expected: u64 = if (std.mem.eql(u8, mode, "verify-old")) 4 else 3;
        if (store.metadata.objects != expected or store.metadata.collection.phase != .clearing) return error.InvalidRecovery;
        try f.collect(&store, &db);
        if (store.metadata.objects != 2 or store.metadata.roots != 1) return error.InvalidRecoveredGraph;
        for (1..3) |sequence| {
            const lease = try f.load(&store, &db, .{ .store = f.id, .incarnation = 1, .sequence = sequence });
            if ((try store.view(lease)).edge_count != 1) return error.InvalidRecoveredEdge;
            try store.release(lease);
        }
        return;
    }
    if (!std.mem.eql(u8, mode, "before") and !std.mem.eql(u8, mode, "after")) return error.InvalidArguments;
    while (store.metadata.collection.phase != .sweep) try f.collectionStep(&store, &db, 1);
    try f.collectionStep(&store, &db, 2); // Both reachable records precede the garbage.
    const ticket = try store.prepareCollection(1);
    var pending = try db.beginCommit(try store.beginWrite(ticket));
    if (std.mem.eql(u8, mode, "after")) {
        if (pending.finish() != .committed) std.process.exit(2);
    }
    std.debug.print("READY\n", .{});
    while (true) _ = pause();
}
