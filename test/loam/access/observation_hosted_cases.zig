//! Real CapTP receives can wait while an independent cancellation lane runs.
const std = @import("std");
const d = @import("description_fixture.zig");
const f = d.f;
const h = d.h;

pub fn driveWaiting(server: *h.Hosted, backend: anytype) !void {
    for (0..64) |_| {
        _ = try server.host.vat.driveIngressBudgeted(.local, 64);
        try server.attached.advance();
        if (try server.reads(backend)) |batch| try server.attached.completeWrite(batch.ticket, backend.commit(batch));
    }
    try std.testing.expectEqual(@as(usize, 0), server.caps.operations);
    try std.testing.expectEqual(@as(usize, 0), server.caps.observations);
}

fn response(value: f.model.Argument, status: []const u8, changed: bool) !h.c.storage.Observation.Cursor {
    try std.testing.expect(value == .tagged);
    try std.testing.expectEqualStrings("access:observation", value.tagged.tag);
    const fields = value.tagged.value;
    try std.testing.expectEqual(@as(usize, 5), fields.len);
    try std.testing.expectEqual(@as(usize, @sizeOf(h.c.storage.Observation.Cursor)), fields[0].bytes.len);
    try d.expectStatus(fields[1], status);
    try std.testing.expectEqual(changed, fields[3].boolean);
    return fields[0].bytes[0..@sizeOf(h.c.storage.Observation.Cursor)].*;
}

pub fn live(store: *h.loam.core.Store, backend: anytype) !void {
    const data = try h.seed(store, backend);
    var server: h.Hosted = undefined;
    try server.init(store, backend, data);
    defer server.deinit();
    var client: f.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
    try client.init(&server);
    defer client.deinit();
    var memory = std.heap.ArenaAllocator.init(h.a);
    defer memory.deinit();
    const arena = memory.allocator();
    var registration: d.Capture = .{ .arena = arena };
    try client.send(client.parent, "mutate", &.{ .{ .integer = 1 }, .{ .string = "observe" } }, &registration);
    const batch = try server.untilWrite(backend);
    try std.testing.expect(registration.value == null and !registration.failed);
    var active: usize = 0;
    var names = server.host.publications.valueIterator();
    while (names.next()) |entry| if (entry.active) {
        active += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), active);
    try std.testing.expectEqual(@as(u32, 3), server.host.publications.count());
    try server.attached.completeWrite(batch.ticket, backend.commit(batch));
    try server.drain(backend);
    try client.pump();
    const registered = try registration.require();
    try std.testing.expect(registered == .list and registered.list.len == 2);
    const receiver = registered.list[0].reference;
    const canceller = registered.list[1].reference;
    const revision = store.metadata.revision;
    var replay: d.Capture = .{ .arena = arena };
    try client.send(client.parent, "mutate", &.{ .{ .integer = 1 }, .{ .string = "observe" } }, &replay);
    try server.drain(backend);
    try client.pump();
    try std.testing.expectEqualDeep(registered, try replay.require());
    try std.testing.expectEqual(revision, store.metadata.revision);
    var first: d.Capture = .{ .arena = arena };
    try client.send(receiver, "poll", &.{}, &first);
    try server.drain(backend);
    try client.pump();
    const cursor = try response(try first.require(), "active", true);
    var waiting: d.Capture = .{ .arena = arena };
    try client.send(receiver, "receive", &.{.{ .bytes = &cursor }}, &waiting);
    try driveWaiting(&server, backend);
    try client.pump();
    try std.testing.expect(waiting.value == null and !waiting.failed);
    for (0..40) |_| _ = try h.f.resource(store, backend, data.owner, null);
    try driveWaiting(&server, backend);
    try client.pump();
    try std.testing.expect(waiting.value == null and !waiting.failed);
    // A committed content edit wakes a parked receiver without retaining model
    // leases between calls, even after hidden activity expired its old history.
    var edit: h.Answer = .{};
    try server.mutate(server.use, 2, "add", &.{.{ .integer = 5 }}, &edit);
    try server.drain(backend);
    try client.pump();
    try std.testing.expectEqual(@as(?i64, 5), edit.number);
    const changed = try waiting.require();
    const second_cursor = try response(changed, "active", true);
    try std.testing.expect(changed.tagged.value[2].boolean);
    var noop: h.Answer = .{};
    try server.mutate(server.use, 3, "add", &.{.{ .integer = 0 }}, &noop);
    try server.drain(backend);
    try std.testing.expectEqual(@as(?i64, 5), noop.number);
    var unchanged: d.Capture = .{ .arena = arena };
    try client.send(receiver, "poll", &.{.{ .bytes = &second_cursor }}, &unchanged);
    try server.drain(backend);
    try client.pump();
    try std.testing.expectEqualDeep(second_cursor, try response(try unchanged.require(), "active", false));
    var late: d.Capture = .{ .arena = arena };
    try client.send(receiver, "receive", &.{.{ .bytes = &second_cursor }}, &late);
    try driveWaiting(&server, backend);
    var aborted: h.Answer = .{};
    try server.mutate(server.use, 4, "add", &.{.{ .integer = 1 }}, &aborted);
    const denied_batch = try server.untilWrite(backend);
    try server.attached.completeWrite(denied_batch.ticket, .{ .unchanged = error.InjectedAbort });
    try driveWaiting(&server, backend);
    try client.pump();
    try std.testing.expect(aborted.broken and late.value == null and !late.failed);
    _ = try h.f.change(store, backend, data.owner, .{ .pause = data.grant });
    try server.drain(backend);
    try client.pump();
    const paused_cursor = try response(try late.require(), "paused", true);
    var blocked: d.Capture = .{ .arena = arena };
    try client.send(receiver, "receive", &.{.{ .bytes = &paused_cursor }}, &blocked);
    try driveWaiting(&server, backend);
    var close: h.Answer = .{};
    try client.send(canceller, "cancel", &.{}, &close);
    try server.drain(backend);
    try client.pump();
    try std.testing.expectEqual(@as(?bool, true), close.changed);
    try std.testing.expect(blocked.failed);
    try std.testing.expectEqual(@as(u32, 1), server.host.publications.count());
    const cancelled_revision = store.metadata.revision;
    var again: h.Answer = .{};
    try client.send(canceller, "cancel", &.{}, &again);
    try server.drain(backend);
    try client.pump();
    try std.testing.expectEqual(@as(?bool, false), again.changed);
    try std.testing.expectEqual(cancelled_revision, store.metadata.revision);
    var retired: d.Capture = .{ .arena = arena };
    try client.send(client.parent, "mutate", &.{ .{ .integer = 1 }, .{ .string = "observe" } }, &retired);
    try server.drain(backend);
    try client.pump();
    try std.testing.expect(retired.failed);
    try std.testing.expectEqual(cancelled_revision, store.metadata.revision);
    // A freshly opened paused viewer must discover its exact receipt sequence
    // and register observation without invoking content or widening access.
    var next: d.Capture = .{ .arena = arena };
    try client.send(client.parent, "mutation-sequence", &.{}, &next);
    try server.drain(backend);
    try client.pump();
    const sequence = (try next.require()).integer;
    var reopened: d.Capture = .{ .arena = arena };
    try client.send(client.parent, "mutate", &.{ .{ .integer = sequence }, .{ .string = "observe" } }, &reopened);
    try server.drain(backend);
    try client.pump();
    const fronts = try @import("observation_fixture.zig").Fronts.from(try reopened.require());
    var paused: d.Capture = .{ .arena = arena };
    try client.send(fronts.receiver, "poll", &.{}, &paused);
    try server.drain(backend);
    try client.pump();
    _ = try response(try paused.require(), "paused", true);
    var cancelled: h.Answer = .{};
    try client.send(fronts.canceller, "cancel", &.{}, &cancelled);
    try server.drain(backend);
    try client.pump();
    try std.testing.expectEqual(@as(?bool, true), cancelled.changed);
}

pub fn fanout(store: *h.loam.core.Store, backend: anytype) !void {
    const o = @import("observation_fixture.zig");
    const capacity = h.loam.access.records.ObservationIndexRecord.capacity;
    const data = try h.seed(store, backend);
    var server: h.Hosted = undefined;
    try server.init(store, backend, data);
    // Each admitted call reserves the attachment's 64 KiB arena against its
    // ingress budget. Admit all 32 receivers and leave room for mutation and
    // cancellation on their independent lanes.
    server.host.vat.queue_limits.max_pending_bytes = 4 * 1024 * 1024;
    // Session scheduling may settle a whole ready burst during one attachment
    // advance. Budget one maximum-sized reply per parked receiver.
    try server.host.setSessionLimits(null, null, capacity * 4096, null, null);
    defer server.deinit();
    var client: f.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
    try client.init(&server);
    defer client.deinit();
    var memory = std.heap.ArenaAllocator.init(h.a);
    defer memory.deinit();
    var fronts: [capacity]o.Fronts = undefined;
    var cursors: [capacity]h.c.storage.Observation.Cursor = undefined;
    var waiting: [capacity]d.Capture = undefined;
    for (&fronts, &cursors, &waiting, 1..) |*front, *cursor, *capture, sequence| {
        var registration: d.Capture = .{ .arena = memory.allocator() };
        try client.send(client.parent, "mutate", &.{ .{ .integer = @intCast(sequence) }, .{ .string = "observe" } }, &registration);
        try server.drain(backend);
        try client.pump();
        front.* = try o.Fronts.from(try registration.require());
        var first: d.Capture = .{ .arena = memory.allocator() };
        try client.send(front.receiver, "poll", &.{}, &first);
        try server.drain(backend);
        try client.pump();
        cursor.* = try o.cursor(try first.require());
        capture.* = .{ .arena = memory.allocator() };
    }
    for (fronts, &cursors, &waiting) |front, *cursor, *capture| try client.send(front.receiver, "receive", &.{.{ .bytes = cursor }}, capture);
    try driveWaiting(&server, backend);
    for (waiting) |capture| try std.testing.expect(capture.value == null and !capture.failed);
    store.evict();
    var edited: h.Answer = .{};
    try server.mutate(server.use, capacity + 1, "add", &.{.{ .integer = 1 }}, &edited);
    const batch = try server.untilWrite(backend);
    try server.attached.completeWrite(batch.ticket, backend.commit(batch));
    // Drain the bounded transport between replies instead of producing an
    // entire burst before the byte-fed adapter can consume any frames.
    for (0..256) |_| {
        _ = try server.host.vat.driveIngressBudgeted(.local, 1);
        try server.attached.advance();
        if (try server.reads(backend)) |next| try server.attached.completeWrite(next.ticket, backend.commit(next));
        client.pump() catch |err| {
            std.log.err("fanout transport failed: server={s} client={s}", .{ client.pair.b.served.closeReason("active"), client.pair.a.served.closeReason("active") });
            return err;
        };
        if (!server.attached.hasPendingWork()) break;
    } else return error.DidNotQuiesce;
    try std.testing.expectEqual(@as(?i64, 1), edited.number);
    for (waiting) |capture| {
        _ = try response(try capture.require(), "active", true);
    }
    for (fronts) |front| {
        var closed: h.Answer = .{};
        try client.send(front.canceller, "cancel", &.{}, &closed);
        try server.drain(backend);
        try client.pump();
        try std.testing.expectEqual(@as(?bool, true), closed.changed);
    }
}
