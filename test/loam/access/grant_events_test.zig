//! Every committed grant mutation returns one owned event. Failed mutations and
//! unchanged requests return no event. Branch events describe the dependency
//! root without enumerating children. Delivery is not the enforcement mechanism.
//! A suppressed policy event was injected and caught by this suite.

const structural_policy = @import("grant_fixture.zig").structural_policy;
const std = @import("std");
const f = @import("grant_fixture.zig");
const core = f.core;
const Ledger = core.GrantLedger;

test "access grant events follow committed revisions and identify branch changes" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer ledger.deinit() catch unreachable;
    const full = try f.terms(.{ .object = resource }, &.{ f.read, f.post }, null);
    const issued = try ledger.issueRootCopying(ledger.version(), f.issue(full, 2));
    const root = issued.grant;
    try std.testing.expect(issued.kind == .issued and issued.kind.issued == null);
    try std.testing.expectEqualDeep(ledger.version(), issued.version);
    try std.testing.expectEqual(issued.version.grants, (try ledger.get(root)).revision);
    const derived = try ledger.deriveCopying(ledger.version(), root, f.issue(full, 0));
    const child = derived.grant;
    try std.testing.expect(derived.kind.issued.?.eql(root));
    try std.testing.expectEqualDeep(ledger.version(), derived.version);
    try std.testing.expectEqual(derived.version.grants, (try ledger.get(root)).revision);
    const child_revision = (try ledger.get(child)).revision;
    const observer = try f.terms(full.scope, &.{f.read}, null);
    const edit_event = try ledger.setPolicyCopying(ledger.version(), root, observer);
    try std.testing.expect(edit_event != null);
    const edited = edit_event.?;
    try std.testing.expect(edited.grant.eql(root));
    try std.testing.expect(edited.kind == .policy_changed);
    try std.testing.expectEqualDeep(ledger.version(), edited.version);
    // The one parent event covers descendants whose records did not change.
    try std.testing.expectEqual(child_revision, (try ledger.get(child)).revision);
    try std.testing.expectError(error.Denied, ledger.require(child, resource, .{ .permissions = &.{f.post} }));
    const paused = (try ledger.pause(ledger.version(), root)).?;
    try std.testing.expectEqual(.active, paused.kind.status_changed.before);
    try std.testing.expectEqual(.paused, paused.kind.status_changed.after);
    try std.testing.expectEqualDeep(ledger.version(), paused.version);
    try std.testing.expectEqual(.paused, try ledger.effectiveStatus(child));
    const resumed = (try ledger.@"resume"(ledger.version(), root)).?;
    try std.testing.expectEqual(.paused, resumed.kind.status_changed.before);
    try std.testing.expectEqual(.active, resumed.kind.status_changed.after);
    const revoked = (try ledger.revoke(ledger.version(), root)).?;
    try std.testing.expectEqual(.active, revoked.kind.status_changed.before);
    try std.testing.expectEqual(.revoked, revoked.kind.status_changed.after);
    try std.testing.expectEqualDeep(ledger.version(), revoked.version);
    try std.testing.expectError(error.Revoked, ledger.require(child, resource, .{ .permissions = &.{f.read} }));
    // Earlier events retain their meaning after later commits; none borrows terms.
    try std.testing.expectEqual(.paused, paused.kind.status_changed.after);
    try std.testing.expectEqual(@as(u64, 1), @backingInt(issued.version.grants));
}

test "access failed and unchanged grant mutations produce no change event" {
    var graph = try f.graphInit(std.testing.allocator);
    defer graph.deinit() catch unreachable;
    const resource = try graph.create(graph.revision(), &structural_policy, f.kind, null);
    var ledger = try Ledger.init(std.testing.allocator, &graph, f.descriptor, .{ .capacity = 4 });
    defer ledger.deinit() catch unreachable;
    const terms = try f.terms(.{ .objects = &.{resource} }, &.{f.read}, null);
    const root = (try ledger.issueRootCopying(ledger.version(), f.issue(terms, 1))).grant;
    var version = ledger.version();
    try std.testing.expectEqual(@as(?Ledger.Change, null), try ledger.@"resume"(version, root));
    try std.testing.expectEqual(@as(?Ledger.Change, null), try ledger.setPolicyCopying(version, root, terms));
    try std.testing.expectEqualDeep(version, ledger.version());
    try std.testing.expectError(error.CeilingExceeded, ledger.setPolicyCopying(version, root, try f.terms(terms.scope, &.{f.post}, null)));
    try std.testing.expectEqualDeep(version, ledger.version());
    const paused = (try ledger.pause(version, root)).?;
    try std.testing.expectError(error.RevisionConflict, ledger.pause(version, root));
    try std.testing.expectEqualDeep(paused.version, ledger.version());
    try std.testing.expect((try ledger.pause(ledger.version(), root)) == null);
    try std.testing.expectEqualDeep(paused.version, ledger.version());
    const revoked = (try ledger.revoke(ledger.version(), root)).?;
    version = ledger.version();
    try std.testing.expectEqual(.paused, revoked.kind.status_changed.before);
    try std.testing.expect((try ledger.revoke(version, root)) == null);
    try std.testing.expectError(error.Revoked, ledger.@"resume"(version, root));
    try std.testing.expectError(error.Revoked, ledger.setPolicyCopying(version, root, terms));
    try std.testing.expectEqualDeep(version, ledger.version());
}
