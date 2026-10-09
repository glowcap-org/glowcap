//! Prepared exact fields do not make recipe population a residency requirement.
const std = @import("std");
const f = @import("fixture.zig");
const records = @import("../core/fixture.zig");
const refs = f.hosting.references;
const a = std.testing.allocator;
const schemas = f.schemas ++ [_]f.loam.core.Schema{refs.schema};

test "loam saved proof stages one recipe per transaction and never reuses an aborted ID" {
    for ([_]bool{ false, true }) |prepared_save| {
        var backend = try f.loam.Volatile.init(a, records.id, 1024 * 1024);
        defer backend.deinit();
        var store = try f.loam.core.Store.init(a, try backend.open(), &schemas, records.limits);
        defer store.deinit() catch unreachable;
        var scope = try refs.Scope.init(a, 2);
        defer scope.deinit() catch unreachable;
        var host = @import("../../support/core_host.zig").init(a, @splat(0x72), .{});
        defer host.deinit();
        const source = try f.hosting.Attachment.create(a, &host, &store, &f.behaviors, .{ .reference_scope = &scope, .attachment_name = "source" });
        defer source.destroy() catch unreachable;
        const target = try f.hosting.Attachment.create(a, &host, &store, &f.behaviors, .{ .reference_scope = &scope, .attachment_name = "target" });
        defer target.destroy() catch unreachable;
        try store.begin();
        const id = try store.allocateId();
        var row = records.record(id, &@as([8]u8, @splat(0)));
        row.rooted = true;
        try store.putCopying(row, null);
        try records.commit(&store, &backend);
        const lease = try records.load(&store, &backend, id);
        defer store.release(lease) catch unreachable;
        const held = try target.restore(lease);
        defer host.releaseCapabilityTerminal(held, null);
        const baseline = host.capabilities.retainCount(held).?;
        var memory: f.hosting.Call.Memory = undefined;
        memory.init(a, 1024 * 1024);
        defer memory.deinit();
        var call: f.hosting.Call = .{ .memory = &memory, .attachment = source, .view = try store.currentView(lease) };
        defer call.release();
        const captured = if (prepared_save) blk: {
            const working = try refs.Set.create(&call, call.view, &.{.{ .save = .{ .capability = held } }});
            try std.testing.expect(try working.advance() == .ready);
            const first = try working.captured(held);
            const before = host.capabilities.retainCount(held).?;
            try std.testing.expectEqual(first.saved, (try working.captured(held)).saved);
            try std.testing.expectEqual(before, host.capabilities.retainCount(held).?);
            break :blk first;
        } else blk: {
            const save = try refs.beginSave(source, a, held, null);
            defer save.deinit();
            // The independently owned Save retires before staging. The call
            // must own its copied recipe and capability, including its bytes.
            break :blk try refs.copySaved(&call, save);
        };
        try store.begin();
        const aborted = try captured.saved.stage(&store);
        try std.testing.expectEqualDeep(aborted, try captured.saved.stage(&store));
        try std.testing.expectEqual(@as(usize, 1), store.count);
        try store.abort();
        try store.begin();
        const committed = try captured.saved.stage(&store);
        try std.testing.expect(!aborted.target.eql(committed.target));
        try std.testing.expectEqualDeep(committed, try captured.saved.stage(&store));
        try std.testing.expectEqual(@as(usize, 1), store.count);
        row = records.record(try store.allocateId(), &@as([8]u8, @splat(0)));
        row.rooted = true;
        row.edges = &.{ committed, committed };
        try store.putCopying(row, null);
        try records.commit(&store, &backend);
        try std.testing.expectEqual(@as(u64, 3), store.metadata.objects);
        const recipe_lease = try records.load(&store, &backend, committed.target);
        defer store.release(recipe_lease) catch unreachable;
        const recipe = try store.currentView(recipe_lease);
        try std.testing.expectEqualStrings("\x00target", recipe.payload);
        try std.testing.expectEqualDeep(id, (try refs.edgeAt(recipe, 0)).target);
        call.release();
        try std.testing.expectEqual(baseline, host.capabilities.retainCount(held).?);
    }
}

test "loam reference preparation restores more cold recipes than cache slots" {
    for ([_]bool{ false, true }) |refuse_last| {
        var backend = try f.loam.Volatile.init(a, records.id, 1024 * 1024);
        defer backend.deinit();
        var store = try f.loam.core.Store.init(a, try backend.open(), &schemas, records.limits);
        defer store.deinit() catch unreachable;
        var scope = try refs.Scope.init(a, 2);
        defer scope.deinit() catch unreachable;
        var host = @import("../../support/core_host.zig").init(a, @splat(0x72), .{});
        defer host.deinit();
        const source = try f.hosting.Attachment.create(a, &host, &store, &f.behaviors, .{ .reference_scope = &scope, .attachment_name = "source" });
        defer source.destroy() catch unreachable;
        const target = try f.hosting.Attachment.create(a, &host, &store, &f.behaviors, .{ .reference_scope = &scope, .attachment_name = "target" });
        defer target.destroy() catch unreachable;
        try store.begin();
        const id = try store.allocateId();
        var row = records.record(id, &@as([8]u8, @splat(0)));
        row.rooted = true;
        try store.putCopying(row, null);
        var edges: [6]f.loam.core.Edge = undefined;
        for (&edges) |*edge| {
            const recipe = try store.allocateId();
            try store.putCopying(.{ .id = recipe, .revision = 0, .schema = refs.schema.id, .payload = "\x00target", .edges = &.{.{ .target = id }} }, null);
            edge.* = .{ .target = recipe, .restoration = .recipe };
        }
        const page = try store.allocateId();
        row = records.record(page, &@as([8]u8, @splat(0)));
        row.rooted = true;
        row.edges = &edges;
        try store.putCopying(row, null);
        try records.commit(&store, &backend);
        var memory: f.hosting.Call.Memory = undefined;
        memory.init(a, 1024 * 1024);
        defer memory.deinit();
        const target_lease = try records.load(&store, &backend, id);
        const held = try target.restore(target_lease);
        defer host.releaseCapabilityTerminal(held, null);
        var root = try store.currentView(target_lease);
        root.payload = try memory.working.allocator().dupe(u8, root.payload);
        root.edge_bytes = try memory.working.allocator().dupe(u8, root.edge_bytes);
        try store.release(target_lease);
        store.evict();
        const lease = try records.load(&store, &backend, page);
        defer store.release(lease) catch unreachable;
        const view = try store.currentView(lease);
        var call: f.hosting.Call = .{ .memory = &memory, .attachment = source, .view = root };
        defer call.release();
        const views = [_]f.loam.core.RecordView{ root, view };
        var requests: [6]refs.Request = undefined;
        for (&requests, 0..) |*request, index| request.* = .{ .restore_record = .{ .record = 1, .index = index, .retain_uri = index % 2 == 0 } };
        const baseline = host.capabilities.retainCount(held).?;
        const working = try refs.Set.createViews(&call, &views, &requests);
        var reads: usize = 0;
        for (0..16) |_| switch (try working.advance()) {
            .read => |read| {
                reads += 1;
                if (refuse_last and reads == requests.len) {
                    try std.testing.expectError(error.InjectedRead, working.completeRead(read.ticket, .{ .failed = error.InjectedRead }));
                    break;
                }
                try working.completeRead(read.ticket, backend.read(read));
            },
            .waiting => return error.UnexpectedWait,
            .ready => break,
        };
        try std.testing.expectEqual(requests.len, reads);
        try std.testing.expectEqual(@as(usize, 2), store.cache.slots.len);
        if (!refuse_last) for (0..requests.len) |index| {
            try std.testing.expect((try call.storedEdge(view, index)).eql(held));
            if (index % 2 == 0) {
                try std.testing.expectEqual(@as(?[]const u8, null), try working.restoredUri(view, index));
            } else {
                try std.testing.expectError(error.ReferenceUnprepared, working.restoredUri(view, index));
            }
            var stale = view;
            stale.revision += 1;
            try std.testing.expectError(error.ReferenceUnprepared, working.restoredUri(stale, index));
            const captured = try working.captured(held);
            try std.testing.expect(captured == .edge);
            try std.testing.expectEqualDeep(edges[0], captured.edge);
        };
        call.release();
        try std.testing.expectEqual(baseline, host.capabilities.retainCount(held).?);
    }
}
