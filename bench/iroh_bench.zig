//! Round-trip latency and throughput of a full OCapN call over a real socket,
//! measured for the encrypted iroh transport and, on the same machine, the
//! cleartext TCP transport as a baseline.
//!
//! Each sample is one synchronous `greet` round-trip: an `op:deliver` out and a
//! resolve back over a live connection between two runtimes in this process:
//! a `driver.Server` thread that publishes a greeter and serves, and a
//! `driver.Session` client that fetches once and then calls in a loop. No pipelining; one call is in
//! flight at a time, so the per-call number is the wire's serial latency and the
//! throughput is its reciprocal.
//!
//! The iroh path carries the bytes over real keyed QUIC endpoints; only the
//! address is resolved in-process (the `local_discovery` posture), so the data
//! path is the encrypted channel, not a stub. The gap between the two transports
//! is what the QUIC stack, the encryption, and the Rust sidecar's FFI boundary
//! cost over loopback. It is not a real-network measurement: loopback removes the
//! propagation delay and packet loss a relayed or hole-punched path would add, so
//! read this as the floor of the transport's own overhead, not field latency.
//!
//! Like the other benches, it reports numbers and gates none of them. Under
//! `zig build check` it would run in Debug; it is not on `check` because it links
//! the Rust sidecar. Read the printed `mode=` field and run with
//! `-Doptimize=ReleaseFast` for absolute figures: `zig build bench-iroh`.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const iroh = @import("iroh");

const model = glowcap.ocapn.model;
const crypto = glowcap.foundation.crypto;
const driver = glowcap.driver;

const frame_cap: usize = 4096;
const greeting = "hello over the wire";

/// Finite waits for every dial and settle: a partner that wedges fails the
/// bench loudly instead of parking it, which is the cli rule's posture for
/// anything that dials. Sixty seconds dwarfs any healthy call here.
const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 60_000 },
    .settle = .{ .ms = 60_000 },
};

/// The published actor: answers `greet` with a static greeting so the timed loop
/// measures the transport and the protocol turn, not application work.
const Greeter = struct {
    pub fn handle(_: *Greeter, _: *driver.HostTurn, verb: []const u8, _: []const driver.Value) !driver.Value {
        if (!std.mem.eql(u8, verb, "greet")) return error.NoSuchMethod;
        return .{ .string = greeting };
    }
};

/// Server half: accept every partner, attend it, and serve until `done`.
fn serve(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    var sessions: [loop_conns]*driver.Session = undefined;
    var accepted: usize = 0;
    defer for (sessions[0..accepted]) |session| session.deinit();
    while (!done.load(.acquire)) {
        if (accepted < sessions.len and try server.waitAcceptable(0)) {
            sessions[accepted] = try server.accept();
            accepted += 1;
            // An accepted session dispatches nothing until its owner attends.
            try sessions[accepted - 1].attend();
            continue;
        }
        _ = try server.runtime.stepAny(10);
    }
}

/// Monotonic clock read in nanoseconds. `.awake` is `CLOCK_MONOTONIC`.
fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}

/// Client half: connect, fetch the greeter once, warm the path, then time
/// `samples.len` sequential calls into `samples` (nanoseconds each).
fn clientMeasure(
    io: std.Io,
    allocator: std.mem.Allocator,
    transports: driver.Transports,
    locator: model.PeerLocator,
    warmup: usize,
    samples: []u64,
) !void {
    const session = try driver.connect(allocator, io, transports, locator, .ephemeral, opts);
    defer session.deinit();
    const greeter = try session.fetch("greeter");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (0..warmup) |_| {
        _ = arena_state.reset(.retain_capacity);
        if (!try callOnce(session, greeter, arena)) return error.WrongReply;
    }

    for (samples) |*sample| {
        _ = arena_state.reset(.retain_capacity);
        const t0 = nowNs(io);
        const ok = try callOnce(session, greeter, arena);
        const t1 = nowNs(io);
        if (!ok) return error.WrongReply;
        sample.* = @intCast(t1 - t0);
    }
}

fn callOnce(session: *driver.Session, greeter: driver.Capability, arena: std.mem.Allocator) !bool {
    return switch (try session.call(greeter, "greet", &.{.{ .string = "world" }}, arena)) {
        .fulfilled => |value| value == .string and std.mem.eql(u8, value.string, greeting),
        .broken => false,
    };
}

fn lessThan(_: void, a: u64, b: u64) bool {
    return a < b;
}

/// Sort `samples` in place and print one structured `roundtrip` line: the median
/// and 99th-percentile latency, the mean, and the reciprocal-of-mean throughput.
fn report(transport: []const u8, warmup: usize, samples: []u64) void {
    std.mem.sort(u64, samples, {}, lessThan);
    const n = samples.len;
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean_ns: f64 = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n));
    const p50 = samples[n / 2];
    const p99 = samples[(n * 99) / 100];
    const rps: f64 = if (mean_ns > 0) 1_000_000_000.0 / mean_ns else 0;
    std.debug.print(
        "roundtrip transport={s} calls={d} warmup={d} p50_ns={d} p99_ns={d} mean_ns={d:.0} rps={d:.0} mode={s}\n",
        .{ transport, n, warmup, p50, p99, mean_ns, rps, @tagName(builtin.mode) },
    );
}

/// Serve one Server on its own thread while `measure` runs, then join it.
fn withServer(io: std.Io, server: *driver.Server, measure: anytype, measure_args: anytype) !void {
    var done = std.atomic.Value(bool).init(false);
    var serving = try io.concurrent(serve, .{ server, &done });
    const measured = @call(.auto, measure, measure_args);
    done.store(true, .release);
    const served = serving.await(io);
    try measured;
    try served;
}

/// Run the TCP baseline: a loopback listener on an ephemeral port, dialed by the
/// bound `host:port` the listener reports.
fn benchTcp(io: std.Io, allocator: std.mem.Allocator, warmup: usize, samples: []u64) !void {
    const transports: driver.Transports = .{ .symbols = &.{.tcp} };
    var server = try driver.listen(allocator, io, transports, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer server.deinit();
    try server.publish("greeter", Greeter, .{});
    const locator = try model.clonePeerLocator(allocator, try server.advertisedLocator());
    defer model.freePeerLocator(allocator, locator);
    try withServer(io, server, clientMeasure, .{ io, allocator, transports, locator, warmup, samples });
    report("tcp", warmup, samples);
}

/// One iroh endpoint and the resident its runtime polls.
const Endpoint = struct {
    endpoint: iroh.Resident,
    adapter: iroh.MultiplexedAdapter,
    providers: [1]driver.HostRuntime.ProviderRegistration = undefined,

    fn init(self: *Endpoint, io: std.Io, allocator: std.mem.Allocator, seed: ?*const [32]u8) !void {
        self.endpoint = try iroh.Resident.init(io, seed, .{ .reachability = .local_discovery });
        errdefer self.endpoint.deinit() catch {};
        self.adapter = try iroh.MultiplexedAdapter.init(allocator, &self.endpoint);
        self.providers = .{.{ .profile = iroh.transport_profile, .resident = self.adapter.multiplexed() }};
    }

    fn deinit(self: *Endpoint) void {
        if (self.adapter.deinit()) |failure| std.log.err("iroh adapter: {s}", .{failure.primaryName()});
        self.endpoint.deinit() catch |err| std.log.err("iroh endpoint teardown failed: {s}", .{@errorName(err)});
    }

    fn transports(self: *Endpoint) driver.Transports {
        return .{ .residents = &self.providers };
    }

    /// A Server signing with the endpoint's own key: a key-designator dial
    /// pins the session to the dialed node id.
    fn listen(self: *Endpoint, io: std.Io, allocator: std.mem.Allocator, seed: [32]u8) !*driver.Server {
        const server = try driver.listen(allocator, io, self.transports(), iroh.transport_name, .{ .designator = "" }, .{
            .keyed = crypto.SecretKey.fromSeed(seed),
        }, opts);
        errdefer server.deinit();
        try server.publish("greeter", Greeter, .{});
        return server;
    }

    fn locator(self: *Endpoint, id_buf: *[iroh.node_id_len]u8) model.PeerLocator {
        return .{ .transport = iroh.transport_name, .designator = self.endpoint.nodeId(id_buf), .hints = model.Hints.emptyFalse() };
    }
};

/// Run the iroh path: two real iroh endpoints, the client dialing the server by
/// its node id alone through the deterministic in-process address book.
fn benchIroh(io: std.Io, allocator: std.mem.Allocator, warmup: usize, samples: []u64) !void {
    const server_seed: [32]u8 = @splat(0x61);
    var server_endpoint: Endpoint = undefined;
    try server_endpoint.init(io, allocator, &server_seed);
    defer server_endpoint.deinit();
    var client_endpoint: Endpoint = undefined;
    try client_endpoint.init(io, allocator, null);
    defer client_endpoint.deinit();

    var server = try server_endpoint.listen(io, allocator, server_seed);
    defer server.deinit();
    var id_buf: [iroh.node_id_len]u8 = undefined;
    try withServer(io, server, clientMeasure, .{ io, allocator, client_endpoint.transports(), server_endpoint.locator(&id_buf), warmup, samples });
    report("iroh", warmup, samples);
}

// ── iroh at its design point: many connections on one serving thread ─────────
// The serial bench above is one connection, one call in flight, the worst case
// for the async sidecar bridge, where every read pays a cross-thread wakeup
// with nothing to amortize it against. One Server thread multiplexing many
// connections through the endpoint's single readiness descriptor is the path
// iroh is built to be served on (ADR-0057). This measures the
// aggregate round-trip throughput there, so the page can show that the serial
// single-stream number is a floor, not the transport's capacity.

/// Connections multiplexed on the one serving thread for the throughput run.
/// Fixed (comptime) so the futures array is sized at compile time.
const loop_conns: usize = 16;

/// Cross-thread start barrier: each client signals `ready` once it is connected
/// and warm, then parks on `go` so every connection's timed calls overlap. The
/// throughput window thus excludes the per-endpoint bind and connect, which would
/// otherwise dominate it.
const LoopSync = struct {
    ready: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    go: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// One throughput client: bind its own iroh endpoint, dial the server by id
/// alone, fetch the greeter, warm the path, then, once every client is at the
/// barrier, make `calls` sequential calls. Its own connection is serial; the
/// concurrency across the `loop_conns` clients is what the one thread
/// multiplexes.
fn loopClient(
    io: std.Io,
    allocator: std.mem.Allocator,
    server_locator: model.PeerLocator,
    warmup: usize,
    calls: usize,
    sync: *LoopSync,
) anyerror!void {
    var endpoint: Endpoint = undefined;
    try endpoint.init(io, allocator, null);
    defer endpoint.deinit();
    const session = try driver.connect(allocator, io, endpoint.transports(), server_locator, .ephemeral, opts);
    defer session.deinit();
    const greeter = try session.fetch("greeter");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (0..warmup) |_| {
        _ = arena_state.reset(.retain_capacity);
        if (!try callOnce(session, greeter, arena)) return error.WrongReply;
    }

    _ = sync.ready.fetchAdd(1, .acq_rel);
    while (!sync.go.load(.acquire)) std.Thread.yield() catch {};

    for (0..calls) |_| {
        _ = arena_state.reset(.retain_capacity);
        if (!try callOnce(session, greeter, arena)) return error.WrongReply;
    }
}

/// Aggregate round-trip throughput when one Server thread serves `loop_conns`
/// connections at once. Prints one `loop` line; the serial bench's per-stream
/// reciprocal is the contrast the page draws.
fn benchIrohLoop(io: std.Io, allocator: std.mem.Allocator, warmup: usize, calls: usize) !void {
    const server_seed: [32]u8 = @splat(0x62);
    var server_endpoint: Endpoint = undefined;
    try server_endpoint.init(io, allocator, &server_seed);
    defer server_endpoint.deinit();
    var server = try server_endpoint.listen(io, allocator, server_seed);
    defer server.deinit();
    var id_buf: [iroh.node_id_len]u8 = undefined;
    const server_locator = server_endpoint.locator(&id_buf);

    var done = std.atomic.Value(bool).init(false);
    var serving = try io.concurrent(serve, .{ server, &done });

    var sync = LoopSync{};
    var futures: [loop_conns]@TypeOf(io.concurrent(loopClient, .{ io, allocator, server_locator, warmup, calls, &sync }) catch unreachable) = undefined;
    var started: usize = 0;
    var first_err: ?anyerror = null;
    while (started < loop_conns) : (started += 1) {
        futures[started] = io.concurrent(loopClient, .{ io, allocator, server_locator, warmup, calls, &sync }) catch |err| {
            first_err = err;
            break;
        };
    }

    // Every client connected and warm: open the gate and time the overlapped
    // calls. A client that fails before the barrier ends the wait early.
    while (first_err == null and sync.ready.load(.acquire) < started) std.Thread.yield() catch {};
    const t0 = nowNs(io);
    sync.go.store(true, .release);

    for (futures[0..started]) |*f| {
        if (f.await(io)) |_| {} else |err| {
            if (first_err == null) first_err = err;
        }
    }
    const t1 = nowNs(io);

    done.store(true, .release);
    const served = serving.await(io);
    if (first_err) |err| return err;
    try served;

    const total: u64 = @intCast(loop_conns * calls);
    const secs: f64 = @as(f64, @floatFromInt(t1 - t0)) / 1_000_000_000.0;
    const rps: f64 = if (secs > 0) @as(f64, @floatFromInt(total)) / secs else 0;
    std.debug.print(
        "loop transport=iroh conns={d} calls_each={d} aggregate_rps={d:.0} mode={s}\n",
        .{ loop_conns, calls, rps, @tagName(builtin.mode) },
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    var smoke = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke = true;
    }

    const calls: usize = if (smoke) 200 else 3000;
    const warmup: usize = if (smoke) 50 else 300;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const samples = try allocator.alloc(u64, calls);
    defer allocator.free(samples);

    try benchTcp(io, allocator, warmup, samples);
    try benchIroh(io, allocator, warmup, samples);

    // iroh's design point: aggregate throughput with many connections on one
    // serving thread, the contrast to the serial single-stream number above.
    const loop_calls: usize = if (smoke) 50 else 300;
    const loop_warmup: usize = if (smoke) 5 else 20;
    try benchIrohLoop(io, allocator, loop_warmup, loop_calls);
}
