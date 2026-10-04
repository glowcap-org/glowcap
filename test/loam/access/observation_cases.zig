//! Scoped observation uses held source authority and committed storage effects.
const std = @import("std");
const h = @import("hosting_fixture.zig");
const f = h.f;
const c = h.c;
const storage = f.storage;

pub fn register(caps: *storage.Capabilities, backend: anytype, descriptor: f.loam.core.ObjectId, target: ?f.core.ResourceId, key: [32]u8) !f.loam.core.ObjectId {
    const operation = if (target != null) blk: {
        const use = try c.use(caps, backend, descriptor);
        defer use.release();
        break :blk try use.begin(8);
    } else blk: {
        const control = try c.control(caps, backend, descriptor);
        defer control.release();
        break :blk try control.begin(8);
    };
    defer operation.deinit() catch unreachable;
    _ = try f.pump(operation, backend);
    const registration = for (0..128) |_| {
        const value = storage.ObservationRegistration.init(operation, target, key) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try f.pump(operation, backend);
            continue;
        };
        break value;
    } else return error.NoProgress;
    defer registration.deinit() catch unreachable;
    _ = try f.pump(registration, backend);
    try caps.store.begin();
    errdefer if (caps.store.phase == .staging) caps.store.abort() catch unreachable;
    const id = try registration.stage(@splat(null));
    try f.commit(caps.store, backend);
    return id;
}

pub fn poll(caps: *storage.Capabilities, backend: anytype, id: f.loam.core.ObjectId, cursor: ?storage.Observation.Cursor) !storage.Observation.Result {
    const lease = try c.load(caps.store, backend, id);
    const operation = storage.Observation.init(caps, lease, cursor, 8) catch |err| {
        try caps.store.release(lease);
        return err;
    };
    try caps.store.release(lease);
    defer operation.deinit() catch unreachable;
    _ = try f.pump(operation, backend);
    return operation.result();
}

pub fn scoped(store: *f.loam.core.Store, backend: anytype) !void {
    const data = try h.seed(store, backend);
    var caps = try storage.Capabilities.init(store.allocator, store, .{});
    defer caps.deinit() catch unreachable;
    const endpoint_lease = try c.load(store, backend, data.use);
    const endpoint = try f.loam.access.records.EndpointRecord.decode(try store.currentView(endpoint_lease));
    try store.release(endpoint_lease);
    const observed = try register(&caps, backend, endpoint.descriptor, data.resource, @splat(42));
    const first = try poll(&caps, backend, observed, null);
    try std.testing.expect(first.snapshot.use.access == .active);
    const second_context = try register(&caps, backend, endpoint.descriptor, data.resource, @splat(42));
    try std.testing.expectError(error.InvalidCursor, poll(&caps, backend, second_context, first.cursor));
    var corrupt = first.cursor;
    corrupt[0] ^= 1;
    try std.testing.expectError(error.InvalidCursor, poll(&caps, backend, observed, corrupt));
    for (0..40) |_| _ = try f.resource(store, backend, data.owner, null);
    const hidden = try poll(&caps, backend, observed, first.cursor);
    try std.testing.expect(!hidden.changed and !hidden.resync);
    try std.testing.expectEqualDeep(first.cursor, hidden.cursor);
    const fresh = try poll(&caps, backend, observed, null);
    try std.testing.expectEqualDeep(first.cursor, fresh.cursor);
    _ = try f.change(store, backend, data.owner, .{ .pause = data.grant });
    _ = try f.change(store, backend, data.owner, .{ .resume_access = data.grant });
    const reversal = try poll(&caps, backend, observed, hidden.cursor);
    try std.testing.expect(reversal.changed and reversal.resync);
    try std.testing.expect(reversal.snapshot.use.access == .active);
    for (0..4) |_| _ = try f.resource(store, backend, data.owner, null);
    const fresh_after_change = try poll(&caps, backend, observed, null);
    try std.testing.expectEqualDeep(reversal.cursor, fresh_after_change.cursor);
    _ = try f.change(store, backend, data.owner, .{ .pause = data.grant });
    const paused = try poll(&caps, backend, observed, reversal.cursor);
    try std.testing.expect(paused.changed and !paused.resync and paused.notices.access);
    try std.testing.expect(paused.snapshot.use.access == .paused and !paused.notices.target);
    const narrower = try f.vocabulary.terms(.{ .object = data.resource }, &.{f.vocabulary.read}, null);
    _ = try f.change(store, backend, data.owner, .{ .set_policy = .{ .grant = data.grant, .terms = narrower } });
    const hidden_policy = try poll(&caps, backend, observed, paused.cursor);
    try std.testing.expect(!hidden_policy.changed and !hidden_policy.resync);
    try std.testing.expectEqualDeep(paused.cursor, hidden_policy.cursor);
    _ = try f.change(store, backend, data.owner, .{ .revoke = data.grant });
    const revoked = try poll(&caps, backend, observed, paused.cursor);
    try std.testing.expect(revoked.snapshot.use.access == .revoked);
    try std.testing.expect(!revoked.notices.target and !revoked.notices.inventory);
}

pub fn cancel(store: *f.loam.core.Store, backend: anytype, id: f.loam.core.ObjectId, abort: bool) !bool {
    const lease = try c.load(store, backend, id);
    const operation = storage.ObservationCancellation.init(store, lease) catch |err| {
        try store.release(lease);
        return err;
    };
    try store.release(lease);
    defer operation.deinit() catch unreachable;
    _ = try f.pump(operation, backend);
    try store.begin();
    errdefer if (store.phase == .staging) store.abort() catch unreachable;
    const changed = try operation.stage(null);
    if (abort or !changed) try store.abort() else try f.commit(store, backend);
    return changed;
}

pub fn quota(store: *f.loam.core.Store, backend: anytype) !void {
    const data = try h.seed(store, backend);
    var caps = try storage.Capabilities.init(store.allocator, store, .{});
    defer caps.deinit() catch unreachable;
    const lease = try c.load(store, backend, data.use);
    const endpoint = try f.loam.access.records.EndpointRecord.decode(try store.currentView(lease));
    try store.release(lease);
    var ids: [f.loam.access.records.ObservationIndexRecord.capacity]f.loam.core.ObjectId = undefined;
    for (&ids, 0..) |*id, index| id.* = try register(&caps, backend, endpoint.descriptor, data.resource, @splat(@intCast(index + 1)));
    const revision = store.metadata.revision;
    try std.testing.expectError(error.ObservationCapacity, register(&caps, backend, endpoint.descriptor, data.resource, @splat(99)));
    try std.testing.expectEqual(revision, store.metadata.revision);
    try std.testing.expect(try cancel(store, backend, ids[0], true));
    try std.testing.expectEqual(revision, store.metadata.revision);
    try std.testing.expectError(error.ObservationCapacity, register(&caps, backend, endpoint.descriptor, data.resource, @splat(99)));
    try std.testing.expect(try cancel(store, backend, ids[0], false));
    const closed_revision = store.metadata.revision;
    try std.testing.expect(!try cancel(store, backend, ids[0], false));
    try std.testing.expectEqual(closed_revision, store.metadata.revision);
    try std.testing.expectError(error.ObservationClosed, poll(&caps, backend, ids[0], null));
    const closed = try c.load(store, backend, ids[0]);
    try std.testing.expectEqual(@as(u32, 0), (try store.currentView(closed)).edge_count);
    try store.release(closed);
    _ = try register(&caps, backend, endpoint.descriptor, data.resource, @splat(100));
    try std.testing.expectEqual(@as(usize, 0), caps.operations);
    try std.testing.expectEqual(@as(usize, 0), caps.observations);
}

pub fn submitted(store: *f.loam.core.Store, backend: anytype) !void {
    const data = try h.seed(store, backend);
    var caps = try storage.Capabilities.init(store.allocator, store, .{});
    defer caps.deinit() catch unreachable;
    const endpoint_lease = try c.load(store, backend, data.use);
    const endpoint = try f.loam.access.records.EndpointRecord.decode(try store.currentView(endpoint_lease));
    try store.release(endpoint_lease);
    const context = try register(&caps, backend, endpoint.descriptor, data.resource, @splat(77));
    const lease = try c.load(store, backend, context);
    const observation = try storage.Observation.init(&caps, lease, null, 8);
    try store.release(lease);
    store.evict();
    const request = (try observation.advance()).read;
    try std.testing.expect(try observation.advance() == .waiting);
    try std.testing.expectError(error.Busy, observation.deinit());
    var wrong = request.ticket;
    wrong.sequence += 1;
    try std.testing.expectError(error.StaleCompletion, observation.completeRead(wrong, .missing));
    try observation.cancel();
    try std.testing.expectError(error.Busy, observation.deinit());
    try std.testing.expectError(error.Canceled, observation.completeRead(request.ticket, backend.read(request)));
    try observation.deinit();
    const closing_lease = try c.load(store, backend, context);
    const closing = try storage.ObservationCancellation.init(store, closing_lease);
    try store.release(closing_lease);
    store.evict();
    const closing_read = (try closing.advance()).read;
    try std.testing.expectError(error.Busy, closing.deinit());
    try closing.cancel();
    try std.testing.expectError(error.Busy, closing.deinit());
    try std.testing.expectError(error.Canceled, closing.completeRead(closing_read.ticket, backend.read(closing_read)));
    try closing.deinit();
    const current_lease = try c.load(store, backend, context);
    const current = try storage.Observation.init(&caps, current_lease, null, 8);
    try store.release(current_lease);
    defer current.deinit() catch unreachable;
    _ = try f.pump(current, backend);
    _ = try f.change(store, backend, data.owner, .{ .pause = data.grant });
    try std.testing.expectError(error.RevisionConflict, current.result());
    try std.testing.expectError(error.RevisionConflict, current.advance());
}

pub fn allocation(allocator: std.mem.Allocator) !void {
    var fixture = try f.Fixture.init(allocator, h.limits);
    defer fixture.deinit();
    const store = &fixture.store;
    const backend = &fixture.backend;
    const data = try h.seed(store, backend);
    var caps = try storage.Capabilities.init(allocator, store, .{});
    defer caps.deinit() catch unreachable;
    const lease = try c.load(store, backend, data.use);
    const endpoint = try f.loam.access.records.EndpointRecord.decode(try store.currentView(lease));
    try store.release(lease);
    const context = try register(&caps, backend, endpoint.descriptor, data.resource, @splat(18));
    const first = try poll(&caps, backend, context, null);
    _ = try f.change(store, backend, data.owner, .{ .pause = data.grant });
    _ = try poll(&caps, backend, context, first.cursor);
    _ = try cancel(store, backend, context, false);
}

pub fn controlInventory(store: *f.loam.core.Store, backend: anytype) !void {
    const management = @import("management_fixture.zig");
    const data = try h.seedDepth(store, backend, 1);
    var caps = try storage.Capabilities.init(store.allocator, store, .{});
    defer caps.deinit() catch unreachable;
    const control_lease = try c.load(store, backend, data.control);
    const endpoint = try f.loam.access.records.EndpointRecord.decode(try store.currentView(control_lease));
    try store.release(control_lease);
    const root_control = try c.control(&caps, backend, endpoint.descriptor);
    defer root_control.release();
    const child_descriptor = try management.attenuation(&caps, backend, root_control, .{ .pause = true });
    const child_control = try c.control(&caps, backend, child_descriptor);
    defer child_control.release();
    const context = try register(&caps, backend, child_descriptor, null, @splat(87));
    const first = try poll(&caps, backend, context, null);
    try std.testing.expect(first.snapshot.control.available);
    const terms = try f.vocabulary.terms(.{ .object = data.resource }, &.{f.vocabulary.read}, null);
    _ = try f.change(store, backend, data.owner, .{ .issue_root = f.vocabulary.issue(terms, 0) });
    const unrelated = try poll(&caps, backend, context, first.cursor);
    try std.testing.expect(!unrelated.changed);
    const child = (try f.change(store, backend, data.owner, .{ .derive = .{ .parent = data.grant, .request = f.vocabulary.issue(terms, 0) } })).?;
    const inventory = try poll(&caps, backend, context, first.cursor);
    try std.testing.expect(inventory.changed and inventory.notices.inventory and !inventory.notices.target);
    const use_descriptor = try c.descriptor(&caps, backend, data.owner, child.grant, null, false);
    const use_context = try register(&caps, backend, use_descriptor, data.resource, @splat(88));
    const use_first = try poll(&caps, backend, use_context, null);
    try management.revoke(&caps, backend, root_control);
    const unavailable = try poll(&caps, backend, context, inventory.cursor);
    try std.testing.expect(unavailable.changed and unavailable.notices.management);
    try std.testing.expect(!unavailable.snapshot.control.available and !unavailable.notices.inventory);
    _ = try f.change(store, backend, data.owner, .{ .pause = data.grant });
    const hidden_status = try poll(&caps, backend, context, unavailable.cursor);
    try std.testing.expect(!hidden_status.changed);
    try std.testing.expectEqualDeep(unavailable.cursor, hidden_status.cursor);
    _ = try f.change(store, backend, data.owner, .{ .revoke = data.grant });
    const revoked = try poll(&caps, backend, use_context, use_first.cursor);
    try std.testing.expect(revoked.changed and revoked.snapshot.use.access == .revoked);
    try std.testing.expect(!revoked.notices.inventory and !revoked.notices.target);
}

pub fn composed(store: *f.loam.core.Store, backend: anytype) !void {
    const data = try h.seed(store, backend);
    var caps = try storage.Capabilities.init(store.allocator, store, .{});
    defer caps.deinit() catch unreachable;
    const lease = try c.load(store, backend, data.use);
    const endpoint = try f.loam.access.records.EndpointRecord.decode(try store.currentView(lease));
    try store.release(lease);
    const held = try c.use(&caps, backend, endpoint.descriptor);
    defer held.release();
    var sources: [2]*storage.Operation = undefined;
    var registrations: [2]*storage.ObservationRegistration = undefined;
    var count: usize = 0;
    defer for (0..count) |index| {
        registrations[index].deinit() catch unreachable;
        sources[index].deinit() catch unreachable;
    };
    for (&sources, &registrations, 0..) |*source, *registration, index| {
        source.* = try held.begin(8);
        errdefer if (count <= index) source.*.deinit() catch unreachable;
        _ = try f.pump(source.*, backend);
        registration.* = for (0..128) |_| {
            const registration_value = storage.ObservationRegistration.init(source.*, data.resource, @splat(@intCast(index + 1))) catch |err| {
                if (err != error.RecordUnloaded) return err;
                _ = try f.pump(source.*, backend);
                continue;
            };
            break registration_value;
        } else return error.NoProgress;
        count += 1;
        _ = try f.pump(registration.*, backend);
    }
    var read = try storage.Read.init(store.allocator, store, data.owner, 8);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    try f.require(&read, backend, data.grant, data.resource, .{ .permissions = &.{} });
    for (0..128) |_| {
        read.prepareHistory() catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try f.pump(&read, backend);
            continue;
        };
        break;
    } else return error.NoProgress;
    try store.begin();
    errdefer if (store.phase == .staging) store.abort() catch unreachable;
    const first = try registrations[0].stage(@splat(null));
    const second = try registrations[1].stage(@splat(null));
    try storage.stage.contentChanged(&read, data.resource);
    try f.commit(store, backend);
    const owner_lease = try c.load(store, backend, data.owner);
    const header = try f.loam.access.records.OwnerRecord.decode(try store.currentView(owner_lease));
    try store.release(owner_lease);
    const index_lease = try c.load(store, backend, header.observations orelse return error.LostObservationIndex);
    const index = try f.loam.access.records.ObservationIndexRecord.decode(try store.currentView(index_lease));
    try store.release(index_lease);
    try std.testing.expectEqual(@as(usize, 2), index.count);
    try std.testing.expect(index.contexts[0].eql(first) and index.contexts[1].eql(second));
}
