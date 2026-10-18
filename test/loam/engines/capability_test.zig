//! Exact managed references survive a reopen and uncertain grant edits.
const std = @import("std");
const c = @import("../access/capability_fixture.zig");
const f = c.f;
const a = c.a;
const fixture = @import("engine_fixture");
const support = @import("loam_test_support");

test "loam engine managed capabilities restore roles and fence cold calls through recovery" {
    for ([_]bool{ false, true }) |committed| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        defer a.free(path);
        const terminated = try a.dupeSentinel(u8, path, 0);
        defer a.free(terminated);
        var db = try fixture.open(terminated, .create, f.store_id);
        defer db.close() catch unreachable;
        var store = try f.loam.core.Store.init(a, db.metadata, &f.schemas, f.limits);
        defer store.deinit() catch unreachable;
        const owner = try f.create(&store, &db, @fromBackingInt(71));
        const resource = try f.resource(&store, &db, owner, null);
        const terms = try f.vocabulary.terms(.{ .objects = &.{resource} }, &.{f.vocabulary.read}, null);
        const grant = (try f.change(&store, &db, owner, .{ .issue_root = f.vocabulary.issue(terms, 0) })).?.grant;
        var use_id: f.loam.core.ObjectId = undefined;
        var control_id: f.loam.core.ObjectId = undefined;
        {
            var caps = try c.storage.Capabilities.init(a, &store, .{});
            defer caps.deinit() catch unreachable;
            use_id = try c.descriptor(&caps, &db, owner, grant, null, .rooted);
            control_id = try c.descriptor(&caps, &db, owner, grant, .{ .revoke = true, .policy_ceiling = terms }, .rooted);
        }
        try store.begin();
        const content = try store.allocateId();
        try store.putCopying(.{ .id = content, .revision = 0, .schema = 7, .payload = "before", .rooted = true }, null);
        try f.commit(&store, &db);
        const revision = store.metadata.revision;
        try store.deinit();
        try db.close();
        db = try fixture.open(terminated, .open, f.store_id);
        store = try f.loam.core.Store.init(a, db.metadata, &f.schemas, f.limits);
        {
            var caps = try c.storage.Capabilities.init(a, &store, .{});
            defer caps.deinit() catch unreachable;
            const use = try c.use(&caps, &db, use_id);
            defer use.release();
            const control = try c.control(&caps, &db, control_id);
            defer control.release();
            try std.testing.expectError(error.WrongRole, c.use(&caps, &db, control_id));
            store.evict();
            const cold = try use.begin(4);
            defer cold.deinit() catch unreachable;
            const request = (try cold.advance()).read;
            const reply = db.read(request);
            const edit = try control.begin(4);
            defer edit.deinit() catch unreachable;
            try std.testing.expect(try c.edit(edit, &db, .revoke));
            try store.begin();
            try store.putCopying(.{ .id = content, .revision = 0, .schema = 7, .payload = "revoked", .rooted = true }, revision);
            _ = try caps.stage(edit, .reachable);
            const ticket = try store.prepare();
            const batch = try store.beginWrite(ticket);
            if (committed) {
                try std.testing.expect(db.commit(batch) == .committed);
            } else {
                var pending = try db.beginWrite();
                _ = try batch.apply(&pending);
                pending.abort();
            }
            try store.completeWrite(ticket, .unknown);
            try std.testing.expectError(error.RecoveryRequired, cold.advance());
            try std.testing.expectError(error.RecoveryRequired, use.begin(4));
            try store.resolve(ticket, try db.recover(try store.recoveryBatch()));
            if (committed) {
                try std.testing.expectError(error.StaleCompletion, cold.completeRead(request.ticket, reply));
                try std.testing.expectError(error.RevisionConflict, cold.advance());
            } else {
                try cold.completeRead(request.ticket, reply);
                try c.require(cold, &db, resource, .{ .permissions = &.{f.vocabulary.read} });
            }
        }
        try store.deinit();
        try db.close();
        db = try fixture.open(terminated, .open, f.store_id);
        store = try f.loam.core.Store.init(a, db.metadata, &f.schemas, f.limits);
        {
            var caps = try c.storage.Capabilities.init(a, &store, .{});
            defer caps.deinit() catch unreachable;
            const use = try c.use(&caps, &db, use_id);
            defer use.release();
            const operation = try use.begin(4);
            defer operation.deinit() catch unreachable;
            const req: c.core.Policy.Requirement = .{ .permissions = &.{f.vocabulary.read} };
            if (committed) try std.testing.expectError(error.Revoked, c.require(operation, &db, resource, req)) else try c.require(operation, &db, resource, req);
            const lease = try c.load(&store, &db, content);
            defer store.release(lease) catch unreachable;
            try std.testing.expectEqualStrings(if (committed) "revoked" else "before", (try store.currentView(lease)).payload);
        }
        // An unrooted descriptor survives only while actual store custody does.
        var caps = try c.storage.Capabilities.init(a, &store, .{});
        defer caps.deinit() catch unreachable;
        const loose = try c.descriptor(&caps, &db, owner, grant, null, .reachable);
        const held = try c.use(&caps, &db, loose);
        try support.collect(&store, &db);
        const before = store.metadata.objects;
        held.release();
        try support.collect(&store, &db);
        try std.testing.expectEqual(before - 1, store.metadata.objects);
        try std.testing.expectError(error.Gone, c.use(&caps, &db, loose));
    }
}
