//! Native managed owners reopen their own indexes and recover atomic changes.
const std = @import("std");
const f = @import("../access/owner_fixture.zig");
const Lmdb = @import("loam_lmdb").Lmdb;
const support = @import("loam_test_support");
const a = std.testing.allocator;

test "loam LMDB managed owner reopens indexes and recovers content grants and event together" {
    for ([_]bool{ false, true }) |committed| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", a);
        defer a.free(path);
        const terminated = try a.dupeSentinel(u8, path, 0);
        defer a.free(terminated);
        var db = try Lmdb.open(terminated, .{ .mode = .{ .create = f.store_id } });
        defer db.close() catch unreachable;
        var store = try f.loam.core.Store.init(a, db.metadata, &f.schemas, f.limits);
        defer store.deinit() catch unreachable;
        const owner = try f.create(&store, &db, @fromBackingInt(71));
        const resource = try f.resource(&store, &db, owner, null);
        const terms = try f.vocabulary.terms(.{ .objects = &.{resource} }, &.{f.vocabulary.read}, null);
        const issued = (try f.change(&store, &db, owner, .{ .issue_root = f.vocabulary.issue(terms, 1) })).?;
        try store.begin();
        const content = try store.allocateId();
        try store.putCopying(.{ .id = content, .revision = 0, .schema = 7, .payload = "before", .rooted = true }, null);
        try f.commit(&store, &db);
        const content_revision = store.metadata.revision;
        try store.deinit();
        try db.close();
        db = try Lmdb.open(terminated, .{ .mode = .{ .open = f.store_id } });
        store = try f.loam.core.Store.init(a, db.metadata, &f.schemas, f.limits);
        try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
        {
            var read = try f.storage.Read.init(a, &store, owner, 6);
            defer read.deinit() catch unreachable;
            _ = try f.pump(&read, &db);
            try f.require(&read, &db, issued.grant, resource, .{ .permissions = &.{f.vocabulary.read} });
            var resources = try read.resourceView();
            var plan = (try f.prepare(&read, &db, .{ .revoke = issued.grant })).?;
            defer plan.deinit(a);
            try store.begin();
            try store.putCopying(.{ .id = content, .revision = 0, .schema = 7, .payload = "revoked", .rooted = true }, content_revision);
            const event = try f.storage.stage.grant(&read, &plan, null);
            const ticket = try store.prepare();
            const batch = try store.beginWrite(ticket);
            if (committed) {
                try std.testing.expect(db.commit(batch) == .committed);
            } else {
                var pending = try db.beginCommit(batch);
                pending.abort();
            }
            try store.completeWrite(ticket, .unknown);
            try std.testing.expectError(error.RecoveryRequired, resources.get(resource));
            try std.testing.expectError(error.RecoveryRequired, read.advance());
            try store.resolve(ticket, try db.recover(try store.recoveryBatch()));
            if (committed) {
                try std.testing.expectError(error.RevisionConflict, resources.get(resource));
            } else {
                try f.require(&read, &db, issued.grant, resource, .{ .permissions = &.{f.vocabulary.read} });
            }
            try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(2)), event.change.version.grants);
        }
        try store.deinit();
        try db.close();
        db = try Lmdb.open(terminated, .{ .mode = .{ .open = f.store_id } });
        store = try f.loam.core.Store.init(a, db.metadata, &f.schemas, f.limits);
        {
            var read = try f.storage.Read.init(a, &store, owner, 6);
            defer read.deinit() catch unreachable;
            _ = try f.pump(&read, &db);
            const req: f.core.Policy.Requirement = .{ .permissions = &.{f.vocabulary.read} };
            if (committed) try std.testing.expectError(error.Revoked, f.require(&read, &db, issued.grant, resource, req)) else try f.require(&read, &db, issued.grant, resource, req);
            const event_lease = try support.load(&store, &db, read.header.change.?);
            const event = try f.loam.access.records.ChangeRecord.decode((try store.currentView(event_lease)).payload);
            try std.testing.expectEqualDeep(read.header.version, event.change.version);
            try std.testing.expectEqual(issued.grant, event.change.grant);
            if (committed) try std.testing.expectEqual(.revoked, event.change.kind.status_changed.after) else try std.testing.expect(event.change.kind == .issued);
            try store.release(event_lease);
            const lease = try support.load(&store, &db, content);
            try std.testing.expectEqualStrings(if (committed) "revoked" else "before", (try store.currentView(lease)).payload);
            try store.release(lease);
        }
        const before = store.metadata.objects;
        try support.collect(&store, &db);
        try std.testing.expectEqual(before - @as(u64, @intFromBool(committed)), store.metadata.objects);
        // The reopened store continues issuance from the stored allocation floor.
        const next = try f.resource(&store, &db, owner, null);
        try std.testing.expectEqual(resource.slot + 1, next.slot);
        store.evict();
        try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    }
}
