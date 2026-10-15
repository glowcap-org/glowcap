//! Scoped stamps distinguish content, placement, authority and inventory changes.
const std = @import("std");
const r = @import("resource_fixture.zig");
const h = r.h;
const f = r.f;
const records = h.loam.access.records;
const cases = @import("history_cases.zig");

pub const depth_limits: h.loam.core.Store.Limits = blk: {
    var limits = h.limits;
    limits.cache_slots = 80;
    limits.max_leases = 80;
    limits.resident_bytes = 80 * 64 * 1024;
    limits.max_changes = 256;
    break :blk limits;
};

fn resource(store: *h.loam.core.Store, backend: anytype, owner: h.loam.core.ObjectId, id: f.core.ResourceId) !records.ResourceRecord {
    var read = try f.storage.Read.init(store.allocator, store, owner, 1);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    for (0..128) |_| {
        var view = try read.resourceView();
        _ = view.get(id) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try f.pump(&read, backend);
            continue;
        };
        const binding = (try read.binding(.{ .resource = id })).?;
        return records.ResourceRecord.decode((try f.storage.Read.rowFor(store, binding)).?.view);
    }
    return error.NoProgress;
}

const GrantStamps = struct { authority: u64, inventory: u64 };

fn grant(store: *h.loam.core.Store, backend: anytype, owner: h.loam.core.ObjectId, id: f.core.GrantId) !GrantStamps {
    var read = try f.storage.Read.init(store.allocator, store, owner, 1);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    for (0..128) |_| {
        var view = try read.grantView();
        _ = view.borrow(id) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try f.pump(&read, backend);
            continue;
        };
        defer view.release();
        const row = read.heldRow();
        return .{ .authority = row.authority.revision, .inventory = row.inventory.revision };
    }
    return error.NoProgress;
}

pub fn stamps(store: *h.loam.core.Store, backend: anytype) !void {
    const seed = try r.seed(store, backend);
    const owner = seed.data.owner;
    const root_before = try resource(store, backend, owner, seed.root);
    const leaf_before = try resource(store, backend, owner, seed.leaf);
    const other_before = try resource(store, backend, owner, seed.other);
    {
        var server: h.Hosted = undefined;
        try server.init(store, backend, seed.data);
        defer server.deinit();
        var answer: h.Answer = .{};
        try server.mutate(server.use, 1, "add", &.{.{ .integer = 1 }}, &answer);
        try server.drain(backend);
        try std.testing.expectEqual(@as(?i64, 1), answer.number);
    }
    const leaf_content = try resource(store, backend, owner, seed.leaf);
    const root_content = try resource(store, backend, owner, seed.root);
    try std.testing.expect(leaf_content.content.revision > leaf_before.content.revision);
    try std.testing.expectEqual(leaf_content.content.revision, leaf_content.subtree.revision);
    try std.testing.expectEqual(leaf_content.content.revision, root_content.subtree.revision);
    try std.testing.expectEqual(leaf_before.placement.revision, leaf_content.placement.revision);
    try std.testing.expectEqual(root_before.placement.revision, root_content.placement.revision);
    try std.testing.expectEqual(root_before.content.revision, root_content.content.revision);
    try std.testing.expectEqualDeep(other_before, try resource(store, backend, owner, seed.other));

    try std.testing.expect(try r.change(store, backend, owner, seed.leaf, .{ .move = seed.other }));
    const leaf_moved = try resource(store, backend, owner, seed.leaf);
    const root_moved = try resource(store, backend, owner, seed.root);
    const other_moved = try resource(store, backend, owner, seed.other);
    try std.testing.expect(leaf_moved.placement.revision > leaf_content.placement.revision);
    try std.testing.expectEqual(leaf_moved.placement.revision, root_moved.subtree.revision);
    try std.testing.expectEqual(leaf_moved.placement.revision, other_moved.subtree.revision);
    try std.testing.expectEqual(leaf_content.content.revision, leaf_moved.content.revision);
    try std.testing.expectEqual(root_before.placement.revision, root_moved.placement.revision);
    try std.testing.expectEqual(other_before.placement.revision, other_moved.placement.revision);
    // Returning to the old parent cannot recreate an earlier scoped state stamp.
    try std.testing.expect(try r.change(store, backend, owner, seed.leaf, .{ .move = seed.root }));
    try std.testing.expect((try resource(store, backend, owner, seed.leaf)).placement.revision > leaf_moved.placement.revision);

    const root_grant = try grant(store, backend, owner, seed.data.grant);
    const terms = try f.vocabulary.terms(.{ .owned_subtree = seed.root }, &.{f.vocabulary.read}, null);
    const child = (try f.change(store, backend, owner, .{ .derive = .{ .parent = seed.data.grant, .request = f.vocabulary.issue(terms, 1) } })).?.grant;
    const child_before = try grant(store, backend, owner, child);
    const grandchild = (try f.change(store, backend, owner, .{ .derive = .{ .parent = child, .request = f.vocabulary.issue(terms, 0) } })).?.grant;
    const latest = try grant(store, backend, owner, grandchild);
    const child_after = try grant(store, backend, owner, child);
    const root_after = try grant(store, backend, owner, seed.data.grant);
    try std.testing.expectEqual(latest.authority, latest.inventory);
    try std.testing.expectEqual(latest.inventory, child_after.inventory);
    try std.testing.expectEqual(latest.inventory, root_after.inventory);
    try std.testing.expectEqual(child_before.authority, child_after.authority);
    try std.testing.expectEqual(root_grant.authority, root_after.authority);
    _ = try f.change(store, backend, owner, .{ .pause = grandchild });
    try std.testing.expect((try grant(store, backend, owner, grandchild)).authority > latest.authority);
    try std.testing.expectEqual(root_after.authority, (try grant(store, backend, owner, seed.data.grant)).authority);
}

pub fn depth(store: *h.loam.core.Store, backend: anytype) !void {
    const policy = try f.core.Policy.init(f.vocabulary.descriptor);
    try store.begin();
    try std.testing.expectError(error.DepthLimit, f.storage.stage.createOwner(store, @fromBackingInt(45), policy, .{ .max_resource_depth = 65 }));
    try std.testing.expectEqual(.staging, store.phase);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
    try std.testing.expectError(error.DepthLimit, f.storage.stage.createOwner(store, @fromBackingInt(45), policy, .{ .max_grant_depth = 65 }));
    try store.abort();
    const owner = try f.create(store, backend, @fromBackingInt(45));
    var parent: ?f.core.ResourceId = null;
    for (0..65) |_| parent = try appendDepthResource(store, backend, owner, parent);
    const retained = try cases.history(store, backend, owner);
    var last = try cases.batch(store, backend, retained.batches[retained.count - 1]);
    defer last.deinit(store.allocator);
    try std.testing.expectEqual(@as(usize, 65), last.value.effects[0].resource.after.len);
    var read = try f.storage.Read.init(store.allocator, store, owner, 70);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    var append = try f.storage.Append.init(&read, .resource);
    defer append.deinit() catch unreachable;
    _ = try f.pump(&append, backend);
    try std.testing.expectError(error.DepthLimit, f.prepareResource(&append, &read, backend, parent));
    try std.testing.expectEqualDeep(retained, try cases.history(store, backend, owner));
}

/// Maximum-depth scenarios reserve the complete path instead of the ordinary
/// fixture's six bindings. The Store limits still own admission.
pub fn appendDepthResource(store: *h.loam.core.Store, backend: anytype, owner: h.loam.core.ObjectId, parent: ?f.core.ResourceId) !f.core.ResourceId {
    var read = try f.storage.Read.init(store.allocator, store, owner, 70);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    var append = try f.storage.Append.init(&read, .resource);
    defer append.deinit() catch unreachable;
    _ = try f.pump(&append, backend);
    try f.prepareResource(&append, &read, backend, parent);
    try store.begin();
    errdefer if (store.phase == .staging) store.abort() catch unreachable;
    const result = try f.storage.stage.appendResource(&append, f.vocabulary.kind, parent);
    try f.commit(store, backend);
    return result;
}
