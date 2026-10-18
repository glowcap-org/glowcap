//! Held CapTP references, receipt refusal and publication fencing during cleanup.
const std = @import("std");
const d = @import("description_fixture.zig");
const h = d.h;
const f = d.f;
const records = h.loam.access.records;

pub fn step(server: *h.Hosted, backend: anytype, owner: h.driver.Capability, verb: []const u8, sequence: u64, allocator: std.mem.Allocator) !h.c.storage.Maintenance.Result {
    var capture: d.Capture = .{ .arena = allocator };
    _ = try server.host.vat.sendObservedFromIngress(.local, server.host.localActorFor(owner).?, .{ .verb = verb, .args = &.{.{ .integer = @intCast(sequence) }} }, .{ .ctx = &capture, .func = d.Capture.record });
    try server.drain(backend);
    const reply = try capture.require();
    if (reply != .tagged or !std.mem.eql(u8, reply.tagged.tag, "access:maintenance") or reply.tagged.value.len != 4) return error.InvalidMaintenanceReply;
    const fields = reply.tagged.value;
    return .{ .sequence = @intCast(fields[0].integer), .phase = std.meta.stringToEnum(records.MaintenancePosition.Phase, fields[1].symbol) orelse return error.InvalidMaintenanceReply, .retired = fields[2].boolean, .replay = fields[3].boolean };
}
pub fn finish(server: *h.Hosted, backend: anytype, owner: h.driver.Capability, verb: []const u8, sequence: u64, allocator: std.mem.Allocator) !h.c.storage.Maintenance.Result {
    var result = try step(server, backend, owner, verb, sequence, allocator);
    for (0..512) |_| {
        if (result.phase == .idle) return result;
        result = try step(server, backend, owner, "maintenance-step", result.sequence, allocator);
    }
    return error.NoProgress;
}

pub fn replay(store: *h.loam.core.Store, backend: anytype, collect: anytype) !void {
    const data = try h.seedDepth(store, backend, 1);
    var server: h.Hosted = undefined;
    try server.init(store, backend, data);
    defer server.deinit();
    var client: f.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
    try client.init(&server);
    defer client.deinit();
    const admin = try server.restore(backend, data.owner);
    defer server.host.releaseCapability(admin, 1) catch unreachable;
    var memory = std.heap.ArenaAllocator.init(h.a);
    defer memory.deinit();
    const arena = memory.allocator();
    const child = try client.derive(&server, backend, 1, 0, 0);
    var name: f.captures.CapturedString = .{};
    try client.send(child, "durable-name", &.{}, &name);
    try server.drain(backend);
    try client.pump();
    const grant = try f.publishedGrant(&server, backend, client.pair.b, name.text());
    _ = try h.f.change(store, backend, data.owner, .{ .revoke = grant });
    const before = store.metadata.objects;
    const swept = try finish(&server, backend, admin, "sweep", 0, arena);
    try std.testing.expect(!swept.retired);
    var denied: f.captures.CapturedRef = .{};
    const revision = store.metadata.revision;
    try client.send(client.parent, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &denied);
    try server.drain(backend);
    try client.pump();
    try std.testing.expectEqualStrings("CapabilityRetired", denied.reason_buf[0..denied.reason_len]);
    try std.testing.expectEqual(revision, store.metadata.revision);
    var held: h.Answer = .{};
    try client.send(child, "get", &.{}, &held);
    try server.drain(backend);
    try client.pump();
    try std.testing.expectEqualStrings("CapabilityRetired", held.reason());
    var fetched: f.captures.CapturedRef = .{};
    try client.host.vowOn(try client.host.fetch(client.pair.a, name.text()), .{ .ctx = &fetched, .func = f.captures.CapturedRef.record });
    try client.pump();
    try std.testing.expect(fetched.broken);
    var read: h.c.storage.Read = undefined;
    try read.init(h.a, store, data.owner, 4, null);
    errdefer read.deinit() catch unreachable;
    _ = try h.f.pump(&read, backend);
    var grants = try read.grantView();
    for (0..32) |_| {
        const parent = grants.borrow(data.grant) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try h.f.pump(&read, backend);
            continue;
        };
        defer grants.release();
        try std.testing.expectEqual(@as(u32, 0), parent.child_count);
        break;
    } else return error.NoProgress;
    try read.deinit();
    try collect(store, backend);
    try std.testing.expect(store.metadata.objects < before);
    _ = try client.derive(&server, backend, 2, 0, 0);
    const retired = try finish(&server, backend, admin, "retire-owner", swept.sequence, arena);
    try std.testing.expect(retired.retired);
    var obsolete: f.captures.CapturedRef = .{};
    try client.send(client.parent, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &obsolete);
    try server.drain(backend);
    try client.pump();
    try std.testing.expectEqualStrings("CapabilityRetired", obsolete.reason_buf[0..obsolete.reason_len]);
}

pub fn controlReceipt(store: *h.loam.core.Store, backend: anytype) !void {
    const data = try h.seed(store, backend);
    var server: h.Hosted = undefined;
    try server.init(store, backend, data);
    defer server.deinit();
    var client: f.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
    try client.init(&server);
    defer client.deinit();
    @import("management_fixture.zig").configure(&server);
    const swiss = try server.host.publishDurableCapability(@splat(0x72), server.control);
    var issuer: f.captures.CapturedRef = .{};
    try client.host.vowOn(try client.host.fetch(client.pair.a, swiss.slice()), .{ .ctx = &issuer, .func = f.captures.CapturedRef.record });
    try client.pump();
    const parent = try issuer.require();
    var result: f.captures.CapturedRef = .{};
    const args = [_]f.model.Argument{ .{ .integer = 1 }, .{ .string = "attenuate-control" }, .{ .integer = 1 } };
    try client.send(parent, "mutate", &args, &result);
    try server.drain(backend);
    try client.pump();
    const child = try result.require();
    var revoked: h.Answer = .{};
    try client.send(child, "revoke-control", &.{}, &revoked);
    try server.drain(backend);
    try client.pump();
    try std.testing.expectEqual(@as(?bool, true), revoked.changed);
    const admin = try server.restore(backend, data.owner);
    defer server.host.releaseCapability(admin, 1) catch unreachable;
    var memory = std.heap.ArenaAllocator.init(h.a);
    defer memory.deinit();
    _ = try finish(&server, backend, admin, "sweep", 0, memory.allocator());
    const revision = store.metadata.revision;
    var denied: f.captures.CapturedRef = .{};
    try client.send(parent, "mutate", &args, &denied);
    try server.drain(backend);
    try client.pump();
    try std.testing.expectEqualStrings("CapabilityRetired", denied.reason_buf[0..denied.reason_len]);
    try std.testing.expectEqual(revision, store.metadata.revision);
    var inspected: @import("management_fixture.zig").Inspection = .{};
    try client.send(parent, "describe-control", &.{}, &inspected);
    try server.drain(backend);
    try client.pump();
    try std.testing.expectEqual(@as(?bool, true), inspected.available);
    var usable: h.Answer = .{};
    try client.send(client.parent, "get", &.{}, &usable);
    try server.drain(backend);
    try client.pump();
    try std.testing.expectEqual(@as(?i64, 0), usable.number);
}
