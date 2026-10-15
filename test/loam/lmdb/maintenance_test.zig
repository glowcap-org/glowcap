//! Cleanup that compacts the LMDB file between phases and reopens cold.
const std = @import("std");
const h = @import("../access/hosting_fixture.zig");
const maintenance = @import("../access/maintenance_fixture.zig");
const Lmdb = @import("loam_lmdb").Lmdb;

test "loam LMDB maintenance reopens every bounded retirement phase without resurrection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", h.a);
    defer h.a.free(path);
    const terminated = try h.a.dupeSentinel(u8, path, 0);
    defer h.a.free(terminated);
    var db = try Lmdb.open(terminated, .{ .mode = .{ .create = h.f.store_id } });
    defer db.close() catch unreachable;
    var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &db);
    var result = try maintenance.change(&store, &db, data.owner, .retire, 0);
    for (0..64) |_| {
        if (result.retired) break;
        try store.deinit();
        try db.compact();
        try db.close();
        db = try Lmdb.open(terminated, .{ .mode = .{ .open = h.f.store_id } });
        store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
        try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
        result = try maintenance.change(&store, &db, data.owner, .step, result.sequence);
        const revision = store.metadata.revision;
        const retry = try maintenance.change(&store, &db, data.owner, .step, result.sequence - 1);
        try std.testing.expect(retry.replay);
        try std.testing.expectEqual(revision, store.metadata.revision);
        try @import("loam_test_support").collect(&store, &db);
    }
    try std.testing.expect(result.retired);
    try @import("loam_test_support").collect(&store, &db);
    try std.testing.expectEqual(@as(u64, 1), store.metadata.objects);
    try std.testing.expectError(error.Gone, h.c.load(&store, &db, data.use));
}

const sharing = @import("../access/sharing_fixture.zig");
const management = @import("../access/management_fixture.zig");

fn issuer(server: *h.Hosted, client: *sharing.Client) !sharing.model.Reference {
    const name = try server.host.publishDurableCapability(@splat(0x72), server.control);
    var captured: sharing.captures.CapturedRef = .{};
    try client.host.vowOn(try client.host.fetch(client.pair.a, name.slice()), .{ .ctx = &captured, .func = sharing.captures.CapturedRef.record });
    try client.pump();
    return captured.require();
}

fn refuse(server: *h.Hosted, client: *sharing.Client, db: *Lmdb, target: sharing.model.Reference, verb: []const u8, args: []const sharing.model.Argument, reason: []const u8) !void {
    const revision = server.attached.store.metadata.revision;
    var captured: sharing.captures.CapturedRef = .{};
    try client.send(target, verb, args, &captured);
    try server.drain(db);
    try client.pump();
    try std.testing.expectEqualStrings(reason, captured.reason_buf[0..captured.reason_len]);
    try std.testing.expectEqual(revision, server.attached.store.metadata.revision);
}

test "loam LMDB maintenance preserves expired and retired receipt refusal through collection and cold reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", h.a);
    defer h.a.free(path);
    const terminated = try h.a.dupeSentinel(u8, path, 0);
    defer h.a.free(terminated);
    var db = try Lmdb.open(terminated, .{ .mode = .{ .create = h.f.store_id } });
    defer db.close() catch unreachable;
    var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedDepth(&store, &db, 1);
    {
        var server: h.Hosted = undefined;
        try server.init(&store, &db, data);
        defer server.deinit();
        var client: sharing.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
        try client.init(&server);
        defer client.deinit();
        management.configure(&server);
        const control = try issuer(&server, &client);
        // Expire sequence one in both windows, then retire every returned
        // identity. The issuer's own use and control remain live.
        for (1..10) |sequence| {
            const child = try client.derive(&server, &db, @intCast(sequence), 0, 0);
            var name: sharing.captures.CapturedString = .{};
            try client.send(child, "durable-name", &.{}, &name);
            try server.drain(&db);
            try client.pump();
            const grant = try sharing.publishedGrant(&server, &db, client.pair.b, name.text());
            _ = try h.f.change(&store, &db, data.owner, .{ .revoke = grant });
            var attenuated: sharing.captures.CapturedRef = .{};
            try client.send(control, "mutate", &.{ .{ .integer = @intCast(sequence) }, .{ .string = "attenuate-control" }, .{ .integer = 1 } }, &attenuated);
            try server.drain(&db);
            try client.pump();
            var revoked: h.Answer = .{};
            try client.send(try attenuated.require(), "revoke-control", &.{}, &revoked);
            try server.drain(&db);
            try client.pump();
            try std.testing.expectEqual(@as(?bool, true), revoked.changed);
        }
        const admin = try server.restore(&db, data.owner);
        defer server.host.releaseCapability(admin, 1) catch unreachable;
        var arena = std.heap.ArenaAllocator.init(h.a);
        defer arena.deinit();
        _ = try @import("../access/maintenance_hosted_cases.zig").finish(&server, &db, admin, "sweep", 0, arena.allocator());
    }
    try @import("loam_test_support").collect(&store, &db);
    try store.deinit();
    try db.compact();
    try db.close();
    db = try Lmdb.open(terminated, .{ .mode = .{ .open = h.f.store_id } });
    store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    var server: h.Hosted = undefined;
    try server.init(&store, &db, data);
    defer server.deinit();
    var client: sharing.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
    try client.init(&server);
    defer client.deinit();
    management.configure(&server);
    const control = try issuer(&server, &client);
    // This deterministic test source replaces fresh OS randomness on reopen.
    // Keep its new names distinct from the immutable retired reservations.
    client.entropy_counter = 200;
    for ([_]u64{ 1, 9 }) |sequence| {
        const reason = if (sequence == 1) "ReceiptExpired" else "CapabilityRetired";
        try refuse(&server, &client, &db, client.parent, "derive", &.{ .{ .integer = @intCast(sequence) }, .{ .integer = 0 }, .{ .integer = 0 } }, reason);
        try refuse(&server, &client, &db, control, "mutate", &.{ .{ .integer = @intCast(sequence) }, .{ .string = "attenuate-control" }, .{ .integer = 1 } }, reason);
    }
    _ = try client.derive(&server, &db, 10, 0, 0);
    var fresh: sharing.captures.CapturedRef = .{};
    try client.send(control, "mutate", &.{ .{ .integer = 10 }, .{ .string = "attenuate-control" }, .{ .integer = 1 } }, &fresh);
    try server.drain(&db);
    try client.pump();
    _ = try fresh.require();
}
