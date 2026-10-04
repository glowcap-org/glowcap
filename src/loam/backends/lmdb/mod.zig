//! Optional blocking native storage. The embedding executes reads and commits
//! off the Host turn and joins them before close. No mapped value escapes a
//! backend call, and no LMDB transaction follows the lifetime of a capability.
const std = @import("std");
const core = @import("loam_core");
const c = @import("c.zig");

pub const Lmdb = struct {
    env: *c.Env,
    dbi: c_uint,
    lock_fd: c_int,
    directory_fd: c_int,
    environment_open: bool = true,
    metadata: core.Metadata,
    users: std.atomic.Value(usize) = .init(0),
    const closing: usize = @as(usize, 1) << (@bitSizeOf(usize) - 1);
    const maintenance = closing >> 1;

    pub const Options = struct {
        map_bytes: usize = 256 * 1024 * 1024,
        max_readers: u32 = 16,
        mode: union(enum) { create: core.StoreId, open: core.StoreId },
    };

    /// The directory must exist. Create refuses an existing Loam store; open
    /// refuses missing or mismatched metadata. Successful opening durably
    /// reserves a fresh incarnation while holding exclusive lifetime custody.
    pub fn open(path: [:0]const u8, options: Options) !Lmdb {
        if (options.map_bytes < 1024 * 1024 or options.max_readers == 0) return error.InvalidLimits;
        var absolute: [std.fs.max_path_bytes:0]u8 = undefined;
        try check(c.loam_lmdb_canonical_path(path.ptr, &absolute, absolute.len));
        const directory = c.loam_lmdb_directory(&absolute);
        if (directory < 0) return error.StorageFailure;
        errdefer c.loam_lmdb_close_fd(directory);
        const fd = c.loam_lmdb_lock(directory);
        if (fd < 0) return error.CustodyUnavailable;
        errdefer c.loam_lmdb_close_fd(fd);
        var env: ?*c.Env = null;
        try check(c.mdb_env_create(&env));
        errdefer c.mdb_env_close(env.?);
        try check(c.mdb_env_set_mapsize(env.?, options.map_bytes));
        try check(c.mdb_env_set_maxreaders(env.?, options.max_readers));
        // Default synchronous durability. No NOSYNC, NOMETASYNC, WRITEMAP, or
        // MAPASYNC flags are permitted by this profile.
        try check(c.mdb_env_open(env.?, &absolute, c.notls, 0o600));
        var txn: ?*c.Txn = null;
        try check(c.mdb_txn_begin(env.?, null, 0, &txn));
        defer if (txn) |active| c.mdb_txn_abort(active);
        var dbi: c_uint = 0;
        try check(c.mdb_dbi_open(txn.?, null, 0, &dbi));
        var kv: Kv = .{ .txn = txn.?, .dbi = dbi };
        const stored = try kv.get(core.metadata_key);
        const meta: core.Metadata = switch (options.mode) {
            .create => |id| blk: {
                if (stored != null) return error.AlreadyExists;
                break :blk .{ .store = id };
            },
            .open => |id| blk: {
                const found = try core.Metadata.decode(stored orelse return error.MissingStore);
                if (found.store != id) return error.StoreMismatch;
                break :blk found;
            },
        };
        const claimed = try meta.claim();
        try kv.put(core.metadata_key, &claimed.encode());
        const active = txn.?;
        txn = null;
        // Commit consumes its transaction even on failure. An uncertain open
        // returns no store; retry must verify the metadata instead of resetting.
        if (c.mdb_txn_commit(active) != 0) return error.OpenOutcomeUnknown;
        return .{ .env = env.?, .dbi = dbi, .lock_fd = fd, .directory_fd = directory, .metadata = claimed };
    }

    /// Stops new work and refuses to free the environment while a worker or
    /// pending commit retains it. Retry after joining that work. The associated
    /// Store must also retire its leases and staging before its own deinit.
    pub fn close(self: *Lmdb) !void {
        if (self.users.fetchOr(closing, .acq_rel) & ~closing != 0) return error.Busy;
        if (self.environment_open) c.mdb_env_close(self.env);
        c.loam_lmdb_close_fd(self.lock_fd);
        c.loam_lmdb_close_fd(self.directory_fd);
        self.* = undefined;
    }

    pub const Statistics = struct {
        map_bytes: usize,
        high_water_bytes: usize,
        page_bytes: usize,
        tree_pages: usize,
        entries: usize,
    };

    /// One offline replacement. Keep the backend stable until deinit. A failed
    /// copy is canceled; an installed copy can retry its directory sync. The
    /// original owner lock remains held until backend close in every state.
    pub const Compaction = struct {
        owner: *Lmdb,
        files: c.ReplacementFiles,
        copy_path: [std.fs.max_path_bytes:0]u8,
        phase: enum { copying, prepared, installed, finished, failed } = .copying,

        fn init(owner: *Lmdb) !Compaction {
            var source_path: [*:0]const u8 = undefined;
            try check(c.mdb_env_get_path(owner.env, &source_path));
            var result: Compaction = .{ .owner = owner, .files = undefined, .copy_path = undefined };
            try check(c.mdb_env_sync(owner.env, 1));
            try check(c.loam_lmdb_replacement_begin(owner.directory_fd, source_path, &result.copy_path, result.copy_path.len, &result.files));
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
        /// directory. Even a rename refusal leaves the backend fenced for
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
        /// incomplete copy is discarded. After installation the backend stays
        /// closed to work, and close alone releases lifetime writer custody.
        pub fn deinit(self: *Compaction) void {
            c.loam_lmdb_replacement_end(&self.files);
            self.owner.endMaintenance();
            self.* = undefined;
        }
    };

    /// Reserves the backend exclusively until Compaction.deinit. Join workers
    /// and retire the associated Store before beginning this offline operation.
    /// Installation closes backend admission; close it before reopening.
    pub fn beginCompaction(self: *Lmdb) !Compaction {
        try self.beginMaintenance();
        errdefer self.endMaintenance();
        return Compaction.init(self);
    }

    /// Complete offline replacement and release its maintenance reservation.
    /// Successful installation fences this backend; close and reopen normally.
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

    /// Reports physical geometry while no backend transaction is active.
    /// High water includes reusable free pages; map minus high water is unused
    /// address space, not a guarantee that a particular write will fit.
    pub fn inspect(self: *Lmdb) !Statistics {
        try self.beginMaintenance();
        defer self.endMaintenance();
        return self.statistics();
    }

    /// Increase the native map between backend operations. Copied record leases
    /// remain valid. Active workers refuse growth; remapping failure fences the
    /// backend for close/reopen because LMDB may have released the old mapping.
    /// A later successful write persists the increased size in LMDB metadata.
    pub fn grow(self: *Lmdb, map_bytes: usize) !void {
        try self.beginMaintenance();
        defer self.endMaintenance();
        const stat = try self.statistics();
        if (map_bytes <= stat.map_bytes or map_bytes % stat.page_bytes != 0) return error.InvalidLimits;
        if (c.mdb_env_set_mapsize(self.env, map_bytes) != 0) {
            _ = self.users.fetchOr(closing, .acq_rel);
            return error.ReopenRequired;
        }
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
            return if (current & closing != 0) error.Closed else error.Busy;
        }
    }

    fn endMaintenance(self: *Lmdb) void {
        // A concurrent close can set its fence while maintenance is in flight.
        const previous = self.users.fetchAnd(~maintenance, .release);
        std.debug.assert(previous & maintenance != 0);
    }

    pub fn read(self: *Lmdb, request: core.Read) core.ReadResult {
        self.retain() catch |err| return .{ .failed = err };
        defer self.release();
        return self.readRecord(request) catch |err| .{ .failed = err };
    }

    fn readRecord(self: *Lmdb, request: core.Read) !core.ReadResult {
        var txn: ?*c.Txn = null;
        try check(c.mdb_txn_begin(self.env, null, c.readonly, &txn));
        defer c.mdb_txn_abort(txn.?);
        var kv: Kv = .{ .txn = txn.?, .dbi = self.dbi };
        const meta = try core.Metadata.decode((try kv.get(core.metadata_key)) orelse return error.Corrupt);
        if (meta.store != request.ticket.store or meta.incarnation != request.ticket.incarnation or meta.revision != request.ticket.revision) return error.StaleCompletion;
        const bytes = (try kv.get(&request.id.key())) orelse return .missing;
        if (bytes.len > request.buffer.len) return error.RecordTooLarge;
        @memcpy(request.buffer[0..bytes.len], bytes);
        return .{ .found = .{ .length = bytes.len, .metadata = meta } };
    }

    pub fn commit(self: *Lmdb, batch: core.Batch) core.Outcome {
        var pending = self.beginCommit(batch) catch |err| return .{ .unchanged = err };
        return pending.finish();
    }

    pub fn lookup(self: *Lmdb, request: core.NameLookup) core.NameResult {
        self.retain() catch |err| return .{ .failed = err };
        defer self.release();
        return self.lookupName(request) catch |err| .{ .failed = err };
    }

    fn lookupName(self: *Lmdb, request: core.NameLookup) !core.NameResult {
        var txn: ?*c.Txn = null;
        try check(c.mdb_txn_begin(self.env, null, c.readonly, &txn));
        defer c.mdb_txn_abort(txn.?);
        var kv: Kv = .{ .txn = txn.?, .dbi = self.dbi };
        return request.read(&kv);
    }

    /// Begins and fills one backend transaction without making it durable.
    /// Finish or abort on the same worker before releasing the backend. The
    /// returned object owns the LMDB transaction and retains no batch buffers.
    pub fn beginCommit(self: *Lmdb, batch: core.Batch) !Commit {
        try self.retain();
        errdefer self.release();
        var txn: ?*c.Txn = null;
        try check(c.mdb_txn_begin(self.env, null, 0, &txn));
        errdefer c.mdb_txn_abort(txn.?);
        var kv: Kv = .{ .txn = txn.?, .dbi = self.dbi };
        const next = try batch.apply(&kv);
        return .{ .owner = self, .txn = txn, .metadata = next };
    }

    pub const Commit = struct {
        owner: *Lmdb,
        txn: ?*c.Txn,
        metadata: core.Metadata,

        pub fn finish(self: *Commit) core.Outcome {
            const active = self.txn orelse return .{ .unchanged = error.Closed };
            self.txn = null;
            defer self.owner.release();
            if (c.mdb_txn_commit(active) != 0) return .unknown;
            return .{ .committed = self.metadata };
        }

        pub fn abort(self: *Commit) void {
            if (self.txn) |active| {
                c.mdb_txn_abort(active);
                self.owner.release();
            }
            self.txn = null;
        }
    };

    /// The original commit worker must be joined before resolving absence.
    pub fn recover(self: *Lmdb, batch: core.Batch) !core.Resolution {
        try self.retain();
        defer self.release();
        var txn: ?*c.Txn = null;
        try check(c.mdb_txn_begin(self.env, null, c.readonly, &txn));
        defer c.mdb_txn_abort(txn.?);
        var kv: Kv = .{ .txn = txn.?, .dbi = self.dbi };
        const meta = try core.Metadata.decode((try kv.get(core.metadata_key)) orelse return error.Corrupt);
        return batch.resolve(meta);
    }
    fn retain(self: *Lmdb) !void {
        var current = self.users.load(.acquire);
        while (true) {
            if (current & closing != 0) return error.Closed;
            if (current & maintenance != 0 or current == maintenance - 1) return error.Busy;
            current = self.users.cmpxchgWeak(current, current + 1, .acq_rel, .acquire) orelse return;
        }
    }

    fn release(self: *Lmdb) void {
        const previous = self.users.fetchSub(1, .release);
        std.debug.assert(previous & ~closing != 0);
    }
};

const Kv = struct {
    txn: *c.Txn,
    dbi: c_uint,

    pub fn next(self: *Kv, prefix: []const u8, after: ?[]const u8) !?core.CollectionRow {
        var cursor: ?*c.Cursor = null;
        try check(c.mdb_cursor_open(self.txn, self.dbi, &cursor));
        defer c.mdb_cursor_close(cursor.?);
        var key = val(after orelse prefix);
        var value: c.Val = undefined;
        var rc = c.mdb_cursor_get(cursor.?, &key, &value, 17); // MDB_SET_RANGE
        if (rc == c.not_found) return null;
        try check(rc);
        if (after) |previous| {
            if (std.mem.eql(u8, valueBytes(key), previous)) {
                rc = c.mdb_cursor_get(cursor.?, &key, &value, 8); // MDB_NEXT
                if (rc == c.not_found) return null;
                try check(rc);
            }
        }
        if (!std.mem.startsWith(u8, valueBytes(key), prefix)) return null;
        return .{ .key = valueBytes(key), .value = valueBytes(value) };
    }

    pub fn get(self: *Kv, key: []const u8) !?[]const u8 {
        var k = val(key);
        var value: c.Val = undefined;
        const rc = c.mdb_get(self.txn, self.dbi, &k, &value);
        if (rc == c.not_found) return null;
        try check(rc);
        const bytes: [*]const u8 = @ptrCast(value.data);
        return bytes[0..value.size];
    }

    pub fn put(self: *Kv, key: []const u8, value: []const u8) !void {
        var k = val(key);
        var v = val(value);
        try check(c.mdb_put(self.txn, self.dbi, &k, &v, 0));
    }

    pub fn remove(self: *Kv, key: []const u8) !void {
        var k = val(key);
        try check(c.mdb_del(self.txn, self.dbi, &k, null));
    }
};

fn val(bytes: []const u8) c.Val {
    return .{ .size = bytes.len, .data = @ptrCast(@constCast(bytes.ptr)) };
}

fn valueBytes(value: c.Val) []const u8 {
    const bytes: [*]const u8 = @ptrCast(value.data);
    return bytes[0..value.size];
}

fn check(rc: c_int) !void {
    return switch (rc) {
        0 => {},
        c.map_full => error.StorageCapacity,
        c.readers_full => error.ReaderCapacity,
        @backingInt(std.posix.E.NOSPC), @backingInt(std.posix.E.FBIG) => error.StorageCapacity,
        @backingInt(std.posix.E.NAMETOOLONG) => error.NameTooLong,
        -30796, -30793, -30795, -30794 => error.Corrupt,
        else => error.StorageFailure,
    };
}
