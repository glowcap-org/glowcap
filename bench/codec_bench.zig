//! Throughput benchmarks for codec encode/decode, steady-state inbound dispatch,
//! and sparse export-table inserts.
//!
//! The alloc-budget test gates per-turn allocation count (`== 1`). This bench
//! reports ns/op and MB/s as visible numbers, not gated thresholds. Under
//! `zig build check` it runs in Debug, read the printed `mode=` field and compare
//! relative regressions, or run with `-Doptimize=ReleaseFast` for absolute figures.
//!
//! Timing uses `std.Io`'s monotonic clock (`.awake`) in the harness only.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const codec = glowcap.ocapn.codec;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const foundation = glowcap.foundation;

/// A representative outbound call: a method invocation on an imported object
/// carrying a small mixed-type argument list and an answer position. This is the
/// common `op:deliver` the hot path encodes and decodes.
const bench_args = [_]model.Argument{
    .{ .symbol = "greet" },
    .{ .string = "hello, world" },
    .{ .integer = 42 },
    .{ .bytes = "\x00\x01\x02\x03" },
    .{ .boolean = true },
};

fn benchMessage() model.Message {
    return .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(5) },
        .args = &bench_args,
        .answer = .from(7),
    } };
}

/// The `report` call the round-trip benches send (`bench/iroh_bench.zig`): a
/// source name, eight tags, sixty-four integer readings, and a timestamp.
/// Its cost is per value, so it shows what the decoder pays for each element
/// of a list rather than for the frame.
const report_tags = [_]model.Argument{
    .{ .string = "site:north-shed" },
    .{ .string = "unit:percent" },
    .{ .string = "calibrated" },
    .{ .string = "interval:1s" },
    .{ .string = "sensor:sht45" },
    .{ .string = "firmware:2.4.1" },
    .{ .string = "battery:ok" },
    .{ .string = "quality:raw" },
};
const report_samples = blk: {
    var samples: [64]model.Argument = undefined;
    for (&samples, 0..) |*sample, i| sample.* = .{ .integer = 349_000 + @as(i64, @intCast(i)) * 37 };
    break :blk samples;
};
const report_args = [_]model.Argument{
    .{ .symbol = "report" },
    .{ .string = "sensor-17/humidity" },
    .{ .list = &report_tags },
    .{ .list = &report_samples },
    .{ .integer = 1_760_400_000 },
};

fn reportMessage() model.Message {
    return .{ .deliver = .{
        .target = .{ .far = model.FarRef.object(5) },
        .args = &report_args,
        .answer = .from(7),
    } };
}

/// Monotonic clock read in nanoseconds. `.awake` is `CLOCK_MONOTONIC`.
fn nowNs(io: std.Io) f64 {
    return @floatFromInt(std.Io.Clock.now(.awake, io).nanoseconds);
}

/// Encode `iters` copies of `message`, freeing each frame, and report ns/op and
/// MB/s over the encoded frame size.
fn benchEncode(
    io: std.Io,
    allocator: std.mem.Allocator,
    codec_id: model.CodecId,
    call: []const u8,
    message: model.Message,
    iters: usize,
) !void {
    // Warm encode to learn frame size for the throughput figure.
    var probe = try codec.dispatch.encodeMessageForProfile(codec_id, allocator, model.CaptpVersion.v1_0, message);
    const frame_len = probe.bytes().len;
    probe.deinit();

    const start = nowNs(io);
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        var frame = try codec.dispatch.encodeMessageForProfile(codec_id, allocator, model.CaptpVersion.v1_0, message);
        std.mem.doNotOptimizeAway(frame.bytes().len);
        frame.deinit();
    }
    report("encode", codec_id, call, iters, frame_len, nowNs(io) - start);
}

/// Decode (project a borrowed view of) the same encoded frame `iters` times.
/// Pure parse, no allocation, so this isolates the codec's structural decode.
fn benchDecode(
    io: std.Io,
    allocator: std.mem.Allocator,
    codec_id: model.CodecId,
    call: []const u8,
    message: model.Message,
    iters: usize,
) !void {
    var frame = try codec.dispatch.encodeMessageForProfile(codec_id, allocator, model.CaptpVersion.v1_0, message);
    defer frame.deinit();
    const frame_len = frame.bytes().len;
    const view = frame.view();

    const start = nowNs(io);
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        const body = try codec.dispatch.decodeBody(codec_id, view);
        std.mem.doNotOptimizeAway(&body);
    }
    report("decode", codec_id, call, iters, frame_len, nowNs(io) - start);
}

/// Decode the same frame `iters` times into the argument room the engine
/// lends a frame of this size (`engine.events.headViewsFor`), the
/// production shape: every list is parsed once into views, so this is the
/// decoder's whole per-value cost and nothing is left for a later walk.
fn benchDecodeInto(
    io: std.Io,
    allocator: std.mem.Allocator,
    codec_id: model.CodecId,
    call: []const u8,
    message: model.Message,
    iters: usize,
) !void {
    var frame = try codec.dispatch.encodeMessageForProfile(codec_id, allocator, model.CaptpVersion.v1_0, message);
    defer frame.deinit();
    const frame_len = frame.bytes().len;
    const view = frame.view();
    const views = try allocator.alloc(model.view.Argument, engine.events.headViewsFor(frame_len));
    defer allocator.free(views);

    const start = nowNs(io);
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        var slab = model.view.ValueSlab.init(std.mem.sliceAsBytes(views));
        var body: model.view.Body = undefined;
        try codec.dispatch.decodeBodyInto(codec_id, model.CaptpVersion.v1_0, view, &slab, &body);
        std.mem.doNotOptimizeAway(&body);
    }
    report("decode-into", codec_id, call, iters, frame_len, nowNs(io) - start);
}

/// Steady-state inbound dispatch: feed a borrowed `op:deliver` to a live export
/// and drain the surfaced event. Complements `test/engine/alloc_budget_test.zig`.
fn benchDispatch(io: std.Io, allocator: std.mem.Allocator, turns: usize) !void {
    // No-answer (`#f` answer) deliver: driven repeatedly to one peer below, so a
    // live-answer position would be refused on the second apply.
    const deliver_to_live_export = "<10'op:deliver<11'desc:export7+>[5:hello]ff>";
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();
    try peer.exportObject(7);

    for (0..8) |_| try driveOneTurn(&peer, deliver_to_live_export);

    const start = nowNs(io);
    for (0..turns) |_| try driveOneTurn(&peer, deliver_to_live_export);
    const ns_per = (nowNs(io) - start) / @as(f64, @floatFromInt(turns));

    std.debug.print(
        "dispatch turns={d} ns_per_turn={d:.1} turns_per_sec={d:.0}\n",
        .{ turns, ns_per, 1_000_000_000.0 / ns_per },
    );
}

fn driveOneTurn(peer: *engine.Peer, frame_bytes: []const u8) !void {
    try peer.recvBorrowed(.{ .bytes = frame_bytes, .shape = .byte });
    while (peer.pollEvent()) |event_in| {
        var event = event_in;
        event.deinit();
    }
}

/// Populate the import table with `count` *sparse* positions (stride well above
/// 1 so a flat backing store would balloon) and time the inserts. The partner
/// chooses import positions, so that table is an integer-keyed hash and a
/// peer naming sparse positions cannot force O(position) memory or scan cost
/// (see docs/architecture.md). This keeps that cost a measured constant, not
/// a claim. Export positions are this side's own and live in a slab, so a
/// sparse export is the chooser's cost, not an attack.
fn benchSparseImportTable(io: std.Io, allocator: std.mem.Allocator, count: usize) !void {
    var peer = engine.Peer.init(allocator);
    defer peer.deinit();

    const stride: u64 = 0x1_0000_0001; // sparse, far beyond any flat-vector size
    const start = nowNs(io);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        try peer.session_state.registerImport(.from(@as(u64, i) * stride + 1));
    }
    const ns_per = (nowNs(io) - start) / @as(f64, @floatFromInt(count));

    std.debug.print(
        "sparse_import_table inserts={d} ns_per_insert={d:.1}\n",
        .{ count, ns_per },
    );
}

/// One structured line per measurement. The site report reads the `greet`
/// lines by their leading fields (`bench/site_report.rkt`), so `call` trails.
fn report(op: []const u8, codec_id: model.CodecId, call: []const u8, iters: usize, frame_len: usize, elapsed_ns: f64) void {
    const ns_per: f64 = elapsed_ns / @as(f64, @floatFromInt(iters));
    const total_bytes: f64 = @floatFromInt(iters * frame_len);
    const mb_per_sec: f64 = (total_bytes / 1_000_000.0) / (elapsed_ns / 1_000_000_000.0);
    std.debug.print(
        "{s} codec={s} iters={d} frame_bytes={d} ns_per_op={d:.1} mb_per_sec={d:.0} mode={s} call={s}\n",
        .{ op, @tagName(codec_id), iters, frame_len, ns_per, mb_per_sec, @tagName(builtin.mode), call },
    );
}

pub fn main() !void {
    const allocator = std.heap.smp_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const message = benchMessage();

    const codec_iters: usize = 200_000;
    for ([_]model.CodecId{ .syrup, .capnp }) |codec_id| {
        try benchEncode(io, allocator, codec_id, "greet", message, codec_iters);
        try benchDecode(io, allocator, codec_id, "greet", message, codec_iters);
        try benchDecodeInto(io, allocator, codec_id, "greet", message, codec_iters);
    }
    const report_message = reportMessage();
    for ([_]model.CodecId{ .syrup, .capnp }) |codec_id| {
        try benchEncode(io, allocator, codec_id, "report", report_message, codec_iters);
        try benchDecodeInto(io, allocator, codec_id, "report", report_message, codec_iters);
    }

    try benchDispatch(io, allocator, 50_000);
    try benchSparseImportTable(io, allocator, 100_000);
}
