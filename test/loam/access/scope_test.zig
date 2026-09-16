//! Managed access scope semantics: exact selection, future descendants, and current graph
//! coverage. These assertions do not claim grant or capability enforcement.

const std = @import("std");
const core = @import("glowcap").loam.access.core;
const Graph = core.Graph;
const Scope = core.Scope;
const kind: core.KindId = @fromBackingInt(@intCast(7));

test "access exact access cannot authorize future descendants" {
    var graph = try Graph.init(std.testing.allocator, @fromBackingInt(@intCast(1)), .{ .capacity = 4 });
    defer graph.deinit() catch unreachable;
    const root = try graph.create(graph.revision(), kind, null);
    const exact: Scope = .{ .object = root };
    const subtree: Scope = .{ .owned_subtree = root };
    const selected: Scope = .{ .objects = &.{root} };
    var resources = graph.readView();
    try std.testing.expect(try exact.isSubsetOf(&resources, subtree));
    try std.testing.expect(!try subtree.isSubsetOf(&resources, exact));
    try std.testing.expect(!try subtree.isSubsetOf(&resources, selected));
    const child = try graph.create(graph.revision(), kind, root);
    resources = graph.readView();
    try std.testing.expect(try subtree.contains(&resources, child));
    try std.testing.expect(!try exact.contains(&resources, child));
    try std.testing.expect(!try selected.contains(&resources, child));
}

test "access scope coverage changes with containment without retargeting exact IDs" {
    var graph = try Graph.init(std.testing.allocator, @fromBackingInt(@intCast(1)), .{ .capacity = 5 });
    defer graph.deinit() catch unreachable;
    const a = try graph.create(graph.revision(), kind, null);
    const b = try graph.create(graph.revision(), kind, null);
    const child = try graph.create(graph.revision(), kind, a);
    const child_scope: Scope = .{ .owned_subtree = child };
    const a_scope: Scope = .{ .owned_subtree = a };
    const b_scope: Scope = .{ .owned_subtree = b };
    const exact: Scope = .{ .object = child };
    var resources = graph.readView();
    try std.testing.expect(try child_scope.isSubsetOf(&resources, a_scope));
    try std.testing.expect(!try child_scope.isSubsetOf(&resources, b_scope));
    try graph.reparent(graph.revision(), child, b);
    resources = graph.readView();
    try std.testing.expect(!try child_scope.isSubsetOf(&resources, a_scope));
    try std.testing.expect(try child_scope.isSubsetOf(&resources, b_scope));
    try std.testing.expect(try exact.contains(&resources, child));
    try std.testing.expect(!try a_scope.contains(&resources, child));
}

test "access selected scopes are bounded canonical and fully validated" {
    var graph = try Graph.init(std.testing.allocator, @fromBackingInt(@intCast(1)), .{ .capacity = 4 });
    defer graph.deinit() catch unreachable;
    const a = try graph.create(graph.revision(), kind, null);
    const b = try graph.create(graph.revision(), kind, null);
    const selection: Scope = .{ .objects = &.{ a, b } };
    var resources = graph.readView();
    try std.testing.expect(try selection.contains(&resources, a));
    try std.testing.expect(try (Scope{ .object = b }).isSubsetOf(&resources, selection));
    try std.testing.expect(!try selection.isSubsetOf(&resources, .{ .object = a }));
    try std.testing.expect(try (Scope{ .objects = &.{} }).isSubsetOf(&resources, selection));
    try std.testing.expectError(error.NonCanonicalScope, (Scope{ .objects = &.{ b, a } }).validate(&resources));
    try std.testing.expectError(error.NonCanonicalScope, (Scope{ .objects = &.{ a, a } }).validate(&resources));
    var excessive: [core.max_scope_objects + 1]core.ResourceId = undefined;
    @memset(&excessive, a);
    try std.testing.expectError(error.ScopeLimit, (Scope{ .objects = &excessive }).validate(&resources));
    // A matching first entry must not hide a stale later entry.
    try graph.destroy(graph.revision(), b);
    resources = graph.readView();
    try std.testing.expectError(error.Gone, selection.contains(&resources, a));
    var foreign = a;
    foreign.owner = @fromBackingInt(@intCast(2));
    try std.testing.expectError(error.ForeignOwner, (Scope{ .object = foreign }).contains(&resources, a));
}

test "access scope cannot revive access when a destroyed slot is reused" {
    var graph = try Graph.init(std.testing.allocator, @fromBackingInt(@intCast(1)), .{ .capacity = 1 });
    defer graph.deinit() catch unreachable;
    const old = try graph.create(graph.revision(), kind, null);
    const exact: Scope = .{ .object = old };
    const subtree: Scope = .{ .owned_subtree = old };
    try graph.destroy(graph.revision(), old);
    const fresh = try graph.create(graph.revision(), kind, null);
    var resources = graph.readView();
    try std.testing.expectError(error.Gone, exact.contains(&resources, fresh));
    try std.testing.expectError(error.Gone, subtree.contains(&resources, fresh));
}
