//! LMDB-backed Loam service and sustained-worker measurements through shipped APIs.
//! Smoke holds reload, coalescing, admission, worker and collection invariants,
//! timing results never impose machine-dependent pass/fail thresholds.
const std = @import("std");
const builtin = @import("builtin");
const w = @import("loam/workload.zig");
const metrics = @import("alloc_metrics");

const reporting = @import("loam/report.zig");
const memory = @import("loam/process_memory.zig");
const profile = @import("support/profile.zig");
const sustained = @import("loam/sustained.zig");
const managed = @import("loam/managed_run.zig");
const Samples = reporting.Samples;
const now = reporting.now;
const elapsed = reporting.elapsed;
const emit = reporting.emit;
const row = reporting.row;

pub fn main(init: std.process.Init) !void {
    var smoke = false;
    var references_only = false;
    var managed_only = false;
    var foreign_only = false;
    var collection_only = false;
    var ordinary_only = false;
    var tasks_only = false;
    var scale_only = false;
    const Engine = @import("loam/tasks.zig").Engine;
    var engine: ?Engine = null;
    var cpu: ?u32 = null;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke = true else if (std.mem.eql(u8, arg, "--references-only")) references_only = true else if (std.mem.eql(u8, arg, "--managed-only")) managed_only = true else if (std.mem.eql(u8, arg, "--foreign-only")) foreign_only = true else if (std.mem.eql(u8, arg, "--collection-only")) collection_only = true else if (std.mem.eql(u8, arg, "--ordinary-only")) ordinary_only = true else if (std.mem.eql(u8, arg, "--tasks-only")) tasks_only = true else if (std.mem.eql(u8, arg, "--scale-only")) scale_only = true else if (std.mem.startsWith(u8, arg, "--engine=") and engine == null) {
            engine = std.meta.stringToEnum(Engine, arg["--engine=".len..]) orelse return error.InvalidArguments;
        } else if (std.mem.startsWith(u8, arg, "--cpu=") and cpu == null) {
            cpu = try std.fmt.parseInt(u32, arg["--cpu=".len..], 10);
        } else return error.InvalidArguments;
    }
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(init.gpa);
    if (@as(u8, @intFromBool(references_only)) + @intFromBool(managed_only) + @intFromBool(foreign_only) + @intFromBool(collection_only) + @intFromBool(ordinary_only) + @intFromBool(tasks_only) + @intFromBool(scale_only) > 1) return error.InvalidArguments;
    // Only the Tasks workload runs on a chosen engine. The others measure
    // LMDB's own pages and map.
    if ((engine != null or cpu != null) and !tasks_only) return error.InvalidArguments;
    if (cpu) |selected| {
        try memory.pinCpu(selected);
        try emit(init.gpa, &report, "tasks_cpu pinned={d}\n", .{selected});
    } else if (tasks_only) try emit(init.gpa, &report, "tasks_cpu pinned=none\n", .{});
    const chosen = [1]Engine{engine orelse .lmdb};
    const engines: []const Engine = if (engine != null) &chosen else std.enums.values(Engine);
    if (collection_only) {
        try @import("loam/collection_cost.zig").run(init, &report, smoke);
        return;
    }
    try emit(init.gpa, &report, "Loam workload mode={s} arch={s} os={s} durability=engine-default-sync\n", .{ @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) });
    if (tasks_only) {
        try @import("loam/tasks.zig").run(init, &report, smoke, engines);
        return write(init, &report, smoke, "zig-out/bench-reports/loam-tasks.txt");
    }
    if (scale_only) {
        try @import("loam/scale.zig").run(init, &report, smoke);
        return write(init, &report, smoke, "zig-out/bench-reports/loam-scale.txt");
    }
    // Tasks and scale print their own limits. These describe the workloads below.
    try emit(init.gpa, &report, "workload_limits cache_slots={d} cache_slot_bytes={d} max_record_bytes=8192\n", .{
        w.cache_slots, @sizeOf(std.meta.Child(@TypeOf(@as(w.Workload, undefined).store.cache.slots))),
    });
    const counts: []const usize = if (smoke) &.{16} else &.{ 64, 512, 2048 };
    const sizes: []const usize = if (smoke) &.{256} else &.{ 256, 4096 };
    if (!references_only and !managed_only and !foreign_only) for (counts) |count| for (sizes) |size| try run(init, &report, count, size, smoke);
    if (ordinary_only) return write(init, &report, smoke, "zig-out/bench-reports/loam-ordinary.txt");
    if (!foreign_only) for (counts) |count| for ([_]u16{ 0, 4 }) |depth| try managed.run(init, &report, count, depth, smoke, references_only);
    if (!references_only and !foreign_only) for (counts) |count| for ([_]u16{ 0, 4 }) |depth| try @import("loam/managed_sustained.zig").run(init, &report, count, depth, smoke);
    if (!references_only) for (counts) |count| for ([_]u16{ 0, 4 }) |depth| try @import("loam/foreign_references.zig").run(init, &report, count, depth, smoke);
    if (!references_only and !managed_only and !foreign_only) for (counts) |count| try sustained.run(init, &report, count, smoke);
    if (!references_only and !managed_only and !foreign_only) try @import("loam/tasks.zig").run(init, &report, smoke, engines);
    if (smoke and !references_only and !managed_only and !foreign_only) try @import("loam/collection_cost.zig").run(init, &report, true);
    if (smoke and !references_only and !managed_only and !foreign_only) try @import("loam/scale.zig").run(init, &report, true);
    try write(init, &report, smoke, if (references_only) "zig-out/bench-reports/loam-references.txt" else if (managed_only) "zig-out/bench-reports/loam-managed.txt" else if (foreign_only) "zig-out/bench-reports/loam-foreign.txt" else "zig-out/bench-reports/loam.txt");
}

fn write(init: std.process.Init, report: *std.ArrayList(u8), smoke: bool, sub_path: []const u8) !void {
    if (smoke) return;
    try std.Io.Dir.cwd().createDirPath(init.io, "zig-out/bench-reports");
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = sub_path, .data = report.items });
}

fn run(init: std.process.Init, report: *std.ArrayList(u8), count: usize, size: usize, smoke: bool) !void {
    const gpa = init.gpa;
    const io = init.io;
    const path = try std.fmt.allocPrintSentinel(gpa, "zig-out/loam-bench-{d}-{d}-{d}", .{ now(io), count, size }, 0);
    defer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(io, "zig-out");
    try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch unreachable;
    const store_id: w.core.StoreId = @fromBackingInt(72);
    var bytes: metrics.LiveBytesAllocator = .{ .backing = gpa };
    var allocations: metrics.CountingAllocator = .{ .backing = bytes.allocator() };
    const samples: usize = if (smoke) 8 else 128;
    var first: w.core.ObjectId = undefined;
    {
        var db = try w.Lmdb.open(path, .{ .opening = .{ .id = store_id, .mode = .create } });
        defer db.close() catch unreachable;
        var workload: w.Workload = undefined;
        try workload.init(allocations.allocator(), &db, count, size);
        defer workload.deinit();
        try emit(gpa, report, "footprint conversations={d} message_bytes={d} objects={d} record_bytes={d} cold_zig_heap_bytes={d} resident_bytes={d}\n", .{
            count, size, workload.store.metadata.objects, workload.store.metadata.record_bytes, bytes.liveBytes(), workload.store.cache.allocated_bytes,
        });
        try memory.emit(gpa, report, "ordinary-cold", count, size);
        if (workload.store.cache.allocated_bytes != 0) return error.EagerResidency;
        try physical(gpa, report, &db, "populated", count, size);
        first = workload.ids[0];
        // `edit` runs last: the read phases expect every conversation unedited.
        for ([_][:0]const u8{ "hot", "cold", "thrash", "edit-unrelated-read", "edit" }) |phase| {
            // Warm a small set, independently of population size.
            for (0..8) |i| _ = try workload.call(i, "read");
            const reads = workload.reads;
            const writes = workload.writes;
            const allocs = allocations.allocs;
            var timings: Samples = .{};
            profile.begin();
            const start = now(io);
            for (0..samples) |i| {
                if (std.mem.eql(u8, phase, "cold")) try workload.attachment.sleep(workload.caps[i % 8]);
                const sample = now(io);
                if (std.mem.eql(u8, phase, "edit")) {
                    _ = try workload.call(0, "edit");
                } else if (std.mem.eql(u8, phase, "edit-unrelated-read")) {
                    _ = try workload.call(0, "edit");
                    for (1..8) |j| if (try workload.call(j, "read") != 0) return error.ChangedUnrelatedConversation;
                } else {
                    const index = if (std.mem.eql(u8, phase, "thrash")) i % count else i % 8;
                    if (try workload.call(index, "read") != 0) return error.UnexpectedEdit;
                }
                timings.add(elapsed(io, sample));
            }
            profile.end(phase);
            try row(gpa, report, .{ .phase = phase, .conversations = count, .message_bytes = size, .operations = samples, .reads = workload.reads - reads, .writes = workload.writes - writes, .elapsed_ns = elapsed(io, start), .latency = timings.summarize() });
            try emit(gpa, report, "allocation phase={s} allocs={d} live_zig_heap_bytes={d} resident_bytes={d}\n", .{ phase, allocations.allocs - allocs, bytes.liveBytes(), workload.store.cache.allocated_bytes });
            if (std.mem.eql(u8, phase, "hot") or std.mem.eql(u8, phase, "edit-unrelated-read") or std.mem.eql(u8, phase, "edit")) {
                if (workload.reads != reads) return error.UnnecessaryReload;
            }
        }
        for ([_]bool{ false, true }) |fanout| {
            var timings: Samples = .{};
            const reads = workload.reads;
            const burst = @min(count, 64);
            const start = now(io);
            for (0..if (smoke) @as(usize, 2) else 16) |_| {
                workload.store.evict();
                var answers: [64]w.Answer = @splat(.{});
                const sample = now(io);
                for (0..burst) |i| try workload.send(if (fanout) i else 0, "read", &answers[i]);
                try workload.drain();
                for (answers[0..burst]) |answer| _ = try answer.require();
                timings.add(elapsed(io, sample));
            }
            try row(gpa, report, .{ .phase = if (fanout) "burst-distinct" else "burst-same", .conversations = count, .message_bytes = size, .operations = timings.count * burst, .reads = workload.reads - reads, .writes = 0, .elapsed_ns = elapsed(io, start), .latency = timings.summarize() });
            if (!fanout and workload.reads - reads != timings.count) return error.ActivationNotCoalesced;
        }
        for ([_]usize{ 64, 256 }) |work_limit| {
            try workload.garbage(if (smoke) 4 else count / 4);
            const expected = count * (1 + w.messages_per_conversation);
            const garbage_count = workload.store.metadata.objects - expected;
            _ = try workload.call(1, "read");
            const reads = workload.reads;
            const before = bytes.liveBytes();
            var peak = before;
            var batches: usize = 0;
            var service_max: u64 = 0;
            var latency_max: u64 = 0;
            const start = now(io);
            var peak_high_water: usize = 0;
            while (true) {
                const sample = now(io);
                const ticket = try workload.store.prepareCollection(work_limit);
                peak = @max(peak, bytes.liveBytes());
                var answer: w.Answer = .{};
                try workload.send(1, "read", &answer);
                _ = try workload.host.vat.driveIngressBudgeted(.local, 128);
                try workload.attachment.advance();
                if (answer.value != null or answer.failed) return error.EscapedCollectionFence;
                try workload.finish(ticket);
                service_max = @max(service_max, elapsed(io, sample));
                try workload.drain();
                if (try answer.require() != 0) return error.InvalidForegroundRead;
                latency_max = @max(latency_max, elapsed(io, sample));
                peak_high_water = @max(peak_high_water, (try db.inspect()).high_water_bytes);
                batches += 1;
                if (workload.store.metadata.collection.phase == .idle) break;
                if (batches > count * 32) return error.CollectionDidNotFinish;
            }
            if (workload.store.metadata.objects != expected or workload.store.metadata.collection.reclaimed_objects != garbage_count) return error.InvalidCollection;
            try emit(gpa, report, "collection conversations={d} message_bytes={d} work_limit={d} batches={d} reclaimed={d} foreground_reads={d} elapsed_ns={d} max_fence_ns={d} max_foreground_ns={d} preparation_extra_zig_bytes={d}\n", .{
                count, size, work_limit, batches, garbage_count, workload.reads - reads, elapsed(io, start), service_max, latency_max, peak - before,
            });
            try emit(gpa, report, "collection_physical peak_high_water_bytes={d}\n", .{peak_high_water});
            try physical(gpa, report, &db, "collected", count, size);
        }
    }
    try restart(init, report, path, store_id, allocations.allocator(), count, size, first, 2 * samples);
    if (bytes.live != 0) return error.LeakedZigMemory;
}

/// Reopen the closed database in a new Store, Host and Attachment, and time
/// everything up to the answer of one call. Conversation `first` must answer
/// with every edit the earlier run committed.
fn restart(init: std.process.Init, report: *std.ArrayList(u8), path: [:0]const u8, store_id: w.core.StoreId, allocator: std.mem.Allocator, count: usize, size: usize, first: w.core.ObjectId, edits: usize) !void {
    const io = init.io;
    const start = now(io);
    var db = try w.Lmdb.open(path, .{ .opening = .{ .id = store_id, .mode = .open } });
    defer db.close() catch unreachable;
    var workload: w.Workload = undefined;
    try workload.open(allocator, &db, count);
    defer workload.deinit();
    try workload.restore(first);
    if (try workload.call(0, "read") != edits) return error.LostCommittedEdit;
    try emit(init.gpa, report, "restart conversations={d} message_bytes={d} reads={d} elapsed_ns={d}\n", .{ count, size, workload.reads, elapsed(io, start) });
}

fn physical(gpa: std.mem.Allocator, report: *std.ArrayList(u8), db: *w.Lmdb, phase: []const u8, count: usize, size: usize) !void {
    try memory.emit(gpa, report, phase, count, size);
    const stat = try db.inspect();
    try emit(gpa, report, "physical phase={s} conversations={d} message_bytes={d} map_bytes={d} high_water_bytes={d} tree_bytes={d} entries={d}\n", .{
        phase, count, size, stat.map_bytes, stat.high_water_bytes, stat.tree_pages * stat.page_bytes, stat.entries,
    });
}
