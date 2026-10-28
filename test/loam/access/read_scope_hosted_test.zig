//! Recursive readers use real source grants and exact upstream authority.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const Scope = h.loam.hosting.ReadScope;

const App = struct {
    target: ?h.driver.Capability = null,
    dispatched: usize = 0,
    results: []const usize = &.{},
    mode: h.access.RetryMode = .read_only,
    allowed: bool = true,
    fn behavior(self: *App) h.access.ContentBehavior {
        return .{ .schema = 7, .context = self, .requirement = requirement, .retry = retry, .invoke = invoke };
    }
    fn requirement(context: ?*anyopaque, _: std.mem.Allocator, input: h.access.ContentInvocation) !h.c.core.Policy.Requirement {
        const self: *App = @ptrCast(@alignCast(context.?));
        if (!self.allowed) return error.SourceClosed;
        if (std.mem.eql(u8, input.verb, "readers")) return .{ .permissions = &.{h.f.vocabulary.read} };
        if (std.mem.eql(u8, input.verb, "target")) return .{ .permissions = &.{h.f.vocabulary.post} };
        return error.NoSuchMethod;
    }
    fn retry(context: ?*anyopaque, _: []const u8, _: []const h.driver.Value) !h.access.RetryMode {
        const self: *App = @ptrCast(@alignCast(context.?));
        return self.mode;
    }
    fn invoke(context: ?*anyopaque, call: *h.access.ContentCall, input: h.access.ContentInvocation) !h.driver.Value {
        const self: *App = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, input.verb, "target")) {
            self.dispatched += 1;
            return .{ .integer = 7 };
        }
        return call.discloseReadsCopying(self.target orelse try call.reference(0), &.{.{ .methods = &.{.{ .verb = "target", .results = self.results }} }}, 0);
    }
};

test "loam read scope refuses idempotent and receipt content callbacks" {
    for ([_]h.access.RetryMode{ .idempotent, .receipt }) |mode| {
        var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
        defer backend.deinit();
        var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        const data = try h.seedIndependentTarget(&store, &backend);
        var host: h.Hosted = undefined;
        try host.initOptions(&store, &backend, data, .{ .sleep_policy = .every_turn });
        defer host.deinit();
        defer host.drain(&backend) catch unreachable;
        var app: App = .{ .mode = mode };
        const registration = [_]h.access.ContentBehavior{app.behavior()};
        host.service.contents = &registration;
        const acquired = try host.host.callLocalCapability(h.a, host.use, if (mode == .receipt) "mutate" else "readers", if (mode == .receipt) &.{ .{ .integer = 1 }, .{ .string = "readers" } } else &.{}, 4096);
        defer acquired.deinit();
        try host.drain(&backend);
        try std.testing.expect(acquired.result() == .failed);
        try std.testing.expectEqualStrings("ReadOnlyRequired", acquired.result().failed.message);
        try std.testing.expectEqual(@as(usize, 0), host.attached.continuations);
    }
}
test "loam read scope settlement retry rechecks volatile source admission without a storage edit" {
    const peers = @import("../../support/host_pair.zig");
    const peer_support = @import("../../support/core_host.zig");
    const CapturedRef = @import("../../support/capture.zig").CapturedRef;
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedIndependentTarget(&store, &backend);
    var host: h.Hosted = undefined;
    try host.initOptions(&store, &backend, data, .{ .sleep_policy = .every_turn });
    defer host.deinit();
    defer host.drain(&backend) catch unreachable;
    var waiting: Waiting.State = .{};
    const actor = try host.host.vat.spawn(h.driver.Hosting(Waiting), .{ .inner = .{ .state = &waiting } });
    const target = try host.host.liftLocalActor(actor);
    defer host.host.releaseCapabilityTerminal(target, null);
    var app: App = .{ .target = target };
    const registration = [_]h.access.ContentBehavior{app.behavior()};
    host.service.contents = &registration;
    const acquired = try host.host.callLocalCapability(h.a, host.use, "readers", &.{}, 4096);
    defer acquired.deinit();
    try host.drain(&backend);
    var peer = peer_support.init(h.a, @splat(0x81), h.driver.Host.Options.withFrameCap(4096));
    defer peer.deinit();
    const swiss = try host.host.publishDurableCapability(@splat(0x82), acquired.result().ready.capability);
    defer host.host.removeDurable(swiss.slice()) catch unreachable;
    const pair = try peers.openPair(&host.host, &peer, "127.0.0.1:9760");
    defer host.host.releaseSession(pair.a) catch unreachable;
    var fetched: CapturedRef = .{};
    try peer.vowOn(try peer.fetch(pair.b, swiss.slice()), .{ .ctx = &fetched, .func = CapturedRef.record });
    try peers.pumpToQuiescence(&.{pair});
    const reader = try peer.liftCapability(pair.b, try fetched.require());
    defer peer.releaseCapabilityTerminal(reader, null);
    const pending = try peer.callCapability(h.a, pair.b, reader, "target", &.{}, 4096);
    defer pending.deinit();
    // The call still awaits the Host action drain below. Moving available
    // frames cannot declare that pending send quiescent; after the action
    // drain, every loop pump must reach checked agreement.
    try std.testing.expectError(error.PairNotAtRest, peers.pumpToQuiescence(&.{pair}));
    for (0..64) |_| {
        while (try peer.nextAction()) |_| {}
        while (try host.host.nextAction()) |_| {}
        _ = try host.host.vat.driveIngressBudgeted(.local, 64);
        try host.attached.advance();
        _ = try host.reads(&backend);
        try host.host.flushSession(pair.a);
        try peer.flushSession(pair.b);
        try peers.pumpToQuiescence(&.{pair});
        if (waiting.resolver != null) break;
    }
    try std.testing.expect(waiting.resolver != null);
    var arena = std.heap.ArenaAllocator.init(h.a);
    defer arena.deinit();
    try host.host.resolverFulfillValue(waiting.resolver.?, .{ .list = &.{.{ .string = "chunk" }} }, arena.allocator());
    const original = host.attached.allocator;
    var failing = std.testing.FailingAllocator.init(original, .{ .fail_index = 0 });
    host.attached.allocator = failing.allocator();
    defer host.attached.allocator = original;
    try std.testing.expectError(error.OutOfMemory, host.drain(&backend));
    try std.testing.expect(pending.result() == .pending);
    const revision = store.metadata.revision;
    app.allowed = false;
    failing.fail_index = std.math.maxInt(usize);
    try host.drain(&backend);
    try host.host.flushSession(pair.a);
    try peers.pumpToQuiescence(&.{pair});
    while (try peer.nextAction()) |_| {}
    try std.testing.expectEqual(revision, store.metadata.revision);
    if (pending.result() != .failed) std.debug.print("volatile admission retry delivered {s}\n", .{@tagName(pending.result())});
    try std.testing.expect(pending.result() == .failed);
    try std.testing.expectEqualStrings("SourceClosed", pending.result().failed.message);
    try std.testing.expectEqual(@as(usize, 1), waiting.calls);
}
const Waiting = struct {
    const State = struct { resolver: ?u64 = null, calls: usize = 0 };
    state: *State,
    pub fn handle(self: *Waiting, turn: *h.driver.HostTurn, _: []const u8, args: h.driver.Args) !h.driver.Value {
        const arg_values = try args.values();
        defer turn.releaseValues(arg_values);
        self.state.resolver = try turn.deferAnswer();
        self.state.calls += 1;
        return .{ .void = {} };
    }
};

test "loam read scope actual source and upstream grants independently fence retained readers" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedIndependentTarget(&store, &backend);
    var host: h.Hosted = undefined;
    try host.initOptions(&store, &backend, data, .{ .sleep_policy = .every_turn });
    defer host.deinit();
    defer host.drain(&backend) catch unreachable;
    var app: App = .{};
    const registration = [_]h.access.ContentBehavior{app.behavior()};
    host.service.contents = &registration;
    const acquired = try host.host.callLocalCapability(h.a, host.use, "readers", &.{}, 4096);
    defer acquired.deinit();
    try host.drain(&backend);
    const reader = acquired.result().ready.capability;
    try std.testing.expect(!reader.eql(host.use));
    for ([_][]const u8{ "target", "not-declared" }) |verb| {
        const call = try host.host.callLocalCapability(h.a, reader, verb, &.{}, 4096);
        defer call.deinit();
        try host.drain(&backend);
        if (std.mem.eql(u8, verb, "target")) try std.testing.expectEqual(@as(i64, 7), call.result().ready.integer) else try std.testing.expectEqualStrings("NoSuchMethod", call.result().failed.message);
    }
    try std.testing.expectEqual(@as(usize, 1), app.dispatched);
    _ = try h.f.change(&store, &backend, data.owner, .{ .pause = data.target_grant.? });
    const upstream = try host.host.callLocalCapability(h.a, reader, "target", &.{}, 4096);
    defer upstream.deinit();
    try host.drain(&backend);
    try std.testing.expectEqualStrings("Paused", upstream.result().failed.message);
    _ = try h.f.change(&store, &backend, data.owner, .{ .resume_access = data.target_grant.? });
    _ = try h.f.change(&store, &backend, data.owner, .{ .set_policy = .{
        .grant = data.grant,
        .terms = try h.f.vocabulary.terms(.{ .objects = &.{data.resource} }, &.{h.f.vocabulary.post}, null),
    } });
    const narrowed = try host.host.callLocalCapability(h.a, reader, "target", &.{}, 4096);
    defer narrowed.deinit();
    try host.drain(&backend);
    try std.testing.expect(narrowed.result() == .failed);
    try std.testing.expectEqual(@as(usize, 1), app.dispatched);
}

test "loam read scope refuses recursive disclosure after actual source pause or revoke during a wait" {
    for ([_]bool{ false, true }) |revoke| {
        var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
        defer backend.deinit();
        var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        const data = try h.seedIndependentTarget(&store, &backend);
        var host: h.Hosted = undefined;
        try host.initOptions(&store, &backend, data, .{ .sleep_policy = .every_turn });
        defer host.deinit();
        defer host.drain(&backend) catch unreachable;
        var waiting: Waiting.State = .{};
        const actor = try host.host.vat.spawn(h.driver.Hosting(Waiting), .{ .inner = .{ .state = &waiting } });
        const target = try host.host.liftLocalActor(actor);
        defer host.host.releaseCapabilityTerminal(target, null);
        var app: App = .{ .target = target, .results = &.{0} };
        const registration = [_]h.access.ContentBehavior{app.behavior()};
        host.service.contents = &registration;
        const acquired = try host.host.callLocalCapability(h.a, host.use, "readers", &.{}, 4096);
        defer acquired.deinit();
        try host.drain(&backend);
        const pending = try host.host.callLocalCapability(h.a, acquired.result().ready.capability, "target", &.{}, 4096);
        defer pending.deinit();
        for (0..64) |_| {
            _ = try host.host.vat.driveIngressBudgeted(.local, 64);
            try host.attached.advance();
            _ = try host.reads(&backend);
            if (waiting.resolver != null) break;
        }
        try std.testing.expect(waiting.resolver != null);
        try std.testing.expect(pending.result() == .pending);
        _ = try h.f.change(&store, &backend, data.owner, if (revoke) .{ .revoke = data.grant } else .{ .pause = data.grant });
        var arena = std.heap.ArenaAllocator.init(h.a);
        defer arena.deinit();
        try host.host.resolverFulfillValue(waiting.resolver.?, .{ .capability = target }, arena.allocator());
        try host.drain(&backend);
        try std.testing.expect(pending.result() == .failed);
        try std.testing.expectEqual(@as(usize, 1), waiting.calls);
        try std.testing.expectEqual(@as(usize, 0), host.attached.pending_bytes);
    }
}
