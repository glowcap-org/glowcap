//! The outbound engine path, end to end, and the GC release storm.
//!
//! `bench-codec` times encode alone; nothing times what a caller actually pays
//! to put a message on the wire: `send` (owned-tree validate walk plus
//! `recordSend`'s retain walk), then queue, then `step` (on a v1.0 session, an
//! answered `op:deliver` also mints a resolver export: an export allocation,
//! the answer-to-resolver link insert, and the wire-delta retain), then encode,
//! then outbound push, then `takeOutbound`. Scenario (a) measures that full path
//! per answered deliver. The application boundary clone (`sendCopying`) is timed
//! separately so the engine-path figure reads net of it.
//!
//! Scenario (b) is the release wave: open Q answered delivers, then send one
//! `op:gc-answers` naming all Q positions, timing the single send+step that
//! releases them. Releasing an outbound answer drops its v1.0 resolver link
//! via `removeOutboundResolverByAnswer`, an O(1) lookup through the session's
//! answer-to-resolver inverse map, so the wave is linear and ns/answer holds
//! flat across the Q sweep. The sweep defends that shape: ns/answer growing
//! with Q means a per-position scan crept back.
//!
//! Run `zig build bench-outbound` (use `-Doptimize=ReleaseFast` for absolute
//! figures) to measure and write the report under `zig-out/bench-reports/`.
//! The `--smoke` argument runs tiny counts and skips the report write. The
//! `--gate` argument (used by `zig build check` through the ReleaseFast
//! `perf-check` tripwire) gates the answered-send figure against
//! `gate_outbound_send_ceiling_ns` and the storm's linearity against
//! `gate_storm_growth_ceiling`, exiting red when either is crossed.

const std = @import("std");
const builtin = @import("builtin");
const pancake = @import("pancake");

const engine = pancake.ocapn.engine;
const model = pancake.ocapn.model;

/// The same representative outbound call `bench-codec` encodes: a method
/// invocation on an imported object with a small mixed-type argument list, so
/// the encode share of this path is directly comparable with that bench.
const bench_args = [_]model.Argument{
    .{ .symbol = "greet" },
    .{ .string = "hello, world" },
    .{ .integer = 42 },
    .{ .bytes = "\x00\x01\x02\x03" },
    .{ .boolean = true },
};

const target_import: u64 = 5;

/// The enforced ceilings under `--gate` (ReleaseFast). docs/ladder.md step 2
/// owns these numbers. Both are tripwires, not precision instruments: the
/// send ceiling sits roughly an order of magnitude over the measured figure
/// so only a structural regression crosses it, and the growth ceiling is
/// dimensionless (the same code at two sizes), so machine speed cancels out
/// of it entirely — a reintroduced per-position scan shows as roughly
/// Q-proportional growth against a measured noise floor near 1.2.
pub const gate_outbound_send_ceiling_ns: f64 = 8_000;
pub const gate_storm_growth_ceiling: f64 = 3.0;

const gate_batches = 5;
const gate_iters_per_batch = 20_000;
const gate_storm_small_q = 1_000;
const gate_storm_big_q = 8_000;
const gate_storm_samples = 5;

/// The `--gate` arm: the answered-send path gated on the minimum of
/// `gate_batches` batch means (a contention spike inflates some batches,
/// almost never all of them), and the gc-storm shape gated on the ratio of
/// ns/answer at two Q sizes. Exits red past either ceiling.
fn runGate(io: std.Io, allocator: std.mem.Allocator) !void {
    var min_send_ns = std.math.floatMax(f64);
    for (0..gate_batches) |_| {
        const send = try measureAnsweredSend(io, allocator, gate_iters_per_batch);
        min_send_ns = @min(min_send_ns, send.total_ns);
    }

    const small = try measureGcStorm(io, allocator, gate_storm_small_q, gate_storm_samples);
    const big = try measureGcStorm(io, allocator, gate_storm_big_q, gate_storm_samples);
    const growth = big.ns_per_answer / small.ns_per_answer;

    var failed = false;
    if (min_send_ns > gate_outbound_send_ceiling_ns) {
        failed = true;
        std.debug.print(
            "perf_gate FAIL outbound_send min_ns={d:.1} ceiling_ns={d:.1} — docs/ladder.md step 2\n",
            .{ min_send_ns, gate_outbound_send_ceiling_ns },
        );
    } else {
        std.debug.print(
            "perf_gate outbound_send min_ns={d:.1} ceiling_ns={d:.1} ok\n",
            .{ min_send_ns, gate_outbound_send_ceiling_ns },
        );
    }
    if (growth > gate_storm_growth_ceiling) {
        failed = true;
        std.debug.print(
            "perf_gate FAIL gc_storm_growth q{d}_ns_per={d:.1} q{d}_ns_per={d:.1} growth={d:.2} ceiling={d:.1} — docs/ladder.md step 2\n",
            .{ gate_storm_small_q, small.ns_per_answer, gate_storm_big_q, big.ns_per_answer, growth, gate_storm_growth_ceiling },
        );
    } else {
        std.debug.print(
            "perf_gate gc_storm_growth q{d}_ns_per={d:.1} q{d}_ns_per={d:.1} growth={d:.2} ceiling={d:.1} ok\n",
            .{ gate_storm_small_q, small.ns_per_answer, gate_storm_big_q, big.ns_per_answer, growth, gate_storm_growth_ceiling },
        );
    }
    if (failed) std.process.exit(1);
}

fn benchMessage(answer: u64) model.Message {
    return .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(target_import) },
        .args = &bench_args,
        .answer = .from(answer),
    } };
}

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}

fn elapsed(start: i128, end: i128) u64 {
    return @intCast(@max(end - start, 0));
}

/// A peer ready to send: open v1.0 session (so answered delivers take the
/// resolver mint) holding the import the bench message targets.
fn benchPeer(allocator: std.mem.Allocator) !engine.Peer {
    var peer = engine.Peer.init(allocator);
    errdefer peer.deinit();
    try peer.importObject(target_import);
    return peer;
}

/// One answered deliver through the whole outbound path: boundary clone
/// (`sendCopying`), record + queue, `step` (resolver mint + encode + push),
/// and `takeOutbound`. The caller owns the peer so table state accumulates
/// across messages, exactly as a long-lived session's does.
fn sendOneAnswered(peer: *engine.Peer) !void {
    const answer = try peer.allocateAnswer();
    try peer.sendCopying(benchMessage(answer));
    _ = try peer.step();
    while (peer.takeOutbound()) |frame_in| {
        var frame = frame_in;
        frame.deinit();
    }
}

const SendMeasurement = struct {
    iters: usize,
    /// Full path: clone + send + step + takeOutbound, ns per message.
    total_ns: f64,
    /// The boundary clone alone (`model.cloneMessage` + free), ns per message.
    clone_ns: f64,
};

/// Scenario (a): ns per answered deliver through `sendCopying`+`step`+
/// `takeOutbound`, plus a clone-only calibration so the engine-path share
/// (total - clone) is readable.
fn measureAnsweredSend(io: std.Io, allocator: std.mem.Allocator, iters: usize) !SendMeasurement {
    var peer = try benchPeer(allocator);
    defer peer.deinit();

    for (0..64) |_| try sendOneAnswered(&peer);

    const start = nowNs(io);
    for (0..iters) |_| try sendOneAnswered(&peer);
    const total_ns = @as(f64, @floatFromInt(elapsed(start, nowNs(io)))) / @as(f64, @floatFromInt(iters));

    // Clone-only calibration: what `sendCopying`'s boundary copy costs by
    // itself, measured with the same message shape.
    const clone_start = nowNs(io);
    for (0..iters) |_| {
        const owned = try model.cloneMessage(allocator, benchMessage(1));
        std.mem.doNotOptimizeAway(&owned);
        model.freeMessage(allocator, owned);
    }
    const clone_ns = @as(f64, @floatFromInt(elapsed(clone_start, nowNs(io)))) / @as(f64, @floatFromInt(iters));

    return .{ .iters = iters, .total_ns = total_ns, .clone_ns = clone_ns };
}

const StormMeasurement = struct {
    q: usize,
    /// Median ns for the whole release wave (one `op:gc-answers` send + step).
    wave_ns: u64,
    /// wave_ns / q — flat across the sweep means linear release, growth
    /// means the per-position resolver-link scan is quadratic.
    ns_per_answer: f64,
};

const max_storm_samples = 8;

/// Scenario (b): open `q` answered delivers (each leaves an outbound answer
/// row and a v1.0 resolver link), then send one `op:gc-answers` releasing all
/// `q` positions and time that send+step wave. Median over fresh peers.
fn measureGcStorm(io: std.Io, allocator: std.mem.Allocator, q: usize, samples: usize) !StormMeasurement {
    var buf: [max_storm_samples]u64 = undefined;
    for (0..samples) |i| {
        var peer = try benchPeer(allocator);
        defer peer.deinit();

        const positions = try allocator.alloc(u64, q);
        // `send` takes ownership of the message heap on every outcome (freed
        // after encode, or freed inside `send` on refusal), so the flag hands
        // `positions` over at the call and the errdefer covers only the fill.
        var positions_owned_here = true;
        errdefer if (positions_owned_here) allocator.free(positions);
        for (positions) |*pos| {
            const answer = try peer.allocateAnswer();
            pos.* = answer;
            try peer.sendCopying(benchMessage(answer));
            _ = try peer.step();
            while (peer.takeOutbound()) |frame_in| {
                var frame = frame_in;
                frame.deinit();
            }
        }

        const start = nowNs(io);
        positions_owned_here = false;
        try peer.send(.{ .gc_answer = .{ .positions = positions } });
        _ = try peer.step();
        while (peer.takeOutbound()) |frame_in| {
            var frame = frame_in;
            frame.deinit();
        }
        buf[i] = elapsed(start, nowNs(io));
    }
    const taken = buf[0..samples];
    std.mem.sort(u64, taken, {}, std.sort.asc(u64));
    // The fastest wave, not the median. What this measures is the shape of the
    // work, and the fastest observation is the one least polluted by whatever
    // else the machine was doing. A median only discards an isolated spike; a
    // second build running alongside inflates every sample, and the ratio then
    // reds the gate for a regression that is not there. The answered-send gate
    // beside this one already takes a minimum for the same reason.
    const wave = taken[0];
    return .{
        .q = q,
        .wave_ns = wave,
        .ns_per_answer = @as(f64, @floatFromInt(wave)) / @as(f64, @floatFromInt(q)),
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;

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
            std.debug.print("perf_gate FAIL outbound: --gate measures ReleaseFast only, got {s}\n", .{@tagName(builtin.mode)});
            std.process.exit(1);
        }
        return runGate(io, allocator);
    }

    const send_iters: usize = if (smoke) 500 else 100_000;
    const storm_qs: []const usize = if (smoke) &.{ 16, 64 } else &.{ 100, 1_000, 10_000 };
    const storm_samples: usize = if (smoke) 2 else 7;

    const send = try measureAnsweredSend(io, allocator, send_iters);
    std.debug.print(
        "outbound_send iters={d} total_ns_per_msg={d:.1} clone_ns_per_msg={d:.1} engine_path_ns={d:.1} mode={s}\n",
        .{ send.iters, send.total_ns, send.clone_ns, send.total_ns - send.clone_ns, @tagName(builtin.mode) },
    );

    var storms: [3]StormMeasurement = undefined;
    var count: usize = 0;
    for (storm_qs) |q| {
        storms[count] = try measureGcStorm(io, allocator, q, storm_samples);
        const m = storms[count];
        count += 1;
        std.debug.print(
            "outbound_gc_storm q={d} wave_ns={d} ns_per_answer={d:.1} mode={s}\n",
            .{ m.q, m.wave_ns, m.ns_per_answer, @tagName(builtin.mode) },
        );
    }

    if (smoke) return;

    try writeReport(allocator, io, send, storms[0..count]);
    std.debug.print("outbound report written to zig-out/bench-reports/outbound.md\n", .{});
}

fn appendFmt(b: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try b.appendSlice(gpa, s);
}

fn writeReport(gpa: std.mem.Allocator, io: std.Io, send: SendMeasurement, storms: []const StormMeasurement) !void {
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);

    try appendFmt(&b, gpa,
        \\# The outbound engine path
        \\
        \\Generated by `zig build bench-outbound`. Mode: {s}.
        \\
        \\## One answered deliver, end to end
        \\
        \\`sendCopying` -> record (validate + retain walks) -> queue -> `step`
        \\(v1.0 resolver mint: export allocation + link insert + retain) ->
        \\encode -> outbound push -> `takeOutbound`. `bench-codec` times the
        \\encode share of this alone.
        \\
        \\| iters | total ns/msg | boundary clone ns/msg | engine path ns/msg |
        \\| ---: | ---: | ---: | ---: |
        \\| {d} | {d:.1} | {d:.1} | {d:.1} |
        \\
        \\## GC release storm (`op:gc-answers` over Q open answers)
        \\
        \\Q answered delivers opened, then one `op:gc-answers` releasing all Q,
        \\timed as a single send+step wave (median over fresh peers). Each
        \\release drops the answer's v1.0 resolver link through the session's
        \\answer-to-resolver inverse map, so ns/answer holds flat across Q;
        \\growth means a per-position scan crept back.
        \\
        \\| Q | wave (ns) | ns/answer |
        \\| ---: | ---: | ---: |
        \\
    , .{ @tagName(builtin.mode), send.iters, send.total_ns, send.clone_ns, send.total_ns - send.clone_ns });
    for (storms) |m| {
        try appendFmt(&b, gpa, "| {d} | {d} | {d:.1} |\n", .{ m.q, m.wave_ns, m.ns_per_answer });
    }
    try b.appendSlice(gpa, "\n");

    var dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "zig-out/bench-reports") catch {};
    try dir.writeFile(io, .{ .sub_path = "zig-out/bench-reports/outbound.md", .data = b.items });
}
