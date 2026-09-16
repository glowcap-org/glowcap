//! Native grant references bound their live object count, retain aliases
//! without allocation, and own copied management scopes until final release.
const std = @import("std");
const f = @import("grant_fixture.zig");
const core = f.core;
const Ledger = core.GrantLedger;

test "access native capability quota counts objects and releases final aliases" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 2, .max_capabilities = 1 });
    defer f.deinitLedger(&ledger);
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    const root = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 0))).grant;
    const use = try ledger.createUse(root);
    const alias = try use.retain();
    use.release();
    try std.testing.expectEqual(@as(u32, 1), ledger.live_capabilities);
    try std.testing.expectError(error.CapacityExceeded, ledger.createUse(root));
    try std.testing.expectError(error.CapacityExceeded, ledger.createControlCopying(root, .{ .pause = true }));
    try std.testing.expectError(error.Busy, ledger.deinit());
    try alias.require(resource, .{ .permissions = &.{f.read} });
    alias.release();
    const control = try ledger.createControlCopying(root, .{ .pause = true });
    const control_alias = try control.retain();
    control.release();
    try std.testing.expectError(error.Busy, ledger.deinit());
    control_alias.release();
    try std.testing.expectEqual(@as(u32, 0), ledger.live_capabilities);
}

test "access management ceiling owns its scope and refuses wider factory terms" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), f.kind, null);
    const other = try graph.create(graph.revision(), f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 2 });
    defer f.deinitLedger(&ledger);
    const terms = try f.terms(.{ .objects = &.{ resource, other } }, &.{f.read}, null);
    const root = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 0))).grant;
    var selection = [_]core.ResourceId{resource};
    const limited = try f.terms(.{ .objects = &selection }, &.{f.read}, null);
    const control = try ledger.createControlCopying(root, .{ .policy_ceiling = limited });
    defer control.release();
    selection[0] = other;
    try std.testing.expectError(error.CeilingExceeded, control.prepareCopying(ledger.version(), .{ .set_policy = limited }));
    const original = try f.terms(.{ .object = resource }, &.{f.read}, null);
    const ticket = (try control.prepareCopying(ledger.version(), .{ .set_policy = original })).?;
    _ = try ledger.commitVolatile(ticket);
    try std.testing.expectError(error.CeilingExceeded, ledger.createControlCopying(root, .{
        .policy_ceiling = try f.terms(terms.scope, &.{ f.read, f.post }, null),
    }));
    try std.testing.expectEqual(@as(u32, 1), ledger.live_capabilities);
}

test "access capability allocation failures leave no binding or retained scope" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var graph = try f.graphInit(allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), f.kind, null);
    var ledger = try Ledger.init(allocator, &graph, f.descriptor, .{ .capacity = 2 });
    defer f.deinitLedger(&ledger);
    const terms = try f.terms(.{ .objects = &.{resource} }, &.{f.read}, null);
    const root = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 0))).grant;
    const use = try ledger.createUse(root);
    defer use.release();
    const control = try ledger.createControlCopying(root, .{ .policy_ceiling = terms });
    defer control.release();
    const alias = try control.retain();
    defer alias.release();
    try use.require(resource, .{ .permissions = &.{f.read} });
    try std.testing.expect(try alias.prepareCopying(ledger.version(), .{ .set_policy = terms }) == null);
}

test "access prepared edits retain their inputs after final control release" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var graph = try f.graphInit(failing.allocator());
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), f.kind, null);
    var ledger = try Ledger.init(failing.allocator(), &graph, f.descriptor, .{ .capacity = 2 });
    defer f.deinitLedger(&ledger);
    const terms = try f.terms(.{ .objects = &.{resource} }, &.{ f.read, f.post }, null);
    const root = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 0))).grant;
    const control = try ledger.createControlCopying(root, .{ .policy_ceiling = terms });
    var owned_control: ?*core.GrantControl = control;
    defer if (owned_control) |value| value.release();
    const use = try ledger.createUse(root);
    defer use.release();
    var selection = [_]core.ResourceId{resource};
    const replacement = try f.terms(.{ .objects = &selection }, &.{f.read}, null);
    const ticket = (try control.prepareCopying(ledger.version(), .{ .set_policy = replacement })).?;
    selection[0].generation += 1;
    control.release();
    owned_control = null;
    // Storage completion, reference sharing, and protected reads allocate no memory.
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    const alias = try use.retain();
    defer alias.release();
    const write = try ledger.beginWrite(ticket);
    try std.testing.expect(write.record.configured.scope.objects[0].eql(resource));
    _ = try ledger.finishWrite(ticket, .committed);
    try alias.require(resource, .{ .permissions = &.{f.read} });
    try std.testing.expectError(error.Denied, alias.require(resource, .{ .permissions = &.{f.post} }));
    try std.testing.expectEqual(allocations, failing.alloc_index);
}
