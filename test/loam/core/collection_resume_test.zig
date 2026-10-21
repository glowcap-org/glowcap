//! Collection finishes on a store that holds one loaded row at a time and
//! suspends every read, as the browser embedding does. A retried step must
//! leave the same store, and perform the same writes, as a synchronous sweep.
const std = @import("std");
const f = @import("fixture.zig");
const loam = @import("glowcap").loam;
const core = f.core;

const Counts = struct { get_suspensions: usize = 0, next_suspensions: usize = 0, puts: usize = 0, removals: usize = 0 };

const Request = union(enum) {
    get: struct { key: [35]u8, len: usize },
    next: struct { prefix: u8, after: ?[33]u8 },
};
const Answer = union(enum) {
    get: ?[]const u8,
    next: ?core.CollectionRow,
};

/// A transaction behind browser semantics: at most one answer is loaded, and a
/// write drops the answer it could have changed. With `suspend_reads` off it
/// answers directly and only counts writes.
const OneRowKv = struct {
    txn: *loam.Volatile.WriteTransaction,
    counts: *Counts,
    suspend_reads: bool,
    loaded: ?struct { request: Request, answer: Answer } = null,
    pending: ?Request = null,

    fn matches(a: Request, b: Request) bool {
        return switch (a) {
            .get => |x| switch (b) {
                .get => |y| x.len == y.len and std.mem.eql(u8, x.key[0..x.len], y.key[0..y.len]),
                .next => false,
            },
            .next => |x| switch (b) {
                .get => false,
                .next => |y| x.prefix == y.prefix and std.meta.eql(x.after, y.after),
            },
        };
    }
    fn getRequest(key: []const u8) Request {
        var request: Request = .{ .get = .{ .key = undefined, .len = key.len } };
        @memcpy(request.get.key[0..key.len], key);
        return request;
    }
    fn nextRequest(prefix: []const u8, after: ?[]const u8) Request {
        std.debug.assert(prefix.len == 1);
        var request: Request = .{ .next = .{ .prefix = prefix[0], .after = null } };
        if (after) |bytes| {
            var buffer: [33]u8 = @splat(0);
            @memcpy(buffer[0..bytes.len], bytes);
            request.next.after = buffer;
        }
        return request;
    }

    pub fn get(self: *OneRowKv, key: []const u8) !?[]const u8 {
        if (!self.suspend_reads) return self.txn.get(key);
        const request = getRequest(key);
        if (self.loaded) |loaded| if (matches(loaded.request, request)) return loaded.answer.get;
        self.pending = request;
        self.counts.get_suspensions += 1;
        return error.RecordUnloaded;
    }
    pub fn next(self: *OneRowKv, prefix: []const u8, after: ?[]const u8) !?core.CollectionRow {
        if (!self.suspend_reads) return self.txn.next(prefix, after);
        const request = nextRequest(prefix, after);
        if (self.loaded) |loaded| if (matches(loaded.request, request)) return loaded.answer.next;
        self.pending = request;
        self.counts.next_suspensions += 1;
        return error.RecordUnloaded;
    }
    pub fn put(self: *OneRowKv, key: []const u8, bytes: []const u8) !void {
        try self.txn.put(key, bytes);
        self.counts.puts += 1;
        self.drop(key);
    }
    pub fn remove(self: *OneRowKv, key: []const u8) !void {
        try self.txn.remove(key);
        self.counts.removals += 1;
        self.drop(key);
    }
    fn drop(self: *OneRowKv, key: []const u8) void {
        const loaded = self.loaded orelse return;
        const stale = switch (loaded.request) {
            .get => |g| std.mem.eql(u8, g.key[0..g.len], key),
            .next => |n| n.prefix == key[0],
        };
        if (stale) self.loaded = null;
    }
    /// Load the one row the last suspension asked for.
    fn load(self: *OneRowKv) !void {
        const request = self.pending orelse return error.NothingPending;
        self.pending = null;
        self.loaded = .{ .request = request, .answer = switch (request) {
            .get => |g| .{ .get = try self.txn.get(g.key[0..g.len]) },
            .next => |n| .{ .next = try self.txn.next(&.{n.prefix}, if (n.after) |*after| after else null) },
        } };
    }
};

fn collectUntilIdle(store: *core.Store, backend: *loam.Volatile, work: usize, one_row: bool, counts: *Counts) !void {
    for (0..4096) |_| {
        try runBatch(store, backend, work, one_row, counts);
        if (store.metadata.collection.phase == .idle) return;
    }
    return error.CollectionDidNotFinish;
}

fn runBatch(store: *core.Store, backend: *loam.Volatile, work: usize, one_row: bool, counts: *Counts) !void {
    const ticket = try store.prepareCollection(work);
    const batch = try store.beginWrite(ticket);
    var write = try backend.beginWrite();
    var kv: OneRowKv = .{ .txn = &write, .counts = counts, .suspend_reads = one_row };
    var evaluation = core.Batch.Evaluation.init(&batch);
    const outcome: core.Outcome = outcome: {
        const next = settle(&evaluation, &kv) catch |err| {
            write.abort();
            break :outcome .{ .unchanged = err };
        };
        break :outcome switch (write.commit() catch |err| break :outcome .{ .unchanged = err }) {
            .committed => .{ .committed = next },
            .unknown => .unknown,
        };
    };
    try store.completeWrite(ticket, outcome);
    switch (outcome) {
        .committed => {},
        .unchanged => |err| return err,
        .unknown => return error.OutcomeUnknown,
    }
}

fn settle(evaluation: *core.Batch.Evaluation, kv: *OneRowKv) !core.Metadata {
    for (0..100_000) |_| {
        return evaluation.advance(kv) catch |err| {
            if (err != error.RecordUnloaded) return err;
            try kv.load();
            continue;
        };
    }
    return error.EvaluationDidNotFinish;
}

const Graph = struct { a: core.ObjectId, b: core.ObjectId, c: core.ObjectId, d: core.ObjectId, e: core.ObjectId, f: core.ObjectId, g: core.ObjectId, h: core.ObjectId };

/// A roots to B to C, A strongly to G after a weak edge to E, B strongly to H
/// which is then deleted, F rooted, D unreferenced, E reachable only weakly.
fn build(fixture: *f.Fixture) !Graph {
    const store = &fixture.store;
    try store.begin();
    const n: Graph = .{ .a = try store.allocateId(), .b = try store.allocateId(), .c = try store.allocateId(), .d = try store.allocateId(), .e = try store.allocateId(), .f = try store.allocateId(), .g = try store.allocateId(), .h = try store.allocateId() };
    var r = f.record(n.a, "a");
    r.rooted = true;
    r.edges = &.{ .{ .target = n.b }, .{ .target = n.e, .strength = .weak }, .{ .target = n.g } };
    try store.putCopying(r, null);
    r = f.record(n.b, "b");
    r.edges = &.{ .{ .target = n.c }, .{ .target = n.h } };
    try store.putCopying(r, null);
    try store.putCopying(f.record(n.c, "c"), null);
    try store.putCopying(f.record(n.d, "d"), null);
    try store.putCopying(f.record(n.e, "e"), null);
    r = f.record(n.f, "f");
    r.rooted = true;
    try store.putCopying(r, null);
    try store.putCopying(f.record(n.g, "g"), null);
    try store.putCopying(f.record(n.h, "h"), null);
    try f.commit(store, &fixture.backend);
    // B still names H, so tracing queues H and then finds it gone.
    try store.begin();
    try store.remove(n.h, 1);
    try f.commit(store, &fixture.backend);
    return n;
}

/// Reopen the same storage as a new Store, which claims a fresh incarnation.
fn reopen(fixture: *f.Fixture) !void {
    try fixture.store.deinit();
    try fixture.backend.close();
    const meta = try fixture.backend.open();
    fixture.store = try core.Store.init(std.testing.allocator, meta, &f.schemas, f.limits);
}

fn expectSwept(fixture: *f.Fixture, g: Graph, expected: core.Metadata) !void {
    const store = &fixture.store;
    try std.testing.expectEqual(.idle, store.metadata.collection.phase);
    try std.testing.expectEqual(expected.objects, store.metadata.objects);
    try std.testing.expectEqual(expected.record_bytes, store.metadata.record_bytes);
    for ([_]core.ObjectId{ g.a, g.b, g.c, g.f, g.g }) |id| {
        const lease = try f.load(store, &fixture.backend, id);
        try store.release(lease);
    }
    for ([_]core.ObjectId{ g.d, g.e, g.h }) |id| try std.testing.expectError(error.Gone, f.load(store, &fixture.backend, id));
}

test "loam collection finishes under one loaded row at a time and matches the synchronous sweep" {
    var reference = try f.Fixture.init(std.testing.allocator);
    defer reference.deinit();
    _ = try build(&reference);
    try f.collect(&reference.store, &reference.backend);
    try std.testing.expectEqual(@as(u64, 5), reference.store.metadata.objects);
    try std.testing.expectEqual(@as(u64, 2), reference.store.metadata.collection.reclaimed_objects);

    for ([_]usize{ 2, 1 }) |work| {
        var fixture = try f.Fixture.init(std.testing.allocator);
        defer fixture.deinit();
        const graph = try build(&fixture);
        const token = try fixture.store.retain(graph.f);
        var counts: Counts = .{};
        try collectUntilIdle(&fixture.store, &fixture.backend, work, true, &counts);
        try expectSwept(&fixture, graph, reference.store.metadata);
        // Every traced record costs a queue read and a record read, and H, which
        // is gone, still costs both: A, B, C, F, G, and H.
        try std.testing.expect(counts.get_suspensions >= 2 * 6);
        try std.testing.expect(counts.next_suspensions > 0);
        try std.testing.expectEqual(reference.store.metadata.collection.reclaimed_objects, fixture.store.metadata.collection.reclaimed_objects);
        try fixture.store.releaseRetention(token);
    }
}

test "loam collection retries a suspended step without redoing its writes" {
    var twin = try f.Fixture.init(std.testing.allocator);
    defer twin.deinit();
    const twin_graph = try build(&twin);
    const twin_token = try twin.store.retain(twin_graph.f);
    var direct: Counts = .{};
    try collectUntilIdle(&twin.store, &twin.backend, 1, false, &direct);
    try twin.store.releaseRetention(twin_token);

    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const graph = try build(&fixture);
    const token = try fixture.store.retain(graph.f);
    var suspended: Counts = .{};
    try collectUntilIdle(&fixture.store, &fixture.backend, 1, true, &suspended);
    try fixture.store.releaseRetention(token);

    try std.testing.expect(suspended.get_suspensions + suspended.next_suspensions > 0);
    try std.testing.expectEqual(@as(usize, 0), direct.get_suspensions + direct.next_suspensions);
    try std.testing.expectEqual(direct.puts, suspended.puts);
    try std.testing.expectEqual(direct.removals, suspended.removals);
    try std.testing.expectEqual(twin.store.metadata.objects, fixture.store.metadata.objects);
}

test "loam collection clears an interrupted cycle after reopening" {
    var reference = try f.Fixture.init(std.testing.allocator);
    defer reference.deinit();
    _ = try build(&reference);
    try f.collect(&reference.store, &reference.backend);

    var fixture = try f.Fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const graph = try build(&fixture);
    var counts: Counts = .{};
    // Run single-step batches until tracing has queued marks, then stop mid-cycle.
    for (0..64) |_| {
        if (fixture.store.metadata.collection.tail > 0) break;
        try runBatch(&fixture.store, &fixture.backend, 1, true, &counts);
    } else return error.NoMarksQueued;
    try std.testing.expect(fixture.store.metadata.collection.phase != .idle);

    try reopen(&fixture);
    try std.testing.expectEqual(.clearing, fixture.store.metadata.collection.phase);
    // The old marks are still stored, so the first batch clears and stays clearing. status-allow: replacement state identity
    try runBatch(&fixture.store, &fixture.backend, 1, true, &counts);
    try std.testing.expectEqual(.clearing, fixture.store.metadata.collection.phase);

    try collectUntilIdle(&fixture.store, &fixture.backend, 1, true, &counts);
    try expectSwept(&fixture, graph, reference.store.metadata);
}
