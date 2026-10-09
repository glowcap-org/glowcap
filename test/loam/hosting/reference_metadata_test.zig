//! Recipe inspection describes committed custody without reviving its exporter.
const std = @import("std");
const f = @import("fixture.zig");
const records = @import("../core/fixture.zig");
const refs = f.hosting.references;
const a = std.testing.allocator;

test "loam recipe inspection outlives exporters and never restores authority" {
    const uri = "ocapn://unreachable.invalid.tcp/s/cmV0aXJlZA";
    for ([_]bool{ false, true }) |foreign| {
        var backend = try f.loam.Volatile.init(a, records.id, 1024 * 1024);
        defer backend.deinit();
        const schemas = f.schemas ++ [_]f.loam.core.Schema{refs.schema};
        var store = try f.loam.core.Store.init(a, try backend.open(), &schemas, records.limits);
        defer store.deinit() catch unreachable;
        var host = @import("../../support/core_host.zig").init(a, @splat(0x73), .{});
        defer host.deinit();
        // No local reference scope or foreign dial provider exists. Metadata
        // remains useful after revocation, including on this unconnected Host.
        const source = try f.hosting.Attachment.create(a, &host, &store, &f.behaviors, .{});
        defer source.destroy() catch unreachable;
        try store.begin();
        const id = try store.allocateId();
        var edges: [6]f.loam.core.Edge = undefined;
        for (&edges) |*edge| {
            const recipe = try store.allocateId();
            try store.putCopying(.{
                .id = recipe,
                .revision = 0,
                .schema = refs.schema.id,
                .payload = if (foreign) "\x01" ++ uri else "\x00missing-exporter",
                .edges = if (foreign) &.{} else &.{.{ .target = id }},
            }, null);
            edge.* = .{ .target = recipe, .restoration = .recipe };
        }
        var row = records.record(id, &@as([8]u8, @splat(0)));
        row.rooted = true;
        row.edges = &edges;
        try store.putCopying(row, null);
        try records.commit(&store, &backend);
        store.evict();
        const lease = try records.load(&store, &backend, id);
        defer store.release(lease) catch unreachable;
        const view = try store.currentView(lease);
        var memory: f.hosting.Call.Memory = undefined;
        memory.init(a, 1024 * 1024);
        defer memory.deinit();
        var call: f.hosting.Call = .{ .memory = &memory, .attachment = source, .view = view };
        defer call.release();
        var requests: [6]refs.Request = undefined;
        for (&requests, 0..) |*request, index| request.* = .{ .restore_record = .{
            .record = 0,
            .index = index,
            .retain_uri = true,
            .metadata_only = true,
        } };
        const set = try refs.Set.create(&call, view, &requests);
        var reads: usize = 0;
        for (0..16) |_| switch (try set.advance()) {
            .ready => break,
            .read => |read| {
                reads += 1;
                try set.completeRead(read.ticket, backend.read(read));
            },
            .waiting => return error.UnexpectedWait,
        } else return error.PreparationDidNotFinish;
        try std.testing.expectEqual(edges.len, reads);
        try std.testing.expectEqual(@as(usize, 2), store.cache.slots.len);
        for (0..edges.len) |index| {
            if (foreign) try std.testing.expectEqualStrings(uri, (try set.restoredUri(view, index)).?) else try std.testing.expect((try set.restoredUri(view, index)) == null);
            try std.testing.expectError(error.ReferenceUnprepared, set.restored(view, index));
            var stale = view;
            stale.revision += 1;
            try std.testing.expectError(error.ReferenceUnprepared, set.restoredUri(stale, index));
        }
    }
}
