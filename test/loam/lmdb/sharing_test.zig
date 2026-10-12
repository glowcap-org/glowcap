//! Native lost-acknowledgement recovery followed by a fresh CapTP connection.
const std = @import("std");
const f = @import("../access/sharing_fixture.zig");
const h = f.h;
const Lmdb = @import("loam_lmdb").Lmdb;

test "loam LMDB sharing recovers a lost reply without duplicate grants after reopen" {
    for ([_]bool{ false, true }) |committed| {
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
        const data = try h.seedDepth(&store, &db, 1);
        {
            var server: h.Hosted = undefined;
            try server.init(&store, &db, data);
            defer server.deinit();
            var client: f.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
            try client.init(&server);
            defer client.deinit();
            var lost: f.captures.CapturedRef = .{};
            try client.send(client.parent, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &lost);
            const batch = try server.untilWrite(&db);
            if (committed) try std.testing.expect(db.commit(batch) == .committed) else {
                var tx = try db.beginCommit(batch);
                tx.abort();
            }
            try server.attached.completeWrite(batch.ticket, .unknown);
            try std.testing.expectError(error.Busy, server.attached.destroy());
            try std.testing.expect(lost.ref == null and !lost.broken);
            var waiting: f.captures.CapturedRef = .{};
            try client.send(client.parent, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &waiting);
            try server.attached.advance();
            try std.testing.expect(waiting.ref == null and !waiting.broken);
            try server.attached.resolve(batch.ticket, try db.recover(try server.attached.recoveryBatch()));
            // Retire the first call; the matching queued retry may commit only
            // when recovery proved the first attempt absent.
            try server.drain(&db);
            // Discard outbound replies with this client/Host.
        }
        try store.deinit();
        try db.close();
        db = try Lmdb.open(terminated, .{ .mode = .{ .open = h.f.store_id } });
        store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
        var server: h.Hosted = undefined;
        try server.init(&store, &db, data);
        defer server.deinit();
        var client: f.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
        try client.init(&server);
        defer client.deinit();
        const revision = store.metadata.revision;
        const child = try client.derive(&server, &db, 1, 0, 0);
        try std.testing.expectEqual(revision, store.metadata.revision);
        var locator: f.captures.CapturedString = .{};
        try client.send(child, "durable-name", &.{}, &locator);
        try server.drain(&db);
        try client.pump();
        var fetched: f.captures.CapturedRef = .{};
        try client.host.vowOn(try client.host.fetch(client.pair.a, locator.text()), .{ .ctx = &fetched, .func = f.captures.CapturedRef.record });
        try client.pump();
        const original = try client.host.liftCapability(client.pair.a, child);
        const restored = try client.host.liftCapability(client.pair.a, try fetched.require());
        try std.testing.expect(original.eql(restored));
        var read = try h.c.storage.Read.init(h.a, &store, data.owner, 8);
        defer read.deinit() catch unreachable;
        _ = try h.f.pump(&read, &db);
        try std.testing.expectEqual(@as(u64, 2), read.header.next_grant);
    }
}
