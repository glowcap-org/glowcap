//! Cold process witnesses for owner closure and a terminal publication step.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const d = @import("description_fixture.zig");
const wire = @import("../../support/storage_host_pair.zig");
const pairs = @import("../../support/host_pair.zig");
const native = @import("maintenance_fixture.zig");
const publication = h.loam.hosting.publication;
const core = h.loam.core;
const records = h.loam.access.records;
const model = h.f.glowcap.ocapn.model;
pub const admin_name: publication.Entropy = @splat(0x93);
const witness_name: publication.Entropy = @splat(0x94);
pub const schema: core.Schema = .{ .id = 9, .version = 1, .max_payload = 32, .max_edges = 0, .name_offset = 0 };

pub fn owner(server: anytype) !core.ObjectId {
    const store = server.caps.store;
    const result = server.db.lookup(.{ .ticket = .{ .store = store.metadata.store, .incarnation = store.metadata.incarnation, .revision = store.metadata.revision, .sequence = 1 }, .name = .{ .schema = publication.schema.id, .bytes = admin_name } });
    const id = switch (result) {
        .found => |id| id,
        .failed => |err| return err,
        .missing => return error.MissingAdmin,
    };
    const lease = try h.c.load(store, server.db, id);
    defer store.release(lease) catch unreachable;
    return publication.activeTarget(try store.currentView(lease));
}
fn header(server: anytype) !records.OwnerRecord {
    const store = server.caps.store;
    const lease = try h.c.load(store, server.db, try owner(server));
    defer store.release(lease) catch unreachable;
    return records.OwnerRecord.decode(try store.currentView(lease));
}
fn witness(server: anytype) !publication.Entropy {
    const store = server.caps.store;
    const result = server.db.lookup(.{ .ticket = .{ .store = store.metadata.store, .incarnation = store.metadata.incarnation, .revision = store.metadata.revision, .sequence = 1 }, .name = .{ .schema = schema.id, .bytes = witness_name } });
    const id = switch (result) {
        .found => |id| id,
        .failed => |err| return err,
        .missing => return error.MissingWitness,
    };
    const lease = try h.c.load(store, server.db, id);
    defer store.release(lease) catch unreachable;
    const view = try store.currentView(lease);
    if (view.schema != schema.id or view.payload.len != 32) return error.InvalidWitness;
    return view.payload[16..32].*;
}

pub fn create(server: anytype, client: *h.driver.Host, pair: pairs.Pair, use: model.Reference, owner_id: core.ObjectId, cleanup: bool) !void {
    const store = server.caps.store;
    try store.begin();
    _ = try publication.stageTarget(store, admin_name, owner_id);
    try h.f.commit(store, server.db);
    if (!cleanup) return;
    var child: d.f.captures.CapturedRef = .{};
    try wire.send(client, pair, use, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &child);
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    const target = try child.require();
    const receipt_endpoint = endpoint: {
        const lease = try h.c.load(store, server.db, try owner(server));
        const value = try records.OwnerRecord.decode(try store.currentView(lease));
        try store.release(lease);
        var read: h.c.storage.Read = undefined;
        try read.init(store.allocator, store, owner_id, 1, null);
        defer read.deinit() catch unreachable;
        _ = try h.f.pump(&read, server.db);
        const slot: u32 = @intCast(value.next_identity - 1);
        _ = try read.binding(.{ .identity = .{ .owner = value.owner, .slot = slot } });
        _ = try h.f.pump(&read, server.db);
        const binding = (try read.binding(.{ .identity = .{ .owner = value.owner, .slot = slot } })).?;
        break :endpoint try records.EndpointRecord.decode((try h.c.storage.Read.rowFor(store, binding)).?.view);
    };
    var name: d.f.captures.CapturedString = .{};
    try wire.send(client, pair, target, "durable-name", &.{}, &name);
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    const pub_lease = try h.c.load(store, server.db, receipt_endpoint.publication.?);
    const secret = (try store.currentView(pub_lease)).payload[0..16].*;
    try store.release(pub_lease);
    const descriptor_lease = try h.c.load(store, server.db, receipt_endpoint.descriptor);
    var descriptor: records.CapabilityRecord = undefined;
    try descriptor.decodeOwned(store.allocator, try store.currentView(descriptor_lease));
    defer descriptor.deinit(store.allocator);
    try store.release(descriptor_lease);
    var bytes: [32]u8 = undefined;
    @memcpy(bytes[0..16], &witness_name);
    @memcpy(bytes[16..32], &secret);
    try store.begin();
    const id = try store.allocateId();
    try store.putCopying(.{ .id = id, .revision = 0, .schema = schema.id, .rooted = true, .payload = &bytes }, null);
    try h.f.commit(store, server.db);
    _ = try h.f.change(store, server.db, owner_id, .{ .revoke = descriptor.grant });
    var progress = try native.change(store, server.db, owner_id, .sweep, 0);
    // Stop immediately before the terminal endpoint/publication batch. Earlier status-allow: event or source ordering
    // weak members and its descriptor have already advanced persisted progress.
    for (0..64) |_| {
        const step = try h.c.storage.Maintenance.init(store.allocator, store, owner_id, .step, progress.sequence, 8);
        defer step.deinit() catch unreachable;
        _ = try h.f.pump(step, server.db);
        for (try step.publications()) |publication_id| if (publication_id != null) return;
        progress = try native.change(store, server.db, owner_id, .step, progress.sequence);
    }
    return error.MissingTerminalStep;
}

pub fn sequence(server: anytype) !u64 {
    return (try header(server)).maintenance.sequence;
}
pub fn verify(server: anytype, client: *h.driver.Host, pair: pairs.Pair, use: model.Reference, cleanup: bool, committed: bool) !void {
    const store = server.caps.store;
    const admin = try wire.fetch(server, client, pair, admin_name);
    const before = try header(server);
    const expected_lifecycle: @FieldType(records.OwnerRecord, "lifecycle") = if (committed) .retiring else .active;
    if (!cleanup and (before.lifecycle != expected_lifecycle or before.maintenance.sequence != @intFromBool(committed))) return error.NonAtomicOwnerClosure;
    if (cleanup) {
        const child = try wire.fetchCapture(server, client, pair, try witness(server));
        if (child.broken != committed) return error.NonAtomicPublicationRetirement;
    }
    const revision = store.metadata.revision;
    const old_sequence = before.maintenance.sequence - @as(u64, @intFromBool(committed));
    var memory = std.heap.ArenaAllocator.init(store.allocator);
    defer memory.deinit();
    var retry: d.Capture = .{ .arena = memory.allocator() };
    try wire.send(client, pair, admin, if (cleanup) "maintenance-step" else "retire-owner", &.{.{ .integer = @intCast(old_sequence) }}, &retry);
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    const retried = try retry.require();
    if (retried.tagged.value[3].boolean != committed or store.metadata.revision != revision + @intFromBool(!committed)) return error.RepeatedMaintenanceEffect;
    for (0..128) |_| {
        const current = try header(server);
        if (current.maintenance.phase == .idle) break;
        var next: d.Capture = .{ .arena = memory.allocator() };
        try wire.send(client, pair, admin, "maintenance-step", &.{.{ .integer = @intCast(current.maintenance.sequence) }}, &next);
        try server.drain();
        try pairs.pumpToQuiescence(&.{pair});
        _ = try next.require();
    } else return error.NoProgress;
    if (cleanup) {
        const child = try wire.fetchCapture(server, client, pair, try witness(server));
        if (!child.broken) return error.RetiredNameRestored;
        var denied: d.f.captures.CapturedRef = .{};
        const unchanged = store.metadata.revision;
        try wire.send(client, pair, use, "derive", &.{ .{ .integer = 1 }, .{ .integer = 0 }, .{ .integer = 0 } }, &denied);
        try server.drain();
        try pairs.pumpToQuiescence(&.{pair});
        if (!denied.broken or store.metadata.revision != unchanged) return error.TerminalRetryReminted;
        var fresh: d.f.captures.CapturedRef = .{};
        try wire.send(client, pair, use, "derive", &.{ .{ .integer = 2 }, .{ .integer = 0 }, .{ .integer = 0 } }, &fresh);
        try server.drain();
        try pairs.pumpToQuiescence(&.{pair});
        _ = try fresh.require();
    } else {
        const final = try header(server);
        if (final.lifecycle != .retired or final.next_grant != 1 or final.next_resource != 1 or final.next_identity != 6) return error.ResurrectedOwner;
        var refused: h.Answer = .{};
        try wire.send(client, pair, use, "get", &.{}, &refused);
        try server.drain();
        try pairs.pumpToQuiescence(&.{pair});
        if (!refused.broken) return error.RetiredAuthorityAdmitted;
    }
}
