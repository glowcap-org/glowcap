//! Prepared grant writes expose only committed authority until a matching
//! completion. The tests use a fake storage boundary, not a persistent backend.

const structural_policy = @import("grant_fixture.zig").structural_policy;
const std = @import("std");
const f = @import("grant_fixture.zig");
const core = f.core;
const Ledger = core.GrantLedger;

test "access prepared grants stay private until their exact storage completion" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer f.deinitLedger(&ledger);
    const terms = try f.terms(.{ .object = resource }, &.{ f.read, f.post }, null);
    const before = ledger.version();
    const ticket = (try ledger.prepareCopying(before, .{ .issue_root = f.issue(terms, 2) })).?;
    try std.testing.expectEqualDeep(before, ledger.version());
    try std.testing.expectEqual(@as(u32, 0), ledger.count());
    try std.testing.expectError(error.Busy, ledger.issueRootCopying(before, f.issue(terms, 0)));
    try std.testing.expectError(error.Busy, graph.create(graph.revision(), &structural_policy, f.kind, null));
    try std.testing.expectError(error.Busy, graph.reparent(graph.revision(), &structural_policy, resource, null));
    try std.testing.expectError(error.Busy, graph.destroy(graph.revision(), resource));
    try std.testing.expectError(error.Busy, graph.deinit());
    try std.testing.expectError(error.Busy, ledger.deinit());
    try std.testing.expectError(error.WrongPhase, ledger.finishWrite(ticket, .committed));
    const write = try ledger.beginWrite(ticket);
    try std.testing.expectEqualDeep(ticket, write.ticket);
    try std.testing.expect(write.parent_record == null);
    try std.testing.expectError(error.UnknownGrant, ledger.get(write.record.id));
    try std.testing.expectError(error.WrongPhase, ledger.beginWrite(ticket));
    try std.testing.expectError(error.WrongPhase, ledger.commitVolatile(ticket));
    try std.testing.expectError(error.Busy, ledger.cancel(ticket));
    const completion = try ledger.finishWrite(ticket, .committed);
    try std.testing.expectEqualDeep(write.version, completion.committed.version);
    try std.testing.expectEqualDeep(write.record, try ledger.get(completion.committed.grant));
    try ledger.require(completion.committed.grant, resource, .{ .permissions = &.{f.read} });
    try std.testing.expectError(error.InvalidTransaction, ledger.finishWrite(ticket, .committed));
    _ = try graph.create(graph.revision(), &structural_policy, f.kind, null);
}

test "access prepared child writes include the atomic parent inventory update" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer f.deinitLedger(&ledger);
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    const parent = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 2))).grant;
    const before = ledger.version();
    const ticket = (try ledger.prepareCopying(before, .{ .derive = .{ .parent = parent, .request = f.issue(terms, 0) } })).?;
    const write = try ledger.beginWrite(ticket);
    try std.testing.expectEqual(@as(u32, 1), write.parent_record.?.child_count);
    try std.testing.expectEqual(write.version.grants, write.parent_record.?.revision);
    try std.testing.expectEqual(@as(u32, 0), (try ledger.get(parent)).child_count);
    try ledger.require(parent, resource, .{ .permissions = &.{f.read} });
    _ = try ledger.finishWrite(ticket, .committed);
    try std.testing.expectEqualDeep(write.parent_record.?, try ledger.get(parent));
    try std.testing.expectEqualDeep(write.record, try ledger.get(write.record.id));
}

test "access unchanged storage and pre-write cancellation preserve authority" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer f.deinitLedger(&ledger);
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    const parent = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 1))).grant;
    const before = ledger.version();
    const canceled = (try ledger.prepareCopying(before, .{ .revoke = parent })).?;
    try ledger.cancel(canceled);
    try std.testing.expectEqualDeep(before, ledger.version());
    try ledger.require(parent, resource, .{ .permissions = &.{f.read} });
    const ticket = (try ledger.prepareCopying(before, .{ .revoke = parent })).?;
    try std.testing.expect(ticket.sequence != canceled.sequence);
    _ = try ledger.beginWrite(ticket);
    try std.testing.expectError(error.InvalidTransaction, ledger.finishWrite(canceled, .committed));
    const unchanged = try ledger.finishWrite(ticket, .unchanged);
    try std.testing.expect(unchanged == .unchanged);
    try std.testing.expectEqualDeep(before, ledger.version());
    try ledger.require(parent, resource, .{ .permissions = &.{f.read} });
    const committed = (try ledger.prepareCopying(before, .{ .revoke = parent })).?;
    const event = try ledger.commitVolatile(committed);
    try std.testing.expectEqual(.revoked, event.kind.status_changed.after);
    try std.testing.expectError(error.Revoked, ledger.require(parent, resource, .{ .permissions = &.{f.read} }));
}

test "access uncertain writes fence use and keep storage memory until resolved" {
    for ([_]Ledger.Resolution{ .committed, .unchanged }) |resolution| {
        var graph = try f.graphInit(std.testing.allocator);
        defer graph.deinit() catch unreachable;
        const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
        var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 4 });
        defer f.deinitLedger(&ledger);
        const terms = try f.terms(.{ .objects = &.{resource} }, &.{f.read}, null);
        const parent = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 1))).grant;
        const before = ledger.version();
        const ticket = (try ledger.prepareCopying(before, .{ .set_policy = .{ .grant = parent, .terms = try f.terms(terms.scope, &.{}, null) } })).?;
        const write = try ledger.beginWrite(ticket);
        try std.testing.expectError(error.WrongPhase, ledger.resolveWrite(ticket, resolution));
        try std.testing.expect(try ledger.finishWrite(ticket, .unknown) == .recovery_required);
        try std.testing.expectEqualDeep(before, ledger.version());
        try std.testing.expectError(error.RecoveryRequired, ledger.require(parent, resource, .{ .permissions = &.{f.read} }));
        try std.testing.expectError(error.RecoveryRequired, ledger.get(parent));
        try std.testing.expectError(error.RecoveryRequired, ledger.effectiveStatus(parent));
        try std.testing.expectError(error.RecoveryRequired, ledger.revoke(before, parent));
        try std.testing.expectError(error.Busy, ledger.cancel(ticket));
        try std.testing.expectError(error.Busy, ledger.deinit());
        try std.testing.expectError(error.Busy, graph.deinit());
        try std.testing.expectError(error.Busy, graph.destroy(graph.revision(), resource));
        try std.testing.expectError(error.WrongPhase, ledger.finishWrite(ticket, .committed));
        try std.testing.expect(write.record.configured.scope.objects[0].eql(resource));
        const completion = try ledger.resolveWrite(ticket, resolution);
        if (resolution == .committed) {
            try std.testing.expectEqualDeep(write.version, completion.committed.version);
            try std.testing.expectError(error.Denied, ledger.require(parent, resource, .{ .permissions = &.{f.read} }));
        } else {
            try std.testing.expect(completion == .unchanged);
            try std.testing.expectEqualDeep(before, ledger.version());
            try ledger.require(parent, resource, .{ .permissions = &.{f.read} });
        }
        try std.testing.expectError(error.InvalidTransaction, ledger.resolveWrite(ticket, resolution));
    }
}

test "access storage tickets reject changed owner sequence and base" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer f.deinitLedger(&ledger);
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    const ticket = (try ledger.prepareCopying(ledger.version(), .{ .issue_root = f.issue(terms, 0) })).?;
    _ = try ledger.beginWrite(ticket);
    var invalid = [_]Ledger.Ticket{ ticket, ticket, ticket, ticket };
    invalid[0].owner = @fromBackingInt(99);
    invalid[1].sequence += 1;
    invalid[2].base.grants = @fromBackingInt(99);
    invalid[3].base.resources = @fromBackingInt(99);
    for (invalid) |wrong| {
        try std.testing.expectError(error.InvalidTransaction, ledger.finishWrite(wrong, .committed));
        try std.testing.expectError(error.InvalidTransaction, ledger.finishWrite(wrong, .unchanged));
        try std.testing.expectError(error.InvalidTransaction, ledger.finishWrite(wrong, .unknown));
    }
    try std.testing.expectEqual(@as(u32, 0), ledger.count());
    _ = try ledger.finishWrite(ticket, .committed);
}
