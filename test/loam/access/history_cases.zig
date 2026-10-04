//! Integrated retention through the same native owner and Store boundaries.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const f = h.f;
const records = h.loam.access.records;
const c = h.c;
const m = @import("management_fixture.zig");

pub fn history(store: *h.loam.core.Store, backend: anytype, owner: h.loam.core.ObjectId) !records.ChangeHistoryRecord {
    var read = try c.storage.Read.init(store.allocator, store, owner, 1);
    defer read.deinit() catch unreachable;
    read.history_requested = true;
    _ = try f.pump(&read, backend);
    return read.history;
}

pub fn batch(store: *h.loam.core.Store, backend: anytype, id: h.loam.core.ObjectId) !records.ChangeBatchRecord.Owned {
    const lease = try c.load(store, backend, id);
    defer store.release(lease) catch unreachable;
    return records.ChangeBatchRecord.decodeOwned(store.allocator, try store.currentView(lease));
}

pub fn composed(store: *h.loam.core.Store, backend: anytype) !void {
    for ([_]bool{ false, true }) |commit| {
        const data = try h.seed(store, backend);
        const before = try history(store, backend, data.owner);
        var caps = try c.storage.Capabilities.init(store.allocator, store, .{});
        defer caps.deinit() catch unreachable;
        const endpoint_lease = try c.load(store, backend, data.control);
        const endpoint = try records.EndpointRecord.decode(try store.currentView(endpoint_lease));
        try store.release(endpoint_lease);
        const control = try c.control(&caps, backend, endpoint.descriptor);
        defer control.release();
        const operation = try control.begin(8);
        defer operation.deinit() catch unreachable;
        try std.testing.expect(try m.prepareRevocation(operation, backend));
        try store.begin();
        defer if (store.phase == .staging) store.abort() catch unreachable;
        try std.testing.expect(try operation.stageControlRevocation());
        {
            var read = try c.storage.Read.init(store.allocator, store, data.owner, 8);
            defer read.deinit() catch unreachable;
            _ = try f.pump(&read, backend);
            var child: c.core.ResourceId = undefined;
            {
                var append = try c.storage.Append.init(&read, .resource);
                defer append.deinit() catch unreachable;
                _ = try f.pump(&append, backend);
                child = try f.stageResource(&append, &read, backend, f.vocabulary.kind, data.resource);
            }
            const terms = try f.vocabulary.terms(.{ .object = child }, &.{f.vocabulary.read}, null);
            {
                var plan = (try f.prepare(&read, backend, .{ .issue_root = f.vocabulary.issue(terms, 0) })).?;
                defer plan.deinit(store.allocator);
                var append = try c.storage.Append.init(&read, .grant);
                defer append.deinit() catch unreachable;
                _ = try f.pump(&append, backend);
                _ = try c.storage.stage.grant(&read, &plan, &append);
            }
            // The content participant and its resource stamp share this batch.
            const lease = try c.load(store, backend, data.content);
            const view = try store.currentView(lease);
            var edges: [8]h.loam.core.Edge = undefined;
            var iterator = view.edges();
            var count: usize = 0;
            while (iterator.next()) |edge| {
                edges[count] = edge;
                count += 1;
            }
            try store.putCopying(.{ .id = view.id, .revision = 0, .schema = view.schema, .payload = &@as([8]u8, @splat(1)), .edges = edges[0..count], .rooted = view.rooted }, view.revision);
            try store.release(lease);
            try c.storage.stage.contentChanged(&read, data.resource);
            try std.testing.expectEqual(before.next_sequence + 1, read.history.next_sequence);
            const proposed = (try store.proposed(read.history.batches[read.history.count - 1])).?;
            var changes = try records.ChangeBatchRecord.decodeOwned(store.allocator, proposed.view);
            defer changes.deinit(store.allocator);
            try std.testing.expectEqual(@as(usize, 4), changes.value.effects.len);
            try std.testing.expect(changes.value.effects[0] == .control);
            try std.testing.expect(changes.value.effects[1] == .resource);
            try std.testing.expect(changes.value.effects[2] == .grant);
            try std.testing.expect(changes.value.effects[3] == .content);
            if (commit) try f.commit(store, backend) else try store.abort();
            try std.testing.expectError(error.RevisionConflict, read.advance());
        }
        const after = try history(store, backend, data.owner);
        try std.testing.expectEqual(before.next_sequence + @intFromBool(commit), after.next_sequence);
    }
}

pub fn capacity(store: *h.loam.core.Store, backend: anytype) !void {
    const owner = try f.create(store, backend, @fromBackingInt(43));
    const initial = store.metadata.objects;
    var read = try c.storage.Read.init(store.allocator, store, owner, 8);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    try store.begin();
    for (0..records.ChangeBatchRecord.max_effects + 1) |index| {
        var append = try c.storage.Append.init(&read, .resource);
        defer append.deinit() catch unreachable;
        _ = try f.pump(&append, backend);
        try f.prepareResource(&append, &read, backend, null);
        if (index == records.ChangeBatchRecord.max_effects) {
            try std.testing.expectError(error.ChangeCapacity, c.storage.stage.appendResource(&append, f.vocabulary.kind, null));
            try std.testing.expectEqual(.idle, store.phase);
            try std.testing.expectError(error.RevisionConflict, read.advance());
            try std.testing.expectError(error.RevisionConflict, read.resourceView());
        } else _ = try c.storage.stage.appendResource(&append, f.vocabulary.kind, null);
    }
    try std.testing.expectEqual(initial, store.metadata.objects);
    const retained = try history(store, backend, owner);
    try std.testing.expectEqual(@as(usize, 0), retained.count);
}

pub fn overflow(store: *h.loam.core.Store, backend: anytype, collect: anytype) !void {
    const owner = try f.create(store, backend, @fromBackingInt(44));
    _ = try f.resource(store, backend, owner, null);
    const first = (try history(store, backend, owner)).batches[0];
    for (0..39) |_| _ = try f.resource(store, backend, owner, null);
    const retained = try history(store, backend, owner);
    try std.testing.expectEqual(@as(usize, 32), retained.count);
    try std.testing.expectEqual(@as(u64, 9), retained.firstSequence());
    try collect(store, backend);
    try std.testing.expectError(error.Gone, c.load(store, backend, first));
    for (retained.batches[0..retained.count], 0..) |id, index| {
        var value = try batch(store, backend, id);
        defer value.deinit(store.allocator);
        try std.testing.expectEqual(retained.firstSequence() + index, value.value.sequence);
        try std.testing.expectEqual(@as(usize, 1), value.value.effects.len);
    }
}
