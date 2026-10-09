//! Prepared writes retain bounded copied inputs. Completion, cancellation, and
//! uncertainty resolution perform no allocation. Failed preparation leaves
//! both the committed ledger and the graph reservation unchanged.

const structural_policy = @import("grant_fixture.zig").structural_policy;
const std = @import("std");
const f = @import("grant_fixture.zig");
const core = f.core;
const Ledger = core.GrantLedger;

test "access prepared writes copy selections and commit without allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 4 });
    const allocator = failing.allocator();
    var graph = try f.graphInit(allocator);
    defer graph.deinit() catch unreachable;
    const a = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    const b = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer f.deinitLedger(&ledger);
    var selection = [_]core.ResourceId{ a, b };
    const terms = try f.terms(.{ .objects = &selection }, &.{f.read}, null);
    const ticket = (try ledger.prepareCopying(ledger.version(), .{ .issue_root = f.issue(terms, 0) })).?;
    selection[0] = b;
    const write = try ledger.beginWrite(ticket);
    try std.testing.expect(write.record.ceiling.scope.objects[0].eql(a));
    try std.testing.expect(write.record.configured.scope.objects[0].eql(a));
    try std.testing.expect(try ledger.finishWrite(ticket, .unknown) == .recovery_required);
    const completion = try ledger.resolveWrite(ticket, .committed);
    try ledger.require(completion.committed.grant, a, .{ .permissions = &.{f.read} });
    const pause = (try ledger.prepareCopying(ledger.version(), .{ .pause = completion.committed.grant })).?;
    try ledger.cancel(pause);
    try std.testing.expect(!failing.has_induced_failure);
}

fn prepareFailures(allocator: std.mem.Allocator) !void {
    var graph = try f.graphInit(allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer f.deinitLedger(&ledger);
    const terms = try f.terms(.{ .objects = &.{resource} }, &.{f.read}, null);
    const before = ledger.version();
    const ticket = (ledger.prepareCopying(before, .{ .issue_root = f.issue(terms, 0) }) catch |err| {
        try std.testing.expectEqualDeep(before, ledger.version());
        try std.testing.expectEqual(@as(u32, 0), ledger.count());
        try std.testing.expect(ledger.pending == null);
        try std.testing.expect(graph.reservation == null);
        return err;
    }).?;
    _ = try ledger.beginWrite(ticket);
    _ = try ledger.finishWrite(ticket, .unchanged);
    try std.testing.expectEqualDeep(before, ledger.version());
    try std.testing.expect(graph.reservation == null);
    // An aborted slot can be proposed again, but its transaction ID is fresh.
    const next = (try ledger.prepareCopying(before, .{ .issue_root = f.issue(terms, 0) })).?;
    try std.testing.expect(next.sequence != ticket.sequence);
    try ledger.cancel(next);
}

test "access preparation allocation failures unwind without reserving the graph" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, prepareFailures, .{});
}

test "access transaction counters never wrap and no-op changes need no ticket" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer f.deinitLedger(&ledger);
    const terms = try f.terms(.{ .objects = &.{resource} }, &.{f.read}, null);
    const root = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 0))).grant;
    const before = ledger.version();
    ledger.transaction_sequence = std.math.maxInt(u64);
    try std.testing.expectError(error.TransactionExhausted, ledger.prepareCopying(before, .{ .issue_root = f.issue(terms, 0) }));
    try std.testing.expect((try ledger.prepareCopying(before, .{ .resume_access = root })) == null);
    try std.testing.expect(graph.reservation == null);
    try std.testing.expect(ledger.pending == null);
    try std.testing.expectEqualDeep(before, ledger.version());
    ledger.transaction_sequence = 1;
    graph.reservation_sequence = std.math.maxInt(u64);
    try std.testing.expectError(error.ReservationExhausted, ledger.prepareCopying(before, .{ .issue_root = f.issue(terms, 0) }));
    try std.testing.expect(ledger.pending == null);
    try std.testing.expectEqualDeep(before, ledger.version());
}
