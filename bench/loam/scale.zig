//! Cold indexed reads at two stored populations under one fixed record-cache budget.
//! One owner holds every resource, a seeded sample of them holds use endpoints,
//! and each measured call starts from an evicted Loam cache.
const std = @import("std");
const g = @import("glowcap");
const m = @import("managed.zig");
const w = @import("workload.zig");
const setup = @import("managed_setup.zig");
const metrics = @import("alloc_metrics");
const memory = @import("process_memory.zig");
const r = @import("report.zig");
const marks = @import("../support/profile.zig");

const seed = 0x6c6f_616d;
const record_cache_bytes = 32 * 1024 * 1024;
const max_record_bytes = 64 * 1024;
const directory_levels = @as(usize, std.math.maxInt(@FieldType(g.loam.access.records.DirectoryPage.Header, "level"))) + 1;
/// A cold call reads the sample's resource-index path beside the owner's own
/// path to the parent resource. Both start at the shared root page. While slots
/// stay below `1 << 24` the next page is shared too, so a larger store can add at
/// most the two lower pages (the level-2 page and the leaf) to a call. Fixed
/// depth means the count never grows with the number of stored resources.
const growth_allowance = directory_levels - 2;
const shared_slot_limit = 1 << 24;

const Profile = struct {
    populations: [2]usize,
    samples: usize,
};
const full: Profile = .{ .populations = .{ 10_000, 1_000_000 }, .samples = 128 };
const smoke_profile: Profile = .{ .populations = .{ 1_024, 8_192 }, .samples = 16 };
/// One transaction retains one change batch, and each appended resource is one
/// of its effects, so a commit takes at most this many appends.
const batch = g.loam.access.records.ChangeBatchRecord.max_effects;

const Outcome = struct { max_reads: u64, actors: usize };

pub fn run(init: std.process.Init, report: *std.ArrayList(u8), smoke: bool) !void {
    const profile = if (smoke) smoke_profile else full;
    for (profile.populations) |count| if (count >= shared_slot_limit) return error.InvalidScalePopulation;
    var outcomes: [2]Outcome = undefined;
    for (profile.populations, &outcomes) |count, *outcome| outcome.* = try population(init, report, profile, count);
    if (outcomes[1].max_reads > outcomes[0].max_reads + growth_allowance) return error.ScaledColdReads;
    if (outcomes[1].actors != outcomes[0].actors) return error.ScaledActors;
}

fn population(init: std.process.Init, report: *std.ArrayList(u8), profile: Profile, count: usize) !Outcome {
    const gpa = init.gpa;
    const io = init.io;
    const path = try std.fmt.allocPrintSentinel(gpa, "zig-out/loam-scale-bench-{d}-{d}", .{ r.now(io), count }, 0);
    defer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(io, "zig-out");
    try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch unreachable;
    const map_bytes = 512 * 1024 * 1024 + count * 4096;
    var db = try w.Lmdb.open(path, .{ .map_bytes = map_bytes, .opening = .{ .id = @fromBackingInt(74), .mode = .create } });
    defer db.close() catch unreachable;
    var bytes: metrics.LiveBytesAllocator = .{ .backing = gpa };
    var allocations: metrics.CountingAllocator = .{ .backing = bytes.allocator() };
    var outcome: Outcome = undefined;
    {
        const picks = try sample(gpa, count, profile.samples);
        defer gpa.free(picks);
        var workload: m.Managed = undefined;
        const shape: m.Managed.Shape = .{
            .held = profile.samples,
            .cache_slots = record_cache_bytes / max_record_bytes,
            .resident_bytes = record_cache_bytes,
            .max_changes = batch * 2 + 128,
            .staging_bytes = batch * 1024 + 1024 * 1024,
        };
        try workload.initShaped(allocations.allocator(), &db, shape, 0, 0x83, try (try m.callAllocationBound()).physicalBytes());
        defer workload.deinit();
        const limits = workload.store.limits;
        try r.emit(gpa, report, "scale_limits resources={d} samples={d} seed={d} batch={d} cache_slots={d} resident_limit_bytes={d} max_record_bytes={d} max_leases={d} max_changes={d} staging_limit_bytes={d} max_retentions={d} max_collection_roots={d} lmdb_map_bytes={d} record_cache=Loam database_cache=LMDB-map-and-OS-page-cache os_caches_dropped=false\n", .{
            count, profile.samples, @as(u64, seed), batch, limits.cache_slots, limits.resident_bytes, limits.records.max_record_bytes, limits.max_leases, limits.max_changes, limits.staging_bytes, limits.max_retentions, limits.max_collection_roots, map_bytes,
        });
        const actors_idle = workload.host.vat.actors.count();

        const writes = workload.writes;
        const populate_start = r.now(io);
        try populate(&workload, count, picks);
        const populate_ns = r.elapsed(io, populate_start);
        const setup_commits = workload.writes - writes;
        if (workload.host.vat.actors.count() != actors_idle) return error.EagerActors;

        const share_writes = workload.writes;
        const share_start = r.now(io);
        for (0..picks.len) |i| try workload.share(i);
        const share_ns = r.elapsed(io, share_start);
        const actors_held = workload.host.vat.actors.count();
        if (actors_held - actors_idle > 2 * picks.len) return error.ScaledActors;
        const stat = try db.inspect();
        try r.emit(gpa, report, "scale_setup resources={d} populate_ns={d} share_ns={d} populate_commits={d} share_commits={d} db_high_water_bytes={d} db_tree_bytes={d} db_entries={d} store_objects={d} store_record_bytes={d} live_zig_heap_with_warm_cache_bytes={d} actors_idle={d} actors_held={d}\n", .{
            count, populate_ns, share_ns, setup_commits, workload.writes - share_writes, stat.high_water_bytes, stat.tree_pages * stat.page_bytes, stat.entries, workload.store.metadata.objects, workload.store.metadata.record_bytes, bytes.liveBytes(), actors_idle, actors_held,
        });

        // Cold means evicted from Loam's record cache. LMDB's map and the OS
        // page cache keep whatever the earlier phases touched.
        workload.store.evict();
        if (workload.store.cache.allocated_bytes != 0) return error.EagerResidency;
        const heap_setup = bytes.liveBytes();
        const before = try memory.snapshot();
        try memory.emitSnapshot(gpa, report, "scale-cold-before", count, picks.len, before);
        const commits = workload.writes;
        var latency: r.Samples = .{};
        var read_counts: Counts = .{};
        var byte_counts: Counts = .{};
        var max_resident: usize = 0;
        marks.begin();
        const start = r.now(io);
        for (0..picks.len) |i| {
            workload.store.evict();
            if (workload.store.cache.allocated_bytes != 0) return error.EagerResidency;
            const reads = workload.reads;
            const encoded = workload.read_bytes;
            const sample_start = r.now(io);
            const answer = try workload.call(i, "read");
            latency.add(r.elapsed(io, sample_start));
            try answer.requireNumber(0);
            const resident = workload.store.cache.allocated_bytes;
            if (resident > limits.resident_bytes) return error.ResidentBudget;
            max_resident = @max(max_resident, resident);
            read_counts.add(workload.reads - reads);
            byte_counts.add(workload.read_bytes - encoded);
        }
        marks.end("scale-cold");
        const elapsed_ns = r.elapsed(io, start);
        const after = try memory.snapshot();
        try memory.emitSnapshot(gpa, report, "scale-cold-after", count, picks.len, after);
        const actors_after = workload.host.vat.actors.count();
        const dist = latency.summarize();
        try r.emit(gpa, report, "scale_cold resources={d} samples={d} reads_min={d} reads_max={d} reads_mean={d:.2} encoded_bytes_min={d} encoded_bytes_max={d} encoded_bytes_mean={d:.0} p50_ns={d} p95_ns={d} p99_ns={d} elapsed_ns={d} max_resident_charge_bytes={d} resident_limit_bytes={d} live_zig_heap_after_setup_evicted_bytes={d} live_zig_heap_after_phase_bytes={d} actors_after_phase={d} rss_before_bytes={d} rss_after_bytes={d} major_faults_before={d} major_faults_after={d} major_faults_delta={d} minor_faults_delta={d} reads_growth_allowance={d}\n", .{
            count,                      picks.len,        read_counts.min,       read_counts.max, read_counts.mean(), byte_counts.min, byte_counts.max, byte_counts.mean(), dist.p50_ns,  dist.p95_ns, dist.p99_ns,
            elapsed_ns,                 max_resident,     limits.resident_bytes, heap_setup,      bytes.liveBytes(),  actors_after,    before.resident, after.resident,     before.major, after.major, after.major - before.major,
            after.minor - before.minor, growth_allowance,
        });
        if (workload.writes != commits) return error.ColdCallCommitted;
        if (read_counts.min == 0) return error.MissingColdReads;
        if (actors_after != actors_held) return error.ScaledActors;
        outcome = .{ .max_reads = read_counts.max, .actors = actors_held };
    }
    if (bytes.live != 0) return error.LeakedScaleZigMemory;
    return outcome;
}

const Counts = struct {
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,
    total: u64 = 0,
    n: u64 = 0,
    fn add(self: *Counts, value: u64) void {
        self.min = @min(self.min, value);
        self.max = @max(self.max, value);
        self.total += value;
        self.n += 1;
    }
    fn mean(self: Counts) f64 {
        return @as(f64, @floatFromInt(self.total)) / @as(f64, @floatFromInt(self.n));
    }
};

/// Distinct resource ordinals drawn uniformly from the whole population by a
/// fixed seed, in ascending order.
fn sample(gpa: std.mem.Allocator, count: usize, samples: usize) ![]usize {
    const picks = try gpa.alloc(usize, samples);
    errdefer gpa.free(picks);
    var prng = std.Random.DefaultPrng.init(seed);
    var filled: usize = 0;
    while (filled < samples) {
        const pick = prng.random().uintLessThan(usize, count);
        if (std.mem.indexOfScalar(usize, picks[0..filled], pick) != null) continue;
        picks[filled] = pick;
        filled += 1;
    }
    std.mem.sort(usize, picks, {}, std.sort.asc(usize));
    return picks;
}

/// Trusted setup: up to `batch` resource appends and their content records commit
/// together. The sampled ordinals keep their resource and content for sharing.
fn populate(self: *m.Managed, count: usize, picks: []const usize) !void {
    const content = &@as([128]u8, @splat(0));
    var created: usize = 0;
    var next: usize = 0;
    while (created < count) {
        var read: g.loam.access.storage.Read = undefined;
        try read.init(self.allocator, &self.store, self.owner, m.record_capacity, null);
        defer read.deinit() catch unreachable;
        try setup.pump(self, &read);
        try self.store.begin();
        errdefer if (self.store.phase == .staging) self.store.abort() catch unreachable;
        for (0..@min(batch, count - created)) |_| {
            const resource = try setup.stageResource(self, &read, self.parent_resource);
            const object = try self.store.allocateId();
            try self.store.putCopying(.{ .id = object, .revision = 0, .schema = 7, .payload = content }, null);
            if (next < picks.len and picks[next] == created) {
                self.items[next] = .{ .resource = resource, .content = object };
                next += 1;
            }
            created += 1;
        }
        try self.finish(try self.store.prepare());
    }
}
