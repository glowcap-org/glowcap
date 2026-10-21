//! Managed calls use the same persistent worker pool as ordinary actors.
const std = @import("std");
const m = @import("managed.zig");
const w = @import("workload.zig");
const workers = @import("worker_pool.zig");
const calls = @import("sustained_calls.zig");
const r = @import("report.zig");
const memory = @import("process_memory.zig");
const metrics = @import("alloc_metrics");

pub fn run(init: std.process.Init, report: *std.ArrayList(u8), count: usize, depth: u16, smoke: bool) !void {
    const path = try std.fmt.allocPrintSentinel(init.gpa, "zig-out/loam-managed-workers-{d}", .{r.now(init.io)}, 0);
    defer init.gpa.free(path);
    try std.Io.Dir.cwd().createDir(init.io, path, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(init.io, path) catch unreachable;
    var db = try w.Lmdb.open(path, .{ .opening = .{ .id = @fromBackingInt(75), .mode = .create } });
    var opened = true;
    defer if (opened) db.close() catch unreachable;
    var bytes: metrics.LiveBytesAllocator = .{ .backing = init.gpa };
    var allocations: metrics.CountingAllocator = .{ .backing = bytes.allocator() };
    var metadata: w.core.Metadata = undefined;
    {
        var workload: m.Managed = undefined;
        try workload.init(allocations.allocator(), &db, count, depth);
        defer workload.deinit();
        for (0..count) |i| {
            try workload.create(i);
            try workload.share(i);
        }
        workload.store.evict();
        try memory.emit(init.gpa, report, "managed-worker-startup", count, depth);
        try r.emit(init.gpa, report, "managed_worker_limits resources={d} ancestry={d} cache_slots={d} resident_limit_bytes={d} max_leases={d} call_bytes={d} pending_limit_bytes={d} startup_zig_heap_bytes={d}\n", .{ count, depth, m.cache_slots, workload.store.limits.resident_bytes, workload.store.limits.max_leases, workload.attachment.options.call_bytes, workload.attachment.options.pending_bytes, bytes.liveBytes() });
        var threaded = std.Io.Threaded.init(init.gpa, .{ .concurrent_limit = .limited(workers.capacity) });
        defer threaded.deinit();
        var pool: workers.Pool = .{ .io = threaded.io() };
        try pool.start();
        defer {
            pool.drain(&workload);
            pool.stop();
        }
        try calls.calibrateManaged(&workload, &pool);
        try calls.run(init, report, &workload, &pool, if (smoke) 64 else 1024, "managed", count, depth, &allocations, &bytes);
        metadata = workload.store.metadata;
    }
    if (bytes.live != 0) return error.LeakedManagedWorkerMemory;
    const before = try db.inspect();
    const start = r.now(init.io);
    try db.compact();
    const elapsed_ns = r.elapsed(init.io, start);
    // Replacement retires the old environment. Inspect only the newly opened status-allow: replacement state identity
    // writer after installation, never the closed pre-compaction owner.
    try db.close();
    opened = false;
    db = try w.Lmdb.open(path, .{ .opening = .{ .id = @fromBackingInt(75), .mode = .open } });
    opened = true;
    const after = try db.inspect();
    if (!std.meta.eql(try metadata.claim(), db.metadata) or before.entries != after.entries) return error.CompactionChangedRecords;
    try r.emit(init.gpa, report, "managed_compaction resources={d} ancestry={d} entries={d} before_high_water_bytes={d} after_high_water_bytes={d} before_tree_bytes={d} after_tree_bytes={d} elapsed_ns={d}\n", .{ count, depth, after.entries, before.high_water_bytes, after.high_water_bytes, before.tree_pages * before.page_bytes, after.tree_pages * after.page_bytes, elapsed_ns });
    try memory.emit(init.gpa, report, "managed-compacted", count, depth);
}
