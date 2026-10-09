//! Restart markers follow the shared transaction and snapshot contract.
const std = @import("std");
const loam = @import("glowcap").loam;
const f = @import("../core/fixture.zig");
const epoch = loam.hosting.LiveEpoch;
const a = std.testing.allocator;
const schemas = f.schemas ++ [_]loam.core.Schema{epoch.schema};

const Fixture = struct {
    backend: loam.Volatile,
    store: loam.core.Store,

    fn init(self: *Fixture) !void {
        self.backend = try loam.Volatile.init(a, f.id, 1024 * 1024);
        errdefer self.backend.deinit();
        self.store = try loam.core.Store.init(a, try self.backend.open(), &schemas, f.limits);
    }
    fn deinit(self: *Fixture) void {
        if (self.store.phase == .staging or self.store.phase == .prepared) self.store.abort() catch unreachable;
        self.store.deinit() catch unreachable;
        self.backend.close();
        self.backend.deinit();
    }
    fn fresh(self: *Fixture) !epoch {
        try self.store.begin();
        const proposed = try epoch.stageFresh(&self.store);
        try f.commit(&self.store, &self.backend);
        const lease = try f.load(&self.store, &self.backend, proposed.epoch.object);
        defer self.store.release(lease) catch unreachable;
        return proposed.confirm(&self.store, lease);
    }
};

test "loam live epoch advances on a Host restart within the same Store opening" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const store = &fixture.store;
    const original = try fixture.fresh();
    const incarnation = store.metadata.incarnation;
    const prior = try f.load(store, &fixture.backend, original.object);
    defer store.release(prior) catch unreachable;
    try original.check(store, prior);
    try store.begin();
    const proposed = try epoch.stageRestart(store, prior);
    try std.testing.expectEqual(@as(u64, 2), proposed.epoch.generation);
    try std.testing.expectError(error.EpochAlreadyStaged, epoch.stageRestart(store, prior));
    try std.testing.expectEqual(@as(usize, 1), store.count);
    try std.testing.expectError(error.EpochUnconfirmed, proposed.confirm(store, prior));
    try f.commit(store, &fixture.backend);
    try std.testing.expectEqual(incarnation, store.metadata.incarnation);
    try std.testing.expectError(error.StaleSnapshot, epoch.read(store, prior));
    const current = try f.load(store, &fixture.backend, original.object);
    defer store.release(current) catch unreachable;
    const restarted = try proposed.confirm(store, current);
    try std.testing.expectError(error.LiveReferenceExpired, original.check(store, current));
    try restarted.check(store, current);
}

test "loam live epoch abort leaves the previous lifetime admitted" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const store = &fixture.store;
    const original = try fixture.fresh();
    const lease = try f.load(store, &fixture.backend, original.object);
    defer store.release(lease) catch unreachable;
    try store.begin();
    const proposed = try epoch.stageRestart(store, lease);
    try store.abort();
    try original.check(store, lease);
    try std.testing.expectError(error.LiveReferenceExpired, proposed.confirm(store, lease));
    try store.begin();
    const retried = try epoch.stageRestart(store, lease);
    try std.testing.expectEqual(proposed.epoch.generation, retried.epoch.generation);
    try f.commit(store, &fixture.backend);
    const current = try f.load(store, &fixture.backend, original.object);
    defer store.release(current) catch unreachable;
    _ = try retried.confirm(store, current);
    try std.testing.expectError(error.LiveReferenceExpired, proposed.confirm(store, current));
}

test "loam live epoch uncertain writes admit neither lifetime before exact recovery" {
    for ([_]bool{ false, true }) |applied| {
        var fixture: Fixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const store = &fixture.store;
        const original = try fixture.fresh();
        const prior = try f.load(store, &fixture.backend, original.object);
        defer store.release(prior) catch unreachable;
        try store.begin();
        const proposed = try epoch.stageRestart(store, prior);
        const ticket = try store.prepare();
        const batch = try store.beginWrite(ticket);
        if (applied) try std.testing.expect(fixture.backend.commit(batch) == .committed);
        try store.completeWrite(ticket, .unknown);
        try std.testing.expectError(error.EpochUnconfirmed, original.check(store, prior));
        try std.testing.expectError(error.EpochUnconfirmed, proposed.confirm(store, prior));
        const resolution = try (try store.recoveryBatch()).resolve(fixture.backend.metadata);
        try store.resolve(ticket, resolution);
        const current = try f.load(store, &fixture.backend, original.object);
        defer store.release(current) catch unreachable;
        if (applied) {
            _ = try proposed.confirm(store, current);
            try std.testing.expectError(error.LiveReferenceExpired, original.check(store, current));
        } else {
            try original.check(store, current);
            try std.testing.expectError(error.LiveReferenceExpired, proposed.confirm(store, current));
        }
    }
}

test "loam live epoch survives backend reopen and refuses exhausted or malformed markers" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const original = try fixture.fresh();
    const incarnation = fixture.store.metadata.incarnation;
    try fixture.store.deinit();
    fixture.backend.close();
    fixture.store = try loam.core.Store.init(a, try fixture.backend.open(), &schemas, f.limits);
    const store = &fixture.store;
    try std.testing.expect(store.metadata.incarnation > incarnation);
    const lease = try f.load(store, &fixture.backend, original.object);
    try original.check(store, lease);
    const view = try store.currentView(lease);
    var payload: [24]u8 = undefined;
    @memcpy(&payload, view.payload);
    std.mem.writeInt(u64, payload[0..8], std.math.maxInt(u64), .big);
    try store.begin();
    try store.putCopying(.{ .id = original.object, .revision = 0, .schema = epoch.schema.id, .rooted = true, .payload = &payload }, view.revision);
    try f.commit(store, &fixture.backend);
    try store.release(lease);
    const exhausted = try f.load(store, &fixture.backend, original.object);
    const exhausted_view = try store.currentView(exhausted);
    try store.begin();
    try std.testing.expectError(error.EpochExhausted, epoch.stageRestart(store, exhausted));
    try std.testing.expectEqual(@as(usize, 0), store.count);
    payload = @splat(0);
    try store.putCopying(.{ .id = original.object, .revision = 0, .schema = epoch.schema.id, .rooted = true, .payload = &payload }, exhausted_view.revision);
    try f.commit(store, &fixture.backend);
    try store.release(exhausted);
    const malformed = try f.load(store, &fixture.backend, original.object);
    defer store.release(malformed) catch unreachable;
    try std.testing.expectError(error.InvalidLiveEpoch, epoch.read(store, malformed));
}
