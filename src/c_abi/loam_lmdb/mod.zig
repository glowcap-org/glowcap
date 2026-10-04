//! Optional LMDB execution companion. It creates no Host or actor runtime.
pub const std_options = @import("c_abi_shared").library_options;
const std = @import("std");
const c = @import("c_abi_loam");
const bridge = c.embedding;
const shared = @import("c_abi_shared");
const loam = @import("loam_core");
const Lmdb = @import("loam_lmdb").Lmdb;
const allocator = shared.library_allocator;
pub const GlowcapLoamLmdb = opaque {};
pub const symbols = @import("symbols.zig");
const Storage = struct { backend: Lmdb, store: *bridge.Store };
fn storage(raw: ?*GlowcapLoamLmdb) !*Storage {
    return @ptrCast(@alignCast(raw orelse return error.NullPointer));
}

pub fn glowcap_loam_lmdb_open(path: ?[*]const u8, path_len: usize, store_id: ?[*]const u8, create: u32, map_bytes: usize, schemas: ?[*]const c.GlowcapLoamSchema, schema_count: usize, limits: ?*const c.GlowcapLoamLimits, out_storage: ?*?*GlowcapLoamLmdb, out_store: ?*?*c.GlowcapLoamStore) callconv(.c) i32 {
    shared.lastErrorClear();
    const storage_slot = out_storage orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    storage_slot.* = null;
    const store_slot = out_store orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    store_slot.* = null;
    const id = store_id orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const bounds = limits orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (create > 1) return bridge.code(error.InvalidArgument);
    const path_slice = shared.sliceFromC(path, path_len) catch |err| return bridge.code(err);
    if (std.mem.indexOfScalar(u8, path_slice, 0) != null) return bridge.code(error.InvalidArgument);
    const declarations = bridge.slice(c.GlowcapLoamSchema, schemas, schema_count) catch |err| return bridge.code(err);
    bridge.Store.validateConfiguration(declarations, bounds.*) catch |err| return bridge.code(err);
    const owned_path = allocator.dupeSentinel(u8, path_slice, 0) catch |err| return bridge.code(err);
    defer allocator.free(owned_path);
    const owner = allocator.create(Storage) catch |err| return bridge.code(err);
    const identity: loam.StoreId = @fromBackingInt(std.mem.readInt(u128, id[0..16], .big));
    var backend = Lmdb.open(owned_path, .{ .mode = if (create == 1) .{ .create = identity } else .{ .open = identity }, .map_bytes = map_bytes }) catch |err| {
        allocator.destroy(owner);
        return bridge.code(err);
    };
    const store = bridge.Store.init(allocator, backend.metadata, declarations, bounds.*) catch |err| {
        backend.close() catch unreachable;
        allocator.destroy(owner);
        return bridge.code(err);
    };
    store.backend_owned = true;
    owner.* = .{ .backend = backend, .store = store };
    storage_slot.* = @ptrCast(owner);
    store_slot.* = @ptrCast(store);
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_lmdb_release(raw: ?*GlowcapLoamLmdb) callconv(.c) i32 {
    shared.lastErrorClear();
    if (raw == null) return shared.GLOWCAP_OK;
    const owner = storage(raw) catch |err| return bridge.code(err);
    owner.store.destroy() catch |err| return bridge.code(err);
    owner.backend.close() catch unreachable; // Synchronous execution has no surviving worker after Store teardown.
    allocator.destroy(owner);
    return shared.GLOWCAP_OK;
}
/// Execute on the embedding's storage executor. Join it before completing or
/// releasing the work on the Host thread. No Host or attachment is touched.
pub fn glowcap_loam_lmdb_work_run(raw: ?*GlowcapLoamLmdb, work_handle: ?*c.GlowcapLoamWork) callconv(.c) i32 {
    shared.lastErrorClear();
    const owner = storage(raw) catch |err| return bridge.code(err);
    const work = bridge.work(work_handle) catch |err| return bridge.code(err);
    if (work.owner.store != owner.store or work.completed or work.result != null) return bridge.code(error.StaleCompletion);
    work.result = switch (work.request) {
        .read => |request| .{ .read = owner.backend.read(request) },
        .write => |request| .{ .write = owner.backend.commit(request) },
        .lookup => |request| .{ .lookup = owner.backend.lookup(request) },
        .recover => |request| blk: {
            const resolution = owner.backend.recover(request) catch |err| break :blk .{ .failed = err };
            break :blk .{ .recover = resolution };
        },
    };
    return shared.GLOWCAP_OK;
}
/// Restore from trusted persisted metadata. The ordinary Store read checks the
/// full record before the attachment mints one held Host capability occurrence.
pub fn glowcap_loam_lmdb_restore(raw: ?*GlowcapLoamLmdb, attachment: ?*c.GlowcapLoamAttachment, object: ?*const c.GlowcapLoamObject, out_ref: ?*shared.GlowcapReference) callconv(.c) i32 {
    shared.lastErrorClear();
    const owner = storage(raw) catch |err| return bridge.code(err);
    const attached = bridge.attachment(attachment) catch |err| return bridge.code(err);
    const source = object orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    const target = out_ref orelse return shared.GLOWCAP_ERR_NULL_POINTER;
    if (attached.store != owner.store) return bridge.code(error.ForeignStore);
    attached.value.topLevel() catch |err| return bridge.code(err);
    const id = bridge.object(source.*) catch |err| return bridge.code(err);
    const lease = load(owner, id) catch |err| return bridge.code(err);
    defer owner.store.value.release(lease) catch unreachable;
    const ref = attached.value.restore(lease) catch |err| return bridge.code(err);
    target.* = .{ .id = ref.raw() };
    return shared.GLOWCAP_OK;
}
fn load(owner: *Storage, id: loam.ObjectId) !loam.Lease {
    return switch (try owner.store.value.acquire(id)) {
        .ready => |lease| lease,
        .read => |request| blk: {
            try owner.store.value.completeRead(request.ticket, owner.backend.read(request));
            break :blk (try owner.store.value.acquire(id)).ready;
        },
    };
}
pub fn glowcap_loam_lmdb_commit(raw: ?*GlowcapLoamLmdb) callconv(.c) i32 {
    shared.lastErrorClear();
    const owner = storage(raw) catch |err| return bridge.code(err);
    if (owner.store.attachments != 0) return bridge.code(error.Busy);
    const store = &owner.store.value;
    const ticket = store.prepare() catch |err| {
        if (store.phase == .staging or store.phase == .prepared) store.abort() catch unreachable;
        return bridge.code(err);
    };
    const batch = store.beginWrite(ticket) catch |err| return bridge.code(err);
    const outcome = owner.backend.commit(batch);
    store.completeWrite(ticket, outcome) catch |err| {
        if (store.phase == .uncertain) return bridge.code(error.RecoveryRequired);
        return bridge.code(err);
    };
    switch (outcome) {
        .committed => {},
        .unchanged => |err| {
            // Preserve the storage cause; the result family describes the
            // proven terminal outcome, not invalid application arguments.
            _ = bridge.code(err);
            return c.GLOWCAP_LOAM_ERR_UNCHANGED;
        },
        .unknown => return bridge.code(error.OutcomeUnknown),
    }
    return shared.GLOWCAP_OK;
}
pub fn glowcap_loam_lmdb_last_error(buf: ?[*]u8, len: usize) callconv(.c) usize {
    return shared.lastErrorRead(buf, len);
}

pub const contract_layouts = [_]shared.archive_contract.Layout{};
pub const GLOWCAP_LOAM_LMDB_ARCHIVE_FINGERPRINT = shared.archive_contract.fingerprint("glowcap_loam_lmdb", @This(), .{ &shared.contract_layouts, &contract_layouts });
pub fn glowcap_loam_lmdb_archive_fingerprint() callconv(.c) u64 {
    return GLOWCAP_LOAM_LMDB_ARCHIVE_FINGERPRINT;
}

/// Resolve unattached creation only after its commit worker has terminated.
pub fn glowcap_loam_lmdb_recover(raw: ?*GlowcapLoamLmdb) callconv(.c) i32 {
    shared.lastErrorClear();
    const owner = storage(raw) catch |err| return bridge.code(err);
    if (owner.store.attachments != 0) return bridge.code(error.Busy);
    const store = &owner.store.value;
    const batch = store.recoveryBatch() catch |err| return bridge.code(err);
    const resolution = owner.backend.recover(batch) catch |err| return bridge.code(err);
    store.resolve(batch.ticket, resolution) catch |err| return bridge.code(err);
    return if (resolution == .committed) shared.GLOWCAP_OK else c.GLOWCAP_LOAM_ERR_UNCHANGED;
}

pub fn glowcap_loam_lmdb_clear_last_error() callconv(.c) void {
    shared.lastErrorClear();
}
