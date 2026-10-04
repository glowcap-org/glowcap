//! Exact held foreign authority, transactional refusal and dependent forwarding.
const std = @import("std");
const f = @import("reference_fixture.zig");
const h = f.h;
const a = std.testing.allocator;

test "loam managed fields append from empty custody and refuse schema capacity atomically" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &f.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    try f.fields(&store, &backend, data.content, 0);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    host.service.contents = &f.contents;
    var peer = h.host_support.init(a, @splat(0x66), .{});
    defer peer.deinit();
    const pair = try f.pairs.openPair(&host.host, &peer, "127.0.0.1:9792");
    const target = try host.restore(&backend, data.use);
    defer host.host.releaseCapabilityTerminal(target, null);
    for (0..8) |_| {
        const call = try host.host.callCapability(a, pair.a, host.use, "append", &.{ .{ .integer = 0 }, .{ .capability = target } }, 4096);
        defer call.deinit();
        try finishCall(&host, &backend, pair, call);
        try std.testing.expect(call.result().ready.boolean);
    }
    const before = store.metadata;
    const refused = try host.host.callCapability(a, pair.a, host.use, "append", &.{ .{ .integer = 0 }, .{ .capability = target } }, 4096);
    defer refused.deinit();
    try finishCall(&host, &backend, pair, refused);
    try std.testing.expect(refused.result() == .failed);
    try std.testing.expectEqualDeep(before, store.metadata);
    const lease = try h.c.load(&store, &backend, data.content);
    defer store.release(lease) catch unreachable;
    const view = try store.currentView(lease);
    try std.testing.expectEqual(@as(usize, 8), view.edge_count);
    const exact = try host.host.callCapability(a, pair.a, host.use, "ref", &.{.{ .integer = 7 }}, 4096);
    defer exact.deinit();
    try finishCall(&host, &backend, pair, exact);
    try std.testing.expect(exact.result().ready.capability.eql(target));
}

fn finishCall(host: *h.Hosted, backend: *h.loam.Volatile, pair: f.pairs.Pair, call: *h.driver.Host.Call) !void {
    for (0..256) |_| {
        try host.host.flushSession(pair.a);
        try pair.bh.flushSession(pair.b);
        try f.pairs.pumpToQuiescence(&.{pair});
        try host.drain(backend);
        if (call.result() != .pending) return;
    }
    return error.DidNotSettle;
}

test "loam foreign fields preserve exact authority, nested forwarding and both grant checks" {
    var source_backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer source_backend.deinit();
    var source_store = try h.loam.core.Store.init(a, try source_backend.open(), &f.schemas, h.limits);
    defer source_store.deinit() catch unreachable;
    const source_data = try h.seed(&source_store, &source_backend);
    var target_backend = try h.loam.Volatile.init(a, @fromBackingInt(93), 16 * 1024 * 1024);
    defer target_backend.deinit();
    var target_store = try h.loam.core.Store.init(a, try target_backend.open(), &h.schemas, h.limits);
    defer target_store.deinit() catch unreachable;
    const target_data = try h.seed(&target_store, &target_backend);
    var source: h.Hosted = undefined;
    try source.init(&source_store, &source_backend, source_data);
    defer source.deinit();
    var dependent_declarations: usize = 0;
    var registrations = f.contents;
    registrations[0].context = &dependent_declarations;
    source.service.contents = &registrations;
    var target: h.Hosted = undefined;
    try target.initIdentity(&target_store, &target_backend, target_data, .{ .sleep_policy = .every_turn }, @splat(0x65));
    defer target.deinit();
    const name = try f.publication(&target, &target_backend, target_data.use, @splat(0x71));
    const pair = try f.pairs.openPair(&source.host, &target.host, "127.0.0.1:9791");
    const original = try f.fetch(&source, &source_backend, &target, &target_backend, pair, name);
    defer source.host.releaseCapabilityTerminal(original, null);
    const uri = try f.uri(a, name);
    defer a.free(uri);
    const put = try f.send(&source, &source_backend, &target, &target_backend, pair, source.use, "put", &.{ .{ .integer = 0 }, .{ .capability = original }, .{ .string = uri } });
    defer put.deinit();
    try std.testing.expect(put.result().ready.boolean);
    const exact = try f.send(&source, &source_backend, &target, &target_backend, pair, source.use, "ref", &.{.{ .integer = 0 }});
    defer exact.deinit();
    try std.testing.expect(exact.result().ready.capability.eql(original));
    const dependent = try f.send(&source, &source_backend, &target, &target_backend, pair, source.use, "dependent", &.{.{ .integer = 0 }});
    defer dependent.deinit();
    const facet = dependent.result().ready.capability;
    const read = try f.send(&source, &source_backend, &target, &target_backend, pair, facet, "get", &.{});
    defer read.deinit();
    try std.testing.expectEqual(@as(i64, 0), read.result().ready.integer);
    try std.testing.expectEqual(@as(usize, 1), dependent_declarations);
    const nested = try f.send(&source, &source_backend, &target, &target_backend, pair, facet, "share-list", &.{});
    defer nested.deinit();
    try std.testing.expect(nested.result().ready.list[0] == .capability);
    const delayed = try source.host.callCapability(a, pair.a, facet, "mutate", &.{ .{ .integer = 1 }, .{ .string = "add" }, .{ .integer = 3 } }, 4096);
    defer delayed.deinit();
    const writing = blk: {
        for (0..128) |_| {
            try source.host.flushSession(pair.a);
            try target.host.flushSession(pair.b);
            try f.pairs.pumpToQuiescence(&.{pair});
            try source.attached.advance();
            if (try source.reads(&source_backend)) |_| return error.UnexpectedSourceWrite;
            try target.attached.advance();
            if (try target.reads(&target_backend)) |batch| break :blk batch;
        }
        return error.DidNotForward;
    };
    // Once dispatched, another source revision cannot replay or recall the
    // target effect. Subsequent facet calls still require current admission.
    _ = try h.f.change(&source_store, &source_backend, source_data.owner, .{ .pause = source_data.grant });
    try target.attached.completeWrite(writing.ticket, target_backend.commit(writing));
    try f.pump(&source, &source_backend, &target, &target_backend, pair);
    try std.testing.expectEqual(@as(i64, 3), delayed.result().ready.integer);
    const pause = try f.send(&source, &source_backend, &target, &target_backend, pair, source.control, "pause", &.{});
    defer pause.deinit();
    const denied = try f.send(&source, &source_backend, &target, &target_backend, pair, facet, "get", &.{});
    defer denied.deinit();
    try std.testing.expect(denied.result() == .failed);
    const still_exact = try f.send(&source, &source_backend, &target, &target_backend, pair, original, "get", &.{});
    defer still_exact.deinit();
    try std.testing.expectEqual(@as(i64, 3), still_exact.result().ready.integer);
    const resumed = try f.send(&source, &source_backend, &target, &target_backend, pair, source.control, "resume", &.{});
    defer resumed.deinit();
    var paused: h.Answer = .{};
    try target.send(target.control, "pause", &.{}, &paused);
    try target.drain(&target_backend);
    const remote_denied = try f.send(&source, &source_backend, &target, &target_backend, pair, facet, "get", &.{});
    defer remote_denied.deinit();
    try std.testing.expect(remote_denied.result() == .failed);
    try std.testing.expectEqual(@as(usize, 0), source.attached.reference_saves);
    const content = try h.c.load(&source_store, &source_backend, source_data.content);
    const recipe = (try f.refs.edgeAt(try source_store.currentView(content), 0)).target;
    try source_store.release(content);
    const removed = try f.send(&source, &source_backend, &target, &target_backend, pair, source.use, "remove", &.{.{ .integer = 0 }});
    defer removed.deinit();
    try std.testing.expect(removed.result().ready.boolean);
    source_store.evict();
    try @import("../core/fixture.zig").collect(&source_store, &source_backend);
    try std.testing.expectError(error.Gone, h.c.load(&source_store, &source_backend, recipe));
    // Removal drops the local recipe only; the target's publication and held
    // exact capability retain their independent remote owner.
    const still_named = try f.fetch(&source, &source_backend, &target, &target_backend, pair, name);
    defer source.host.releaseCapabilityTerminal(still_named, null);
    try std.testing.expect(still_named.eql(original));
}

test "loam foreign save refuses a mismatched or missing durable reference without partial writes" {
    var source_backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer source_backend.deinit();
    var source_store = try h.loam.core.Store.init(a, try source_backend.open(), &f.schemas, h.limits);
    defer source_store.deinit() catch unreachable;
    const source_data = try h.seed(&source_store, &source_backend);
    var target_backend = try h.loam.Volatile.init(a, @fromBackingInt(94), 16 * 1024 * 1024);
    defer target_backend.deinit();
    var target_store = try h.loam.core.Store.init(a, try target_backend.open(), &h.schemas, h.limits);
    defer target_store.deinit() catch unreachable;
    const target_data = try h.seed(&target_store, &target_backend);
    var source: h.Hosted = undefined;
    try source.init(&source_store, &source_backend, source_data);
    defer source.deinit();
    source.service.contents = &f.contents;
    var target: h.Hosted = undefined;
    try target.initIdentity(&target_store, &target_backend, target_data, .{ .sleep_policy = .every_turn }, @splat(0x65));
    defer target.deinit();
    const name = try f.publication(&target, &target_backend, target_data.use, @splat(0x72));
    const wrong = try f.publication(&target, &target_backend, target_data.control, @splat(0x73));
    const pair = try f.pairs.openPair(&source.host, &target.host, "127.0.0.1:9791");
    const original = try f.fetch(&source, &source_backend, &target, &target_backend, pair, name);
    defer source.host.releaseCapabilityTerminal(original, null);
    const wrong_uri = try f.uri(a, wrong);
    defer a.free(wrong_uri);
    const before = source_store.metadata;
    for ([_]bool{ false, true }) |missing| {
        const args = [_]h.driver.Value{ .{ .integer = 0 }, .{ .capability = original }, .{ .string = wrong_uri } };
        const refused = try f.send(&source, &source_backend, &target, &target_backend, pair, source.use, "put", args[0..if (missing) 2 else 3]);
        defer refused.deinit();
        try std.testing.expect(refused.result() == .failed);
        try std.testing.expectEqualDeep(before, source_store.metadata);
        try std.testing.expectEqual(@as(usize, 0), source.attached.reference_saves);
    }
}
