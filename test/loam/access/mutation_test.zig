//! Held CapTP mutation sequences retain exact outcomes and refuse stale replay.
const std = @import("std");
const f = @import("sharing_fixture.zig");
const h = f.h;

const RepeatedReply = struct {
    invoked: usize = 0,
    const occurrences = 65;
    fn requirement(_: ?*anyopaque, _: std.mem.Allocator, _: h.access.ContentInvocation) !h.c.core.Policy.Requirement {
        return .{ .permissions = &.{h.f.vocabulary.read} };
    }
    fn retry(_: ?*anyopaque, _: []const u8, _: []const h.driver.Value) !h.access.RetryMode {
        return .receipt;
    }
    fn invoke(context: ?*anyopaque, call: *h.access.ContentCall, _: h.access.ContentInvocation) !h.driver.Value {
        const self: *RepeatedReply = @ptrCast(@alignCast(context.?));
        self.invoked += 1;
        const target = try call.discloseExact(0);
        const nested = try call.allocator().alloc(h.driver.Value, occurrences - 1);
        @memset(nested, target);
        const outer = try call.allocator().alloc(h.driver.Value, 2);
        outer[0] = target;
        outer[1] = .{ .list = nested };
        return .{ .list = outer };
    }
    const Capture = struct {
        target: ?f.model.Reference = null,
        count: usize = 0,
        invalid: bool = false,
        pub fn record(context: ?*anyopaque, resolution: h.actors.Resolution) void {
            const self: *Capture = @ptrCast(@alignCast(context.?));
            if (resolution != .fulfilled or resolution.fulfilled != .list) {
                self.invalid = true;
                return;
            }
            const values = resolution.fulfilled.list;
            if (values.len != 2 or values[0] != .reference or values[1] != .list) {
                self.invalid = true;
                return;
            }
            self.target = values[0].reference;
            self.count = 1;
            for (values[1].list) |value| {
                if (value != .reference or !std.meta.eql(value.reference, self.target.?)) {
                    self.invalid = true;
                    return;
                }
                self.count += 1;
            }
        }
    };
};

test "loam invocation allowance replays repeated receipt capabilities from one binding" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var bound = try h.access.invocationAllocationBound(.{
        .arguments = .{ .values = 2, .bytes = "share-repeated".len },
        .reply = .{ .values = RepeatedReply.occurrences + 2, .capabilities = RepeatedReply.occurrences },
        .verb_bytes = "mutate".len,
        .held_occurrences = 1,
        .receipt = true,
    });
    // The trusted callback owns its two fresh reply containers separately.
    try bound.include((RepeatedReply.occurrences - 1) * @sizeOf(h.driver.Value), @alignOf(h.driver.Value), 1);
    try bound.include(2 * @sizeOf(h.driver.Value), @alignOf(h.driver.Value), 1);
    const call_bytes = try bound.physicalBytes();
    var server: h.Hosted = undefined;
    try server.initOptions(&store, &backend, data, .{ .call_bytes = call_bytes, .pending_bytes = call_bytes, .ingress_bytes = call_bytes, .sleep_policy = .every_turn });
    defer server.deinit();
    var app: RepeatedReply = .{};
    const contents = [_]h.access.ContentBehavior{.{ .schema = 7, .context = &app, .requirement = RepeatedReply.requirement, .retry = RepeatedReply.retry, .invoke = RepeatedReply.invoke }};
    server.service.contents = &contents;
    var client: f.Client = undefined;
    try client.init(&server);
    defer client.deinit();
    const args = [_]f.model.Argument{ .{ .integer = 1 }, .{ .string = "share-repeated" } };
    var first: RepeatedReply.Capture = .{};
    try client.send(client.parent, "mutate", &args, &first);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expect(!first.invalid);
    try std.testing.expectEqual(RepeatedReply.occurrences, first.count);
    {
        const endpoint = try h.c.load(&store, &backend, data.use);
        defer store.release(endpoint) catch unreachable;
        const row = try h.loam.access.records.EndpointRecord.decode(try store.currentView(endpoint));
        const receipt = try h.c.load(&store, &backend, (try row.mutations.lookup(1)).?);
        defer store.release(receipt) catch unreachable;
        try std.testing.expectEqual(@as(usize, 1), (try store.currentView(receipt)).edge_count);
    }
    store.evict();
    const revision = store.metadata.revision;
    var replay: RepeatedReply.Capture = .{};
    try client.send(client.parent, "mutate", &args, &replay);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expect(!replay.invalid);
    try std.testing.expectEqual(RepeatedReply.occurrences, replay.count);
    try std.testing.expectEqualDeep(first.target, replay.target);
    try std.testing.expectEqual(@as(usize, 1), app.invoked);
    try std.testing.expectEqual(revision, store.metadata.revision);
    try std.testing.expect(!server.attached.hasPendingWork());
}

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
