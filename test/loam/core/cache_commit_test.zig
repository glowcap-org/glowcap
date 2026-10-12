//! Commit-aware residency preserves unchanged bytes without refreshing old
//! leases or pending reads. Internal storage authority is the committed batch.
//! Calibrated by disabling cache promotion and by checking a slot's refreshed
//! revision instead of the lease's acquisition revision. Both fail these tests.
const std = @import("std");
const f = @import("fixture.zig");

fn seed(fixture: *f.Fixture) ![2]f.core.ObjectId {
    const store = &fixture.store;
    try store.begin();
    const a = try store.allocateId();
    const b = try store.allocateId();
    try store.putCopying(f.record(a, "a"), null);
    try store.putCopying(f.record(b, "b"), null);
    try f.commit(store, &fixture.backend);
    return .{ a, b };
}

test "loam unchanged resident bytes survive edits but historical leases stay historical" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    const ids = try seed(&fixture);
    const old = try f.load(store, &fixture.backend, ids[0]);
    defer store.release(old) catch unreachable;
    const address = (try store.view(old)).payload.ptr;
    const changed = try f.load(store, &fixture.backend, ids[1]);
    try store.release(changed);
    try store.begin();
    try store.putCopying(f.record(ids[1], "edited-b"), 1);
    try store.retainOnCommit();
    try f.commit(store, &fixture.backend);
    // The same bytes support a new lease; the old lease never changes epoch.
    {
        const fresh = try store.resident(ids[0]);
        defer store.release(fresh) catch unreachable;
        try std.testing.expect(address == (try store.currentView(fresh)).payload.ptr);
        try std.testing.expectError(error.StaleSnapshot, store.currentView(old));
        try std.testing.expectEqualStrings("a", (try store.view(old)).payload);
    }
    const updated = try store.resident(ids[1]);
    defer store.release(updated) catch unreachable;
    try std.testing.expectEqualStrings("edited-b", (try store.currentView(updated)).payload);
}

test "loam old changed and deleted records never become current on later commits" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    const ids = try seed(&fixture);
    const old = try f.load(store, &fixture.backend, ids[0]);
    const other = try f.load(store, &fixture.backend, ids[1]);
    try store.release(other);
    try store.begin();
    try store.putCopying(f.record(ids[0], "new-a"), 1);
    try f.commit(store, &fixture.backend);
    try store.begin();
    try store.putCopying(f.record(ids[1], "new-b"), 1);
    try store.retainOnCommit();
    try f.commit(store, &fixture.backend);
    try std.testing.expectError(error.ResidencyRequired, store.resident(ids[0]));
    try std.testing.expectEqualStrings("a", (try store.view(old)).payload);
    try store.release(old);
    const current = try f.load(store, &fixture.backend, ids[0]);
    try std.testing.expectEqualStrings("new-a", (try store.currentView(current)).payload);
    try store.begin();
    try store.remove(ids[0], 2);
    try f.commit(store, &fixture.backend);
    try std.testing.expectError(error.StaleSnapshot, store.currentView(current));
    try store.release(current);
    try store.begin();
    try store.putCopying(f.record(ids[1], "again-b"), 3);
    try f.commit(store, &fixture.backend);
    try std.testing.expectError(error.ResidencyRequired, store.resident(ids[0]));
    try std.testing.expectError(error.Gone, f.load(store, &fixture.backend, ids[0]));
}

test "loam unrelated commit cannot install a pending read from an old revision" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    const ids = try seed(&fixture);
    const request = (try store.acquire(ids[0])).read;
    const result = fixture.backend.read(request);
    try store.begin();
    try store.putCopying(f.record(ids[1], "edited-b"), 1);
    try f.commit(store, &fixture.backend);
    try std.testing.expectError(error.StaleCompletion, store.completeRead(request.ticket, result));
    try std.testing.expectError(error.ResidencyRequired, store.resident(ids[0]));
}

test "loam commit recovery promotes unchanged cache only after outcome is established" {
    for ([_]bool{ false, true }) |committed| {
        var fixture = try f.Fixture.init(std.testing.allocator);
        defer fixture.deinit();
        const store = &fixture.store;
        const ids = try seed(&fixture);
        const old = try f.load(store, &fixture.backend, ids[0]);
        defer store.release(old) catch unreachable;
        try store.begin();
        try store.putCopying(f.record(ids[1], "edited-b"), 1);
        const ticket = try store.prepare();
        const batch = try store.beginWrite(ticket);
        if (committed) try std.testing.expect(fixture.backend.commit(batch) == .committed);
        try store.completeWrite(ticket, .unknown);
        try std.testing.expectError(error.RecoveryRequired, store.currentView(old));
        try std.testing.expectError(error.RecoveryRequired, store.resident(ids[0]));
        try store.resolve(ticket, try fixture.backend.recover(try store.recoveryBatch()));
        const fresh = try store.resident(ids[0]);
        defer store.release(fresh) catch unreachable;
        try std.testing.expectEqualStrings("a", (try store.currentView(fresh)).payload);
        if (committed) {
            try std.testing.expectError(error.StaleSnapshot, store.currentView(old));
        } else try std.testing.expectEqualStrings("a", (try store.currentView(old)).payload);
    }
}

test "loam collection keeps unchanged cache current but never serves a swept record" {
    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    const ids = try seed(&fixture);
    try store.begin();
    var rooted = f.record(ids[0], "root");
    rooted.rooted = true;
    try store.putCopying(rooted, 1);
    try f.commit(store, &fixture.backend);
    const root = try f.load(store, &fixture.backend, ids[0]);
    try store.release(root);
    const garbage = try f.load(store, &fixture.backend, ids[1]);
    try store.release(garbage);
    try f.collectionStep(store, &fixture.backend, 1);
    const fresh = try store.resident(ids[0]);
    try std.testing.expectEqualStrings("root", (try store.currentView(fresh)).payload);
    try store.release(fresh);
    try f.collect(store, &fixture.backend);
    try std.testing.expectEqual(@as(u64, 1), store.metadata.objects);
    try std.testing.expectError(error.ResidencyRequired, store.resident(ids[1]));
    try std.testing.expectError(error.Gone, f.load(store, &fixture.backend, ids[1]));
}
