//! Fault injection at the physical backend. Missing allocator and identity
//! metadata cannot authorize initialization over surviving application rows.
const std = @import("std");
const core = @import("loam_core");
const Lmdb = @import("loam_lmdb").Lmdb;
const Env = @typeInfo(@FieldType(Lmdb, "env")).pointer.child;
const Txn = opaque {};
const Val = extern struct { size: usize, data: ?*anyopaque };
extern "c" fn mdb_env_create(*?*Env) c_int;
extern "c" fn mdb_env_open(*Env, [*:0]const u8, c_uint, std.c.mode_t) c_int;
extern "c" fn mdb_env_close(*Env) void;
extern "c" fn mdb_txn_begin(*Env, ?*Txn, c_uint, *?*Txn) c_int;
extern "c" fn mdb_txn_abort(*Txn) void;
extern "c" fn mdb_txn_commit(*Txn) c_int;
extern "c" fn mdb_dbi_open(*Txn, ?[*:0]const u8, c_uint, *c_uint) c_int;
extern "c" fn mdb_put(*Txn, c_uint, *Val, *Val, c_uint) c_int;
extern "c" fn mdb_del(*Txn, c_uint, *Val, ?*Val) c_int;
extern "c" fn mdb_get(*Txn, c_uint, *Val, *Val) c_int;

fn value(bytes: []const u8) Val {
    return .{ .size = bytes.len, .data = @ptrCast(@constCast(bytes.ptr)) };
}

test "loam LMDB refuses initialization over rows without metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.Io.Dir.realPathFileAlloc(tmp.dir, std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const terminated = try std.testing.allocator.dupeSentinel(u8, path, 0);
    defer std.testing.allocator.free(terminated);
    const id: core.StoreId = @fromBackingInt(42);
    var db = try Lmdb.open(terminated, .{ .opening = .{ .id = id, .mode = .create } });
    var txn: ?*Txn = null;
    try std.testing.expectEqual(@as(c_int, 0), mdb_txn_begin(db.env, null, 0, &txn));
    var row_key = value("surviving-row");
    var row_value = value("retained identity and content");
    var meta_key = value(core.metadata_key);
    try std.testing.expectEqual(@as(c_int, 0), mdb_put(txn.?, db.dbi, &row_key, &row_value, 0));
    try std.testing.expectEqual(@as(c_int, 0), mdb_del(txn.?, db.dbi, &meta_key, null));
    try std.testing.expectEqual(@as(c_int, 0), mdb_txn_commit(txn.?));
    try db.close();
    for ([_]Lmdb.Options{
        .{ .opening = .{ .id = id, .mode = .create } },
        .{ .opening = .{ .id = id, .mode = .bootstrap } },
    }) |options| {
        const attempted = Lmdb.open(terminated, options);
        if (attempted) |opened| {
            var unexpected = opened;
            try unexpected.close();
            return error.ExpectedCorruptRefusal;
        } else |err| try std.testing.expectEqual(error.Corrupt, err);
    }
    // Inspect raw storage after both refusals. Neither may claim metadata or
    // remove the original row; a caller must repair/reset explicitly.
    var env: ?*Env = null;
    try std.testing.expectEqual(@as(c_int, 0), mdb_env_create(&env));
    defer mdb_env_close(env.?);
    try std.testing.expectEqual(@as(c_int, 0), mdb_env_open(env.?, terminated, 0x200000, 0o600));
    try std.testing.expectEqual(@as(c_int, 0), mdb_txn_begin(env.?, null, 0x20000, &txn));
    defer mdb_txn_abort(txn.?);
    var dbi: c_uint = 0;
    try std.testing.expectEqual(@as(c_int, 0), mdb_dbi_open(txn.?, null, 0, &dbi));
    var found: Val = undefined;
    try std.testing.expectEqual(@as(c_int, -30798), mdb_get(txn.?, dbi, &meta_key, &found));
    try std.testing.expectEqual(@as(c_int, 0), mdb_get(txn.?, dbi, &row_key, &found));
    const bytes: [*]const u8 = @ptrCast(found.data);
    try std.testing.expectEqualStrings("retained identity and content", bytes[0..found.size]);
}
