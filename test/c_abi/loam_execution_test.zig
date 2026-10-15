//! Portable C executor scenarios. Zig transactions decide atomicity, fencing
//! and exact recovery. This bounded test KV only supplies physical snapshots.
const std = @import("std");
const c = @import("c_abi_loam");
const core = @import("loam_core");
const shared = @import("c_abi_shared");
const allocator = std.testing.allocator;
const Kv = struct {
    const Row = struct { key: []u8, value: []u8, removed: bool = false };
    rows: std.ArrayList(Row) = .empty,
    writes: std.ArrayList(Row) = .empty,
    loaded: bool = true,
    yield_reads: bool = false,
    pending_key: [core.max_key_bytes]u8 = undefined,
    pending_len: ?usize = null,
    next_key: [core.max_key_bytes]u8 = undefined,
    next_len: ?usize = null,
    suspensions: usize = 0,
    reentrant_store: ?*c.GlowcapLoamStore = null,
    reentries: usize = 0,
    independent_thread_checked: bool = false,
    const WorkerProbe = struct {
        store: *c.GlowcapLoamStore,
        admitted: bool = false,
        fn run(self: *WorkerProbe) void {
            _ = c.embedding.store(self.store) catch return;
            self.admitted = true;
        }
    };
    fn deinit(self: *Kv) void {
        self.clearWrites();
        self.writes.deinit(allocator);
        for (self.rows.items) |row| {
            allocator.free(row.key);
            allocator.free(row.value);
        }
        self.rows.deinit(allocator);
    }
    fn clearWrites(self: *Kv) void {
        for (self.writes.items) |row| {
            allocator.free(row.key);
            allocator.free(row.value);
        }
        self.writes.clearRetainingCapacity();
    }
    fn put(self: *Kv, key: []const u8, value: []const u8) !void {
        const k = try allocator.dupe(u8, key);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, value);
        errdefer allocator.free(v);
        try self.writes.append(allocator, .{ .key = k, .value = v });
    }
    fn remove(self: *Kv, key: []const u8) !void {
        const k = try allocator.dupe(u8, key);
        errdefer allocator.free(k);
        const v = try allocator.alloc(u8, 0);
        errdefer allocator.free(v);
        try self.writes.append(allocator, .{ .key = k, .value = v, .removed = true });
    }
    /// The newest pending or committed row for a key, tombstones included.
    fn find(self: *Kv, key: []const u8) ?Row {
        var i = self.writes.items.len;
        while (i != 0) {
            i -= 1;
            if (std.mem.eql(u8, self.writes.items[i].key, key)) return self.writes.items[i];
        }
        for (self.rows.items) |row| if (std.mem.eql(u8, row.key, key)) return row;
        return null;
    }
    fn smallestAfter(self: *Kv, prefix: []const u8, after: ?[]const u8) ?[]const u8 {
        var best: ?[]const u8 = null;
        for ([_][]const Row{ self.rows.items, self.writes.items }) |group| for (group) |row| {
            if (!std.mem.startsWith(u8, row.key, prefix)) continue;
            if (after) |floor| if (std.mem.order(u8, row.key, floor) != .gt) continue;
            if (best) |b| if (std.mem.order(u8, row.key, b) != .lt) continue;
            if (self.find(row.key).?.removed) continue;
            best = row.key;
        };
        return best;
    }
    fn commit(self: *Kv) !void {
        try self.rows.ensureUnusedCapacity(allocator, self.writes.items.len);
        for (self.writes.items) |write| {
            const slot = for (self.rows.items) |*row| {
                if (std.mem.eql(u8, row.key, write.key)) break row;
            } else null;
            if (write.removed) {
                if (slot) |row| {
                    allocator.free(row.key);
                    allocator.free(row.value);
                    row.* = self.rows.pop().?;
                }
                allocator.free(write.key);
                allocator.free(write.value);
            } else if (slot) |row| {
                allocator.free(row.key);
                allocator.free(row.value);
                row.* = write;
            } else self.rows.appendAssumeCapacity(write);
        }
        self.writes.clearRetainingCapacity();
    }
    fn callback(context: ?*anyopaque, op: u32, key: ?[*]const u8, len: usize, value: ?*const c.GlowcapLoamBytes, out: ?*c.GlowcapLoamBytes) callconv(.c) i32 {
        const self: *Kv = @ptrCast(@alignCast(context.?));
        const name = key.?[0..len];
        if (self.reentrant_store) |store| {
            if (!self.independent_thread_checked) {
                var probe: WorkerProbe = .{ .store = store };
                const worker = std.Thread.spawn(.{}, WorkerProbe.run, .{&probe}) catch return shared.GLOWCAP_ERR_INTERNAL;
                worker.join();
                if (!probe.admitted) return shared.GLOWCAP_ERR_INTERNAL;
                self.independent_thread_checked = true;
            }
            if (c.glowcap_loam_store_release(store) != shared.GLOWCAP_ERR_INVALID_ARGUMENT or
                c.glowcap_loam_store_finish(store, 0, 1) != shared.GLOWCAP_ERR_INVALID_ARGUMENT or
                c.glowcap_loam_store_plan(store, 0, Kv.callback, self) != shared.GLOWCAP_ERR_INVALID_ARGUMENT)
                return shared.GLOWCAP_ERR_INTERNAL;
            self.reentries += 1;
        }
        if (op == 1) {
            self.put(name, value.?.data.?[0..value.?.len]) catch return shared.GLOWCAP_ERR_INTERNAL;
            return shared.GLOWCAP_OK;
        }
        if (op == 2) {
            self.remove(name) catch return shared.GLOWCAP_ERR_INTERNAL;
            return shared.GLOWCAP_OK;
        }
        if (op != 0 and op != 3) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
        if (!self.loaded) return shared.GLOWCAP_ERR_WOULD_BLOCK;
        // The get that reads back a key just answered by next is synchronous.
        const read_back = op == 0 and self.next_len != null and std.mem.eql(u8, self.next_key[0..self.next_len.?], name);
        if (op == 0) self.next_len = null;
        if (self.yield_reads and !read_back) {
            if (self.pending_len) |length| {
                if (!std.mem.eql(u8, self.pending_key[0..length], name)) return shared.GLOWCAP_ERR_INTERNAL;
                self.pending_len = null;
            } else {
                @memcpy(self.pending_key[0..len], name);
                self.pending_len = len;
                self.suspensions += 1;
                return shared.GLOWCAP_ERR_WOULD_BLOCK;
            }
        }
        if (op == 3) {
            const floor: ?[]const u8 = if (value.?.present == 1) value.?.data.?[0..value.?.len] else null;
            const found = self.smallestAfter(name, floor) orelse {
                out.?.* = .{};
                return shared.GLOWCAP_OK;
            };
            @memcpy(self.next_key[0..found.len], found);
            self.next_len = found.len;
            out.?.* = .{ .data = &self.next_key, .len = found.len, .present = 1 };
            return shared.GLOWCAP_OK;
        }
        if (self.find(name)) |row| if (!row.removed) {
            out.?.* = .{ .data = row.value.ptr, .len = row.value.len, .present = 1 };
            return shared.GLOWCAP_OK;
        };
        out.?.* = .{};
        return shared.GLOWCAP_OK;
    }
};
test "portable Loam startup suspends without installation and recovers exact terminal outcomes" {
    var kv: Kv = .{};
    defer kv.deinit();
    const id: [16]u8 = @splat(3);
    var metadata: [core.Metadata.encoded_size]u8 = undefined;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_metadata_claim(&id, 1, null, 0, &metadata, metadata.len));
    try kv.put("m", &metadata);
    try kv.commit();
    try std.testing.expect(c.glowcap_loam_metadata_claim(&id, 1, &metadata, metadata.len, &metadata, metadata.len) != shared.GLOWCAP_OK);
    // Only a null pointer denotes absence. A present empty row is corrupted
    // storage, so bootstrap must not initialize it or replace the output.
    const before = metadata;
    try std.testing.expectEqual(c.GLOWCAP_LOAM_ERR_CORRUPT, c.glowcap_loam_metadata_claim(&id, 2, &metadata, 0, &metadata, metadata.len));
    try std.testing.expectEqualSlices(u8, &before, &metadata);
    const limits: c.GlowcapLoamLimits = .{ .resident_bytes = 4 * 1024 * 1024, .staging_bytes = 4 * 1024 * 1024, .cache_slots = 64, .max_leases = 128, .max_changes = 64, .max_references = 128, .max_operations = 32 };
    const schemas = [_]c.GlowcapLoamSchema{.{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 }};
    var store: ?*c.GlowcapLoamStore = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_new(&metadata, metadata.len, &schemas, schemas.len, &limits, &store));
    defer std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_release(store)) catch unreachable;
    const owner = try c.embedding.store(store);
    try owner.value.begin();
    const object = try owner.value.allocateId();
    try owner.value.putCopying(.{ .id = object, .revision = 0, .schema = 7, .payload = "retained", .edges = &.{} }, null);
    kv.loaded = false;
    try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, c.glowcap_loam_store_plan(store, 0, Kv.callback, &kv));
    try std.testing.expectEqual(@as(u64, 0), owner.value.metadata.revision);
    try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, c.glowcap_loam_store_release(store));
    try std.testing.expectEqual(c.GLOWCAP_LOAM_ERR_STALE_COMPLETION, c.glowcap_loam_store_finish(store, 0, 0));
    kv.loaded = true;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_plan(store, 0, Kv.callback, &kv));
    try std.testing.expectEqual(@as(u64, 0), owner.value.metadata.revision);
    try std.testing.expectEqual(@as(usize, 1), kv.rows.items.len);
    try kv.commit();
    try std.testing.expectEqual(c.GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED, c.glowcap_loam_store_finish(store, 0, 2));
    try std.testing.expectEqual(.uncertain, owner.value.phase);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_plan(store, 1, Kv.callback, &kv));
    // An aborted recovery must release its tentative plan, keep the original
    // barrier, and permit a subsequent exact read of the committed receipt.
    try std.testing.expectEqual(c.GLOWCAP_LOAM_ERR_RECOVERY_REQUIRED, c.glowcap_loam_store_finish(store, 1, 1));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_plan(store, 1, Kv.callback, &kv));
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_finish(store, 1, 0));
    try std.testing.expectEqual(@as(u64, 1), owner.value.metadata.revision);
    try std.testing.expect(c.glowcap_loam_store_finish(store, 1, 0) != shared.GLOWCAP_OK);
    try owner.value.begin();
    const refused = try owner.value.allocateId();
    try owner.value.putCopying(.{ .id = refused, .revision = 0, .schema = 7, .payload = "aborted", .edges = &.{} }, null);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_plan(store, 0, Kv.callback, &kv));
    kv.clearWrites();
    try std.testing.expectEqual(c.GLOWCAP_LOAM_ERR_UNCHANGED, c.glowcap_loam_store_finish(store, 0, 1));
    try std.testing.expectEqual(@as(u64, 1), owner.value.metadata.revision);
    try std.testing.expectEqual(.idle, owner.value.phase);
}

test "portable Loam startup preserves emissions across reads and refuses callback reentry" {
    var kv: Kv = .{ .yield_reads = true };
    defer kv.deinit();
    const metadata = (core.Metadata{ .store = @fromBackingInt(3), .incarnation = 1, .collection = .{ .phase = .trace } }).encode();
    try kv.put("m", &metadata);
    try kv.commit();
    const limits: c.GlowcapLoamLimits = .{ .resident_bytes = 4 * 1024 * 1024, .staging_bytes = 4 * 1024 * 1024, .cache_slots = 64, .max_leases = 128, .max_changes = 64, .max_references = 128, .max_operations = 32 };
    const schemas = [_]c.GlowcapLoamSchema{.{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 }};
    var store: ?*c.GlowcapLoamStore = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_new(&metadata, metadata.len, &schemas, schemas.len, &limits, &store));
    defer std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_release(store)) catch unreachable;
    const owner = try c.embedding.store(store);
    try owner.value.begin();
    const object = try owner.value.allocateId();
    try owner.value.putCopying(.{ .id = object, .revision = 0, .schema = 7, .payload = "resumed", .rooted = true }, null);
    kv.reentrant_store = store;
    var suspended_after_emission = false;
    for (0..32) |_| {
        const code = c.glowcap_loam_store_plan(store, 0, Kv.callback, &kv);
        if (code == shared.GLOWCAP_OK) break;
        try std.testing.expectEqual(shared.GLOWCAP_ERR_WOULD_BLOCK, code);
        suspended_after_emission = suspended_after_emission or kv.writes.items.len != 0;
    } else return error.EvaluationDidNotFinish;
    kv.reentrant_store = null;
    try std.testing.expect(suspended_after_emission);
    try std.testing.expect(kv.reentries != 0);
    try std.testing.expect(kv.independent_thread_checked);
    try std.testing.expectEqual(@as(usize, 4), kv.writes.items.len);
    try std.testing.expectEqual(@as(u64, 0), owner.value.metadata.revision);
    try kv.commit();
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_finish(store, 0, 0));
    try std.testing.expectEqual(@as(u64, 1), owner.value.metadata.collection.tail);
    try std.testing.expectEqual(@as(u64, 1), owner.value.metadata.objects);
}

test "portable Loam collects over the callback store with suspended reads and walks" {
    var kv: Kv = .{};
    defer kv.deinit();
    const id: [16]u8 = @splat(5);
    var metadata: [core.Metadata.encoded_size]u8 = undefined;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_metadata_claim(&id, 1, null, 0, &metadata, metadata.len));
    try kv.put("m", &metadata);
    try kv.commit();
    const limits: c.GlowcapLoamLimits = .{ .resident_bytes = 4 * 1024 * 1024, .staging_bytes = 4 * 1024 * 1024, .cache_slots = 64, .max_leases = 128, .max_changes = 64, .max_references = 128, .max_operations = 32 };
    const schemas = [_]c.GlowcapLoamSchema{.{ .id = 7, .version = 1, .max_payload = 256, .max_edges = 8 }};
    var store: ?*c.GlowcapLoamStore = null;
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_new(&metadata, metadata.len, &schemas, schemas.len, &limits, &store));
    defer std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_release(store)) catch unreachable;
    const owner = try c.embedding.store(store);
    try owner.value.begin();
    const kept = try owner.value.allocateId();
    const dropped = try owner.value.allocateId();
    const dropped_too = try owner.value.allocateId();
    const kept_too = try owner.value.allocateId();
    try owner.value.putCopying(.{ .id = kept, .revision = 0, .schema = 7, .payload = "kept", .rooted = true }, null);
    try owner.value.putCopying(.{ .id = dropped, .revision = 0, .schema = 7, .payload = "dropped", .edges = &.{} }, null);
    try owner.value.putCopying(.{ .id = dropped_too, .revision = 0, .schema = 7, .payload = "dropped too", .edges = &.{} }, null);
    try owner.value.putCopying(.{ .id = kept_too, .revision = 0, .schema = 7, .payload = "kept too", .rooted = true }, null);
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_plan(store, 0, Kv.callback, &kv));
    try kv.commit();
    try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_finish(store, 0, 0));
    try std.testing.expectEqual(@as(u64, 4), owner.value.metadata.objects);
    try std.testing.expect(kv.find(&kept.key()) != null and kv.find(&dropped.key()) != null);

    kv.yield_reads = true;
    var collecting: u32 = 1;
    var rounds: usize = 0;
    while (collecting != 0) : (rounds += 1) {
        try std.testing.expect(rounds < 1000);
        const code = c.glowcap_loam_store_collect_plan(store, 2, Kv.callback, &kv);
        if (code == shared.GLOWCAP_ERR_WOULD_BLOCK) continue;
        try std.testing.expectEqual(shared.GLOWCAP_OK, code);
        try kv.commit();
        const finished = c.glowcap_loam_store_finish(store, 0, 0);
        try std.testing.expect(finished == shared.GLOWCAP_OK or finished == c.GLOWCAP_LOAM_ERR_UNCHANGED);
        try std.testing.expectEqual(shared.GLOWCAP_OK, c.glowcap_loam_store_collecting(store, &collecting));
    }
    try std.testing.expect(kv.suspensions > 0);
    try std.testing.expect(kv.find(&dropped.key()) == null and kv.find(&dropped_too.key()) == null);
    try std.testing.expect(kv.find(&kept.key()) != null and kv.find(&kept_too.key()) != null);
    try std.testing.expectEqual(@as(u64, 2), owner.value.metadata.objects);
}
