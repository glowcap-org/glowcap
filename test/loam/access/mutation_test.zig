//! Held CapTP mutation sequences retain exact outcomes and refuse stale replay.
const std = @import("std");
const f = @import("sharing_fixture.zig");
const h = f.h;

test "loam mutation retries retain exact results, match intent, expire and recheck authority" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var server: h.Hosted = undefined;
    try server.init(&store, &backend, data);
    defer server.deinit();
    var client: f.Client = undefined;
    try client.init(&server);
    defer client.deinit();
    var bare: h.Answer = .{};
    try client.send(client.parent, "add", &.{.{ .integer = 7 }}, &bare);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqualStrings("RetryRequired", bare.reason());
    var first: h.Answer = .{};
    try client.send(client.parent, "mutate", &.{ .{ .integer = 1 }, .{ .string = "add" }, .{ .integer = 7 } }, &first);
    const batch = try server.untilWrite(&backend);
    try std.testing.expect(first.number == null);
    try server.attached.completeWrite(batch.ticket, backend.commit(batch));
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqual(@as(?i64, 7), first.number);
    for (2..11) |sequence| {
        var answer: h.Answer = .{};
        try client.send(client.parent, "mutate", &.{ .{ .integer = @intCast(sequence) }, .{ .string = "add" }, .{ .integer = 1 } }, &answer);
        try server.drain(&backend);
        try client.pump();
        try std.testing.expectEqual(@as(?i64, @intCast(sequence + 6)), answer.number);
    }
    const revision = store.metadata.revision;
    var replay: h.Answer = .{};
    try client.send(client.parent, "mutate", &.{ .{ .integer = 3 }, .{ .string = "add" }, .{ .integer = 1 } }, &replay);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqual(@as(?i64, 9), replay.number);
    try std.testing.expectEqual(revision, store.metadata.revision);
    for ([_]struct { sequence: i64, amount: i64, reason: []const u8 }{
        .{ .sequence = 1, .amount = 7, .reason = "ReceiptExpired" },
        .{ .sequence = 3, .amount = 2, .reason = "OperationConflict" },
        .{ .sequence = 12, .amount = 1, .reason = "OperationOutOfOrder" },
    }) |request| {
        var answer: h.Answer = .{};
        try client.send(client.parent, "mutate", &.{ .{ .integer = request.sequence }, .{ .string = "add" }, .{ .integer = request.amount } }, &answer);
        try server.drain(&backend);
        try client.pump();
        try std.testing.expectEqualStrings(request.reason, answer.reason());
        try std.testing.expectEqual(revision, store.metadata.revision);
    }
    var revoked: h.Answer = .{};
    try server.mutate(server.control, 1, "revoke", &.{}, &revoked);
    try server.drain(&backend);
    try std.testing.expectEqual(@as(?bool, true), revoked.changed);
    var control_retry: h.Answer = .{};
    try server.mutate(server.control, 1, "revoke", &.{}, &control_retry);
    try server.drain(&backend);
    try std.testing.expectEqual(@as(?bool, true), control_retry.changed);
    var denied: h.Answer = .{};
    try client.send(client.parent, "mutate", &.{ .{ .integer = 3 }, .{ .string = "add" }, .{ .integer = 1 } }, &denied);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqualStrings("Revoked", denied.reason());
}

test "loam mutation failure does not consume sequence and receipt windows refuse exhaustion" {
    var fixture = try h.f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    const data = try h.seed(&fixture.store, &fixture.backend);
    var server: h.Hosted = undefined;
    try server.init(&fixture.store, &fixture.backend, data);
    defer server.deinit();
    var failed: h.Answer = .{};
    try server.mutate(server.use, 1, "fail", &.{.{ .integer = 99 }}, &failed);
    try server.drain(&fixture.backend);
    try std.testing.expect(failed.broken);
    var first: h.Answer = .{};
    try server.mutate(server.use, 1, "add", &.{.{ .integer = 4 }}, &first);
    try server.drain(&fixture.backend);
    try std.testing.expectEqual(@as(?i64, 4), first.number);
    const Window = h.loam.access.records.RetryWindow;
    const full: Window = .{ .next = std.math.maxInt(i64) };
    try std.testing.expectError(error.SequenceExhausted, full.lookup(full.next));
    try std.testing.expectError(error.ReceiptExpired, full.lookup(1));
    try std.testing.expectError(error.InvalidRecord, (Window{ .next = 1, .count = 1 }).lookup(1));
}
