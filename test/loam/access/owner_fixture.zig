//! Common owner operations for portable and native persistence tests.
const std = @import("std");
pub const glowcap = @import("glowcap");
pub const loam = glowcap.loam;
pub const core = loam.access.core;
pub const storage = loam.access.storage;
pub const a = std.testing.allocator;
pub const vocabulary = @import("grant_fixture.zig");
pub const schemas = loam.access.records.profile.schemas ++ [_]loam.core.Schema{.{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 }};
pub const limits: loam.core.Store.Limits = .{
    .records = .{ .max_record_bytes = 64 * 1024, .max_edges = 514 },
    .cache_slots = 8,
    .max_leases = 8,
    .resident_bytes = 512 * 1024,
    .max_changes = 16,
    .staging_bytes = 256 * 1024,
};
pub const store_id: loam.core.StoreId = @fromBackingInt(92);

pub fn commit(store: *loam.core.Store, backend: anytype) !void {
    const ticket = try store.prepare();
    const outcome = backend.commit(try store.beginWrite(ticket));
    try store.completeWrite(ticket, outcome);
    switch (outcome) {
        .committed => {},
        .unchanged => |err| return err,
        .unknown => return error.OutcomeUnknown,
    }
}

pub fn pump(operation: anytype, backend: anytype) !usize {
    var reads: usize = 0;
    for (0..512) |_| switch (try operation.advance()) {
        .ready => return reads,
        .read => |request| {
            reads += 1;
            try operation.completeRead(request.ticket, backend.read(request));
        },
        .waiting => return error.UnexpectedWait,
    };
    return error.NoProgress;
}

pub fn create(store: *loam.core.Store, backend: anytype, owner: core.OwnerId) !loam.core.ObjectId {
    const policy = try core.Policy.init(vocabulary.descriptor);
    try store.begin();
    errdefer if (store.phase == .staging or store.phase == .prepared) store.abort() catch unreachable;
    const object = try storage.stage.createOwner(store, owner, policy, .{});
    try commit(store, backend);
    return object;
}

pub fn resource(store: *loam.core.Store, backend: anytype, owner: loam.core.ObjectId, parent: ?core.ResourceId) !core.ResourceId {
    var read = try storage.Read.init(a, store, owner, @min(6, store.limits.max_leases -| 1));
    defer read.deinit() catch unreachable;
    _ = try pump(&read, backend);
    var append = try storage.Append.init(&read, .resource);
    defer append.deinit() catch unreachable;
    _ = try pump(&append, backend);
    try store.begin();
    errdefer if (store.phase == .staging or store.phase == .prepared) store.abort() catch unreachable;
    for (0..128) |_| {
        const id = storage.stage.appendResource(&append, vocabulary.kind, parent) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try pump(&read, backend);
            continue;
        };
        try commit(store, backend);
        return id;
    }
    return error.NoProgress;
}

pub fn prepare(read: *storage.Read, backend: anytype, command: core.GrantPlan.Command) !?core.GrantPlan {
    for (0..128) |_| {
        var grants = try read.grantView();
        var resources = try read.resourceView();
        const fresh: ?core.GrantId = if (read.header.next_grant < loam.access.records.OwnerRecord.max_slots) .{ .owner = read.header.owner, .slot = @intCast(read.header.next_grant), .generation = 1 } else null;
        const plan = core.GrantPlan.prepareCopying(a, &grants, &resources, &read.header.policy, read.header.max_grant_children, fresh, command) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try pump(read, backend);
            continue;
        };
        return plan;
    }
    return error.NoProgress;
}

pub fn change(store: *loam.core.Store, backend: anytype, owner: loam.core.ObjectId, command: core.GrantPlan.Command) !?core.GrantPlan.Change {
    var read = try storage.Read.init(a, store, owner, @min(6, store.limits.max_leases -| 1));
    defer read.deinit() catch unreachable;
    _ = try pump(&read, backend);
    var plan = (try prepare(&read, backend, command)) orelse return null;
    defer plan.deinit(a);
    var append: ?storage.Append = null;
    defer if (append) |*path| path.deinit() catch unreachable;
    if (plan.delta == .issue) {
        append = try storage.Append.init(&read, .grant);
        _ = try pump(&append.?, backend);
    }
    try store.begin();
    errdefer if (store.phase == .staging or store.phase == .prepared) store.abort() catch unreachable;
    const event = try storage.stage.grant(&read, &plan, if (append) |*path| path else null);
    try commit(store, backend);
    return event.change;
}

pub fn require(read: *storage.Read, backend: anytype, grant: core.GrantId, target: core.ResourceId, requirement: core.Policy.Requirement) !void {
    for (0..128) |_| {
        var grants = try read.grantView();
        var resources = try read.resourceView();
        grants.require(&resources, &read.header.policy, grant, target, requirement) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try pump(read, backend);
            continue;
        };
        return;
    }
    return error.NoProgress;
}

pub const Fixture = struct {
    backend: loam.Volatile,
    store: loam.core.Store,

    pub fn init(allocator: std.mem.Allocator, options: loam.core.Store.Limits) !Fixture {
        var backend = try loam.Volatile.init(allocator, store_id, 16 * 1024 * 1024);
        errdefer backend.deinit();
        const store = try loam.core.Store.init(allocator, try backend.open(), &schemas, options);
        return .{ .backend = backend, .store = store };
    }

    pub fn deinit(self: *Fixture) void {
        if (self.store.phase == .staging or self.store.phase == .prepared) self.store.abort() catch unreachable;
        self.store.deinit() catch unreachable;
        self.backend.close();
        self.backend.deinit();
    }
};
