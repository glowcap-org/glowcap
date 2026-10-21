//! The in-memory archive's C door: no path, a store that exists only once
//! created, stores that coexist under one identity, a committed creation, and
//! the lock that lets storage workers and the Host thread share one engine.
const std = @import("std");
const c = @import("c_abi_loam");
const n = @import("c_abi_loam_volatile");
const sqlite = @import("c_abi_loam_sqlite");
const shared = @import("c_abi_shared");
const loam = @import("loam_core");

const limits: c.GlowcapLoamLimits = .{ .resident_bytes = 4 * 1024 * 1024, .staging_bytes = 4 * 1024 * 1024, .cache_slots = 64, .max_leases = 128, .max_changes = 64, .max_references = 128, .max_operations = 32, .record_capacity = 32, .max_reference_saves = 96, .max_retentions = 256, .max_continuations = 2, .continuation_bytes = 4096, .max_continuation_targets = 3, .forward_reply_bytes = 3072 };
const schema: c.GlowcapLoamSchema = .{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 };
const capacity: usize = 8 * 1024 * 1024;

fn open(id: *const [16]u8, mode: u32, backend: *?*n.GlowcapLoamVolatile, store: *?*c.GlowcapLoamStore) i32 {
    return n.glowcap_loam_volatile_open(id, mode, capacity, @as([*]const c.GlowcapLoamSchema, @ptrCast(&schema)), 1, &limits, backend, store);
}

test "Loam C in-memory archive has its own fingerprint and error slot" {
    try std.testing.expect(n.glowcap_loam_volatile_archive_fingerprint() != sqlite.glowcap_loam_sqlite_archive_fingerprint());
    n.glowcap_loam_volatile_clear_last_error();
    try std.testing.expectEqual(@as(usize, 0), n.glowcap_loam_volatile_last_error(null, 0));
}

test "Loam C in-memory open refuses without leaving a slot behind" {
    const id: [16]u8 = @splat(3);
    var backend: ?*n.GlowcapLoamVolatile = null;
    var store: ?*c.GlowcapLoamStore = null;

    // No store exists before it is created.
    try std.testing.expectEqual(shared.GLOWCAP_ERR_NOT_FOUND, open(&id, 0, &backend, &store));
    try std.testing.expect(backend == null and store == null);
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, open(&id, 3, &backend, &store));
    try std.testing.expect(backend == null and store == null);

    // A null out slot is refused, and the other slot stays untouched.
    try std.testing.expectEqual(shared.GLOWCAP_ERR_NULL_POINTER, n.glowcap_loam_volatile_open(&id, 1, capacity, @as([*]const c.GlowcapLoamSchema, @ptrCast(&schema)), 1, &limits, null, &store));
    try std.testing.expect(store == null);
    try std.testing.expectEqual(shared.GLOWCAP_ERR_NULL_POINTER, n.glowcap_loam_volatile_open(&id, 1, capacity, @as([*]const c.GlowcapLoamSchema, @ptrCast(&schema)), 1, &limits, &backend, null));
    try std.testing.expect(backend == null);
}

test "Loam C in-memory stores with one identity open at once" {
    const id: [16]u8 = @splat(3);
    var first: ?*n.GlowcapLoamVolatile = null;
    var first_store: ?*c.GlowcapLoamStore = null;
    var second: ?*n.GlowcapLoamVolatile = null;
    var second_store: ?*c.GlowcapLoamStore = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, open(&id, 1, &first, &first_store));
    try std.testing.expectEqual(shared.GLOWCAP_OK, open(&id, 2, &second, &second_store));
    try std.testing.expect(first != second and first_store != second_store);
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_volatile_release(first));
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_volatile_release(second));
}

test "Loam C in-memory resource is staged, committed, and collected" {
    const id: [16]u8 = @splat(3);
    var backend: ?*n.GlowcapLoamVolatile = null;
    var store: ?*c.GlowcapLoamStore = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, open(&id, 1, &backend, &store));
    var policy = std.mem.zeroes(c.GlowcapLoamPolicy);
    policy.identity = @splat(5);
    policy.permissions[0] = 10;
    policy.permissions[1] = 20;
    policy.permission_count = 2;
    policy.prerequisite_masks[1] = 1;
    var resource: c.GlowcapLoamResource = undefined;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_resource_stage(store, &policy, &id, 1, 7, 1, "initial", 7, 2, &resource));
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_volatile_commit(backend));
    try std.testing.expectEqual(.idle, (try c.embedding.store(store)).value.phase);
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_volatile_collect(backend, 4));
    // Nothing is indeterminate, so recovery has nothing to resolve.
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, n.glowcap_loam_volatile_recover(backend));
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_volatile_release(backend));
}

const Race = struct {
    serialized: *n.Serialized,
    ticket: loam.Ticket,
    done: std.atomic.Value(bool) = .init(false),
    /// The revision the last commit reached, which readers ask for.
    revision: std.atomic.Value(u64) = .init(0),
    /// Reads that found their record, which proves the readers raced the
    /// commits on the rows themselves and not only on the metadata check.
    found: std.atomic.Value(usize) = .init(0),
    broken: std.atomic.Value(bool) = .init(false),

    fn id(self: *const Race, sequence: u64) loam.ObjectId {
        return .{ .store = self.ticket.store, .incarnation = self.ticket.incarnation, .sequence = sequence };
    }

    fn read(self: *Race) void {
        var buffer: [512]u8 = undefined;
        var sequence: u64 = 1;
        while (!self.done.load(.acquire)) {
            var ticket = self.ticket;
            ticket.revision = self.revision.load(.acquire);
            switch (self.serialized.read(.{ .ticket = ticket, .id = self.id(sequence), .buffer = &buffer })) {
                .found => |found| {
                    if (found.length == 0) self.broken.store(true, .release);
                    _ = self.found.fetchAdd(1, .monotonic);
                },
                // A record the commits have not reached yet. status-allow: pending state or quoted runtime label
                .missing => {},
                // A commit landed between reading the revision and the read.
                .failed => |err| if (err != error.StaleCompletion) self.broken.store(true, .release),
            }
            sequence = sequence % @max(ticket.revision, 1) + 1;
        }
    }
};

test "Loam C in-memory engine serves reads while the Host thread commits" {
    const allocator = std.heap.smp_allocator;
    const store_id: loam.StoreId = @fromBackingInt(@intCast(9));
    var serialized = try n.Serialized.open(allocator, store_id, capacity);
    defer serialized.close() catch {};
    const Batch = loam.Batch;
    const schemas = [_]loam.Schema{.{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 }};
    const record_limits: @FieldType(Batch, "limits") = .{};
    const commits: u64 = 200;
    var race: Race = .{
        .serialized = &serialized,
        .ticket = .{ .store = store_id, .incarnation = serialized.metadata.incarnation, .sequence = 0, .revision = 0 },
    };
    var readers: [4]std.Thread = undefined;
    for (&readers) |*thread| thread.* = try std.Thread.spawn(.{}, Race.read, .{&race});

    var failed = false;
    var sequence: u64 = 1;
    while (sequence <= commits) : (sequence += 1) {
        const record: loam.Record = .{ .id = race.id(sequence), .revision = sequence, .schema = 7, .rooted = true, .payload = "payload" };
        const bytes = try record.encodeAlloc(allocator, record_limits, &schemas);
        defer allocator.free(bytes);
        const change = [_]loam.Mutation{.{ .id = record.id, .expected = null, .bytes = bytes }};
        const outcome = serialized.commit(.{
            .ticket = .{ .store = store_id, .incarnation = race.ticket.incarnation, .sequence = sequence, .revision = sequence - 1 },
            .changes = &change,
            .limits = record_limits,
            .schemas = &schemas,
        });
        if (outcome != .committed) failed = true;
        race.revision.store(sequence, .release);
    }
    race.done.store(true, .release);
    for (readers) |thread| thread.join();

    try std.testing.expect(!failed);
    try std.testing.expect(!race.broken.load(.acquire));
    try std.testing.expect(race.found.load(.monotonic) > 0);
    var buffer: [512]u8 = undefined;
    var settled = race.ticket;
    settled.revision = commits;
    for ([_]u64{ 1, commits }) |last| {
        const result = serialized.read(.{ .ticket = settled, .id = race.id(last), .buffer = &buffer });
        try std.testing.expect(result == .found);
        try std.testing.expectEqual(commits, result.found.metadata.revision);
    }
}
