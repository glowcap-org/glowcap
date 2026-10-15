//! Inbound dispatch cost across N live peers in the cold-cache regime.
//!
//! `bench-codec`'s dispatch figure drives one peer whose session struct and
//! tables stay resident in L1, so it measures the warm per-turn CPU floor. A
//! server holding hundreds of thousands of sessions never runs there: each
//! turn lands on a peer whose session state was evicted while the other
//! connections took their turns, so the realistic per-turn cost includes the
//! cache misses of touching that state cold. This benchmark measures exactly
//! that: it stands up N warmed peers (cheap, sans-io, the same construction
//! `bench-peer-scaling` weighs), round-robins one inbound `op:deliver` through
//! each, and reports ns/turn as N grows from one L1-resident peer to a
//! hundred thousand.
//!
//! Two passes per N:
//!
//!   1. **Batch mean**: no per-turn clock reads, total elapsed / turns. The
//!      N=1 row of this pass is the same measurement `bench-codec`'s dispatch
//!      makes, the cross-check that the harness reproduces the warm headline.
//!   2. **Per-turn samples**: one clock read pair per turn, sorted for
//!      p50/p99. Each sample carries the timer-read overhead, which is
//!      measured and reported alongside so the percentiles read accurately.
//!
//! Run `zig build bench-dispatch-scaling` (use `-Doptimize=ReleaseFast` for
//! absolute figures) to measure and write the report under
//! `zig-out/bench-reports/`. The `--smoke` argument runs tiny counts and
//! skips the report write. The `--gate` argument (used by `zig build check`
//! through the ReleaseFast `perf-check` tripwire) gates the warm N=1 figure
//! against `gate_warm_dispatch_ceiling_ns` and exits red when it is crossed.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const profile = @import("support/profile.zig");

const engine = glowcap.ocapn.engine;
const model = glowcap.ocapn.model;

/// One inbound `op:deliver` to live local export 7, the steady-state turn the
/// alloc-budget test pins and `bench-codec`'s dispatch drives, so the N=1 row
/// is directly comparable.
// No-answer (`#f` answer position) deliver: re-applied to one peer across the
// measured turns, so a live-answer position would be refused on the second apply.
const deliver_to_live_export = "<10'op:deliver<11'desc:export7+>[5:hello]ff>";

/// The enforced ceiling for one warm inbound dispatch turn under `--gate`
/// (ReleaseFast). This constant owns the number. It is a tripwire at
/// roughly an order of magnitude over the measured figure, so crossing it
/// means a structural regression (an accidental copy in the loop, a Debug-only
/// path leaking into hot code, an asymptotic slip), never machine noise,
/// which is also why it gates: a threshold tight enough to catch a 20% drift
/// would flake across hardware, and a gate that flakes is worse than a print.
pub const gate_warm_dispatch_ceiling_ns: f64 = 2_000;

const gate_batches = 5;
const gate_turns_per_batch = 20_000;

/// The `--gate` arm: one warmed peer, `gate_batches` batch means over
/// `gate_turns_per_batch` turns each, gated on the minimum batch mean, the
/// right estimator for CPU-bound work, since a contention spike inflates some
/// batches but almost never all of them. Exits red past the ceiling.
fn runGate(io: std.Io, backing: std.mem.Allocator) !void {
    var peer = engine.Peer.init(backing);
    defer peer.deinit();
    try peer.exportObject(7);
    for (0..64) |_| try driveOneTurn(&peer);

    var min_ns = std.math.floatMax(f64);
    for (0..gate_batches) |_| {
        const start = nowNs(io);
        for (0..gate_turns_per_batch) |_| try driveOneTurn(&peer);
        const elapsed: f64 = @floatFromInt(@max(nowNs(io) - start, 0));
        min_ns = @min(min_ns, elapsed / @as(f64, @floatFromInt(gate_turns_per_batch)));
    }

    if (min_ns > gate_warm_dispatch_ceiling_ns) {
        std.debug.print(
            "perf_gate FAIL warm_dispatch min_ns={d:.1} ceiling_ns={d:.1} — bench/dispatch_scaling_bench.zig\n",
            .{ min_ns, gate_warm_dispatch_ceiling_ns },
        );
        std.process.exit(1);
    }
    std.debug.print(
        "perf_gate warm_dispatch min_ns={d:.1} ceiling_ns={d:.1} ok\n",
        .{ min_ns, gate_warm_dispatch_ceiling_ns },
    );
}

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}

fn driveOneTurn(peer: *engine.Peer) !void {
    try peer.recvBorrowed(.{ .bytes = deliver_to_live_export, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
}

/// Mean and percentiles for one visiting order over one peer population.
const OrderStats = struct {
    mean_ns: f64,
    p50_ns: u64,
    p99_ns: u64,
};

const Measurement = struct {
    peers: usize,
    turns: usize,
    /// Peers visited in array order: the hardware prefetcher sees an ascending
    /// address stream, so this understates the miss cost.
    sequential: OrderStats,
    /// Peers visited in a fixed pseudo-random permutation each round: the
    /// realistic regime, where the next turn's session state is unpredictable.
    shuffled: OrderStats,
};

/// Time `rounds` passes over `peers` in the visiting order `order` gives:
/// a batch pass for the mean (no per-turn clock reads), then a sampled pass
/// for p50/p99 (one clock-read pair per turn. The caller reports that
/// overhead alongside).
fn runOrder(
    io: std.Io,
    peers: []engine.Peer,
    order: []const u32,
    rounds: usize,
    samples: []u64,
    label: []const u8,
) !OrderStats {
    const turns = order.len * rounds;

    // One untimed pass so first-run effects (page faults, cold icache on the
    // dispatch path) land outside the measured window.
    for (order) |i| try driveOneTurn(&peers[i]);

    var phase: [48]u8 = undefined;
    profile.begin();
    const batch_start = nowNs(io);
    for (0..rounds) |_| {
        for (order) |i| try driveOneTurn(&peers[i]);
    }
    const name = try std.fmt.bufPrint(phase[0 .. phase.len - 1], "dispatch-{s}-{d}", .{ label, peers.len });
    phase[name.len] = 0;
    profile.end(phase[0..name.len :0]);
    const batch_elapsed: f64 = @floatFromInt(nowNs(io) - batch_start);

    var sample_index: usize = 0;
    for (0..rounds) |_| {
        for (order) |i| {
            const t0 = nowNs(io);
            try driveOneTurn(&peers[i]);
            samples[sample_index] = @intCast(@max(nowNs(io) - t0, 0));
            sample_index += 1;
        }
    }
    const taken = samples[0..sample_index];
    std.mem.sort(u64, taken, {}, std.sort.asc(u64));

    return .{
        .mean_ns = batch_elapsed / @as(f64, @floatFromInt(turns)),
        .p50_ns = taken[taken.len / 2],
        .p99_ns = taken[(taken.len * 99) / 100],
    };
}

/// Stand up `n` warmed peers and drive `rounds` delivers through each, once
/// in array order and once in a shuffled order. By the time a round returns
/// to a peer, the other n-1 turns evicted its session state, so every turn at
/// large `n` touches cold tables, the regime a many-connection server
/// actually runs in. The shuffled order additionally defeats the prefetcher's
/// ascending-address pattern, which is what real arrival order looks like.
fn measure(
    io: std.Io,
    backing: std.mem.Allocator,
    n: usize,
    rounds: usize,
    samples: []u64,
) !Measurement {
    const peers = try backing.alloc(engine.Peer, n);
    defer backing.free(peers);

    var created: usize = 0;
    errdefer for (peers[0..created]) |*p| p.deinit();
    while (created < n) : (created += 1) {
        peers[created] = engine.Peer.init(backing);
        try peers[created].exportObject(7);
        try driveOneTurn(&peers[created]);
    }
    defer for (peers) |*p| p.deinit();

    const order = try backing.alloc(u32, n);
    defer backing.free(order);
    for (order, 0..) |*slot, i| slot.* = @intCast(i);
    const sequential = try runOrder(io, peers, order, rounds, samples, "sequential");

    var prng = std.Random.DefaultPrng.init(0x70616e63616b65); // fixed seed: reproducible order
    prng.random().shuffle(u32, order);
    const shuffled = try runOrder(io, peers, order, rounds, samples, "shuffled");

    return .{
        .peers = n,
        .turns = n * rounds,
        .sequential = sequential,
        .shuffled = shuffled,
    };
}

/// Median cost of one `nowNs` read pair, the overhead each percentile sample
/// carries. Measured, not assumed, so the report can say how much of p50 is
/// the clock.
fn timerOverheadNs(io: std.Io) u64 {
    const iters = 4096;
    const start = nowNs(io);
    for (0..iters) |_| std.mem.doNotOptimizeAway(nowNs(io));
    const elapsed: u64 = @intCast(@max(nowNs(io) - start, 0));
    return elapsed / iters;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const backing = std.heap.smp_allocator;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    var smoke = false;
    var gate = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke = true;
        if (std.mem.eql(u8, arg, "--gate")) gate = true;
    }

    if (gate) {
        if (builtin.mode != .fast) {
            std.debug.print("perf_gate FAIL warm_dispatch: --gate measures ReleaseFast only, got {s}\n", .{@tagName(builtin.mode)});
            std.process.exit(1);
        }
        return runGate(io, backing);
    }

    const peer_counts: []const usize = if (smoke) &.{ 1, 64 } else &.{ 1, 1_000, 100_000 };
    // Enough turns per row for stable percentiles, without letting the N=1
    // row spin forever: aim for ~100k turns, at least one full round.
    const target_turns: usize = if (smoke) 2_000 else 100_000;

    const overhead_ns = timerOverheadNs(io);

    var results: [3]Measurement = undefined;
    var count: usize = 0;
    for (peer_counts) |n| {
        const rounds = @max(target_turns / n, 1);
        const samples = try backing.alloc(u64, n * rounds);
        defer backing.free(samples);
        results[count] = try measure(io, backing, n, rounds, samples);
        const m = results[count];
        count += 1;
        std.debug.print(
            "dispatch_scaling peers={d} turns={d} seq_mean_ns={d:.1} seq_p50_ns={d} seq_p99_ns={d} shuf_mean_ns={d:.1} shuf_p50_ns={d} shuf_p99_ns={d} timer_overhead_ns={d} mode={s}\n",
            .{
                m.peers,            m.turns,           m.sequential.mean_ns, m.sequential.p50_ns, m.sequential.p99_ns,
                m.shuffled.mean_ns, m.shuffled.p50_ns, m.shuffled.p99_ns,    overhead_ns,         @tagName(builtin.mode),
            },
        );
    }

    if (smoke) return;

    try writeReport(backing, io, results[0..count], overhead_ns);
    std.debug.print("dispatch_scaling report written to zig-out/bench-reports/dispatch-scaling.md\n", .{});
}

fn appendFmt(b: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try b.appendSlice(gpa, s);
}

fn writeReport(gpa: std.mem.Allocator, io: std.Io, results: []const Measurement, overhead_ns: u64) !void {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\# Inbound dispatch across N peers (cold-cache regime)
        \\
        \\Generated by `zig build bench-dispatch-scaling`. One inbound
        \\`op:deliver` to a live export, round-robined across N warmed peers.
        \\The N=1 row is the warm L1-resident figure `bench-codec`'s dispatch
        \\also measures; the large-N rows are the cost when each turn lands on
        \\session state the other connections' turns evicted — the regime a
        \\many-connection server actually runs in, and the gap between the two
        \\is pure memory-hierarchy cost (the code path is identical).
        \\
        \\Each N is visited in two orders: **sequential** (array order, which
        \\the prefetcher's ascending-address pattern flatters) and **shuffled**
        \\(a fixed pseudo-random permutation, the realistic arrival order).
        \\The mean is a batch measurement with no per-turn clock reads. p50 and
        \\p99 come from per-turn samples, each of which carries one timer-read
        \\overhead (measured below), so read the percentiles net of it.
        \\
        \\## Results
        \\
        \\| peers (N) | turns | seq mean ns/turn | seq p50 | seq p99 | shuffled mean ns/turn | shuffled p50 | shuffled p99 |
        \\| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
        \\
    );
    for (results) |m| {
        try appendFmt(&b, gpa, "| {d} | {d} | {d:.1} | {d} | {d} | {d:.1} | {d} | {d} |\n", .{
            m.peers,             m.turns,            m.sequential.mean_ns, m.sequential.p50_ns,
            m.sequential.p99_ns, m.shuffled.mean_ns, m.shuffled.p50_ns,    m.shuffled.p99_ns,
        });
    }
    try appendFmt(&b, gpa,
        \\
        \\Timer-read overhead per percentile sample: about {d} ns. Mode: {s}.
        \\
    , .{ overhead_ns, @tagName(builtin.mode) });

    var dir = std.Io.Dir.cwd();
    try dir.createDirPath(io, "zig-out/bench-reports");
    try dir.writeFile(io, .{ .sub_path = "zig-out/bench-reports/dispatch-scaling.md", .data = b.items });
}
