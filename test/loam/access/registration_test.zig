//! Borrowed application state stays bound from admission through settlement.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const sharing = @import("sharing_fixture.zig");
const management = @import("management_fixture.zig");
const a = std.testing.allocator;

const Probe = struct {
    bias: i64,
    bound_resource: ?h.c.storage.Operation.BoundResource = null,
    content_revision: u64 = 0,
    requirements: usize = 0,
    retries: usize = 0,
    resources: usize = 0,
    reference_calls: usize = 0,
    invocations: usize = 0,
    replacement_invocations: usize = 0,
    decoders: [4]usize = @splat(0),
    entropy_calls: usize = 0,

    fn get(context: ?*anyopaque) *Probe {
        return @ptrCast(@alignCast(context.?));
    }
    fn behavior(self: *Probe) h.access.ContentBehavior {
        return .{ .context = self, .schema = 7, .requirement = requirement, .retry = retry, .resource = resource, .references = references, .invoke = invoke };
    }
    fn requirement(context: ?*anyopaque, arena: std.mem.Allocator, input: h.access.ContentInvocation) !h.c.core.Policy.Requirement {
        const self = get(context);
        self.requirements += 1;
        self.bound_resource = input.bound_resource;
        self.content_revision = input.content.revision;
        return h.contents[0].requirement(null, arena, input);
    }
    fn retry(context: ?*anyopaque, verb: []const u8, args: []const h.driver.Value) !h.access.RetryMode {
        get(context).retries += 1;
        return h.contents[0].retry(null, verb, args);
    }
    fn resource(context: ?*anyopaque, arena: std.mem.Allocator, input: h.access.ContentInvocation) !?h.c.storage.ResourceChange.Action {
        get(context).resources += 1;
        return h.contents[0].resource.?(null, arena, input);
    }
    fn references(context: ?*anyopaque, _: std.mem.Allocator, input: h.access.ContentInvocation) ![]const h.loam.hosting.references.Request {
        const self = get(context);
        self.reference_calls += 1;
        try std.testing.expectEqualDeep(self.bound_resource.?, input.bound_resource);
        try std.testing.expectEqual(self.content_revision, input.content.revision);
        return &.{};
    }
    fn invoke(context: ?*anyopaque, call: *h.access.ContentCall, input: h.access.ContentInvocation) !h.driver.Value {
        const self = get(context);
        self.invocations += 1;
        try std.testing.expectEqualDeep(self.bound_resource.?, input.bound_resource);
        try std.testing.expectEqual(self.content_revision, input.content.revision);
        const result = try h.contents[0].invoke(null, call, input);
        return .{ .integer = result.integer + self.bias };
    }
    fn replacementInvoke(context: ?*anyopaque, call: *h.access.ContentCall, input: h.access.ContentInvocation) !h.driver.Value {
        get(context).replacement_invocations += 1;
        return invoke(context, call, input);
    }
    fn refusedEntropy(_: ?*anyopaque, _: *h.driver.Host.DurableSwiss.Entropy) !void {
        return error.ReplacedEntropy;
    }
    fn control(context: ?*anyopaque, _: std.mem.Allocator, _: h.c.core.Control.Powers, _: []const u8, _: []const h.driver.Value) !h.c.core.Control.Edit {
        get(context).decoders[0] += 1;
        return error.ApplicationRefused;
    }
    fn derive(context: ?*anyopaque, arena: std.mem.Allocator, resource_id: h.c.core.ResourceId, args: []const h.driver.Value) !h.c.core.GrantLedger.Issue {
        get(context).decoders[1] += 1;
        return sharing.decode(null, arena, resource_id, args);
    }
    fn managed(context: ?*anyopaque, arena: std.mem.Allocator, resource_id: h.c.core.ResourceId, args: []const h.driver.Value) !h.access.Service.ManagedIssue {
        get(context).decoders[2] += 1;
        return management.decodeManaged(null, arena, resource_id, args);
    }
    fn attenuation(context: ?*anyopaque, arena: std.mem.Allocator, bound: h.c.core.Control.Powers, args: []const h.driver.Value) !h.c.core.Control.Powers {
        get(context).decoders[3] += 1;
        return management.decodeAttenuation(null, arena, bound, args);
    }
    fn entropy(context: ?*anyopaque, bytes: *h.driver.Host.DurableSwiss.Entropy) !void {
        const self = get(context);
        self.entropy_calls += 1;
        bytes.* = @splat(@intCast(self.bias));
    }
};

/// Stop after selecting content but before authority reads finish. No Vat
/// invocation runs here, so the test owns the exact asynchronous boundary.
fn selected(host: *h.Hosted, backend: *h.loam.Volatile, probe: *Probe) !void {
    _ = try host.host.vat.driveIngressBudgeted(.local, 64);
    for (0..128) |_| {
        try host.attached.advance();
        if (probe.requirements != 0) return;
        const work = (try host.attached.nextWork()) orelse return error.NoProgress;
        if (work != .read) return error.UnexpectedWrite;
        try host.attached.completeRead(work.read.ticket, backend.read(work.read));
    }
    return error.DidNotSelect;
}

test "loam managed registrations isolate application contexts across cold reads and closure" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var first: h.Hosted = undefined;
    try first.init(&store, &backend, data);
    defer first.deinit();
    var second: h.Hosted = undefined;
    try second.init(&store, &backend, data);
    defer second.deinit();
    var probes = [_]Probe{ .{ .bias = 17 }, .{ .bias = 29 } };
    var registrations = [_][1]h.access.ContentBehavior{ .{probes[0].behavior()}, .{probes[1].behavior()} };
    registrations[1][0].invoke = Probe.replacementInvoke;
    first.service.contents = &registrations[0];
    second.service.contents = &registrations[1];
    store.evict();
    var answer: h.Answer = .{};
    try first.send(first.use, "get", &.{}, &answer);
    try selected(&first, &backend, &probes[0]);
    try std.testing.expectError(error.Busy, first.attached.destroy());
    try std.testing.expectEqual(@as(usize, 0), probes[0].invocations);
    // Future selections may use a replacement table; this preparation retains
    // its exact binding. Both old table and context still belong to the caller.
    first.service.contents = &registrations[1];
    try first.drain(&backend);
    try std.testing.expectEqual(@as(?i64, 17), answer.number);
    try std.testing.expectEqual(@as(usize, 1), probes[0].invocations);
    try std.testing.expectEqual(@as(usize, 0), probes[0].replacement_invocations);
    try std.testing.expect(probes[0].reference_calls != 0);
    try std.testing.expectEqual(@as(usize, 1), probes[0].retries);
    try std.testing.expectEqual(@as(usize, 1), probes[0].resources);
    try std.testing.expectEqual(@as(usize, 0), probes[1].requirements);
    var other: h.Answer = .{};
    try second.send(second.use, "get", &.{}, &other);
    try second.drain(&backend);
    try std.testing.expectEqual(@as(?i64, 29), other.number);
    try std.testing.expectEqual(@as(usize, 1), probes[1].invocations);
    try std.testing.expectEqual(@as(usize, 1), probes[1].replacement_invocations);
}

test "loam managed service decoders receive their application context on refusal" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedDepth(&store, &backend, 2);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    var probe: Probe = .{ .bias = 19 };
    host.service.context = &probe;
    host.service.decode_control = Probe.control;
    host.service.decode_derive = Probe.derive;
    host.service.decode_managed_derive = Probe.managed;
    host.service.decode_attenuation = Probe.attenuation;
    const calls = [_]struct { ref: h.driver.Capability, verb: []const u8, args: []const h.f.glowcap.ocapn.model.Argument }{
        .{ .ref = host.control, .verb = "pause", .args = &.{} },
        .{ .ref = host.use, .verb = "derive", .args = &.{.{ .integer = 1 }} },
        .{ .ref = host.use, .verb = "derive-managed", .args = &.{.{ .integer = 1 }} },
        .{ .ref = host.control, .verb = "mutate", .args = &.{ .{ .integer = 1 }, .{ .string = "attenuate-control" } } },
    };
    for (calls, 0..) |call, index| {
        var answer: h.Answer = .{};
        try host.send(call.ref, call.verb, call.args, &answer);
        try host.drain(&backend);
        try std.testing.expect(answer.broken);
        try std.testing.expectEqual(@as(usize, 1), probe.decoders[index]);
    }
    try std.testing.expectEqual(@as(usize, 0), probe.invocations);
}

test "loam managed sharing retains entropy registration across cold preparation" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedDepth(&store, &backend, 2);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    var client: sharing.Client = undefined;
    try client.init(&host);
    defer client.deinit();
    var original: Probe = .{ .bias = 19 };
    var replacement: Probe = .{ .bias = 23 };
    host.service.context = &original;
    host.service.decode_derive = Probe.derive;
    host.service.entropy = .{ .context = &original, .fill = Probe.entropy };
    store.evict();
    var answer: sharing.captures.CapturedRef = .{};
    try client.send(client.parent, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &answer);
    for (0..128) |_| {
        try host.attached.advance();
        if (original.decoders[1] != 0) break;
        const work = (try host.attached.nextWork()) orelse return error.NoProgress;
        if (work != .read) return error.UnexpectedWrite;
        try host.attached.completeRead(work.read.ticket, backend.read(work.read));
    }
    try std.testing.expectEqual(@as(usize, 1), original.decoders[1]);
    try std.testing.expectEqual(@as(usize, 0), original.entropy_calls);
    host.service.entropy = .{ .context = &replacement, .fill = Probe.refusedEntropy };
    try host.drain(&backend);
    try client.pump();
    _ = try answer.require();
    try std.testing.expectEqual(@as(usize, 1), original.entropy_calls);
    try std.testing.expectEqual(@as(usize, 0), replacement.entropy_calls);
}

test "loam managed registration context can be freed after successful attachment closure" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer {
        host.host.releaseCapabilityTerminal(host.use, null);
        host.host.releaseCapabilityTerminal(host.control, null);
        host.host.deinit();
        host.caps.deinit() catch unreachable;
    }
    var attached = true;
    defer if (attached) host.attached.destroy() catch unreachable;
    const probe = try a.create(Probe);
    probe.* = .{ .bias = 31 };
    var owned = true;
    defer if (owned) a.destroy(probe);
    const registrations = [_]h.access.ContentBehavior{probe.behavior()};
    host.service.contents = &registrations;
    var answer: h.Answer = .{};
    try host.send(host.use, "get", &.{}, &answer);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?i64, 31), answer.number);
    const actor = host.host.localActorFor(host.use).?;
    try host.attached.destroy();
    attached = false;
    a.destroy(probe);
    owned = false;
    try std.testing.expectError(error.AttachmentClosed, host.host.vat.near(actor, .{ .verb = "get", .args = &.{} }));
    var refused: h.Answer = .{};
    try host.send(host.use, "get", &.{}, &refused);
    _ = try host.host.vat.driveIngressBudgeted(.local, 64);
    try std.testing.expect(refused.broken);
    try std.testing.expectEqualStrings("AttachmentClosed", refused.reason());
}

test "loam managed revision restart reconstructs registration and current admission" {
    var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    var before: Probe = .{ .bias = 17 };
    var after: Probe = .{ .bias = 29 };
    const old_registration = [_]h.access.ContentBehavior{before.behavior()};
    const new_registration = [_]h.access.ContentBehavior{after.behavior()};
    host.service.contents = &old_registration;
    store.evict();
    var answer: h.Answer = .{};
    try host.send(host.use, "get", &.{}, &answer);
    try selected(&host, &backend, &before);
    for (0..128) |_| {
        try host.attached.advance();
        if (host.attached.operations[0].phase == .scheduled) break;
        if (try host.reads(&backend)) |_| return error.UnexpectedWrite;
    }
    try std.testing.expect(host.attached.operations[0].phase == .scheduled);
    try std.testing.expectEqual(@as(usize, 0), before.invocations);
    host.service.contents = &new_registration;
    _ = try h.f.change(&store, &backend, data.owner, .{ .pause = data.grant });
    try host.drain(&backend);
    try std.testing.expect(answer.broken);
    try std.testing.expect(after.requirements != 0);
    try std.testing.expect(before.bound_resource.?.id.eql(data.resource));
    try std.testing.expect(after.bound_resource.?.id.eql(data.resource));
    // Grant-only changes leave descriptive resource revision unchanged. The
    // Store restart still rechecks admission and refuses the paused grant.
    try std.testing.expectEqual(before.bound_resource.?.revision, after.bound_resource.?.revision);
    try std.testing.expectEqual(@as(usize, 0), before.invocations);
    try std.testing.expectEqual(@as(usize, 0), after.invocations);
    try std.testing.expectEqual(@as(usize, 0), host.caps.operations);
}

test "loam managed registration selection refusal releases the content lease" {
    for ([_]bool{ false, true }) |duplicate| {
        var backend = try h.loam.Volatile.init(a, h.f.store_id, 16 * 1024 * 1024);
        defer backend.deinit();
        var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        const data = try h.seed(&store, &backend);
        var host: h.Hosted = undefined;
        try host.init(&store, &backend, data);
        defer host.deinit();
        const registrations = [_]h.access.ContentBehavior{ host.contents[0], host.contents[0] };
        host.service.contents = if (duplicate) &registrations else &.{};
        store.evict();
        var answer: h.Answer = .{};
        try host.send(host.use, "get", &.{}, &answer);
        try host.drain(&backend);
        try std.testing.expect(answer.broken);
        try std.testing.expectEqualStrings(if (duplicate) "DuplicateBehavior" else "UnknownBehavior", answer.reason());
        try std.testing.expectEqual(@as(usize, 0), host.caps.operations);
        store.evict();
        try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    }
}
