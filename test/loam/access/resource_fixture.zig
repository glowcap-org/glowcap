//! Shared resource lifecycle proof helpers use ordinary Store and managed APIs.
const std = @import("std");
pub const h = @import("hosting_fixture.zig");
pub const f = h.f;
pub const core = f.core;
pub const storage = f.storage;
pub const a = h.a;

pub fn prepare(read: *storage.Read, backend: anytype, target: core.ResourceId, action: storage.ResourceChange.Action) !storage.ResourceChange {
    for (0..128) |_| {
        return storage.ResourceChange.init(read, target, action) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try f.pump(read, backend);
            continue;
        };
    }
    return error.NoProgress;
}

pub fn pump(operation: anytype, backend: anytype) !usize {
    var reads: usize = 0;
    for (0..8192) |_| switch (try operation.advance()) {
        .ready => return reads,
        .waiting => {},
        .read => |request| {
            reads += 1;
            try operation.completeRead(request.ticket, backend.read(request));
        },
    };
    return error.NoProgress;
}

pub fn change(store: *h.loam.core.Store, backend: anytype, owner: h.loam.core.ObjectId, target: core.ResourceId, action: storage.ResourceChange.Action) !bool {
    var read: storage.Read = undefined;
    try read.init(store.allocator, store, owner, @min(6, store.limits.max_leases -| 1), null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    var edit = try prepare(&read, backend, target, action);
    defer edit.deinit() catch unreachable;
    _ = try pump(&edit, backend);
    try store.begin();
    errdefer if (store.phase == .staging or store.phase == .prepared) store.abort() catch unreachable;
    const changed = try edit.stage();
    try f.commit(store, backend);
    return changed;
}

pub fn children(caps: *storage.Capabilities, backend: anytype, use_id: h.loam.core.ObjectId, parent: core.ResourceId, expected: []const core.ResourceId) !void {
    const lease = try h.c.load(caps.store, backend, use_id);
    const use = try caps.restoreUse(lease);
    try caps.store.release(lease);
    defer use.release();
    const operation = try use.begin(6);
    defer operation.deinit() catch unreachable;
    _ = try pump(operation, backend);
    var cursor: ?*storage.Children = null;
    for (0..128) |_| {
        cursor = operation.children(parent, .{ .permissions = &.{f.vocabulary.read} }) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try pump(operation, backend);
            continue;
        };
        break;
    }
    const query = cursor orelse return error.NoProgress;
    defer query.deinit() catch unreachable;
    try std.testing.expectError(error.Busy, operation.deinit());
    var count: usize = 0;
    for (0..8192) |_| switch (try query.advance()) {
        .read => |request| try query.completeRead(request.ticket, backend.read(request)),
        .waiting => {},
        .done => {
            try std.testing.expectEqual(expected.len, count);
            return;
        },
        .item => |id| {
            try std.testing.expect(count < expected.len);
            try std.testing.expect(id.eql(expected[count]));
            count += 1;
        },
    };
    return error.NoProgress;
}

pub fn seed(store: *h.loam.core.Store, backend: anytype) !struct { data: h.Data, root: core.ResourceId, other: core.ResourceId, leaf: core.ResourceId } {
    const owner = try f.create(store, backend, @fromBackingInt(81));
    const root = try f.resource(store, backend, owner, null);
    const other = try f.resource(store, backend, owner, null);
    const leaf = try f.resource(store, backend, owner, root);
    const policy = try core.Policy.init(f.vocabulary.descriptor);
    const terms: core.Terms = .{ .scope = .{ .owned_subtree = root }, .policy = try policy.value(&.{ f.vocabulary.read, f.vocabulary.post }, &.{}) };
    const grant = (try f.change(store, backend, owner, .{ .issue_root = f.vocabulary.issue(terms, 2) })).?.grant;
    var caps = try storage.Capabilities.init(store.allocator, store, .{});
    defer caps.deinit() catch unreachable;
    const use_descriptor = try h.c.descriptor(&caps, backend, owner, grant, null, .reachable);
    const control_descriptor = try h.c.descriptor(&caps, backend, owner, grant, .{ .pause = true, .resume_access = true, .revoke = true, .policy_ceiling = terms }, .reachable);
    var endpoint_owner: storage.Read = undefined;
    try endpoint_owner.init(store.allocator, store, owner, 1, null);
    defer endpoint_owner.deinit() catch unreachable;
    try h.prepareEndpointOwner(&endpoint_owner, backend, 2);
    const use_lease = try h.c.load(store, backend, use_descriptor);
    defer store.release(use_lease) catch unreachable;
    const control_lease = try h.c.load(store, backend, control_descriptor);
    defer store.release(control_lease) catch unreachable;
    try store.begin();
    const content = try store.allocateId();
    try store.putCopying(.{ .id = content, .revision = 0, .schema = 7, .payload = &@as([8]u8, @splat(0)) }, null);
    const use = try h.access.stageEndpoint(&endpoint_owner, store.allocator, .{ .descriptor = use_descriptor, .content = .{ .resource = leaf, .object = content } }, .rooted);
    const control = try h.access.stageEndpoint(&endpoint_owner, store.allocator, .{ .descriptor = control_descriptor }, .rooted);
    try f.commit(store, backend);
    return .{ .data = .{ .owner = owner, .resource = leaf, .grant = grant, .content = content, .use = use, .control = control }, .root = root, .other = other, .leaf = leaf };
}
