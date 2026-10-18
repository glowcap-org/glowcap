//! Optional blocking storage over SQLite. The embedding executes reads and
//! commits off the Host turn and joins them before close. A value an engine
//! call returns lives until the next call on its transaction, and no SQLite
//! statement outlives the transaction that stepped it.
const std = @import("std");
const core = @import("loam_core");
const c = @import("c.zig");
const connection = @import("connection.zig");
const custody = @import("loam_custody");

/// The database inside the store directory. Its `-wal` and `-shm` siblings
/// are SQLite's, and `loam-owner.lock` is the owner lock.
pub const file_name = "loam.sqlite";
/// `PRAGMA application_id`, the bytes "LOAM", so a foreign tool can tell the
/// file is a Loam store.
pub const application_id: i64 = 0x4C4F414D;
/// `PRAGMA user_version`, the row contract this engine writes.
pub const user_version: i64 = 1;
/// The page size every store is created with, which capacity divides by.
pub const page_bytes: usize = 4096;
/// Bytes the write-ahead log keeps on disk beside the file, outside the
/// capacity. A commit that brings the log to this size checkpoints it into
/// the file, and the first commit after a complete checkpoint truncates the
/// log back to this size, so a larger write grows it only until then.
pub const log_bytes: usize = 4 * 1024 * 1024;
/// One log frame holds a page behind a 24-byte header.
const log_checkpoint_pages = log_bytes / (page_bytes + 24);
/// The largest page count SQLite accepts. A larger capacity is refused
/// rather than silently held to this.
const max_pages: usize = 4294967294;

const Reader = connection.Connection(.reader);
const Writer = connection.Connection(.writer);

pub const Sqlite = struct {
    /// Engine-owned canonical path and requested capacity profile survive
    /// closed handles, so failed recovery can retry without a path allocation.
    directory: [std.fs.max_path_bytes:0]u8,
    capacity_limit_bytes: usize,
    reader_limit: u32,
    writer: Writer,
    readers: [max_readers_limit]Reader,
    reader_count: u32,
    /// Bit `i` set: reader `i` holds no transaction.
    idle_readers: std.atomic.Value(ReaderMask),
    writer_idle: std.atomic.Value(bool) = .init(true),
    connections_open: bool = true,
    lock: custody.owner_lock.Held,
    metadata: core.Metadata,
    admission: custody.Admission = .{},

    /// The most reader connections one engine opens.
    pub const max_readers_limit = 16;
    /// Bit `i` names reader `i`.
    const ReaderMask = std.math.IntFittingRange(0, (1 << max_readers_limit) - 1);
    /// The requested page-cache target per connection. The writer and each
    /// reader have their own cache, outside the Store's residency budget.
    pub const page_cache_bytes = connection.page_cache_bytes;

    pub const Options = struct {
        /// Bytes the database file may reach, held as SQLite's maximum page
        /// count and rounded down to whole pages. The write-ahead log, up to
        /// `log_bytes` between large writes, is not counted. A store reopens with whatever capacity this names.
        capacity_bytes: usize = 256 * 1024 * 1024,
        /// Reader connections opened with the store. Each read transaction
        /// holds one until it ends.
        max_readers: u32 = 4,
        opening: core.Opening,
    };

    /// The directory must exist. Create refuses an existing Loam store. Open
    /// refuses a missing or mismatched one and creates no file. A file that
    /// is not a Loam store is refused untouched. Successful opening durably
    /// reserves a fresh incarnation while holding exclusive lifetime custody.
    pub fn open(path: [:0]const u8, options: Options) !Sqlite {
        if (options.capacity_bytes < core.backend.min_capacity_bytes or options.capacity_bytes / page_bytes > max_pages or options.max_readers == 0 or options.max_readers > max_readers_limit) return error.InvalidLimits;
        var absolute: [std.fs.max_path_bytes:0]u8 = undefined;
        var lock = try custody.owner_lock.acquire(path, &absolute);
        // best-effort: the lock is released on every refusal below, and a failing unlock cannot change what the refusal reports.
        errdefer lock.release() catch {};
        var file: [std.fs.max_path_bytes:0]u8 = undefined;
        const file_path = try filePath(&absolute, &file);
        const creating = options.opening.mode != .open;
        if (!creating and std.c.access(file_path, std.c.F_OK) != 0) return error.MissingStore;
        try connection.check(c.sqlite3_initialize());
        var result: Sqlite = .{ .directory = absolute, .capacity_limit_bytes = options.capacity_bytes, .reader_limit = options.max_readers, .writer = undefined, .readers = undefined, .reader_count = 0, .idle_readers = .init(0), .connections_open = false, .lock = lock, .metadata = undefined };
        try result.openConnections(creating);
        errdefer result.closeConnections() catch {}; // best-effort: opening failure is the report
        try result.writer.beginTransaction();
        errdefer _ = result.writer.rollBack(); // best-effort: the connections close above, which ends any transaction
        const stored = try result.writer.get(core.metadata_key);
        // Absent metadata means new storage only when no row remains. A
        // reclaimed allocator or identity floor would revive stale authority.
        if (stored == null and try result.writer.next("", null) != null) return error.Corrupt;
        const meta = try core.Metadata.select(options.opening.id, options.opening.mode, stored);
        const claimed = try meta.claim();
        try result.writer.put(core.metadata_key, &claimed.encode());
        const rc = result.writer.commitTransaction();
        if (rc != c.done) return commitRefusal(rc) orelse error.OpenOutcomeUnknown;
        result.metadata = claimed;
        return result;
    }

    /// Stops new work and refuses to close while a transaction retains the
    /// engine. Retry after joining that work. A close SQLite refuses leaves
    /// the owner lock held, and the next close releases it.
    pub fn close(self: *Sqlite) !void {
        try self.admission.close();
        try self.closeConnections();
        try self.lock.release();
        self.* = undefined;
    }

    pub fn read(self: *Sqlite, request: core.Read) core.ReadResult {
        return core.backend.read(self, request);
    }

    pub fn commit(self: *Sqlite, batch: core.Batch) core.Outcome {
        return core.backend.commit(self, batch);
    }

    pub fn lookup(self: *Sqlite, request: core.NameLookup) core.NameResult {
        return core.backend.lookup(self, request);
    }

    /// Join the original worker first. Recovery reopens failed connections,
    /// keeps the directory lock and the store's open count, and resolves from
    /// what the fresh connections read. Ordinary work is refused until it
    /// succeeds.
    pub fn recover(self: *Sqlite, batch: core.Batch) !core.Resolution {
        const fenced = try self.admission.beginRecovery();
        defer self.admission.endMaintenance();
        if (fenced) {
            try self.closeConnections();
            try self.openConnections(false);
        }
        try self.writer.beginTransaction();
        errdefer if (!self.writer.rollBack()) self.admission.fence();
        const resolution = try batch.resolve(try core.backend.metadata(&self.writer));
        if (!self.writer.rollBack()) return error.ReopenRequired;
        // Observation may come from a complete but unsynced WAL frame. A full
        // checkpoint flushes the WAL and database before reporting durability.
        if (try connection.readInt(self.writer.db, "PRAGMA wal_checkpoint(FULL)") != 0) return error.Busy;
        self.admission.recovered();
        return resolution;
    }

    /// Open/configure connections without claiming or changing store metadata.
    fn openConnections(self: *Sqlite, creating: bool) !void {
        var file: [std.fs.max_path_bytes:0]u8 = undefined;
        const path = try filePath(&self.directory, &file);
        const handle = try connection.openHandle(path, creating);
        {
            errdefer _ = c.sqlite3_close(handle); // best-effort: configuration refusal is the report
            try configure(handle, self.capacity_limit_bytes, creating);
        }
        self.writer = try Writer.adopt(handle);
        errdefer _ = self.writer.close(); // best-effort: opening refusal is the report
        self.reader_count = 0;
        errdefer for (self.readers[0..self.reader_count]) |*reader| {
            _ = reader.close(); // best-effort: opening refusal is the report
        };
        while (self.reader_count < self.reader_limit) : (self.reader_count += 1) {
            const reader = try connection.openHandle(path, false);
            {
                errdefer _ = c.sqlite3_close(reader); // best-effort: configuration refusal is the report
                try connection.exec(reader, "PRAGMA query_only=1");
            }
            self.readers[self.reader_count] = try Reader.adopt(reader);
        }
        self.idle_readers.store(@intCast((@as(u32, 1) << @intCast(self.reader_limit)) - 1), .release);
        self.connections_open = true;
    }

    fn closeConnections(self: *Sqlite) !void {
        if (!self.connections_open) return;
        self.connections_open = false;
        var refused = false;
        for (self.readers[0..self.reader_count]) |*reader| {
            if (reader.close() != 0) refused = true;
        }
        // Last connection checkpoints the log. Recovery reopens all handles.
        if (self.writer.close() != 0) refused = true;
        if (refused) return error.StorageFailure;
    }

    pub const Statistics = struct {
        /// Bytes the file may reach: the page count limit times the page size.
        capacity_bytes: usize,
        /// Bytes the file holds, free pages included.
        file_bytes: usize,
        /// Bytes on SQLite's free list. Later writes reuse them first, and
        /// `compact` returns them to the file system.
        free_bytes: usize,
        page_bytes: usize,
    };

    /// Reports the file's size and capacity while no engine transaction is
    /// active. Capacity minus file size, plus free bytes, is what later
    /// writes can still use.
    pub fn inspect(self: *Sqlite) !Statistics {
        try self.admission.beginMaintenance();
        defer self.admission.endMaintenance();
        return self.statistics();
    }

    /// Raise the capacity between engine operations, to a larger whole
    /// number of pages. The new capacity lasts until close, and the next
    /// open names its own.
    pub fn grow(self: *Sqlite, capacity_bytes: usize) !void {
        try self.admission.beginMaintenance();
        defer self.admission.endMaintenance();
        const current = try self.statistics();
        if (capacity_bytes <= current.capacity_bytes or capacity_bytes % page_bytes != 0 or capacity_bytes / page_bytes > max_pages) return error.InvalidLimits;
        try setCapacity(self.writer.db, capacity_bytes);
        self.capacity_limit_bytes = capacity_bytes;
    }

    /// Rewrite the file without its free pages, in place, while no engine
    /// transaction is active. SQLite's vacuum is one transaction, so a refusal
    /// or a crash leaves the store as it was or fully compacted. The
    /// checkpoint after it moves the result into the file and truncates the
    /// log, which is when the file shrinks. `Busy` after the vacuum means a
    /// foreign connection held the log, the rows are compacted, and the file
    /// shrinks at a later checkpoint.
    pub fn compact(self: *Sqlite) !void {
        try self.admission.beginMaintenance();
        defer self.admission.endMaintenance();
        try connection.exec(self.writer.db, "VACUUM");
        // The first column is 1 when a reader kept the checkpoint from
        // finishing. Every reader here is idle and the owner lock keeps other
        // Loam processes out, so that is a foreign connection. The vacuum has
        // committed by then, and the file shrinks at a later checkpoint or at
        // close, so `Busy` here reports only the size.
        if (try connection.readInt(self.writer.db, "PRAGMA wal_checkpoint(TRUNCATE)") != 0) return error.Busy;
    }

    fn statistics(self: *Sqlite) !Statistics {
        const db = self.writer.db;
        const pages: usize = @intCast(try connection.readInt(db, "PRAGMA page_count"));
        const free: usize = @intCast(try connection.readInt(db, "PRAGMA freelist_count"));
        const limit: usize = @intCast(try connection.readInt(db, "PRAGMA max_page_count"));
        return .{
            .capacity_bytes = try std.math.mul(usize, limit, page_bytes),
            .file_bytes = try std.math.mul(usize, pages, page_bytes),
            .free_bytes = try std.math.mul(usize, free, page_bytes),
            .page_bytes = page_bytes,
        };
    }

    /// The read transactions open at once, one per reader connection. One
    /// more is refused as `ReaderCapacity`.
    pub fn readerCapacity(self: *const Sqlite) usize {
        return self.reader_limit;
    }

    /// Retains the engine and one reader connection until `end`. The snapshot
    /// is taken at the transaction's first read.
    pub fn beginRead(self: *Sqlite) !ReadTransaction {
        try self.admission.retain();
        errdefer self.admission.release();
        const slot = self.takeReader() orelse return error.ReaderCapacity;
        errdefer self.returnReader(slot);
        try self.readers[slot].beginTransaction();
        return .{ .owner = self, .slot = slot };
    }

    /// Retains the engine and the one writer connection until `commit` or
    /// `abort`. A second concurrent writer is `error.Busy`, never a wait.
    pub fn beginWrite(self: *Sqlite) !WriteTransaction {
        try self.admission.retain();
        errdefer self.admission.release();
        if (!self.writer_idle.swap(false, .acq_rel)) return error.Busy;
        errdefer self.writer_idle.store(true, .release);
        // The prior writer may have fenced after our retain but before it
        // released this connection. Acquiring the slot must observe that fence.
        try self.admission.checkOpen();
        try self.writer.beginTransaction();
        return .{ .owner = self };
    }

    pub const ReadTransaction = struct {
        owner: *Sqlite,
        slot: usize,

        pub fn get(self: *ReadTransaction, key: []const u8) !?[]const u8 {
            return self.owner.readers[self.slot].get(key);
        }

        pub fn next(self: *ReadTransaction, prefix: []const u8, after: ?[]const u8) !?core.CollectionRow {
            return self.owner.readers[self.slot].next(prefix, after);
        }

        /// A reader whose transaction cannot end keeps its connection out of
        /// the pool until the engine closes, so a later read never inherits it.
        pub fn end(self: *ReadTransaction) void {
            if (self.owner.readers[self.slot].rollBack()) self.owner.returnReader(self.slot);
            self.owner.admission.release();
        }
    };

    pub const WriteTransaction = struct {
        owner: *Sqlite,
        state: State = .active,
        const State = union(enum) { active, finished: core.backend.Commit, aborted };

        /// A read the writer cannot answer ends the transaction too, because
        /// what it would have applied is no longer known.
        pub fn get(self: *WriteTransaction, key: []const u8) !?[]const u8 {
            if (self.state != .active) return error.Closed;
            return self.abortOnError(self.owner.writer.get(key));
        }

        pub fn next(self: *WriteTransaction, prefix: []const u8, after: ?[]const u8) !?core.CollectionRow {
            if (self.state != .active) return error.Closed;
            return self.abortOnError(self.owner.writer.next(prefix, after));
        }

        /// A refused put applied nothing and ends the transaction.
        pub fn put(self: *WriteTransaction, key: []const u8, value: []const u8) !void {
            if (self.state != .active) return error.Closed;
            try self.abortOnError(self.owner.writer.put(key, value));
        }

        pub fn remove(self: *WriteTransaction, key: []const u8) !void {
            if (self.state != .active) return error.Closed;
            try self.abortOnError(self.owner.writer.remove(key));
        }

        /// Commit once and retain the reported state. A refused commit changed
        /// nothing and closes the transaction. A repeated completion must not
        /// turn an applied or uncertain write into confirmed absence.
        pub fn commit(self: *WriteTransaction) !core.backend.Commit {
            switch (self.state) {
                .active => {},
                .finished => |state| return state,
                .aborted => return error.Closed,
            }
            const rc = self.owner.writer.commitTransaction();
            if (rc == c.done) {
                self.finish(.{ .finished = .committed });
                return .committed;
            }
            // SQLite rolls a failed commit back itself unless it kept the
            // transaction for a retry. Either way nothing stays open here.
            const clean = self.owner.writer.rollBack();
            if (!clean) self.owner.admission.fence();
            if (commitRefusal(rc)) |err| {
                self.finish(.aborted);
                return if (clean) err else error.ReopenRequired;
            }
            // A clean connection does not prove that the WAL lacks a commit
            // frame. Reopen before recovery so cached state cannot prove a
            // false absence after a write or sync reported an uncertain result.
            self.owner.admission.fence();
            self.finish(.{ .finished = .unknown });
            return .unknown;
        }

        /// Abandon an active transaction. A finished state stays final.
        pub fn abort(self: *WriteTransaction) void {
            if (self.state != .active) return;
            // A writer that cannot roll back can never begin again, so the
            // engine closes to be reopened.
            if (!self.owner.writer.rollBack()) self.owner.admission.fence();
            self.finish(.aborted);
        }

        /// `result`, with a refusal ending the transaction first.
        fn abortOnError(self: *WriteTransaction, result: anytype) @TypeOf(result) {
            return result catch |err| {
                self.abort();
                return err;
            };
        }

        fn finish(self: *WriteTransaction, state: State) void {
            self.state = state;
            self.owner.writer_idle.store(true, .release);
            self.owner.admission.release();
        }
    };

    fn takeReader(self: *Sqlite) ?usize {
        var idle = self.idle_readers.load(.acquire);
        while (idle != 0) {
            const slot: std.math.Log2Int(ReaderMask) = @intCast(@ctz(idle));
            idle = self.idle_readers.cmpxchgWeak(idle, idle & ~(@as(ReaderMask, 1) << slot), .acq_rel, .acquire) orelse return slot;
        }
        return null;
    }

    fn returnReader(self: *Sqlite, slot: usize) void {
        _ = self.idle_readers.fetchOr(@as(ReaderMask, 1) << @intCast(slot), .release);
    }

    comptime {
        core.backend.checkEngine(@This());
    }
};

fn filePath(directory: [*:0]const u8, out: *[std.fs.max_path_bytes:0]u8) ![*:0]const u8 {
    const dir = std.mem.span(directory);
    const total = dir.len + 1 + file_name.len;
    if (total >= out.len) return error.NameTooLong;
    @memcpy(out[0..dir.len], dir);
    out[dir.len] = '/';
    @memcpy(out[dir.len + 1 ..][0..file_name.len], file_name);
    out[total] = 0;
    return out[0..total :0];
}

/// Check an existing file is a Loam store before changing anything in it, or
/// refuse an empty one when not creating. Then set the journal, its size,
/// durability, flush, and capacity, and create the schema in an empty file. Switching to the
/// write-ahead log writes the file header, so it follows the identity check.
/// Busy handling stays at SQLite's default of none, so a lock held elsewhere
/// is refused at once.
fn configure(db: *c.Db, capacity_bytes: usize, creating: bool) !void {
    const empty = try connection.readInt(db, "PRAGMA page_count") == 0;
    if (empty and !creating) return error.MissingStore;
    if (!empty) {
        if (try connection.readInt(db, "PRAGMA application_id") != application_id) return error.ForeignDatabase;
        if (try connection.readInt(db, "PRAGMA user_version") != user_version) return error.UnsupportedVersion;
    }
    if (empty) try connection.exec(db, std.fmt.comptimePrint("PRAGMA page_size={d}", .{page_bytes}));
    try connection.exec(db, "PRAGMA journal_mode=WAL");
    try connection.exec(db, std.fmt.comptimePrint("PRAGMA wal_autocheckpoint={d}", .{log_checkpoint_pages}));
    try connection.exec(db, std.fmt.comptimePrint("PRAGMA journal_size_limit={d}", .{log_bytes}));
    try connection.exec(db, "PRAGMA synchronous=FULL");
    // On Apple systems fsync stops at the drive's cache, so commits and
    // checkpoints flush with F_FULLFSYNC, as LMDB's do. Elsewhere the setting
    // changes nothing. This connection does every commit, vacuum, and closing
    // checkpoint, and reader connections never write.
    try connection.exec(db, "PRAGMA fullfsync=1");
    try setCapacity(db, capacity_bytes);
    if (!empty) return;
    connection.exec(db, std.fmt.comptimePrint(
        \\BEGIN IMMEDIATE;
        \\PRAGMA application_id={d};
        \\PRAGMA user_version={d};
        \\CREATE TABLE kv(k BLOB PRIMARY KEY, v BLOB NOT NULL) WITHOUT ROWID;
        \\COMMIT
    , .{ application_id, user_version })) catch |err| {
        // A partial schema is rolled back so the file stays empty.
        if (c.sqlite3_get_autocommit(db) == 0) connection.exec(db, "ROLLBACK") catch {}; // best-effort: the schema failure is the report, and the handle closes
        return err;
    };
}

/// Hold the file to `capacity_bytes`, rounded down to whole pages. SQLite
/// never sets the limit below the file's current page count, so a smaller
/// capacity than the file already holds refuses every growing write.
fn setCapacity(db: *c.Db, capacity_bytes: usize) !void {
    var text: [48]u8 = undefined;
    const pragma = std.fmt.bufPrintSentinel(&text, "PRAGMA max_page_count={d}", .{capacity_bytes / page_bytes}, 0) catch unreachable;
    try connection.exec(db, pragma.ptr);
}

/// SQLite's commit point in write-ahead log mode is the sync of the commit
/// frame by the log module's frame writer, which every write of the
/// transaction's frames precedes, and with `SQLITE_POWERSAFE_OVERWRITE` no
/// frame is written after that sync. `SQLITE_BUSY` is raised before the
/// frames or swallowed by the log restart. Even `SQLITE_FULL` stays uncertain:
/// a failed write can leave accepted bytes, including the final commit frame,
/// despite the connection returning to autocommit. After the commit,
/// SQLite's default log hook runs the
/// automatic checkpoint and discards its result, and the engine installs no
/// other hook, so a durable commit always reports done.
fn commitRefusal(rc: c_int) ?anyerror {
    return switch (rc) {
        c.busy => error.Busy,
        else => null,
    };
}
