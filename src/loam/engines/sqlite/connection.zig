//! One SQLite connection and the statements the engine steps on it. A
//! reader prepares the row reads and a deferred BEGIN. The writer also
//! prepares the row writes, BEGIN IMMEDIATE, and COMMIT. A row value a
//! connection returns borrows the statement that produced it and ends at
//! the connection's next operation.
const std = @import("std");
const core = @import("loam_core");
const c = @import("c.zig");

pub const Role = enum { reader, writer };

/// Every failure a connection reports, by what the caller can do about it.
pub const Error = error{ Closed, StorageCapacity, KeyTooLong, ValueTooLarge, OutOfMemory, Busy, Corrupt, StorageFailure };

pub fn Connection(comptime role: Role) type {
    return struct {
        db: *c.Db,
        begin: *c.Stmt,
        rollback: *c.Stmt,
        get_row: *c.Stmt,
        first_from: *c.Stmt,
        first_after: *c.Stmt,
        commit: Writes(*c.Stmt),
        upsert: Writes(*c.Stmt),
        delete: Writes(*c.Stmt),
        /// The statement whose row the last returned value borrows. Resetting
        /// it ends that value, so every operation resets it first.
        active: ?*c.Stmt = null,
        /// The key an operation binds. A key argument may be the previous
        /// row's key, which the operation ends before it binds, so the key is
        /// copied here first. The copy outlives the binding, and a value
        /// passed to `put` is bound only for the step that applies it.
        key: [core.max_key_bytes]u8 = undefined,

        const Self = @This();

        fn Writes(comptime T: type) type {
            return if (role == .writer) T else void;
        }

        const read_texts = [_][*:0]const u8{
            if (role == .writer) "BEGIN IMMEDIATE" else "BEGIN",
            "ROLLBACK",
            "SELECT v FROM kv WHERE k = ?1",
            "SELECT k, v FROM kv WHERE k >= ?1 ORDER BY k LIMIT 1",
            "SELECT k, v FROM kv WHERE k > ?1 ORDER BY k LIMIT 1",
        };
        const write_texts = [_][*:0]const u8{
            "COMMIT",
            "INSERT INTO kv(k, v) VALUES(?1, ?2) ON CONFLICT(k) DO UPDATE SET v = excluded.v",
            "DELETE FROM kv WHERE k = ?1",
        };
        const texts = if (role == .writer) read_texts ++ write_texts else read_texts;
        const fields = [_][]const u8{ "begin", "rollback", "get_row", "first_from", "first_after", "commit", "upsert", "delete" };

        /// Prepare every statement on `db`, whose schema already exists. A
        /// refused preparation closes `db`.
        pub fn adopt(db: *c.Db) Error!Self {
            errdefer _ = c.sqlite3_close(db); // best-effort: the preparation failure is the report, and nothing was stepped
            var prepared: [texts.len]?*c.Stmt = @splat(null);
            errdefer for (prepared) |maybe| if (maybe) |stmt| {
                _ = c.sqlite3_finalize(stmt); // idempotent: finalize repeats a step code, and nothing was stepped
            };
            for (texts, 0..) |text, i| prepared[i] = try prepare(db, text);
            var self: Self = undefined;
            self.db = db;
            self.active = null;
            inline for (fields, 0..) |name, i| {
                if (i < texts.len) @field(self, name) = prepared[i].?;
            }
            return self;
        }

        /// Finalize every statement and close the connection. The result is
        /// SQLite's close code, zero when the connection is gone.
        pub fn close(self: *Self) c_int {
            self.settle();
            inline for (fields, 0..) |name, i| {
                if (i < texts.len) _ = c.sqlite3_finalize(@field(self, name)); // idempotent: finalize repeats the last step code, which its caller already handled
            }
            const rc = c.sqlite3_close(self.db);
            self.* = undefined;
            return rc;
        }

        /// End the lifetime of the last returned value and of the key it was
        /// found by.
        pub fn settle(self: *Self) void {
            if (self.active) |stmt| {
                _ = c.sqlite3_reset(stmt); // idempotent: reset repeats the last step code, which its caller already handled
                _ = c.sqlite3_clear_bindings(stmt); // idempotent: clearing bindings cannot fail
                self.active = null;
            }
        }

        pub fn get(self: *Self, key: []const u8) Error!?[]const u8 {
            try self.inTransaction();
            const k = try self.keyCopy(key);
            self.settle();
            try bind(self.get_row, 1, k);
            if (!try step(self.get_row)) return null;
            self.active = self.get_row;
            return try column(self.get_row, 0);
        }

        pub fn next(self: *Self, prefix: []const u8, after: ?[]const u8) Error!?core.CollectionRow {
            try self.inTransaction();
            // The prefix can borrow the previous row too. Preserve it before
            // resetting that row, independently of the seek key's scratch.
            var prefix_bytes: [core.max_key_bytes]u8 = undefined;
            if (prefix.len > prefix_bytes.len) {
                self.settle();
                return null;
            }
            @memcpy(prefix_bytes[0..prefix.len], prefix);
            const match = prefix_bytes[0..prefix.len];
            const strict = if (after) |floor| std.mem.order(u8, floor, match) != .lt else false;
            const floor = try self.keyCopy(if (strict) after.? else match);
            self.settle();
            const stmt = if (strict) self.first_after else self.first_from;
            try bind(stmt, 1, floor);
            if (!try step(stmt)) return null;
            self.active = stmt;
            const key = try column(stmt, 0);
            if (!std.mem.startsWith(u8, key, match)) {
                self.settle();
                return null;
            }
            return .{ .key = key, .value = try column(stmt, 1) };
        }

        pub fn put(self: *Self, key: []const u8, value: []const u8) Error!void {
            try self.inTransaction();
            const k = try self.keyCopy(key);
            // A value may borrow the active SELECT. Consume it before that
            // statement resets, including when the upsert replaces its row.
            defer self.settle();
            defer _ = c.sqlite3_clear_bindings(self.upsert); // idempotent: release static bindings on every refusal too
            try bind(self.upsert, 1, k);
            try bind(self.upsert, 2, value);
            try run(self.upsert);
        }

        pub fn remove(self: *Self, key: []const u8) Error!void {
            try self.inTransaction();
            const k = try self.keyCopy(key);
            self.settle();
            try bind(self.delete, 1, k);
            try run(self.delete);
        }

        /// SQLite ends a transaction itself on some failures. A statement
        /// run after that would be its own transaction, so a put would commit
        /// alone and a read would see a newer snapshot. Refuse it instead.
        fn inTransaction(self: *Self) Error!void {
            if (c.sqlite3_get_autocommit(self.db) != 0) return error.Closed;
        }

        fn keyCopy(self: *Self, key: []const u8) Error![]const u8 {
            if (key.len > self.key.len) return error.KeyTooLong;
            @memcpy(self.key[0..key.len], key);
            return self.key[0..key.len];
        }

        /// Begin a transaction. The writer takes SQLite's write lock here, so
        /// a holder elsewhere is `error.Busy` at once.
        pub fn beginTransaction(self: *Self) Error!void {
            self.settle();
            try run(self.begin);
        }

        /// Step COMMIT and return its primary code, `c.done` on success.
        pub fn commitTransaction(self: *Self) c_int {
            self.settle();
            const rc = primary(c.sqlite3_step(self.commit));
            _ = c.sqlite3_reset(self.commit); // idempotent: reset repeats the step code returned here
            return rc;
        }

        /// Roll back whatever transaction is open and report whether the
        /// connection is clean, with no transaction, for its next begin.
        pub fn rollBack(self: *Self) bool {
            self.settle();
            if (c.sqlite3_get_autocommit(self.db) == 0) {
                _ = c.sqlite3_step(self.rollback); // tolerant: the autocommit check below is the verdict
                _ = c.sqlite3_reset(self.rollback); // idempotent: reset repeats the step code, judged by the check below
            }
            return c.sqlite3_get_autocommit(self.db) != 0;
        }
    };
}

/// The requested page-cache target per connection. SQLite adds page headers
/// and other working memory, so this does not bound total connection memory.
pub const page_cache_bytes = 2 * 1024 * 1024;

/// Open a connection to `path`, creating the file only when `create` is set,
/// requesting a page-cache target of `page_cache_bytes`.
pub fn openHandle(path: [*:0]const u8, create: bool) Error!*c.Db {
    var db: ?*c.Db = null;
    const flags = c.open_readwrite | c.open_nomutex | c.open_exrescode | @as(c_int, if (create) c.open_create else 0);
    const rc = c.sqlite3_open_v2(path, &db, flags, null);
    // SQLite returns a handle even when opening fails, for its error text.
    errdefer if (db) |handle| {
        _ = c.sqlite3_close(handle); // best-effort: the open failure is the report
    };
    try check(rc);
    const opened = db orelse return error.OutOfMemory;
    // A negative cache size counts KiB rather than pages.
    try exec(opened, std.fmt.comptimePrint("PRAGMA cache_size=-{d}", .{page_cache_bytes / 1024}));
    return opened;
}

/// Run SQL that returns no rows the caller needs.
pub fn exec(db: *c.Db, sql: [*:0]const u8) Error!void {
    try check(c.sqlite3_exec(db, sql, null, null, null));
}

/// Read the one integer a pragma or query returns.
pub fn readInt(db: *c.Db, sql: [*:0]const u8) Error!i64 {
    const stmt = try prepare(db, sql);
    defer _ = c.sqlite3_finalize(stmt); // idempotent: finalize repeats the step code, which step reported
    if (!try step(stmt)) return error.StorageFailure;
    return c.sqlite3_column_int64(stmt, 0);
}

fn prepare(db: *c.Db, text: [*:0]const u8) Error!*c.Stmt {
    var stmt: ?*c.Stmt = null;
    try check(c.sqlite3_prepare_v2(db, text, -1, &stmt, null));
    return stmt orelse error.StorageFailure;
}

/// Step once: true for a row, false when the statement finished and was
/// reset, and the mapped failure after a reset otherwise.
fn step(stmt: *c.Stmt) Error!bool {
    const rc = c.sqlite3_step(stmt);
    switch (primary(rc)) {
        c.row => return true,
        c.done => {},
        else => {
            _ = c.sqlite3_reset(stmt); // idempotent: reset repeats the step code mapped below
            return failure(rc);
        },
    }
    _ = c.sqlite3_reset(stmt); // idempotent: a finished statement resets without a code
    return false;
}

/// Step a statement that yields no row, then release what it bound.
fn run(stmt: *c.Stmt) Error!void {
    defer _ = c.sqlite3_clear_bindings(stmt); // idempotent: clearing bindings cannot fail
    if (try step(stmt)) _ = c.sqlite3_reset(stmt); // idempotent: the row is unused, and reset after a row carries no code
}

fn bind(stmt: *c.Stmt, index: c_int, bytes: []const u8) Error!void {
    const length = std.math.cast(c_int, bytes.len) orelse return error.ValueTooLarge;
    // A null pointer binds SQL NULL whatever the length, so an empty blob
    // binds as a zero-length zeroblob.
    try check(if (length == 0) c.sqlite3_bind_zeroblob(stmt, index, 0) else c.sqlite3_bind_blob(stmt, index, bytes.ptr, length, c.static));
}

fn column(stmt: *c.Stmt, index: c_int) Error![]const u8 {
    const pointer = c.sqlite3_column_blob(stmt, index);
    const length: usize = @intCast(c.sqlite3_column_bytes(stmt, index));
    // A zero-length blob has no pointer. A longer one with no pointer could
    // not be materialized.
    const bytes: [*]const u8 = @ptrCast(pointer orelse return if (length == 0) "" else error.OutOfMemory);
    return bytes[0..length];
}

pub fn check(rc: c_int) Error!void {
    if (primary(rc) != c.ok) return failure(rc);
}

/// The primary result code below the extended bits `open_exrescode` adds.
fn primary(rc: c_int) c_int {
    return rc & 0xff;
}

fn failure(rc: c_int) Error {
    return switch (primary(rc)) {
        c.full => error.StorageCapacity,
        c.toobig => error.ValueTooLarge,
        c.nomem => error.OutOfMemory,
        c.busy, c.locked => error.Busy,
        c.corrupt, c.notadb => error.Corrupt,
        else => error.StorageFailure,
    };
}
