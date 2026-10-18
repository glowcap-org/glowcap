//! Cleanup commits progress with identity refusal and preserves allocation floors.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const f = h.f;
const c = h.c;
const storage = c.storage;
const records = f.loam.access.records;

const change = @import("maintenance_fixture.zig").change;
const finish = @import("maintenance_fixture.zig").finish;

test "access maintenance owner retirement closes admission and compacts retained identities" {
    var fixture = try f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const data = try h.seed(store, backend);
    const use_endpoint = try c.load(store, backend, data.use);
    const descriptor = (try records.EndpointRecord.decode(try store.currentView(use_endpoint))).descriptor;
    try store.release(use_endpoint);
    var caps = try storage.Capabilities.init(h.a, store, .{});
    defer caps.deinit() catch unreachable;
    const use = try c.use(&caps, backend, descriptor);
    defer use.release();
    const outstanding = try use.begin(4);
    _ = try f.pump(outstanding, backend);
    const started = try change(store, backend, data.owner, .retire, 0);
    try std.testing.expectError(error.RevisionConflict, outstanding.require(data.resource, .{ .permissions = &.{f.vocabulary.read} }));
    try outstanding.deinit();
    const refused = try use.begin(4);
    try std.testing.expectError(error.OwnerRetired, f.pump(refused, backend));
    try refused.deinit();
    const replay = try change(store, backend, data.owner, .retire, 0);
    try std.testing.expect(replay.replay);
    try std.testing.expectEqual(started.sequence, replay.sequence);
    var result = started;
    for (0..64) |_| {
        if (result.phase == .idle) break;
        result = try change(store, backend, data.owner, .step, result.sequence);
    }
    try std.testing.expect(result.retired);
    var read: storage.Read = undefined;
    try read.init(h.a, store, data.owner, 1, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    try std.testing.expectEqual(@as(u64, 6), read.header.next_identity);
    try std.testing.expectEqual(@as(u64, 1), read.header.next_grant);
    try std.testing.expectEqual(@as(u64, 1), read.header.next_resource);
    try std.testing.expectEqual(@as(usize, 0), blk: {
        var edges: [records.OwnerRecord.max_edges]f.loam.core.Edge = undefined;
        break :blk read.header.edges(&edges).len;
    });
    try std.testing.expectError(error.OwnerRetired, storage.Append.init(&read, .resource));
    const dead = try c.load(store, backend, descriptor);
    defer store.release(dead) catch unreachable;
    const terminal = try records.TerminalRecord.decode(try store.currentView(dead));
    try std.testing.expectEqual(records.TerminalRecord.Kind.capability, terminal.kind);
    try std.testing.expectError(error.CapabilityRetired, caps.restoreUse(dead));
    try @import("../core/fixture.zig").collect(store, backend);
}

test "access maintenance sweep prunes terminal grants and missing weak identities without resetting floors" {
    var fixture = try f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(71));
    const resource = try f.resource(store, backend, owner, null);
    const terms = try f.vocabulary.terms(.{ .object = resource }, &.{f.vocabulary.read}, null);
    const grant = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 0) })).?.grant;
    var caps = try storage.Capabilities.init(h.a, store, .{});
    defer caps.deinit() catch unreachable;
    _ = try c.descriptor(&caps, backend, owner, grant, null, .reachable);
    try @import("../core/fixture.zig").collect(store, backend);
    _ = try f.change(store, backend, owner, .{ .revoke = grant });
    const result = try finish(store, backend, owner, .sweep, 0);
    try std.testing.expect(!result.retired);
    var read: storage.Read = undefined;
    try read.init(h.a, store, owner, 1, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    try std.testing.expect(read.header.grants == null);
    try std.testing.expect(read.header.identities == null);
    try std.testing.expectEqual(@as(u64, 1), read.header.next_grant);
    try std.testing.expectEqual(@as(u64, 1), read.header.next_identity);
    const next = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 0) })).?.grant;
    try std.testing.expectEqual(@as(u32, 1), next.slot);
}

test "access maintenance hosted retirement preserves held refusal and retry floors" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    try @import("maintenance_hosted_cases.zig").replay(&store, &backend, @import("../core/fixture.zig").collect);
}

test "access maintenance cancellation preserves exact pending read custody" {
    var fixture = try f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    const data = try h.seed(&fixture.store, &fixture.backend);
    fixture.store.evict();
    const operation = try storage.Maintenance.init(h.a, &fixture.store, data.owner, .retire, 0, 4);
    defer operation.deinit() catch unreachable;
    const request = (try operation.advance()).read;
    try std.testing.expectError(error.Busy, operation.deinit());
    var stale = request.ticket;
    stale.sequence += 1;
    try std.testing.expectError(error.StaleCompletion, operation.completeRead(stale, .missing));
    try std.testing.expectError(error.Busy, operation.deinit());
    try operation.cancel();
    try std.testing.expectError(error.Canceled, operation.completeRead(request.ticket, fixture.backend.read(request)));
    try std.testing.expectError(error.StaleCompletion, operation.completeRead(request.ticket, .missing));
    try std.testing.expectError(error.Cancelled, operation.advance());
}

test "access maintenance aborted steps and stale preparations cannot advance progress" {
    var fixture = try f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    const data = try h.seed(&fixture.store, &fixture.backend);
    const operation = try storage.Maintenance.init(h.a, &fixture.store, data.owner, .retire, 0, 4);
    defer operation.deinit() catch unreachable;
    _ = try f.pump(operation, &fixture.backend);
    const competing = try storage.Maintenance.init(h.a, &fixture.store, data.owner, .retire, 0, 4);
    defer competing.deinit() catch unreachable;
    _ = try f.pump(competing, &fixture.backend);
    try fixture.store.begin();
    try std.testing.expect(try operation.stage(null));
    try std.testing.expectError(error.RevisionConflict, competing.stage(null));
    try fixture.store.abort();
    const committed = try change(&fixture.store, &fixture.backend, data.owner, .retire, 0);
    try std.testing.expectEqual(@as(u64, 1), committed.sequence);
    try std.testing.expectError(error.RevisionConflict, competing.advance());
    try std.testing.expectError(error.SequenceConflict, change(&fixture.store, &fixture.backend, data.owner, .sweep, 0));
    try std.testing.expectError(error.FutureSequence, change(&fixture.store, &fixture.backend, data.owner, .step, 2));
}

test "access maintenance repeated create share revoke delete cycles reclaim payload and index storage" {
    var fixture = try f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    try @import("maintenance_cases.zig").churn(&fixture.store, &fixture.backend, @import("../core/fixture.zig").collect);
}

test "access maintenance retired mutation results refuse replay while issuer control remains live" {
    var backend = try h.loam.Volatile.init(h.a, h.f.store_id, 16 * 1024 * 1024);
    defer backend.deinit();
    var store = try h.loam.core.Store.init(h.a, try backend.open(), &h.schemas, h.limits);
    defer store.deinit() catch unreachable;
    try @import("maintenance_hosted_cases.zig").controlReceipt(&store, &backend);
}

test "access maintenance failed reads cannot close admission or advance the journal" {
    var fixture = try f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    const data = try h.seed(&fixture.store, &fixture.backend);
    const revision = fixture.store.metadata.revision;
    fixture.store.evict();
    const operation = try storage.Maintenance.init(h.a, &fixture.store, data.owner, .retire, 0, 4);
    defer operation.deinit() catch unreachable;
    const request = (try operation.advance()).read;
    try std.testing.expectError(error.InjectedReadFailure, operation.completeRead(request.ticket, .{ .failed = error.InjectedReadFailure }));
    try std.testing.expectError(error.InjectedReadFailure, operation.advance());
    try std.testing.expectEqual(revision, fixture.store.metadata.revision);
    const started = try change(&fixture.store, &fixture.backend, data.owner, .retire, 0);
    try std.testing.expectEqual(@as(u64, 1), started.sequence);
}

fn allocateMaintenance(allocator: std.mem.Allocator, store: *h.loam.core.Store, backend: *h.loam.Volatile, owner: h.loam.core.ObjectId, sequence: u64) !void {
    const operation = try storage.Maintenance.init(allocator, store, owner, .step, sequence, 4);
    defer operation.deinit() catch unreachable;
    _ = try f.pump(operation, backend);
    try store.begin();
    defer if (store.phase == .staging or store.phase == .prepared) store.abort() catch unreachable;
    _ = try operation.stage(null);
}

test "access maintenance partial preparations and staging release every allocation on refusal" {
    var fixture = try f.Fixture.init(h.a, h.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const owner = try f.create(store, backend, @fromBackingInt(72));
    const resource = try f.resource(store, backend, owner, null);
    const terms = try f.vocabulary.terms(.{ .objects = &.{resource} }, &.{f.vocabulary.read}, null);
    const grant = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 0) })).?.grant;
    _ = try f.change(store, backend, owner, .{ .revoke = grant });
    var result = try change(store, backend, owner, .sweep, 0);
    while (result.phase != .grants) result = try change(store, backend, owner, .step, result.sequence);
    const revision = store.metadata.revision;
    try std.testing.checkAllAllocationFailures(h.a, allocateMaintenance, .{ store, backend, owner, result.sequence });
    try std.testing.expectEqual(revision, store.metadata.revision);
}
