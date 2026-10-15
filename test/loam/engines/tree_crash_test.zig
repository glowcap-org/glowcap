//! A hosted move that changes three resources recovers all or none of them
//! after the write is lost or committed and the engine reopens. The retry then
//! settles the same intent exactly once (ADR-0227).
const std = @import("std");
const t = @import("../access/tree_fixture.zig");
const h = t.h;
const fixture = @import("engine_fixture");

/// Build root -> {first -> {leaf}, second} through ordinary hosted calls.
fn grow(tree: *t.Tree, db: *fixture.Engine) !void {
    const root = tree.client.parent;
    const first = try tree.add(db, root, 1);
    _ = try tree.add(db, root, 2);
    _ = try tree.add(db, first, 3);
}

test "loam engine hosted tree move recovers all or none of its resources after reopen" {
    for ([_]bool{ false, true }) |committed| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", h.a);
        defer h.a.free(path);
        const terminated = try h.a.dupeSentinel(u8, path, 0);
        defer h.a.free(terminated);
        var db = try fixture.open(terminated, .create, h.f.store_id);
        defer db.close() catch unreachable;
        var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        const data = try h.seedSubtree(&store, &db, 2);
        {
            var tree: t.Tree = undefined;
            try tree.init(&store, &db, data);
            defer tree.deinit();
            try grow(&tree, &db);
            const first = try tree.open(&db, tree.client.parent, 2);
            const second = try tree.open(&db, tree.client.parent, 3);
            var lost: t.Outcome = .{};
            const leaf = try tree.open(&db, first, 0);
            const args = [_]t.s.model.Argument{ .{ .integer = 4 }, .{ .string = "move" }, .{ .reference = leaf }, .{ .reference = second } };
            try tree.client.send(first, "mutate", &args, &lost);
            const batch = try tree.server.untilWrite(&db);
            if (committed) try std.testing.expect(db.commit(batch) == .committed) else {
                var pending = try db.beginWrite();
                _ = try batch.apply(&pending);
                pending.abort();
            }
            try tree.server.attached.completeWrite(batch.ticket, .unknown);
            try tree.server.attached.resolve(batch.ticket, try db.recover(try tree.server.attached.recoveryBatch()));
            try tree.server.drain(&db);
            try tree.client.pump();
        }
        try store.deinit();
        try db.close();
        db = try fixture.open(terminated, .open, h.f.store_id);
        store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
        try std.testing.expectEqualDeep(if (committed) t.Latest{ .moved = 1, .content = 2 } else t.Latest{ .created = 1, .content = 1 }, try t.latest(&store, &db, data.owner));
        var tree: t.Tree = undefined;
        try tree.init(&store, &db, data);
        defer tree.deinit();
        const first = try tree.open(&db, tree.client.parent, 2);
        const second = try tree.open(&db, tree.client.parent, 3);
        try std.testing.expectEqual(@as(i64, @intFromBool(!committed)), try tree.count(&db, first));
        try std.testing.expectEqual(@as(i64, @intFromBool(committed)), try tree.count(&db, second));
        // Fresh facets name the same nodes, so the retry matches the receipt
        // when the move committed and runs once when it did not. The leaf is
        // opened from whichever node holds it now.
        const leaf = try tree.open(&db, if (committed) second else first, 0);
        const revision = store.metadata.revision;
        var retry: t.Outcome = .{};
        try tree.mutate(&db, first, 4, "move", &.{ .{ .reference = leaf }, .{ .reference = second } }, &retry);
        try std.testing.expectEqualStrings("", retry.reason());
        try std.testing.expectEqual(@as(?i64, 1), retry.value);
        try std.testing.expectEqual(revision + @intFromBool(!committed), store.metadata.revision);
        try std.testing.expectEqual(@as(i64, 0), try tree.count(&db, first));
        try std.testing.expectEqual(@as(i64, 1), try tree.count(&db, second));
        // A creation retried after reopen replays its saved reply: the same
        // child, now holding the moved leaf, and no new resource.
        const settled = store.metadata.revision;
        const replayed = try tree.add(&db, tree.client.parent, 2);
        try std.testing.expectEqual(settled, store.metadata.revision);
        try std.testing.expectEqual(@as(i64, 1), try tree.count(&db, replayed));
    }
}
