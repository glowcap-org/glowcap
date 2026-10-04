//! Named test witnesses retain public names and cursors across killed processes.
//! They hold no capability edges and do not preserve cancelled source authority.
const std = @import("std");
const fixture = @import("observation_fixture.zig");
const d = fixture.d;
const h = d.h;
const wire = @import("../../support/storage_host_pair.zig");
const pairs = @import("../../support/host_pair.zig");
const model = d.f.model;
const publication = h.loam.hosting.publication;
const core = h.loam.core;
const witness_name: publication.Entropy = @splat(0x91);
pub const schema: core.Schema = .{ .id = 8, .version = 1, .max_payload = 104, .max_edges = 0, .name_offset = 0 };

pub fn register(server: anytype, client: *h.driver.Host, pair: pairs.Pair, use: model.Reference, allocator: std.mem.Allocator) !fixture.Fronts {
    var memory = std.heap.ArenaAllocator.init(allocator);
    defer memory.deinit();
    var captured: d.Capture = .{ .arena = memory.allocator() };
    try wire.send(client, pair, use, "mutate", &.{ .{ .integer = 1 }, .{ .string = "observe" } }, &captured);
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    return fixture.Fronts.from(try captured.require());
}

pub fn names(server: anytype, owner: core.ObjectId) ![2]publication.Entropy {
    const store = server.caps.store;
    const owner_lease = try h.c.load(store, server.db, owner);
    const header = try h.loam.access.records.OwnerRecord.decode(try store.currentView(owner_lease));
    try store.release(owner_lease);
    const index_lease = try h.c.load(store, server.db, header.observations orelse return error.MissingObservation);
    const index = try h.loam.access.records.ObservationIndexRecord.decode(try store.currentView(index_lease));
    try store.release(index_lease);
    if (index.count != 1) return error.DuplicateObservation;
    const context_lease = try h.c.load(store, server.db, index.contexts[0]);
    const context = try h.loam.access.records.ObservationRecord.decode(try store.currentView(context_lease));
    try store.release(context_lease);
    var result: [2]publication.Entropy = undefined;
    for (context.publications, &result) |id, *bytes| {
        const lease = try h.c.load(store, server.db, id orelse return error.MissingPublication);
        const view = try store.currentView(lease);
        _ = try publication.activeTarget(view);
        bytes.* = view.payload[0..16].*;
        try store.release(lease);
    }
    return result;
}

pub fn createWitness(server: anytype, client: *h.driver.Host, pair: pairs.Pair, use: model.Reference, owner: core.ObjectId) !void {
    const store = server.caps.store;
    const fronts = try register(server, client, pair, use, store.allocator);
    const secrets = try names(server, owner);
    var memory = std.heap.ArenaAllocator.init(store.allocator);
    defer memory.deinit();
    var captured: d.Capture = .{ .arena = memory.allocator() };
    try wire.send(client, pair, fronts.receiver, "poll", &.{}, &captured);
    try server.drain();
    try pairs.pumpToQuiescence(&.{pair});
    const cursor = try fixture.cursor(try captured.require());
    var bytes: [104]u8 = undefined;
    @memcpy(bytes[0..16], &witness_name);
    @memcpy(bytes[16..32], &secrets[0]);
    @memcpy(bytes[32..48], &secrets[1]);
    @memcpy(bytes[48..104], &cursor);
    try store.begin();
    const id = try store.allocateId();
    try store.putCopying(.{ .id = id, .revision = 0, .schema = schema.id, .rooted = true, .payload = &bytes }, null);
    try h.f.commit(store, server.db);
}

fn witness(server: anytype) ![104]u8 {
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
    if (view.schema != schema.id or view.payload.len != 104) return error.InvalidWitness;
    return view.payload[0..104].*;
}

pub fn canceller(server: anytype, client: *h.driver.Host, pair: pairs.Pair) !model.Reference {
    const bytes = try witness(server);
    return wire.fetch(server, client, pair, bytes[32..48].*);
}

pub fn verify(server: anytype, client: *h.driver.Host, pair: pairs.Pair, use: model.Reference, owner: core.ObjectId, cancelling: bool, committed: bool) !void {
    const store = server.caps.store;
    var cold: ?model.Reference = null;
    if (cancelling) {
        const bytes = try witness(server);
        if (committed) {
            for ([_]publication.Entropy{ bytes[16..32].*, bytes[32..48].* }) |secret| {
                const retired = try wire.fetchCapture(server, client, pair, secret);
                if (!retired.broken or retired.ref != null) return error.RetiredObservationRestored;
            }
            const revision = store.metadata.revision;
            var denied: d.f.captures.CapturedRef = .{};
            try wire.send(client, pair, use, "mutate", &.{ .{ .integer = 1 }, .{ .string = "observe" } }, &denied);
            try server.drain();
            try pairs.pumpToQuiescence(&.{pair});
            if (!denied.broken or !std.mem.eql(u8, denied.reason_buf[0..denied.reason_len], "ObservationClosed")) return error.CancelledRetryReminted;
            if (store.metadata.revision != revision) return error.RepeatedEffect;
            return;
        }
        cold = try wire.fetch(server, client, pair, bytes[16..32].*);
        var memory = std.heap.ArenaAllocator.init(store.allocator);
        defer memory.deinit();
        var polled: d.Capture = .{ .arena = memory.allocator() };
        try wire.send(client, pair, cold.?, "poll", &.{.{ .bytes = bytes[48..104] }}, &polled);
        try server.drain();
        try pairs.pumpToQuiescence(&.{pair});
        const value = try polled.require();
        if (value.tagged.value[3].boolean or !std.mem.eql(u8, &(try fixture.cursor(value)), bytes[48..104])) return error.AbortedCancellationChanged;
    } else if (committed) {
        const secrets = try names(server, owner);
        cold = try wire.fetch(server, client, pair, secrets[0]);
        _ = try wire.fetch(server, client, pair, secrets[1]);
    }
    const revision = store.metadata.revision;
    const fronts = try register(server, client, pair, use, store.allocator);
    if (store.metadata.revision != revision + @intFromBool(!cancelling and !committed)) return error.DuplicateObservation;
    if (cold) |held| {
        const original = try client.liftCapability(pair.a, held);
        defer client.releaseCapability(original, 1) catch unreachable;
        const retried = try client.liftCapability(pair.a, fronts.receiver);
        defer client.releaseCapability(retried, 1) catch unreachable;
        if (!original.eql(retried)) return error.ChangedObservationAuthority;
    }
}
