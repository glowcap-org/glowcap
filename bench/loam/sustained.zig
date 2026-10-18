//! Closed-loop sustained admission, bounded workers, and concurrent
//! foreground work during tracing maintenance. Timing is descriptive only.
const std = @import("std");
const glowcap = @import("glowcap");
const w = @import("workload.zig");
const workers = @import("worker_pool.zig");
const r = @import("report.zig");
const memory = @import("process_memory.zig");
const metrics = @import("alloc_metrics");
const Foreground = struct {
    pub fn handle(_: *@This(), _: *glowcap.actors.Turn, _: glowcap.actors.Delivery) !glowcap.ocapn.model.Argument {
        return .{ .integer = 77 };
    }
};

fn foreground(workload: *w.Workload, actor: anytype, answer: *w.Answer) !void {
    _ = try workload.host.vat.sendObservedFromIngress(.local, actor, .{ .verb = "get" }, .{ .ctx = answer, .func = w.Answer.receive });
}

pub fn run(init: std.process.Init, report: *std.ArrayList(u8), count: usize, smoke: bool) !void {
    const path = try std.fmt.allocPrintSentinel(init.gpa, "zig-out/loam-workers-{d}-{d}", .{ r.now(init.io), count }, 0);
    defer init.gpa.free(path);
    try std.Io.Dir.cwd().createDir(init.io, path, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(init.io, path) catch unreachable;
    var db = try w.Lmdb.open(path, .{ .opening = .{ .id = @fromBackingInt(74), .mode = .create } });
    defer db.close() catch unreachable;
    var bytes: metrics.LiveBytesAllocator = .{ .backing = init.gpa };
    var allocations: metrics.CountingAllocator = .{ .backing = bytes.allocator() };
    {
        var workload: w.Workload = undefined;
        try workload.init(allocations.allocator(), &db, count, 4096);
        defer workload.deinit();
        var threaded = std.Io.Threaded.init(init.gpa, .{ .concurrent_limit = .limited(workers.capacity) });
        defer threaded.deinit();
        var pool: workers.Pool = .{ .io = threaded.io() };
        try pool.start();
        defer {
            pool.drain(&workload);
            pool.stop();
        }
        const actor = try workload.host.vat.spawn(Foreground, .{});
        defer workload.host.vat.releaseActor(actor.local);
        try calibrate(init.gpa, &workload, &pool, actor);
        const total: usize = if (smoke) 64 else 1024;
        try @import("sustained_calls.zig").run(init, report, &workload, &pool, total, "ordinary", count, 0, &allocations, &bytes);
        for ([_]usize{ 64, 256 }) |limit| {
            try workload.garbage(if (smoke) 4 else count / 4);
            const expected = count * (1 + w.messages_per_conversation);
            var batches: usize = 0;
            var independent: r.Samples = .{};
            var durable: r.Samples = .{};
            const start = r.now(init.io);
            while (true) {
                const sample = r.now(init.io);
                const ticket = try workload.store.prepareCollection(limit);
                try pool.submit(&workload, .{ .write = try workload.store.beginWrite(ticket) }, true, null);
                var local: w.Answer = .{};
                var stored: w.Answer = .{};
                defer {
                    pool.drain(&workload);
                    // best-effort: this drain is teardown, so the measured result is already taken or the run is already returning its own error.
                    workload.drain() catch {};
                }
                try foreground(&workload, actor, &local);
                try workload.send(1, "read", &stored);
                var counted = false;
                while (stored.value == null and !stored.failed or !counted) {
                    try pool.turn(&workload);
                    if (!counted and local.value != null) {
                        if (try local.require() != 77) return error.InvalidForeground;
                        independent.add(r.elapsed(init.io, sample));
                        counted = true;
                    }
                }
                _ = try stored.require();
                durable.add(r.elapsed(init.io, sample));
                try quiesce(&pool, &workload);
                batches += 1;
                if (workload.store.metadata.collection.phase == .idle) break;
                if (batches >= 2048) return error.MaintenanceDidNotFinish;
            }
            if (workload.store.metadata.objects != expected) return error.InvalidCollection;
            const local = independent.summarize();
            const stored = durable.summarize();
            try r.emit(init.gpa, report, "concurrent_collection conversations={d} work_limit={d} batches={d} elapsed_ns={d} local_p50_ns={d} local_p99_ns={d} durable_p50_ns={d} durable_p99_ns={d}\n", .{ count, limit, batches, r.elapsed(init.io, start), local.p50_ns, local.p99_ns, stored.p50_ns, stored.p99_ns });
            try memory.emit(init.gpa, report, "concurrent-collected", count, limit);
        }
        const stat = try db.inspect();
        try r.emit(init.gpa, report, "sustained_physical conversations={d} map_bytes={d} high_water_bytes={d} tree_bytes={d} resident_bytes={d}\n", .{ count, stat.map_bytes, stat.high_water_bytes, stat.tree_pages * stat.page_bytes, workload.store.cache.allocated_bytes });
    }
    if (bytes.live != 0) return error.LeakedSustainedMemory;
}

fn quiesce(pool: *workers.Pool, workload: *w.Workload) !void {
    while (pool.active != 0 or workload.attachment.hasPendingWork()) {
        try pool.turn(workload);
    }
}

fn calibrate(gpa: std.mem.Allocator, workload: *w.Workload, pool: *workers.Pool, actor: anytype) !void {
    // Hold a real collection commit and saturate the attachment. A
    // transient actor must progress, and one excess stored call must refuse.
    var gate = std.atomic.Value(bool).init(false);
    defer {
        gate.store(true, .release);
        pool.drain(workload);
        // best-effort: this drain is teardown, so the measured result is already taken or the run is already returning its own error.
        workload.drain() catch {};
    }
    // Exercise partial startup cleanup with a limit below the worker count.
    // Startup refuses before any Store request is borrowed.
    var disabled = std.Io.Threaded.init(gpa, .{ .concurrent_limit = .limited(2) });
    defer disabled.deinit();
    var refusing: workers.Pool = .{ .io = disabled.io() };
    if (refusing.start()) |_| {
        refusing.stop();
        return error.MissingLaunchRefusal;
    } else |err| if (err != error.ConcurrencyUnavailable) return err;
    if (refusing.started or refusing.active != 0) return error.LeakedStartup;
    for (refusing.slots) |slot| if (slot.future != null) return error.UnjoinedStartup;

    // Fill every worker with a distinct cold read. Refusal must happen before
    // accepting a fifth borrowed request, so it cannot consume or duplicate it.
    for (0..workers.capacity) |i| try workload.attachment.prefetch(workload.caps[i]);
    var first: ?w.hosting.Work = null;
    for (0..workers.capacity) |_| {
        const work = (try workload.attachment.nextWork()).?;
        if (first == null) first = work;
        try pool.submit(workload, work, false, &gate);
    }
    if (pool.submit(workload, first.?, false, &gate)) |_| return error.MissingExecutorRefusal else |err| if (err != error.ExecutorFull) return err;
    gate.store(true, .release);
    try quiesce(pool, workload);
    gate.store(false, .release);
    const ticket = try workload.store.prepareCollection(64);
    try pool.submit(workload, .{ .write = try workload.store.beginWrite(ticket) }, true, &gate);
    var answers: [65]w.Answer = @splat(.{});
    for (&answers) |*answer| try workload.send(0, "read", answer);
    var local: w.Answer = .{};
    try foreground(workload, actor, &local);
    _ = try workload.host.vat.driveIngressBudgeted(.local, 128);
    try workload.attachment.advance();
    if (try local.require() != 77 or !answers[64].failed) return error.MissingOverloadOrProgress;
    if (workload.attachment.pending_bytes > 256 * 1024) return error.UnboundedAdmission;
    for (answers[0..64]) |answer| if (answer.value != null or answer.failed) return error.EscapedCollectionFence;
    gate.store(true, .release);
    try quiesce(pool, workload);
    _ = try workload.host.vat.driveIngressBudgeted(.local, 128);
    for (answers[0..64]) |answer| _ = try answer.require();
    while (workload.store.metadata.collection.phase != .idle) try workload.finish(try workload.store.prepareCollection(64));
}
