//! Loam's portable storage model: graph updates, current revisions, bounded
//! residency, and exact completion ownership. These are internal contracts.
const std = @import("std");
const f = @import("fixture.zig");
const core = f.core;

test "loam resident views reject corrupt input and borrow without allocation" {
    const a = std.testing.allocator;
    var allocator = std.testing.FailingAllocator.init(a, .{});
    var fixture = try f.Fixture.init(allocator.allocator());
    defer fixture.deinit();
    const store = &fixture.store;
    // Checked envelope metadata belongs to the existing fixed slot inventory.
    try std.testing.expect(@sizeOf(@TypeOf(store.cache.slots[0])) <= 192);
    try store.begin();
    const id = try store.allocateId();
    var record = f.record(id, "checked");
    record.edges = &.{.{ .target = id }};
    try store.putCopying(record, null);
    try f.commit(store, &fixture.backend);
    const request = (try store.acquire(id)).read;
    const result = fixture.backend.read(request);
    request.buffer[0] ^= 1;
    try std.testing.expectError(error.Corrupt, store.completeRead(request.ticket, result));
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    const lease = try f.load(store, &fixture.backend, id);
    defer store.release(lease) catch unreachable;
    const payload = (try store.currentView(lease)).payload;
    allocator.fail_index = allocator.alloc_index;
    for (0..64) |_| {
        const view = try store.currentView(lease);
        try std.testing.expectEqualStrings("checked", view.payload);
        try std.testing.expect(view.payload.ptr == payload.ptr);
        var edges = view.edges();
        try std.testing.expect(edges.next().?.target.eql(id));
        try std.testing.expect(edges.next() == null);
    }
    try std.testing.expect(!allocator.has_induced_failure);
}

test "loam re-proposals compose at full mutation capacity without admitting another record" {
    const a = std.testing.allocator;
    var backend = try @import("glowcap").loam.Volatile.init(a, f.id, 1024 * 1024);
    defer backend.deinit();
    var limits = f.limits;
    limits.max_changes = 1;
    var store = try core.Store.init(a, try backend.open(), &f.schemas, limits);
    defer store.deinit() catch unreachable;
    try store.begin();
    defer if (store.phase == .staging) store.abort() catch unreachable;
    const id = try store.allocateId();
    try store.putCopying(f.record(id, "initial"), null);
    const bytes = store.staged_bytes;
    try store.putCopying(f.record(id, "updated"), null);
    try std.testing.expectEqual(@as(usize, 1), store.count);
    try std.testing.expectEqual(bytes, store.staged_bytes);
    try std.testing.expectError(error.DuplicateMutation, store.putCopying(f.record(id, "conflict"), 1));
    const other = try store.allocateId();
    try std.testing.expectError(error.ChangeCapacity, store.putCopying(f.record(other, "refused"), null));
    try std.testing.expectEqualStrings("updated", (try store.proposed(id)).?.view.payload);
    try f.commit(&store, &backend);
    try store.begin();
    try store.putCopying(f.record(id, "pending"), 1);
    try store.putCopying(f.record(id, "settled"), 1);
    try f.commit(&store, &backend);
    const lease = try f.load(&store, &backend, id);
    defer store.release(lease) catch unreachable;
    try std.testing.expectEqualStrings("settled", (try store.view(lease)).payload);
}

test "loam commit verifies introduced edges and kept edges to a record the batch removes" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    const a = try store.allocateId();
    const b = try store.allocateId();
    var first = f.record(a, "first");
    first.rooted = true;
    first.edges = &.{.{ .target = b }};
    try store.putCopying(first, null);
    try store.putCopying(f.record(b, "second"), null);
    try f.commit(store, &fixture.backend);
    try store.begin();
    const missing = try store.allocateId();
    var rewritten = f.record(a, "rewritten");
    rewritten.rooted = true;
    rewritten.edges = &.{ .{ .target = b }, .{ .target = missing } };
    try store.putCopying(rewritten, 1);
    try std.testing.expectError(error.DanglingReference, f.commit(store, &fixture.backend));
    try store.begin();
    rewritten.edges = &.{.{ .target = b }};
    try store.putCopying(rewritten, 1);
    try store.remove(b, 1);
    try std.testing.expectError(error.DanglingReference, f.commit(store, &fixture.backend));
    try store.begin();
    try store.putCopying(rewritten, 1);
    try f.commit(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 2), store.metadata.objects);
    try std.testing.expectEqual(@as(u64, 2), store.metadata.revision);
}

test "loam graph commits a rooted cycle without recursively loading targets" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    const a = try store.allocateId();
    const b = try store.allocateId();
    var first = f.record(a, "first");
    first.rooted = true;
    first.edges = &.{.{ .target = b }};
    var second = f.record(b, "second");
    second.edges = &.{.{ .target = a }};
    try store.putCopying(first, null);
    try store.putCopying(second, null);
    try f.commit(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 2), store.metadata.objects);
    try std.testing.expectEqual(@as(u64, 1), store.metadata.roots);
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    const lease = try f.load(store, &fixture.backend, a);
    const view = try store.view(lease);
    try std.testing.expectEqualStrings("first", view.payload);
    var edges = view.edges();
    try std.testing.expect(edges.next().?.target.eql(b));
    try std.testing.expect(edges.next() == null);
    try store.release(lease);
    store.evict();
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    const reloaded = try f.load(store, &fixture.backend, b);
    defer store.release(reloaded) catch unreachable;
    try std.testing.expectEqualStrings("second", (try store.view(reloaded)).payload);
}

test "loam validation leaves content edges and totals unchanged on failure" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    const id = try store.allocateId();
    const missing = try store.allocateId();
    var record = f.record(id, "dangling");
    record.edges = &.{.{ .target = missing }};
    try store.putCopying(record, null);
    try std.testing.expectError(error.DanglingReference, f.commit(store, &fixture.backend));
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.revision);
    try store.begin();
    try std.testing.expectError(error.InvalidObject, store.putCopying(f.record(id, "recycled"), null));
    const fresh = try store.allocateId();
    record = f.record(fresh, "weak");
    record.edges = &.{.{ .target = missing, .strength = .weak }};
    record.rooted = true;
    try store.putCopying(record, null);
    try f.commit(store, &fixture.backend);
    const before = store.metadata;
    try store.begin();
    try store.remove(fresh, 1);
    try std.testing.expectError(error.Rooted, f.commit(store, &fixture.backend));
    try std.testing.expectEqualDeep(before, store.metadata);
    try store.begin();
    record.rooted = false;
    try store.putCopying(record, 9);
    try std.testing.expectError(error.RevisionConflict, f.commit(store, &fixture.backend));
    try store.begin();
    try store.putCopying(record, 1);
    try f.commit(store, &fixture.backend);
    try store.begin();
    try store.remove(fresh, 2);
    try f.commit(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
    try std.testing.expectEqual(@as(u64, 0), store.metadata.record_bytes);
    try store.begin();
    try std.testing.expectError(error.InvalidObject, store.putCopying(f.record(fresh, "resurrect"), null));
    try store.abort();
}

test "loam leases preserve old data while new acquisitions see committed revisions" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    const id = try store.allocateId();
    try store.putCopying(f.record(id, "old"), null);
    try f.commit(store, &fixture.backend);
    const old = try f.load(store, &fixture.backend, id);
    try store.begin();
    try store.putCopying(f.record(id, "new"), 1);
    try f.commit(store, &fixture.backend);
    const new = try f.load(store, &fixture.backend, id);
    try std.testing.expectEqualStrings("old", (try store.view(old)).payload);
    try std.testing.expectEqualStrings("new", (try store.view(new)).payload);
    try std.testing.expectError(error.LeaseCapacity, store.acquire(id));
    try std.testing.expectError(error.Busy, store.deinit());
    try store.release(old);
    try std.testing.expectError(error.InvalidLease, store.release(old));
    try store.release(new);
    store.evict();
    try std.testing.expectError(error.InvalidLease, store.view(new));
}

test "loam delayed and canceled reads retain ownership and reject stale installation" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    const id = try store.allocateId();
    try store.putCopying(f.record(id, "first"), null);
    try f.commit(store, &fixture.backend);
    const read = (try store.acquire(id)).read;
    const result = fixture.backend.read(read);
    try std.testing.expectError(error.PendingRead, store.acquire(id));
    try store.begin();
    try store.putCopying(f.record(id, "second"), 1);
    try f.commit(store, &fixture.backend);
    try std.testing.expectError(error.StaleCompletion, store.completeRead(read.ticket, result));
    const canceled = (try store.acquire(id)).read;
    try store.cancelRead(canceled.ticket);
    try std.testing.expectError(error.Busy, store.deinit());
    try std.testing.expectError(error.Canceled, store.completeRead(canceled.ticket, fixture.backend.read(canceled)));
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    const lease = try f.load(store, &fixture.backend, id);
    defer store.release(lease) catch unreachable;
    try std.testing.expectError(error.StaleCompletion, store.completeRead(read.ticket, result));
}

test "loam unknown writes fence use and recover the committed receipt once" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    const id = try store.allocateId();
    try store.putCopying(f.record(id, "committed"), null);
    const ticket = try store.prepare();
    const batch = try store.beginWrite(ticket);
    try std.testing.expectError(error.Busy, store.abort());
    try std.testing.expect(fixture.backend.commit(batch) == .committed);
    try store.completeWrite(ticket, .unknown);
    try std.testing.expectError(error.RecoveryRequired, store.acquire(id));
    try std.testing.expectError(error.RecoveryRequired, store.begin());
    try std.testing.expectError(error.Busy, store.deinit());
    try store.resolve(ticket, try fixture.backend.recover(try store.recoveryBatch()));
    try std.testing.expectEqual(@as(u64, 1), store.metadata.objects);
    try std.testing.expectError(error.StaleCompletion, store.completeWrite(ticket, .unknown));
    try store.begin();
    try store.putCopying(f.record(id, "unsubmitted"), 1);
    const absent = try store.prepare();
    _ = try store.beginWrite(absent);
    try store.completeWrite(absent, .unknown);
    try store.resolve(absent, try fixture.backend.recover(try store.recoveryBatch()));
    try std.testing.expectEqual(@as(u64, 1), store.metadata.revision);
}

test "loam cache capacity is independent of stored object count" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    var ids: [100]core.ObjectId = undefined;
    for (&ids) |*id| {
        try store.begin();
        id.* = try store.allocateId();
        try store.putCopying(f.record(id.*, "data"), null);
        try f.commit(store, &fixture.backend);
    }
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    const a = try f.load(store, &fixture.backend, ids[0]);
    const b = try f.load(store, &fixture.backend, ids[1]);
    try std.testing.expectError(error.ResidentCapacity, store.acquire(ids[2]));
    try store.release(a);
    try store.release(b);
    for (ids) |id| {
        const lease = try f.load(store, &fixture.backend, id);
        try std.testing.expect(store.cache.allocated_bytes <= f.limits.resident_bytes);
        try store.release(lease);
    }
    try std.testing.expectEqual(@as(u64, 100), store.metadata.objects);
}

test "loam leases and completions cannot alias another store or opening" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    try store.begin();
    const id = try store.allocateId();
    try store.putCopying(f.record(id, "retained"), null);
    try f.commit(store, &fixture.backend);
    const old_read = (try store.acquire(id)).read;
    try store.completeRead(old_read.ticket, fixture.backend.read(old_read));
    const old_lease = (try store.acquire(id)).ready;
    var foreign = old_lease;
    foreign.store = @fromBackingInt(@backingInt(f.id) + 1);
    try std.testing.expectError(error.InvalidLease, store.view(foreign));
    try std.testing.expectError(error.InvalidLease, store.release(foreign));
    try store.release(old_lease);
    try store.deinit();
    try fixture.backend.close();
    store.* = try core.Store.init(std.testing.allocator, try fixture.backend.open(), &f.schemas, f.limits);
    const new_read = (try store.acquire(id)).read;
    try std.testing.expectEqual(old_read.ticket.sequence, new_read.ticket.sequence);
    try std.testing.expectError(error.StaleCompletion, store.completeRead(old_read.ticket, .missing));
    try store.completeRead(new_read.ticket, fixture.backend.read(new_read));
    const new_lease = (try store.acquire(id)).ready;
    defer store.release(new_lease) catch unreachable;
    try std.testing.expectEqual(old_lease.sequence, new_lease.sequence);
    try std.testing.expectError(error.InvalidLease, store.view(old_lease));
    try std.testing.expectError(error.InvalidLease, store.release(old_lease));
    try std.testing.expectEqualStrings("retained", (try store.view(new_lease)).payload);
    try store.begin();
    const next_id = try store.allocateId();
    try std.testing.expectEqual(id.sequence, next_id.sequence);
    try std.testing.expect(!id.eql(next_id));
    try store.abort();
}

test "loam committed residency transfers prepared ownership without allocation or displacing pins" {
    for (0..3) |pin_count| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var fixture = try f.Fixture.init(failing.allocator());
        defer fixture.deinit();
        const store = &fixture.store;
        try store.begin();
        const a = try store.allocateId();
        const b = try store.allocateId();
        try store.putCopying(f.record(a, "old-a"), null);
        try store.putCopying(f.record(b, "old-b"), null);
        try f.commit(store, &fixture.backend);
        var pins: [2]core.Lease = undefined;
        for (0..pin_count) |i| pins[i] = try f.load(store, &fixture.backend, if (i == 0) a else b);
        defer for (pins[0..pin_count]) |pin| store.release(pin) catch unreachable;
        try store.begin();
        try store.putCopying(f.record(a, "new-a"), 1);
        try store.retainOnCommit();
        const ticket = try store.prepare();
        const batch = try store.beginWrite(ticket);
        const allocation = batch.changes[0].bytes.?.ptr;
        const outcome = fixture.backend.commit(batch);
        try std.testing.expect(outcome == .committed);
        failing.fail_index = failing.alloc_index;
        try store.completeWrite(ticket, outcome);
        try std.testing.expect(!failing.has_induced_failure);
        failing.fail_index = std.math.maxInt(usize);
        for (pins[0..pin_count], 0..) |pin, i| {
            try std.testing.expectError(error.StaleSnapshot, store.currentView(pin));
            try std.testing.expectEqualStrings(if (i == 0) "old-a" else "old-b", (try store.view(pin)).payload);
        }
        if (pin_count == 2) {
            try std.testing.expectError(error.ResidencyRequired, store.resident(a));
        } else {
            const lease = try store.resident(a);
            defer store.release(lease) catch unreachable;
            try std.testing.expectEqualStrings("new-a", (try store.view(lease)).payload);
            var transferred = false;
            for (store.cache.slots) |slot| if (slot.bytes()) |bytes| {
                if (bytes.ptr == allocation) transferred = true;
            };
            try std.testing.expect(transferred);
        }
        try std.testing.expect(store.cache.allocated_bytes <= store.limits.resident_bytes);
    }
}
