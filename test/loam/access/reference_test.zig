//! Exact held foreign authority, transactional refusal and dependent forwarding.
const std = @import("std");
const f = @import("reference_fixture.zig");
const h = f.h;
const a = std.testing.allocator;

test "loam dependent same attachment with independent owners forwards through both actual authorities" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &f.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const source_data = try h.seed(&store, &backend);
    const target_data = try h.seedAuthority(&store, &backend, @fromBackingInt(82));
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, source_data);
    defer host.deinit();
    var probe: f.ForwardingProbe = .{};
    var registrations = f.contents;
    registrations[0].context = &probe;
    host.service.contents = &registrations;
    const target = try host.restore(&backend, target_data.use);
    defer host.host.releaseCapabilityTerminal(target, null);
    const target_control = try host.restore(&backend, target_data.control);
    defer host.host.releaseCapabilityTerminal(target_control, null);
    const facet = try host.attached.projectDependent(source_data.use, target);
    defer host.host.releaseCapabilityTerminal(facet, null);
    for ([_]h.driver.Capability{ host.control, target_control }) |control| {
        const call = try host.host.callLocalCapability(a, facet, "get", &.{}, 256);
        defer call.deinit();
        try host.drain(&backend);
        try std.testing.expect(call.result() == .ready);
        try std.testing.expectEqual(@as(i64, 0), call.result().ready.integer);
        try std.testing.expectEqual(.forwarding, probe.delivery.?);
        try std.testing.expect(probe.resource.?.id.eql(source_data.resource));
        var paused: h.Answer = .{};
        try host.send(control, "pause", &.{}, &paused);
        try host.drain(&backend);
        try std.testing.expectEqual(@as(?bool, true), paused.changed);
        const refused = try host.host.callLocalCapability(a, facet, "get", &.{}, 256);
        defer refused.deinit();
        try host.drain(&backend);
        try std.testing.expect(refused.result() == .failed);
        var resumed: h.Answer = .{};
        try host.send(control, "resume", &.{}, &resumed);
        try host.drain(&backend);
        try std.testing.expectEqual(@as(?bool, true), resumed.changed);
    }
    const args = [_]h.driver.Value{ .{ .integer = 1 }, .{ .string = "remove" }, .{ .integer = 0 } };
    for (0..2) |_| {
        const mutation = try host.host.callLocalCapability(a, facet, "mutate", &args, 256);
        defer mutation.deinit();
        try host.drain(&backend);
        try std.testing.expect(mutation.result() == .ready);
        try std.testing.expect(mutation.result().ready.boolean);
    }
    const target_lease = try h.c.load(&store, &backend, target_data.use);
    defer store.release(target_lease) catch unreachable;
    const source_lease = try h.c.load(&store, &backend, source_data.use);
    defer store.release(source_lease) catch unreachable;
    const Endpoint = h.loam.access.records.EndpointRecord;
    try std.testing.expectEqual(@as(u64, 2), (try Endpoint.decode(try store.currentView(target_lease))).mutations.next);
    try std.testing.expectEqual(@as(u64, 1), (try Endpoint.decode(try store.currentView(source_lease))).mutations.next);
}

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

test "loam foreign preparation wakes Host drain and parks while reply is withheld" {
    try foreignPreparation(.ordinary);
}

test "loam retained foreign preparation saves and restores cold fields through Host finish" {
    try foreignPreparation(.save_finish);
    try foreignPreparation(.restore_finish);
}

const PreparationCase = enum { ordinary, save_finish, restore_finish };

fn foreignPreparation(comptime mode: PreparationCase) !void {
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
    source.service.contents = &f.contents;
    var target: h.Hosted = undefined;
    try target.initIdentity(&target_store, &target_backend, target_data, .{}, @splat(0x65));
    defer target.deinit();
    const name = try f.publication(&target, &target_backend, target_data.use, @splat(0x71));
    const pair = try f.pairs.openPair(&source.host, &target.host, "127.0.0.1:9791");
    // A held target remains valid without the optional enliven dedup cache.
    pair.a.served.port.peer.session_state.limits.max_sturdyref_cache_entries = 0;
    const original = try f.fetch(&source, &source_backend, &target, &target_backend, pair, name);
    defer source.host.releaseCapabilityTerminal(original, null);
    const uri = try f.uri(a, name);
    defer a.free(uri);
    if (mode == .restore_finish) {
        const saved = try f.send(&source, &source_backend, &target, &target_backend, pair, source.use, "put", &.{ .{ .integer = 0 }, .{ .capability = original }, .{ .string = uri } });
        defer saved.deinit();
        try std.testing.expect(saved.result().ready.boolean);
        try source.attached.sleep(source.use);
    }
    while (try source.host.nextAction()) |_| {}
    const call = if (mode == .ordinary)
        try source.host.callCapability(a, pair.a, source.use, "put", &.{ .{ .integer = 0 }, .{ .capability = original }, .{ .string = uri } }, 4096)
    else if (mode == .save_finish)
        try source.host.callLocalCapability(a, source.use, "put", &.{ .{ .integer = 0 }, .{ .capability = original }, .{ .string = uri } }, 4096)
    else
        try source.host.callLocalCapability(a, source.use, "ref", &.{.{ .integer = 0 }}, 4096);
    defer {
        if (call.result() == .pending) finishCall(&source, &source_backend, pair, call) catch unreachable;
        call.deinit();
    }
    if (mode != .ordinary) {
        try std.testing.expectEqual(@as(usize, 1), source.host.pending_operations);
        source.host.beginClose(.{ .finish = .unbounded }, 0);
        try std.testing.expectError(error.HostClosing, source.host.enlivenCapability(a, .{ .peer = f.pairs.tcpLocator("127.0.0.1:9791"), .swissnum = name.slice() }));
    }
    const woke = for (0..256) |_| {
        while (try source.host.nextAction()) |_| {}
        const progressed = try source.attached.advanceProgress();
        if (if (mode == .restore_finish) source.host.pending_operations == 3 else source.attached.reference_saves != 0) break progressed;
        if (try source.reads(&source_backend)) |_| return error.UnexpectedWrite;
    } else return error.DidNotPrepare;
    try std.testing.expect(woke);
    try std.testing.expect(source.host.hasRunnableWork());
    // Export the queued fetch, but do not feed it to the target yet.
    while (try source.host.nextAction()) |_| {}
    try std.testing.expect(!source.host.hasRunnableWork());
    for (0..3) |_| try std.testing.expect(!try source.attached.advanceProgress());
    try std.testing.expect(call.result() == .pending);
    try finishCall(&source, &source_backend, pair, call);
    if (mode == .restore_finish) try std.testing.expectEqual(original, call.result().ready.capability) else try std.testing.expect(call.result().ready.boolean);
    try std.testing.expectEqual(@as(usize, 0), source.host.pending_operations);
    try std.testing.expectEqual(@as(usize, 0), source.attached.pending_bytes);
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
    var dependent_declarations: f.ForwardingProbe = .{};
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
    const before_copy = source_store.metadata.objects;
    const copy = try f.send(&source, &source_backend, &target, &target_backend, pair, source.use, "copy", &.{.{ .integer = 0 }});
    defer copy.deinit();
    try std.testing.expect(copy.result().ready.boolean);
    // One managed content history batch is added; the immutable foreign
    // recipe is reused rather than saved and staged under another name.
    try std.testing.expectEqual(before_copy + 1, source_store.metadata.objects);
    const copied = try h.c.load(&source_store, &source_backend, source_data.content);
    const copied_view = try source_store.currentView(copied);
    try std.testing.expectEqualDeep(try f.refs.edgeAt(copied_view, 0), try f.refs.edgeAt(copied_view, copied_view.edge_count - 1));
    const last_field: i64 = @intCast(copied_view.edge_count - 1);
    try source_store.release(copied);
    const remove_copy = try f.send(&source, &source_backend, &target, &target_backend, pair, source.use, "remove", &.{.{ .integer = last_field }});
    defer remove_copy.deinit();
    try std.testing.expect(remove_copy.result().ready.boolean);
    const dependent = try f.send(&source, &source_backend, &target, &target_backend, pair, source.use, "dependent", &.{.{ .integer = 0 }});
    defer dependent.deinit();
    const facet = dependent.result().ready.capability;
    const read = try f.send(&source, &source_backend, &target, &target_backend, pair, facet, "get", &.{});
    defer read.deinit();
    try std.testing.expectEqual(@as(i64, 0), read.result().ready.integer);
    // The same source declaration guards dispatch and outward completion.
    try std.testing.expectEqual(@as(usize, 2), dependent_declarations.calls);
    try std.testing.expectEqual(.forwarding, dependent_declarations.delivery.?);
    try std.testing.expect(dependent_declarations.resource.?.id.eql(source_data.resource));
    try std.testing.expectEqual(source_store.metadata.store, dependent_declarations.resource.?.object.store);
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
    // Source loss cannot recall an already dispatched target effect. It does
    // suppress outward disclosure through this dependent facet, while exact
    // target authority still observes the applied result below.
    _ = try h.f.change(&source_store, &source_backend, source_data.owner, .{ .pause = source_data.grant });
    try target.attached.completeWrite(writing.ticket, target_backend.commit(writing));
    try f.pump(&source, &source_backend, &target, &target_backend, pair);
    try std.testing.expectEqualStrings("Paused", delayed.result().failed.message);
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
