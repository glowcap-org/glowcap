//! Structural records reject corrupt, truncated, oversized, and unknown schemas
//! before exposing a borrowed view. Encoding allocates only its measured bytes.
//! Defect probes removed record/metadata checksum validation, the short-envelope
//! guard, and the volatile overlay's allocation unwind; each was detected.
//! Exhaustive prefixes and metadata bit flips cover these fixtures, not arbitrary
//! syntax or physical storage faults. Allocation enumeration covers the exercised
//! create/read/update path, not every graph shape or native LMDB allocation.
const std = @import("std");
const loam = @import("glowcap").loam;
const f = @import("fixture.zig");

test "loam records round trip bounded edges and reject every truncated envelope" {
    const id: f.core.ObjectId = .{ .store = f.id, .incarnation = 1, .sequence = 9 };
    var record = f.record(id, "payload past the identity field");
    record.revision = 1;
    record.edges = &.{ .{ .target = id }, .{ .target = id, .restoration = .recipe } };
    const bytes = try record.encodeAlloc(std.testing.allocator, f.limits.records, &f.schemas);
    defer std.testing.allocator.free(bytes);
    const decoded = try loam.records.View.decode(bytes, f.limits.records, &f.schemas);
    try std.testing.expectEqualStrings(record.payload, decoded.payload);
    var edges = decoded.edges();
    try std.testing.expect(edges.next().?.target.eql(id));
    try std.testing.expectEqualDeep(record.edges[1], edges.next().?);
    for (0..bytes.len) |length| {
        if (loam.records.View.decode(bytes[0..length], f.limits.records, &f.schemas)) |_| return error.AcceptedTruncation else |_| {}
    }
    bytes[bytes.len - 1] ^= 1;
    try std.testing.expectError(error.Corrupt, loam.records.View.decode(bytes, f.limits.records, &f.schemas));
    bytes[bytes.len - 1] ^= 1;
    try std.testing.expectError(error.UnsupportedSchema, loam.records.View.decode(bytes, f.limits.records, &.{}));
    const small_schema = [_]f.core.Schema{.{ .id = 7, .version = 1, .max_payload = 2, .max_edges = 8 }};
    try std.testing.expectError(error.RecordTooLarge, loam.records.View.decode(bytes, f.limits.records, &small_schema));
    const kind_offset = @intFromPtr(decoded.edge_bytes.ptr) - @intFromPtr(bytes.ptr) + decoded.edge_bytes.len - 1;
    bytes[kind_offset] = 'x';
    // A valid checksum cannot make an unknown restoration kind acceptable.
    std.mem.writeInt(u32, bytes[bytes.len - 4 ..][0..4], std.hash.Crc32.hash(bytes[0 .. bytes.len - 4]), .big);
    try std.testing.expectError(error.Corrupt, loam.records.View.decode(bytes, f.limits.records, &f.schemas));
}

test "loam encoding refuses oversized records before allocating and uses one allocation" {
    var fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const id: f.core.ObjectId = .{ .store = f.id, .incarnation = 1, .sequence = 1 };
    var record = f.record(id, "bounded");
    record.revision = 1;
    var limits = f.limits.records;
    limits.max_record_bytes = 8;
    try std.testing.expectError(error.RecordTooLarge, record.encodeAlloc(fail.allocator(), limits, &f.schemas));
    try std.testing.expect(!fail.has_induced_failure);
    fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const bytes = try record.encodeAlloc(fail.allocator(), f.limits.records, &f.schemas);
    defer fail.allocator().free(bytes);
    try std.testing.expect(!fail.has_induced_failure);
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    var fixture = try f.Fixture.init(allocator);
    defer fixture.deinit();
    const store = &fixture.store;
    errdefer if (store.phase == .staging or store.phase == .prepared) store.abort() catch unreachable;
    try store.begin();
    const id = try store.allocateId();
    var payload = [_]u8{ 'o', 'l', 'd' };
    try store.putCopying(f.record(id, &payload), null);
    @memset(&payload, 'x');
    try f.commit(store, &fixture.backend);
    const lease = try f.load(store, &fixture.backend, id);
    try std.testing.expectEqualStrings("old", (try store.view(lease)).payload);
    try store.release(lease);
    try store.begin();
    try store.putCopying(f.record(id, "new"), 1);
    f.commit(store, &fixture.backend) catch |err| {
        try std.testing.expectEqual(@as(u64, 1), store.metadata.revision);
        return err;
    };
    store.evict();
    const next = try f.load(store, &fixture.backend, id);
    defer store.release(next) catch unreachable;
    try std.testing.expectEqualStrings("new", (try store.view(next)).payload);
}

test "loam allocation failure unwinds staging backend writes and cache loads" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}

test "loam metadata detects corruption and refuses incarnation wrap" {
    var metadata: f.core.Metadata = .{ .store = f.id };
    const encoded = metadata.encode();
    try std.testing.expectEqualDeep(metadata, try f.core.Metadata.decode(&encoded));
    var old = encoded;
    old[7] = 2;
    std.mem.writeInt(u32, old[170..174], std.hash.Crc32.hash(old[0..170]), .big);
    try std.testing.expectError(error.Corrupt, f.core.Metadata.decode(&old));
    for (0..encoded.len) |i| {
        var bad = encoded;
        bad[i] ^= 1;
        try std.testing.expectError(error.Corrupt, f.core.Metadata.decode(&bad));
    }
    metadata.incarnation = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, metadata.claim());
}
