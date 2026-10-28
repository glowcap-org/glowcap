//! Graph pages, recipe custody, managed events and receipts share one outcome.
const std = @import("std");
const h = @import("../access/hosting_fixture.zig");
const graph = @import("../access/content_graph_fixture.zig");
const history = @import("../access/history_cases.zig");
const fixture = @import("engine_fixture");
const refs = h.loam.hosting.references;
const schemas = h.schemas ++ [_]h.loam.core.Schema{refs.schema};

fn expectGraph(store: *h.loam.core.Store, db: *fixture.Engine, root: h.loam.core.ObjectId, value: i64, target: h.loam.core.ObjectId, recipe: bool) !void {
    const lease = try h.c.load(store, db, root);
    defer store.release(lease) catch unreachable;
    const view = try store.currentView(lease);
    try std.testing.expectEqual(value, std.mem.readInt(i64, view.payload[0..8], .little));
    try std.testing.expectEqual(@as(usize, 7), view.edge_count);
    var links = view.edges();
    const resource = links.next().?.target;
    var shared_recipe: ?h.loam.core.ObjectId = null;
    while (links.next()) |link| {
        const page = try h.c.load(store, db, link.target);
        defer store.release(page) catch unreachable;
        const child = try store.currentView(page);
        try std.testing.expectEqual(value, std.mem.readInt(i64, child.payload[0..8], .little));
        try std.testing.expectEqual(@as(usize, 2), child.edge_count);
        var fields = child.edges();
        try std.testing.expect(fields.next().?.target.eql(resource));
        const field = fields.next().?;
        if (recipe) {
            try std.testing.expectEqual(.recipe, field.restoration);
            if (shared_recipe) |prior| try std.testing.expect(prior.eql(field.target)) else shared_recipe = field.target;
            const saved = try h.c.load(store, db, field.target);
            defer store.release(saved) catch unreachable;
            const decoded = try store.currentView(saved);
            try std.testing.expectEqual(refs.schema.id, decoded.schema);
            try std.testing.expectEqualSlices(u8, "\x00target", decoded.payload);
            try std.testing.expectEqual(@as(usize, 1), decoded.edge_count);
            var dependencies = decoded.edges();
            try std.testing.expect(dependencies.next().?.target.eql(target));
        } else {
            try std.testing.expectEqual(.object, field.restoration);
            try std.testing.expect(field.target.eql(target));
        }
    }
}

test "loam engine graph replacement recovers applied and absent recipe outcomes" {
    for ([_]enum { absent, unknown_applied, unknown_absent }{ .absent, .unknown_applied, .unknown_absent }) |outcome| {
        const applied = outcome == .unknown_applied;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", h.a);
        defer h.a.free(path);
        const terminated = try h.a.dupeSentinel(u8, path, 0);
        defer h.a.free(terminated);
        var db = try fixture.open(terminated, .create, h.f.store_id);
        defer db.close() catch unreachable;
        var store = try h.loam.core.Store.init(h.a, db.metadata, &schemas, h.limits);
        defer store.deinit() catch unreachable;
        const seeded = try graph.seed(&store, &db);
        {
            var scope = try refs.Scope.init(h.a, 2);
            defer scope.deinit() catch unreachable;
            var host: h.Hosted = undefined;
            try host.initOptions(&store, &db, seeded.data, .{ .reference_scope = &scope, .attachment_name = "source" });
            defer host.deinit();
            var app: graph.App = .{ .held = host.control };
            const registrations = [_]h.access.ContentBehavior{app.behavior()};
            host.service.contents = &registrations;
            var first: h.Answer = .{};
            try host.mutate(host.use, 1, "set", &.{.{ .integer = 11 }}, &first);
            try host.drain(&db);
            try std.testing.expectEqual(@as(?bool, true), first.changed);
            const before = store.metadata.revision;
            const stamp = try graph.stamp(&store, &db, seeded.resource);
            const prior = try history.history(&store, &db, seeded.data.owner);
            const target_owner = try h.loam.hosting.Attachment.create(h.a, &host.host, &store, &host.behaviors, .{ .reference_scope = &scope, .attachment_name = "target" });
            defer target_owner.destroy() catch unreachable;
            const lease = try h.c.load(&store, &db, seeded.data.control);
            const target = try target_owner.restore(lease);
            defer host.host.releaseCapabilityTerminal(target, null);
            try store.release(lease);
            const retains = host.host.capabilities.retainCount(target).?;
            app.held = target;
            var changed: h.Answer = .{};
            try host.mutate(host.use, 2, "set", &.{.{ .integer = 71 }}, &changed);
            const batch = try host.untilWrite(&db);
            var recipes: usize = 0;
            for (batch.changes) |change| if (change.staged) |staged| {
                if (staged.view.schema == refs.schema.id) recipes += 1;
            };
            try std.testing.expectEqual(@as(usize, 1), recipes);
            try std.testing.expect(changed.changed == null and !changed.broken);
            if (applied) try std.testing.expect(db.commit(batch) == .committed) else {
                var pending = try db.beginWrite();
                _ = try batch.apply(&pending);
                pending.abort();
            }
            var queued: h.Answer = .{};
            app.held = if (applied) target else host.control;
            if (outcome == .absent) {
                try host.attached.completeWrite(batch.ticket, .{ .unchanged = error.StorageCapacity });
            } else {
                try host.attached.completeWrite(batch.ticket, .unknown);
                try host.send(host.use, "get", &.{}, &queued);
                _ = try host.host.vat.driveIngressBudgeted(.local, 64);
                try host.attached.advance();
                try std.testing.expect(queued.number == null and !queued.broken);
                try std.testing.expect(changed.changed == null and !changed.broken);
                try std.testing.expectError(error.Busy, host.attached.destroy());
                try host.attached.resolve(batch.ticket, try db.recover(try host.attached.recoveryBatch()));
            }
            try host.drain(&db);
            try std.testing.expectEqual(applied, changed.changed != null);
            try std.testing.expectEqual(!applied, changed.broken);
            if (outcome != .absent) try std.testing.expectEqual(@as(?i64, if (applied) 71 else 11), queued.number);
            try expectGraph(&store, &db, seeded.data.content, if (applied) 71 else 11, seeded.data.control, applied);
            try std.testing.expectEqual(before + @intFromBool(applied), store.metadata.revision);
            try std.testing.expectEqual(stamp + @intFromBool(applied), try graph.stamp(&store, &db, seeded.resource));
            const next = try history.history(&store, &db, seeded.data.owner);
            try std.testing.expectEqual(prior.next_sequence + @intFromBool(applied), next.next_sequence);
            try std.testing.expectEqual(@as(usize, 0), host.attached.reference_saves);
            try std.testing.expectEqual(retains, host.host.capabilities.retainCount(target).?);
            app.held = target;
            var retry: h.Answer = .{};
            try host.mutate(host.use, 2, "set", &.{.{ .integer = 71 }}, &retry);
            try host.drain(&db);
            try std.testing.expectEqual(@as(?bool, true), retry.changed);
            try std.testing.expectEqual(@as(usize, if (applied) 2 else 3), app.invoked);
            try expectGraph(&store, &db, seeded.data.content, 71, seeded.data.control, true);
        }
        try store.deinit();
        try db.close();
        db = try fixture.open(terminated, .open, h.f.store_id);
        store = try h.loam.core.Store.init(h.a, db.metadata, &schemas, h.limits);
        try expectGraph(&store, &db, seeded.data.content, 71, seeded.data.control, true);
        var scope = try refs.Scope.init(h.a, 2);
        defer scope.deinit() catch unreachable;
        var host: h.Hosted = undefined;
        try host.initOptions(&store, &db, seeded.data, .{ .reference_scope = &scope, .attachment_name = "source" });
        defer host.deinit();
        const target_owner = try h.loam.hosting.Attachment.create(h.a, &host.host, &store, &host.behaviors, .{ .reference_scope = &scope, .attachment_name = "target" });
        defer target_owner.destroy() catch unreachable;
        const lease = try h.c.load(&store, &db, seeded.data.control);
        const target = try target_owner.restore(lease);
        defer host.host.releaseCapabilityTerminal(target, null);
        try store.release(lease);
        var app: graph.App = .{ .held = target };
        const registrations = [_]h.access.ContentBehavior{app.behavior()};
        host.service.contents = &registrations;
        var cold: h.Answer = .{};
        try host.send(host.use, "get", &.{}, &cold);
        try host.drain(&db);
        try std.testing.expectEqual(@as(?i64, 71), cold.number);
        var replay: h.Answer = .{};
        try host.mutate(host.use, 2, "set", &.{.{ .integer = 71 }}, &replay);
        try host.drain(&db);
        try std.testing.expectEqual(@as(?bool, true), replay.changed);
        try std.testing.expectEqual(@as(usize, 0), app.invoked);
    }
}
