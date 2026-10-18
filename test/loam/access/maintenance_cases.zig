//! Churn reuses delegation capacity while retaining irreversible identity floors.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const f = h.f;
const c = h.c;
const r = @import("resource_fixture.zig");
const native = @import("maintenance_fixture.zig");

pub fn churn(store: *h.loam.core.Store, backend: anytype, collect: anytype) !void {
    const policy = try c.core.Policy.init(f.vocabulary.descriptor);
    try store.begin();
    const owner = try c.storage.stage.createOwner(store, @fromBackingInt(73), policy, .{ .max_grant_children = 1 });
    try f.commit(store, backend);
    const root = try f.resource(store, backend, owner, null);
    const wide = try f.vocabulary.terms(.{ .owned_subtree = root }, &.{ f.vocabulary.read, f.vocabulary.post }, null);
    const parent = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(wide, 1) })).?.grant;
    var caps = try c.storage.Capabilities.init(store.allocator, store, .{});
    defer caps.deinit() catch unreachable;
    const source_id = try c.descriptor(&caps, backend, owner, parent, null, .reachable);
    const source = try c.use(&caps, backend, source_id);
    defer source.release();
    var sequence: u64 = 0;
    var steady_objects: ?u64 = null;
    var steady_bytes: ?u64 = null;
    for (0..32) |cycle| {
        const leaf = try f.resource(store, backend, owner, root);
        const terms = try f.vocabulary.terms(.{ .object = leaf }, &.{ f.vocabulary.read, f.vocabulary.post }, null);
        const child = (try f.change(store, backend, owner, .{ .derive = .{ .parent = parent, .request = f.vocabulary.issue(terms, 0) } })).?.grant;
        const descriptor = try c.descriptor(&caps, backend, owner, child, null, .reachable);
        {
            var read: c.storage.Read = undefined;
            try read.init(store.allocator, store, owner, 1, null);
            defer read.deinit() catch unreachable;
            try h.prepareEndpointOwner(&read, backend, 1);
            const lease = try c.load(store, backend, descriptor);
            defer store.release(lease) catch unreachable;
            try store.begin();
            const content = try store.allocateId();
            try store.putCopying(.{ .id = content, .revision = 0, .schema = 7, .payload = &@as([256]u8, @splat(0xa1)) }, null);
            _ = try h.access.stageEndpoint(&read, store.allocator, .{ .descriptor = descriptor, .content = .{ .resource = leaf, .object = content } }, .rooted);
            try f.commit(store, backend);
        }
        {
            var read: c.storage.Read = undefined;
            try read.init(store.allocator, store, owner, 4, null);
            defer read.deinit() catch unreachable;
            _ = try f.pump(&read, backend);
            var removal = try r.prepare(&read, backend, leaf, .delete_leaf);
            defer removal.deinit() catch unreachable;
            _ = try f.pump(&removal, backend);
            try store.begin();
            _ = try removal.stage();
            try f.commit(store, backend);
        }
        _ = try f.change(store, backend, owner, .{ .revoke = child });
        const result = try native.finish(store, backend, owner, .sweep, sequence);
        sequence = result.sequence;
        try collect(store, backend);
        // The retained journal saturates before this interval. Both logical
        // record count and payload bytes then stay bounded while floors grow.
        if (cycle == 16) {
            steady_objects = store.metadata.objects;
            steady_bytes = store.metadata.record_bytes;
        } else if (cycle > 16) {
            try std.testing.expectEqual(steady_objects.?, store.metadata.objects);
            try std.testing.expect(store.metadata.record_bytes <= steady_bytes.? + 512);
        }
        var read: c.storage.Read = undefined;
        try read.init(store.allocator, store, owner, 4, null);
        defer read.deinit() catch unreachable;
        _ = try f.pump(&read, backend);
        try std.testing.expectEqual(@as(u64, cycle + 2), read.header.next_resource);
        try std.testing.expectEqual(@as(u64, cycle + 2), read.header.next_grant);
        try std.testing.expectEqual(@as(u64, 2 * (cycle + 1) + 1), read.header.next_identity);
        var grants = try read.grantView();
        for (0..32) |_| {
            const record = grants.borrow(parent) catch |err| {
                if (err != error.RecordUnloaded) return err;
                _ = try f.pump(&read, backend);
                continue;
            };
            defer grants.release();
            try std.testing.expectEqual(@as(u32, 0), record.child_count);
            break;
        } else return error.NoProgress;
    }
}
