//! The native Zig client for the per-language consumer-cost bench. It drives the
//! taskboard unit against the fixed Zig host and prints one NDJSON metric line,
//! the same schema every other language's bench client emits (see
//! `bench/langs/contract.md`). Being native Zig on the same core every binding
//! wraps, it is the zero-overhead reference row: no interpreter, no JIT, no GC.
//!
//!   zig_bench <mode> <host> <port> <n>
//!
//! Modes: `latency`, `throughput`, `connections`, `cold` (one settled unit from
//! a fresh process, for the orchestrator's spawn-to-first-settle timing), and
//! `local` (the local-turn instrument: in-process actor dispatch vs the same
//! behavior forced across an in-process loopback pair; host/port unused).

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
fn runUnit(conn: *driver.Session, root: driver.Capability, arena: std.mem.Allocator) !void {
    const task = switch (try conn.call(root, "create", &.{.{ .bytes = "benchmark" }}, arena)) {
        .fulfilled => |arg| switch (arg) {
            .capability => |cap| cap,
            else => return error.CreateNotACapability,
        },
        .broken => return error.CreateBroke,
    };
    _ = try conn.call(task, "assign", &.{.{ .bytes = "alice" }}, arena);
    _ = try conn.call(task, "complete", &.{}, arena);
    const status = try conn.call(task, "status", &.{}, arena);
    const ok = status == .fulfilled and status.fulfilled == .bytes and
        std.mem.eql(u8, status.fulfilled.bytes, "done");
    if (!ok) return error.StatusNotDone;
}

/// The same four verbs as `runUnit`, but pipelined (ADR-0007, questioner half):
/// `assign`/`complete`/`status` are addressed at the *answer* `create` will
/// resolve to. The first two are one-way deliveries; only `status` allocates an
/// answer and settles. The whole unit therefore costs one round trip instead
/// of four without leaving discarded result promises behind.
fn runUnitPipelined(conn: *driver.Session, root: driver.Capability, arena: std.mem.Allocator) !void {
    const create = try conn.send(root, "create", &.{.{ .bytes = "benchmark" }});
    try create.tell("assign", &.{.{ .bytes = "alice" }});
    try create.tell("complete", &.{});
    const status_promise = try create.send("status", &.{});
    const status = try status_promise.settle(arena);
    try create.release();
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

fn connectOne(io: std.Io, allocator: std.mem.Allocator, designator: []const u8) !*driver.Session {
    var tcp_resident = tcp.Resident{ .io = io };
    return driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.locator(designator), .ephemeral, .{ .frame_cap = frame_cap, .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } });
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
    const warm = try allocator.alloc(*driver.Session, warmup);
    defer allocator.free(warm);
    for (0..warmup) |i| {
        warm[i] = try connectOne(io, allocator, designator);
        _ = try warm[i].fetch("root");
    }
    // The orchestrator samples the baseline resident set at this marker.
    try printLine(io, "{{\"v\":1,\"event\":\"warmed\"}}\n", .{});
    try io.sleep(std.Io.Duration.fromMilliseconds(600), .awake);

    const handles = try allocator.alloc(*driver.Session, n);
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
    for (handles) |h| h.deinit();
    for (warm) |h| h.deinit();
}

/// The local-turn counter: `hit` increments and returns the count, any other
/// verb refuses. The same behavior serves both paths of `runLocal`, spawned
/// in-vat for the in-language figure and published across the loopback pair
/// for the via-host one.
const Counter = struct {
    count: i64 = 0,

    pub fn handle(self: *Counter, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = ht;
        _ = args;
        if (!std.mem.eql(u8, verb, "hit")) return error.NoSuchMethod;
        self.count += 1;
        return .{ .integer = self.count };
    }
};

/// The accept half of the `local` mode's loopback pair: accept the one dialer,
/// publish the counter, and serve until it leaves. Runs on its own fiber; a
/// failure here would strand the dialing half in a blocked read, so it fails
/// the process loudly instead of returning quietly.
fn serveLocalCounter(server: *driver.Server) void {
    const conn = server.accept() catch |err| {
        std.debug.print("zig_bench local: accept failed: {t}\n", .{err});
        std.process.exit(1);
    };
    defer conn.deinit();
    _ = conn.publish("counter", Counter, .{}) catch |err| {
        std.debug.print("zig_bench local: publish failed: {t}\n", .{err});
        std.process.exit(1);
    };
    conn.serve() catch {};
}

/// Run `n` sequential hit units against `target` on `conn`, one settle per
/// send, returning the sorted per-turn latencies (ns). Asserts the final count
/// equals `n` (native Zig is ahead-of-time, so there is no warmup ahead of the
/// window and the counter starts at zero).
fn measureHits(io: std.Io, conn: *driver.Session, target: driver.Capability, n: usize, samples: []u64) !void {
    var arena_state = std.heap.ArenaAllocator.init(conn.allocator);
    defer arena_state.deinit();

    var final: i64 = 0;
    for (0..n) |i| {
        const start = nowNs(io);
        const settled = try conn.call(target, "hit", &.{}, arena_state.allocator());
        samples[i] = nowNs(io) - start;
        if (settled != .fulfilled or settled.fulfilled != .integer) return error.HitNotAnInteger;
        final = settled.fulfilled.integer;
        _ = arena_state.reset(.retain_capacity);
    }
    if (final != @as(i64, @intCast(n))) return error.BadFinalCount;
    std.sort.pdq(u64, samples, {}, lessThanU64);
}

fn meanNs(samples: []const u64) f64 {
    if (samples.len == 0) return 0;
    var total: u128 = 0;
    for (samples) |s| total += s;
    return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(samples.len));
}

/// Nearest-rank percentile over latencies already sorted ascending, in
/// nanoseconds (the `local` mode's unit; `percentileMs` is the same rank in
/// milliseconds).
fn percentileNs(sorted_ns: []const u64, p: f64) f64 {
    return percentileMs(sorted_ns, p) * 1_000_000.0;
}

/// The `local` mode (see contract.md): (a) in_lang — a counter spawned on this
/// connection's vat, hit through the native near path, no wire; (b) via_host —
/// the same behavior published across a loopback pair inside this process, so
/// every turn pays wire codec, feed, and dispatch both ways. The orchestrator's
/// host/port arguments are unused; the pair is self-contained.
fn runLocal(io: std.Io, allocator: std.mem.Allocator, n: usize) !void {
    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, .{ .frame_cap = frame_cap, .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } });
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const local_designator = try server.localDesignator(&addr_buf);

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    group.async(io, serveLocalCounter, .{server});

    var conn = try connectOne(io, allocator, local_designator);
    defer conn.deinit();

    const in_lang = try allocator.alloc(u64, n);
    defer allocator.free(in_lang);
    const via_host = try allocator.alloc(u64, n);
    defer allocator.free(via_host);

    // (a) in_lang: the vat near path this connection surface gives.
    const local_cap = try conn.spawn(Counter, .{});
    try measureHits(io, conn, local_cap, n, in_lang);

    // (b) via_host: the published counter across the loopback pair.
    const far = try conn.fetch("counter");
    try measureHits(io, conn, far, n, via_host);

    const in_mean = meanNs(in_lang);
    const via_mean = meanNs(via_host);
    const ratio: f64 = if (in_mean > 0) via_mean / in_mean else 0;

    try printLine(
        io,
        "{{\"v\":1,\"metric\":\"local\",\"client\":\"{s}\",\"suite\":\"local-turn\",\"n\":{d}," ++
            "\"in_lang_ns\":{d:.1},\"in_lang_p99_ns\":{d:.1},\"via_host_ns\":{d:.1},\"via_host_p99_ns\":{d:.1}," ++
            "\"ratio\":{d:.2},\"runtime\":\"{s}\",\"warmup_n\":0}}\n",
        .{ client_name, n, in_mean, percentileNs(in_lang, 0.99), via_mean, percentileNs(via_host, 0.99), ratio, runtime_name },
    );
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
    std.debug.print("usage: zig_bench <latency|throughput|connections|cold|local> <host> <port> <n>\n  ({s})\n", .{message});
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

    const port = try std.fmt.parseInt(u16, port_str, 10);
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try tcp.parseHostPort(host, port);
    const designator = tcp.locatorFromAddress(&designator_buf, designator_addr).designator;

    if (std.mem.eql(u8, mode, "latency")) {
        try runLatency(io, allocator, designator, n);
    } else if (std.mem.eql(u8, mode, "throughput")) {
        try runThroughput(io, allocator, designator, n);
    } else if (std.mem.eql(u8, mode, "connections")) {
        try runConnections(io, allocator, designator, n);
    } else if (std.mem.eql(u8, mode, "cold")) {
        try runCold(io, allocator, designator);
    } else if (std.mem.eql(u8, mode, "local")) {
        try runLocal(io, allocator, n);
    } else {
        return fail("unknown mode");
    }
}
