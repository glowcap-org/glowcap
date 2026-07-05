//! The native Zig client for the per-language consumer-cost bench. It drives the
//! taskboard unit against the fixed Zig host and prints one NDJSON metric line,
//! the same schema every other language's bench client emits (see
//! `bench/langs/contract.md`). Being native Zig on the same core every binding
//! wraps, it is the zero-overhead reference row: no interpreter, no JIT, no GC.
//!
//!   zig_bench <mode> <host> <port> <n>
//!
//! Modes: `latency`, `throughput`, `connections`, `cold` (one settled unit from
//! a fresh process, for the orchestrator's spawn-to-first-settle timing).

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net.tcp;

const frame_cap: usize = 1 << 16;
const client_name = "zig";
const runtime_name = "native-zig";

/// One bench unit: create a task, assign it, complete it, read its status, and
/// assert the status settled to the bytes `done`. The same four verbs every
/// client runs, sequential send-and-settle, no pipelining.
fn runUnit(conn: *driver.Connection, root: actors.Ref, arena: std.mem.Allocator) !void {
    const task = switch (try conn.call(root, .{ .verb = "create", .args = &.{.{ .bytes = "benchmark" }} }, arena)) {
        .fulfilled => |arg| switch (arg) {
            .reference => |reference| switch (reference) {
                .far => |far_ref| actors.Ref{ .far = far_ref },
                else => return error.CreateNotACapability,
            },
            else => return error.CreateNotACapability,
        },
        .broken => return error.CreateBroke,
    };
    _ = try conn.call(task, .{ .verb = "assign", .args = &.{.{ .bytes = "alice" }} }, arena);
    _ = try conn.call(task, .{ .verb = "complete", .args = &.{} }, arena);
    const status = try conn.call(task, .{ .verb = "status", .args = &.{} }, arena);
    const ok = status == .fulfilled and status.fulfilled == .bytes and
        std.mem.eql(u8, status.fulfilled.bytes, "done");
    if (!ok) return error.StatusNotDone;
}

/// The same four verbs as `runUnit`, but pipelined (ADR-0007, questioner half):
/// `assign`/`complete`/`status` are addressed at the *answer* `create` will
/// resolve to — sent without awaiting it — so the whole unit costs one round trip
/// instead of four. Only the final `status` is settled. This is the throughput
/// unit; `runUnit` stays sequential so the latency row keeps measuring one
/// round trip at a time.
fn runUnitPipelined(conn: *driver.Connection, root: actors.Ref, arena: std.mem.Allocator) !void {
    const create = try conn.send(root, .{ .verb = "create", .args = &.{.{ .bytes = "benchmark" }} });
    _ = try conn.sendToAnswer(create, .{ .verb = "assign", .args = &.{.{ .bytes = "alice" }} });
    _ = try conn.sendToAnswer(create, .{ .verb = "complete", .args = &.{} });
    const status_promise = try conn.sendToAnswer(create, .{ .verb = "status", .args = &.{} });
    const status = try conn.settlePromise(status_promise, arena);
    const ok = status == .fulfilled and status.fulfilled == .bytes and
        std.mem.eql(u8, status.fulfilled.bytes, "done");
    if (!ok) return error.StatusNotDone;
}

fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.now(.awake, io).nanoseconds);
}

/// Nearest-rank percentile over latencies already sorted ascending, `p` in
/// [0,1], returned in milliseconds.
fn percentileMs(sorted_ns: []const u64, p: f64) f64 {
    if (sorted_ns.len == 0) return 0;
    const rank: usize = @intFromFloat(@ceil(p * @as(f64, @floatFromInt(sorted_ns.len))));
    const idx = if (rank == 0) 0 else @min(sorted_ns.len - 1, rank - 1);
    return @as(f64, @floatFromInt(sorted_ns[idx])) / 1_000_000.0;
}

fn lessThanU64(_: void, a: u64, b: u64) bool {
    return a < b;
}

fn connectOne(io: std.Io, allocator: std.mem.Allocator, designator: []const u8) !*driver.Connection {
    var tcp_resident = tcp.Resident{ .io = io };
    return driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.at(designator), .ephemeral, .{ .frame_cap = frame_cap });
}

fn runLatency(io: std.Io, allocator: std.mem.Allocator, designator: []const u8, n: usize) !void {
    var conn = try connectOne(io, allocator, designator);
    defer conn.deinit();
    const root = try conn.fetch("root");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const samples = try allocator.alloc(u64, n);
    defer allocator.free(samples);

    for (0..n) |i| {
        const start = nowNs(io);
        try runUnit(conn, root, arena_state.allocator());
        samples[i] = nowNs(io) - start;
        _ = arena_state.reset(.retain_capacity);
    }
    std.sort.pdq(u64, samples, {}, lessThanU64);

    var total: u128 = 0;
    for (samples) |s| total += s;
    const mean_ms = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(n)) / 1_000_000.0;

    try printLine(
        io,
        "{{\"v\":1,\"metric\":\"latency\",\"client\":\"{s}\",\"suite\":\"taskboard\",\"n\":{d}," ++
            "\"p50_ms\":{d:.4},\"p99_ms\":{d:.4},\"p999_ms\":{d:.4},\"mean_ms\":{d:.4}," ++
            "\"runtime\":\"{s}\",\"warmup_n\":0}}\n",
        .{ client_name, n, percentileMs(samples, 0.50), percentileMs(samples, 0.99), percentileMs(samples, 0.999), mean_ms, runtime_name },
    );
}

fn runThroughput(io: std.Io, allocator: std.mem.Allocator, designator: []const u8, n: usize) !void {
    var conn = try connectOne(io, allocator, designator);
    defer conn.deinit();
    const root = try conn.fetch("root");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const start = nowNs(io);
    for (0..n) |_| {
        try runUnitPipelined(conn, root, arena_state.allocator());
        _ = arena_state.reset(.retain_capacity);
    }
    const total_ms = @as(f64, @floatFromInt(nowNs(io) - start)) / 1_000_000.0;
    const rps: f64 = if (total_ms <= 0) 0 else @as(f64, @floatFromInt(n)) / (total_ms / 1000.0);

    try printLine(
        io,
        "{{\"v\":1,\"metric\":\"throughput\",\"client\":\"{s}\",\"suite\":\"taskboard\",\"n\":{d}," ++
            "\"total_ms\":{d:.2},\"rps\":{d:.0},\"runtime\":\"{s}\",\"warmup_n\":0}}\n",
        .{ client_name, n, total_ms, rps, runtime_name },
    );
}

fn runConnections(io: std.Io, allocator: std.mem.Allocator, designator: []const u8, n: usize) !void {
    const warmup = @min(n, 5);
    const warm = try allocator.alloc(*driver.Connection, warmup);
    defer allocator.free(warm);
    for (0..warmup) |i| {
        warm[i] = try connectOne(io, allocator, designator);
        _ = try warm[i].fetch("root");
    }
    // The orchestrator samples the baseline resident set at this marker.
    try printLine(io, "{{\"v\":1,\"event\":\"warmed\"}}\n", .{});
    try io.sleep(std.Io.Duration.fromMilliseconds(600), .awake);

    const handles = try allocator.alloc(*driver.Connection, n);
    defer allocator.free(handles);
    const start = nowNs(io);
    for (0..n) |i| {
        handles[i] = try connectOne(io, allocator, designator);
        _ = try handles[i].fetch("root");
    }
    const total_ms = @as(f64, @floatFromInt(nowNs(io) - start)) / 1_000_000.0;
    const per_conn = total_ms / @as(f64, @floatFromInt(@max(1, n)));

    try printLine(
        io,
        "{{\"v\":1,\"metric\":\"connections\",\"client\":\"{s}\",\"suite\":\"taskboard\"," ++
            "\"conns\":{d},\"total_ms\":{d:.2},\"per_conn_ms\":{d:.4},\"runtime\":\"{s}\"}}\n",
        .{ client_name, n, total_ms, per_conn, runtime_name },
    );
    // Hold every connection open while the orchestrator takes its loaded sample.
    try io.sleep(std.Io.Duration.fromMilliseconds(2500), .awake);
    for (handles) |h| h.close();
    for (warm) |h| h.close();
}

fn runCold(io: std.Io, allocator: std.mem.Allocator, designator: []const u8) !void {
    var conn = try connectOne(io, allocator, designator);
    defer conn.deinit();
    const root = try conn.fetch("root");
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    try runUnit(conn, root, arena_state.allocator());
    try printLine(io, "{{\"v\":1,\"event\":\"cold-done\",\"client\":\"{s}\"}}\n", .{client_name});
}

fn printLine(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    try stdout.interface.print(fmt, args);
    try stdout.interface.flush();
}

fn fail(message: []const u8) error{Usage} {
    std.debug.print("usage: zig_bench <latency|throughput|connections|cold> <host> <port> <n>\n  ({s})\n", .{message});
    return error.Usage;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse return fail("missing <mode>");
    const host = args.next() orelse return fail("missing <host>");
    const port_str = args.next() orelse return fail("missing <port>");
    const n_str = args.next() orelse "0";
    const n = try std.fmt.parseInt(usize, n_str, 10);

    var designator_buf: [64]u8 = undefined;
    const designator = try std.fmt.bufPrint(&designator_buf, "{s}:{s}", .{ host, port_str });

    if (std.mem.eql(u8, mode, "latency")) {
        try runLatency(io, allocator, designator, n);
    } else if (std.mem.eql(u8, mode, "throughput")) {
        try runThroughput(io, allocator, designator, n);
    } else if (std.mem.eql(u8, mode, "connections")) {
        try runConnections(io, allocator, designator, n);
    } else if (std.mem.eql(u8, mode, "cold")) {
        try runCold(io, allocator, designator);
    } else {
        return fail("unknown mode");
    }
}
