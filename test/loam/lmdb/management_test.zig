//! Exact issuer custody survives uncertain native commits and a new Host.
const std = @import("std");
const m = @import("../access/management_fixture.zig");
const h = m.h;
const Lmdb = @import("loam_lmdb").Lmdb;

test "loam LMDB management keeps control attenuation and independent retirement across native storage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", h.a);
    defer h.a.free(path);
    const terminated = try h.a.dupeSentinel(u8, path, 0);
    defer h.a.free(terminated);
    var db = try Lmdb.open(terminated, .{ .mode = .{ .create = h.f.store_id } });
    defer db.close() catch unreachable;
    var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    try @import("../access/management_cases.zig").native(&store, &db);
    try @import("../access/management_cases.zig").composed(&store, &db);
}

test "loam LMDB management recovers use and issuer control after lost issuance and attenuation replies" {
    for ([_]bool{ false, true }) |committed| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", h.a);
        defer h.a.free(path);
        const terminated = try h.a.dupeSentinel(u8, path, 0);
        defer h.a.free(terminated);
        var db = try Lmdb.open(terminated, .{ .mode = .{ .create = h.f.store_id } });
        defer db.close() catch unreachable;
        var store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        const data = try h.seedDepth(&store, &db, 1);
        const issue: []const m.s.model.Argument = &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 7 } };
        const attenuate: []const m.s.model.Argument = &.{ .{ .integer = 1 }, .{ .string = "attenuate-control" }, .{ .integer = 1 } };
        var first_control: ?h.loam.core.ObjectId = null;
        for (0..3) |phase| {
            if (phase != 0) {
                try store.deinit();
                try db.close();
                db = try Lmdb.open(terminated, .{ .mode = .{ .open = h.f.store_id } });
                store = try h.loam.core.Store.init(h.a, db.metadata, &h.schemas, h.limits);
            }
            var server: h.Hosted = undefined;
            try server.init(&store, &db, data);
            defer server.deinit();
            var client: m.s.Client = undefined;
            try client.init(&server);
            defer client.deinit();
            client.entropy_counter = 1000 + phase * 100;
            m.configure(&server);
            var result: m.Pair = .{};
            const before = store.metadata.revision;
            try client.send(client.parent, "derive-managed", issue, &result);
            if (phase == 0) {
                try uncertain(&server, &db, client.pair, committed);
                try std.testing.expect(result.use.ref == null and result.control.ref == null);
                continue;
            }
            try server.drain(&db);
            try client.pump();
            const use = try result.use.require();
            const control = try result.control.require();
            try std.testing.expectEqual(before + @intFromBool(phase == 1 and !committed), store.metadata.revision);
            var receipt_control: h.loam.core.ObjectId = undefined;
            {
                const source = try h.c.load(&store, &db, data.use);
                const endpoint = try h.loam.access.records.EndpointRecord.decode(try store.currentView(source));
                try store.release(source);
                const receipt = try h.c.load(&store, &db, endpoint.derivations.receipts[0]);
                receipt_control = (try h.loam.access.records.DerivationRecord.decode(try store.currentView(receipt))).control.?;
                try store.release(receipt);
            }
            if (first_control) |previous| try std.testing.expect(previous.eql(receipt_control)) else first_control = receipt_control;
            var limited: m.s.captures.CapturedRef = .{};
            const revision = store.metadata.revision;
            try client.send(control, "mutate", attenuate, &limited);
            if (phase == 1) {
                try uncertain(&server, &db, client.pair, committed);
                try std.testing.expect(limited.ref == null);
                continue;
            }
            try server.drain(&db);
            try client.pump();
            _ = try limited.require();
            try std.testing.expectEqual(revision + @intFromBool(!committed), store.metadata.revision);
            var observed: m.Inspection = .{};
            try client.send(try limited.require(), "describe-control", &.{}, &observed);
            try server.drain(&db);
            try client.pump();
            try std.testing.expectEqual(@as(?bool, true), observed.available);
            var paused: h.Answer = .{};
            try client.send(try limited.require(), "pause", &.{}, &paused);
            try server.drain(&db);
            try client.pump();
            try std.testing.expectEqual(@as(?bool, true), paused.changed);
            var denied: h.Answer = .{};
            try client.send(use, "get", &.{}, &denied);
            try server.drain(&db);
            try client.pump();
            try std.testing.expectEqualStrings("Paused", denied.reason());
        }
    }
}

fn uncertain(server: *h.Hosted, db: *Lmdb, pair: m.s.pairs.Pair, committed: bool) !void {
    const batch = try server.untilWrite(db);
    if (committed) try std.testing.expect(db.commit(batch) == .committed) else {
        var pending = try db.beginCommit(batch);
        pending.abort();
    }
    try server.attached.completeWrite(batch.ticket, .unknown);
    try std.testing.expectError(error.Busy, server.attached.destroy());
    try server.attached.resolve(batch.ticket, try db.recover(try server.attached.recoveryBatch()));
    try server.drain(db);
    // Drop the outbound reply while the actor has already confirmed it.
    while (try pair.b.takeOutbound()) |outgoing| {
        var owned = outgoing;
        owned.deinit();
    }
}
