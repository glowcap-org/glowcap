//! Managed local grants preserve issuance ceilings, selected authority paths,
//! ancestor restrictions, and terminal revocation. These exercise model calls;
//! they do not claim authenticated management, storage, or Host enforcement.

const std = @import("std");
const f = @import("grant_fixture.zig");
const core = f.core;
const Ledger = core.GrantLedger;

test "access dependency refusals preserve direct issuance derivation and policy editing state" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), f.kind, null);
    var descriptor = f.descriptor;
    descriptor.dependencies = &.{.{ .permission = f.post, .required = f.read }};
    var ledger = try Ledger.init(std.testing.allocator, &graph, descriptor, .{ .capacity = 8 });
    defer ledger.deinit() catch unreachable;
    const full = try f.terms(.{ .object = resource }, &.{ f.read, f.post }, null);
    var invalid = full;
    invalid.policy.permissions = 2; // Direct calls can bypass a value constructor.
    const initial = ledger.version();
    try std.testing.expectError(error.MissingPrerequisite, ledger.issueRootCopying(initial, f.issue(invalid, 1)));
    try std.testing.expectEqualDeep(initial, ledger.version());
    const root = (try ledger.issueRootCopying(initial, f.issue(full, 2))).grant;
    const before = ledger.version();
    try std.testing.expectError(error.MissingPrerequisite, ledger.deriveCopying(before, root, f.issue(invalid, 0)));
    try std.testing.expectError(error.MissingPrerequisite, ledger.setPolicyCopying(before, root, invalid));
    var resources = graph.readView();
    const policy = try core.Policy.init(descriptor);
    const powers: core.Control.Powers = .{ .policy_ceiling = full };
    const malformed: core.Control.Powers = .{ .policy_ceiling = invalid };
    try std.testing.expectError(error.MissingPrerequisite, core.Control.validate(&resources, &policy, full, malformed));
    try std.testing.expectError(error.MissingPrerequisite, core.Control.attenuate(&resources, &policy, powers, malformed));
    try std.testing.expectError(error.MissingPrerequisite, core.Control.command(&resources, &policy, root, powers, .{ .set_policy = invalid }));
    try std.testing.expectEqualDeep(before, ledger.version());
    const child = (try ledger.deriveCopying(before, root, f.issue(full, 0))).grant;
    try ledger.require(child, resource, .{ .permissions = &.{f.post} });
    _ = try ledger.setPolicyCopying(ledger.version(), root, try f.terms(.{ .object = resource }, &.{f.read}, null));
    try std.testing.expectError(error.Denied, ledger.require(child, resource, .{ .permissions = &.{f.post} }));
}

test "access child ceiling captures current access and survives parent edits" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const room = try graph.create(graph.revision(), f.kind, null);
    const message = try graph.create(graph.revision(), f.kind, room);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 8 });
    defer ledger.deinit() catch unreachable;
    const full = try f.terms(.{ .owned_subtree = room }, &.{ f.read, f.post }, null);
    const observer = try f.terms(.{ .owned_subtree = room }, &.{f.read}, 50);
    const parent = (try ledger.issueRootCopying(ledger.version(), .{ .ceiling = full, .configured = observer, .delegation_depth = 3 })).grant;
    try std.testing.expectError(error.CeilingExceeded, ledger.deriveCopying(ledger.version(), parent, f.issue(full, 0)));
    const child_terms = try f.terms(.{ .object = message }, &.{f.read}, 50);
    const child = (try ledger.deriveCopying(ledger.version(), parent, f.issue(child_terms, 1))).grant;
    _ = try ledger.setPolicyCopying(ledger.version(), parent, full);
    try std.testing.expectError(error.Denied, ledger.require(child, message, .{ .permissions = &.{f.post} }));
    try std.testing.expectError(error.Denied, ledger.require(child, message, .{ .permissions = &.{f.read}, .facts = &.{.{ .key = f.history, .value = 49 }} }));
    try std.testing.expectError(error.CeilingExceeded, ledger.setPolicyCopying(ledger.version(), child, try f.terms(.{ .object = message }, &.{ f.read, f.post }, 50)));
    _ = try ledger.setPolicyCopying(ledger.version(), parent, try f.terms(.{ .owned_subtree = room }, &.{f.read}, 80));
    try std.testing.expectError(error.Denied, ledger.require(child, message, .{ .permissions = &.{f.read}, .facts = &.{.{ .key = f.history, .value = 60 }} }));
    try std.testing.expectError(error.CeilingExceeded, ledger.deriveCopying(ledger.version(), child, f.issue(child_terms, 0)));
    _ = try ledger.setPolicyCopying(ledger.version(), parent, full);
    try ledger.require(child, message, .{ .permissions = &.{f.read}, .facts = &.{.{ .key = f.history, .value = 60 }} });
    _ = try ledger.setPolicyCopying(ledger.version(), child, try f.terms(.{ .object = message }, &.{}, 50));
    _ = try ledger.setPolicyCopying(ledger.version(), parent, observer);
    _ = try ledger.setPolicyCopying(ledger.version(), parent, full);
    try std.testing.expectError(error.Denied, ledger.require(child, message, .{ .permissions = &.{f.read} }));
}

test "access paused edits and revocation affect exact dependent branches" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 8 });
    defer ledger.deinit() catch unreachable;
    const terms = try f.terms(.{ .object = resource }, &.{ f.read, f.post }, null);
    var request = f.issue(terms, 3);
    request.initial_status = .paused;
    const parent = (try ledger.issueRootCopying(ledger.version(), request)).grant;
    try std.testing.expectError(error.Paused, ledger.require(parent, resource, .{ .permissions = &.{f.read} }));
    try std.testing.expectError(error.Paused, ledger.deriveCopying(ledger.version(), parent, f.issue(terms, 0)));
    _ = try ledger.setPolicyCopying(ledger.version(), parent, terms);
    try std.testing.expectEqual(.paused, try ledger.effectiveStatus(parent));
    _ = try ledger.@"resume"(ledger.version(), parent);
    const child = (try ledger.deriveCopying(ledger.version(), parent, f.issue(terms, 2))).grant;
    const grandchild = (try ledger.deriveCopying(ledger.version(), child, f.issue(terms, 1))).grant;
    const sibling = (try ledger.deriveCopying(ledger.version(), parent, f.issue(terms, 0))).grant;
    const independent = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 0))).grant;
    _ = try ledger.pause(ledger.version(), parent);
    try std.testing.expectEqual(.paused, try ledger.effectiveStatus(grandchild));
    _ = try ledger.pause(ledger.version(), child);
    _ = try ledger.setPolicyCopying(ledger.version(), child, try f.terms(.{ .object = resource }, &.{f.read}, null));
    _ = try ledger.@"resume"(ledger.version(), parent);
    try std.testing.expectEqual(.paused, try ledger.effectiveStatus(child));
    _ = try ledger.@"resume"(ledger.version(), child);
    try std.testing.expectError(error.Denied, ledger.require(grandchild, resource, .{ .permissions = &.{f.post} }));
    _ = try ledger.pause(ledger.version(), grandchild);
    _ = try ledger.revoke(ledger.version(), child);
    try std.testing.expectEqual(.revoked, try ledger.effectiveStatus(grandchild));
    try std.testing.expectError(error.Revoked, ledger.@"resume"(ledger.version(), grandchild));
    try std.testing.expectError(error.Revoked, ledger.setPolicyCopying(ledger.version(), grandchild, terms));
    try std.testing.expectError(error.Revoked, ledger.deriveCopying(ledger.version(), grandchild, f.issue(terms, 0)));
    try ledger.require(sibling, resource, .{ .permissions = &.{f.post} });
    try ledger.require(independent, resource, .{ .permissions = &.{f.post} });
    _ = try ledger.revoke(ledger.version(), parent);
    try std.testing.expectError(error.Revoked, ledger.require(sibling, resource, .{ .permissions = &.{f.read} }));
    try ledger.require(independent, resource, .{ .permissions = &.{f.read} });
    const version = ledger.version();
    _ = try ledger.revoke(version, parent);
    try std.testing.expectEqualDeep(version, ledger.version());
}

test "access resource moves recheck all scopes and exact grants never retarget" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const a = try graph.create(graph.revision(), f.kind, null);
    const b = try graph.create(graph.revision(), f.kind, null);
    const message = try graph.create(graph.revision(), f.kind, a);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 8 });
    defer ledger.deinit() catch unreachable;
    const scope = try f.terms(.{ .owned_subtree = a }, &.{f.read}, null);
    const exact = try f.terms(.{ .object = message }, &.{f.read}, null);
    const parent = (try ledger.issueRootCopying(ledger.version(), f.issue(scope, 2))).grant;
    const child = (try ledger.deriveCopying(ledger.version(), parent, f.issue(exact, 1))).grant;
    const independent = (try ledger.issueRootCopying(ledger.version(), f.issue(exact, 0))).grant;
    try std.testing.expectError(error.CeilingExceeded, ledger.deriveCopying(ledger.version(), child, f.issue(try f.terms(.{ .owned_subtree = message }, &.{f.read}, null), 0)));
    try graph.reparent(graph.revision(), message, b);
    try std.testing.expectError(error.OutOfScope, ledger.require(child, message, .{ .permissions = &.{f.read} }));
    try ledger.require(independent, message, .{ .permissions = &.{f.read} });
    try graph.reparent(graph.revision(), message, a);
    try ledger.require(child, message, .{ .permissions = &.{f.read} });
    const later = try graph.create(graph.revision(), f.kind, a);
    try ledger.require(parent, later, .{ .permissions = &.{f.read} });
    try std.testing.expectError(error.OutOfScope, ledger.require(child, later, .{ .permissions = &.{f.read} }));
    try graph.destroy(graph.revision(), message);
    const replacement = try graph.create(graph.revision(), f.kind, a);
    try std.testing.expectEqual(message.slot, replacement.slot);
    try std.testing.expectError(error.Gone, ledger.require(independent, replacement, .{ .permissions = &.{f.read} }));
    _ = try ledger.revoke(ledger.version(), child);
    try std.testing.expectEqual(.revoked, try ledger.effectiveStatus(child));
}

test "access independent grants never union their permissions" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 2 });
    defer ledger.deinit() catch unreachable;
    const reader = (try ledger.issueRootCopying(ledger.version(), f.issue(try f.terms(.{ .object = resource }, &.{f.read}, null), 0))).grant;
    const writer = (try ledger.issueRootCopying(ledger.version(), f.issue(try f.terms(.{ .object = resource }, &.{f.post}, null), 0))).grant;
    try ledger.require(reader, resource, .{ .permissions = &.{f.read} });
    try ledger.require(writer, resource, .{ .permissions = &.{f.post} });
    for ([_]core.GrantId{ reader, writer }) |grant| try std.testing.expectError(error.Denied, ledger.require(grant, resource, .{ .permissions = &.{ f.read, f.post } }));
}
