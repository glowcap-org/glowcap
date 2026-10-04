//! Held controls narrow independently while grants remain the use authority.
const std = @import("std");
const m = @import("management_fixture.zig");
const c = m.c;
const f = m.f;
const h = m.h;

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
    const args: []const m.s.model.Argument = &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 }, .{ .integer = 7 } };
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
    try std.testing.expectEqual(@as(usize, 6), inspection.fields);
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

/// Exercise the preparation completion contract below Attachment's own ticket
/// guard. A rejected completion must leave the real request routable.
fn drainWithStaleCompletions(server: *h.Hosted, backend: anytype) !usize {
    var rejected: usize = 0;
    for (0..256) |_| {
        _ = try server.host.vat.driveIngressBudgeted(.local, 64);
        try server.attached.advance();
        while (try server.attached.nextWork()) |work| switch (work) {
            .read => |request| {
                for (server.attached.operations) |*operation| {
                    if (!operation.pending_read) continue;
                    const preparation = operation.call.?.preparation.?;
                    var stale = request.ticket;
                    stale.sequence += 1000;
                    try std.testing.expectError(error.StaleCompletion, preparation.completeRead(stale, .missing));
                    rejected += 1;
                }
                try server.attached.completeRead(request.ticket, backend.read(request));
            },
            .lookup => |request| try server.attached.completeLookup(request.ticket, backend.lookup(request)),
            .write => |batch| try server.attached.completeWrite(batch.ticket, backend.commit(batch)),
        };
        if (!server.attached.hasPendingWork()) return rejected;
    }
    return error.DidNotQuiesce;
}
