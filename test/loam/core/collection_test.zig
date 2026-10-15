//! Tracing preserves current and historical authority while reclaiming cycles.
//! Disabling the sweep insertion barrier fails the late-edge scenario: it
//! loses both reachable descendants.
const std = @import("std");
const f = @import("fixture.zig");
const core = f.core;

const step = f.collectionStep;
const collect = f.collect;

test "loam collection reclaims cycles and weak targets without loading actors" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    const root = try store.allocateId();
    const child = try store.allocateId();
    const a = try store.allocateId();
    const b = try store.allocateId();
    var r = f.record(root, "root");
    r.rooted = true;
    r.edges = &.{ .{ .target = child }, .{ .target = a, .strength = .weak } };
    try store.putCopying(r, null);
    r = f.record(child, "child");
    r.edges = &.{.{ .target = root }};
    try store.putCopying(r, null);
    r = f.record(a, "cycle a");
    r.edges = &.{.{ .target = b }};
    try store.putCopying(r, null);
    r = f.record(b, "cycle b");
    r.edges = &.{.{ .target = a }};
    try store.putCopying(r, null);
    try f.commit(store, &fixture.backend);
    try collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 2), store.metadata.objects);
    try std.testing.expectEqual(@as(u64, 2), store.metadata.collection.reclaimed_objects);
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 3), fixture.backend.rows.count()); // Two objects and metadata; no leftover marks.
    try std.testing.expectError(error.Gone, f.load(store, &fixture.backend, a));
}

test "loam collection shades a new edge from an already scanned root before sweep" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    const root = try store.allocateId();
    const child = try store.allocateId();
    const leaf = try store.allocateId();
    var r = f.record(root, "root");
    r.rooted = true;
    try store.putCopying(r, null);
    r = f.record(child, "child");
    r.edges = &.{.{ .target = leaf }};
    try store.putCopying(r, null);
    try store.putCopying(f.record(leaf, "leaf"), null);
    try f.commit(store, &fixture.backend);
    while (store.metadata.collection.phase != .sweep) try step(store, &fixture.backend, 1);
    try step(store, &fixture.backend, 1); // Root is now behind the sweep cursor.
    try store.begin();
    r = f.record(root, "root");
    r.rooted = true;
    r.edges = &.{.{ .target = child }};
    try store.putCopying(r, 1);
    try f.commit(store, &fixture.backend);
    try collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 3), store.metadata.objects);
}

test "loam collection retains old snapshot edges and checked live custody" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    const parent = try store.allocateId();
    const child = try store.allocateId();
    var r = f.record(parent, "old");
    r.edges = &.{.{ .target = child }};
    try store.putCopying(r, null);
    try store.putCopying(f.record(child, "child"), null);
    try f.commit(store, &fixture.backend);
    const old = try f.load(store, &fixture.backend, parent);
    try store.begin();
    try store.putCopying(f.record(parent, "new"), 1);
    try f.commit(store, &fixture.backend);
    try collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 2), store.metadata.objects);
    try std.testing.expectEqualStrings("old", (try store.view(old)).payload);
    const retained = try store.retain(child);
    try store.release(old);
    try collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 1), store.metadata.objects);
    try store.releaseRetention(retained);
    try std.testing.expectError(error.InvalidRetention, store.releaseRetention(retained));
    try collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
}

test "loam collection admits a late live root before a sweep and fences worker ownership" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    const id = try store.allocateId();
    try store.putCopying(f.record(id, "live"), null);
    try f.commit(store, &fixture.backend);
    while (store.metadata.collection.phase != .sweep) try step(store, &fixture.backend, 1);
    const retained = try store.retain(id);
    const ticket = try store.prepareCollection(2);
    try std.testing.expectError(error.Busy, store.retain(id));
    try std.testing.expectError(error.Busy, store.acquire(id));
    try std.testing.expectError(error.Busy, store.deinit());
    const batch = try store.beginWrite(ticket);
    const outcome = fixture.backend.commit(batch);
    try std.testing.expect(outcome == .committed);
    try store.completeWrite(ticket, .unknown);
    try std.testing.expectError(error.RecoveryRequired, store.retain(id));
    try store.resolve(ticket, try fixture.backend.recover(try store.recoveryBatch()));
    try collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 1), store.metadata.objects);
    try store.releaseRetention(retained);
    try collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
}

test "loam collection preparation unwinds allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var fixture = try f.Fixture.init(allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    errdefer if (store.phase == .staging) store.abort() catch unreachable;
    const id = try store.allocateId();
    try store.putCopying(f.record(id, "held"), null);
    try f.commit(store, &fixture.backend);
    const root = try store.retain(id);
    defer store.releaseRetention(root) catch unreachable;
    const ticket = try store.prepareCollection(64);
    const outcome = fixture.backend.commit(try store.beginWrite(ticket));
    try store.completeWrite(ticket, outcome);
    if (outcome == .unchanged) return outcome.unchanged;
    try std.testing.expectEqual(@as(u64, 1), store.metadata.objects);
}

test "loam collection capacity failure aborts the whole tracing batch" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    const id = try store.allocateId();
    var r = f.record(id, "root");
    r.rooted = true;
    try store.putCopying(r, null);
    try f.commit(store, &fixture.backend);
    const before = store.metadata;
    // Root tracing needs marker/queue storage beyond the existing rows.
    fixture.backend.max_bytes = fixture.backend.stored_bytes;
    try std.testing.expectError(error.StorageCapacity, step(store, &fixture.backend, 3));
    try std.testing.expectEqualDeep(before, store.metadata);
    try std.testing.expectEqual(@as(usize, 2), fixture.backend.rows.count());
    fixture.backend.max_bytes = 1024 * 1024;
    try collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 1), store.metadata.objects);
}

test "loam collection cannot use an incomplete root snapshot when root capacity is exhausted" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    const id: core.ObjectId = .{ .store = f.id, .incarnation = 1, .sequence = 1 };
    const retained = try store.retain(id);
    defer store.releaseRetention(retained) catch unreachable;
    store.limits.max_collection_roots = 0;
    try std.testing.expectError(error.RetentionCapacity, store.prepareCollection(1));
    try std.testing.expectEqual(.idle, store.phase);
    try std.testing.expectError(error.Busy, store.deinit());
}

test "loam collection retains a pending read until its stale completion is retired" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    const id = try store.allocateId();
    try store.putCopying(f.record(id, "pending"), null);
    try f.commit(store, &fixture.backend);
    const read = (try store.acquire(id)).read;
    const result = fixture.backend.read(read);
    try collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 1), store.metadata.objects);
    try std.testing.expectError(error.StaleCompletion, store.completeRead(read.ticket, result));
    try collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
}
