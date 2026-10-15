//! Collector admission and receipt ownership. These internal scenarios hold
//! complete custody while removing per-batch work for unchanged holders.
const std = @import("std");
const f = @import("fixture.zig");

test "loam collection unchanged custody has no repeated roots or preparation allocations" {
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var fixture = try f.Fixture.init(allocator.allocator());
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    const id = try store.allocateId();
    var record = f.record(id, "held");
    record.rooted = true;
    try store.putCopying(record, null);
    try f.commit(store, &fixture.backend);
    const token = try store.retain(id);
    defer store.releaseRetention(token) catch unreachable;
    try f.collectionStep(store, &fixture.backend, 2);
    try f.collectionStep(store, &fixture.backend, 1);
    const allocations = allocator.alloc_index;
    _ = try store.prepareCollection(1);
    defer store.abort() catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), store.collection_work.?.roots.len);
    try std.testing.expectEqual(allocations, allocator.alloc_index);
}

test "loam collection clearing and finishing preserve custody across phase boundaries" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    const ids = try pair(store, &fixture.backend);
    store.limits.max_collection_roots = 1;
    const interrupted = try store.retain(ids[0]);
    try f.collectionStep(store, &fixture.backend, 1);
    try store.releaseRetention(interrupted);
    const limits = store.limits;
    try store.deinit();
    try fixture.backend.close();
    store.* = try f.core.Store.init(std.testing.allocator, try fixture.backend.open(), &f.schemas, limits);
    try std.testing.expectEqual(.clearing, store.metadata.collection.phase);
    const first = try store.retain(ids[0]);
    const ticket = try store.prepareCollection(1024);
    try std.testing.expectEqual(@as(usize, 0), store.collection_work.?.roots.len);
    try finish(store, &fixture.backend, ticket);
    try std.testing.expectEqual(.roots, store.metadata.collection.phase);
    try std.testing.expectEqual(@as(usize, 1), store.collector.?.roots.items.len);
    while (store.metadata.collection.phase != .finishing) try f.collectionStep(store, &fixture.backend, 1);
    try store.releaseRetention(first);
    for (0..4) |_| {
        const transient = try store.retain(ids[0]);
        try store.releaseRetention(transient);
    }
    const late = try store.retain(ids[0]);
    defer store.releaseRetention(late) catch unreachable;
    try std.testing.expectEqual(@as(usize, 0), store.collector.?.roots.items.len);
    try f.collect(store, &fixture.backend); // Finish, then capture the remaining holder afresh.
    try std.testing.expect(store.collector == null);
    try f.collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 2), store.metadata.objects);
}

test "loam collection abort and recovery acknowledge only submitted committed debt" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    const ids = try pair(store, &fixture.backend);
    try f.collectionStep(store, &fixture.backend, 1);
    const token = try store.retain(ids[0]);
    _ = try store.prepareCollection(1);
    const address = store.collection_work.?.roots.ptr;
    try store.releaseRetention(token);
    try std.testing.expect(address == store.collection_work.?.roots.ptr);
    try store.abort();
    try std.testing.expectEqual(@as(usize, 1), store.collector.?.roots.items.len);
    const aborted = try store.prepareCollection(1);
    _ = try store.beginWrite(aborted);
    try store.completeWrite(aborted, .{ .unchanged = error.StorageCapacity });
    try std.testing.expectEqual(@as(usize, 1), store.collector.?.roots.items.len);
    const uncertain = try store.prepareCollection(1);
    _ = try store.beginWrite(uncertain);
    try store.completeWrite(uncertain, .unknown);
    try store.resolve(uncertain, try fixture.backend.recover(try store.recoveryBatch()));
    try std.testing.expectEqual(@as(usize, 1), store.collector.?.roots.items.len);
    // A content receipt cannot acknowledge collection debt.
    try store.begin();
    try store.putCopying(f.record(ids[0], "changed"), 1);
    try f.commit(store, &fixture.backend);
    try std.testing.expectEqual(@as(usize, 1), store.collector.?.roots.items.len);
    const committed = try store.prepareCollection(1);
    const outcome = fixture.backend.commit(try store.beginWrite(committed));
    try std.testing.expect(outcome == .committed);
    try store.completeWrite(committed, .unknown);
    try std.testing.expectEqual(@as(usize, 1), store.collector.?.roots.items.len);
    try store.resolve(committed, try fixture.backend.recover(try store.recoveryBatch()));
    try std.testing.expectEqual(@as(usize, 0), store.collector.?.roots.items.len);
    try f.collect(store, &fixture.backend);
    try f.collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
}

test "loam collection admits each immutable portrait including completed and historical edges" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    const ids = try pair(store, &fixture.backend);
    try store.begin();
    const replacement = try store.allocateId();
    try store.putCopying(f.record(replacement, "replacement"), null);
    try f.commit(store, &fixture.backend);
    const request = (try store.acquire(ids[0])).read;
    const read_result = fixture.backend.read(request);
    const initial = try store.prepareCollection(1);
    // Completion may populate bytes while admission is frozen. Their first
    // later lease must report edges, even though the pending ID was captured.
    try store.completeRead(request.ticket, read_result);
    try finish(store, &fixture.backend, initial);
    try f.collectionStep(store, &fixture.backend, 1); // Shade the pending ID.
    const old = try store.resident(ids[0]);
    defer store.release(old) catch unreachable;
    const debt = store.collector.?.roots.items.len;
    const repeated = try store.resident(ids[0]);
    try store.release(repeated);
    try std.testing.expectEqual(debt, store.collector.?.roots.items.len);
    try store.begin();
    var record = f.record(ids[0], "new");
    record.edges = &.{.{ .target = replacement }};
    try store.putCopying(record, 1);
    try store.retainOnCommit();
    try f.commit(store, &fixture.backend);
    const current = try store.resident(ids[0]);
    defer store.release(current) catch unreachable;
    try std.testing.expectEqual(debt + 2, store.collector.?.roots.items.len);
    try std.testing.expectError(error.StaleSnapshot, store.currentView(old));
    try f.collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 3), store.metadata.objects);
}

test "loam collection cancels late read custody only after worker retirement" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    const ids = try pair(store, &fixture.backend);
    try f.collectionStep(store, &fixture.backend, 1);
    const request = (try store.acquire(ids[0])).read;
    try store.cancelRead(request.ticket);
    try f.collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 2), store.metadata.objects);
    try std.testing.expectError(error.Canceled, store.completeRead(request.ticket, fixture.backend.read(request)));
    try f.collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
}

test "loam collection refuses capacity before publishing tokens leases or reads" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    const ids = try pair(store, &fixture.backend);
    const loaded = try f.load(store, &fixture.backend, ids[1]);
    try store.release(loaded);
    store.limits.max_collection_roots = 1;
    try f.collectionStep(store, &fixture.backend, 1);
    const token = try store.retain(ids[0]);
    defer store.releaseRetention(token) catch unreachable;
    const sequence = store.cache.next;
    const bytes = store.cache.allocated_bytes;
    try std.testing.expectError(error.RetentionCapacity, store.retain(ids[1]));
    try std.testing.expectError(error.RetentionCapacity, store.resident(ids[1]));
    try std.testing.expectError(error.RetentionCapacity, store.acquire(ids[0]));
    try std.testing.expectEqual(sequence, store.cache.next);
    try std.testing.expectEqual(bytes, store.cache.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 1), store.collector.?.roots.items.len);
    for (store.cache.pins) |pin| try std.testing.expectEqual(@as(u64, 0), pin.sequence);
    try std.testing.expectError(error.InvalidObject, store.retain(.{ .store = @fromBackingInt(999), .incarnation = 1, .sequence = 1 }));
}

test "loam collection failed initial capture publishes no portrait reports" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    const ids = try pair(store, &fixture.backend);
    const lease = try f.load(store, &fixture.backend, ids[0]);
    defer store.release(lease) catch unreachable;
    store.limits.max_collection_roots = 1; // Parent plus its strong historical edge need two slots.
    try std.testing.expectError(error.RetentionCapacity, store.prepareCollection(1));
    try std.testing.expect(store.collector == null);
    for (store.cache.slots) |slot| if (slot.contents == .resident) {
        try std.testing.expect(!slot.contents.resident.collection_reported);
    };
    store.limits.max_collection_roots = 2;
    _ = try store.prepareCollection(1);
    try std.testing.expectEqual(@as(usize, 2), store.collector.?.roots.items.len);
    try store.abort();
}

fn pair(store: *f.core.Store, backend: anytype) ![2]f.core.ObjectId {
    try store.begin();
    const parent = try store.allocateId();
    const child = try store.allocateId();
    var record = f.record(parent, "parent");
    record.edges = &.{.{ .target = child }};
    try store.putCopying(record, null);
    try store.putCopying(f.record(child, "child"), null);
    try f.commit(store, backend);
    return .{ parent, child };
}

test "loam collection journal allocation refusal publishes no custody and remains retryable" {
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var fixture = try f.Fixture.init(allocator.allocator());
    defer fixture.deinit();
    const store = &fixture.store;
    const ids = try pair(store, &fixture.backend);
    const warm = try f.load(store, &fixture.backend, ids[1]);
    try store.release(warm);
    try f.collectionStep(store, &fixture.backend, 1);
    var tokens: [16]f.core.Retention = undefined;
    var held: usize = 0;
    defer for (tokens[0..held]) |token| store.releaseRetention(token) catch unreachable;
    for (&tokens) |*token| {
        token.* = try store.retain(ids[0]);
        held += 1;
    }
    try std.testing.expectEqual(@as(usize, 16), store.collector.?.roots.capacity);
    const retention_sequence = store.retentions.sequence;
    const read_sequence = store.cache.next;
    allocator.fail_index = allocator.alloc_index;
    allocator.resize_fail_index = allocator.resize_index;
    try std.testing.expectError(error.OutOfMemory, store.retain(ids[1]));
    try std.testing.expectError(error.OutOfMemory, store.resident(ids[1]));
    try std.testing.expectError(error.OutOfMemory, store.acquire(ids[0]));
    try std.testing.expectEqual(retention_sequence, store.retentions.sequence);
    try std.testing.expectEqual(read_sequence, store.cache.next);
    try std.testing.expectEqual(@as(usize, 16), store.collector.?.roots.items.len);
    for (store.cache.slots) |slot| {
        try std.testing.expect(slot.contents != .loading and slot.pins == 0);
        if (slot.contents == .resident) try std.testing.expect(!slot.contents.resident.collection_reported);
    }
    allocator.fail_index = std.math.maxInt(usize);
    allocator.resize_fail_index = std.math.maxInt(usize);
    const leaf = try store.resident(ids[1]);
    try store.release(leaf);
    const token = try store.retain(ids[1]);
    try store.releaseRetention(token);
    const parent = try f.load(store, &fixture.backend, ids[0]);
    try store.release(parent);
}

test "loam collection read buffer refusal leaves reserved capacity without loading debt" {
    var allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var fixture = try f.Fixture.init(allocator.allocator());
    defer fixture.deinit();
    const store = &fixture.store;
    const ids = try pair(store, &fixture.backend);
    try f.collectionStep(store, &fixture.backend, 1);
    const token = try store.retain(ids[0]); // Journal capacity is already available.
    defer store.releaseRetention(token) catch unreachable;
    const capacity = store.collector.?.roots.capacity;
    allocator.fail_index = allocator.alloc_index;
    try std.testing.expectError(error.OutOfMemory, store.acquire(ids[1]));
    try std.testing.expectEqual(capacity, store.collector.?.roots.capacity);
    try std.testing.expectEqual(@as(usize, 1), store.collector.?.roots.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    for (store.cache.slots) |slot| try std.testing.expect(slot.contents == .empty);
    allocator.fail_index = std.math.maxInt(usize);
    const lease = try f.load(store, &fixture.backend, ids[1]);
    try store.release(lease);
}

test "loam collection sequence refusal publishes neither debt nor portrait reports" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    const ids = try pair(store, &fixture.backend);
    const warm = try f.load(store, &fixture.backend, ids[1]);
    try store.release(warm);
    try f.collectionStep(store, &fixture.backend, 1);
    store.retentions.sequence = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, store.retain(ids[0]));
    store.cache.next = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, store.resident(ids[1]));
    try std.testing.expectError(error.Overflow, store.acquire(ids[0]));
    try std.testing.expectEqual(@as(usize, 0), store.collector.?.roots.items.len);
    for (store.cache.slots) |slot| {
        try std.testing.expect(slot.contents != .loading and slot.pins == 0);
        if (slot.contents == .resident) try std.testing.expect(!slot.contents.resident.collection_reported);
    }
}

fn finish(store: *f.core.Store, backend: anytype, ticket: f.core.Ticket) !void {
    const outcome = backend.commit(try store.beginWrite(ticket));
    try store.completeWrite(ticket, outcome);
    if (outcome != .committed) return error.CommitFailed;
}
