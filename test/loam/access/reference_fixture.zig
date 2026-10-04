//! Managed reference methods driven through ordinary Host Value calls.
const std = @import("std");
pub const h = @import("hosting_fixture.zig");
pub const pairs = @import("../../support/host_pair.zig");
pub const model = h.f.glowcap.ocapn.model;
pub const refs = h.loam.hosting.references;
pub const schemas = h.schemas ++ [_]h.loam.core.Schema{refs.schema};
pub const contents = [_]h.access.ContentBehavior{.{ .schema = 7, .requirement = requirement, .retry = retry, .references = references, .dependent_requirement = dependentRequirement, .invoke = invoke }};

fn requirement(_: ?*anyopaque, _: std.mem.Allocator, _: h.loam.core.RecordView, verb: []const u8, _: []const h.driver.Value) !h.c.core.Policy.Requirement {
    if (std.mem.eql(u8, verb, "get") or std.mem.eql(u8, verb, "ref") or std.mem.eql(u8, verb, "dependent")) return .{ .permissions = &.{h.f.vocabulary.read} };
    if (std.mem.eql(u8, verb, "put") or std.mem.eql(u8, verb, "append") or std.mem.eql(u8, verb, "remove")) return .{ .permissions = &.{h.f.vocabulary.post} };
    return error.NoSuchMethod;
}
fn dependentRequirement(context: ?*anyopaque, _: std.mem.Allocator, _: h.loam.core.RecordView, verb: []const u8, _: []const h.driver.Value) !h.c.core.Policy.Requirement {
    if (context) |pointer| {
        const calls: *usize = @ptrCast(@alignCast(pointer));
        calls.* += 1;
    }
    if (std.mem.eql(u8, verb, "get") or std.mem.startsWith(u8, verb, "share")) return .{ .permissions = &.{h.f.vocabulary.read} };
    if (std.mem.eql(u8, verb, "mutate") or std.mem.eql(u8, verb, "pause") or std.mem.eql(u8, verb, "resume")) return .{ .permissions = &.{h.f.vocabulary.post} };
    return error.NoSuchMethod;
}
fn retry(_: ?*anyopaque, verb: []const u8, _: []const h.driver.Value) !h.access.RetryMode {
    return if (std.mem.eql(u8, verb, "put") or std.mem.eql(u8, verb, "append") or std.mem.eql(u8, verb, "remove")) .idempotent else .read_only;
}
fn index(args: []const h.driver.Value) !usize {
    if (args.len == 0 or args[0] != .integer) return error.InvalidArguments;
    return std.math.cast(usize, args[0].integer) orelse error.InvalidArguments;
}
fn references(_: ?*anyopaque, arena: std.mem.Allocator, _: h.loam.core.RecordView, verb: []const u8, args: []const h.driver.Value) ![]const refs.Request {
    if (std.mem.eql(u8, verb, "ref") or std.mem.eql(u8, verb, "dependent")) {
        const requests = try arena.alloc(refs.Request, 1);
        requests[0] = .{ .restore = try index(args) };
        return requests;
    }
    if (std.mem.eql(u8, verb, "put") or std.mem.eql(u8, verb, "append")) {
        if ((args.len != 2 and args.len != 3) or args[1] != .capability or (args.len == 3 and args[2] != .string)) return error.InvalidArguments;
        const requests = try arena.alloc(refs.Request, 1);
        requests[0] = .{ .save = .{ .capability = args[1].capability, .uri = if (args.len == 3) args[2].string else null } };
        return requests;
    }
    return &.{};
}
fn invoke(_: ?*anyopaque, call: *h.access.ContentCall, view: h.loam.core.RecordView, verb: []const u8, args: []const h.driver.Value) !h.driver.Value {
    if (std.mem.eql(u8, verb, "get")) return .{ .integer = std.mem.readInt(i64, view.payload[0..8], .little) };
    if (std.mem.eql(u8, verb, "ref")) return call.discloseExact(try index(args));
    if (std.mem.eql(u8, verb, "dependent")) return call.discloseDependent(try index(args));
    if (std.mem.eql(u8, verb, "put")) {
        try call.replaceReference(try index(args), args[1].capability);
        const payload = try call.allocator().alloc(u8, 8);
        std.mem.writeInt(i64, payload[0..8], 17, .little);
        call.replace(payload);
        return .{ .boolean = true };
    }
    if (std.mem.eql(u8, verb, "append")) {
        try call.appendReference(args[1].capability);
        return .{ .boolean = true };
    }
    if (std.mem.eql(u8, verb, "remove")) {
        try call.removeReference(try index(args));
        return .{ .boolean = true };
    }
    return error.NoSuchMethod;
}

pub fn fields(store: *h.loam.core.Store, backend: anytype, content: h.loam.core.ObjectId, count: usize) !void {
    const lease = try h.c.load(store, backend, content);
    defer store.release(lease) catch unreachable;
    const view = try store.currentView(lease);
    var iterator = view.edges();
    const target = iterator.next().?.target;
    const edges = try store.allocator.alloc(h.loam.core.Edge, count);
    defer store.allocator.free(edges);
    @memset(edges, .{ .target = target });
    try store.begin();
    try store.putCopying(.{ .id = view.id, .revision = 0, .schema = view.schema, .rooted = view.rooted, .payload = view.payload, .edges = edges }, view.revision);
    try h.f.commit(store, backend);
}

pub fn publication(server: *h.Hosted, backend: anytype, id: h.loam.core.ObjectId, entropy: h.driver.Host.DurableSwiss.Entropy) !h.driver.Host.DurableSwiss {
    const store = server.caps.store;
    const lease = try h.c.load(store, backend, id);
    defer store.release(lease) catch unreachable;
    try store.begin();
    const recipe = try h.access.stagePublication(store, lease, entropy);
    try h.f.commit(store, backend);
    const published = try h.c.load(store, backend, recipe);
    defer store.release(published) catch unreachable;
    return h.loam.hosting.publication.restore(server.attached, published);
}

/// Execute only the storage and Host work emitted by these two participants.
pub fn pump(source: *h.Hosted, source_backend: anytype, target: *h.Hosted, target_backend: anytype, pair: pairs.Pair) !void {
    for (0..1024) |_| {
        try source.host.flushSession(pair.a);
        try target.host.flushSession(pair.b);
        try pairs.pumpToQuiescence(&.{pair});
        try source.attached.advance();
        if (try source.reads(source_backend)) |batch| try source.attached.completeWrite(batch.ticket, source_backend.commit(batch));
        try target.attached.advance();
        if (try target.reads(target_backend)) |batch| try target.attached.completeWrite(batch.ticket, target_backend.commit(batch));
        if (!source.attached.hasPendingWork() and !target.attached.hasPendingWork() and source.host.pendingVowCount() == 0 and target.host.pendingVowCount() == 0) return;
    }
    return error.DidNotQuiesce;
}

pub fn send(source: *h.Hosted, source_backend: anytype, target: *h.Hosted, target_backend: anytype, pair: pairs.Pair, capability: h.driver.Capability, verb: []const u8, args: []const h.driver.Value) !*h.driver.Host.Call {
    const owned = try source.host.callCapability(source.caps.store.allocator, pair.a, capability, verb, args, 4096);
    errdefer owned.deinit();
    try pump(source, source_backend, target, target_backend, pair);
    return owned;
}

pub fn uri(arena: std.mem.Allocator, name: h.driver.Host.DurableSwiss) ![]u8 {
    return model.uri.writeSturdyref(arena, .{ .peer = pairs.tcpLocator("127.0.0.1:9791"), .swissnum = name.slice() });
}

pub fn fetch(source: *h.Hosted, source_backend: anytype, target: *h.Hosted, target_backend: anytype, pair: pairs.Pair, name: h.driver.Host.DurableSwiss) !h.driver.Capability {
    const enliven = try source.host.enlivenCapability(source.caps.store.allocator, .{ .peer = pairs.tcpLocator("127.0.0.1:9791"), .swissnum = name.slice() });
    defer enliven.deinit();
    try pump(source, source_backend, target, target_backend, pair);
    return enliven.take();
}
