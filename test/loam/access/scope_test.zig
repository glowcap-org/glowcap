//! Scope validation checks selection limits, canonical order, and live ownership.

const structural_policy = @import("grant_fixture.zig").structural_policy;
const std = @import("std");
const core = @import("glowcap").loam.access.core;
const Graph = core.Graph;
const Scope = core.Scope;
const kind: core.KindId = @fromBackingInt(@intCast(7));

test "access selected scopes are bounded canonical and fully validated" {
    var graph = try Graph.init(std.testing.allocator, @fromBackingInt(@intCast(1)), .{ .capacity = 4 });
    defer graph.deinit() catch unreachable;
    const a = try graph.create(graph.revision(), &structural_policy, kind, null);
    const b = try graph.create(graph.revision(), &structural_policy, kind, null);
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
