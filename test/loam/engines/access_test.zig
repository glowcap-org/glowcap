//! Native atomic record participation, not a durable capability owner. This
//! fixture keeps its exact Loam object references. No ID-to-capability lookup
//! or control/publication restoration is implied by the record round trip.
const structural_policy = @import("../access/grant_fixture.zig").structural_policy;
const std = @import("std");
const glowcap = @import("glowcap");
const loam = glowcap.loam.core;
const access = glowcap.loam.access.core;
const records = glowcap.loam.access.records;
const fixture = @import("engine_fixture");
const f = @import("loam_test_support");
const a = std.testing.allocator;
const schemas = [_]loam.Schema{
    .{ .id = 7, .version = 1, .max_payload = records.GrantRecord.max_encoded_bytes, .max_edges = 8 },
    .{ .id = records.profile.change_batch, .version = 1, .max_payload = records.ChangeBatchRecord.max_encoded_bytes, .max_edges = 0 },
};
const limits: loam.Store.Limits = .{ .records = .{ .max_record_bytes = 33 * 1024, .max_edges = 8 }, .cache_slots = 2, .max_leases = 2, .resident_bytes = 66 * 1024, .max_changes = 8, .staging_bytes = 128 * 1024 };

const Source = struct {
    grant: access.GrantLedger.Record,
    resources: access.Revision,

    fn view(self: *const Source) access.GrantView {
        return access.GrantView.init(.{ .owner = self.grant.id.owner, .revisions = .{ .resources = self.resources, .grants = self.grant.revision } }, 4, .{ .context = self, .lend = lend });
    }

    fn lend(context: *const anyopaque, id: access.GrantId) access.GrantView.SourceError!access.GrantView.Reply {
        const self: *const Source = @ptrCast(@alignCast(context));
        return .{ .version = self.view().version, .value = if (id.eql(self.grant.id)) .{ .present = &self.grant } else .{ .absent = .unknown } };
    }
};

fn loadGrant(store: *loam.Store, db: *fixture.Engine, id: loam.ObjectId) !records.GrantRecord {
    const lease = try f.load(store, db, id);
    defer store.release(lease) catch unreachable;
    var value: records.GrantRecord = undefined;
    try value.decodeOwned(a, (try store.currentView(lease)).payload);
    return value;
}

fn putEncoded(store: *loam.Store, id: loam.ObjectId, value: anytype, expected: ?u64, edges: []const loam.Edge) !void {
    const payload = try value.encodeAlloc(a);
    defer a.free(payload);
    var row = f.record(id, payload);
    row.edges = edges;
    if (@TypeOf(value) == records.ChangeBatchRecord) row.schema = records.profile.change_batch;
    try store.putCopying(row, expected);
}

test "loam engine commits access content and change records together through uncertain completion and reopen" {
    for ([_]bool{ false, true }) |commit_write| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", a);
        defer a.free(path);
        const terminated = try a.dupeSentinel(u8, path, 0);
        defer a.free(terminated);
        var db = try fixture.open(terminated, .create, f.id);
        defer db.close() catch unreachable;
        var store = try loam.Store.init(a, db.metadata, &schemas, limits);
        defer store.deinit() catch unreachable;
        var graph = try access.Graph.init(a, @fromBackingInt(71), .{ .capacity = 1 });
        defer graph.deinit() catch unreachable;
        const resource = try graph.create(graph.revision(), &structural_policy, @fromBackingInt(1), null);
        const permission: access.Policy.Key = @fromBackingInt(1);
        const policy = try access.Policy.init(.{ .id = @fromBackingInt(1), .permissions = &.{permission} });
        const terms: access.Terms = .{ .scope = .{ .object = resource }, .policy = try policy.value(&.{permission}, &.{}) };
        const initial: access.GrantLedger.Record = .{
            .id = .{ .owner = graph.owner, .slot = 0, .generation = 1 },
            .parent = null,
            .ceiling = terms,
            .configured = terms,
            .status = .active,
            .revision = @fromBackingInt(7),
            .delegation_depth = 0,
            .child_count = 0,
        };
        try store.begin();
        const resource_object = try store.allocateId();
        const grant_object = try store.allocateId();
        const content_object = try store.allocateId();
        const resource_record: records.ResourceRecord = .{ .revision = graph.revision(), .resource = .{ .id = resource, .kind = @fromBackingInt(1), .parent = null } };
        try putEncoded(&store, resource_object, resource_record, null, &.{});
        try putEncoded(&store, grant_object, records.GrantRecord{ .grant = initial }, null, &.{.{ .target = resource_object }});
        var content = f.record(content_object, "before revocation");
        content.rooted = true;
        content.edges = &.{.{ .target = grant_object }};
        try store.putCopying(content, null);
        try f.commit(&store, &db);
        const original_row_revision = store.metadata.revision;
        // An unrelated write advances the Loam snapshot without changing
        // these rows or the access owner's logical revision pair.
        try store.begin();
        const unrelated = try store.allocateId();
        try store.putCopying(f.record(unrelated, "ordinary object"), null);
        try f.commit(&store, &db);
        store.evict();
        var loaded = try loadGrant(&store, &db, grant_object);
        defer loaded.deinit(a);
        const source: Source = .{ .grant = loaded.grant, .resources = graph.revision() };
        var grants = source.view();
        var resources = graph.readView();
        const req: access.Policy.Requirement = .{ .permissions = &.{permission} };
        try grants.require(&resources, &policy, initial.id, resource, req);
        // One owner holds this revision through staging. Content facts and the
        // grant plan were read at it; Loam owns the single commit/recovery path.
        try store.begin();
        var plan = (try access.GrantPlan.prepareCopying(a, &grants, &resources, &policy, 4, null, .{ .revoke = initial.id })).?;
        defer plan.deinit(a);
        const changes = try plan.changes(&grants);
        try std.testing.expectEqual(@as(?access.Revision, @fromBackingInt(7)), changes.expected);
        try std.testing.expectEqual(@as(access.Revision, @fromBackingInt(8)), changes.event.version.grants);
        const event_object = try store.allocateId();
        try putEncoded(&store, grant_object, records.GrantRecord{ .grant = changes.record }, original_row_revision, &.{.{ .target = resource_object }});
        try putEncoded(&store, event_object, records.ChangeBatchRecord{ .owner = graph.owner, .commit_revision = 3, .sequence = 1, .effects = &.{.{ .grant = .{ .change = changes.event, .path = &.{initial.id} } }} }, null, &.{});
        content.payload = "revocation committed";
        content.edges = &.{ .{ .target = grant_object }, .{ .target = event_object } };
        try store.putCopying(content, original_row_revision);
        const ticket = try store.prepare();
        const batch = try store.beginWrite(ticket);
        if (commit_write) {
            try std.testing.expect(db.commit(batch) == .committed);
        } else {
            var pending = try db.beginWrite();
            _ = try batch.apply(&pending);
            pending.abort();
        }
        try store.completeWrite(ticket, .unknown);
        try std.testing.expectError(error.RecoveryRequired, store.acquire(grant_object));
        try std.testing.expectError(error.RecoveryRequired, store.acquire(event_object));
        try store.resolve(ticket, try db.recover(try store.recoveryBatch()));
        try std.testing.expectEqual(@as(u64, if (commit_write) 3 else 2), store.metadata.revision);
        try store.deinit();
        try db.close();
        db = try fixture.open(terminated, .open, f.id);
        store = try loam.Store.init(a, db.metadata, &schemas, limits);
        try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
        var restored = try loadGrant(&store, &db, grant_object);
        defer restored.deinit(a);
        const restored_source: Source = .{ .grant = restored.grant, .resources = graph.revision() };
        grants = restored_source.view();
        if (commit_write) {
            try std.testing.expectError(error.Revoked, grants.require(&resources, &policy, initial.id, resource, req));
            const lease = try f.load(&store, &db, event_object);
            const row = try store.currentView(lease);
            var event: records.ChangeBatchRecord = undefined;
            try event.decodeOwned(a, row);
            defer event.deinit(a);
            try std.testing.expectEqualDeep(changes.event, event.effects[0].grant.change);
            try std.testing.expectEqual(grants.version.revisions.grants, event.effects[0].grant.change.version.grants);
            try std.testing.expectEqual(@as(u64, 3), row.revision);
            try store.release(lease);
        } else {
            try grants.require(&resources, &policy, initial.id, resource, req);
            try std.testing.expectError(error.Gone, f.load(&store, &db, event_object));
        }
        const lease = try f.load(&store, &db, content_object);
        const row = try store.currentView(lease);
        try std.testing.expectEqualStrings(if (commit_write) "revocation committed" else "before revocation", row.payload);
        try std.testing.expectEqual(@as(u64, if (commit_write) 3 else 1), row.revision);
        try store.release(lease);
        store.evict();
        try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    }
}
