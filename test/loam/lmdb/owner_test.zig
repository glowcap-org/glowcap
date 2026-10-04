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
            // This read consumed the proposed owner header. Recovery ends that
            // transaction even when absent; its composed view must be reopened.
            try std.testing.expectError(error.RevisionConflict, resources.get(resource));
            try std.testing.expectError(error.RevisionConflict, read.advance());
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
            const event = try f.latestGrant(&read, &db);
            try std.testing.expectEqualDeep(read.header.version, event.version);
            try std.testing.expectEqual(issued.grant, event.grant);
            if (committed) try std.testing.expectEqual(.revoked, event.kind.status_changed.after) else try std.testing.expect(event.kind == .issued);
            const lease = try support.load(&store, &db, content);
            try std.testing.expectEqualStrings(if (committed) "revoked" else "before", (try store.currentView(lease)).payload);
            try store.release(lease);
        }
        const before = store.metadata.objects;
        try support.collect(&store, &db);
        try std.testing.expectEqual(before, store.metadata.objects);
        // The reopened store continues issuance from the stored allocation floor.
        const next = try f.resource(&store, &db, owner, null);
        try std.testing.expectEqual(resource.slot + 1, next.slot);
        store.evict();
        try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    }
}

test "loam LMDB composed managed changes reopen atomically after commit and unknown outcomes" {
    for ([_]bool{ false, true }) |committed| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", a);
        defer a.free(path);
        const terminated = try a.dupeSentinel(u8, path, 0);
        defer a.free(terminated);
        var db = try Lmdb.open(terminated, .{ .mode = .{ .create = f.store_id } });
        defer db.close() catch unreachable;
        var wide = f.limits;
        wide.cache_slots = 24;
        wide.max_leases = 24;
        var store = try f.loam.core.Store.init(a, db.metadata, &f.schemas, wide);
        defer store.deinit() catch unreachable;
        const owner = try f.create(&store, &db, @fromBackingInt(81));
        const resource = try f.resource(&store, &db, owner, null);

        // One transaction: resource append, root issuance over committed and
        // staged resources, and a derive under the issued grant. The working
        // read closes before the store does.
        var issued_grant: f.core.GrantId = undefined;
        var derived_grant: f.core.GrantId = undefined;
        var staged_message: f.core.ResourceId = undefined;
        {
            try store.begin();
            var read = try f.storage.Read.init(a, &store, owner, 7);
            defer read.deinit() catch unreachable;
            _ = try f.pump(&read, &db);
            var append = try f.storage.Append.init(&read, .resource);
            _ = try f.pump(&append, &db);
            const message = try f.stageResource(&append, &read, &db, f.vocabulary.kind, resource);
            staged_message = message;
            try append.deinit();
            const terms = try f.vocabulary.terms(.{ .objects = &.{ resource, message } }, &.{ f.vocabulary.read, f.vocabulary.post }, null);
            var plan = (try f.prepare(&read, &db, .{ .issue_root = f.vocabulary.issue(terms, 2) })).?;
            defer plan.deinit(a);
            var grants_append = try f.storage.Append.init(&read, .grant);
            _ = try f.pump(&grants_append, &db);
            const issued = try f.storage.stage.grant(&read, &plan, &grants_append);
            issued_grant = issued.change.grant;
            try grants_append.deinit();
            const selected = try f.vocabulary.terms(.{ .objects = &.{message} }, &.{f.vocabulary.read}, null);
            var child_plan = (try f.prepare(&read, &db, .{ .derive = .{ .parent = issued.change.grant, .request = f.vocabulary.issue(selected, 0) } })).?;
            defer child_plan.deinit(a);
            var child_append = try f.storage.Append.init(&read, .grant);
            _ = try f.pump(&child_append, &db);
            const derived = try f.storage.stage.grant(&read, &child_plan, &child_append);
            derived_grant = derived.change.grant;
            try child_append.deinit();
            const ticket = try store.prepare();
            const batch = try store.beginWrite(ticket);
            if (committed) {
                const outcome = db.commit(batch);
                try std.testing.expect(outcome == .committed);
                try store.completeWrite(ticket, outcome);
            } else {
                var pending = try db.beginCommit(batch);
                pending.abort();
                try store.completeWrite(ticket, .unknown);
                try store.resolve(ticket, try db.recover(try store.recoveryBatch()));
            }
        }
        try store.deinit();
        try db.close();
        db = try Lmdb.open(terminated, .{ .mode = .{ .open = f.store_id } });
        store = try f.loam.core.Store.init(a, db.metadata, &f.schemas, wide);
        try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
        {
            var verify = try f.storage.Read.init(a, &store, owner, 7);
            defer verify.deinit() catch unreachable;
            _ = try f.pump(&verify, &db);
            const req: f.core.Policy.Requirement = .{ .permissions = &.{f.vocabulary.read} };
            if (committed) {
                try std.testing.expectEqual(@as(u64, 2), verify.header.next_resource);
                try std.testing.expectEqual(@as(u64, 2), verify.header.next_grant);
                try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(2)), verify.header.version.grants);
                try f.require(&verify, &db, issued_grant, resource, req);
                try f.require(&verify, &db, issued_grant, staged_message, req);
                try f.require(&verify, &db, derived_grant, staged_message, req);
                try std.testing.expectError(error.OutOfScope, f.require(&verify, &db, derived_grant, resource, req));
                var grants = try verify.grantView();
                try std.testing.expectEqual(@as(u32, 1), (try grants.get(issued_grant)).child_count);
                try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(2)), (try grants.get(issued_grant)).revision);
                const event = try f.latestGrant(&verify, &db);
                try std.testing.expectEqualDeep(verify.header.version, event.version);
                try std.testing.expectEqual(derived_grant, event.grant);
            } else {
                // Recovery proved the composed batch absent: the committed
                // owner keeps its pre-composition indexes and counters.
                try std.testing.expectEqual(@as(u64, 1), verify.header.next_resource);
                try std.testing.expectEqual(@as(u64, 0), verify.header.next_grant);
                try std.testing.expectEqual(@as(f.core.Revision, @fromBackingInt(0)), verify.header.version.grants);
                try std.testing.expectError(error.MissingGrantEvent, f.latestGrant(&verify, &db));
                try std.testing.expectEqual(@as(u64, 2), verify.history.next_sequence);
                try std.testing.expectError(error.UnknownGrant, f.require(&verify, &db, issued_grant, resource, req));
            }
        }
        const next = try f.resource(&store, &db, owner, null);
        try std.testing.expectEqual((if (committed) staged_message.slot + 1 else staged_message.slot), next.slot);
        store.evict();
        try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    }
}
