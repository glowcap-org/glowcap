//! Native Loam workload: conversation headers, cold message chains, edits,
//! wakeup bursts, and collection with queued foreground reads. Backend calls
//! run synchronously at the executor seam to measure service cost, including
//! durable commit. This does not measure networking or concurrent worker queues.
//! Disabling unchanged-record promotion makes the smoke workload fail its
//! UnnecessaryReload check; timing measurements have no pass/fail threshold.
//! Forcing sleep between calls in the same cold burst also trips its load budget.
const std = @import("std");
const builtin = @import("builtin");
const w = @import("loam/workload.zig");
const metrics = @import("alloc_metrics");

const Samples = struct {
    values: [256]u64 = undefined,
    count: usize = 0,
    fn add(self: *Samples, ns: u64) void {
        self.values[self.count] = ns;
        self.count += 1;
    }
    fn summarize(self: *Samples) Distribution {
        std.mem.sort(u64, self.values[0..self.count], {}, std.sort.asc(u64));
        return .{ .p50_ns = self.values[self.count / 2], .p99_ns = self.values[@min(self.count - 1, self.count * 99 / 100)] };
    }
};
const Distribution = struct { p50_ns: u64, p99_ns: u64 };
const Row = struct {
    phase: []const u8,
    conversations: usize,
    message_bytes: usize,
    operations: usize,
    reads: u64,
    writes: u64,
    elapsed_ns: u64,
    latency: Distribution,
};

fn now(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}
fn elapsed(io: std.Io, start: i128) u64 {
    return @intCast(@max(0, now(io) - start));
}
fn emit(gpa: std.mem.Allocator, report: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const line = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(line);
    std.debug.print("{s}", .{line});
    try report.appendSlice(gpa, line);
}
fn row(gpa: std.mem.Allocator, report: *std.ArrayList(u8), value: Row) !void {
    try emit(gpa, report, "{s} conversations={d} message_bytes={d} ops={d} reads={d} writes={d} elapsed_ns={d} p50_ns={d} p99_ns={d}\n", .{
        value.phase, value.conversations, value.message_bytes, value.operations, value.reads, value.writes, value.elapsed_ns, value.latency.p50_ns, value.latency.p99_ns,
    });
}

pub fn main(init: std.process.Init) !void {
    var smoke = false;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke = true else return error.InvalidArguments;
    }
    var report: std.ArrayList(u8) = .empty;
    defer report.deinit(init.gpa);
    try emit(init.gpa, &report, "Loam native workload mode={s} arch={s} os={s} cache_slots={d} max_record_bytes=8192 durability=LMDB-default-sync\n", .{
        @tagName(builtin.mode), @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), w.cache_slots,
    });
    const counts: []const usize = if (smoke) &.{16} else &.{ 64, 512, 2048 };
    const sizes: []const usize = if (smoke) &.{256} else &.{ 256, 4096 };
    for (counts) |count| for (sizes) |size| try run(init, &report, count, size, smoke);
    if (!smoke) {
        try std.Io.Dir.cwd().createDirPath(init.io, "zig-out/bench-reports");
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "zig-out/bench-reports/loam.txt", .data = report.items });
    }
}

fn run(init: std.process.Init, report: *std.ArrayList(u8), count: usize, size: usize, smoke: bool) !void {
    const gpa = init.gpa;
    const io = init.io;
    const path = try std.fmt.allocPrintSentinel(gpa, "zig-out/loam-bench-{d}-{d}-{d}", .{ now(io), count, size }, 0);
    defer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(io, "zig-out");
    try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch unreachable;
    var db = try w.Lmdb.open(path, .{ .mode = .{ .create = @fromBackingInt(72) } });
    defer db.close() catch unreachable;
    var bytes: metrics.LiveBytesAllocator = .{ .backing = gpa };
    var allocations: metrics.CountingAllocator = .{ .backing = bytes.allocator() };
    {
        var workload: w.Workload = undefined;
        try workload.init(allocations.allocator(), &db, count, size);
        defer workload.deinit();
        try emit(gpa, report, "footprint conversations={d} message_bytes={d} objects={d} record_bytes={d} cold_zig_heap_bytes={d} resident_bytes={d}\n", .{
            count, size, workload.store.metadata.objects, workload.store.metadata.record_bytes, bytes.liveBytes(), workload.store.cache.allocated_bytes,
        });
        if (workload.store.cache.allocated_bytes != 0) return error.EagerResidency;
        try physical(gpa, report, &db, "populated", count, size);
        const samples: usize = if (smoke) 8 else 128;
        for ([_][]const u8{ "hot", "cold", "thrash", "edit-unrelated-read" }) |phase| {
            // Warm a small set, independently of population size.
            for (0..8) |i| _ = try workload.call(i, "read");
            const reads = workload.reads;
            const writes = workload.writes;
            const allocs = allocations.allocs;
            var timings: Samples = .{};
            const start = now(io);
            for (0..samples) |i| {
                if (std.mem.eql(u8, phase, "cold")) try workload.attachment.sleep(workload.caps[i % 8]);
                const sample = now(io);
                if (std.mem.eql(u8, phase, "edit-unrelated-read")) {
                    _ = try workload.call(0, "edit");
                    for (1..8) |j| if (try workload.call(j, "read") != 0) return error.ChangedUnrelatedConversation;
                } else {
                    const index = if (std.mem.eql(u8, phase, "thrash")) i % count else i % 8;
                    if (try workload.call(index, "read") != 0) return error.UnexpectedEdit;
                }
                timings.add(elapsed(io, sample));
            }
            try row(gpa, report, .{ .phase = phase, .conversations = count, .message_bytes = size, .operations = samples, .reads = workload.reads - reads, .writes = workload.writes - writes, .elapsed_ns = elapsed(io, start), .latency = timings.summarize() });
            try emit(gpa, report, "allocation phase={s} allocs={d} live_zig_heap_bytes={d} resident_bytes={d}\n", .{ phase, allocations.allocs - allocs, bytes.liveBytes(), workload.store.cache.allocated_bytes });
            if (std.mem.eql(u8, phase, "hot") or std.mem.eql(u8, phase, "edit-unrelated-read")) {
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
    if (bytes.live != 0) return error.LeakedZigMemory;
}

fn physical(gpa: std.mem.Allocator, report: *std.ArrayList(u8), db: *w.Lmdb, phase: []const u8, count: usize, size: usize) !void {
    const stat = try db.inspect();
    try emit(gpa, report, "physical phase={s} conversations={d} message_bytes={d} map_bytes={d} high_water_bytes={d} tree_bytes={d} entries={d}\n", .{
        phase, count, size, stat.map_bytes, stat.high_water_bytes, stat.tree_pages * stat.page_bytes, stat.entries,
    });
}
