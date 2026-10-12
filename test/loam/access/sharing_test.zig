//! Atomic derivation and bounded retry semantics through held CapTP references.
//! Removing shared-read discovery notification makes the overlap test fail to
//! quiesce. The provider correctly refuses destruction with that work retained.
const std = @import("std");
const f = @import("sharing_fixture.zig");
const h = f.h;

test "loam sharing commits before discovery and returns the same narrower capability on retry" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedDepth(&store, &backend, 2);
    var server: h.Hosted = undefined;
    try server.init(&store, &backend, data);
    defer server.deinit();
    var client: f.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
    try client.init(&server);
    defer client.deinit();
    var answer: f.captures.CapturedRef = .{};
    try client.send(client.parent, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 1 } }, &answer);
    const batch = server.untilWrite(&backend) catch |err| {
        try client.pump();
        _ = try answer.require();
        return err;
    };
    try std.testing.expect(answer.ref == null and !answer.broken);
    var pending_name: h.driver.Host.DurableSwiss = undefined;
    var rows = server.host.publications.valueIterator();
    var found = false;
    while (rows.next()) |row| if (!row.active) {
        @memcpy(&pending_name.bytes, row.name);
        found = true;
    };
    try std.testing.expect(found);
    try std.testing.expect((try server.host.publishedCapability(client.pair.b, pending_name.slice())) == null);
    var hidden: f.captures.CapturedRef = .{};
    try client.host.vowOn(try client.host.fetch(client.pair.a, pending_name.slice()), .{ .ctx = &hidden, .func = f.captures.CapturedRef.record });
    try client.pump();
    try server.attached.completeWrite(batch.ticket, backend.commit(batch));
    try server.drain(&backend);
    try client.pump();
    try std.testing.expect(hidden.broken);
    const child = try answer.require();
    const revision = store.metadata.revision;
    const again = try client.derive(&server, &backend, 1, 0, 1);
    try std.testing.expect(std.meta.eql(child, again));
    try std.testing.expectEqual(revision, store.metadata.revision);
    var locator: f.captures.CapturedString = .{};
    try client.send(child, "durable-name", &.{}, &locator);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqualStrings(pending_name.slice(), locator.text());
    var denied: h.Answer = .{};
    try client.send(child, "add", &.{.{ .integer = 9 }}, &denied);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expect(denied.broken);
    var conflict: f.captures.CapturedRef = .{};
    try client.send(client.parent, "derive", &.{ .{ .integer = 1 }, .{ .integer = 1 }, .{ .integer = 1 } }, &conflict);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqualStrings("OperationConflict", conflict.reason_buf[0..conflict.reason_len]);
    var lifecycle_conflict: f.captures.CapturedRef = .{};
    try client.send(client.parent, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 1 }, .{ .boolean = true } }, &lifecycle_conflict);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqualStrings("OperationConflict", lifecycle_conflict.reason_buf[0..lifecycle_conflict.reason_len]);
    var escalation: f.captures.CapturedRef = .{};
    try client.send(child, "derive", &.{ .{ .integer = 1 }, .{ .integer = 1 }, .{ .integer = 0 } }, &escalation);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqualStrings("CeilingExceeded", escalation.reason_buf[0..escalation.reason_len]);
    var nested: f.captures.CapturedRef = .{};
    try client.send(child, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &nested);
    try server.drain(&backend);
    try client.pump();
    const grandchild = try nested.require();
    var exhausted: f.captures.CapturedRef = .{};
    try client.send(grandchild, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &exhausted);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqualStrings("DelegationDenied", exhausted.reason_buf[0..exhausted.reason_len]);
    const child_grant = try f.publishedGrant(&server, &backend, client.pair.b, pending_name.slice());
    _ = try h.f.change(&store, &backend, data.owner, .{ .revoke = child_grant });
    var child_revoked: f.captures.CapturedRef = .{};
    try client.send(client.parent, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 1 } }, &child_revoked);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqualStrings("Revoked", child_revoked.reason_buf[0..child_revoked.reason_len]);
    var parent_live: h.Answer = .{};
    try client.send(client.parent, "get", &.{}, &parent_live);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqual(@as(?i64, 0), parent_live.number);
    var revoked: h.Answer = .{};
    try server.send(server.control, "revoke", &.{}, &revoked);
    try server.drain(&backend);
    var replay: f.captures.CapturedRef = .{};
    try client.send(client.parent, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 1 } }, &replay);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqualStrings("Revoked", replay.reason_buf[0..replay.reason_len]);
    var descendant: h.Answer = .{};
    try client.send(grandchild, "get", &.{}, &descendant);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expect(descendant.broken);
}

test "loam sharing expires old sequences without reissuing and preserves published children" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedDepth(&store, &backend, 1);
    var server: h.Hosted = undefined;
    try server.init(&store, &backend, data);
    defer server.deinit();
    var client: f.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
    try client.init(&server);
    defer client.deinit();
    var first: ?f.model.Reference = null;
    for (1..h.loam.access.records.EndpointRecord.max_receipts + 2) |seq| {
        const child = try client.derive(&server, &backend, @intCast(seq), 0, 0);
        if (first == null) first = child;
    }
    const revision = store.metadata.revision;
    var expired: f.captures.CapturedRef = .{};
    try client.send(client.parent, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &expired);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqualStrings("ReceiptExpired", expired.reason_buf[0..expired.reason_len]);
    try std.testing.expectEqual(revision, store.metadata.revision);
    var locator: f.captures.CapturedString = .{};
    try client.send(first.?, "durable-name", &.{}, &locator);
    try server.drain(&backend);
    try client.pump();
    var fetched: f.captures.CapturedRef = .{};
    try client.host.vowOn(try client.host.fetch(client.pair.a, locator.text()), .{ .ctx = &fetched, .func = f.captures.CapturedRef.record });
    try client.pump();
    const original = try client.host.liftCapability(client.pair.a, first.?);
    const restored = try client.host.liftCapability(client.pair.a, try fetched.require());
    try std.testing.expect(original.eql(restored));
}

test "loam sharing aborts reserved publications and refuses endpoint pressure before writing" {
    for ([_]bool{ false, true }) |pressure| {
        var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
        defer backend.deinit();
        var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        const data = try h.seedDepth(&store, &backend, 1);
        var server: h.Hosted = undefined;
        try server.initOptions(&store, &backend, data, .{ .max_endpoints = if (pressure) 2 else 128 });
        defer server.deinit();
        var client: f.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
        try client.init(&server);
        defer client.deinit();
        const revision = store.metadata.revision;
        var failed: f.captures.CapturedRef = .{};
        try client.send(client.parent, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &failed);
        if (pressure) try server.drain(&backend) else {
            const batch = try server.untilWrite(&backend);
            try server.attached.completeWrite(batch.ticket, .{ .unchanged = error.InjectedAbort });
            try server.drain(&backend);
        }
        try client.pump();
        try std.testing.expectEqualStrings(if (pressure) "EndpointCapacity" else "InjectedAbort", failed.reason_buf[0..failed.reason_len]);
        try std.testing.expectEqual(revision, store.metadata.revision);
        try std.testing.expectEqual(@as(u32, 1), server.host.publications.count());
        try std.testing.expectEqual(@as(usize, 0), server.caps.operations);
        var next: h.Answer = .{};
        try client.send(client.parent, "derivation-sequence", &.{}, &next);
        try server.drain(&backend);
        try client.pump();
        try std.testing.expectEqual(@as(?i64, 1), next.number);
    }
}

test "loam cold discovery shares managed durable-name preparation read and its terminal result" {
    for ([_]bool{ false, true }) |corrupt| {
        var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
        defer backend.deinit();
        var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        const data = try h.seedDepth(&store, &backend, 1);
        var server: h.Hosted = undefined;
        try server.init(&store, &backend, data);
        defer server.deinit();
        var client: f.Client = .{ .host = undefined, .pair = undefined, .parent = undefined };
        try client.init(&server);
        defer client.deinit();
        const child = try client.derive(&server, &backend, 1, 0, 0);
        var name: f.captures.CapturedString = .{};
        try client.send(child, "durable-name", &.{}, &name);
        try server.drain(&backend);
        try client.pump();
        try server.host.removeDurable(name.text());
        try h.loam.hosting.publication.listen(server.attached, .{});
        store.evict();
        var held_name: f.captures.CapturedString = .{};
        try client.send(child, "durable-name", &.{}, &held_name);
        const descriptor_read = waiting: for (0..64) |_| {
            try server.attached.advance();
            while (try server.attached.nextWork()) |work| {
                const read = work.read;
                const result = backend.read(read);
                const view = try h.loam.core.RecordView.decode(read.buffer[0..result.found.length], store.limits.records, &h.schemas);
                if (view.schema == h.loam.hosting.publication.schema.id) break :waiting read;
                try server.attached.completeRead(read.ticket, result);
            }
        } else return error.NoPublicationRead;
        var fetched: f.captures.CapturedRef = .{};
        try client.host.vowOn(try client.host.fetch(client.pair.a, name.text()), .{ .ctx = &fetched, .func = f.captures.CapturedRef.record });
        try client.pump();
        const lookup = (try server.attached.nextWork()).?.lookup;
        try server.attached.completeLookup(lookup.ticket, backend.lookup(lookup));
        try server.attached.advance();
        // Discovery joins the existing preparation read instead of issuing one.
        try std.testing.expect((try server.attached.nextWork()) == null);
        const result = backend.read(descriptor_read);
        if (corrupt) {
            descriptor_read.buffer[0] ^= 1;
            try std.testing.expectError(error.Corrupt, server.attached.completeRead(descriptor_read.ticket, result));
        } else try server.attached.completeRead(descriptor_read.ticket, result);
        try server.drain(&backend);
        try client.pump();
        if (corrupt) {
            try std.testing.expectEqualStrings("Corrupt", fetched.reason_buf[0..fetched.reason_len]);
        } else {
            try std.testing.expectEqualStrings(name.text(), held_name.text());
            const original = try client.host.liftCapability(client.pair.a, child);
            const restored = try client.host.liftCapability(client.pair.a, try fetched.require());
            try std.testing.expect(original.eql(restored));
        }
        try std.testing.expect(!server.attached.hasPendingWork());
        try std.testing.expectEqual(@as(usize, 0), server.host.pending_operations);
    }
}
