//! Create, open, bootstrap, atomic commit, reopen recovery, and tracing over any durable engine.
const std = @import("std");
const core = @import("loam_core");
const fixture = @import("engine_fixture");
const f = @import("loam_test_support");

test "loam engine creates and reopens an exclusively owned store" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    const id: core.StoreId = @fromBackingInt(42);
    var db = try fixture.open(tmp.path, .create, id);
    try std.testing.expectError(error.CustodyUnavailable, fixture.open(tmp.path, .open, id));
    const incarnation = db.metadata.incarnation;
    try db.close();
    db = try fixture.open(tmp.path, .open, id);
    defer db.close() catch unreachable;
    try std.testing.expect(db.metadata.incarnation > incarnation);
}

test "loam engine refuses to open a missing store and writes no storage file" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    try std.testing.expectError(error.MissingStore, fixture.open(tmp.path, .open, f.id));
    // Only the owner lock, which outlives every owner, may be left behind.
    var dir = try tmp.dir.dir.openDir(std.testing.io, ".", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var entries = dir.iterate();
    while (try entries.next(std.testing.io)) |entry| {
        try std.testing.expectEqualStrings("loam-owner.lock", entry.name);
    }
    var db = try fixture.open(tmp.path, .create, f.id);
    try db.close();
}

test "loam engine bootstrap survives opening before any resource commit" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try fixture.open(tmp.path, .bootstrap, f.id);
    const incarnation = db.metadata.incarnation;
    try db.close();
    try std.testing.expectError(error.StoreMismatch, fixture.open(tmp.path, .bootstrap, @fromBackingInt(999)));
    db = try fixture.open(tmp.path, .bootstrap, f.id);
    defer db.close() catch unreachable;
    try std.testing.expect(db.metadata.incarnation > incarnation);
    try std.testing.expectEqual(@as(u64, 0), db.metadata.objects);
}

test "loam engine passes the storage engine suite" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try fixture.open(tmp.path, .create, f.id);
    defer db.close() catch unreachable;
    try @import("../core/engine_scenario.zig").exercise(f, &db, db.metadata, .{ .capacity_bytes = fixture.capacity_bytes });
}

test "loam engine restores cyclic records roots exact totals and stable identities" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try fixture.open(tmp.path, .create, f.id);
    var store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
    try store.begin();
    const a = try store.allocateId();
    const b = try store.allocateId();
    var record = f.record(a, "root");
    record.rooted = true;
    record.edges = &.{.{ .target = b }};
    try store.putCopying(record, null);
    record = f.record(b, "child");
    record.edges = &.{.{ .target = a }};
    try store.putCopying(record, null);
    try f.commit(&store, &db);
    const totals = store.metadata;
    try store.deinit();
    try db.close();
    db = try fixture.open(tmp.path, .open, f.id);
    defer db.close() catch unreachable;
    store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
    defer store.deinit() catch unreachable;
    try std.testing.expectEqual(totals.objects, store.metadata.objects);
    try std.testing.expectEqual(totals.record_bytes, store.metadata.record_bytes);
    try std.testing.expectEqual(totals.roots, store.metadata.roots);
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
    const lease = try f.load(&store, &db, a);
    const view = try store.view(lease);
    try std.testing.expect(view.id.eql(a));
    var edges = view.edges();
    try std.testing.expect(edges.next().?.target.eql(b));
    try store.release(lease);
    try store.begin();
    const fresh = try store.allocateId();
    try std.testing.expect(fresh.incarnation != a.incarnation);
    try store.abort();
}

test "loam engine abort and missing acknowledgement preserve atomic records and receipt" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try fixture.open(tmp.path, .create, f.id);
    defer db.close() catch unreachable;
    var store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
    defer store.deinit() catch unreachable;
    try store.begin();
    const a = try store.allocateId();
    const b = try store.allocateId();
    try store.putCopying(f.record(a, "one"), null);
    try store.putCopying(f.record(b, "two"), null);
    var ticket = try store.prepare();
    var pending = try db.beginWrite();
    _ = try (try store.beginWrite(ticket)).apply(&pending);
    pending.abort();
    try store.completeWrite(ticket, .unknown);
    try store.resolve(ticket, try db.recover(try store.recoveryBatch()));
    try std.testing.expectEqual(@as(u64, 0), store.metadata.objects);
    try store.begin();
    const fresh_a = try store.allocateId();
    const fresh_b = try store.allocateId();
    try store.putCopying(f.record(fresh_a, "one"), null);
    try store.putCopying(f.record(fresh_b, "two"), null);
    ticket = try store.prepare();
    const outcome = db.commit(try store.beginWrite(ticket));
    try std.testing.expect(outcome == .committed);
    try store.completeWrite(ticket, .unknown);
    try std.testing.expectError(error.RecoveryRequired, store.acquire(fresh_a));
    try store.resolve(ticket, try db.recover(try store.recoveryBatch()));
    try std.testing.expectEqual(@as(u64, 2), store.metadata.objects);
    const lease = try f.load(&store, &db, fresh_b);
    defer store.release(lease) catch unreachable;
    try std.testing.expectEqualStrings("two", (try store.view(lease)).payload);
}

test "loam engine open distinguishes absence identity mismatch and existing creation" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    try std.testing.expectError(error.MissingStore, fixture.open(tmp.path, .open, f.id));
    var db = try fixture.open(tmp.path, .create, f.id);
    try db.close();
    try std.testing.expectError(error.AlreadyExists, fixture.open(tmp.path, .create, f.id));
    try std.testing.expectError(error.StoreMismatch, fixture.open(tmp.path, .open, @fromBackingInt(999)));
    db = try fixture.open(tmp.path, .open, f.id);
    try db.close();
}

test "loam engine tracing survives reopen and a lost sweep acknowledgement" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try fixture.open(tmp.path, .create, f.id);
    var store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
    try store.begin();
    const root = try store.allocateId();
    const child = try store.allocateId();
    const garbage = try store.allocateId();
    var r = f.record(root, "root");
    r.rooted = true;
    r.edges = &.{.{ .target = child }};
    try store.putCopying(r, null);
    r = f.record(child, "child");
    r.edges = &.{.{ .target = root }};
    try store.putCopying(r, null);
    r = f.record(garbage, "cycle");
    r.edges = &.{.{ .target = garbage }};
    try store.putCopying(r, null);
    try f.commit(&store, &db);
    while (store.metadata.collection.phase != .sweep) try f.collectionStep(&store, &db, 1);
    // Reopening must restart tracing, including a newly reconstructed live root.
    try store.deinit();
    try db.close();
    db = try fixture.open(tmp.path, .open, f.id);
    defer db.close() catch unreachable;
    store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
    defer store.deinit() catch unreachable;
    try std.testing.expectEqual(.clearing, store.metadata.collection.phase);
    const held = try store.retain(garbage);
    try f.collect(&store, &db);
    try std.testing.expectEqual(@as(u64, 3), store.metadata.objects);
    try store.releaseRetention(held);
    const ticket = try store.prepareCollection(64);
    const batch = try store.beginWrite(ticket);
    var pending = try db.beginWrite();
    _ = try batch.apply(&pending);
    try std.testing.expectEqual(core.backend.Commit.committed, try pending.commit());
    try std.testing.expectEqual(core.backend.Commit.committed, try pending.commit());
    try store.completeWrite(ticket, .unknown);
    try store.resolve(ticket, try db.recover(try store.recoveryBatch()));
    try std.testing.expectEqual(@as(u64, 2), store.metadata.objects);
    const lease = try f.load(&store, &db, root);
    defer store.release(lease) catch unreachable;
    try std.testing.expectEqualStrings("root", (try store.view(lease)).payload);
}

test "loam engine insertion barrier traces mapped edges after black record mutation" {
    var tmp = try fixture.Temp.init();
    defer tmp.deinit();
    var db = try fixture.open(tmp.path, .create, f.id);
    defer db.close() catch unreachable;
    var store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
    defer store.deinit() catch unreachable;
    try store.begin();
    const root = try store.allocateId();
    var ids: [7]core.ObjectId = undefined;
    for (&ids) |*id| id.* = try store.allocateId();
    var r = f.record(root, "root");
    r.rooted = true;
    try store.putCopying(r, null);
    for (ids, 0..) |id, i| {
        r = f.record(id, "chain");
        if (i + 1 < ids.len) r.edges = &.{.{ .target = ids[i + 1] }};
        try store.putCopying(r, null);
    }
    try f.commit(&store, &db);
    while (store.metadata.collection.phase != .sweep) try f.collectionStep(&store, &db, 1);
    try f.collectionStep(&store, &db, 1);
    try store.begin();
    r = f.record(root, "changed");
    r.rooted = true;
    r.edges = &.{.{ .target = ids[0] }};
    try store.putCopying(r, 1);
    try f.commit(&store, &db);
    try f.collect(&store, &db);
    try std.testing.expectEqual(@as(u64, 8), store.metadata.objects);
    try std.testing.expectEqual(@as(usize, 0), store.cache.allocated_bytes);
}

test "loam engine commit handles preserve their terminal outcome" {
    for ([_]bool{ false, true }) |aborted| {
        var tmp = try fixture.Temp.init();
        defer tmp.deinit();
        var db = try fixture.open(tmp.path, .create, f.id);
        defer db.close() catch unreachable;
        var store = try core.Store.init(std.testing.allocator, db.metadata, &f.schemas, f.limits);
        defer store.deinit() catch unreachable;
        try store.begin();
        const id = try store.allocateId();
        try store.putCopying(f.record(id, "saved"), null);
        const ticket = try store.prepare();
        const batch = try store.beginWrite(ticket);
        var pending = try db.beginWrite();
        const next = try batch.apply(&pending);
        defer pending.abort();
        if (aborted) pending.abort();
        const outcome = completion(&pending, next);
        if (aborted) {
            try std.testing.expect(outcome == .unchanged);
        } else {
            try std.testing.expect(outcome == .committed);
        }
        pending.abort();
        const repeated = completion(&pending, next);
        const recovered = try db.recover(batch);
        try store.completeWrite(ticket, repeated);
        try std.testing.expectEqualDeep(outcome, repeated);
        if (aborted) {
            try std.testing.expect(recovered == .unchanged);
        } else {
            try std.testing.expectEqualDeep(outcome.committed, recovered.committed);
        }
    }
}

fn completion(pending: *fixture.Engine.WriteTransaction, next: core.Metadata) core.Outcome {
    const state = pending.commit() catch |err| return .{ .unchanged = err };
    return switch (state) {
        .committed => .{ .committed = next },
        .unknown => .unknown,
    };
}
