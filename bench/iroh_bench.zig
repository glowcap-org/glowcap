//! Round-trip latency and throughput of a full OCapN call over a real socket,
//! measured for the encrypted iroh transport and, on the same machine, the
//! cleartext TCP transport as a baseline.
//!
//! Each sample is one synchronous `greet` round-trip — an `op:deliver` out and a
//! resolve back — over a live connection between two residents in this process:
//! a server thread that accepts, publishes a greeter, and serves, and a client
//! that fetches once and then calls in a loop. No pipelining; one call is in
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
const pancake = @import("pancake");
const iroh = @import("iroh");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;

const frame_cap: usize = 4096;
const greeting = "hello over the wire";

const IrohLoop = net.completion.Loop(iroh.Backend, iroh.DialResolver);
const IrohBridge = driver.Bridge(IrohLoop);

/// The published actor: answers `greet` with a static greeting so the timed loop
/// measures the transport and the protocol turn, not application work.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "greet")) return error.NoSuchMethod;
        return .{ .string = greeting };
    }
};

/// Server half: accept one partner over `listener` signing with `identity`
/// (the tcp arm accepts ephemeral; the iroh arm signs with its endpoint's own
/// key, since a key-designator dial pins the session to the dialed node id),
/// publish the greeter, and serve until the client closes, the client's
/// `cv.deinit` ends this serve.
fn hostOnce(listener: net.netlayer.Listener, allocator: std.mem.Allocator, identity: driver.AcceptIdentity) anyerror!void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var cv = try driver.acceptVia(allocator, listener, &peer, identity, read_buf, write_buf, 0);
    defer cv.deinit();
    _ = try cv.publish("greeter", Greeter, .{});
    try cv.serve();
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
    netlayers: []const net.netlayer.Netlayer,
    locator: model.PeerLocator,
    warmup: usize,
    samples: []u64,
) !void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var cv = try driver.connectVia(allocator, netlayers, &peer, locator, .ephemeral, read_buf, write_buf, 0);
    defer cv.deinit();

    const greeter = try cv.fetch("greeter");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var w: usize = 0;
    while (w < warmup) : (w += 1) {
        _ = arena_state.reset(.retain_capacity);
        if (!try callOnce(&cv, greeter, arena)) return error.WrongReply;
    }

    for (samples) |*sample| {
        _ = arena_state.reset(.retain_capacity);
        const t0 = nowNs(io);
        const ok = try callOnce(&cv, greeter, arena);
        const t1 = nowNs(io);
        if (!ok) return error.WrongReply;
        sample.* = @intCast(t1 - t0);
    }
}

fn callOnce(cv: *driver.BlockingSession, greeter: anytype, arena: std.mem.Allocator) !bool {
    const settled = try cv.call(greeter, .{ .verb = "greet", .args = &.{.{ .string = "world" }} }, arena);
    return switch (settled) {
        .fulfilled => |arg| arg == .string and std.mem.eql(u8, arg.string, greeting),
        .broken, .give => false,
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

/// Run the TCP baseline: a loopback listener on an ephemeral port, dialed by the
/// bound `host:port` the listener reports.
fn benchTcp(io: std.Io, allocator: std.mem.Allocator, warmup: usize, samples: []u64) !void {
    var resident = net.tcp.Resident{ .io = io };
    const entries = [_]net.netlayer.Netlayer{resident.netlayer()};

    var listener = try net.netlayer.resolve(&entries, net.tcp.transport_name).?.listen(allocator, .{
        .designator = "127.0.0.1:0",
        .hints = model.Hints.emptyFalse(),
    });
    defer listener.close();

    var addr_buf: [64]u8 = undefined;
    const designator = listener.localDesignator(&addr_buf);

    var host = try io.concurrent(hostOnce, .{ listener, allocator, driver.AcceptIdentity.ephemeral });
    const client_result = clientMeasure(io, allocator, &entries, net.tcp.at(designator), warmup, samples);
    const host_result = host.await(io);
    try client_result;
    try host_result;
    report("tcp", warmup, samples);
}

/// Run the iroh path: two real iroh endpoints, the client dialing the server by
/// its node id alone through the deterministic in-process address book.
fn benchIroh(io: std.Io, allocator: std.mem.Allocator, warmup: usize, samples: []u64) !void {
    const server_seed: [32]u8 = @splat(0x61);
    const server_secret = pancake.foundation.crypto.SecretKey.fromSeed(server_seed);
    var server = try iroh.Resident.init(io, &server_seed, .{ .reachability = .local_discovery });
    defer server.deinit();
    var client = try iroh.Resident.init(io, null, .{ .reachability = .local_discovery });
    defer client.deinit();

    const server_entries = [_]net.netlayer.Netlayer{server.netlayer()};
    const client_entries = [_]net.netlayer.Netlayer{client.netlayer()};

    var listener = try net.netlayer.resolve(&server_entries, iroh.transport_name).?.listen(allocator, .{
        .designator = "",
        .hints = model.Hints.emptyFalse(),
    });
    defer listener.close();

    var id_buf: [iroh.node_id_len]u8 = undefined;
    const server_id = server.nodeId(&id_buf);
    const locator: model.PeerLocator = .{
        .transport = iroh.transport_name,
        .designator = server_id,
        .hints = model.Hints.emptyFalse(),
    };

    var host = try io.concurrent(hostOnce, .{ listener, allocator, driver.AcceptIdentity{ .keyed = server_secret } });
    const client_result = clientMeasure(io, allocator, &client_entries, locator, warmup, samples);
    const host_result = host.await(io);
    try client_result;
    try host_result;
    report("iroh", warmup, samples);
}

// ── iroh at its design point: many connections on one readiness loop ──────────
// The serial bench above is one connection, one call in flight, the worst case
// for the async sidecar bridge, where every blocking read pays a cross-thread
// `block_on` wakeup with nothing to amortize it against. ADR-0057's readiness
// loop is the path iroh is built to be served on: one thread multiplexes many
// connections through the endpoint's single readiness fd. This measures the
// aggregate round-trip throughput there, so the page can show that the serial
// single-stream number is a floor, not the transport's capacity.

/// Connections multiplexed on the one loop thread for the throughput run. Fixed
/// (comptime) so the futures array is sized at compile time, like `iroh-loop`.
const loop_conns: usize = 16;

/// Per-connection setup the loop host runs on accept: publish this connection's
/// greeter on its own vat (the same static `Greeter` the serial bench uses).
fn publishGreeterLoop(ctx: ?*anyopaque, served: *driver.Served) anyerror!void {
    _ = ctx;
    _ = try served.publish("greeter", Greeter, .{});
}

/// Run the completion loop until every connection has closed.
fn serveIrohLoop(loop: *IrohLoop, out_err: *?anyerror) void {
    loop.run(.{ .after_closed = loop_conns }) catch |err| {
        out_err.* = err;
    };
}

/// Cross-thread start barrier: each client signals `ready` once it is connected
/// and warm, then parks on `go` so every connection's timed calls overlap. The
/// throughput window thus excludes the per-endpoint bind and connect, which would
/// otherwise dominate it.
const LoopSync = struct {
    ready: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    go: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// One loop-throughput client: bind its own iroh endpoint, dial the server by id
/// alone, fetch the greeter, warm the path, then — once every client is at the
/// barrier — make `calls` sequential calls. Its own connection is serial; the
/// concurrency across the `loop_conns` clients is what the one loop multiplexes.
fn loopClient(
    io: std.Io,
    allocator: std.mem.Allocator,
    server_id: []const u8,
    warmup: usize,
    calls: usize,
    sync: *LoopSync,
) anyerror!void {
    var client = try iroh.Resident.init(io, null, .{ .reachability = .local_discovery });
    defer client.deinit();
    const entries = [_]net.netlayer.Netlayer{client.netlayer()};

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const locator: model.PeerLocator = .{
        .transport = iroh.transport_name,
        .designator = server_id,
        .hints = model.Hints.emptyFalse(),
    };
    var cv = try driver.connectVia(allocator, &entries, &peer, locator, .ephemeral, read_buf, write_buf, 0);
    defer cv.deinit();

    const greeter = try cv.fetch("greeter");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var w: usize = 0;
    while (w < warmup) : (w += 1) {
        _ = arena_state.reset(.retain_capacity);
        if (!try callOnce(&cv, greeter, arena)) return error.WrongReply;
    }

    _ = sync.ready.fetchAdd(1, .acq_rel);
    while (!sync.go.load(.acquire)) std.Thread.yield() catch {};

    var i: usize = 0;
    while (i < calls) : (i += 1) {
        _ = arena_state.reset(.retain_capacity);
        if (!try callOnce(&cv, greeter, arena)) return error.WrongReply;
    }
}

/// Aggregate round-trip throughput when one loop thread serves `loop_conns`
/// connections at once. Prints one `loop` line; the serial bench's per-stream
/// reciprocal is the contrast the page draws.
fn benchIrohLoop(io: std.Io, allocator: std.mem.Allocator, warmup: usize, calls: usize) !void {
    const server_seed: [32]u8 = @splat(0x62);
    var server = try iroh.Resident.init(io, &server_seed, .{ .reachability = .local_discovery });
    defer server.deinit();

    var id_buf: [iroh.node_id_len]u8 = undefined;
    const server_id = server.nodeId(&id_buf);

    var host = driver.core.Host.init(allocator, server_seed, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = actors.Vat.max_batch_local_turns,
    });
    defer host.deinit();
    var loop: IrohLoop = undefined;
    var bridge = IrohBridge.init(allocator, &host, io, &loop, .{ .publish = publishGreeterLoop });
    defer bridge.deinit();

    const read_buffer_bytes: u32 = @intCast(@min(frame_cap, 16 * 1024));
    const backend = try iroh.Backend.initBound(allocator, &server, 256, 256, read_buffer_bytes);
    loop = try IrohLoop.initWithBackend(allocator, backend, IrohBridge.makePeer, @ptrCast(&bridge), .{
        .frame_cap = frame_cap,
        .max_conns = 64,
        .listen = 0,
        .make_conn_ctx = IrohBridge.makeConnCtx,
        .serve = IrohBridge.serve,
        .free_conn_ctx = IrohBridge.freeConnCtx,
        .on_close = IrohBridge.onClose,
    });
    defer loop.deinit();
    try bridge.attach(iroh.transport_name, server_id, &.{});

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(serveIrohLoop, .{ &loop, &loop_err });

    var sync = LoopSync{};
    var futures: [loop_conns]@TypeOf(io.concurrent(loopClient, .{ io, allocator, server_id, warmup, calls, &sync }) catch unreachable) = undefined;
    var started: usize = 0;
    while (started < loop_conns) : (started += 1) {
        futures[started] = try io.concurrent(loopClient, .{ io, allocator, server_id, warmup, calls, &sync });
    }

    // Every client connected and warm: open the gate and time the overlapped calls.
    while (sync.ready.load(.acquire) < loop_conns) std.Thread.yield() catch {};
    const t0 = nowNs(io);
    sync.go.store(true, .release);

    var first_err: ?anyerror = null;
    for (futures[0..started]) |*f| {
        if (f.await(io)) |_| {} else |err| {
            if (first_err == null) first_err = err;
        }
    }
    const t1 = nowNs(io);

    loop_future.await(io);
    if (loop_err) |err| return err;
    if (first_err) |err| return err;

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
    // readiness loop, the contrast to the serial single-stream number above.
    const loop_calls: usize = if (smoke) 50 else 300;
    const loop_warmup: usize = if (smoke) 5 else 20;
    try benchIrohLoop(io, allocator, loop_warmup, loop_calls);
}
