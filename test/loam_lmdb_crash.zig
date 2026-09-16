//! Child process for loam-lmdb-crash-test. The parent kills the child after it
//! reports a precise transaction boundary; no test hook enters production code.
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
        const a = try store.allocateId();
        const b = try store.allocateId();
        var first = f.record(a, "old");
        first.rooted = true;
        first.edges = &.{.{ .target = b }};
        try store.putCopying(first, null);
        var second = f.record(b, "old");
        second.edges = &.{.{ .target = a }};
        try store.putCopying(second, null);
        try f.commit(&store, &db);
        return;
    }
    const a: core.ObjectId = .{ .store = f.id, .incarnation = 1, .sequence = 1 };
    const b: core.ObjectId = .{ .store = f.id, .incarnation = 1, .sequence = 2 };
    if (std.mem.startsWith(u8, mode, "verify-")) {
        const expected = mode[7..];
        for ([_]core.ObjectId{ a, b }) |id| {
            const lease = try f.load(&store, &db, id);
            const view = try store.view(lease);
            if (!std.mem.eql(u8, expected, view.payload) or view.edge_count != 1) return error.InvalidRecoveredGraph;
            var edges = view.edges();
            if (!edges.next().?.target.eql(if (id.eql(a)) b else a)) return error.InvalidRecoveredEdge;
            try store.release(lease);
        }
        if (store.metadata.objects != 2 or store.metadata.roots != 1) return error.InvalidRecoveredTotals;
        if (store.metadata.revision != (if (std.mem.eql(u8, expected, "old")) @as(u64, 1) else 2)) return error.InvalidRecoveredRevision;
        return;
    }
    if (!std.mem.eql(u8, mode, "before") and !std.mem.eql(u8, mode, "after")) return error.InvalidArguments;
    try store.begin();
    var first = f.record(a, "new");
    first.rooted = true;
    first.edges = &.{.{ .target = b }};
    try store.putCopying(first, 1);
    var second = f.record(b, "new");
    second.edges = &.{.{ .target = a }};
    try store.putCopying(second, 1);
    const ticket = try store.prepare();
    var pending = try db.beginCommit(try store.beginWrite(ticket));
    if (std.mem.eql(u8, mode, "after")) {
        if (pending.finish() != .committed) std.process.exit(2);
    }
    // Parent owns the deadline and sends SIGKILL after this exact boundary.
    std.debug.print("READY\n", .{});
    while (true) _ = pause();
}
