//! Managed application measurements with structural assertions in smoke mode.
const std = @import("std");
const m = @import("managed.zig");
const w = @import("workload.zig");
const access = @import("glowcap").loam.access;
const metrics = @import("alloc_metrics");
const memory = @import("process_memory.zig");
const r = @import("report.zig");

pub fn run(init: std.process.Init, report: *std.ArrayList(u8), count: usize, depth: u16, smoke: bool, references_only: bool) !void {
    const gpa = init.gpa;
    const io = init.io;
    const path = try std.fmt.allocPrintSentinel(gpa, "zig-out/loam-managed-bench-{d}-{d}-{d}", .{ r.now(io), count, depth }, 0);
    defer gpa.free(path);
    try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch unreachable;
    var db = try w.Lmdb.open(path, .{ .opening = .{ .id = @fromBackingInt(73), .mode = .create } });
    defer db.close() catch unreachable;
    var bytes: metrics.LiveBytesAllocator = .{ .backing = gpa };
    var allocations: metrics.CountingAllocator = .{ .backing = bytes.allocator() };
    population: {
        var workload: m.Managed = undefined;
        try workload.init(allocations.allocator(), &db, count, depth);
        defer workload.deinit();
        try r.emit(gpa, report, "managed_limits resources={d} ancestry={d} cache_slots={d} resident_limit_bytes={d} record_capacity={d} max_calls=8 pending_limit_bytes={d}\n", .{
            count, depth, m.cache_slots, workload.store.limits.resident_bytes, m.record_capacity, workload.attachment.options.pending_bytes,
        });
        try r.emit(gpa, report, "managed_store_limits max_record_bytes={d} max_edges={d} max_leases={d} max_retentions={d} max_collection_roots={d} max_changes={d} staging_limit_bytes={d}\n", .{
            workload.store.limits.records.max_record_bytes, workload.store.limits.records.max_edges, workload.store.limits.max_leases, workload.store.limits.max_retentions, workload.store.limits.max_collection_roots, workload.store.limits.max_changes, workload.store.limits.staging_bytes,
        });
        for ([_][]const u8{ "create", "share" }) |phase| {
            const reads = workload.reads;
            const writes = workload.writes;
            const allocs = allocations.allocs;
            var timings: r.Samples = .{};
            const start = r.now(io);
            for (0..count) |i| {
                const sample = r.now(io);
                if (std.mem.eql(u8, phase, "create")) try workload.create(i) else try workload.share(i);
                timings.add(r.elapsed(io, sample));
            }
            try row(gpa, report, &workload, phase, depth, count, reads, writes, allocs, &allocations, &bytes, r.elapsed(io, start), &timings);
        }
        {
            var read: access.storage.Read = undefined;
            try read.init(workload.allocator, &workload.store, workload.owner, 1, null);
            defer read.deinit() catch unreachable;
            read.history_requested = true;
            try @import("managed_setup.zig").pump(&workload, &read);
            if (read.history.count > access.records.ChangeHistoryRecord.capacity) return error.UnboundedManagedHistory;
            try r.emit(gpa, report, "managed_history resources={d} ancestry={d} retained_batches={d} batch_limit={d} effect_limit={d} path_limit={d}\n", .{ count, depth, read.history.count, access.records.ChangeHistoryRecord.capacity, access.records.ChangeBatchRecord.max_effects, access.records.ChangeBatchRecord.max_path });
        }
        workload.store.evict();
        try r.emit(gpa, report, "managed_footprint resources={d} ancestry={d} objects={d} record_bytes={d} cold_zig_heap_bytes={d} resident_bytes={d}\n", .{
            count, depth, workload.store.metadata.objects, workload.store.metadata.record_bytes, bytes.liveBytes(), workload.store.cache.allocated_bytes,
        });
        try memory.emit(gpa, report, "managed-cold", count, depth);
        if (workload.store.cache.allocated_bytes != 0) return error.EagerResidency;
        try @import("managed_references.zig").run(init, report, &workload, depth, smoke, &allocations, &bytes);
        try @import("managed_retention.zig").run(init, report, &workload, depth, smoke, &allocations, &bytes);
        if (references_only) break :population;
        try @import("managed_controls.zig").run(init, report, &workload, depth, smoke, &allocations, &bytes);
        const samples = if (smoke) @as(usize, 8) else 128;
        for ([_][]const u8{ "hot", "cold", "thrash", "edit-unrelated-read", "revoke" }) |phase| {
            for (0..4) |i| try (try workload.call(i, "read")).requireNumber(if (i == 0 and std.mem.eql(u8, phase, "revoke")) @intCast(samples) else 0);
            const reads = workload.reads;
            const writes = workload.writes;
            const allocs = allocations.allocs;
            var timings: r.Samples = .{};
            var calls: usize = 0;
            var mutation_reads: u64 = 0;
            const start = r.now(io);
            for (0..samples) |i| {
                if (std.mem.eql(u8, phase, "cold")) workload.store.evict();
                const sample = r.now(io);
                if (std.mem.eql(u8, phase, "edit-unrelated-read")) {
                    const before_edit = workload.reads;
                    try (try workload.call(0, "edit")).requireNumber(@intCast(i + 1));
                    mutation_reads += workload.reads - before_edit;
                    const before_siblings = workload.reads;
                    for (1..4) |j| try (try workload.call(j, "read")).requireNumber(0);
                    if (workload.reads != before_siblings) return error.UnnecessaryManagedReload;
                    calls += 4;
                } else if (std.mem.eql(u8, phase, "revoke")) {
                    // Check both content permissions and an unaffected sibling.
                    // Each measured group commits one grant edit and event.
                    const target = i % count;
                    try (try workload.call(target, "revoke")).requireChanged();
                    try (try workload.call(target, "read")).requireRevoked();
                    try (try workload.call(target, "edit")).requireRevoked();
                    calls += 3;
                    if (target + 1 < count) {
                        try (try workload.call(target + 1, "read")).requireNumber(0);
                        calls += 1;
                    }
                    // Do not revoke the same grant twice in smaller populations.
                    if (i + 1 == count) {
                        timings.add(r.elapsed(io, sample));
                        break;
                    }
                } else {
                    const index = if (std.mem.eql(u8, phase, "thrash")) i % count else i % 4;
                    try (try workload.call(index, "read")).requireNumber(0);
                    calls += 1;
                }
                timings.add(r.elapsed(io, sample));
            }
            try row(gpa, report, &workload, phase, depth, calls, reads, writes, allocs, &allocations, &bytes, r.elapsed(io, start), &timings);
            if (std.mem.eql(u8, phase, "hot") and workload.reads != reads) return error.UnnecessaryManagedReload;
            if (std.mem.eql(u8, phase, "edit-unrelated-read")) {
                // Read-only warming does not load history. Only the first edit
                // may load its root; later edits use the adopted committed row.
                if (mutation_reads > 1) return error.ManagedHistoryReadBudget;
                try r.emit(gpa, report, "managed_edit_reads resources={d} ancestry={d} mutation_reads={d} sibling_reads=0\n", .{ count, depth, mutation_reads });
            }
            if (std.mem.eql(u8, phase, "cold")) {
                const cold_reads = workload.reads - reads;
                if (cold_reads == 0) return error.MissingColdManagedReads;
                // Four fixed directory levels per index plus the bounded
                // resource/grant paths. Population growth must not add scans.
                if (cold_reads > samples * (16 + 2 * @as(usize, depth))) return error.ManagedReadBudget;
            }
            const mutating = std.mem.eql(u8, phase, "edit-unrelated-read") or std.mem.eql(u8, phase, "revoke");
            if (workload.writes - writes != (if (mutating) timings.count else @as(usize, 0))) return error.InvalidManagedWrites;
        }
        try @import("managed_resources.zig").run(init, report, &workload, depth, smoke, &allocations, &bytes);
        try @import("managed_observation.zig").run(init, report, &workload, depth, smoke, &allocations, &bytes);
        try @import("managed_retirement.zig").run(init, report, &workload, depth, &allocations, &bytes);
        const stat = try db.inspect();
        try r.emit(gpa, report, "managed_physical resources={d} ancestry={d} map_bytes={d} high_water_bytes={d} tree_bytes={d} entries={d}\n", .{
            count, depth, stat.map_bytes, stat.high_water_bytes, stat.tree_pages * stat.page_bytes, stat.entries,
        });
    }
    if (bytes.live != 0) return error.LeakedManagedZigMemory;
}

fn row(gpa: std.mem.Allocator, report: *std.ArrayList(u8), workload: *m.Managed, phase: []const u8, depth: u16, calls: usize, reads: u64, writes: u64, allocs: usize, allocations: *metrics.CountingAllocator, bytes: *metrics.LiveBytesAllocator, elapsed_ns: u64, timings: *r.Samples) !void {
    try memory.emit(gpa, report, phase, workload.items.len, depth);
    const latency = timings.summarize();
    try r.emit(gpa, report, "managed phase={s} resources={d} ancestry={d} ops={d} groups={d} reads={d} writes={d} allocs={d} elapsed_ns={d} ops_per_second={d} p50_ns={d} p99_ns={d} live_zig_heap_bytes={d} resident_bytes={d}\n", .{
        phase, workload.items.len, depth, calls, timings.count, workload.reads - reads, workload.writes - writes, allocations.allocs - allocs, elapsed_ns, @as(u128, calls) * std.time.ns_per_s / @max(1, elapsed_ns), latency.p50_ns, latency.p99_ns, bytes.liveBytes(), workload.store.cache.allocated_bytes,
    });
}
