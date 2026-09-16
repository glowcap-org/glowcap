//! Compile a complete record/lease path with caller-owned memory and no host I/O.
const std = @import("std");
const loam = @import("loam");

export fn exercise() u32 {
    run() catch return 1;
    return 0;
}

fn run() !void {
    var memory: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    const allocator = fixed.allocator();
    var backend = try loam.Volatile.init(allocator, @fromBackingInt(1), 8192);
    defer backend.deinit();
    const schemas = [_]loam.core.Schema{.{ .id = 1, .version = 1, .max_payload = 32, .max_edges = 1 }};
    var store = try loam.core.Store.init(allocator, try backend.open(), &schemas, .{
        .records = .{ .max_record_bytes = 512, .max_edges = 1 },
        .cache_slots = 1,
        .max_leases = 1,
        .resident_bytes = 512,
        .max_changes = 1,
        .staging_bytes = 512,
    });
    defer store.deinit() catch unreachable;
    try store.begin();
    const id = try store.allocateId();
    try store.putCopying(.{ .id = id, .revision = 0, .schema = 1, .payload = "portable", .rooted = true, .edges = &.{.{ .target = id }} }, null);
    const ticket = try store.prepare();
    const outcome = backend.commit(try store.beginWrite(ticket));
    try store.completeWrite(ticket, outcome);
    if (outcome != .committed) return error.CommitFailed;
    const read = (try store.acquire(id)).read;
    try store.completeRead(read.ticket, backend.read(read));
    const lease = (try store.acquire(id)).ready;
    const view = try store.view(lease);
    if (!std.mem.eql(u8, view.payload, "portable")) return error.WrongPayload;
    try store.release(lease);
    store.evict();
    const retained = try store.retain(id);
    const collection_ticket = try store.prepareCollection(64);
    const collected = backend.commit(try store.beginWrite(collection_ticket));
    try store.completeWrite(collection_ticket, collected);
    if (collected != .committed or store.metadata.collection.phase != .idle) return error.CollectionFailed;
    try store.releaseRetention(retained);
    if (store.metadata.objects != 1) return error.LostRoot;
}
