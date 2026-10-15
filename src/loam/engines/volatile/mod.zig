//! Volatile realization of Loam batches. Storage bytes live in RAM and have a
//! separate capacity from the core's resident cache. No durability is implied.
const std = @import("std");
const core = @import("loam_core");

pub const Volatile = struct {
    allocator: std.mem.Allocator,
    rows: std.AutoHashMapUnmanaged(Key, []u8) = .empty,
    metadata: core.Metadata,
    max_bytes: usize,
    stored_bytes: usize = 0,
    opened: bool = false,
    /// Set by `close`, so no new transaction begins while a refused close awaits
    /// its retry. `open` clears it.
    closing: bool = false,
    /// Readers share rows. A writer holds them exclusively until it finishes.
    admission: union(enum) { readers: usize, writer } = .{ .readers = 0 },

    pub fn init(allocator: std.mem.Allocator, id: core.StoreId, max_bytes: usize) !Volatile {
        var result: Volatile = .{ .allocator = allocator, .metadata = .{ .store = id }, .max_bytes = max_bytes };
        errdefer result.deinit();
        try result.putInitial(core.metadata_key, &result.metadata.encode());
        return result;
    }

    pub fn deinit(self: *Volatile) void {
        var it = self.rows.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn open(self: *Volatile) !core.Metadata {
        if (self.opened) return error.Busy;
        const next = try self.metadata.claim();
        @memcpy(self.rows.get(try self.storageKey(core.metadata_key)).?, &next.encode());
        self.metadata = next;
        self.opened = true;
        self.closing = false;
        return next;
    }

    /// Stops new transactions, and refuses with `error.Busy` while one is
    /// active. Retry after that transaction ends. The embedding first retires
    /// its Store and all engine work.
    pub fn close(self: *Volatile) !void {
        self.closing = true;
        if (self.admission == .writer or self.admission.readers != 0) return error.Busy;
        self.opened = false;
    }

    pub fn read(self: *Volatile, request: core.Read) core.ReadResult {
        return core.backend.read(self, request);
    }

    pub fn commit(self: *Volatile, batch: core.Batch) core.Outcome {
        return core.backend.commit(self, batch);
    }

    pub fn lookup(self: *Volatile, request: core.NameLookup) core.NameResult {
        return core.backend.lookup(self, request);
    }

    pub fn recover(self: *Volatile, batch: core.Batch) !core.Resolution {
        return core.backend.recover(self, batch);
    }

    /// Read transactions are counted only by the engine's users, so any
    /// number may be open at once.
    pub fn readerCapacity(_: *const Volatile) usize {
        return std.math.maxInt(usize);
    }

    pub fn beginRead(self: *Volatile) !ReadTransaction {
        if (!self.opened or self.closing) return error.Closed;
        switch (self.admission) {
            .writer => return error.Busy,
            .readers => |*count| count.* = std.math.add(usize, count.*, 1) catch return error.ReaderCapacity,
        }
        return .{ .store = self };
    }

    pub fn beginWrite(self: *Volatile) !WriteTransaction {
        if (!self.opened or self.closing) return error.Closed;
        if (self.admission == .writer or self.admission.readers != 0) return error.Busy;
        self.admission = .writer;
        return .{ .store = self };
    }

    pub const ReadTransaction = struct {
        store: *Volatile,

        pub fn get(self: *ReadTransaction, key: []const u8) !?[]const u8 {
            return self.store.rows.get(try self.store.storageKey(key));
        }

        pub fn next(self: *ReadTransaction, prefix: []const u8, after: ?[]const u8) !?core.CollectionRow {
            return nextRow(self.store, &.{}, prefix, after);
        }

        pub fn end(self: *ReadTransaction) void {
            std.debug.assert(self.store.admission == .readers);
            self.store.admission.readers -= 1;
        }
    };

    /// Writes accumulate beside the rows and install together at `commit`.
    /// Reads inside the transaction see them first.
    pub const WriteTransaction = struct {
        store: *Volatile,
        entries: std.ArrayList(Entry) = .empty,
        state: enum { active, committed, aborted } = .active,

        pub fn get(self: *WriteTransaction, key: []const u8) !?[]const u8 {
            if (self.state != .active) return error.Closed;
            const k = try self.store.storageKey(key);
            for (self.entries.items) |entry| if (std.meta.eql(entry.key, k)) return entry.value;
            return self.store.rows.get(k);
        }

        pub fn next(self: *WriteTransaction, prefix: []const u8, after: ?[]const u8) !?core.CollectionRow {
            if (self.state != .active) return error.Closed;
            return nextRow(self.store, self.entries.items, prefix, after);
        }

        /// A refused put applied nothing and ends the transaction.
        pub fn put(self: *WriteTransaction, key: []const u8, value: []const u8) !void {
            if (self.state != .active) return error.Closed;
            errdefer self.finish(.aborted);
            const bytes = try self.store.allocator.dupe(u8, value);
            errdefer self.store.allocator.free(bytes);
            try self.append(key, bytes);
        }

        pub fn remove(self: *WriteTransaction, key: []const u8) !void {
            if (self.state != .active) return error.Closed;
            errdefer self.finish(.aborted);
            try self.append(key, null);
        }

        fn append(self: *WriteTransaction, key: []const u8, value: ?[]u8) !void {
            const k = try self.store.storageKey(key);
            for (self.entries.items) |*entry| if (std.meta.eql(entry.key, k)) {
                if (entry.value) |old| self.store.allocator.free(old);
                entry.value = value;
                return;
            };
            try self.entries.append(self.store.allocator, .{ .key = k, .value = value });
        }

        /// Install every entry or refuse with nothing changed. Either way the
        /// transaction is finished, and only a committed result answers again.
        pub fn commit(self: *WriteTransaction) !core.backend.Commit {
            switch (self.state) {
                .active => {},
                .committed => return .committed,
                .aborted => return error.Closed,
            }
            errdefer self.finish(.aborted);
            const store = self.store;
            const meta = try core.Metadata.decode((try self.get(core.metadata_key)) orelse return error.Corrupt);
            var stored_bytes = store.stored_bytes;
            for (self.entries.items) |entry| {
                if (store.rows.get(entry.key)) |old| stored_bytes -= entry.key.length + old.len;
                if (entry.value) |bytes| stored_bytes = try std.math.add(usize, stored_bytes, entry.key.length + bytes.len);
            }
            if (stored_bytes > store.max_bytes) return error.StorageCapacity;
            try store.rows.ensureUnusedCapacity(store.allocator, @intCast(self.entries.items.len));
            for (self.entries.items) |*entry| {
                if (entry.value) |value| {
                    const result = store.rows.getOrPutAssumeCapacity(entry.key);
                    if (result.found_existing) {
                        store.allocator.free(result.value_ptr.*);
                    }
                    result.value_ptr.* = value;
                } else {
                    if (store.rows.fetchRemove(entry.key)) |removed| store.allocator.free(removed.value);
                }
                entry.value = null;
            }
            store.metadata = meta;
            store.stored_bytes = stored_bytes;
            self.finish(.committed);
            return .committed;
        }

        /// Abandon an active transaction. A finished state stays final.
        pub fn abort(self: *WriteTransaction) void {
            if (self.state != .active) return;
            self.finish(.aborted);
        }

        fn finish(self: *WriteTransaction, state: @FieldType(WriteTransaction, "state")) void {
            for (self.entries.items) |entry| {
                if (entry.value) |bytes| self.store.allocator.free(bytes);
            }
            self.entries.deinit(self.store.allocator);
            self.entries = .empty;
            self.state = state;
            std.debug.assert(self.store.admission == .writer);
            self.store.admission = .{ .readers = 0 };
        }
    };

    fn storageKey(self: *Volatile, bytes: []const u8) !Key {
        _ = self;
        if (bytes.len == 0 or bytes.len > core.max_key_bytes) return error.Corrupt;
        var result: Key = .{ .length = @intCast(bytes.len) };
        @memcpy(result.bytes[0..bytes.len], bytes);
        return result;
    }

    fn putInitial(self: *Volatile, key: []const u8, value: []const u8) !void {
        const k = try self.storageKey(key);
        const v = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(v);
        try self.rows.put(self.allocator, k, v);
        self.stored_bytes += key.len + value.len;
    }

    comptime {
        core.backend.checkEngine(@This());
    }
};

const Key = struct {
    bytes: [core.max_key_bytes]u8 = @splat(0),
    length: u8,
    fn slice(self: *const Key) []const u8 {
        return self.bytes[0..self.length];
    }
};
const Entry = struct { key: Key, value: ?[]u8 };
/// The first row under `prefix` after `after`, with `entries` (a write
/// transaction's own puts and removes) taking precedence over the rows.
fn nextRow(store: *Volatile, entries: []const Entry, prefix: []const u8, after: ?[]const u8) !?core.CollectionRow {
    var found: ?core.CollectionRow = null;
    var it = store.rows.iterator();
    rows: while (it.next()) |row| {
        for (entries) |*entry| if (std.meta.eql(entry.key, row.key_ptr.*)) {
            if (entry.value) |value| consider(&found, prefix, after, .{ .key = entry.key.slice(), .value = value });
            continue :rows;
        };
        consider(&found, prefix, after, .{ .key = row.key_ptr.slice(), .value = row.value_ptr.* });
    }
    for (entries) |*entry| if (entry.value) |value| {
        if (store.rows.get(entry.key) == null) consider(&found, prefix, after, .{ .key = entry.key.slice(), .value = value });
    };
    return found;
}

fn consider(found: *?core.CollectionRow, prefix: []const u8, after: ?[]const u8, row: core.CollectionRow) void {
    if (!std.mem.startsWith(u8, row.key, prefix)) return;
    if (after) |previous| if (std.mem.order(u8, row.key, previous) != .gt) return;
    if (found.* == null or std.mem.order(u8, row.key, found.*.?.key) == .lt) found.* = row;
}
