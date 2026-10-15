//! Native resource moves recover one atomic content, index and receipt outcome.
const std = @import("std");
const r = @import("../access/resource_fixture.zig");
const h = r.h;
const fixture = @import("engine_fixture");

test "loam engine resource lifecycle recovers moves, child indexes, content and exact retry after reopen" {
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
        const seed = try r.seed(&store, &db);
        const destination = try h.f.resource(&store, &db, seed.data.owner, seed.root);
        var caps = try r.storage.Capabilities.init(h.a, &store, .{});
        const descriptor = try h.c.descriptor(&caps, &db, seed.data.owner, seed.data.grant, null, false);
        try caps.deinit();
        {
            var server: h.Hosted = undefined;
            try server.init(&store, &db, seed.data);
            defer server.deinit();
            var lost: h.Answer = .{};
            try server.mutate(server.use, 1, "move-resource", &.{.{ .integer = destination.slot }}, &lost);
            const batch = try server.untilWrite(&db);
            try std.testing.expect(lost.changed == null);
            if (committed) try std.testing.expect(db.commit(batch) == .committed) else {
                var pending = try db.beginWrite();
                _ = try batch.apply(&pending);
                pending.abort();
            }
            try server.attached.completeWrite(batch.ticket, .unknown);
            try server.attached.resolve(batch.ticket, try db.recover(try server.attached.recoveryBatch()));
            try server.drain(&db);
        }
        try store.deinit();
        try db.close();
        db = try fixture.open(terminated, .open, h.f.store_id);
        store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
        caps = try r.storage.Capabilities.init(h.a, &store, .{});
        try r.children(&caps, &db, descriptor, seed.root, if (committed) &.{destination} else &.{ seed.leaf, destination });
        try r.children(&caps, &db, descriptor, destination, if (committed) &.{seed.leaf} else &.{});
        try caps.deinit();
        var server: h.Hosted = undefined;
        try server.init(&store, &db, seed.data);
        defer server.deinit();
        const revision = store.metadata.revision;
        var retry: h.Answer = .{};
        try server.mutate(server.use, 1, "move-resource", &.{.{ .integer = destination.slot }}, &retry);
        try server.drain(&db);
        try std.testing.expectEqual(@as(?bool, true), retry.changed);
        try std.testing.expectEqual(revision + @intFromBool(!committed), store.metadata.revision);
        var content: h.Answer = .{};
        try server.send(server.use, "get", &.{}, &content);
        try server.drain(&db);
        try std.testing.expectEqual(@as(?i64, 1), content.number);
        var conflict: h.Answer = .{};
        try server.mutate(server.use, 1, "move-resource", &.{.{ .integer = seed.root.slot }}, &conflict);
        try server.drain(&db);
        try std.testing.expectEqualStrings("OperationConflict", conflict.reason());
        try std.testing.expect(try r.change(&store, &db, seed.data.owner, seed.leaf, .delete_leaf));
        var gone: h.Answer = .{};
        try server.send(server.use, "get", &.{}, &gone);
        try server.drain(&db);
        try std.testing.expectEqualStrings("Gone", gone.reason());
    }
}

test "loam engine resource lifecycle preserves structure visibility and rollback invariants" {
    inline for (.{ "structure", "visibility", "rollback", "queued", "independentPreparations", "composedTraversal", "cursorCustody", "cursorCancellation" }) |name| {
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
        try @field(@import("../access/resource_cases.zig"), name)(&store, &db);
    }
}

test "loam engine resource lifecycle reopens moves out of and into subtree scope and stable deleted identities" {
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
    const seed = try r.seed(&store, &db);
    const actions = [_]r.storage.ResourceChange.Action{ .{ .move = seed.other }, .{ .move = seed.root }, .delete_leaf };
    for (actions, [_]?[]const u8{ "OutOfScope", null, "Gone" }) |action, refusal| {
        try std.testing.expect(try r.change(&store, &db, seed.data.owner, seed.leaf, action));
        try store.deinit();
        try db.close();
        db = try fixture.open(terminated, .open, h.f.store_id);
        store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
        var server: h.Hosted = undefined;
        try server.init(&store, &db, seed.data);
        defer server.deinit();
        var answer: h.Answer = .{};
        try server.send(server.use, "get", &.{}, &answer);
        try server.drain(&db);
        if (refusal) |reason| try std.testing.expectEqualStrings(reason, answer.reason()) else try std.testing.expectEqual(@as(?i64, 0), answer.number);
        var caps = try r.storage.Capabilities.init(h.a, &store, .{});
        defer caps.deinit() catch unreachable;
        const use = try h.c.descriptor(&caps, &db, seed.data.owner, seed.data.grant, null, false);
        try r.children(&caps, &db, use, seed.root, if (action == .move and action.move.?.eql(seed.root)) &.{seed.leaf} else &.{});
        const content = try h.c.load(&store, &db, seed.data.content);
        try std.testing.expectEqual(@as(usize, 8), (try store.currentView(content)).payload.len);
        try store.release(content);
    }
}
