//! Core observation authority: runtime lifetimes expire on the hosting marker.
//! Durable observers survive the same unclean restart and retain their quota.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const cases = @import("observation_cases.zig");
const loam = h.loam;
const Epoch = loam.hosting.LiveEpoch;
const Lifetime = loam.access.records.ObservationRecord.Lifetime;
const schemas = h.schemas ++ [_]loam.core.Schema{Epoch.schema};

fn lifetime(store: *loam.core.Store, backend: anytype, marker: loam.core.ObjectId) !Lifetime {
    const lease = try h.c.load(store, backend, marker);
    defer store.release(lease) catch unreachable;
    return .{ .marker = marker, .revision = (try store.currentView(lease)).revision };
}

fn closeHosted(server: *h.Hosted, scope: *loam.hosting.LiveScope) void {
    server.host.releaseCapability(server.use, 1) catch unreachable;
    server.host.releaseCapability(server.control, 1) catch unreachable;
    server.attached.destroy() catch unreachable;
    scope.deinit() catch unreachable;
    server.host.deinit();
    server.caps.deinit() catch unreachable;
}

test "access observation runtime quota reclaims after unclean reopen without retiring durable observers" {
    var backend = try loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try loam.core.Store.init(h.a, try backend.open(), &schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    const endpoint_lease = try h.c.load(&store, &backend, data.use);
    const endpoint = try loam.access.records.EndpointRecord.decode(try store.currentView(endpoint_lease));
    try store.release(endpoint_lease);
    try store.begin();
    const fresh = try Epoch.stageFresh(&store);
    try h.f.commit(&store, &backend);
    const original = try lifetime(&store, &backend, fresh.epoch.object);
    var durable: loam.core.ObjectId = undefined;
    var abandoned: loam.core.ObjectId = undefined;
    var cursor: loam.access.storage.Observation.Cursor = undefined;
    {
        var caps = try loam.access.storage.Capabilities.init(h.a, &store, .{});
        defer caps.deinit() catch unreachable;
        durable = try cases.register(&caps, &backend, endpoint.descriptor, data.resource, @splat(1));
        cursor = (try cases.poll(&caps, &backend, durable, null)).cursor;
        for (0..loam.access.records.ObservationIndexRecord.capacity - 1) |index| {
            const id = try cases.registerLifetime(&caps, &backend, endpoint.descriptor, data.resource, @splat(@intCast(index + 2)), original);
            if (index == 0) abandoned = id;
        }
        try std.testing.expectError(error.ObservationCapacity, cases.registerLifetime(&caps, &backend, endpoint.descriptor, data.resource, @splat(99), original));
    }
    // No observer is cancelled: opening a fresh Store and advancing the saved
    // Host marker are the only actions that establish the ended lifetime.
    const opening = store.metadata.incarnation;
    try store.deinit();
    try backend.close();
    store = try loam.core.Store.init(h.a, try backend.open(), &schemas, h.limits);
    try std.testing.expect(store.metadata.incarnation > opening);
    const prior = try h.c.load(&store, &backend, fresh.epoch.object);
    try store.begin();
    _ = try Epoch.stageRestart(&store, prior);
    try h.f.commit(&store, &backend);
    try store.release(prior);
    const current = try lifetime(&store, &backend, fresh.epoch.object);
    var caps = try loam.access.storage.Capabilities.init(h.a, &store, .{});
    defer caps.deinit() catch unreachable;
    const kept = try cases.poll(&caps, &backend, durable, cursor);
    try std.testing.expect(kept.snapshot.use.access == .active);
    try std.testing.expectEqualDeep(cursor, kept.cursor);
    try std.testing.expectError(error.ObservationClosed, cases.poll(&caps, &backend, abandoned, null));
    for (0..loam.access.records.ObservationIndexRecord.capacity - 1) |index| {
        _ = try cases.registerLifetime(&caps, &backend, endpoint.descriptor, data.resource, @splat(@intCast(index + 40)), current);
    }
    const closed = try h.c.load(&store, &backend, abandoned);
    try std.testing.expectEqual(@as(u32, 0), (try store.currentView(closed)).edge_count);
    try store.release(closed);
    try std.testing.expectError(error.ObservationCapacity, cases.registerLifetime(&caps, &backend, endpoint.descriptor, data.resource, @splat(100), current));
    try std.testing.expect((try cases.poll(&caps, &backend, durable, cursor)).snapshot.use.access == .active);
}

test "access observation hosted live registration fences restart and distinct concurrent requests" {
    const client_fixture = @import("sharing_fixture.zig");
    const captures = @import("description_fixture.zig");
    const Fronts = @import("observation_fixture.zig").Fronts;
    var backend = try loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try loam.core.Store.init(h.a, try backend.open(), &schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var memory = std.heap.ArenaAllocator.init(h.a);
    defer memory.deinit();
    const first_identity: [16]u8 = @splat(1);
    const second_identity: [16]u8 = @splat(2);
    const live_args = [_]h.f.glowcap.ocapn.model.Argument{ .{ .integer = 2 }, .{ .string = "observe-live" }, .{ .bytes = &first_identity } };
    var marker: loam.core.ObjectId = undefined;
    var entropy_counter: u64 = 100;
    {
        var server: h.Hosted = undefined;
        try server.init(&store, &backend, data);
        var scope = try loam.hosting.LiveScope.init(h.a, &server.host, &store, 16);
        defer closeHosted(&server, &scope);
        try scope.startHosted(server.attached, null);
        try server.drain(&backend);
        marker = scope.epoch.?.object;
        var client: client_fixture.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
        try client.init(&server);
        defer client.deinit();
        var durable: captures.Capture = .{ .arena = memory.allocator() };
        try client.send(client.parent, "mutate", &.{ .{ .integer = 1 }, .{ .string = "observe" } }, &durable);
        try server.drain(&backend);
        try client.pump();
        _ = try Fronts.from(try durable.require());
        var first: captures.Capture = .{ .arena = memory.allocator() };
        try client.send(client.parent, "mutate", &live_args, &first);
        try server.drain(&backend);
        try client.pump();
        const first_fronts = try Fronts.from(try first.require());
        var conflicting: h.Answer = .{};
        try client.send(client.parent, "mutate", &.{ .{ .integer = 2 }, .{ .string = "observe-live" }, .{ .bytes = &second_identity } }, &conflicting);
        try server.drain(&backend);
        try client.pump();
        try std.testing.expectEqualStrings("OperationConflict", conflicting.reason());
        var second: captures.Capture = .{ .arena = memory.allocator() };
        try client.send(client.parent, "mutate", &.{ .{ .integer = 3 }, .{ .string = "observe-live" }, .{ .bytes = &second_identity } }, &second);
        try server.drain(&backend);
        try client.pump();
        const second_fronts = try Fronts.from(try second.require());
        try std.testing.expect(!std.meta.eql(first_fronts.receiver, second_fronts.receiver));
        var cancelled: h.Answer = .{};
        try client.send(second_fronts.canceller, "cancel", &.{}, &cancelled);
        try server.drain(&backend);
        try client.pump();
        var first_poll: captures.Capture = .{ .arena = memory.allocator() };
        try client.send(first_fronts.receiver, "poll", &.{}, &first_poll);
        try server.drain(&backend);
        try client.pump();
        _ = try first_poll.require();
        entropy_counter = client.entropy_counter;
        // Leave the first live observer and the durable observer registered.
    }
    {
        var server: h.Hosted = undefined;
        try server.init(&store, &backend, data);
        var scope = try loam.hosting.LiveScope.init(h.a, &server.host, &store, 16);
        defer closeHosted(&server, &scope);
        try scope.startHosted(server.attached, marker);
        try server.drain(&backend);
        // Continue the fixture's deterministic entropy stream across restart.
        var client: client_fixture.Client = .{ .host = undefined, .pair = undefined, .parent = undefined, .entropy_counter = entropy_counter };
        try client.init(&server);
        defer client.deinit();
        var expired: h.Answer = .{};
        try client.send(client.parent, "mutate", &live_args, &expired);
        try server.drain(&backend);
        try client.pump();
        try std.testing.expectEqualStrings("ObservationClosed", expired.reason());
        var durable: captures.Capture = .{ .arena = memory.allocator() };
        try client.send(client.parent, "mutate", &.{ .{ .integer = 1 }, .{ .string = "observe" } }, &durable);
        try server.drain(&backend);
        try client.pump();
        const fronts = try Fronts.from(try durable.require());
        var durable_poll: captures.Capture = .{ .arena = memory.allocator() };
        try client.send(fronts.receiver, "poll", &.{}, &durable_poll);
        try server.drain(&backend);
        try client.pump();
        _ = try durable_poll.require();
        var replacement: captures.Capture = .{ .arena = memory.allocator() };
        try client.send(client.parent, "mutate", &.{ .{ .integer = 4 }, .{ .string = "observe-live" }, .{ .bytes = &second_identity } }, &replacement);
        try server.drain(&backend);
        try client.pump();
        _ = try Fronts.from(try replacement.require());
    }
}
