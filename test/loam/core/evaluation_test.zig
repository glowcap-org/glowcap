//! Suspended reads and emitted writes share one transaction. Each read yields
//! once. Backend borrows are overwritten at the next KV call. These probes
//! cover name indexing, shared strong targets and collection queue accounting.
const std = @import("std");
const core = @import("glowcap").loam.core;
const f = @import("fixture.zig");
const gpa = std.testing.allocator;
const schemas = [_]core.Schema{
    .{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 },
    .{ .id = 8, .version = 1, .max_payload = 256, .max_edges = 8, .name_offset = 0 },
};

const Kv = struct {
    const Row = struct { key: []u8, value: []u8 };
    rows: std.ArrayList(Row) = .empty,
    pending: ?usize = null,
    key: [35]u8 = undefined,
    borrowed: [1024]u8 = undefined,
    writes: usize = 0,
    reads: usize = 0,
    removals: usize = 0,
    refuse_after: ?usize = null,

    fn deinit(self: *Kv) void {
        for (self.rows.items) |row| {
            gpa.free(row.key);
            gpa.free(row.value);
        }
        self.rows.deinit(gpa);
    }
    pub fn get(self: *Kv, key: []const u8) !?[]const u8 {
        @memset(&self.borrowed, 0xa5);
        if (self.pending) |length| {
            try std.testing.expectEqualSlices(u8, self.key[0..length], key);
            self.pending = null;
            self.reads += 1;
            for (self.rows.items) |row| if (std.mem.eql(u8, row.key, key)) {
                @memcpy(self.borrowed[0..row.value.len], row.value);
                return self.borrowed[0..row.value.len];
            };
            return null;
        }
        @memcpy(self.key[0..key.len], key);
        self.pending = key.len;
        return error.RecordUnloaded;
    }
    pub fn put(self: *Kv, key: []const u8, bytes: []const u8) !void {
        if (self.refuse_after == self.writes) return error.RecordUnloaded;
        const value = try gpa.dupe(u8, bytes);
        errdefer gpa.free(value);
        for (self.rows.items) |*row| if (std.mem.eql(u8, row.key, key)) {
            gpa.free(row.value);
            row.value = value;
            self.writes += 1;
            @memset(&self.borrowed, 0xa5);
            return;
        };
        const owned_key = try gpa.dupe(u8, key);
        errdefer gpa.free(owned_key);
        try self.rows.append(gpa, .{ .key = owned_key, .value = value });
        self.writes += 1;
        @memset(&self.borrowed, 0xa5);
    }
    pub fn remove(self: *Kv, key: []const u8) !void {
        if (self.refuse_after == self.writes) return error.RecordUnloaded;
        for (self.rows.items, 0..) |row, i| if (std.mem.eql(u8, row.key, key)) {
            gpa.free(row.key);
            gpa.free(row.value);
            _ = self.rows.swapRemove(i);
            self.removals += 1;
            self.writes += 1;
            @memset(&self.borrowed, 0xa5);
            return;
        };
        return error.UnexpectedRemoval;
    }
    pub fn next(_: *Kv, _: []const u8, _: ?[]const u8) !?core.CollectionRow {
        return error.UnsupportedCollection;
    }
};

fn object(sequence: u64) core.ObjectId {
    return .{ .store = f.id, .incarnation = 1, .sequence = sequence };
}
fn batch(changes: []const core.Mutation) core.Batch {
    const ticket: core.Ticket = .{ .store = f.id, .incarnation = 1, .revision = 5, .sequence = 1 };
    return .{ .ticket = ticket, .changes = changes, .limits = f.limits.records, .schemas = &schemas };
}
fn advance(cursor: *core.Batch.Evaluation, kv: *Kv) !core.Metadata {
    for (0..128) |_| {
        return cursor.advance(kv) catch |err| {
            if (err == error.RecordUnloaded) continue;
            return err;
        };
    }
    return error.EvaluationDidNotFinish;
}

test "loam batch resumes every read without repeating writes or queue accounting" {
    try trace(null);
}

test "loam batch refuses suspension at every write including name and barrier helpers" {
    for (0..10) |after| try trace(after);
}

fn trace(refuse_after: ?usize) !void {
    var kv: Kv = .{};
    defer kv.deinit();
    const external: core.Record = .{ .id = object(200), .revision = 5, .schema = 7, .payload = "external", .rooted = true };
    const old_bytes = try external.encodeAlloc(gpa, f.limits.records, &schemas);
    defer gpa.free(old_bytes);
    const old: core.Metadata = .{ .store = f.id, .incarnation = 1, .revision = 5, .objects = 1, .roots = 1, .record_bytes = old_bytes.len, .collection = .{ .phase = .trace } };
    try kv.put("m", &old.encode());
    try kv.put(&external.id.key(), old_bytes);
    kv.writes = 0;
    kv.refuse_after = refuse_after;
    const root: core.Record = .{ .id = object(1), .revision = 6, .schema = 7, .payload = "root", .rooted = true, .edges = &.{ .{ .target = object(2) }, .{ .target = external.id } } };
    const child: core.Record = .{ .id = object(2), .revision = 6, .schema = 8, .payload = &@as([16]u8, @splat(0x42)), .edges = &.{.{ .target = external.id }} };
    const root_bytes = try root.encodeAlloc(gpa, f.limits.records, &schemas);
    defer gpa.free(root_bytes);
    const child_bytes = try child.encodeAlloc(gpa, f.limits.records, &schemas);
    defer gpa.free(child_bytes);
    const changes = [_]core.Mutation{
        .{ .id = root.id, .expected = null, .bytes = root_bytes },
        .{ .id = child.id, .expected = null, .bytes = child_bytes },
    };
    const submitted = batch(&changes);
    var cursor = core.Batch.Evaluation.init(&submitted);
    if (refuse_after) |after| {
        try std.testing.expectError(error.WriteWouldBlock, advance(&cursor, &kv));
        try std.testing.expectEqual(after, kv.writes);
        kv.refuse_after = null;
        try std.testing.expectError(error.InvalidBatch, cursor.advance(&kv));
        try std.testing.expectEqual(after, kv.writes);
        return;
    }
    const installed = try advance(&cursor, &kv);
    try std.testing.expectEqual(@as(u64, 6), installed.revision);
    try std.testing.expectEqual(@as(u64, 3), installed.objects);
    try std.testing.expectEqual(@as(u64, 2), installed.roots);
    try std.testing.expectEqual(old_bytes.len + root_bytes.len + child_bytes.len, installed.record_bytes);
    try std.testing.expectEqual(@as(u64, 3), installed.collection.tail);
    try std.testing.expectEqual(@as(usize, 10), kv.writes);
    try std.testing.expectError(error.StaleCompletion, cursor.advance(&kv));
    try std.testing.expectEqual(@as(usize, 10), kv.writes);
}

test "loam batch refuses a repeated or unordered record before any write" {
    var kv: Kv = .{};
    defer kv.deinit();
    const old: core.Metadata = .{ .store = f.id, .incarnation = 1, .revision = 5 };
    try kv.put("m", &old.encode());
    kv.writes = 0;
    var bytes: [2][]u8 = undefined;
    for (&bytes, 1..) |*out, sequence| {
        const record: core.Record = .{ .id = object(sequence), .revision = 6, .schema = 7, .payload = "row" };
        out.* = try record.encodeAlloc(gpa, f.limits.records, &schemas);
    }
    defer for (bytes) |row| gpa.free(row);
    const cases = [_]struct { changes: [2]core.Mutation, refusal: anyerror }{
        .{ .changes = .{ .{ .id = object(1), .expected = null, .bytes = bytes[0] }, .{ .id = object(1), .expected = null, .bytes = bytes[0] } }, .refusal = error.DuplicateMutation },
        .{ .changes = .{ .{ .id = object(2), .expected = null, .bytes = bytes[1] }, .{ .id = object(1), .expected = null, .bytes = bytes[0] } }, .refusal = error.InvalidBatch },
    };
    for (&cases) |*case| {
        const submitted = batch(&case.changes);
        var cursor = core.Batch.Evaluation.init(&submitted);
        try std.testing.expectError(case.refusal, advance(&cursor, &kv));
        try std.testing.expectEqual(@as(usize, 0), kv.writes);
    }
}

test "loam batch write suspension is terminal after successful validation" {
    var kv: Kv = .{};
    defer kv.deinit();
    const old: core.Metadata = .{ .store = f.id, .incarnation = 1, .revision = 5 };
    try kv.put("m", &old.encode());
    const record: core.Record = .{ .id = object(1), .revision = 6, .schema = 7, .payload = "write" };
    const bytes = try record.encodeAlloc(gpa, f.limits.records, &schemas);
    defer gpa.free(bytes);
    const changes = [_]core.Mutation{.{ .id = record.id, .expected = null, .bytes = bytes }};
    const submitted = batch(&changes);
    var cursor = core.Batch.Evaluation.init(&submitted);
    kv.refuse_after = kv.writes;
    try std.testing.expectError(error.WriteWouldBlock, advance(&cursor, &kv));
    kv.refuse_after = null;
    try std.testing.expectError(error.InvalidBatch, cursor.advance(&kv));
    try std.testing.expectEqual(@as(usize, 1), kv.writes);
}

test "loam batch fetches only the strong targets a rewrite introduces" {
    var kv: Kv = .{};
    defer kv.deinit();
    var record_bytes: usize = 0;
    for (2..5) |sequence| {
        const target: core.Record = .{ .id = object(sequence), .revision = 5, .schema = 7, .payload = "target", .rooted = true };
        const bytes = try target.encodeAlloc(gpa, f.limits.records, &schemas);
        defer gpa.free(bytes);
        record_bytes += bytes.len;
        try kv.put(&target.id.key(), bytes);
    }
    const previous: core.Record = .{ .id = object(1), .revision = 5, .schema = 7, .payload = "old", .rooted = true, .edges = &.{ .{ .target = object(2) }, .{ .target = object(3) } } };
    const old_bytes = try previous.encodeAlloc(gpa, f.limits.records, &schemas);
    defer gpa.free(old_bytes);
    record_bytes += old_bytes.len;
    try kv.put(&previous.id.key(), old_bytes);
    const old: core.Metadata = .{ .store = f.id, .incarnation = 1, .revision = 5, .objects = 4, .roots = 4, .record_bytes = record_bytes };
    try kv.put("m", &old.encode());
    // Edge 2 is dropped, 3 is kept, and 4 is introduced: only 4 is fetched.
    const record: core.Record = .{ .id = object(1), .revision = 6, .schema = 7, .payload = "rewritten", .rooted = true, .edges = &.{ .{ .target = object(3) }, .{ .target = object(4) } } };
    const bytes = try record.encodeAlloc(gpa, f.limits.records, &schemas);
    defer gpa.free(bytes);
    const changes = [_]core.Mutation{.{ .id = object(1), .expected = 5, .bytes = bytes }};
    const submitted = batch(&changes);
    var cursor = core.Batch.Evaluation.init(&submitted);
    kv.reads = 0;
    const installed = try advance(&cursor, &kv);
    try std.testing.expectEqual(@as(u64, 6), installed.revision);
    try std.testing.expectEqual(@as(u64, 4), installed.objects);
    try std.testing.expectEqual(@as(usize, 3), kv.reads);
}

test "loam batch retains replacement and deletion accounting across suspended edge reads" {
    for ([_]bool{ false, true }) |refuse_remove| try replacement(refuse_remove);
}

fn replacement(refuse_remove: bool) !void {
    var kv: Kv = .{};
    defer kv.deinit();
    var old_bytes: usize = 0;
    for (1..4) |sequence| {
        const previous: core.Record = .{ .id = object(sequence), .revision = 5, .schema = 7, .payload = "old", .rooted = sequence != 2 };
        const bytes = try previous.encodeAlloc(gpa, f.limits.records, &schemas);
        defer gpa.free(bytes);
        old_bytes += bytes.len;
        try kv.put(&previous.id.key(), bytes);
    }
    const old: core.Metadata = .{ .store = f.id, .incarnation = 1, .revision = 5, .objects = 3, .roots = 2, .record_bytes = old_bytes };
    try kv.put("m", &old.encode());
    const record: core.Record = .{ .id = object(1), .revision = 6, .schema = 7, .payload = "replacement", .edges = &.{ .{ .target = object(3) }, .{ .target = object(3) } } };
    const bytes = try record.encodeAlloc(gpa, f.limits.records, &schemas);
    defer gpa.free(bytes);
    const changes = [_]core.Mutation{
        .{ .id = object(1), .expected = 5, .bytes = bytes },
        .{ .id = object(2), .expected = 5, .bytes = null },
    };
    const submitted = batch(&changes);
    var cursor = core.Batch.Evaluation.init(&submitted);
    kv.writes = 0;
    if (refuse_remove) {
        kv.refuse_after = 1;
        try std.testing.expectError(error.WriteWouldBlock, advance(&cursor, &kv));
        try std.testing.expectEqual(@as(usize, 0), kv.removals);
        try std.testing.expectEqual(@as(usize, 1), kv.writes);
        kv.refuse_after = null;
        try std.testing.expectError(error.InvalidBatch, cursor.advance(&kv));
        return;
    }
    const installed = try advance(&cursor, &kv);
    try std.testing.expectEqual(@as(u64, 6), installed.revision);
    try std.testing.expectEqual(@as(u64, 2), installed.objects);
    try std.testing.expectEqual(@as(u64, 1), installed.roots);
    const surviving: core.Record = .{ .id = object(3), .revision = 5, .schema = 7, .payload = "old", .rooted = true };
    const survivor = try surviving.encodeAlloc(gpa, f.limits.records, &schemas);
    defer gpa.free(survivor);
    try std.testing.expectEqual(bytes.len + survivor.len, installed.record_bytes);
    try std.testing.expectEqual(@as(usize, 1), kv.removals);
    try std.testing.expectEqual(@as(usize, 3), kv.writes);
}
