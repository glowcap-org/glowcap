//! Native recovery fences the same managed Host calls used over CapTP.
const std = @import("std");
const h = @import("../access/hosting_fixture.zig");
const Lmdb = @import("loam_lmdb").Lmdb;
const descriptions = @import("../access/description_fixture.zig");

test "loam LMDB managed hosting restores endpoints and resolves lost control acknowledgements" {
    for ([_]bool{ false, true }) |committed| {
        var memory = std.heap.ArenaAllocator.init(h.a);
        defer memory.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", h.a);
        defer h.a.free(path);
        const terminated = try h.a.dupeSentinel(u8, path, 0);
        defer h.a.free(terminated);
        var db = try Lmdb.open(terminated, .{ .mode = .{ .create = h.f.store_id } });
        defer db.close() catch unreachable;
        var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        const data = try h.seed(&store, &db);
        var publication: h.loam.core.ObjectId = undefined;
        {
            var host: h.Hosted = undefined;
            try host.init(&store, &db, data);
            defer host.deinit();
            var add: h.Answer = .{};
            try host.send(host.use, "add", &.{.{ .integer = 4 }}, &add);
            try host.drain(&db);
            try std.testing.expectEqual(@as(?i64, 4), add.number);
            try store.begin();
            publication = try h.loam.hosting.publication.stage(host.attached, @splat(0x43), host.use);
            try h.f.commit(&store, &db);
        }
        try store.deinit();
        try db.close();
        db = try Lmdb.open(terminated, .{ .mode = .{ .open = h.f.store_id } });
        store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
        {
            var host: h.Hosted = undefined;
            try host.init(&store, &db, data);
            defer host.deinit();
            const lease = try h.c.load(&store, &db, publication);
            _ = try h.loam.hosting.publication.restore(host.attached, lease);
            try store.release(lease);
            store.evict();
            var revoke: h.Answer = .{};
            try host.send(host.control, "revoke", &.{}, &revoke);
            const batch = try host.untilWrite(&db);
            if (committed) try std.testing.expect(db.commit(batch) == .committed) else {
                var pending = try db.beginCommit(batch);
                pending.abort();
            }
            try host.attached.completeWrite(batch.ticket, .unknown);
            var snapshot: descriptions.Capture = .{ .arena = memory.allocator() };
            try descriptions.sendLocal(&host, &snapshot);
            var use: h.Answer = .{};
            try host.send(host.use, "get", &.{}, &use);
            _ = try host.host.vat.driveIngressBudgeted(.local, 64);
            try host.attached.advance();
            try std.testing.expect(use.number == null and !use.broken);
            try std.testing.expect(revoke.changed == null and !revoke.broken);
            try std.testing.expect(snapshot.value == null and !snapshot.failed);
            try std.testing.expectError(error.Busy, host.attached.destroy());
            try host.attached.resolve(batch.ticket, try db.recover(try host.attached.recoveryBatch()));
            try host.drain(&db);
            try descriptions.expectStatus(try snapshot.require(), if (committed) "revoked" else "active");
            try std.testing.expectEqual(committed, use.broken);
            try std.testing.expectEqual(!committed, revoke.broken);
            if (!committed) try std.testing.expectEqual(@as(?i64, 4), use.number);
        }
        try store.deinit();
        try db.close();
        db = try Lmdb.open(terminated, .{ .mode = .{ .open = h.f.store_id } });
        store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
        var host: h.Hosted = undefined;
        try host.init(&store, &db, data);
        defer host.deinit();
        var after: h.Answer = .{};
        try host.send(host.use, "get", &.{}, &after);
        try host.drain(&db);
        try std.testing.expectEqual(committed, after.broken);
        if (!committed) try std.testing.expectEqual(@as(?i64, 4), after.number);
        var snapshot: descriptions.Capture = .{ .arena = memory.allocator() };
        try descriptions.sendLocal(&host, &snapshot);
        try host.drain(&db);
        try descriptions.expectStatus(try snapshot.require(), if (committed) "revoked" else "active");
        if (!committed) {
            var shared: h.Answer = .{};
            try host.send(host.use, "share", &.{}, &shared);
            try host.drain(&db);
            // The stored reference field survived reopen: the declared
            // disclosure reaches settlement, and only the local-resolver rule
            // refuses the owning reply on this listener path.
            try std.testing.expect(shared.broken);
            try std.testing.expectEqualStrings("OwningReplyRequired", shared.reason());
        }
    }
}

test "loam LMDB managed hosting recovers reference field replacement and removal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", h.a);
    defer h.a.free(path);
    const terminated = try h.a.dupeSentinel(u8, path, 0);
    defer h.a.free(terminated);
    var db = try Lmdb.open(terminated, .{ .mode = .{ .create = h.f.store_id } });
    defer db.close() catch unreachable;
    var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &db);
    {
        var host: h.Hosted = undefined;
        try host.init(&store, &db, data);
        defer host.deinit();
        h.replacement = host.use;
        defer h.replacement = null;
        var replaced: h.Answer = .{};
        try host.send(host.use, "replace-reference", &.{}, &replaced);
        try host.drain(&db);
        try std.testing.expectEqual(@as(?bool, true), replaced.changed);
    }
    try store.deinit();
    try db.close();
    db = try Lmdb.open(terminated, .{ .mode = .{ .open = h.f.store_id } });
    store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
    {
        var host: h.Hosted = undefined;
        try host.init(&store, &db, data);
        defer host.deinit();
        var lease = try h.c.load(&store, &db, data.content);
        var view = try store.currentView(lease);
        var edges = view.edges();
        try std.testing.expect(edges.next().?.target.eql(data.use));
        try store.release(lease);

        // Simulate an interrupted LMDB commit. Recovery reports unchanged, so
        // both the saved edge and its custody survive the aborted removal.
        var aborted: h.Answer = .{};
        try host.send(host.use, "remove-reference", &.{}, &aborted);
        const batch = try host.untilWrite(&db);
        var pending = try db.beginCommit(batch);
        pending.abort();
        try host.attached.completeWrite(batch.ticket, .unknown);
        try host.attached.resolve(batch.ticket, try db.recover(try host.attached.recoveryBatch()));
        try host.drain(&db);
        try std.testing.expect(aborted.broken);
        lease = try h.c.load(&store, &db, data.content);
        view = try store.currentView(lease);
        edges = view.edges();
        try std.testing.expect(edges.next().?.target.eql(data.use));
        try store.release(lease);

        var removed: h.Answer = .{};
        try host.send(host.use, "remove-reference", &.{}, &removed);
        try host.drain(&db);
        try std.testing.expectEqual(@as(?bool, true), removed.changed);
    }
    try store.deinit();
    try db.close();
    db = try Lmdb.open(terminated, .{ .mode = .{ .open = h.f.store_id } });
    store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
    const lease = try h.c.load(&store, &db, data.content);
    defer store.release(lease) catch unreachable;
    const view = try store.currentView(lease);
    try std.testing.expectEqual(@as(usize, 1), view.edge_count);
    var edges = view.edges();
    const remaining = edges.next().?;
    try std.testing.expect(remaining.target.eql(data.control));
    try std.testing.expect(remaining.strength == .weak);
}
