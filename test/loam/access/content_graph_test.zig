//! Shared graph ownership and atomic replacement, with two cache slots for six pages.
const std = @import("std");
const loam = @import("glowcap").loam;
const graph = loam.access.hosting.graph;
const f = @import("../core/fixture.zig");
const a = std.testing.allocator;
const spec: graph.Spec = .{ .schemas = &.{.{ .id = 7 }}, .max_pages = 7, .max_payload_bytes = 1024, .max_edges = 32 };

const Seed = struct { root: loam.core.ObjectId, resource: loam.core.ObjectId, pages: [6]loam.core.ObjectId };
fn seed(fixture: *f.Fixture) !Seed {
    return seedFields(fixture, false);
}

fn seedFields(fixture: *f.Fixture, fields: bool) !Seed {
    const store = &fixture.store;
    try store.begin();
    const resource = try store.allocateId();
    var row = f.record(resource, "resource");
    row.rooted = true;
    try store.putCopying(row, null);
    const root = try store.allocateId();
    var pages: [6]loam.core.ObjectId = undefined;
    var links: [7]loam.core.Edge = undefined;
    links[0] = .{ .target = resource };
    for (&pages, links[1..], 0..) |*page, *link, index| {
        page.* = try store.allocateId();
        link.* = .{ .target = page.* };
        var payload: [1]u8 = .{@intCast(index)};
        row = f.record(page.*, &payload);
        row.edges = if (fields) &.{ .{ .target = resource }, .{ .target = resource } } else &.{.{ .target = resource }};
        try store.putCopying(row, null);
    }
    row = f.record(root, "root");
    row.rooted = true;
    row.edges = &links;
    try store.putCopying(row, null);
    try f.commit(store, &fixture.backend);
    return .{ .root = root, .resource = resource, .pages = pages };
}

test "loam graph allocation bound covers observed cold copies and complete staged edges" {
    var fixture = try f.Fixture.init(a);
    defer fixture.deinit();
    const data = try seedFields(&fixture, true);
    const bound = try graph.allocationBound(6, 13, 6);
    var memory: loam.hosting.Call.Memory = undefined;
    memory.init(a, try bound.physicalBytes());
    defer memory.deinit();
    var traffic: @import("../../support/alloc_metrics.zig").AllocationTraffic(loam.hosting.references.AllocationBound) = .{ .backing = memory.working.allocator() };
    const store = &fixture.store;
    const root = try f.load(store, &fixture.backend, data.root);
    defer store.release(root) catch unreachable;
    const prepared = try graph.Prepared.create(store, traffic.allocator(), spec, try store.currentView(root), data.resource);
    try std.testing.expectEqual(@as(usize, 6), try pump(prepared, &fixture.backend));
    var candidates: [6]graph.Replacement = undefined;
    for (&candidates) |*candidate| candidate.* = .{ .write = .{ .schema = .{ .id = 7 }, .payload = "x", .fields = &.{.{ .edge = .{ .target = data.resource } }} } };
    const delta = (try prepared.replacement("changed", &candidates)).?;
    try store.begin();
    defer if (store.phase == .staging) store.abort() catch unreachable;
    try delta.stage(store);
    try std.testing.expectEqual(@as(usize, 7), store.count);
    try f.commit(store, &fixture.backend);
    try std.testing.expect(traffic.demand.bytes <= bound.bytes);
    try std.testing.expect(traffic.demand.allocations <= bound.allocations);
    try std.testing.expectError(error.Overflow, graph.allocationBound(std.math.maxInt(usize), 0, 0));
}

fn pump(prepared: *graph.Prepared, backend: *loam.Volatile) !usize {
    var reads: usize = 0;
    for (0..32) |_| switch (try prepared.advanceCopying()) {
        .read => |read| {
            reads += 1;
            try prepared.completeRead(read.ticket, backend.read(read));
        },
        .ready => return reads,
        .waiting => return error.UnexpectedWait,
    };
    return error.NoProgress;
}

test "loam content graph updates payload without restoring or replacing exact fields" {
    var fixture = try f.Fixture.init(a);
    defer fixture.deinit();
    const data = try seedFields(&fixture, true);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const store = &fixture.store;
    var root = try f.load(store, &fixture.backend, data.root);
    defer store.release(root) catch unreachable;
    const prepared = try graph.Prepared.create(store, arena.allocator(), spec, try store.currentView(root), data.resource);
    _ = try pump(prepared, &fixture.backend);
    const pages = prepared.snapshot.pages;
    var candidate: [6]graph.Replacement = undefined;
    for (pages, &candidate) |*page, *out| out.* = .{ .keep = page.handle() };
    candidate[1] = .{ .update = .{ .page = pages[1].handle(), .payload = pages[1].view.payload } };
    try std.testing.expect(try prepared.replacement("root", &candidate) == null);
    candidate[1].update.payload = "settled";
    try std.testing.expectError(error.DuplicatePage, prepared.replacement("root", &.{ candidate[1], .{ .keep = pages[1].handle() } }));
    var foreign: graph.Page = .{ .view = pages[1].view };
    try std.testing.expectError(error.ForeignPage, prepared.replacement("root", &.{.{ .update = .{ .page = foreign.handle(), .payload = "x" } }}));
    const delta = (try prepared.replacement("root", &candidate)).?;
    try store.begin();
    try delta.stage(store);
    try std.testing.expectEqual(@as(usize, 2), store.count);
    try f.commit(store, &fixture.backend);
    try store.release(root);
    root = try f.load(store, &fixture.backend, data.root);
    const restored = try graph.Prepared.create(store, arena.allocator(), spec, try store.currentView(root), data.resource);
    _ = try pump(restored, &fixture.backend);
    const updated = restored.snapshot.pages[1].view;
    try std.testing.expect(updated.id.eql(data.pages[1]));
    try std.testing.expectEqualStrings("settled", updated.payload);
    try std.testing.expectEqualSlices(u8, pages[1].view.edge_bytes, updated.edge_bytes);
}

test "loam graph retained fields exclude bindings and preserve exact recipe edges" {
    const resource: loam.core.ObjectId = .{ .store = f.id, .incarnation = 1, .sequence = 1 };
    const saved: loam.core.ObjectId = .{ .store = f.id, .incarnation = 1, .sequence = 2 };
    var row = f.record(resource, "field selection");
    row.revision = 1;
    row.edges = &.{ .{ .target = resource }, .{ .target = saved, .restoration = .recipe }, .{ .target = saved, .strength = .weak } };
    const bytes = try row.encodeAlloc(a, f.limits.records, &f.schemas);
    defer a.free(bytes);
    const view = try loam.records.View.decode(bytes, f.limits.records, &f.schemas);
    const pages = [_]graph.Page{.{ .view = view }};
    const snapshot: graph.Snapshot = .{ .pages = &pages };
    try std.testing.expectEqualDeep(row.edges[1], try snapshot.field(pages[0].handle(), 0));
    try std.testing.expectError(error.NotDurable, snapshot.field(pages[0].handle(), 1));
    try std.testing.expectError(error.NoSuchEdge, snapshot.field(pages[0].handle(), 2));
    try std.testing.expectError(error.Overflow, snapshot.field(pages[0].handle(), std.math.maxInt(usize)));
    var foreign: graph.Page = .{ .view = view };
    try std.testing.expectError(error.ForeignPage, snapshot.field(foreign.handle(), 0));
}

test "loam content graph streams cold pages and commits one complete replacement" {
    var fixture = try f.Fixture.init(a);
    defer fixture.deinit();
    const data = try seed(&fixture);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const store = &fixture.store;
    var root = try f.load(store, &fixture.backend, data.root);
    defer store.release(root) catch unreachable;
    const prepared = try graph.Prepared.create(store, arena.allocator(), spec, try store.currentView(root), data.resource);
    try std.testing.expectEqual(@as(usize, 6), try pump(prepared, &fixture.backend));
    try std.testing.expectEqual(@as(usize, 2), store.cache.slots.len);
    for (prepared.snapshot.pages, 0..) |page, index| {
        try std.testing.expect(page.view.id.eql(data.pages[index]));
        try std.testing.expectEqual(@as(u8, @intCast(index)), page.view.payload[0]);
    }
    const pages = prepared.snapshot.pages;
    const keep = [_]graph.Replacement{ .{ .keep = pages[0].handle() }, .{ .keep = pages[1].handle() }, .{ .keep = pages[2].handle() }, .{ .keep = pages[3].handle() }, .{ .keep = pages[4].handle() }, .{ .keep = pages[5].handle() } };
    try std.testing.expect(try prepared.replacement("root", &keep) == null);
    const candidate = [_]graph.Replacement{ .{ .keep = pages[2].handle() }, .{ .write = .{ .schema = .{ .id = 7 }, .payload = "new custody", .fields = &.{.{ .edge = .{ .target = data.resource } }} } } };
    const delta = (try prepared.replacement("next root", &candidate)).?;
    try store.begin();
    try delta.stage(store);
    // Only one fresh page plus its root; unchanged pages are not re-staged.
    try std.testing.expectEqual(@as(usize, 2), store.count);
    try f.commit(store, &fixture.backend);
    try std.testing.expectError(error.RevisionConflict, prepared.replacement("root", &keep));
    try store.release(root);
    root = try f.load(store, &fixture.backend, data.root);
    const current = try store.currentView(root);
    try std.testing.expectEqualStrings("next root", current.payload);
    const restored = try graph.Prepared.create(store, arena.allocator(), spec, current, data.resource);
    _ = try pump(restored, &fixture.backend);
    try std.testing.expectEqual(@as(usize, 2), restored.snapshot.pages.len);
    try std.testing.expect(restored.snapshot.pages[0].view.id.eql(data.pages[2]));
    try std.testing.expectEqualStrings("new custody", restored.snapshot.pages[1].view.payload);
    try std.testing.expectEqual(@as(usize, 2), restored.snapshot.pages[1].view.edge_count);
}

test "loam content graph refuses invalid candidates before transaction or retained copy" {
    var fixture = try f.Fixture.init(a);
    defer fixture.deinit();
    const data = try seed(&fixture);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const store = &fixture.store;
    const root = try f.load(store, &fixture.backend, data.root);
    defer store.release(root) catch unreachable;
    const prepared = try graph.Prepared.create(store, arena.allocator(), spec, try store.currentView(root), data.resource);
    _ = try pump(prepared, &fixture.backend);
    const keep = prepared.snapshot.pages[0].handle();
    try std.testing.expectError(error.DuplicatePage, prepared.replacement("root", &.{ .{ .keep = keep }, .{ .keep = keep } }));
    var foreign: graph.Page = .{ .view = prepared.snapshot.pages[0].view };
    try std.testing.expectError(error.ForeignPage, prepared.replacement("root", &.{.{ .keep = foreign.handle() }}));
    try std.testing.expectError(error.UnsupportedSchema, prepared.replacement("root", &.{.{ .write = .{ .schema = .{ .id = 8 }, .payload = "", .fields = &.{} } }}));
    try std.testing.expectError(error.PayloadTooLarge, prepared.replacement(&@as([257]u8, @splat(0)), &.{}));
    const limited = try graph.Prepared.create(store, arena.allocator(), spec, try store.currentView(root), data.resource);
    _ = try pump(limited, &fixture.backend);
    limited.spec.max_edges = 1;
    try std.testing.expectError(error.GraphCapacity, limited.replacement("root", &.{.{ .keep = limited.snapshot.pages[0].handle() }}));
    try std.testing.expectEqual(.idle, store.phase);
    try std.testing.expectEqual(@as(usize, 0), store.count);
}

test "loam content graph refuses capability links and foreign page bindings" {
    for ([_]enum { recipe, weak, duplicate, foreign, rooted }{ .recipe, .weak, .duplicate, .foreign, .rooted }) |fault| {
        var fixture = try f.Fixture.init(a);
        defer fixture.deinit();
        const data = try seed(&fixture);
        const store = &fixture.store;
        var root = try f.load(store, &fixture.backend, data.root);
        defer store.release(root) catch unreachable;
        const old = try store.currentView(root);
        var links: [7]loam.core.Edge = undefined;
        var iterator = old.edges();
        for (&links) |*edge| edge.* = iterator.next().?;
        switch (fault) {
            .recipe => links[1].restoration = .recipe,
            .weak => links[1].strength = .weak,
            .duplicate => links[2] = links[1],
            .foreign => {},
            .rooted => links[1].target = data.resource,
        }
        try store.begin();
        var row = f.record(data.root, old.payload);
        row.rooted = true;
        row.edges = &links;
        try store.putCopying(row, old.revision);
        if (fault == .foreign) {
            const page = try f.load(store, &fixture.backend, data.pages[0]);
            defer store.release(page) catch unreachable;
            const view = try store.currentView(page);
            row = f.record(view.id, view.payload);
            row.edges = &.{.{ .target = data.root }};
            try store.putCopying(row, view.revision);
        }
        try f.commit(store, &fixture.backend);
        try store.release(root);
        root = try f.load(store, &fixture.backend, data.root);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        if (fault == .recipe or fault == .weak) {
            try std.testing.expectError(error.InvalidPageLink, graph.Prepared.create(store, arena.allocator(), spec, try store.currentView(root), data.resource));
        } else {
            const prepared = try graph.Prepared.create(store, arena.allocator(), spec, try store.currentView(root), data.resource);
            try std.testing.expectError(switch (fault) {
                .duplicate => error.DuplicatePage,
                .foreign => error.InvalidResourceBinding,
                else => error.InvalidPage,
            }, pump(prepared, &fixture.backend));
        }
    }
}
