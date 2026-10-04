//! Managed capability calls over internal CapTP sessions and existing actors.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const pair_support = @import("../../support/host_pair.zig");
const CapturedRef = @import("../../support/capture.zig").CapturedRef;
const CapturedInt = @import("../../support/capture.zig").CapturedInt;

fn captureNestedRef(ctx: ?*anyopaque, resolution: h.actors.Resolution) void {
    if (resolution == .fulfilled and resolution.fulfilled == .list and resolution.fulfilled.list.len == 1)
        return CapturedRef.record(ctx, .{ .fulfilled = resolution.fulfilled.list[0] });
    CapturedRef.record(ctx, resolution);
}

test "loam managed hosting hands a disclosed stored reference to a CapTP caller" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    var client = h.host_support.init(h.a, @splat(0x62), h.driver.Host.Options.withFrameCap(4096));
    defer client.deinit();
    const endpoint_lease = try h.c.load(&store, &backend, data.use);
    defer store.release(endpoint_lease) catch unreachable;
    try store.begin();
    const pub_id = try h.access.stagePublication(&store, endpoint_lease, @splat(0x43));
    try h.f.commit(&store, &backend);
    const lease = try h.c.load(&store, &backend, pub_id);
    const swiss = try h.loam.hosting.publication.restore(host.attached, lease);
    try store.release(lease);
    const pair = try pair_support.openPair(&client, &host.host, "127.0.0.1:9732");
    var fetched: CapturedRef = .{};
    try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pair_support.pumpToQuiescence(&.{pair});
    const use = try fetched.require();
    // The declared disclosure crosses the wire inside a composite reply and
    // remains a callable capability.
    var disclosed: CapturedRef = .{};
    try client.vowOn(try client.send(pair.a, use, .{ .verb = "share-list", .args = &.{} }), .{ .ctx = &disclosed, .func = captureNestedRef });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    const peer = try disclosed.require();
    // It is the disclosed field's target: writes through it and reads through
    // the fetched use observe one shared content record.
    var changed: CapturedInt = .{};
    try client.vowOn(try client.send(pair.a, peer, .{ .verb = "mutate", .args = &.{ .{ .integer = 1 }, .{ .string = "add" }, .{ .integer = 5 } } }), .{ .ctx = &changed, .func = CapturedInt.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expectEqual(@as(i64, 5), changed.value.?);
    var observed: CapturedInt = .{};
    try client.vowOn(try client.send(pair.a, use, .{ .verb = "get", .args = &.{} }), .{ .ctx = &observed, .func = CapturedInt.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expectEqual(@as(i64, 5), observed.value.?);
    // The same method returning a capability it never declared breaks over the
    // wire instead of handing out the attachment's own endpoint.
    host.application.smuggle = host.use;
    defer host.application.smuggle = null;
    var smuggled: CapturedRef = .{};
    try client.vowOn(try client.send(pair.a, use, .{ .verb = "smuggle", .args = &.{} }), .{ .ctx = &smuggled, .func = CapturedRef.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expect(smuggled.broken);
    try std.testing.expectEqualStrings("UndeclaredDisclosure", smuggled.reason_buf[0..smuggled.reason_len]);
}

test "loam managed hosting returns a facet dependent on invoking and target grants" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedIndependentTarget(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    const target_control = try host.restore(&backend, data.target_control.?);
    defer host.host.releaseCapability(target_control, 1) catch unreachable;
    var client = h.host_support.init(h.a, @splat(0x62), h.driver.Host.Options.withFrameCap(4096));
    defer client.deinit();
    const endpoint_lease = try h.c.load(&store, &backend, data.use);
    defer store.release(endpoint_lease) catch unreachable;
    try store.begin();
    const pub_id = try h.access.stagePublication(&store, endpoint_lease, @splat(0x44));
    try h.f.commit(&store, &backend);
    const lease = try h.c.load(&store, &backend, pub_id);
    const swiss = try h.loam.hosting.publication.restore(host.attached, lease);
    try store.release(lease);
    const pair = try pair_support.openPair(&client, &host.host, "127.0.0.1:9733");
    var fetched: CapturedRef = .{};
    try client.vowOn(try client.fetch(pair.a, swiss.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
    try pair_support.pumpToQuiescence(&.{pair});
    const use = try fetched.require();

    var dependent: CapturedRef = .{};
    try client.vowOn(try client.send(pair.a, use, .{ .verb = "share-dependent-list", .args = &.{} }), .{ .ctx = &dependent, .func = captureNestedRef });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    const facet = try dependent.require();
    var exact: CapturedRef = .{};
    try client.vowOn(try client.send(pair.a, use, .{ .verb = "share", .args = &.{} }), .{ .ctx = &exact, .func = CapturedRef.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    const target = try exact.require();
    try std.testing.expect(!std.meta.eql(facet, target));

    var added: CapturedInt = .{};
    try client.vowOn(try client.send(pair.a, facet, .{ .verb = "mutate", .args = &.{ .{ .integer = 1 }, .{ .string = "add" }, .{ .integer = 3 } } }), .{ .ctx = &added, .func = CapturedInt.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expectEqual(@as(?i64, 3), added.value);

    // A nested dependent reply keeps the original guard, while an exact reply
    // from the target remains the stored authority and not the guard or facet.
    var nested: CapturedRef = .{};
    try client.vowOn(try client.send(pair.a, facet, .{ .verb = "share-dependent-list", .args = &.{} }), .{ .ctx = &nested, .func = captureNestedRef });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    const nested_facet = try nested.require();
    var nested_exact: CapturedRef = .{};
    try client.vowOn(try client.send(pair.a, facet, .{ .verb = "share", .args = &.{} }), .{ .ctx = &nested_exact, .func = CapturedRef.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expect(std.meta.eql(target, try nested_exact.require()));

    // Each side of the conjunction is live authority. Pausing either side
    // denies the facet while leaving the independently held other side usable.
    var paused: h.Answer = .{};
    try host.send(host.control, "pause", &.{}, &paused);
    try host.drain(&backend);
    var guard_denied: h.Answer = .{};
    try client.vowOn(try client.send(pair.a, nested_facet, .{ .verb = "get", .args = &.{} }), .{ .ctx = &guard_denied, .func = h.Answer.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expect(guard_denied.broken);
    var target_alive: CapturedInt = .{};
    try client.vowOn(try client.send(pair.a, target, .{ .verb = "get", .args = &.{} }), .{ .ctx = &target_alive, .func = CapturedInt.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expectEqual(@as(?i64, 3), target_alive.value);
    var resumed: h.Answer = .{};
    try host.send(host.control, "resume", &.{}, &resumed);
    try host.drain(&backend);
    var target_paused: h.Answer = .{};
    try host.send(target_control, "pause", &.{}, &target_paused);
    try host.drain(&backend);
    var target_denied: h.Answer = .{};
    try client.vowOn(try client.send(pair.a, facet, .{ .verb = "get", .args = &.{} }), .{ .ctx = &target_denied, .func = h.Answer.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expect(target_denied.broken);
    var source_alive: CapturedInt = .{};
    try client.vowOn(try client.send(pair.a, use, .{ .verb = "get", .args = &.{} }), .{ .ctx = &source_alive, .func = CapturedInt.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expectEqual(@as(?i64, 3), source_alive.value);
    var target_resumed: h.Answer = .{};
    try host.send(target_control, "resume", &.{}, &target_resumed);
    try host.drain(&backend);
    var revoked: h.Answer = .{};
    try host.send(host.control, "revoke", &.{}, &revoked);
    try host.drain(&backend);
    var ancestor_denied: h.Answer = .{};
    try client.vowOn(try client.send(pair.a, facet, .{ .verb = "get", .args = &.{} }), .{ .ctx = &ancestor_denied, .func = h.Answer.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expect(ancestor_denied.broken);
    var target_after_revoke: CapturedInt = .{};
    try client.vowOn(try client.send(pair.a, target, .{ .verb = "get", .args = &.{} }), .{ .ctx = &target_after_revoke, .func = CapturedInt.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expectEqual(@as(?i64, 3), target_after_revoke.value);

    // A control field is weak and undeclared authority still cannot leak.
    var weak: CapturedRef = .{};
    try client.vowOn(try client.send(pair.a, use, .{ .verb = "share-dependent-weak", .args = &.{} }), .{ .ctx = &weak, .func = CapturedRef.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expect(weak.broken);
    host.application.smuggle = target_control;
    defer host.application.smuggle = null;
    var controller: CapturedRef = .{};
    try client.vowOn(try client.send(pair.a, use, .{ .verb = "smuggle", .args = &.{} }), .{ .ctx = &controller, .func = CapturedRef.record });
    try pair_support.pumpToQuiescence(&.{pair});
    try host.drain(&backend);
    try pair_support.pumpToQuiescence(&.{pair});
    try std.testing.expect(controller.broken);
}

test "loam managed hosting held CapTP use observes pause and resume through a separate control" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    var client = h.host_support.init(h.a, @splat(0x62), h.driver.Host.Options.withFrameCap(4096));
    defer client.deinit();
    var swiss: [2]h.driver.Host.DurableSwiss = undefined;
    for ([_]h.driver.Capability{ host.use, host.control }, 0..) |ref, i| {
        const target = try host.attached.capture(ref);
        const endpoint_lease = try h.c.load(&store, &backend, target.target);
        defer store.release(endpoint_lease) catch unreachable;
        try store.begin();
        const pub_id = try h.access.stagePublication(&store, endpoint_lease, @splat(@as(u8, @intCast(i + 1))));
        try h.f.commit(&store, &backend);
        const lease = try h.c.load(&store, &backend, pub_id);
        swiss[i] = try h.loam.hosting.publication.restore(host.attached, lease);
        try store.release(lease);
    }
    const pair = try pair_support.openPair(&client, &host.host, "127.0.0.1:9730");
    var fetched = [_]CapturedRef{ .{}, .{} };
    for (&fetched, swiss) |*capture, locator| try client.vowOn(try client.fetch(pair.a, locator.slice()), .{ .ctx = capture, .func = CapturedRef.record });
    try pair_support.pumpToQuiescence(&.{pair});
    const use = try fetched[0].require();
    const control = try fetched[1].require();
    const requests = [_]struct { management: bool, verb: []const u8, broken: bool = false }{
        .{ .management = false, .verb = "get" },
        .{ .management = true, .verb = "pause" },
        .{ .management = false, .verb = "get", .broken = true },
        .{ .management = true, .verb = "resume" },
        .{ .management = false, .verb = "get" },
        .{ .management = true, .verb = "revoke" },
        .{ .management = false, .verb = "get", .broken = true },
    };
    for (requests) |request| {
        store.evict();
        var answer: h.Answer = .{};
        const target = if (request.management) control else use;
        try client.vowOn(try client.send(pair.a, target, .{ .verb = request.verb, .args = &.{} }), .{ .ctx = &answer, .func = h.Answer.record });
        try pair_support.pumpToQuiescence(&.{pair});
        try host.drain(&backend);
        try pair_support.pumpToQuiescence(&.{pair});
        try std.testing.expectEqual(request.broken, answer.broken);
        if (!request.broken) {
            if (request.management) try std.testing.expectEqual(@as(?bool, true), answer.changed) else try std.testing.expectEqual(@as(?i64, 0), answer.number);
        }
    }
}
