//! Loam read-ahead: a bounded depth of reads started before demand, which
//! never takes the room demand needs and never evicts what it loaded.
const std = @import("std");
const f = @import("fixture.zig");
const core = f.core;

const Ahead = struct {
    backend: @import("glowcap").loam.Volatile,
    store: core.Store,
    ids: [10]core.ObjectId = undefined,

    fn init(self: *Ahead, slots: usize, depth: usize, budget: usize) !void {
        self.backend = try .init(std.testing.allocator, f.id, 1024 * 1024);
        errdefer self.backend.deinit();
        var limits = f.limits;
        limits.cache_slots = slots;
        limits.read_ahead = depth;
        limits.max_leases = slots;
        limits.resident_bytes = budget;
        self.store = try core.Store.init(std.testing.allocator, try self.backend.open(), &f.schemas, limits);
        for (&self.ids) |*id| {
            try self.store.begin();
            id.* = try self.store.allocateId();
            try self.store.putCopying(f.record(id.*, "data"), null);
            try f.commit(&self.store, &self.backend);
        }
    }

    fn deinit(self: *Ahead) void {
        self.store.deinit() catch unreachable;
        self.backend.close() catch unreachable;
        self.backend.deinit();
    }

    fn read(self: *Ahead, index: usize) !core.Read {
        return switch (try self.store.acquireAhead(self.ids[index])) {
            .read => |request| request,
            .held, .full => error.TestUnexpectedResult,
        };
    }

    fn land(self: *Ahead, request: core.Read) !void {
        try self.store.completeRead(request.ticket, self.backend.read(request));
    }
};

test "loam read-ahead stops at its depth and demand pins what it loaded" {
    var fixture: Ahead = undefined;
    try fixture.init(8, 2, 8 * 1024);
    defer fixture.deinit();
    const store = &fixture.store;
    const first = try fixture.read(0);
    const second = try fixture.read(1);
    try std.testing.expectEqual(core.Ahead.held, try store.acquireAhead(fixture.ids[0]));
    try std.testing.expectEqual(core.Ahead.full, try store.acquireAhead(fixture.ids[2]));
    // Demand for a record still loading waits on that read instead of
    // starting a second one.
    try std.testing.expectError(error.PendingRead, store.acquire(fixture.ids[0]));
    try fixture.land(first);
    try fixture.land(second);
    try std.testing.expectEqual(core.Ahead.full, try store.acquireAhead(fixture.ids[2]));
    const lease = (try store.acquire(fixture.ids[0])).ready;
    defer store.release(lease) catch unreachable;
    // A pinned record is demand's, so the depth has room again.
    try fixture.land(try fixture.read(2));
    try std.testing.expectEqual(core.Ahead.full, try store.acquireAhead(fixture.ids[3]));
}

test "loam read-ahead leaves demand a slot and demand evicts it last" {
    var fixture: Ahead = undefined;
    try fixture.init(4, 8, 8 * 1024);
    defer fixture.deinit();
    const store = &fixture.store;
    var reads: [3]core.Read = undefined;
    for (&reads, 0..) |*request, index| request.* = try fixture.read(index);
    try std.testing.expectEqual(core.Ahead.full, try store.acquireAhead(fixture.ids[3]));
    const demand = (try store.acquire(fixture.ids[4])).read;
    // Every slot is held, and a read-ahead in flight will free one.
    try std.testing.expectError(error.PendingRead, store.acquire(fixture.ids[5]));
    for (reads) |request| try fixture.land(request);
    try fixture.land(demand);
    // The landed demand record is free room, taken before any read-ahead.
    try fixture.land((try store.acquire(fixture.ids[5])).read);
    for (0..3) |index| try std.testing.expectEqual(core.Ahead.held, try store.acquireAhead(fixture.ids[index]));
}

test "loam read-ahead leaves demand one record of the byte budget" {
    var fixture: Ahead = undefined;
    try fixture.init(8, 8, 3 * 1024);
    defer fixture.deinit();
    const store = &fixture.store;
    // Each load reserves a maximum-size buffer until it lands.
    const first = try fixture.read(0);
    const second = try fixture.read(1);
    try std.testing.expectEqual(core.Ahead.full, try store.acquireAhead(fixture.ids[2]));
    const demand = (try store.acquire(fixture.ids[3])).read;
    for ([_]core.Read{ first, second, demand }) |request| try fixture.land(request);
}

test "loam read-ahead of zero depth or one slot reads nothing ahead" {
    for ([_][2]usize{ .{ 8, 0 }, .{ 1, 8 } }) |shape| {
        var fixture: Ahead = undefined;
        try fixture.init(shape[0], shape[1], 8 * 1024);
        defer fixture.deinit();
        try std.testing.expectEqual(core.Ahead.full, try fixture.store.acquireAhead(fixture.ids[0]));
        // Demand still takes its slot.
        try fixture.land((try fixture.store.acquire(fixture.ids[0])).read);
    }
}
