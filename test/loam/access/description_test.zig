//! Held access snapshots reveal current restrictions without owner activity.
//! Replacing effective policy with configured policy was injected and detected.
const std = @import("std");
const d = @import("description_fixture.zig");
const h = d.h;
const f = d.f;

test "loam descriptions fit maximum policy metadata within the default call budget" {
    const Policy = h.c.core.Policy;
    var permissions: [Policy.max_permissions]Policy.Key = undefined;
    for (&permissions, 0..) |*key, i| key.* = @fromBackingInt(std.math.maxInt(u64) - permissions.len + i);
    var constraints: [Policy.max_constraints]Policy.Constraint = undefined;
    var bounds: [Policy.max_constraints]Policy.Bound = undefined;
    for (&constraints, &bounds, 0..) |*field, *bound, i| {
        field.* = .{ .key = @fromBackingInt(std.math.maxInt(u64) - constraints.len + i), .operator = if (i % 2 == 0) .lower_bound else .upper_bound };
        bound.* = .{ .key = field.key, .value = std.math.maxInt(u64) };
    }
    const policy = try Policy.init(.{ .id = @fromBackingInt(std.math.maxInt(u128)), .permissions = &permissions, .constraints = &constraints });
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedPolicy(&store, &backend, 0, policy, &bounds);
    var server: h.Hosted = undefined;
    try server.init(&store, &backend, data);
    defer server.deinit();
    var memory = std.heap.ArenaAllocator.init(h.a);
    defer memory.deinit();
    var capture: d.Capture = .{ .arena = memory.allocator() };
    try d.sendLocal(&server, &capture);
    try server.drain(&backend);
    const snapshot = try capture.require();
    try d.expectStatus(snapshot, "active");
    try std.testing.expectEqualStrings("340282366920938463463374607431768211455", snapshot.tagged.value[1].big_integer.digits);
    for (snapshot.tagged.value[2..5]) |value| {
        try std.testing.expectEqual(Policy.max_permissions, value.tagged.value[0].list.len);
        try std.testing.expectEqual(Policy.max_constraints, value.tagged.value[1].list.len);
        for (value.tagged.value[0].list) |key| try std.testing.expect(key == .big_integer and key.big_integer.isCanonical());
    }
    try std.testing.expectEqual(@as(usize, 0), server.attached.pending_bytes);
}

test "loam descriptions expose effective keys and retain no revoked policy" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedDepth(&store, &backend, 2);
    var server: h.Hosted = undefined;
    try server.init(&store, &backend, data);
    defer server.deinit();
    var client: f.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
    try client.init(&server);
    defer client.deinit();
    var memory = std.heap.ArenaAllocator.init(h.a);
    defer memory.deinit();
    const arena = memory.allocator();
    const child = try client.derive(&server, &backend, 1, 1, 1);
    const narrowed = try h.f.vocabulary.terms(.{ .object = data.resource }, &.{h.f.vocabulary.read}, 42);
    _ = try h.f.change(&store, &backend, data.owner, .{ .set_policy = .{ .grant = data.grant, .terms = narrowed } });
    store.evict();
    const snapshot = try d.describe(&client, &server, &backend, child, arena);
    try d.expectStatus(snapshot, "active");
    const fields = snapshot.tagged.value;
    try std.testing.expectEqual(@as(i64, 11), fields[1].integer);
    try std.testing.expectEqual(@as(usize, 2), fields[3].tagged.value[0].list.len);
    const effective = fields[4].tagged.value;
    try std.testing.expectEqual(@as(usize, 1), effective[0].list.len);
    try std.testing.expectEqual(@as(i64, 10), effective[0].list[0].integer);
    const bound = effective[1].list[0].tagged.value;
    try std.testing.expectEqual(@as(i64, 100), bound[0].integer);
    try std.testing.expectEqualStrings("lower_bound", bound[1].symbol);
    try std.testing.expectEqual(@as(i64, 42), bound[2].integer);
    const revision = store.metadata.revision;
    const again = try d.describe(&client, &server, &backend, child, arena);
    try std.testing.expectEqual(revision, store.metadata.revision);
    try std.testing.expectEqualDeep(snapshot, again);
    // Another grant changes the owner's global event/revision, not this reply.
    _ = try h.f.change(&store, &backend, data.owner, .{ .issue_root = h.f.vocabulary.issue(narrowed, 0) });
    try std.testing.expectEqualDeep(snapshot, try d.describe(&client, &server, &backend, child, arena));
    var selector: d.Capture = .{ .arena = arena };
    try client.send(child, "describe-access", &.{.{ .integer = 0 }}, &selector);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expect(selector.failed);
    const wide = try h.f.vocabulary.terms(.{ .object = data.resource }, &.{h.f.vocabulary.read}, std.math.maxInt(u64));
    _ = try h.f.change(&store, &backend, data.owner, .{ .set_policy = .{ .grant = data.grant, .terms = wide } });
    const large = try d.describe(&client, &server, &backend, child, arena);
    const limit = large.tagged.value[4].tagged.value[1].list[0].tagged.value[2];
    try std.testing.expect(limit == .big_integer and !limit.big_integer.negative);
    try std.testing.expectEqualStrings("18446744073709551615", limit.big_integer.digits);
    for ([_][]const u8{ "pause", "resume", "revoke" }, [_][]const u8{ "paused", "active", "revoked" }) |verb, status| {
        var changed: h.Answer = .{};
        try server.send(server.control, verb, &.{}, &changed);
        try server.drain(&backend);
        store.evict();
        try d.expectStatus(try d.describe(&client, &server, &backend, child, arena), status);
    }
    try std.testing.expectEqual(@as(usize, 0), server.caps.operations);
    store.evict();
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
}

test "loam descriptions restart when revocation overtakes queued inspection" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var server: h.Hosted = undefined;
    try server.init(&store, &backend, data);
    defer server.deinit();
    var memory = std.heap.ArenaAllocator.init(h.a);
    defer memory.deinit();
    var snapshot: d.Capture = .{ .arena = memory.allocator() };
    try d.sendLocal(&server, &snapshot);
    _ = try server.host.vat.driveIngressBudgeted(.local, 64);
    for (0..64) |_| {
        try server.attached.advance();
        if (server.attached.operations[0].phase == .scheduled) break;
        const work = (try server.attached.nextWork()) orelse return error.NoProgress;
        try std.testing.expect(work == .read);
        try server.attached.completeRead(work.read.ticket, backend.read(work.read));
    }
    try std.testing.expect(server.attached.operations[0].phase == .scheduled);
    _ = try h.f.change(&store, &backend, data.owner, .{ .revoke = data.grant });
    try server.drain(&backend);
    try d.expectStatus(try snapshot.require(), "revoked");
    try std.testing.expectEqual(@as(u64, 1), server.attached.stats.invocations);
}
