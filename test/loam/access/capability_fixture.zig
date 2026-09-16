//! Durable capability scenarios use the same operation driver on both backends.
const std = @import("std");
pub const f = @import("owner_fixture.zig");
pub const storage = f.storage;
pub const core = f.core;
pub const a = std.testing.allocator;

pub fn load(store: *f.loam.core.Store, backend: anytype, id: f.loam.core.ObjectId) !f.loam.core.Lease {
    return switch (try store.acquire(id)) {
        .ready => |lease| lease,
        .read => |request| blk: {
            try store.completeRead(request.ticket, backend.read(request));
            break :blk (try store.acquire(id)).ready;
        },
    };
}

pub fn descriptor(caps: *storage.Capabilities, backend: anytype, owner: f.loam.core.ObjectId, grant: core.GrantId, powers: ?core.Control.Powers, rooted: bool) !f.loam.core.ObjectId {
    var read = try storage.Read.init(a, caps.store, owner, 4);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    try caps.store.begin();
    errdefer if (caps.store.phase == .staging) caps.store.abort() catch unreachable;
    for (0..128) |_| {
        const result = if (powers) |value| caps.stageControl(&read, grant, value, rooted) else caps.stageUse(&read, grant, rooted);
        const id = result catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try f.pump(&read, backend);
            continue;
        };
        try f.commit(caps.store, backend);
        return id;
    }
    return error.NoProgress;
}

pub fn use(caps: *storage.Capabilities, backend: anytype, id: f.loam.core.ObjectId) !*storage.Use {
    const lease = try load(caps.store, backend, id);
    defer caps.store.release(lease) catch unreachable;
    return caps.restoreUse(lease);
}
pub fn control(caps: *storage.Capabilities, backend: anytype, id: f.loam.core.ObjectId) !*storage.Control {
    const lease = try load(caps.store, backend, id);
    defer caps.store.release(lease) catch unreachable;
    return caps.restoreControl(lease);
}

pub fn require(operation: *storage.Operation, backend: anytype, target: core.ResourceId, requirement: core.Policy.Requirement) !void {
    for (0..128) |_| {
        operation.require(target, requirement) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try f.pump(operation, backend);
            continue;
        };
        return;
    }
    return error.NoProgress;
}
pub fn edit(operation: *storage.Operation, backend: anytype, value: core.Control.Edit) !bool {
    for (0..128) |_| {
        return operation.prepareEditCopying(value) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try f.pump(operation, backend);
            continue;
        };
    }
    return error.NoProgress;
}
pub fn derive(operation: *storage.Operation, backend: anytype, request: core.GrantLedger.Issue) !void {
    for (0..128) |_| {
        operation.prepareDeriveCopying(request) catch |err| {
            if (err != error.RecordUnloaded) return err;
            _ = try f.pump(operation, backend);
            continue;
        };
        _ = try f.pump(operation, backend);
        return;
    }
    return error.NoProgress;
}
