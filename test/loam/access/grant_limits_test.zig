//! Grant quotas, stale revisions, and malformed identities refuse before
//! mutation. Tombstones retain their identity and consume bounded capacity.

const structural_policy = @import("grant_fixture.zig").structural_policy;
const std = @import("std");
const f = @import("grant_fixture.zig");
const core = f.core;
const Ledger = core.GrantLedger;

test "access grants bound delegation child counts and retained tombstones" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 3, .max_depth = 2, .max_children = 1 });
    defer ledger.deinit() catch unreachable;
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    try std.testing.expectError(error.DepthLimit, ledger.issueRootCopying(ledger.version(), f.issue(terms, 3)));
    const root = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 2))).grant;
    try std.testing.expectError(error.DelegationDenied, ledger.deriveCopying(ledger.version(), root, f.issue(terms, 2)));
    const child = (try ledger.deriveCopying(ledger.version(), root, f.issue(terms, 1))).grant;
    try std.testing.expectEqual(@as(u32, 1), (try ledger.get(root)).child_count);
    try std.testing.expectEqual(ledger.version().grants, (try ledger.get(root)).revision);
    try std.testing.expectError(error.ChildLimit, ledger.deriveCopying(ledger.version(), root, f.issue(terms, 0)));
    const leaf = (try ledger.deriveCopying(ledger.version(), child, f.issue(terms, 0))).grant;
    try std.testing.expectError(error.DelegationDenied, ledger.deriveCopying(ledger.version(), leaf, f.issue(terms, 0)));
    _ = try ledger.revoke(ledger.version(), child);
    const version = ledger.version();
    try std.testing.expectError(error.CapacityExceeded, ledger.issueRootCopying(version, f.issue(terms, 0)));
    try std.testing.expectError(error.ChildLimit, ledger.deriveCopying(version, root, f.issue(terms, 0)));
    try std.testing.expectEqualDeep(version, ledger.version());
    try std.testing.expectEqual(@as(u32, 3), ledger.count());
    try std.testing.expectEqual(.revoked, try ledger.effectiveStatus(leaf));
}

test "access grant changes reject stale graph and ledger revisions" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 8 });
    defer ledger.deinit() catch unreachable;
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    const request = f.issue(terms, 2);
    const root = (try ledger.issueRootCopying(ledger.version(), request)).grant;
    const old_graph = ledger.version();
    _ = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    const old_ledger = ledger.version();
    _ = try ledger.pause(ledger.version(), root);
    for ([_]Ledger.Version{ old_graph, old_ledger }) |stale| {
        try std.testing.expectError(error.RevisionConflict, ledger.issueRootCopying(stale, request));
        try std.testing.expectError(error.RevisionConflict, ledger.deriveCopying(stale, root, request));
        try std.testing.expectError(error.RevisionConflict, ledger.setPolicyCopying(stale, root, terms));
        try std.testing.expectError(error.RevisionConflict, ledger.pause(stale, root));
        try std.testing.expectError(error.RevisionConflict, ledger.@"resume"(stale, root));
        try std.testing.expectError(error.RevisionConflict, ledger.revoke(stale, root));
    }
    const before = ledger.version();
    _ = try ledger.pause(before, root);
    try std.testing.expectEqualDeep(before, ledger.version());
    try std.testing.expectEqual(@as(u32, 1), ledger.count());
    // Reach counter exhaustion without simulating 2^64 edits.
    ledger.current_revision = @fromBackingInt(std.math.maxInt(u64));
    const exhausted = ledger.version();
    try std.testing.expectError(error.RevisionExhausted, ledger.@"resume"(exhausted, root));
    try std.testing.expectError(error.RevisionExhausted, ledger.revoke(exhausted, root));
    try std.testing.expectError(error.RevisionExhausted, ledger.setPolicyCopying(exhausted, root, try f.terms(terms.scope, &.{}, null)));
    try std.testing.expectError(error.RevisionExhausted, ledger.issueRootCopying(exhausted, request));
    try std.testing.expectEqualDeep(exhausted, ledger.version());
    try std.testing.expectEqual(.paused, try ledger.effectiveStatus(root));
}

test "access grant identities and schemas fail closed without changing state" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 3 });
    defer ledger.deinit() catch unreachable;
    const terms = try f.terms(.{ .object = resource }, &.{f.read}, null);
    const root = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 1))).grant;
    const version = ledger.version();
    var invalid = root;
    invalid.owner = @fromBackingInt(99);
    try std.testing.expectError(error.ForeignOwner, ledger.get(invalid));
    try std.testing.expectError(error.ForeignOwner, ledger.deriveCopying(version, invalid, f.issue(terms, 0)));
    invalid = root;
    invalid.slot += 1;
    try std.testing.expectError(error.UnknownGrant, ledger.get(invalid));
    invalid = root;
    invalid.generation += 1;
    try std.testing.expectError(error.Gone, ledger.require(invalid, resource, .{ .permissions = &.{f.read} }));
    var wrong = terms;
    wrong.policy.schema = @fromBackingInt(99);
    try std.testing.expectError(error.WrongSchema, ledger.issueRootCopying(version, f.issue(wrong, 0)));
    try std.testing.expectError(error.WrongSchema, ledger.setPolicyCopying(version, root, wrong));
    try std.testing.expectEqualDeep(version, ledger.version());
    try std.testing.expectEqual(@as(u32, 1), ledger.count());
}
