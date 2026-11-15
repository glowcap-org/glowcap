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

pub fn descriptor(caps: *storage.Capabilities, backend: anytype, owner: f.loam.core.ObjectId, grant: core.GrantId, powers: ?core.Control.Powers, rooting: storage.Rooting) !f.loam.core.ObjectId {
    var read: storage.Read = undefined;
    try read.init(caps.allocator, caps.store, owner, 4, null);
    defer read.deinit() catch unreachable;
    _ = try f.pump(&read, backend);
    try caps.store.begin();
    errdefer if (caps.store.phase == .staging) caps.store.abort() catch unreachable;
    const id = if (powers) |value|
        try f.loaded(&read, backend, storage.Capabilities.stageControl, .{ caps, &read, grant, value, rooting })
    else
        try f.loaded(&read, backend, storage.Capabilities.stageUse, .{ caps, &read, grant, rooting });
    try f.commit(caps.store, backend);
    return id;
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
    try f.loaded(operation, backend, storage.Operation.require, .{ operation, target, requirement });
}
pub fn edit(operation: *storage.Operation, backend: anytype, value: core.Control.Edit) !bool {
    return f.loaded(operation, backend, storage.Operation.prepareEditCopying, .{ operation, value });
}
pub fn derive(operation: *storage.Operation, backend: anytype, request: core.GrantLedger.Issue) !void {
    try f.loaded(operation, backend, storage.Operation.prepareDeriveCopying, .{ operation, request });
    _ = try f.pump(operation, backend);
}
