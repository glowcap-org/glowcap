//! Internal C declarations for the pinned LMDB library. This is not a glowcap
//! C ABI. The adapter alone owns these handles and borrowed values.
pub const Env = opaque {};
pub const Txn = opaque {};
pub const Cursor = opaque {};
pub const Val = extern struct { size: usize, data: ?*anyopaque };
pub const Stat = extern struct {
    page_size: c_uint,
    depth: c_uint,
    branch_pages: usize,
    leaf_pages: usize,
    overflow_pages: usize,
    entries: usize,
};
pub const Info = extern struct {
    map_address: ?*anyopaque,
    map_size: usize,
    last_page: usize,
    last_transaction: usize,
    max_readers: c_uint,
    reader_slots: c_uint,
};
pub const readonly = 0x20000;
pub const notls = 0x200000;
pub const not_found = -30798;
pub const map_full = -30792;
pub const readers_full = -30790;
pub const compact = 1;
pub const no_subdir = 0x4000;
pub const no_lock = 0x400000;
pub extern "c" fn mdb_env_get_path(env: *Env, path: *[*:0]const u8) c_int;
pub extern "c" fn mdb_env_sync(env: *Env, force: c_int) c_int;
pub extern "c" fn mdb_env_copyfd2(env: *Env, fd: c_int, flags: c_uint) c_int;
pub extern "c" fn mdb_env_create(env: *?*Env) c_int;
pub extern "c" fn mdb_env_set_mapsize(env: *Env, size: usize) c_int;
pub extern "c" fn mdb_env_set_maxreaders(env: *Env, readers: c_uint) c_int;
pub extern "c" fn mdb_env_open(env: *Env, path: [*:0]const u8, flags: c_uint, mode: @import("std").c.mode_t) c_int;
pub extern "c" fn mdb_env_close(env: *Env) void;
pub extern "c" fn mdb_env_stat(env: *Env, stat: *Stat) c_int;
pub extern "c" fn mdb_env_info(env: *Env, info: *Info) c_int;
pub extern "c" fn mdb_txn_begin(env: *Env, parent: ?*Txn, flags: c_uint, txn: *?*Txn) c_int;
pub extern "c" fn mdb_txn_abort(txn: *Txn) void;
pub extern "c" fn mdb_txn_commit(txn: *Txn) c_int;
pub extern "c" fn mdb_dbi_open(txn: *Txn, name: ?[*:0]const u8, flags: c_uint, dbi: *c_uint) c_int;
pub extern "c" fn mdb_get(txn: *Txn, dbi: c_uint, key: *Val, value: *Val) c_int;
pub extern "c" fn mdb_put(txn: *Txn, dbi: c_uint, key: *Val, value: *Val, flags: c_uint) c_int;
pub extern "c" fn mdb_del(txn: *Txn, dbi: c_uint, key: *Val, value: ?*Val) c_int;
pub extern "c" fn mdb_cursor_open(txn: *Txn, dbi: c_uint, cursor: *?*Cursor) c_int;
pub extern "c" fn mdb_cursor_close(cursor: *Cursor) void;
pub extern "c" fn mdb_cursor_get(cursor: *Cursor, key: *Val, value: *Val, operation: c_uint) c_int;
pub extern "c" fn loam_lmdb_canonical_path(path: [*:0]const u8, result: [*]u8, capacity: usize) c_int;
pub extern "c" fn loam_lmdb_directory(path: [*:0]const u8) c_int;
pub extern "c" fn loam_lmdb_lock(directory: c_int) c_int;
pub extern "c" fn loam_lmdb_unlock(fd: c_int) c_int;
pub extern "c" fn loam_lmdb_close_fd(fd: c_int) void;
pub const ReplacementFiles = extern struct { directory: c_int, copy: c_int };
pub extern "c" fn loam_lmdb_replacement_begin(directory: c_int, source_path: [*:0]const u8, copy_path: [*]u8, capacity: usize, files: *ReplacementFiles) c_int;
pub extern "c" fn loam_lmdb_replacement_sync_copy(files: *const ReplacementFiles) c_int;
pub extern "c" fn loam_lmdb_replacement_install(files: *const ReplacementFiles) c_int;
pub extern "c" fn loam_lmdb_replacement_sync_directory(files: *const ReplacementFiles) c_int;
pub extern "c" fn loam_lmdb_replacement_end(files: *const ReplacementFiles) void;
