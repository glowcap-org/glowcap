//! Optional blocking storage. The embedding runs reads and commits off the
//! Host turn and joins them before close. A value read from a transaction
//! stays valid until that transaction's next operation. No LMDB transaction
//! lives as long as a capability.
const std = @import("std");
const core = @import("loam_core");
const c = @import("c.zig");
const owner_lock = @import("loam_owner_lock");
const Kv = @import("kv.zig").Kv;
const check = @import("kv.zig").check;

/// The file inside a store directory that holds its records.
pub const file_name = "data.mdb";

/// An LMDB store that reads each page with a system call, so a disk error
/// comes back as an error instead of SIGBUS. Pages land in a cache that LMDB
/// bounds and evicts, outside the Store's memory budget. A miss reads a whole
/// page, or a whole large value, before LMDB parses it. A value you read
/// borrows the cache until the next operation on its transaction, so using it
/// never touches the disk.
pub const Lmdb = struct {
    env: *c.Env,
    /// Engine-owned canonical path and requested capacity profile survive
    /// closed handles, so failed recovery can retry without a path allocation.
    directory: [std.fs.max_path_bytes:0]u8,
    capacity_limit_bytes: usize,
    dbi: c_uint,
    lock: owner_lock.Held,
    /// LMDB's reader table, which holds at least `Options.max_readers` and
    /// more when an earlier open left a larger lock file.
    reader_capacity: usize,
    environment_open: bool = true,
    metadata: core.Metadata,
    users: std.atomic.Value(usize) = .init(0),
    writer_idle: std.atomic.Value(bool) = .init(true),
    const closing: usize = @as(usize, 1) << (@bitSizeOf(usize) - 1);
    const maintenance = closing >> 1;
    const reopen_required = maintenance >> 1;

    pub const Options = struct {
        map_bytes: usize = 256 * 1024 * 1024,
        max_readers: u32 = 16,
        mode: union(enum) { create: core.StoreId, open: core.StoreId, bootstrap: core.StoreId },
    };

    /// The directory must exist. Create refuses an existing Loam store. Open
    /// refuses a missing store before LMDB creates any file, and refuses
    /// mismatched metadata. Successful opening durably
    /// reserves a fresh incarnation while holding exclusive lifetime custody.
    pub fn open(path: [:0]const u8, options: Options) !Lmdb {
        if (options.map_bytes < 1024 * 1024 or options.map_bytes > std.math.maxInt(std.c.off_t) or options.max_readers == 0) return error.InvalidLimits;
        var absolute: [std.fs.max_path_bytes:0]u8 = undefined;
        var lock = try owner_lock.acquire(path, &absolute);
        // best-effort: the lock is released on every refusal below, and a failing unlock cannot change what the refusal reports.
        errdefer lock.release() catch {};
        const env = try openEnvironment(&absolute, options.map_bytes, options.max_readers, options.mode == .open);
        errdefer c.mdb_env_close(env);
        var readers: c_uint = 0;
        try check(c.mdb_env_get_maxreaders(env, &readers));
        var txn: ?*c.Txn = null;
        try check(c.mdb_txn_begin(env, null, 0, &txn));
        defer if (txn) |active| c.mdb_txn_abort(active);
        var dbi: c_uint = 0;
        try check(c.mdb_dbi_open(txn.?, null, 0, &dbi));
        var kv: Kv = .{ .txn = txn.?, .dbi = dbi };
        const stored = try kv.get(core.metadata_key);
        // Absent metadata means new storage only when no physical rows remain.
        // One cursor seek verifies this under the same exclusive transaction;
        // reclaiming an allocator/identity floor would revive stale authority.
        if (stored == null and try kv.next("", null) != null) return error.Corrupt;
        const meta = switch (options.mode) {
            inline else => |id, mode| try core.Metadata.select(id, @field(core.OpenMode, @tagName(mode)), stored),
        };
        const claimed = try meta.claim();
        try kv.put(core.metadata_key, &claimed.encode());
        const active = txn.?;
        txn = null;
        // Commit consumes its transaction even on failure. An uncertain open
        // returns no store; retry must verify the metadata instead of resetting.
        if (c.mdb_txn_commit(active) != 0) return error.OpenOutcomeUnknown;
        return .{ .env = env, .directory = absolute, .capacity_limit_bytes = options.map_bytes, .dbi = dbi, .lock = lock, .reader_capacity = readers, .metadata = claimed };
    }

    /// Stops new work and refuses to free the environment while a worker or
    /// pending commit retains it. Retry after joining that work. The associated
    /// Store must also retire its leases and staging before its own deinit.
    pub fn close(self: *Lmdb) !void {
        if (self.users.fetchOr(closing, .acq_rel) & ~(closing | reopen_required) != 0) return error.Busy;
        if (self.environment_open) {
            c.mdb_env_close(self.env);
            self.environment_open = false;
        }
        try self.lock.release();
        self.* = undefined;
    }

    pub const Statistics = struct {
        map_bytes: usize,
        high_water_bytes: usize,
        page_bytes: usize,
        tree_pages: usize,
        entries: usize,
    };

    /// One offline replacement. Keep the engine stable until deinit. A failed
    /// copy is canceled. An installed copy can retry its directory sync. The
    /// original owner lock remains held until engine close in every state.
    pub const Compaction = struct {
        owner: *Lmdb,
        files: c.ReplacementFiles,
        copy_path: [std.fs.max_path_bytes:0]u8,
        phase: enum { copying, prepared, installed, finished, failed } = .copying,

        fn init(owner: *Lmdb) !Compaction {
            var result: Compaction = .{ .owner = owner, .files = undefined, .copy_path = undefined };
            try check(c.mdb_env_sync(owner.env, 1));
            try check(c.loam_lmdb_replacement_begin(owner.lock.directory, &owner.directory, &result.copy_path, result.copy_path.len, &result.files));
            errdefer c.loam_lmdb_replacement_end(&result.files);
            // Establish the existing directory entry before creating a durable
            // replacement. Synchronous commits already flushed source data.
            try check(c.loam_lmdb_replacement_sync_directory(&result.files));
            return result;
        }

        /// Compact using LMDB's bounded copy machinery, flush the copy, and
        /// compare every key/value against the quiescent source. No application
        /// row, index, receipt, or authority floor is interpreted or omitted.
        pub fn prepare(self: *Compaction) !void {
            if (self.phase != .copying) return error.WrongPhase;
            errdefer self.phase = .failed;
            try check(c.mdb_env_copyfd2(self.owner.env, self.files.copy, c.compact));
            try check(c.loam_lmdb_replacement_sync_copy(&self.files));
            try @import("compaction.zig").verify(self.owner.env, self.owner.dbi, self.owner.metadata, &self.copy_path);
            self.phase = .prepared;
        }

        /// Close source admission and atomically replace data.mdb in the same
        /// directory. Even a rename refusal leaves the engine fenced for
        /// close/reopen. Call finish before reporting durable installation.
        pub fn install(self: *Compaction) !void {
            if (self.phase != .prepared) return error.WrongPhase;
            self.owner.closeForReplacement();
            self.phase = .failed;
            try check(c.loam_lmdb_replacement_install(&self.files));
            self.phase = .installed;
        }

        /// Sync the installed directory entry. Failure leaves the installed
        /// state intact for retry; close/reopen resolves an unknown outcome.
        pub fn finish(self: *Compaction) !void {
            if (self.phase != .installed) return error.WrongPhase;
            if (c.loam_lmdb_replacement_sync_directory(&self.files) != 0) return error.InstallOutcomeUnknown;
            self.phase = .finished;
        }

        /// Release this operation after success, cancellation, or failure. An
        /// incomplete copy is discarded. After installation the engine stays
        /// closed to work, and close alone releases lifetime writer custody.
        pub fn deinit(self: *Compaction) void {
            c.loam_lmdb_replacement_end(&self.files);
            self.owner.endMaintenance();
            self.* = undefined;
        }
    };

    /// Reserves the engine exclusively until Compaction.deinit. Join workers
    /// and retire the associated Store before beginning this offline operation.
    /// Installation closes engine admission. Close it before reopening.
    pub fn beginCompaction(self: *Lmdb) !Compaction {
        try self.beginMaintenance();
        errdefer self.endMaintenance();
        return Compaction.init(self);
    }

    /// Complete offline replacement and release its maintenance reservation.
    /// Successful installation fences this engine. Close and reopen normally.
    pub fn compact(self: *Lmdb) !void {
        var operation = try self.beginCompaction();
        defer operation.deinit();
        try operation.prepare();
        try operation.install();
        try operation.finish();
    }

    fn closeForReplacement(self: *Lmdb) void {
        _ = self.users.fetchOr(closing, .acq_rel);
        c.mdb_env_close(self.env);
        self.environment_open = false;
    }

    /// Reports physical geometry while no engine transaction is active.
    /// High water includes reusable free pages. Capacity minus high water is unused
    /// file capacity, not a guarantee that a particular write will fit.
    pub fn inspect(self: *Lmdb) !Statistics {
        try self.beginMaintenance();
        defer self.endMaintenance();
        return self.statistics();
    }

    /// Raise the file's size limit between engine operations. Copied record
    /// leases stay valid, and an active worker refuses growth. Nothing reserves
    /// memory for the new size. The next successful write saves it in LMDB's
    /// metadata.
    pub fn grow(self: *Lmdb, map_bytes: usize) !void {
        try self.beginMaintenance();
        defer self.endMaintenance();
        const stat = try self.statistics();
        if (map_bytes <= stat.map_bytes or map_bytes > std.math.maxInt(std.c.off_t) or map_bytes % stat.page_bytes != 0) return error.InvalidLimits;
        try check(c.mdb_env_set_mapsize(self.env, map_bytes));
        self.capacity_limit_bytes = map_bytes;
    }

    fn statistics(self: *Lmdb) !Statistics {
        var stat: c.Stat = undefined;
        var info: c.Info = undefined;
        try check(c.mdb_env_stat(self.env, &stat));
        try check(c.mdb_env_info(self.env, &info));
        return .{
            .map_bytes = info.map_size,
            .high_water_bytes = try std.math.mul(usize, try std.math.add(usize, info.last_page, 1), stat.page_size),
            .page_bytes = stat.page_size,
            .tree_pages = try std.math.add(usize, try std.math.add(usize, stat.branch_pages, stat.leaf_pages), stat.overflow_pages),
            .entries = stat.entries,
        };
    }

    fn beginMaintenance(self: *Lmdb) !void {
        if (self.users.cmpxchgStrong(0, maintenance, .acq_rel, .acquire)) |current| {
            if (current & reopen_required != 0) return error.ReopenRequired;
            return if (current & closing != 0) error.Closed else error.Busy;
        }
    }

    fn endMaintenance(self: *Lmdb) void {
        // A concurrent close can set its fence while maintenance is in flight.
        const previous = self.users.fetchAnd(~maintenance, .release);
        std.debug.assert(previous & maintenance != 0);
    }

    pub fn read(self: *Lmdb, request: core.Read) core.ReadResult {
        return core.backend.read(self, request);
    }

    pub fn commit(self: *Lmdb, batch: core.Batch) core.Outcome {
        return core.backend.commit(self, batch);
    }

    pub fn lookup(self: *Lmdb, request: core.NameLookup) core.NameResult {
        return core.backend.lookup(self, request);
    }

    /// Join the original worker first. Recovery runs alone, reopens an
    /// environment that refuses work after an unknown commit, and keeps the
    /// directory lock and the store's open count. A failed reopen keeps refusing
    /// work and can be retried.
    pub fn recover(self: *Lmdb, batch: core.Batch) !core.Resolution {
        const fenced = self.users.load(.acquire) & reopen_required;
        if (self.users.cmpxchgStrong(fenced, fenced | maintenance | reopen_required, .acq_rel, .acquire)) |current| {
            return if (current & closing != 0) error.Closed else error.Busy;
        }
        defer self.endMaintenance();
        if (fenced != 0) {
            if (self.environment_open) {
                c.mdb_env_close(self.env);
                self.environment_open = false;
            }
            const env = try openEnvironment(&self.directory, self.capacity_limit_bytes, @intCast(self.reader_capacity), true);
            self.env = env;
            self.environment_open = true;
        }
        var txn: ?*c.Txn = null;
        try check(c.mdb_txn_begin(self.env, null, c.readonly, &txn));
        defer c.mdb_txn_abort(txn.?);
        var dbi: c_uint = 0;
        try check(c.mdb_dbi_open(txn.?, null, 0, &dbi));
        var kv: Kv = .{ .txn = txn.?, .dbi = dbi };
        // A failed sync can leave a complete receipt only in the OS cache.
        // Flush it successfully before upgrading observation to durability.
        try check(c.mdb_env_sync(self.env, 1));
        const resolution = try batch.resolve(try core.backend.metadata(&kv));
        self.dbi = dbi;
        _ = self.users.fetchAnd(~reopen_required, .release);
        return resolution;
    }

    /// The read transactions open at once, one per reader table slot. One
    /// more is refused as `ReaderCapacity`.
    pub fn readerCapacity(self: *const Lmdb) usize {
        return self.reader_capacity;
    }

    /// Retains the engine until `end`. A borrowed value ends at the next operation or transaction end.
    pub fn beginRead(self: *Lmdb) !ReadTransaction {
        try self.retain();
        errdefer self.release();
        var txn: ?*c.Txn = null;
        try check(c.mdb_txn_begin(self.env, null, c.readonly, &txn));
        return .{ .owner = self, .kv = .{ .txn = txn.?, .dbi = self.dbi } };
    }

    /// Retains the engine and its writer until `commit` or `abort` on the
    /// same worker. A concurrent writer is refused as Busy, never queued
    /// inside LMDB where it could pass an uncertain completion's fence.
    pub fn beginWrite(self: *Lmdb) !WriteTransaction {
        try self.retain();
        errdefer self.release();
        if (!self.writer_idle.swap(false, .acq_rel)) return error.Busy;
        errdefer self.writer_idle.store(true, .release);
        if (self.users.load(.acquire) & reopen_required != 0) return error.ReopenRequired;
        var txn: ?*c.Txn = null;
        try check(c.mdb_txn_begin(self.env, null, 0, &txn));
        return .{ .owner = self, .kv = .{ .txn = txn.?, .dbi = self.dbi } };
    }

    pub const ReadTransaction = struct {
        owner: *Lmdb,
        kv: Kv,

        pub fn get(self: *ReadTransaction, key: []const u8) !?[]const u8 {
            return self.kv.get(key);
        }

        pub fn next(self: *ReadTransaction, prefix: []const u8, after: ?[]const u8) !?core.CollectionRow {
            return self.kv.next(prefix, after);
        }

        pub fn end(self: *ReadTransaction) void {
            c.mdb_txn_abort(self.kv.txn);
            self.owner.release();
        }
    };

    pub const WriteTransaction = struct {
        owner: *Lmdb,
        kv: Kv,
        state: union(enum) { active, finished: core.backend.Commit, aborted } = .active,

        pub fn get(self: *WriteTransaction, key: []const u8) !?[]const u8 {
            if (self.state != .active) return error.Closed;
            return self.kv.get(key);
        }

        pub fn next(self: *WriteTransaction, prefix: []const u8, after: ?[]const u8) !?core.CollectionRow {
            if (self.state != .active) return error.Closed;
            return self.kv.next(prefix, after);
        }

        /// A refused put applied nothing and ends the transaction, which LMDB
        /// has already marked unusable for anything but abort.
        pub fn put(self: *WriteTransaction, key: []const u8, value: []const u8) !void {
            if (self.state != .active) return error.Closed;
            self.kv.put(key, value) catch |err| {
                self.abort();
                return err;
            };
        }

        pub fn remove(self: *WriteTransaction, key: []const u8) !void {
            if (self.state != .active) return error.Closed;
            self.kv.remove(key) catch |err| {
                self.abort();
                return err;
            };
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
            // mdb_txn_commit frees the transaction on every path.
            const rc = c.mdb_txn_commit(self.kv.txn);
            if (rc != 0) if (commitRefusal(rc)) |err| {
                self.state = .aborted;
                self.owner.writer_idle.store(true, .release);
                self.owner.release();
                return err;
            };
            const state: core.backend.Commit = if (rc == 0) .committed else .unknown;
            // LMDB does not fence every post-metadata failure (notably the
            // macOS F_FULLFSYNC path). Admission is our responsibility.
            if (state == .unknown) _ = self.owner.users.fetchOr(reopen_required, .acq_rel);
            self.state = .{ .finished = state };
            self.owner.writer_idle.store(true, .release);
            self.owner.release();
            return state;
        }

        /// Abandon an active transaction. A finished state stays final.
        pub fn abort(self: *WriteTransaction) void {
            if (self.state != .active) return;
            c.mdb_txn_abort(self.kv.txn);
            self.state = .aborted;
            self.owner.writer_idle.store(true, .release);
            self.owner.release();
        }
    };

    fn retain(self: *Lmdb) !void {
        var current = self.users.load(.acquire);
        while (true) {
            if (current & reopen_required != 0) return error.ReopenRequired;
            if (current & closing != 0) return error.Closed;
            if (current & maintenance != 0 or current == reopen_required - 1) return error.Busy;
            current = self.users.cmpxchgWeak(current, current + 1, .acq_rel, .acquire) orelse return;
        }
    }

    fn release(self: *Lmdb) void {
        const previous = self.users.fetchSub(1, .release);
        std.debug.assert(previous & ~(closing | reopen_required) != 0);
    }

    comptime {
        core.backend.checkEngine(@This());
    }
};

/// LMDB's commit point is the metadata page write in `mdb_env_write_meta`,
/// which `_mdb_txn_commit` reaches only after the freelist is saved, the dirty
/// pages are written, and the data is synced. Each code named here is produced
/// before that write, so the commit changed nothing on disk and LMDB aborted
/// the transaction. Every other code, an I/O error above all, may have come
/// from the metadata write itself and stays uncertain.
fn commitRefusal(rc: c_int) ?anyerror {
    return switch (rc) {
        // Saving the freelist allocates pages and runs out of map.
        c.map_full => error.StorageCapacity,
        // Saving the freelist overflows the dirty page list.
        c.txn_full => error.TransactionCapacity,
        // A finished or foreign transaction is refused at entry, and a loose
        // page count mismatch is caught between the page flush and the
        // metadata write.
        c.bad_txn, c.bad_dbi, c.problem => error.StorageFailure,
        // OS errors do not identify their stage. Metadata writes and their
        // synchronization can report errors too, including capacity errors.
        else => null,
    };
}

/// Opens the LMDB environment. Only `open` also records a new open count.
fn openEnvironment(path: [*:0]const u8, capacity: usize, readers: u32, existing: bool) !*c.Env {
    // LMDB otherwise creates missing data during a recovery attempt.
    if (existing) {
        var file: [std.fs.max_path_bytes:0]u8 = undefined;
        const data = std.fmt.bufPrintSentinel(&file, "{s}/" ++ file_name, .{std.mem.span(path)}, 0) catch return error.NameTooLong;
        if (std.c.access(data, std.c.F_OK) != 0) return error.MissingStore;
    }
    var env: ?*c.Env = null;
    try check(c.mdb_env_create(&env));
    errdefer c.mdb_env_close(env.?);
    try check(c.mdb_env_set_mapsize(env.?, capacity));
    try check(c.mdb_env_set_maxreaders(env.?, readers));
    // Recovery uses exactly the same synchronous profile as initial opening.
    try check(c.mdb_env_open(env.?, path, c.notls, 0o600));
    return env.?;
}
