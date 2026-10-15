//! Internal C declarations for the pinned SQLite amalgamation. This is not a
//! glowcap C ABI. The engine alone owns these handles and borrowed values.
pub const Db = opaque {};
pub const Stmt = opaque {};
pub const Destructor = ?*const fn (?*anyopaque) callconv(.c) void;
/// `SQLITE_STATIC`: the bound bytes outlive every step that reads them.
pub const static: Destructor = null;
pub const Callback = ?*const fn (?*anyopaque, c_int, ?[*]?[*:0]u8, ?[*]?[*:0]u8) callconv(.c) c_int;

/// Primary result codes. A code SQLite reports with `open_exrescode` set
/// carries its extended cause above the low byte.
pub const ok = 0;
pub const busy = 5;
pub const locked = 6;
pub const nomem = 7;
pub const ioerr = 10;
pub const corrupt = 11;
pub const full = 13;
pub const cantopen = 14;
pub const toobig = 18;
pub const notadb = 26;
pub const row = 100;
pub const done = 101;

pub const open_readwrite: c_int = 0x2;
pub const open_create: c_int = 0x4;
pub const open_nomutex: c_int = 0x8000;
pub const open_exrescode: c_int = 0x02000000;

pub extern "c" fn sqlite3_initialize() c_int;
pub extern "c" fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*Db, flags: c_int, vfs: ?[*:0]const u8) c_int;
pub extern "c" fn sqlite3_close(db: *Db) c_int;
pub extern "c" fn sqlite3_exec(db: *Db, sql: [*:0]const u8, callback: Callback, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
pub extern "c" fn sqlite3_prepare_v2(db: *Db, sql: [*:0]const u8, length: c_int, stmt: *?*Stmt, tail: ?*?[*:0]const u8) c_int;
pub extern "c" fn sqlite3_finalize(stmt: *Stmt) c_int;
pub extern "c" fn sqlite3_reset(stmt: *Stmt) c_int;
pub extern "c" fn sqlite3_clear_bindings(stmt: *Stmt) c_int;
pub extern "c" fn sqlite3_step(stmt: *Stmt) c_int;
pub extern "c" fn sqlite3_bind_blob(stmt: *Stmt, index: c_int, bytes: *const anyopaque, length: c_int, destructor: Destructor) c_int;
pub extern "c" fn sqlite3_bind_zeroblob(stmt: *Stmt, index: c_int, length: c_int) c_int;
pub extern "c" fn sqlite3_column_blob(stmt: *Stmt, column: c_int) ?*const anyopaque;
pub extern "c" fn sqlite3_column_bytes(stmt: *Stmt, column: c_int) c_int;
pub extern "c" fn sqlite3_column_int64(stmt: *Stmt, column: c_int) i64;
pub extern "c" fn sqlite3_get_autocommit(db: *Db) c_int;
