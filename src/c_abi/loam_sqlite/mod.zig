//! Optional SQLite execution companion. It creates no Host or actor runtime.
pub const std_options = @import("c_abi_shared").library_options;
const c = @import("c_abi_loam");
const bridge = c.embedding;
const shared = @import("c_abi_shared");
const Sqlite = @import("loam_sqlite").Sqlite;
pub const GlowcapLoamSqlite = opaque {};
pub const symbols = @import("symbols.zig");
const Executor = bridge.executor.Executor(Sqlite);

pub fn glowcap_loam_sqlite_open(path: ?[*]const u8, path_len: usize, store_id: ?[*]const u8, create: u32, capacity_bytes: usize, schemas: ?[*]const c.GlowcapLoamSchema, schema_count: usize, limits: ?*const c.GlowcapLoamLimits, out_storage: ?*?*GlowcapLoamSqlite, out_store: ?*?*c.GlowcapLoamStore) callconv(.c) i32 {
    return Executor.open(store_id, create, schemas, schema_count, limits, @ptrCast(out_storage), out_store, Executor.Disk("capacity_bytes"){ .path = path, .path_len = path_len, .size = capacity_bytes });
}
pub fn glowcap_loam_sqlite_release(raw: ?*GlowcapLoamSqlite) callconv(.c) i32 {
    return Executor.release(raw);
}
pub fn glowcap_loam_sqlite_work_run(raw: ?*GlowcapLoamSqlite, work_handle: ?*c.GlowcapLoamWork) callconv(.c) i32 {
    return (Executor.from(raw) catch |err| return bridge.code(err)).workRun(work_handle);
}
pub fn glowcap_loam_sqlite_restore(raw: ?*GlowcapLoamSqlite, attachment: ?*c.GlowcapLoamAttachment, object: ?*const c.GlowcapLoamObject, out_ref: ?*shared.GlowcapReference) callconv(.c) i32 {
    return (Executor.from(raw) catch |err| return bridge.code(err)).restore(attachment, object, out_ref);
}
pub fn glowcap_loam_sqlite_commit(raw: ?*GlowcapLoamSqlite) callconv(.c) i32 {
    return (Executor.from(raw) catch |err| return bridge.code(err)).commit();
}
pub fn glowcap_loam_sqlite_collect(raw: ?*GlowcapLoamSqlite, work_limit: usize) callconv(.c) i32 {
    return (Executor.from(raw) catch |err| return bridge.code(err)).collect(work_limit);
}
pub fn glowcap_loam_sqlite_last_error(buf: ?[*]u8, len: usize) callconv(.c) usize {
    return shared.lastErrorRead(buf, len);
}

pub const contract_layouts = [_]shared.archive_contract.Layout{};
pub const GLOWCAP_LOAM_SQLITE_ARCHIVE_FINGERPRINT = shared.archive_contract.fingerprint("glowcap_loam_sqlite", @This(), .{ &shared.contract_layouts, &contract_layouts });
pub fn glowcap_loam_sqlite_archive_fingerprint() callconv(.c) u64 {
    return GLOWCAP_LOAM_SQLITE_ARCHIVE_FINGERPRINT;
}

pub fn glowcap_loam_sqlite_recover(raw: ?*GlowcapLoamSqlite) callconv(.c) i32 {
    return (Executor.from(raw) catch |err| return bridge.code(err)).recover();
}

pub fn glowcap_loam_sqlite_clear_last_error() callconv(.c) void {
    shared.lastErrorClear();
}
