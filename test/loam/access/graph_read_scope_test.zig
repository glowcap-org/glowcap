//! Local and forwarded requirements use the current graph without restoring fields.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const fixture = @import("content_graph_fixture.zig");

const Reader = struct {
    target: h.driver.Capability,
    fn requirement(_: ?*anyopaque, _: std.mem.Allocator, input: h.access.ContentInvocation) !h.c.core.Policy.Requirement {
        if (std.mem.eql(u8, input.verb, "root-reader")) {
            if (input.graph != null) return error.UnrequestedGraph;
            return .{ .permissions = &.{h.f.vocabulary.read} };
        }
        if (!std.mem.eql(u8, input.verb, "reader")) return error.NoSuchMethod;
        const graph = input.graph orelse return error.UnpreparedSourceGraph;
        if (graph.pages.len != 6) return error.InvalidSourceGraph;
        for (graph.pages) |page| {
            if (std.mem.readInt(i64, page.view.payload[0..8], .little) != 71) return error.SelectionRetired;
        }
        return .{ .permissions = &.{h.f.vocabulary.read} };
    }
    fn retry(_: ?*anyopaque, _: []const u8, _: []const h.driver.Value) !h.access.RetryMode {
        return .read_only;
    }
    fn invoke(context: ?*anyopaque, call: *h.access.ContentCall, _: h.access.ContentInvocation) !h.driver.Value {
        const self: *Reader = @ptrCast(@alignCast(context.?));
        return call.discloseReadsCopying(self.target, &.{.{ .methods = &.{.{ .verb = "get" }} }}, 0);
    }
    fn behavior(self: *Reader, graph: h.access.graph.Spec) h.access.ContentBehavior {
        var spec = graph;
        spec.requirement_verbs = &.{"reader"};
        return .{ .schema = 7, .graph = spec, .context = self, .requirement = requirement, .retry = retry, .invoke = invoke };
    }
};
const Target = struct {
    calls: *usize,
    pub fn handle(self: *Target, _: *h.driver.HostTurn, _: []const u8, _: h.driver.Args) !h.driver.Value {
        self.calls.* += 1;
        return .{ .integer = 9 };
    }
};

const NoPages = struct {
    backing: *h.loam.Volatile,
    pages: []const h.loam.core.ObjectId,
    attempted: usize = 0,
    pub fn read(self: *NoPages, request: h.loam.core.Read) h.loam.core.ReadResult {
        for (self.pages) |page| if (page.eql(request.id)) {
            self.attempted += 1;
            return .{ .failed = error.UnrequestedGraph };
        };
        return self.backing.read(request);
    }
    pub fn commit(self: *NoPages, batch: h.loam.core.Batch) h.loam.core.Outcome {
        return self.backing.commit(batch);
    }
    pub fn lookup(self: *NoPages, request: h.loam.core.NameLookup) h.loam.core.NameResult {
        return self.backing.lookup(request);
    }
};

test "loam graph source facade rechecks cold scalar selection without field restoration" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const seeded = try fixture.seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, seeded.data);
    defer host.deinit();
    defer host.drain(&backend) catch unreachable;
    var writer: fixture.App = .{ .held = host.control };
    const writes = [_]h.access.ContentBehavior{writer.behavior()};
    host.service.contents = &writes;
    var answer: h.Answer = .{};
    try host.mutate(host.use, 1, "set", &.{.{ .integer = 71 }}, &answer);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?bool, true), answer.changed);
    var calls: usize = 0;
    const actor = try host.host.vat.spawn(h.driver.Hosting(Target), .{ .inner = .{ .calls = &calls } });
    const target = try host.host.liftLocalActor(actor);
    defer host.host.releaseCapabilityTerminal(target, null);
    var reader: Reader = .{ .target = target };
    const reads = [_]h.access.ContentBehavior{reader.behavior(writes[0].graph.?)};
    host.service.contents = &reads;
    const acquired = try host.host.callLocalCapability(h.a, host.use, "reader", &.{}, 4096);
    defer acquired.deinit();
    try host.drain(&backend);
    try std.testing.expect(acquired.result() == .ready);
    const facade = acquired.result().ready.capability;
    store.evict();
    const first = try host.host.callLocalCapability(h.a, facade, "get", &.{}, 4096);
    defer first.deinit();
    try host.drain(&backend);
    try std.testing.expect(first.result() == .ready);
    try std.testing.expectEqual(@as(i64, 9), first.result().ready.integer);
    try std.testing.expectEqual(@as(usize, 1), calls);
    const ordinary = try host.host.callLocalCapability(h.a, host.use, "root-reader", &.{}, 4096);
    defer ordinary.deinit();
    try host.drain(&backend);
    try std.testing.expect(ordinary.result() == .ready);
    var pages: [6]h.loam.core.ObjectId = undefined;
    {
        const lease = try h.c.load(&store, &backend, seeded.data.content);
        defer store.release(lease) catch unreachable;
        var edges = (try store.currentView(lease)).edges();
        _ = edges.next();
        for (&pages) |*page| page.* = edges.next().?.target;
    }
    store.evict();
    var no_pages: NoPages = .{ .backing = &backend, .pages = &pages };
    const root_only = try host.host.callLocalCapability(h.a, ordinary.result().ready.capability, "get", &.{}, 4096);
    defer root_only.deinit();
    try host.drain(&no_pages);
    try std.testing.expect(root_only.result() == .ready);
    try std.testing.expectEqual(@as(usize, 0), no_pages.attempted);
    try std.testing.expectEqual(@as(usize, 2), calls);
    host.service.contents = &writes;
    var changed: h.Answer = .{};
    try host.mutate(host.use, 2, "set", &.{.{ .integer = 72 }}, &changed);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?bool, true), changed.changed);
    host.service.contents = &reads;
    store.evict();
    const stale = try host.host.callLocalCapability(h.a, facade, "get", &.{}, 4096);
    defer stale.deinit();
    try host.drain(&backend);
    try std.testing.expect(stale.result() == .failed);
    try std.testing.expectEqualStrings("SelectionRetired", stale.result().failed.message);
    try std.testing.expectEqual(@as(usize, 2), calls);
}
