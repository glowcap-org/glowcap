//! Retention and effect codecs keep bounded ownership and canonical edges.
//! Removing early transaction binding made the allocation-failure proof fail.
const std = @import("std");
const f = @import("owner_fixture.zig");
const records = f.loam.access.records;
const core = f.loam.access.core;
const a = std.testing.allocator;
const object: f.loam.core.ObjectId = .{ .store = f.store_id, .incarnation = 1, .sequence = 1 };
const owner: core.OwnerId = @fromBackingInt(42);
const target: core.ResourceId = .{ .owner = owner, .slot = 1, .generation = std.math.maxInt(u64) };

fn frame(allocator: std.mem.Allocator, schema: u64, bytes: []const u8, edges: []const f.loam.core.Edge) ![]u8 {
    return (f.loam.core.Record{ .id = object, .revision = 7, .schema = schema, .payload = bytes, .edges = edges }).encodeAlloc(allocator, f.limits.records, &f.schemas);
}

fn roundTrip(allocator: std.mem.Allocator) !void {
    const grant: core.GrantId = .{ .owner = owner, .slot = 2, .generation = std.math.maxInt(u64) };
    const batch: records.ChangeBatchRecord = .{ .owner = owner, .commit_revision = 7, .sequence = 1, .effects = &.{
        .{ .content = .{ .id = target, .path = &.{target} } },
        .{ .resource = .{ .id = target, .kind = .created, .before = &.{}, .after = &.{target} } },
        .{ .grant = .{ .change = .{ .version = .{ .resources = @fromBackingInt(1), .grants = @fromBackingInt(1) }, .grant = grant, .kind = .{ .issued = null } }, .path = &.{grant} } },
        .{ .control = .{ .object = object, .kind = .revoked } },
    } };
    const bytes = try batch.encodeAlloc(allocator);
    defer allocator.free(bytes);
    const encoded = try frame(allocator, records.profile.change_batch, bytes, &.{});
    defer allocator.free(encoded);
    var decoded = try records.ChangeBatchRecord.decodeOwned(allocator, try f.loam.core.RecordView.decode(encoded, f.limits.records, &f.schemas));
    defer decoded.deinit(allocator);
    @memset(encoded, 0);
    try std.testing.expectEqualDeep(batch, decoded.value);
}

test "access retained batch owns paths including full generation width and unwinds failures" {
    try std.testing.checkAllAllocationFailures(a, roundTrip, .{});
    const batch: records.ChangeBatchRecord = .{ .owner = owner, .commit_revision = 7, .sequence = 1, .effects = &.{.{ .content = .{ .id = target, .path = &.{target} } }} };
    const bytes = try batch.encodeAlloc(a);
    defer a.free(bytes);
    for (0..bytes.len) |length| {
        const encoded = try frame(a, records.profile.change_batch, bytes[0..length], &.{});
        defer a.free(encoded);
        if (records.ChangeBatchRecord.decodeOwned(a, try f.loam.core.RecordView.decode(encoded, f.limits.records, &f.schemas))) |value| {
            var owned = value;
            owned.deinit(a);
            return error.AcceptedTruncation;
        } else |_| {}
    }
}

test "access history drops oldest edges at capacity and refuses invalid edge custody" {
    var history: records.ChangeHistoryRecord = .{ .owner = owner };
    for (1..40) |sequence| {
        var id = object;
        id.sequence = sequence;
        try std.testing.expectEqual(sequence, try history.append(id));
    }
    try std.testing.expectEqual(@as(usize, 32), history.count);
    try std.testing.expectEqual(@as(u64, 8), history.firstSequence());
    try std.testing.expectEqual(@as(u64, 8), history.batches[0].sequence);
    var edges: [records.ChangeHistoryRecord.capacity]f.loam.core.Edge = undefined;
    const bytes = try history.encodeAlloc(a);
    defer a.free(bytes);
    const encoded = try frame(a, records.profile.change_history, bytes, try history.edges(&edges));
    defer a.free(encoded);
    const decoded = try records.ChangeHistoryRecord.decode(try f.loam.core.RecordView.decode(encoded, f.limits.records, &f.schemas));
    try std.testing.expectEqual(history.next_sequence, decoded.next_sequence);
    try std.testing.expectEqualDeep(history.batches[0..history.count], decoded.batches[0..decoded.count]);
    edges[0].strength = .weak;
    const invalid = try frame(a, records.profile.change_history, bytes, &edges);
    defer a.free(invalid);
    try std.testing.expectError(error.InvalidRecord, records.ChangeHistoryRecord.decode(try f.loam.core.RecordView.decode(invalid, f.limits.records, &f.schemas)));
    history.count = 33;
    try std.testing.expectError(error.InvalidRecord, history.edges(&edges));
}

test "access history composes real effects refuses overflow atomically and collects expired batches" {
    const h = @import("hosting_fixture.zig");
    const cases = @import("history_cases.zig");
    var fixture = try f.Fixture.init(a, h.limits);
    defer fixture.deinit();
    try cases.composed(&fixture.store, &fixture.backend);
    try cases.capacity(&fixture.store, &fixture.backend);
    try cases.overflow(&fixture.store, &fixture.backend, @import("../core/fixture.zig").collect);
}

fn stagingFailure(allocator: std.mem.Allocator, reached: *bool) !void {
    var fixture = try f.Fixture.init(allocator, f.limits);
    defer fixture.deinit();
    const owner_object = try f.create(&fixture.store, &fixture.backend, owner);
    var read = try f.storage.Read.init(allocator, &fixture.store, owner_object, 1);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, &fixture.backend);
    var append = try f.storage.Append.init(&read, .resource);
    defer append.deinit() catch unreachable;
    _ = try f.pump(&append, &fixture.backend);
    try f.prepareResource(&append, &read, &fixture.backend, null);
    try fixture.store.begin();
    errdefer if (fixture.store.phase == .staging) fixture.store.abort() catch unreachable;
    _ = f.storage.stage.appendResource(&append, f.vocabulary.kind, null) catch |err| {
        if (err != error.OutOfMemory) return err;
        try std.testing.expectEqual(.idle, fixture.store.phase);
        try std.testing.expectError(error.RevisionConflict, read.advance());
        if (read.header.next_resource != 0) reached.* = true;
        return err;
    };
    try f.commit(&fixture.store, &fixture.backend);
}

test "access history failed first staging invalidates its mutated read at every allocation boundary" {
    var reached_mutated_header = false;
    try std.testing.checkAllAllocationFailures(a, stagingFailure, .{&reached_mutated_header});
    try std.testing.expect(reached_mutated_header);
}

fn idempotent(_: ?*anyopaque, _: []const u8, _: []const @import("hosting_fixture.zig").driver.Value) !@import("hosting_fixture.zig").access.RetryMode {
    return .idempotent;
}

test "access history direct equal content and reference edits settle without a transaction" {
    const h = @import("hosting_fixture.zig");
    const cases = @import("history_cases.zig");
    var backend = try h.loam.Volatile.init(a, f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    const data = try h.seed(&store, &backend);
    var host: h.Hosted = undefined;
    try host.init(&store, &backend, data);
    defer host.deinit();
    var contents = host.contents;
    contents[0].retry = idempotent;
    host.service.contents = &contents;
    const lease = try h.c.load(&store, &backend, data.content);
    const row = try store.currentView(lease);
    try store.begin();
    try store.putCopying(.{ .id = row.id, .revision = 0, .schema = row.schema, .payload = row.payload, .edges = &.{ .{ .target = data.use }, .{ .target = data.control, .strength = .weak } } }, row.revision);
    try store.release(lease);
    try f.commit(&store, &backend);
    host.application.replacement = host.use;
    defer host.application.replacement = null;
    const before = try cases.history(&store, &backend, data.owner);
    const revision = store.metadata.revision;
    var payload: h.Answer = .{};
    try host.send(host.use, "add", &.{.{ .integer = 0 }}, &payload);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?i64, 0), payload.number);
    var reference: h.Answer = .{};
    try host.send(host.use, "replace-reference", &.{}, &reference);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?bool, true), reference.changed);
    try std.testing.expectEqual(revision, store.metadata.revision);
    try std.testing.expectEqual(before.next_sequence, (try cases.history(&store, &backend, data.owner)).next_sequence);
    var receipt: h.Answer = .{};
    try host.mutate(host.use, 1, "add", &.{.{ .integer = 0 }}, &receipt);
    try host.drain(&backend);
    try std.testing.expectEqual(@as(?i64, 0), receipt.number);
    try std.testing.expectEqual(revision + 1, store.metadata.revision);
    try std.testing.expectEqual(before.next_sequence, (try cases.history(&store, &backend, data.owner)).next_sequence);
}

test "access history preserves scoped stamp boundaries" {
    const h = @import("hosting_fixture.zig");
    var fixture = try f.Fixture.init(a, h.limits);
    defer fixture.deinit();
    try @import("history_stamp_cases.zig").stamps(&fixture.store, &fixture.backend);
}

test "access history accepts depth 64 paths and refuses depth 65 before staging" {
    const cases = @import("history_stamp_cases.zig");
    var fixture = try f.Fixture.init(a, cases.depth_limits);
    defer fixture.deinit();
    try cases.depth(&fixture.store, &fixture.backend);
}
