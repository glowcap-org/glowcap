//! One closed-loop admission driver for ordinary and managed integer calls.
//! Each resource has at most one outstanding call; replies check exact state.
const std = @import("std");
const w = @import("workload.zig");
const m = @import("managed.zig");
const workers = @import("worker_pool.zig");
const r = @import("report.zig");
const memory = @import("process_memory.zig");
const metrics = @import("alloc_metrics");
const window = 8;

pub fn run(init: std.process.Init, report: *std.ArrayList(u8), workload: anytype, pool: *workers.Pool, total: usize, kind: []const u8, count: usize, depth: u16, allocations: *metrics.CountingAllocator, bytes: *metrics.LiveBytesAllocator) !void {
    const expected = try init.gpa.alloc(i64, count);
    defer init.gpa.free(expected);
    @memset(expected, 0);
    const busy = try init.gpa.alloc(bool, count);
    defer init.gpa.free(busy);
    @memset(busy, false);
    for ([_]bool{ false, true }) |edits| {
        var answers: [window]w.Answer = @splat(.{});
        var starts: [window]?i128 = @splat(null);
        var indices: [window]usize = undefined;
        defer {
            pool.drain(workload);
            workload.drain() catch {};
        }
        pool.peak = 0;
        pool.saturation_turns = 0;
        var admitted: usize = 0;
        var settled: usize = 0;
        var peak_pending: usize = 0;
        var timings: r.Samples = .{};
        const reads = workload.reads;
        const writes = workload.writes;
        const allocs = allocations.allocs;
        const start = r.now(init.io);
        while (settled < total) {
            for (&answers, &starts, &indices) |*answer, *sample, *index| {
                if (sample.* != null and (answer.value != null or answer.failed)) {
                    if (try answer.require() != expected[index.*]) return error.InvalidSustainedReply;
                    busy[index.*] = false;
                    timings.add(r.elapsed(init.io, sample.*.?));
                    sample.* = null;
                    settled += 1;
                }
                if (sample.* == null and admitted < total and !busy[admitted % count]) {
                    const editing = edits and admitted % 8 == 0;
                    index.* = admitted % count;
                    answer.* = .{};
                    sample.* = r.now(init.io);
                    try workload.send(index.*, if (editing) "edit" else "read", answer);
                    if (editing) expected[index.*] += 1;
                    busy[index.*] = true;
                    admitted += 1;
                }
            }
            try pool.turn(workload);
            peak_pending = @max(peak_pending, workload.attachment.pending_bytes);
        }
        while (pool.active != 0 or workload.attachment.hasPendingWork()) try pool.turn(workload);
        if (workload.writes - writes != (if (edits) total / 8 else @as(usize, 0))) return error.InvalidSustainedWrites;
        if (peak_pending > workload.attachment.options.pending_bytes or pool.peak > workers.capacity) return error.UnboundedExecutor;
        const latency = timings.summarize();
        const elapsed_ns = r.elapsed(init.io, start);
        try r.emit(init.gpa, report, "sustained kind={s} phase={s} resources={d} ancestry={d} workers={d} admission_window={d} ops={d} reads={d} writes={d} peak_workers={d} saturation_turns={d} peak_pending_bytes={d} allocs={d} live_zig_heap_bytes={d} elapsed_ns={d} ops_per_second={d} p50_ns={d} p99_ns={d}\n", .{
            kind, if (edits) "mixed" else "read", count, depth, workers.capacity, window, total, workload.reads - reads, workload.writes - writes, pool.peak, pool.saturation_turns, peak_pending, allocations.allocs - allocs, bytes.liveBytes(), elapsed_ns, @as(u128, total) * std.time.ns_per_s / @max(1, elapsed_ns), latency.p50_ns, latency.p99_ns,
        });
        try memory.emit(init.gpa, report, if (edits) "sustained-mixed" else "sustained-read", count, depth);
    }
}

const Foreground = struct {
    pub fn handle(_: *@This(), _: *@import("glowcap").actors.Turn, _: @import("glowcap").actors.Message) !@import("glowcap").ocapn.model.Argument {
        return .{ .integer = 77 };
    }
};

pub fn calibrateManaged(workload: *m.Managed, pool: *workers.Pool) !void {
    var gate = std.atomic.Value(bool).init(false);
    defer {
        gate.store(true, .release);
        pool.drain(workload);
        workload.drain() catch {};
    }
    const actor = try workload.host.vat.spawn(Foreground, .{});
    defer workload.host.vat.releaseActor(actor.local);
    const ticket = try workload.store.prepareCollection(64);
    try pool.submit(workload, .{ .write = try workload.store.beginWrite(ticket) }, true, &gate);
    // The managed attachment admits eight calls. Keep the ninth observer alive
    // until its refusal and all accepted calls have settled.
    var answers: [m.max_calls + 1]w.Answer = @splat(.{});
    for (&answers) |*answer| try workload.send(0, "read", answer);
    var local: w.Answer = .{};
    _ = try workload.host.vat.sendObservedFromIngress(.local, actor, .{ .verb = "get" }, .{ .ctx = &local, .func = w.Answer.receive });
    _ = try workload.host.vat.driveIngressBudgeted(.local, 128);
    try workload.attachment.advance();
    if (try local.require() != 77 or !answers[m.max_calls].failed) return error.MissingOverloadOrProgress;
    if (workload.attachment.pending_bytes != m.max_calls * workload.attachment.options.call_bytes) return error.UnboundedAdmission;
    for (answers[0..m.max_calls]) |answer| if (answer.value != null or answer.failed) return error.EscapedCollectionFence;
    gate.store(true, .release);
    while (pool.active != 0 or workload.attachment.hasPendingWork()) try pool.turn(workload);
    _ = try workload.host.vat.driveIngressBudgeted(.local, 128);
    for (answers[0..m.max_calls]) |answer| if (try answer.require() != 0) return error.InvalidSustainedReply;
    while (workload.store.metadata.collection.phase != .idle) try workload.finish(try workload.store.prepareCollection(64));
}
