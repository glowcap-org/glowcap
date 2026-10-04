//! Observation registration, replay and waiting through the product CapTP path.
const h = @import("hosting_fixture.zig");

test "access observation hosted registration replay waiting and independent cancellation" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    try @import("observation_hosted_cases.zig").live(&store, &backend);
}

test "access observation hosted registration rolls back both fronts and refuses actor pressure" {
    const std = @import("std");
    const f = @import("sharing_fixture.zig");
    for ([_]bool{ false, true }) |pressure| {
        var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
        defer backend.deinit();
        var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        const data = try h.seed(&store, &backend);
        var server: h.Hosted = undefined;
        try server.initOptions(&store, &backend, data, .{ .max_endpoints = if (pressure) 2 else 128 });
        defer server.deinit();
        var client: f.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
        try client.init(&server);
        defer client.deinit();
        const revision = store.metadata.revision;
        var refused: f.captures.CapturedRef = .{};
        try client.send(client.parent, "mutate", &.{ .{ .integer = 1 }, .{ .string = "observe" } }, &refused);
        if (pressure) try server.drain(&backend) else {
            const batch = try server.untilWrite(&backend);
            try server.attached.completeWrite(batch.ticket, .{ .unchanged = error.InjectedAbort });
            try server.drain(&backend);
        }
        try client.pump();
        try std.testing.expectEqualStrings(if (pressure) "EndpointCapacity" else "InjectedAbort", refused.reason_buf[0..refused.reason_len]);
        try std.testing.expectEqual(revision, store.metadata.revision);
        try std.testing.expectEqual(@as(u32, 1), server.host.giftables.count());
        try std.testing.expectEqual(@as(usize, 0), server.caps.operations);
        var next: h.Answer = .{};
        try client.send(client.parent, "mutation-sequence", &.{}, &next);
        try server.drain(&backend);
        try client.pump();
        try std.testing.expectEqual(@as(?i64, 1), next.number);
    }
}

test "access observation maximum parked fanout leaves capacity for cold edits and delivery" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var limits = h.limits;
    // Cold wake-up can prepare every admitted receiver concurrently: one
    // actor portrait plus eight model bindings per call, and mutation slack.
    limits.max_leases = h.loam.access.records.ObservationIndexRecord.capacity * 9 + 8;
    // A commit can leave old pinned portraits beside their current generation
    // while Attachment restarts the waiting calls.
    limits.cache_slots = h.loam.access.records.ObservationIndexRecord.capacity * 2 + 16;
    limits.resident_bytes = limits.cache_slots * 64 * 1024;
    // Published fronts, native context/source preparations and mutation slack
    // share the same bounded tracing-retention registry.
    limits.max_retentions = h.loam.access.records.ObservationIndexRecord.capacity * 5 + 8;
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, limits);
    defer store.deinit() catch unreachable;
    try @import("observation_hosted_cases.zig").fanout(&store, &backend);
}
