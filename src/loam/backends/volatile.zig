//! Volatile realization of Loam batches. Storage bytes live in RAM and have a
//! separate capacity from the core's resident cache; no durability is implied.
const std = @import("std");
const core = @import("loam_core");

pub const Volatile = struct {
    allocator: std.mem.Allocator,
    rows: std.AutoHashMapUnmanaged(Key, []u8) = .empty,
    metadata: core.Metadata,
    max_bytes: usize,
    stored_bytes: usize = 0,
    opened: bool = false,

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
        return next;
    }

    /// The embedding first retires its Store and all backend work.
    pub fn close(self: *Volatile) void {
        self.opened = false;
    }

    pub fn read(self: *Volatile, request: core.Read) core.ReadResult {
        if (!self.opened or !matches(self.metadata, request.ticket)) return .{ .failed = error.StaleCompletion };
        const key = self.storageKey(&request.id.key()) catch |err| return .{ .failed = err };
        const bytes = self.rows.get(key) orelse return .missing;
        if (bytes.len > request.buffer.len) return .{ .failed = error.RecordTooLarge };
        @memcpy(request.buffer[0..bytes.len], bytes);
        return .{ .found = .{ .length = bytes.len, .metadata = self.metadata } };
    }

    pub fn commit(self: *Volatile, batch: core.Batch) core.Outcome {
        const next = self.commitBatch(batch) catch |err| return .{ .unchanged = err };
        return .{ .committed = next };
    }

    pub fn recover(self: *Volatile, batch: core.Batch) !core.Resolution {
        return batch.resolve(self.metadata);
    }

    fn commitBatch(self: *Volatile, batch: core.Batch) !core.Metadata {
        if (!self.opened) return error.Closed;
        var overlay: Overlay = .{ .store = self };
        defer overlay.deinit();
        const next = try batch.apply(&overlay);
        var stored_bytes = self.stored_bytes;
        for (overlay.entries.items) |entry| {
            if (self.rows.get(entry.key)) |old| stored_bytes -= entry.key.length + old.len;
            if (entry.value) |bytes| stored_bytes = try std.math.add(usize, stored_bytes, entry.key.length + bytes.len);
        }
        if (stored_bytes > self.max_bytes) return error.StorageCapacity;
        try self.rows.ensureUnusedCapacity(self.allocator, @intCast(overlay.entries.items.len));
        for (overlay.entries.items) |*entry| {
            if (entry.value) |value| {
                const result = self.rows.getOrPutAssumeCapacity(entry.key);
                if (result.found_existing) {
                    self.allocator.free(result.value_ptr.*);
                }
                result.value_ptr.* = value;
            } else {
                if (self.rows.fetchRemove(entry.key)) |removed| self.allocator.free(removed.value);
            }
            entry.value = null;
        }
        self.metadata = next;
        self.stored_bytes = stored_bytes;
        return next;
    }

    fn storageKey(self: *Volatile, bytes: []const u8) !Key {
        _ = self;
        if (bytes.len == 0 or bytes.len > 35) return error.Corrupt;
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
};

const Key = struct {
    bytes: [35]u8 = @splat(0),
    length: u8,
    fn slice(self: *const Key) []const u8 {
        return self.bytes[0..self.length];
    }
};
const Entry = struct { key: Key, value: ?[]u8 };
const Overlay = struct {
    store: *Volatile,
    entries: std.ArrayList(Entry) = .empty,

    pub fn get(self: *Overlay, key: []const u8) !?[]const u8 {
        const k = try self.store.storageKey(key);
        for (self.entries.items) |entry| if (std.meta.eql(entry.key, k)) return entry.value;
        return self.store.rows.get(k);
    }

    pub fn next(self: *Overlay, prefix: []const u8, after: ?[]const u8) !?core.CollectionRow {
        var found: ?core.CollectionRow = null;
        var it = self.store.rows.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.slice();
            if (try self.get(key)) |value| consider(&found, prefix, after, .{ .key = key, .value = value });
        }
        for (self.entries.items) |*entry| if (entry.value) |value| {
            consider(&found, prefix, after, .{ .key = entry.key.slice(), .value = value });
        };
        return found;
    }

    pub fn put(self: *Overlay, key: []const u8, value: []const u8) !void {
        const bytes = try self.store.allocator.dupe(u8, value);
        errdefer self.store.allocator.free(bytes);
        try self.append(key, bytes);
    }

    pub fn remove(self: *Overlay, key: []const u8) !void {
        try self.append(key, null);
    }

    fn append(self: *Overlay, key: []const u8, value: ?[]u8) !void {
        const k = try self.store.storageKey(key);
        for (self.entries.items) |*entry| if (std.meta.eql(entry.key, k)) {
            if (entry.value) |old| self.store.allocator.free(old);
            entry.value = value;
            return;
        };
        try self.entries.append(self.store.allocator, .{ .key = k, .value = value });
    }

    fn deinit(self: *Overlay) void {
        for (self.entries.items) |entry| {
            if (entry.value) |bytes| self.store.allocator.free(bytes);
        }
        self.entries.deinit(self.store.allocator);
    }
};

fn consider(found: *?core.CollectionRow, prefix: []const u8, after: ?[]const u8, row: core.CollectionRow) void {
    if (!std.mem.startsWith(u8, row.key, prefix)) return;
    if (after) |previous| if (std.mem.order(u8, row.key, previous) != .gt) return;
    if (found.* == null or std.mem.order(u8, row.key, found.*.?.key) == .lt) found.* = row;
}

fn matches(meta: core.Metadata, ticket: core.Ticket) bool {
    return meta.store == ticket.store and meta.incarnation == ticket.incarnation and meta.revision == ticket.revision;
}
