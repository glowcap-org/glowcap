//! The Tasks app measured through its own storage: one board, filled, read hot
//! and cold, rearranged, shared and watched, all by hosted calls.
//!
//! The server's `Storage` opens a disk engine and the Loam attachment, and
//! this file drives it with the local owning call, so a row holds the
//! Host/Vat, the attachment and the engine and no socket. Each run names its
//! engine, so one board shape compares the engines. Smoke runs a small board
//! and holds the structural budgets. Timings carry no threshold.
const std = @import("std");
const g = @import("glowcap");
const tasks = @import("tasks_storage");
const metrics = @import("alloc_metrics");
const r = @import("report.zig");
const profile = @import("../support/profile.zig");
const c = @import("tasks_client.zig");

const driver = g.driver.core;
const board = tasks.board;

/// The board a run fills. The last list stops short of `tasks` by `headroom`,
/// which is the room that moves and the watched adds use.
const Shape = struct { lists: usize, tasks: usize, headroom: usize, samples: usize };
const smoke_shape: Shape = .{ .lists = 2, .tasks = 8, .headroom = 4, .samples = 8 };
const full_shape: Shape = .{ .lists = board.max_lists, .tasks = board.max_tasks, .headroom = 64, .samples = 256 };
/// Backend reads one cold `list`, `task`, `text` chain may take. A board of
/// any size needs the same few records: the root, a list, a task, and the
/// descriptors that authorize each.
const cold_read_ceiling = 24;

/// The disk engines the workload runs on, each with the app's own
/// `Storage` over it and the engine's default options.
pub const Engine = enum {
    lmdb,
    sqlite,

    fn Type(comptime engine: Engine) type {
        return switch (engine) {
            .lmdb => @import("loam_lmdb").Lmdb,
            .sqlite => @import("loam_sqlite").Sqlite,
        };
    }
};

/// One phase's counters, from `begin` to `finish`.
const Meter = struct {
    engine: Engine,
    tally: *const tasks.Tally,
    store: *const g.loam.core.Store,
    allocations: *metrics.CountingAllocator,
    bytes: *metrics.LiveBytesAllocator,
    io: std.Io,
    name: [:0]const u8,
    shape: Shape,
    before: tasks.Tally,
    allocs: usize,
    start: i128,
    timings: r.Samples = .{},
    max_reads: u64 = 0,
    min_reads: u64 = std.math.maxInt(u64),

    const Mark = struct { at: i128, reads: u64 };

    fn mark(self: *Meter) Mark {
        return .{ .at = r.now(self.io), .reads = self.tally.reads };
    }

    fn record(self: *Meter, since: Mark) void {
        self.timings.add(r.elapsed(self.io, since.at));
        const delta = self.tally.reads - since.reads;
        self.max_reads = @max(self.max_reads, delta);
        self.min_reads = @min(self.min_reads, delta);
    }

    fn reads(self: *const Meter) u64 {
        return self.tally.reads - self.before.reads;
    }

    fn commits(self: *const Meter) u64 {
        return self.tally.commits - self.before.commits;
    }

    fn finish(self: *Meter, gpa: std.mem.Allocator, report: *std.ArrayList(u8)) !void {
        // A run covers each engine, so a profile part names both.
        var part: [64:0]u8 = undefined;
        profile.end(std.fmt.bufPrintSentinel(&part, "{s}:{s}", .{ @tagName(self.engine), self.name }, 0) catch unreachable);
        const elapsed_ns = r.elapsed(self.io, self.start);
        const ops = self.timings.count;
        const latency = self.timings.summarize();
        try r.emit(gpa, report, "tasks engine={s} phase={s} lists={d} tasks_per_list={d} ops={d} reads={d} commits={d} allocs={d} max_reads={d} elapsed_ns={d} ops_per_second={d} p50_ns={d} p95_ns={d} p99_ns={d} live_zig_heap_bytes={d} resident_bytes={d}\n", .{
            @tagName(self.engine),                 self.name,                        self.shape.lists, self.shape.tasks,                                         ops,            self.reads(),   self.commits(),
            self.allocations.allocs - self.allocs, self.max_reads,                   elapsed_ns,       @as(u128, ops) * std.time.ns_per_s / @max(1, elapsed_ns), latency.p50_ns, latency.p95_ns, latency.p99_ns,
            self.bytes.liveBytes(),                self.store.cache.allocated_bytes,
        });
    }
};

/// Run the workload on each of `engines` in turn.
pub fn run(init: std.process.Init, report: *std.ArrayList(u8), smoke: bool, engines: []const Engine) !void {
    for (engines) |engine| switch (engine) {
        inline else => |known| try runOn(known, init, report, smoke),
    };
}

fn runOn(comptime engine: Engine, init: std.process.Init, report: *std.ArrayList(u8), smoke: bool) !void {
    const gpa = init.gpa;
    const io = init.io;
    const shape = if (smoke) smoke_shape else full_shape;
    std.debug.assert(shape.lists <= board.max_lists and shape.tasks <= board.max_tasks and shape.headroom < shape.tasks);
    const path = try std.fmt.allocPrintSentinel(gpa, "zig-out/loam-tasks-bench-{d}", .{r.now(io)}, 0);
    defer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(io, "zig-out");
    try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, path) catch unreachable;
    var bytes: metrics.LiveBytesAllocator = .{ .backing = gpa };
    var allocations: metrics.CountingAllocator = .{ .backing = bytes.allocator() };
    const allocator = allocations.allocator();
    {
        // Local, socket-free measurement identity; benchmark stores are isolated.
        var host = try driver.Host.init(allocator, @splat(0x91), @splat(0x92), driver.Host.Options.withFrameCap(4096));
        defer host.deinit();
        var storage: tasks.Storage(engine.Type()) = undefined;
        try storage.open(allocator, io, &host, path);
        defer storage.close() catch unreachable;
        try body(gpa, io, report, engine, &storage, &allocations, &bytes, shape);
    }
    if (bytes.live != 0) return error.LeakedTasksZigMemory;
    try r.emit(gpa, report, "tasks_store engine={s} lists={d} tasks_per_list={d} file_bytes={d}\n", .{ @tagName(engine), shape.lists, shape.tasks, try storedBytes(io, path) });
}

/// The bytes every file in the closed store's directory holds, so engines
/// that keep different files compare by what they leave on disk.
fn storedBytes(io: std.Io, path: []const u8) !u64 {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var total: u64 = 0;
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind == .file) total += (try dir.statFile(io, entry.name, .{})).size;
    }
    return total;
}

fn body(gpa: std.mem.Allocator, io: std.Io, report: *std.ArrayList(u8), engine: Engine, storage: anytype, allocations: *metrics.CountingAllocator, bytes: *metrics.LiveBytesAllocator, shape: Shape) !void {
    const client: c.Client(@TypeOf(storage.*)) = .{ .storage = storage, .allocator = allocations.allocator() };
    const host = storage.attached.host;
    const root = try storage.restoreRoot();
    defer host.releaseCapability(root, 1) catch unreachable;
    try r.emit(gpa, report, "tasks_limits max_lists={d} max_tasks={d} max_text_bytes={d} lists={d} tasks_per_list={d} headroom={d}\n", .{
        board.max_lists, board.max_tasks, board.max_text_bytes, shape.lists, shape.tasks, shape.headroom,
    });

    // Setup: the lists. One mutation sequence numbers every change under the board.
    var sequence = try client.integer(root, "mutation-sequence", &.{});
    var name: [32]u8 = undefined;
    while (try client.integer(root, "lists", &.{}) < shape.lists) {
        const held = try client.mutate(root, &sequence, &.{ .{ .string = "add-list" }, .{ .string = try std.fmt.bufPrint(&name, "List {d}", .{sequence}) } });
        held.deinit();
    }
    var lists: [board.max_lists]c.Held = undefined;
    for (0..shape.lists) |i| {
        lists[i] = try client.facet(root, "list", i);
    }
    defer for (lists[0..shape.lists]) |held| held.deinit();
    const last = shape.lists - 1;
    var text: [64]u8 = undefined;

    // Add: fill the board. Each add is one hosted call and one commit.
    {
        var meter = begin(engine, storage, allocations, bytes, io, "add", shape);
        for (0..shape.lists) |i| {
            const fill = if (i == last) shape.tasks - shape.headroom else shape.tasks;
            for (0..fill) |n| {
                const at = meter.mark();
                try client.add(lists[i].cap(), &sequence, try std.fmt.bufPrint(&text, "task {d}-{d}", .{ i, n }));
                meter.record(at);
            }
        }
        try meter.finish(gpa, report);
        if (meter.commits() != meter.timings.count) return error.TasksAddCommits;
    }
    for (0..shape.lists) |i| {
        const expected = if (i == last) shape.tasks - shape.headroom else shape.tasks;
        if (try client.integer(lists[i].cap(), "count", &.{}) != expected) return error.TasksCount;
    }

    // Hot reads: a few warmed tasks need no backend reads.
    const warm = 4;
    var warmed: [warm]c.Held = undefined;
    var warmed_count: usize = 0;
    defer for (warmed[0..warmed_count]) |held| held.deinit();
    for (&warmed, 0..) |*held, n| {
        held.* = try client.facet(lists[0].cap(), "task", n);
        warmed_count += 1;
        try client.expectText(held.cap(), try std.fmt.bufPrint(&text, "task 0-{d}", .{n}));
    }
    {
        var meter = begin(engine, storage, allocations, bytes, io, "hot-read", shape);
        for (0..shape.samples) |i| {
            const at = meter.mark();
            try client.expectText(warmed[i % warm].cap(), try std.fmt.bufPrint(&text, "task 0-{d}", .{i % warm}));
            meter.record(at);
        }
        try meter.finish(gpa, report);
        if (meter.reads() != 0) return error.TasksHotReads;
    }

    // Cold reads: the record cache is empty before each list, task, text chain.
    {
        var meter = begin(engine, storage, allocations, bytes, io, "cold-read", shape);
        for (0..shape.samples) |i| {
            const list = (i * 7) % shape.lists;
            const fill = if (list == last) shape.tasks - shape.headroom else shape.tasks;
            const task = (i * 13 + 1) % fill;
            storage.store.evict();
            const at = meter.mark();
            const facet = try client.facet(root, "list", list);
            defer facet.deinit();
            const found = try client.facet(facet.cap(), "task", task);
            defer found.deinit();
            try client.expectText(found.cap(), try std.fmt.bufPrint(&text, "task {d}-{d}", .{ list, task }));
            meter.record(at);
        }
        try meter.finish(gpa, report);
        try r.emit(gpa, report, "tasks_cold_reads min_reads={d} max_reads={d} ceiling={d}\n", .{ meter.min_reads, meter.max_reads, cold_read_ceiling });
        if (meter.min_reads == 0) return error.TasksMissingColdReads;
        if (meter.max_reads > cold_read_ceiling) return error.TasksColdReadBudget;
    }

    // Moves: tasks leave the first list for the last and come back, each named
    // by its capability and each one commit.
    const moving = shape.headroom;
    var held_tasks: [full_headroom]c.Held = undefined;
    var held_count: usize = 0;
    defer for (held_tasks[0..held_count]) |held| held.deinit();
    for (held_tasks[0..moving], 0..) |*held, n| {
        held.* = try client.facet(lists[0].cap(), "task", n);
        held_count += 1;
    }
    {
        var meter = begin(engine, storage, allocations, bytes, io, "move", shape);
        for ([_]usize{ 0, last }) |from| {
            const to = last - from;
            for (held_tasks[0..moving]) |held| {
                const at = meter.mark();
                _ = try client.move(lists[from].cap(), &sequence, held.cap(), lists[to].cap());
                meter.record(at);
            }
        }
        try meter.finish(gpa, report);
        if (meter.commits() != meter.timings.count) return error.TasksMoveCommits;
    }
    if (try client.integer(lists[0].cap(), "count", &.{}) != shape.tasks) return error.TasksCount;
    if (try client.integer(lists[last].cap(), "count", &.{}) != shape.tasks - shape.headroom) return error.TasksCount;

    // Share and read: a read-only object share of a task, then reads through it.
    const sharing = @min(moving, 32);
    var shares: [32]c.Held = undefined;
    var share_count: usize = 0;
    defer for (shares[0..share_count]) |held| held.deinit();
    {
        var meter = begin(engine, storage, allocations, bytes, io, "share", shape);
        for (shares[0..sharing], held_tasks[0..sharing]) |*share, held| {
            const at = meter.mark();
            share.* = try client.shareReadOnly(root, held.cap());
            share_count += 1;
            meter.record(at);
        }
        try meter.finish(gpa, report);
        if (meter.commits() != meter.timings.count) return error.TasksShareCommits;
    }
    {
        var meter = begin(engine, storage, allocations, bytes, io, "share-read", shape);
        for (shares[0..sharing], 0..) |share, n| {
            const at = meter.mark();
            try client.expectText(share.cap(), try std.fmt.bufPrint(&text, "task 0-{d}", .{n}));
            meter.record(at);
        }
        try meter.finish(gpa, report);
    }

    // Watch: after each add, the receiver polled with the last cursor reports a change.
    {
        const watcher = try client.observe(root, &sequence);
        defer watcher.deinit();
        var cursor = (try client.poll(watcher, null)).cursor;
        var meter = begin(engine, storage, allocations, bytes, io, "watch", shape);
        for (0..shape.headroom) |n| {
            const at = meter.mark();
            try client.add(lists[last].cap(), &sequence, try std.fmt.bufPrint(&text, "watched {d}", .{n}));
            const seen = try client.poll(watcher, cursor);
            meter.record(at);
            if (!seen.changed) return error.TasksMissedChange;
            cursor = seen.cursor;
        }
        try meter.finish(gpa, report);
        if (meter.commits() != meter.timings.count) return error.TasksWatchCommits;
        if ((try client.poll(watcher, cursor)).changed) return error.TasksPhantomChange;
    }
}

const full_headroom = full_shape.headroom;

fn begin(engine: Engine, storage: anytype, allocations: *metrics.CountingAllocator, bytes: *metrics.LiveBytesAllocator, io: std.Io, name: [:0]const u8, shape: Shape) Meter {
    profile.begin();
    return .{ .engine = engine, .tally = &storage.tally, .store = &storage.store, .allocations = allocations, .bytes = bytes, .io = io, .name = name, .shape = shape, .before = storage.tally, .allocs = allocations.allocs, .start = r.now(io) };
}
