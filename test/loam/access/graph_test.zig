//! Managed access structural invariants: identity, bounded containment, atomic refusal,
//! and allocation ownership. These are Zig model tests, not CapTP conformance.

const structural_policy = @import("grant_fixture.zig").structural_policy;
const std = @import("std");
const core = @import("glowcap").loam.access.core;
const Graph = core.Graph;
const kind: core.KindId = @fromBackingInt(@intCast(1));
const owner: core.OwnerId = @fromBackingInt(@intCast(100));

test "access resource identity separates owners and slot generations" {
    var graph = try Graph.init(std.testing.allocator, owner, .{ .capacity = 2 });
    defer graph.deinit() catch unreachable;
    var other = try Graph.init(std.testing.allocator, @fromBackingInt(@intCast(101)), .{ .capacity = 2 });
    defer other.deinit() catch unreachable;
    const first = try graph.create(graph.revision(), &structural_policy, kind, null);
    const foreign = try other.create(other.revision(), &structural_policy, kind, null);
    try std.testing.expectEqual(first.slot, foreign.slot);
    try std.testing.expectError(error.ForeignOwner, graph.get(foreign));
    try std.testing.expectError(error.ForeignOwner, graph.create(graph.revision(), &structural_policy, kind, foreign));
    try graph.destroy(graph.revision(), first);
    const replacement = try graph.create(graph.revision(), &structural_policy, kind, null);
    try std.testing.expectEqual(first.slot, replacement.slot);
    try std.testing.expect(!first.eql(replacement));
    try std.testing.expectError(error.Gone, graph.get(first));
    try std.testing.expectError(error.Gone, graph.destroy(graph.revision(), first));
    try std.testing.expectEqual(replacement, (try graph.get(replacement)).id);
}

test "access graph refuses malformed names and bounds capacity" {
    try std.testing.expectError(error.InvalidLimits, Graph.init(std.testing.allocator, owner, .{ .capacity = 0 }));
    var graph = try Graph.init(std.testing.allocator, owner, .{ .capacity = 1 });
    defer graph.deinit() catch unreachable;
    const root = try graph.create(graph.revision(), &structural_policy, kind, null);
    const before = graph.revision();
    try std.testing.expectError(error.CapacityExceeded, graph.create(before, &structural_policy, kind, null));
    try std.testing.expectEqual(before, graph.revision());
    try std.testing.expectEqual(@as(u32, 1), graph.count());
    var forged = root;
    forged.slot = 1;
    try std.testing.expectError(error.UnknownResource, graph.get(forged));
    forged = root;
    forged.generation = 0;
    try std.testing.expectError(error.UnknownResource, graph.get(forged));
}

test "access containment includes self and excludes independent roots" {
    var graph = try Graph.init(std.testing.allocator, owner, .{ .capacity = 5 });
    defer graph.deinit() catch unreachable;
    const root = try graph.create(graph.revision(), &structural_policy, kind, null);
    const child = try graph.create(graph.revision(), &structural_policy, kind, root);
    const grandchild = try graph.create(graph.revision(), &structural_policy, kind, child);
    const other = try graph.create(graph.revision(), &structural_policy, kind, null);
    try std.testing.expect(try graph.isDescendant(root, root));
    try std.testing.expect(try graph.isDescendant(grandchild, root));
    try std.testing.expect(!try graph.isDescendant(root, grandchild));
    try std.testing.expect(!try graph.isDescendant(grandchild, other));
    try std.testing.expectEqual(@as(u32, 2), (try graph.get(grandchild)).depth);
    try std.testing.expectEqual(child, (try graph.get(grandchild)).parent.?);
}

test "access failed moves leave every edge and revision unchanged" {
    var graph = try Graph.init(std.testing.allocator, owner, .{ .capacity = 6, .max_depth = 2 });
    defer graph.deinit() catch unreachable;
    const root = try graph.create(graph.revision(), &structural_policy, kind, null);
    const branch = try graph.create(graph.revision(), &structural_policy, kind, root);
    const leaf = try graph.create(graph.revision(), &structural_policy, kind, branch);
    const destination = try graph.create(graph.revision(), &structural_policy, kind, root);
    const before = graph.revision();
    try std.testing.expectError(error.ContainmentCycle, graph.reparent(before, &structural_policy, root, leaf));
    try std.testing.expectError(error.ContainmentCycle, graph.reparent(before, &structural_policy, branch, branch));
    // The branch itself would fit; its existing leaf would exceed the limit.
    try std.testing.expectError(error.DepthLimit, graph.reparent(before, &structural_policy, branch, destination));
    try std.testing.expectError(error.DepthLimit, graph.create(before, &structural_policy, kind, leaf));
    try std.testing.expectError(error.HasChildren, graph.destroy(before, branch));
    try std.testing.expectEqual(before, graph.revision());
    try std.testing.expectEqual(root, (try graph.get(branch)).parent.?);
    try std.testing.expectEqual(branch, (try graph.get(leaf)).parent.?);
    try std.testing.expectEqual(@as(u32, 2), (try graph.get(leaf)).depth);
    try std.testing.expectEqual(@as(u32, 4), graph.count());
}

test "access moves carry every descendant and preserve resource identities" {
    var graph = try Graph.init(std.testing.allocator, owner, .{ .capacity = 8 });
    defer graph.deinit() catch unreachable;
    const root = try graph.create(graph.revision(), &structural_policy, kind, null);
    const first = try graph.create(graph.revision(), &structural_policy, kind, root);
    const middle = try graph.create(graph.revision(), &structural_policy, kind, root);
    const last = try graph.create(graph.revision(), &structural_policy, kind, root);
    const leaf = try graph.create(graph.revision(), &structural_policy, kind, middle);
    const deep = try graph.create(graph.revision(), &structural_policy, kind, leaf);
    try graph.reparent(graph.revision(), &structural_policy, middle, null);
    try std.testing.expect((try graph.get(middle)).parent == null);
    try std.testing.expectEqual(@as(u32, 1), (try graph.get(leaf)).depth);
    try std.testing.expectEqual(@as(u32, 2), (try graph.get(deep)).depth);
    try std.testing.expect(!try graph.isDescendant(deep, root));
    try std.testing.expect(try graph.isDescendant(first, root));
    try std.testing.expect(try graph.isDescendant(last, root));
    try graph.reparent(graph.revision(), &structural_policy, middle, first);
    try std.testing.expectEqual(@as(u32, 4), (try graph.get(deep)).depth);
    try std.testing.expect(try graph.isDescendant(deep, root));
    try graph.destroy(graph.revision(), last);
    try graph.destroy(graph.revision(), deep);
    try graph.destroy(graph.revision(), leaf);
    try graph.destroy(graph.revision(), middle);
    try graph.destroy(graph.revision(), first);
    try graph.destroy(graph.revision(), root);
    try std.testing.expectEqual(@as(u32, 0), graph.count());
}

test "access subtree height checks every sibling branch" {
    var graph = try Graph.init(std.testing.allocator, owner, .{ .capacity = 7, .max_depth = 3 });
    defer graph.deinit() catch unreachable;
    const root = try graph.create(graph.revision(), &structural_policy, kind, null);
    const deep = try graph.create(graph.revision(), &structural_policy, kind, root);
    const leaf = try graph.create(graph.revision(), &structural_policy, kind, deep);
    const deepest = try graph.create(graph.revision(), &structural_policy, kind, leaf);
    // Insertion puts this shallow sibling before the deeper branch.
    const shallow = try graph.create(graph.revision(), &structural_policy, kind, root);
    const destination = try graph.create(graph.revision(), &structural_policy, kind, null);
    const before = graph.revision();
    try std.testing.expectError(error.DepthLimit, graph.reparent(before, &structural_policy, root, destination));
    try std.testing.expectEqual(before, graph.revision());
    try std.testing.expect((try graph.get(root)).parent == null);
    try std.testing.expectEqual(@as(u32, 1), (try graph.get(shallow)).depth);
    try std.testing.expectEqual(@as(u32, 3), (try graph.get(deepest)).depth);
    try graph.destroy(graph.revision(), deepest);
    try graph.reparent(graph.revision(), &structural_policy, root, destination);
    try std.testing.expectEqual(@as(u32, 2), (try graph.get(shallow)).depth);
    try std.testing.expectEqual(@as(u32, 2), (try graph.get(deep)).depth);
    try std.testing.expectEqual(@as(u32, 3), (try graph.get(leaf)).depth);
}

test "access mutations reject stale revisions including no-op moves" {
    var graph = try Graph.init(std.testing.allocator, owner, .{ .capacity = 3 });
    defer graph.deinit() catch unreachable;
    const root = try graph.create(graph.revision(), &structural_policy, kind, null);
    const stale = graph.revision();
    const child = try graph.create(stale, &structural_policy, kind, root);
    const current = graph.revision();
    try std.testing.expectError(error.RevisionConflict, graph.create(stale, &structural_policy, kind, null));
    try std.testing.expectError(error.RevisionConflict, graph.reparent(stale, &structural_policy, child, root));
    try std.testing.expectError(error.RevisionConflict, graph.destroy(stale, child));
    try graph.reparent(current, &structural_policy, child, root);
    try std.testing.expectEqual(current, graph.revision());
    try std.testing.expectEqual(@as(u32, 2), graph.count());
}

test "access exhausted generations and revisions never wrap" {
    var graph = try Graph.init(std.testing.allocator, owner, .{ .capacity = 1 });
    defer graph.deinit() catch unreachable;
    var root = try graph.create(graph.revision(), &structural_policy, kind, null);
    // Reach arithmetic boundaries without allocating 2^64 incarnations.
    graph.slots[root.slot].generation = std.math.maxInt(u64);
    root.generation = std.math.maxInt(u64);
    try graph.destroy(graph.revision(), root);
    try std.testing.expectError(error.Gone, graph.get(root));
    try std.testing.expectError(error.CapacityExceeded, graph.create(graph.revision(), &structural_policy, kind, null));
    graph.current_revision = @fromBackingInt(@intCast(std.math.maxInt(u64)));
    try std.testing.expectError(error.RevisionExhausted, graph.create(graph.revision(), &structural_policy, kind, null));
    try std.testing.expectEqual(@as(u32, 0), graph.count());
}

fn allocationOwnership(allocator: std.mem.Allocator) !void {
    var graph = try Graph.init(allocator, owner, .{ .capacity = 4 });
    defer graph.deinit() catch unreachable;
    const root = try graph.create(graph.revision(), &structural_policy, kind, null);
    const child = try graph.create(graph.revision(), &structural_policy, kind, root);
    _ = try graph.get(child);
    try std.testing.expect(try graph.isDescendant(child, root));
    try graph.reparent(graph.revision(), &structural_policy, child, null);
    try graph.destroy(graph.revision(), root);
    try graph.destroy(graph.revision(), child);
}

test "access graph allocation failures unwind without leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationOwnership, .{});
}

test "access graph reads and mutations allocate only at initialization" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try allocationOwnership(failing.allocator());
    try std.testing.expect(!failing.has_induced_failure);
}
