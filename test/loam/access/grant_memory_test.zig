//! Retained selections are copied before a grant mutation commits. Allocation
//! failure cannot change grant identities, revisions, policies, or child counts.
//! Exact scopes, reads, and lifecycle changes allocate nothing after init.

const structural_policy = @import("grant_fixture.zig").structural_policy;
const std = @import("std");
const f = @import("grant_fixture.zig");
const core = f.core;
const Ledger = core.GrantLedger;

test "access grants own selections and safely edit from borrowed records" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const a = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    const b = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer ledger.deinit() catch unreachable;
    var selection = [_]core.ResourceId{ a, b };
    const terms = try f.terms(.{ .objects = &selection }, &.{f.read}, null);
    const root = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 1))).grant;
    selection[0] = b;
    try ledger.require(root, a, .{ .permissions = &.{f.read} });
    const borrowed = try ledger.get(root);
    const child = (try ledger.deriveCopying(ledger.version(), root, f.issue(borrowed.configured, 0))).grant;
    var replacement = borrowed.configured;
    replacement.policy = try ledger.policy.value(&.{}, &.{});
    _ = try ledger.setPolicyCopying(ledger.version(), root, replacement);
    _ = try ledger.setPolicyCopying(ledger.version(), root, try f.terms(.{ .object = a }, &.{f.read}, null));
    try std.testing.expectError(error.OutOfScope, ledger.require(child, b, .{ .permissions = &.{f.read} }));
    const child_record = try ledger.get(child);
    try std.testing.expectEqual(@as(usize, 2), child_record.configured.scope.objects.len);
    _ = try ledger.setPolicyCopying(ledger.version(), root, (try ledger.get(root)).ceiling);
    try ledger.require(child, b, .{ .permissions = &.{f.read} });
    try graph.destroy(graph.revision(), b);
    // A still-live first selection entry cannot hide the stale second one.
    try std.testing.expectError(error.Gone, ledger.require(child, a, .{ .permissions = &.{f.read} }));
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    var graph = try f.graphInit(allocator);
    defer graph.deinit() catch unreachable;
    const a = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    const b = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer ledger.deinit() catch unreachable;
    const terms = try f.terms(.{ .objects = &.{ a, b } }, &.{f.read}, null);
    var before = ledger.version();
    const root_change = ledger.issueRootCopying(before, f.issue(terms, 2)) catch |err| {
        try std.testing.expectEqualDeep(before, ledger.version());
        try std.testing.expectEqual(@as(u32, 0), ledger.count());
        return err;
    };
    const root = root_change.grant;
    before = ledger.version();
    const child_change = ledger.deriveCopying(before, root, f.issue(terms, 1)) catch |err| {
        try std.testing.expectEqualDeep(before, ledger.version());
        try std.testing.expectEqual(@as(u32, 1), ledger.count());
        try std.testing.expectEqual(@as(u32, 0), (try ledger.get(root)).child_count);
        return err;
    };
    const child = child_change.grant;
    before = ledger.version();
    const narrowed = try f.terms(.{ .objects = &.{a} }, &.{f.read}, null);
    _ = ledger.setPolicyCopying(before, child, narrowed) catch |err| {
        try std.testing.expectEqualDeep(before, ledger.version());
        try std.testing.expectEqual(@as(usize, 2), (try ledger.get(child)).configured.scope.objects.len);
        try ledger.require(child, b, .{ .permissions = &.{f.read} });
        return err;
    };
    try ledger.require(child, a, .{ .permissions = &.{f.read} });
    try std.testing.expectError(error.OutOfScope, ledger.require(child, b, .{ .permissions = &.{f.read} }));
}

test "access grant allocation failures preserve every commit boundary" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}

test "access exact grants and lifecycle perform no post-init allocation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    const allocator = failing.allocator();
    var graph = try f.graphInit(allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer ledger.deinit() catch unreachable;
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    const root = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 2))).grant;
    const child = (try ledger.deriveCopying(ledger.version(), root, f.issue(terms, 1))).grant;
    const leaf = (try ledger.deriveCopying(ledger.version(), child, f.issue(terms, 0))).grant;
    try ledger.require(leaf, resource, .{ .permissions = &.{f.read} });
    _ = try ledger.setPolicyCopying(ledger.version(), child, terms);
    _ = try ledger.pause(ledger.version(), root);
    try std.testing.expectEqual(.paused, try ledger.effectiveStatus(leaf));
    _ = try ledger.@"resume"(ledger.version(), root);
    _ = try ledger.revoke(ledger.version(), child);
    try std.testing.expectError(error.Revoked, ledger.require(leaf, resource, .{ .permissions = &.{f.read} }));
    try std.testing.expect(!failing.has_induced_failure);
}
