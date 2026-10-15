//! The SQLite archive's C door: open modes, the return code each refusal maps
//! to, custody of the directory, the engine's reader count, and a committed
//! creation that survives reopen.
const std = @import("std");
const c = @import("c_abi_loam");
const n = @import("c_abi_loam_sqlite");
const lmdb = @import("c_abi_loam_lmdb");
const shared = @import("c_abi_shared");

const limits: c.GlowcapLoamLimits = .{ .resident_bytes = 4 * 1024 * 1024, .staging_bytes = 4 * 1024 * 1024, .cache_slots = 64, .max_leases = 128, .max_changes = 64, .max_references = 128, .max_operations = 32, .record_capacity = 32, .max_reference_saves = 96, .max_retentions = 256, .max_continuations = 2, .continuation_bytes = 4096, .max_continuation_targets = 3, .forward_reply_bytes = 3072 };
const schema: c.GlowcapLoamSchema = .{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 };
const capacity: usize = 8 * 1024 * 1024;

fn open(path: []const u8, id: *const [16]u8, mode: u32, backend: *?*n.GlowcapLoamSqlite, store: *?*c.GlowcapLoamStore) i32 {
    return n.glowcap_loam_sqlite_open(path.ptr, path.len, id, mode, capacity, @as([*]const c.GlowcapLoamSchema, @ptrCast(&schema)), 1, &limits, backend, store);
}

test "Loam C SQLite archive has its own fingerprint and error slot" {
    try std.testing.expect(n.glowcap_loam_sqlite_archive_fingerprint() != lmdb.glowcap_loam_lmdb_archive_fingerprint());
    n.glowcap_loam_sqlite_clear_last_error();
    try std.testing.expectEqual(@as(usize, 0), n.glowcap_loam_sqlite_last_error(null, 0));
}

test "Loam C SQLite open maps each refusal to its return code" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const id: [16]u8 = @splat(3);
    const other: [16]u8 = @splat(4);
    var backend: ?*n.GlowcapLoamSqlite = null;
    var store: ?*c.GlowcapLoamStore = null;

    // A store that was never created is absent, and opening it creates nothing.
    try std.testing.expectEqual(shared.GLOWCAP_ERR_NOT_FOUND, open(path, &id, 0, &backend, &store));
    try std.testing.expect(backend == null and store == null);
    try std.testing.expectEqual(shared.GLOWCAP_ERR_NOT_FOUND, open(path, &id, 0, &backend, &store));

    // A capacity below the engine floor is an invalid argument.
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, n.glowcap_loam_sqlite_open(path.ptr, path.len, &id, 1, 4096, @as([*]const c.GlowcapLoamSchema, @ptrCast(&schema)), 1, &limits, &backend, &store));

    try std.testing.expectEqual(shared.GLOWCAP_OK, open(path, &id, 1, &backend, &store));
    const held = backend;

    // The directory has one owner, so a second open waits for the first.
    var second: ?*n.GlowcapLoamSqlite = null;
    var second_store: ?*c.GlowcapLoamStore = null;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, open(path, &id, 0, &second, &second_store));
    try std.testing.expect(second == null and second_store == null);
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_sqlite_release(held));

    // Create refuses an existing store, and a different identity is not this store.
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, open(path, &id, 1, &backend, &store));
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, open(path, &other, 0, &backend, &store));
    try std.testing.expect(backend == null and store == null);
    try std.testing.expectEqual(shared.GLOWCAP_OK, open(path, &id, 2, &backend, &store));
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_sqlite_release(backend));
}

test "Loam C SQLite atomic resource creation and reopen" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try temporary.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const id: [16]u8 = @splat(3);
    var backend: ?*n.GlowcapLoamSqlite = null;
    var store: ?*c.GlowcapLoamStore = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, open(path, &id, 1, &backend, &store));
    // An attachment's worker hands out no more reads than the engine's four
    // default reader connections, fewer than its cache slots.
    try std.testing.expectEqual(@as(usize, 4), (try c.embedding.store(store)).readers);
    var policy = std.mem.zeroes(c.GlowcapLoamPolicy);
    policy.identity = @splat(5);
    policy.permissions[0] = 10;
    policy.permissions[1] = 20;
    policy.permission_count = 2;
    policy.prerequisite_masks[1] = 1;
    var resource: c.GlowcapLoamResource = undefined;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_resource_stage(store, &policy, &id, 1, 7, 1, "initial", 7, 2, &resource));
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_sqlite_commit(backend));
    try std.testing.expectEqual(.idle, (try c.embedding.store(store)).value.phase);
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_sqlite_collect(backend, 4));
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_sqlite_release(backend));

    try std.testing.expectEqual(shared.GLOWCAP_OK, open(path, &id, 0, &backend, &store));
    try std.testing.expectEqual(.idle, (try c.embedding.store(store)).value.phase);
    // Nothing is indeterminate, so recovery has nothing to resolve.
    try std.testing.expectEqual(shared.GLOWCAP_ERR_INVALID_ARGUMENT, n.glowcap_loam_sqlite_recover(backend));
    try std.testing.expectEqual(shared.GLOWCAP_OK, n.glowcap_loam_sqlite_release(backend));
}
