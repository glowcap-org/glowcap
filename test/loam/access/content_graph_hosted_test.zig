//! Managed graph and mutation receipt share the existing confirmed-write lane.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const history = @import("history_cases.zig");
const fixture = @import("content_graph_fixture.zig");
const App = fixture.App;
const seed = fixture.seed;
const stamp = fixture.stamp;
const a = std.testing.allocator;

const WithoutGraph = struct {
    backing: *h.loam.Volatile,
    pages: []const h.loam.core.ObjectId,
    attempted: usize = 0,
    pub fn read(self: *WithoutGraph, request: h.loam.core.Read) h.loam.core.ReadResult {
        for (self.pages) |page| if (page.eql(request.id)) {
            self.attempted += 1;
            return .{ .failed = error.GraphUnavailable };
        };
        return self.backing.read(request);
    }
    pub fn commit(self: *WithoutGraph, batch: h.loam.core.Batch) h.loam.core.Outcome {
        return self.backing.commit(batch);
    }
    pub fn lookup(self: *WithoutGraph, request: h.loam.core.NameLookup) h.loam.core.NameResult {
        return self.backing.lookup(request);
    }
    fn drain(self: *WithoutGraph, host: *h.Hosted) !void {
        host.drain(self) catch |err| {
            if (err != error.GraphUnavailable) return err;
            // The executor reports the failed physical read, then retires the
            // failed call and its observer through the ordinary settlement lane.
            try host.drain(self);
        };
    }
};

test "loam graph receipt replay needs current authority and receipt custody only" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const seeded = try seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, seeded.data);
    defer host.deinit();
    var app: App = .{ .held = host.control };
    const registrations = [_]h.access.ContentBehavior{app.behavior()};
    host.service.contents = &registrations;
    var answer: h.Answer = .{};
    try host.mutate(host.use, 1, "set", &.{.{ .integer = 71 }}, &answer);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?bool, true), answer.changed);
    var pages: [6]h.loam.core.ObjectId = undefined;
    {
        const lease = try h.c.load(&store, &backend, seeded.data.content);
        defer store.release(lease) catch unreachable;
        var edges = (try store.currentView(lease)).edges();
        _ = edges.next();
        for (&pages) |*page| page.* = edges.next().?.target;
        try std.testing.expect(edges.next() == null);
    }
    var unavailable: WithoutGraph = .{ .backing = &backend, .pages = &pages };
    app.references_available = false;
    store.evict();
    var replay: h.Answer = .{};
    try host.mutate(host.use, 1, "set", &.{.{ .integer = 71 }}, &replay);
    try unavailable.drain(&host);
    try std.testing.expectEqual(@as(?bool, true), replay.changed);
    try std.testing.expectEqual(@as(usize, 0), unavailable.attempted);
    try std.testing.expectEqual(@as(usize, 1), app.invoked);
    var next: h.Answer = .{};
    try host.mutate(host.use, 2, "set", &.{.{ .integer = 72 }}, &next);
    try unavailable.drain(&host);
    try std.testing.expect(next.broken);
    try std.testing.expectEqualStrings("GraphUnavailable", next.reason());
    try std.testing.expect(unavailable.attempted != 0);
    for ([_][]const u8{ "pause", "resume", "revoke" }, 1..) |verb, sequence| {
        var changed: h.Answer = .{};
        try host.mutate(host.control, @intCast(sequence), verb, &.{}, &changed);
        try unavailable.drain(&host);
        try std.testing.expectEqual(@as(?bool, true), changed.changed);
        store.evict();
        var protected: h.Answer = .{};
        try host.mutate(host.use, 1, "set", &.{.{ .integer = 71 }}, &protected);
        try unavailable.drain(&host);
        if (std.mem.eql(u8, verb, "resume")) {
            try std.testing.expectEqual(@as(?bool, true), protected.changed);
        } else try std.testing.expect(protected.broken);
    }
    try std.testing.expectEqual(@as(usize, 1), app.invoked);
}

test "loam managed content graph confirms pages receipt and one content stamp together" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const seeded = try seed(&store, &backend);
    var host: h.Hosted = undefined;
    // Compose owner-derived demand for this complete call, including the
    // application's request growth and eight-byte payload/one-field scratch.
    var bound = try h.access.invocationAllocationBound(.{
        .arguments = .{ .values = 3, .bytes = 3 },
        .reply = .{ .values = 1 },
        .verb_bytes = 6,
        .held_occurrences = 6,
        .receipt = true,
    });
    try bound.merge(try h.access.graphAllocationBound(6, 56, 6));
    try bound.merge(try h.loam.hosting.references.allocationBound(6, 1, 0));
    try bound.includeArrayGrowth(h.loam.hosting.references.Request, 7);
    try bound.include(8, 1, 1);
    try bound.include(@sizeOf(h.access.GraphField), @alignOf(h.access.GraphField), 1);
    const call_bytes = try bound.physicalBytes();
    try host.initOptions(&store, &backend, seeded.data, .{ .call_bytes = call_bytes, .pending_bytes = call_bytes, .ingress_bytes = call_bytes, .sleep_policy = .every_turn });
    defer host.deinit();
    var app: App = .{ .held = host.control };
    const registrations = [_]h.access.ContentBehavior{app.behavior()};
    host.service.contents = &registrations;
    const before = try stamp(&store, &backend, seeded.resource);
    const previous = try history.history(&store, &backend, seeded.data.owner);
    var answer: h.Answer = .{};
    try host.mutate(host.use, 1, "set", &.{.{ .integer = 71 }}, &answer);
    const batch = try host.untilWrite(&backend);
    try std.testing.expect(answer.changed == null);
    try std.testing.expectEqual(@as(usize, 1), app.invoked);
    try host.attached.completeWrite(batch.ticket, backend.commit(batch));
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?bool, true), answer.changed);
    const changed = try stamp(&store, &backend, seeded.resource);
    try std.testing.expect(changed > before);
    const committed = try history.history(&store, &backend, seeded.data.owner);
    try std.testing.expectEqual(previous.next_sequence + 1, committed.next_sequence);
    var effects = try history.batch(&store, &backend, committed.batches[committed.count - 1]);
    defer effects.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), effects.value.effects.len);
    try std.testing.expect(effects.value.effects[0] == .content);
    try std.testing.expect(effects.value.effects[0].content.id.eql(seeded.data.resource));
    store.evict();
    var restored: h.Answer = .{};
    try host.send(host.use, "get", &.{}, &restored);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?i64, 71), restored.number);
    var replay: h.Answer = .{};
    try host.mutate(host.use, 1, "set", &.{.{ .integer = 71 }}, &replay);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?bool, true), replay.changed);
    try std.testing.expectEqual(@as(usize, 1), app.invoked);
    try std.testing.expectEqual(changed, try stamp(&store, &backend, seeded.resource));
    try std.testing.expectEqual(committed.next_sequence, (try history.history(&store, &backend, seeded.data.owner)).next_sequence);
}

test "loam managed graph row-family bound admits exact capacity and refuses one fewer" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    const seeded = blk: {
        defer backend.close() catch unreachable;
        var initial = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
        defer initial.deinit() catch unreachable;
        break :blk try seed(&initial, &backend);
    };
    const managed = try h.c.storage.stage.contentStagingSizeBound(1, true);
    const graph_rows = 7; // Six child writes and their root.
    const rows = managed.changes + graph_rows;
    try std.testing.expectEqual(@as(usize, 13), rows);
    var limits = h.limits;
    var graph_bytes: usize = 0;
    for (h.schemas) |schema| if (schema.id == 7) {
        graph_bytes = try schema.encodedSizeBound();
    };
    limits.staging_bytes = managed.staging_bytes + graph_rows * graph_bytes;
    limits.records.max_record_bytes = @max(managed.record_bytes, graph_bytes);
    for ([_]usize{ rows - 1, rows }) |capacity| {
        defer backend.close() catch unreachable;
        limits.max_changes = capacity;
        var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, limits);
        defer store.deinit() catch unreachable;
        var host: h.Hosted = undefined;
        try host.init(&store, &backend, seeded.data);
        defer host.deinit();
        var app: App = .{ .held = host.control };
        const registrations = [_]h.access.ContentBehavior{app.behavior()};
        host.service.contents = &registrations;
        const before = store.metadata.revision;
        const content = try stamp(&store, &backend, seeded.resource);
        const prior = try history.history(&store, &backend, seeded.data.owner);
        var answer: h.Answer = .{};
        try host.mutate(host.use, 1, "set", &.{.{ .integer = 71 }}, &answer);
        if (capacity < rows) {
            try host.drain(&backend);
            try std.testing.expect(answer.broken);
            try std.testing.expectEqualStrings("ChangeCapacity", answer.reason());
            try std.testing.expectEqual(before, store.metadata.revision);
            try std.testing.expectEqual(content, try stamp(&store, &backend, seeded.resource));
            try std.testing.expectEqual(prior.next_sequence, (try history.history(&store, &backend, seeded.data.owner)).next_sequence);
            try std.testing.expectEqual(@as(usize, 0), store.count);
            var sequence: h.Answer = .{};
            try host.send(host.use, "mutation-sequence", &.{}, &sequence);
            try host.drain(&backend);
            try std.testing.expectEqual(@as(?i64, 1), sequence.number);
            var unchanged: h.Answer = .{};
            try host.send(host.use, "get", &.{}, &unchanged);
            try host.drain(&backend);
            try std.testing.expectEqual(@as(?i64, 0), unchanged.number);
            continue;
        }
        const batch = try host.untilWrite(&backend);
        // This fixture captures one same-Store endpoint, so no recipe row is
        // created. Every row belongs to the graph or the managed contribution.
        try std.testing.expectEqual(rows, batch.changes.len);
        var application_rows: usize = 0;
        const families = [_]u64{
            h.loam.access.records.profile.resource,
            h.loam.access.records.profile.owner,
            h.loam.access.records.profile.change_batch,
            h.loam.access.records.profile.change_history,
            h.loam.access.records.profile.mutation,
            h.loam.access.records.profile.endpoint,
        };
        var managed_rows: [families.len]usize = @splat(0);
        var bytes: usize = 0;
        for (batch.changes) |change| {
            const view = try h.loam.core.RecordView.decode(change.bytes.?, limits.records, &h.schemas);
            if (view.schema == 7) {
                application_rows += 1;
            } else {
                const index = std.mem.indexOfScalar(u64, &families, view.schema) orelse return error.UnexpectedSchema;
                managed_rows[index] += 1;
            }
            bytes += change.bytes.?.len;
            try std.testing.expect(change.bytes.?.len <= limits.records.max_record_bytes);
        }
        try std.testing.expectEqual(graph_rows, application_rows);
        for (managed_rows) |count| try std.testing.expectEqual(@as(usize, 1), count);
        try std.testing.expect(bytes <= limits.staging_bytes);
        try host.attached.completeWrite(batch.ticket, backend.commit(batch));
        try host.drain(&backend);
        try std.testing.expectEqual(@as(?bool, true), answer.changed);
        store.evict();
        var replay: h.Answer = .{};
        try host.mutate(host.use, 1, "set", &.{.{ .integer = 71 }}, &replay);
        try host.drain(&backend);
        try std.testing.expectEqual(@as(?bool, true), replay.changed);
        try std.testing.expectEqual(@as(usize, 1), app.invoked);
        var changed: h.Answer = .{};
        try host.send(host.use, "get", &.{}, &changed);
        try host.drain(&backend);
        try std.testing.expectEqual(@as(?i64, 71), changed.number);
    }
}

test "loam managed content graph aborts partial staging without publishing a receipt" {
    for ([_]bool{ false, true }) |late| {
        var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
        defer backend.deinit();
        var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        const seeded = try seed(&store, &backend);
        var host: h.Hosted = undefined;
        try host.init(&store, &backend, seeded.data);
        defer host.deinit();
        var app: App = .{ .held = host.control };
        const registrations = [_]h.access.ContentBehavior{app.behavior()};
        host.service.contents = &registrations;
        const before = store.metadata.revision;
        const content = try stamp(&store, &backend, seeded.resource);
        // Refuse either the second page or the managed participants after every
        // page and the root have staged. Both paths must retire the whole call.
        const example: h.loam.core.Record = .{ .id = seeded.data.content, .revision = before + 1, .schema = 7, .payload = &@as([8]u8, @splat(0)), .edges = &.{ .{ .target = seeded.resource }, .{ .target = seeded.data.control } } };
        const encoded = try example.encodeAlloc(a, store.limits.records, store.cache.schemas);
        defer a.free(encoded);
        var root_record = example;
        root_record.edges = &@as([7]h.loam.core.Edge, @splat(.{ .target = seeded.resource }));
        const root_bytes = try root_record.encodeAlloc(a, store.limits.records, store.cache.schemas);
        defer a.free(root_bytes);
        store.limits.staging_bytes = if (late) 6 * encoded.len + root_bytes.len else encoded.len + encoded.len / 2;
        const retained = host.host.capabilities.retainCount(host.control).?;
        const prior = try history.history(&store, &backend, seeded.data.owner);
        var refused: h.Answer = .{};
        try host.mutate(host.use, 1, "set", &.{.{ .integer = 71 }}, &refused);
        try host.drain(&backend);
        try std.testing.expect(refused.broken);
        try std.testing.expectEqualStrings("RecordTooLarge", refused.reason());
        try std.testing.expectEqual(@as(usize, 0), host.attached.reference_saves);
        try std.testing.expectEqual(retained, host.host.capabilities.retainCount(host.control).?);
        try std.testing.expectEqual(prior.next_sequence, (try history.history(&store, &backend, seeded.data.owner)).next_sequence);
        try std.testing.expectEqual(before, store.metadata.revision);
        try std.testing.expectEqual(content, try stamp(&store, &backend, seeded.resource));
        try std.testing.expectEqual(@as(usize, 0), store.count);
        try std.testing.expectEqual(.idle, store.phase);
        var sequence: h.Answer = .{};
        try host.send(host.use, "mutation-sequence", &.{}, &sequence);
        try host.drain(&backend);
        try std.testing.expectEqual(@as(?i64, 1), sequence.number);
        store.limits.staging_bytes = h.limits.staging_bytes;
        var retry: h.Answer = .{};
        try host.mutate(host.use, 1, "set", &.{.{ .integer = 71 }}, &retry);
        try host.drain(&backend);
        try std.testing.expectEqual(@as(?bool, true), retry.changed);
        var replay: h.Answer = .{};
        try host.mutate(host.use, 1, "set", &.{.{ .integer = 71 }}, &replay);
        try host.drain(&backend);
        try std.testing.expectEqual(@as(?bool, true), replay.changed);
        try std.testing.expectEqual(@as(usize, 2), app.invoked);
    }
}
