//! Portable C executor scenarios. Zig transactions decide atomicity, fencing
//! and exact recovery; this bounded test KV only supplies physical snapshots.
const std = @import("std");
const c = @import("c_abi_loam");
const core = @import("loam_core");
const shared = @import("c_abi_shared");
const allocator = std.testing.allocator;
const Kv = struct {
    const Row = struct { key: []u8, value: []u8 };
    rows: std.ArrayList(Row) = .empty,
    writes: std.ArrayList(Row) = .empty,
    loaded: bool = true,
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
    fn commit(self: *Kv) !void {
        try self.rows.ensureUnusedCapacity(allocator, self.writes.items.len);
        for (self.writes.items) |write| {
            const slot = for (self.rows.items) |*row| {
                if (std.mem.eql(u8, row.key, write.key)) break row;
            } else null;
            if (slot) |row| {
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
        if (op == 1) {
            self.put(name, value.?.data.?[0..value.?.len]) catch return shared.GLOWCAP_ERR_INTERNAL;
            return shared.GLOWCAP_OK;
        }
        if (op != 0) return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
        if (!self.loaded) return shared.GLOWCAP_ERR_WOULD_BLOCK;
        var i = self.writes.items.len;
        while (i != 0) {
            i -= 1;
            const row = self.writes.items[i];
            if (std.mem.eql(u8, row.key, name)) {
                out.?.* = .{ .data = row.value.ptr, .len = row.value.len, .present = 1 };
                return shared.GLOWCAP_OK;
            }
        }
        for (self.rows.items) |row| if (std.mem.eql(u8, row.key, name)) {
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
