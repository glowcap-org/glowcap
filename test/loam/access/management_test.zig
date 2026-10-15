//! Held controls narrow independently while grants remain the use authority.
const std = @import("std");
const m = @import("management_fixture.zig");
const c = m.c;
const f = m.f;
const h = m.h;

test "loam management independent powers and cold indexed branch pages" {
    var fixture = try f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    try @import("management_inventory_cases.zig").run(&fixture.store, &fixture.backend);
}

test "loam management native controls narrow powers and revoke independently of held use" {
    var fixture = try f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    try @import("management_cases.zig").native(&fixture.store, &fixture.backend);
    try @import("management_cases.zig").composed(&fixture.store, &fixture.backend);
}

test "loam management CapTP issuance keeps control custody and exact recovery at the issuer" {
    var backend = try h.loam.Volatile.init(h.a, f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seedDepth(&store, &backend, 1);
    var server: h.Hosted = undefined;
    try server.init(&store, &backend, data);
    defer server.deinit();
    var client: m.s.Client = undefined;
    try client.init(&server);
    defer client.deinit();
    m.configure(&server);
    var first: m.Pair = .{};
    const args: []const m.s.model.Argument = &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 15 } };
    try client.send(client.parent, "derive-managed", args, &first);
    const batch = server.untilWrite(&backend) catch |err| {
        try client.pump();
        std.debug.print("managed issue refusal={s}\n", .{first.use.reason_buf[0..first.use.reason_len]});
        return err;
    };
    try client.pump();
    try std.testing.expect(first.use.ref == null and first.control.ref == null and !first.use.broken and !first.control.broken);
    try server.attached.completeWrite(batch.ticket, backend.commit(batch));
    try server.drain(&backend);
    try client.pump();
    const use = try first.use.require();
    const control = try first.control.require();
    try std.testing.expect(!std.meta.eql(use, control));
    const use_name = try publishedName(&server, &client, &backend, use);
    const control_name = try publishedName(&server, &client, &backend, control);
    try std.testing.expect(!std.mem.eql(u8, use_name.text(), control_name.text()));
    const revision = store.metadata.revision;
    var replay: m.Pair = .{};
    store.evict();
    try client.send(client.parent, "derive-managed", args, &replay);
    try std.testing.expect(try drainWithStaleCompletions(&server, &backend) > 0);
    try client.pump();
    try std.testing.expect(std.meta.eql(use, try replay.use.require()));
    try std.testing.expect(std.meta.eql(control, try replay.control.require()));
    try std.testing.expectEqual(revision, store.metadata.revision);
    var inspection: m.Inspection = .{};
    try client.send(control, "describe-control", &.{}, &inspection);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqual(@as(?bool, true), inspection.available);
    try std.testing.expectEqual(@as(usize, 10), inspection.fields);
    var own: GrantInspection = .{};
    store.evict();
    try client.send(control, "inspect-access", &.{}, &own);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqual(@as(usize, 9), own.fields);
    try std.testing.expect(!own.broken);
    var recipient: m.Pair = .{};
    try client.send(use, "derive-managed", args, &recipient);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expect(recipient.use.broken and recipient.control.broken);
    var child: m.s.captures.CapturedRef = .{};
    const attenuation: []const m.s.model.Argument = &.{ .{ .integer = 1 }, .{ .string = "attenuate-control" }, .{ .integer = 1 } };
    try client.send(control, "mutate", attenuation, &child);
    try server.drain(&backend);
    try client.pump();
    const limited = try child.require();
    const limited_name = try publishedName(&server, &client, &backend, limited);
    try std.testing.expect(!std.mem.eql(u8, limited_name.text(), control_name.text()));
    var private: GrantInspection = .{};
    try client.send(limited, "inspect-access", &.{}, &private);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expect(private.broken);
    var denied: h.Answer = .{};
    try client.send(limited, "revoke", &.{}, &denied);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqualStrings("Denied", denied.reason());
    var retired: h.Answer = .{};
    try client.send(control, "mutate", &.{ .{ .integer = 2 }, .{ .string = "revoke-control" } }, &retired);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqual(@as(?bool, true), retired.changed);
    var dead: m.Inspection = .{};
    try client.send(limited, "describe-control", &.{}, &dead);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqual(@as(?bool, false), dead.available);
    try std.testing.expectEqual(@as(usize, 1), dead.fields);
    var hidden_name: m.s.captures.CapturedString = .{};
    try client.send(limited, "durable-name", &.{}, &hidden_name);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expect(hidden_name.broken);
    var still_used: h.Answer = .{};
    try client.send(use, "get", &.{}, &still_used);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expectEqual(@as(?i64, 0), still_used.number);
    var refused_replay: m.s.captures.CapturedRef = .{};
    try client.send(control, "mutate", attenuation, &refused_replay);
    try server.drain(&backend);
    try client.pump();
    try std.testing.expect(refused_replay.broken);
}

fn publishedName(server: *h.Hosted, client: *m.s.Client, backend: anytype, ref: m.s.model.Reference) !m.s.captures.CapturedString {
    var name: m.s.captures.CapturedString = .{};
    const revision = server.caps.store.metadata.revision;
    try client.send(ref, "durable-name", &.{}, &name);
    try server.drain(backend);
    try client.pump();
    try std.testing.expect(!name.broken and name.text().len != 0);
    try std.testing.expectEqual(revision, server.caps.store.metadata.revision);
    var fetched: m.s.captures.CapturedRef = .{};
    try client.host.vowOn(try client.host.fetch(client.pair.a, name.text()), .{ .ctx = &fetched, .func = m.s.captures.CapturedRef.record });
    try client.pump();
    // The fixture's Host owns the original occurrence until teardown. Only the
    // fetched occurrence is temporary; wire encodings can differ for one actor.
    const original = try client.host.liftCapability(client.pair.a, ref);
    const restored = try client.host.liftCapability(client.pair.a, try fetched.require());
    defer client.host.releaseCapability(restored, 1) catch unreachable;
    try std.testing.expect(original.eql(restored));
    return name;
}

test "loam management publication abort and second endpoint pressure expose neither result" {
    for ([_]bool{ false, true }) |pressure| {
        var backend = try h.loam.Volatile.init(h.a, f.store_id, 16 * 1024 * 1024);
        defer backend.deinit();
        var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
        defer store.deinit() catch unreachable;
        const data = try h.seedDepth(&store, &backend, 1);
        var server: h.Hosted = undefined;
        try server.initOptions(&store, &backend, data, .{ .max_endpoints = if (pressure) 3 else 128 });
        defer server.deinit();
        var client: m.s.Client = undefined;
        try client.init(&server);
        defer client.deinit();
        m.configure(&server);
        const revision = store.metadata.revision;
        var result: m.Pair = .{};
        try client.send(client.parent, "derive-managed", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 15 } }, &result);
        if (pressure) try server.drain(&backend) else {
            const batch = try server.untilWrite(&backend);
            var hidden: usize = 0;
            var publications = server.host.publications.valueIterator();
            while (publications.next()) |publication| if (!publication.active) {
                try std.testing.expect((try server.host.publishedCapability(client.pair.b, publication.name)) == null);
                hidden += 1;
            };
            try std.testing.expectEqual(@as(usize, 2), hidden);
            try server.attached.completeWrite(batch.ticket, .{ .unchanged = error.InjectedAbort });
            try server.drain(&backend);
        }
        try client.pump();
        try std.testing.expect(result.use.broken and result.control.broken);
        try std.testing.expectEqualStrings(if (pressure) "EndpointCapacity" else "InjectedAbort", result.use.reason_buf[0..result.use.reason_len]);
        try std.testing.expectEqual(revision, store.metadata.revision);
        try std.testing.expectEqual(@as(u32, 1), server.host.publications.count());
        try std.testing.expectEqual(@as(usize, 0), server.caps.operations);
    }
}

const GrantInspection = struct {
    fields: usize = 0,
    broken: bool = false,
    pub fn record(ctx: ?*anyopaque, result: h.actors.Resolution) void {
        const self: *GrantInspection = @ptrCast(@alignCast(ctx.?));
        if (result == .broken) {
            self.broken = true;
        } else if (result.fulfilled == .tagged) {
            const tagged = result.fulfilled.tagged;
            if (std.mem.eql(u8, tagged.tag, "access:grant")) self.fields = tagged.value.len;
        }
    }
};

/// Exercise the preparation completion contract below Attachment's own ticket
/// guard. A rejected completion must leave the real request routable.
fn drainWithStaleCompletions(server: *h.Hosted, backend: anytype) !usize {
    const Worker = h.loam.hosting.Worker;
    var slot: [1]Worker.Slot = undefined;
    var worker: Worker = .init(&slot, backend.readerCapacity());
    var rejected: usize = 0;
    for (0..256) |_| {
        _ = try server.host.vat.driveIngressBudgeted(.local, 64);
        try server.attached.advance();
        while (try worker.next(server.attached, false)) |work| {
            if (work.request == .read) for (server.attached.operations) |*operation| {
                if (!operation.pending_read) continue;
                const preparation = operation.call.?.preparation.?;
                var stale = work.request.read.ticket;
                stale.sequence += 1000;
                try std.testing.expectError(error.StaleCompletion, preparation.completeRead(stale, .missing));
                rejected += 1;
            };
            try Worker.run(work, backend);
            try worker.complete(work, server.attached);
            try worker.release(work);
        }
        if (!server.attached.hasPendingWork()) return rejected;
    }
    return error.DidNotQuiesce;
}
