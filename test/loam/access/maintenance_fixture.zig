//! Shared bounded native maintenance driver.
const h = @import("hosting_fixture.zig");
const f = h.f;
const storage = h.c.storage;

pub fn change(store: *f.loam.core.Store, backend: anytype, owner: f.loam.core.ObjectId, command: storage.Maintenance.Command, sequence: u64) !storage.Maintenance.Result {
    const operation = try storage.Maintenance.init(store.allocator, store, owner, command, sequence, 4);
    defer operation.deinit() catch unreachable;
    _ = try f.pump(operation, backend);
    const result = try operation.result();
    try store.begin();
    errdefer if (store.phase == .staging or store.phase == .prepared) store.abort() catch unreachable;
    if (try operation.stage(null)) try f.commit(store, backend) else try store.abort();
    return result;
}

pub fn finish(store: *f.loam.core.Store, backend: anytype, owner: f.loam.core.ObjectId, command: storage.Maintenance.Command, sequence: u64) !storage.Maintenance.Result {
    var result = try change(store, backend, owner, command, sequence);
    for (0..128) |_| {
        if (result.phase == .idle) return result;
        result = try change(store, backend, owner, .step, result.sequence);
    }
    return error.NoProgress;
}
