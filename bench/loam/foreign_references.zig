//! Checked foreign fields restore through Host and call durable actors.
//! Byte-fed sessions measure protocol/storage cost without a network delay.
const std = @import("std");
const g = @import("glowcap");
const m = @import("managed.zig");
const w = @import("workload.zig");
const Pair = @import("host_pair.zig").Pair;
const metrics = @import("alloc_metrics");
const r = @import("report.zig");
const memory = @import("process_memory.zig");
const refs = g.loam.hosting.references;
const designator = "127.0.0.1:9794";

fn callAllowance() !usize {
    var bound = try refs.allocationBound(1, 0, refs.schema.max_payload - 1);
    try bound.merge(try m.callAllocationBound());
    return bound.physicalBytes();
}

pub fn run(init: std.process.Init, report: *std.ArrayList(u8), count: usize, depth: u16, smoke: bool) !void {
    const path = try std.fmt.allocPrint(init.gpa, "zig-out/loam-foreign-{d}", .{r.now(init.io)});
    defer init.gpa.free(path);
    try std.Io.Dir.cwd().createDir(init.io, path, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(init.io, path) catch unreachable;
    const source_path = try std.fmt.allocPrintSentinel(init.gpa, "{s}/source", .{path}, 0);
    defer init.gpa.free(source_path);
    const target_path = try std.fmt.allocPrintSentinel(init.gpa, "{s}/target", .{path}, 0);
    defer init.gpa.free(target_path);
    try std.Io.Dir.cwd().createDir(init.io, source_path, .default_dir);
    try std.Io.Dir.cwd().createDir(init.io, target_path, .default_dir);
    var source_db = try w.Lmdb.open(source_path, .{ .opening = .{ .id = @fromBackingInt(76), .mode = .create } });
    defer source_db.close() catch unreachable;
    var target_db = try w.Lmdb.open(target_path, .{ .opening = .{ .id = @fromBackingInt(77), .mode = .create } });
    defer target_db.close() catch unreachable;
    var bytes: metrics.LiveBytesAllocator = .{ .backing = init.gpa };
    var allocations: metrics.CountingAllocator = .{ .backing = bytes.allocator() };
    const targets: usize = if (smoke) 4 else 32;
    {
        var target: w.Workload = undefined;
        try target.init(allocations.allocator(), &target_db, targets, 256);
        defer target.deinit();
        var source: m.Managed = undefined;
        try source.initIdentity(allocations.allocator(), &source_db, count, depth, 0x87, try callAllowance());
        defer source.deinit();
        for (0..count) |index| {
            try source.create(index);
            try source.share(index);
        }
        try g.loam.hosting.publication.listen(target.attachment, .{ .max_names = targets, .max_fetches = 8 });
        var names: [32]g.driver.core.Host.DurableSwiss = undefined;
        for (names[0..targets], 0..) |*name, index| {
            var entropy: g.driver.core.Host.DurableSwiss.Entropy = @splat(0);
            std.mem.writeInt(u64, entropy[0..8], index + 1, .big);
            try target.store.begin();
            const id = try g.loam.hosting.publication.stageTarget(&target.store, entropy, target.ids[index]);
            try target.finish(try target.store.prepare());
            const lease = try target.load(id);
            defer target.store.release(lease) catch unreachable;
            name.* = try g.loam.hosting.publication.restore(target.attachment, lease);
        }
        var pair = try Pair.open(&source.host, &target.host, designator);
        var connected = true;
        defer if (connected) pair.close();
        for (names[0..targets], 0..) |name, index| try install(&source, &target, &pair, name, index);
        source.store.evict();
        target.store.evict();
        try memory.emit(init.gpa, report, "foreign-startup", count, depth);
        try r.emit(init.gpa, report, "foreign_limits resources={d} ancestry={d} targets={d} source_cache_slots={d} source_max_leases={d} target_cache_slots={d} max_calls=8 call_bytes={d} pending_limit_bytes={d} reply_bytes_each=512 startup_zig_heap_bytes={d} publication_names={d} source_record_bytes={d} target_record_bytes={d}\n", .{ count, depth, targets, m.cache_slots, source.store.limits.max_leases, w.cache_slots, source.attachment.options.call_bytes, source.attachment.options.pending_bytes, bytes.liveBytes(), targets, source.store.metadata.record_bytes, target.store.metadata.record_bytes });
        const samples: usize = if (smoke) 8 else 128;
        for ([_]bool{ false, true }) |fresh| for ([_][]const u8{ "exact", "dependent" }) |phase| {
            const reads = source.reads;
            const target_reads = target.reads;
            const lookups = target.lookups;
            const writes = source.writes + target.writes;
            const allocs = allocations.allocs;
            var frame_count: u64 = 0;
            var frame_bytes: u64 = 0;
            var max_source_reads: u64 = 0;
            var max_target_reads: u64 = 0;
            var timings: r.Samples = .{};
            const start = r.now(init.io);
            for (0..samples) |index| {
                const which = index % targets;
                source.store.evict();
                target.store.evict();
                const sample = r.now(init.io);
                const group_source_reads = source.reads;
                const group_target_reads = target.reads;
                if (fresh) {
                    pair.close();
                    connected = false;
                    // Discovery is cold as well as the record caches. The
                    // rooted publication remains in the engine's name index.
                    target.host.removeDurable(names[which].slice()) catch |err| if (err != error.UnknownPublication) return err;
                    pair = try Pair.open(&source.host, &target.host, designator);
                    connected = true;
                }
                const frames = if (fresh) 0 else pair.frames;
                const sent_bytes = if (fresh) 0 else pair.frame_bytes;
                const returned = try source.host.callCapability(source.allocator, pair.session, source.items[which].use, phase, &.{}, 512);
                defer returned.deinit();
                try pair.drain(&source, @as(?*w.Workload, &target));
                if (returned.result() != .ready or returned.result().ready != .capability) {
                    std.debug.print("foreign authority phase={s} session_fresh={any} result={any}\n", .{ phase, fresh, returned.result() });
                    return error.MissingForeignAuthority;
                }
                const called = try source.host.callCapability(source.allocator, pair.session, returned.result().ready.capability, "read", &.{}, 512);
                defer called.deinit();
                try pair.drain(&source, @as(?*w.Workload, &target));
                if (called.result() != .ready or called.result().ready != .integer or called.result().ready.integer != 0) {
                    std.debug.print("foreign call phase={s} session_fresh={any} result={any}\n", .{ phase, fresh, called.result() });
                    return error.InvalidForeignReply;
                }
                frame_count += pair.frames - frames;
                frame_bytes += pair.frame_bytes - sent_bytes;
                max_source_reads = @max(max_source_reads, source.reads - group_source_reads);
                max_target_reads = @max(max_target_reads, target.reads - group_target_reads);
                timings.add(r.elapsed(init.io, sample));
            }
            const before_cleanup = source.reads;
            try (try source.call(0, "read")).requireNumber(0);
            try pair.drain(&source, @as(?*w.Workload, &target));
            if (source.writes + target.writes != writes or source.attachment.dependent_facets != 0) return error.ForeignCustodyGrowth;
            if (target.lookups - lookups != (if (fresh) samples else @as(usize, 0))) return error.ForeignDiscoveryBudget;
            if (max_source_reads > 17 + 2 * @as(usize, depth) or max_target_reads > 2) {
                std.debug.print("foreign read budget phase={s} fresh={any} max_source={d} max_target={d} ancestry={d}\n", .{ phase, fresh, max_source_reads, max_target_reads, depth });
                return error.ForeignReadBudget;
            }
            const latency = timings.summarize();
            const elapsed_ns = r.elapsed(init.io, start);
            try r.emit(init.gpa, report, "foreign_reference phase={s} session={s} resources={d} ancestry={d} targets={d} groups={d} calls={d} source_reads={d} cleanup_reads={d} max_group_source_reads={d} target_reads={d} max_group_target_reads={d} name_lookups={d} writes=0 allocs={d} frames={d} frame_bytes={d} live_zig_heap_bytes={d} elapsed_ns={d} calls_per_second={d} p50_ns={d} p99_ns={d}\n", .{ phase, if (fresh) "fresh" else "established", count, depth, targets, samples, samples * 2 + 1, source.reads - reads, source.reads - before_cleanup, max_source_reads, target.reads - target_reads, max_target_reads, target.lookups - lookups, allocations.allocs - allocs, frame_count, frame_bytes, bytes.liveBytes(), elapsed_ns, @as(u128, samples * 2 + 1) * std.time.ns_per_s / @max(1, elapsed_ns), latency.p50_ns, latency.p99_ns });
            try memory.emit(init.gpa, report, "foreign-restored", count, depth);
        };
    }
    if (bytes.live != 0) return error.LeakedForeignMemory;
}

fn install(source: *m.Managed, target: *w.Workload, pair: *Pair, name: g.driver.core.Host.DurableSwiss, index: usize) !void {
    const locator: g.ocapn.model.PeerLocator = .{ .transport = "tcp", .designator = designator, .hints = g.ocapn.model.Hints.emptyFalse() };
    const fetched = try source.host.enlivenCapability(source.allocator, .{ .peer = locator, .swissnum = name.slice() });
    defer fetched.deinit();
    try pair.drain(source, @as(?*w.Workload, target));
    const uri = try g.ocapn.model.uri.writeSturdyref(source.allocator, .{ .peer = locator, .swissnum = name.slice() });
    defer source.allocator.free(uri);
    const saved = try refs.beginSave(source.attachment, source.allocator, fetched.result().ready.capability, uri);
    defer saved.deinit();
    try pair.drain(source, @as(?*w.Workload, target));
    if (saved.result() != .ready) return error.ForeignSaveFailed;
    const lease = try source.load(source.items[index].content);
    defer source.store.release(lease) catch unreachable;
    const view = try source.store.currentView(lease);
    var call_memory: g.loam.hosting.Call.Memory = undefined;
    call_memory.init(source.allocator, 1024 * 1024);
    defer call_memory.deinit();
    var call: g.loam.hosting.Call = .{ .attachment = source.attachment, .memory = &call_memory, .view = view };
    defer call.release();
    const replacement = try refs.copySaved(&call, saved);
    try source.store.begin();
    errdefer if (source.store.phase == .staging) source.store.abort() catch unreachable;
    const edge = try replacement.saved.stage(&source.store);
    try source.store.putCopying(.{ .id = view.id, .revision = 0, .schema = view.schema, .payload = view.payload, .edges = &.{edge} }, view.revision);
    try source.finish(try source.store.prepare());
}
