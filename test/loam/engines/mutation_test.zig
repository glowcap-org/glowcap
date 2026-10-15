//! A lost mutation reply recovers its exact outcome in a new Host after reopen.
const std = @import("std");
const h = @import("../access/hosting_fixture.zig");
const fixture = @import("engine_fixture");

test "loam engine mutation retries recover committed and absent outcomes after reopen" {
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
        const data = try h.seed(&store, &db);
        {
            var server: h.Hosted = undefined;
            try server.init(&store, &db, data);
            defer server.deinit();
            var lost: h.Answer = .{};
            try server.mutate(server.use, 1, "add", &.{.{ .integer = 7 }}, &lost);
            const batch = try server.untilWrite(&db);
            if (committed) try std.testing.expect(db.commit(batch) == .committed) else {
                var tx = try db.beginWrite();
                _ = try batch.apply(&tx);
                tx.abort();
            }
            try server.attached.completeWrite(batch.ticket, .unknown);
            try std.testing.expect(lost.number == null and !lost.broken);
            try std.testing.expectError(error.Busy, server.attached.destroy());
            try server.attached.resolve(batch.ticket, try db.recover(try server.attached.recoveryBatch()));
            try server.drain(&db);
        }
        try store.deinit();
        try db.close();
        db = try fixture.open(terminated, .open, h.f.store_id);
        store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
        var server: h.Hosted = undefined;
        try server.init(&store, &db, data);
        defer server.deinit();
        const revision = store.metadata.revision;
        var retry: h.Answer = .{};
        try server.mutate(server.use, 1, "add", &.{.{ .integer = 7 }}, &retry);
        try server.drain(&db);
        try std.testing.expectEqual(@as(?i64, 7), retry.number);
        try std.testing.expectEqual(revision + @intFromBool(!committed), store.metadata.revision);
        var later: h.Answer = .{};
        try server.mutate(server.use, 2, "add", &.{.{ .integer = 3 }}, &later);
        try server.drain(&db);
        var exact: h.Answer = .{};
        try server.mutate(server.use, 1, "add", &.{.{ .integer = 7 }}, &exact);
        try server.drain(&db);
        try std.testing.expectEqual(@as(?i64, 7), exact.number);
        var current: h.Answer = .{};
        try server.send(server.use, "get", &.{}, &current);
        try server.drain(&db);
        try std.testing.expectEqual(@as(?i64, 10), current.number);
    }
}
