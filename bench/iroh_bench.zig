//! Round-trip latency and throughput of a full OCapN call, measured for the
//! encrypted iroh transport, for the same machine's cleartext TCP transport
//! as a baseline, and for the in-process `inproc` exchange, which pays no
//! socket and no kernel: the protocol and the runtime alone.
//!
//! Each sample is one synchronous `greet` round-trip: an `op:deliver` out and a
//! resolve back over a live connection between two runtimes in this process:
//! a `driver.Server` thread that publishes a greeter and serves, and a
//! `driver.Session` client that fetches once and then calls in a loop. No pipelining. One call is in
//! flight at a time, so the per-call number is the wire's serial latency and the
//! throughput is its reciprocal.
//!
//! The iroh path carries the bytes over real keyed QUIC endpoints. Only the
//! address is resolved in-process (the `local_discovery` posture), so the data
//! path is the encrypted channel, not a stub. The gap between the two transports
//! is what the QUIC stack, the encryption, and the Rust sidecar's FFI boundary
//! cost over loopback. It is not a real-network measurement: loopback removes the
//! propagation delay and packet loss a relayed or hole-punched path would add, so
//! read this as the floor of the transport's own overhead, not field latency.
//!
//! Both runtimes offer the codec `--codec=` names, `syrup` by default or
//! `capnp`, so one `greet` round trip measures under either encoding with the
//! same validation and the same parse-once path. The `capnp` row is the one
//! to set beside a Cap'n Proto RPC library carrying the same message.
//!
//! Like the other benches, it reports numbers and gates none of them. Under
//! `zig build check` it would run in Debug. It is not on `check` because it links
//! the Rust sidecar. Read the printed `mode=` field and run with
//! `-Doptimize=ReleaseFast` for absolute figures: `zig build bench-iroh`.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const iroh = @import("iroh");

const affinity = @import("support/affinity.zig");
const profile = @import("support/profile.zig");

const model = glowcap.ocapn.model;
const crypto = glowcap.foundation.crypto;
const driver = glowcap.driver;
const net = glowcap.net;

const frame_cap: usize = 4096;
const greeting = "hello over the wire";

/// Finite waits for every dial and settle: a partner that wedges fails the
/// bench loudly instead of parking it, which is the cli rule's posture for
/// anything that dials. Sixty seconds dwarfs any healthy call here.
/// `main` sets the busy-poll window from `--busy-poll-us=` before any row
/// starts, and every runtime a row builds reads it. A window needs a core
/// per runtime: `--pin=A,B` keeps the client on A and the server on B.
var opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 60_000 },
    .settle = .{ .ms = 60_000 },
};

/// The two call shapes, the same two `bench/capnp/echo.capnp` declares for
/// the comparison harnesses. `greet` is the smallest message that is still a
/// call. `report` is one application batch: a source name, eight tags,
/// sixty-four integer readings, and a timestamp, answered with a count and a
/// sum the server computes by reading every reading.
const Call = enum { greet, report };

const report_source = "sensor-17/humidity";
const report_tags = [_]driver.Value{
    .{ .string = "site:lab-3" },   .{ .string = "rack:b2" },
    .{ .string = "unit:percent" }, .{ .string = "model:sht45" },
    .{ .string = "fw:2.4.1" },     .{ .string = "owner:facilities" },
    .{ .string = "tier:gold" },    .{ .string = "region:us-west" },
};
var report_samples: []const i64 = &.{};
var report_args = [_]driver.Value{
    .{ .string = report_source },
    .{ .list = &report_tags },
    .{ .integers = &.{} },
    .{ .integer = 1_760_400_000 },
};
var report_sum: i64 = 0;
const max_readings = 16_384;

/// The published actor: `greet` answers a static greeting so the timed loop
/// measures the transport and the protocol turn alone, and `report` sums the
/// readings it was sent, the same work the comparison servers do.
const Greeter = struct {
    pub fn handle(_: *Greeter, ht: *driver.HostTurn, selector: ?[]const u8, args: driver.Args) !driver.Value {
        defer ht.releaseArguments(args);
        const verb = selector orelse return error.NoSuchMethod;
        if (std.mem.eql(u8, verb, "greet")) return .{ .string = greeting };
        if (std.mem.eql(u8, verb, "report")) return reportReply(ht, args);
        return error.NoSuchMethod;
    }
};

/// `report(source, tags, samples, at)` answers `{count, sum}` over `samples`.
/// The samples are read where the frame holds them (a word run on the
/// Cap'n Proto codec), and the reply lives in the turn arena, which outlives
/// the borrowed reply.
fn reportReply(ht: *driver.HostTurn, args: driver.Args) !driver.Value {
    if ((try args.len()) != 4) return error.BadArguments;
    const samples = try args.integers(2);
    const count = samples.len;
    var sum: i64 = 0;
    for (samples) |sample| {
        sum = std.math.add(i64, sum, sample) catch return error.BadArguments;
    }
    const entries = try ht.turn.arena.alloc(driver.Value.StructEntry, 2);
    entries[0] = .{ .key = "count", .value = .{ .integer = @intCast(count) } };
    entries[1] = .{ .key = "sum", .value = .{ .integer = sum } };
    return .{ .@"struct" = entries };
}

/// The cores `--pin=` named, or null to let the scheduler place the threads.
var pin: ?affinity.Pair = null;

/// `--row=<row>` runs one row of a transport alone, so a profiler sees only
/// that row's syscalls and samples. The default runs every row.
const Row = enum { all, greet, report, @"session-open" };
var row: Row = .all;

fn rowWanted(call: Call) bool {
    return row == .all or std.mem.eql(u8, @tagName(row), @tagName(call));
}

/// Server half: accept every partner, attend it, and serve until `done`.
fn serve(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    if (pin) |cores| try affinity.pinThread(cores[1]);
    var sessions: [loop_conns]*driver.Session = undefined;
    var accepted: usize = 0;
    defer for (sessions[0..accepted]) |session| session.deinit();
    while (!done.load(.acquire)) {
        // The accept wait is a host-wide step: every attended session is
        // served inside it, so one wait a turn covers admission and traffic.
        if (accepted < sessions.len) {
            if (try server.waitAcceptable(10)) {
                sessions[accepted] = try server.accept();
                accepted += 1;
                // An accepted session dispatches nothing until its owner attends.
                try sessions[accepted - 1].attend();
            }
            continue;
        }
        _ = try server.runtime.stepAny(10);
    }
}

/// Server half of the session-open rows: accept every partner for as long as
/// `done` is clear, attend it, and keep the newest `loop_conns` sessions. The
/// partner that is retired closed long ago, because the client opens one
/// session at a time.
fn serveChurn(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    if (pin) |cores| try affinity.pinThread(cores[1]);
    var sessions: [loop_conns]?*driver.Session = @splat(null);
    var accepted: usize = 0;
    defer for (sessions) |held| if (held) |session| session.deinit();
    while (!done.load(.acquire)) {
        if (try server.waitAcceptable(10)) {
            const slot = &sessions[accepted % sessions.len];
            if (slot.*) |old| old.deinit();
            slot.* = null;
            slot.* = try server.accept();
            accepted += 1;
            try slot.*.?.attend();
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
/// `samples.len` sequential `call`s into `samples` (nanoseconds each).
fn clientMeasure(
    io: std.Io,
    allocator: std.mem.Allocator,
    transports: driver.Transports,
    locator: model.PeerLocator,
    name: []const u8,
    call: Call,
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
        if (!expected(call, readReply(call, try callOnce(session, greeter, call, arena)))) return error.WrongReply;
    }

    // The reply's fields are read inside the window and compared after it,
    // the same shape as the Cap'n Proto harnesses under `bench/capnp/`. The
    // profile phase is the timed loop, named like the report row.
    var phase_buf: [32]u8 = undefined;
    const phase = try std.fmt.bufPrintSentinel(&phase_buf, "{s}-{s}", .{ name, @tagName(call) }, 0);
    profile.begin();
    for (samples) |*sample| {
        _ = arena_state.reset(.retain_capacity);
        const t0 = nowNs(io);
        const read = readReply(call, try callOnce(session, greeter, call, arena));
        const t1 = nowNs(io);
        if (!expected(call, read)) return error.WrongReply;
        sample.* = @intCast(t1 - t0);
    }
    profile.end(phase);
}

/// What the client reads from a reply: the greeting, or the report's count
/// and sum. A missing or mistyped field reads as its zero value, which
/// `expected` refuses.
const Read = struct { text: []const u8 = "", count: i64 = 0, sum: i64 = 0 };

fn readReply(call: Call, reply: driver.Value) Read {
    switch (call) {
        .greet => return .{ .text = if (reply == .string) reply.string else "" },
        .report => {
            var read: Read = .{};
            if (reply != .@"struct") return read;
            for (reply.@"struct") |entry| {
                if (entry.value != .integer) continue;
                if (std.mem.eql(u8, entry.key, "count")) read.count = entry.value.integer;
                if (std.mem.eql(u8, entry.key, "sum")) read.sum = entry.value.integer;
            }
            return read;
        },
    }
}

fn expected(call: Call, read: Read) bool {
    return switch (call) {
        .greet => std.mem.eql(u8, read.text, greeting),
        .report => read.count == report_samples.len and read.sum == report_sum,
    };
}

/// Session-open client: `samples.len` times, connect to the listening server,
/// fetch the greeter once, and close the session. Each sample spans connect
/// through teardown, in nanoseconds.
fn openMeasure(
    io: std.Io,
    allocator: std.mem.Allocator,
    transports: driver.Transports,
    locator: model.PeerLocator,
    name: []const u8,
    warmup: usize,
    samples: []u64,
) !void {
    var phase_buf: [32]u8 = undefined;
    const phase = try std.fmt.bufPrintSentinel(&phase_buf, "{s}-session-open", .{name}, 0);
    for (0..warmup + samples.len) |i| {
        if (i == warmup) profile.begin();
        const t0 = nowNs(io);
        const session = try driver.connect(allocator, io, transports, locator, .ephemeral, opts);
        _ = session.fetch("greeter") catch |err| {
            session.deinit();
            return err;
        };
        session.deinit();
        const t1 = nowNs(io);
        if (i >= warmup) samples[i - warmup] = @intCast(t1 - t0);
    }
    profile.end(phase);
}

/// One call of the named shape, returning the fulfilled value. A broken
/// reply is a void value, which `expected` refuses.
fn callOnce(session: *driver.Session, greeter: driver.Capability, call: Call, arena: std.mem.Allocator) !driver.Value {
    const outcome = switch (call) {
        .greet => try session.call(greeter, "greet", &.{.{ .string = "world" }}, arena),
        .report => try session.call(greeter, "report", &report_args, arena),
    };
    return switch (outcome) {
        .fulfilled => |value| value,
        .broken => .void,
    };
}

fn lessThan(_: void, a: u64, b: u64) bool {
    return a < b;
}

/// Sort `samples` in place and print one structured `roundtrip` line: the median
/// and 99th-percentile latency, the mean, and the reciprocal-of-mean throughput.
fn report(transport: []const u8, call: []const u8, warmup: usize, samples: []u64) void {
    std.mem.sort(u64, samples, {}, lessThan);
    const n = samples.len;
    var sum: u128 = 0;
    for (samples) |s| sum += s;
    const mean_ns: f64 = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(n));
    const p50 = samples[n / 2];
    const p99 = samples[(n * 99) / 100];
    const rps: f64 = if (mean_ns > 0) 1_000_000_000.0 / mean_ns else 0;
    std.debug.print(
        "roundtrip transport={s} codec={s} call={s} calls={d} warmup={d} p50_ns={d} p99_ns={d} mean_ns={d:.0} rps={d:.0} mode={s} busy_poll_us={d} pin={s} readings={d} frame_cap={d}\n",
        .{ transport, @tagName(opts.codec), call, n, warmup, p50, p99, mean_ns, rps, @tagName(builtin.mode), opts.busy_poll_ns / std.time.ns_per_us, if (pin != null) "yes" else "no", if (std.mem.eql(u8, call, "report")) report_samples.len else 0, opts.frame_cap },
    );
}

/// The call rows `--row=` admits for one transport, `greet` then `report`,
/// each served and timed on its own.
fn callRows(io: std.Io, allocator: std.mem.Allocator, server: *driver.Server, transports: driver.Transports, locator: model.PeerLocator, name: []const u8, warmup: usize, samples: []u64) !void {
    inline for (.{ Call.greet, Call.report }) |call| {
        if (rowWanted(call)) {
            try withServer(io, server, clientMeasure, .{ io, allocator, transports, locator, name, call, warmup, samples });
            report(name, @tagName(call), warmup, samples);
        }
    }
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

/// Like `withServer`, with the churn loop that retires old sessions.
fn withChurnServer(io: std.Io, server: *driver.Server, measure: anytype, measure_args: anytype) !void {
    var done = std.atomic.Value(bool).init(false);
    var serving = try io.concurrent(serveChurn, .{ server, &done });
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
    try callRows(io, allocator, server, transports, locator, "tcp", warmup, samples);
    if (row == .all or row == .@"session-open") {
        try withChurnServer(io, server, openMeasure, .{ io, allocator, transports, locator, "tcp", warmup, samples });
        report("tcp", "session-open", warmup, samples);
    }
}

/// Run the sealed row: `noise-tcp` over loopback, dialed by the listener's key
/// designator and bound address. The channel is the Noise XK handshake and
/// sealed records, so the gap to `tcp` is what the proof of the durable key
/// and the record sealing cost.
fn benchNoiseTcp(io: std.Io, allocator: std.mem.Allocator, warmup: usize, samples: []u64) !void {
    const transports: driver.Transports = .{ .symbols = &.{.noise_tcp} };
    const server_secret = try driver.drawSessionSecret(io);
    var server = try driver.listen(allocator, io, transports, model.transport.noise_tcp, .{ .designator = "127.0.0.1:0" }, .{ .keyed = server_secret }, opts);
    defer server.deinit();
    try server.publish("greeter", Greeter, .{});
    const advertised = try server.advertisedLocator();
    const hint = net.netlayer.directAddrHint(advertised.hints) orelse return error.MissingBoundAddress;
    var entries: [1]model.HintEntry = undefined;
    const locator: model.PeerLocator = .{
        .transport = model.transport.noise_tcp,
        .designator = advertised.designator,
        .hints = model.Hints.forDirectAddresses(hint, &entries),
    };
    try callRows(io, allocator, server, transports, locator, "noise-tcp", warmup, samples);
    if (row == .all or row == .@"session-open") {
        try withChurnServer(io, server, openMeasure, .{ io, allocator, transports, locator, "noise-tcp", warmup, samples });
        report("noise-tcp", "session-open", warmup, samples);
    }
}

/// Run the in-process row: both runtimes share one `inproc` exchange, so a
/// call crosses two threads through memory. The kernel sees one wake per
/// direction and no socket. The gap between this row and `tcp` is the
/// socket's cost.
fn benchInproc(io: std.Io, allocator: std.mem.Allocator, warmup: usize, samples: []u64) !void {
    var exchange = net.inproc_completion.Exchange.init(allocator);
    defer exchange.deinit();
    const transports: driver.Transports = .{ .symbols = &.{.inproc}, .inproc = &exchange };
    var server = try driver.listen(allocator, io, transports, model.transport.inproc, .{ .designator = "greeter" }, .ephemeral, opts);
    defer server.deinit();
    try server.publish("greeter", Greeter, .{});
    const locator = try model.clonePeerLocator(allocator, try server.advertisedLocator());
    defer model.freePeerLocator(allocator, locator);
    try callRows(io, allocator, server, transports, locator, "inproc", warmup, samples);
}

/// One iroh endpoint and the resident its runtime polls.
const Endpoint = struct {
    endpoint: iroh.Resident,
    adapter: iroh.MultiplexedAdapter,
    providers: [1]driver.HostRuntime.ProviderRegistration = undefined,

    fn init(self: *Endpoint, io: std.Io, allocator: std.mem.Allocator, seed: ?*const [32]u8) !void {
        self.endpoint = try iroh.Resident.init(io, seed, .{ .reachability = .local_discovery });
        // best-effort: this unwind returns the adapter's init error, and a failed endpoint close would only mask it.
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
    try callRows(io, allocator, server, client_endpoint.transports(), server_endpoint.locator(&id_buf), "iroh", warmup, samples);
}

// ── iroh at its design point: many connections on one serving thread ─────────
// The serial bench above is one connection, one call in flight, the worst case
// for the async sidecar bridge, where every read pays a cross-thread wakeup
// with nothing to amortize it against. One Server thread multiplexing many
// connections through the endpoint's single readiness descriptor is the path
// iroh is built to be served on (ADR-0019). This measures the
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
/// barrier, make `calls` sequential calls. Its own connection is serial. The
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
        if (!expected(.greet, readReply(.greet, try callOnce(session, greeter, .greet, arena)))) return error.WrongReply;
    }

    _ = sync.ready.fetchAdd(1, .acq_rel);
    while (!sync.go.load(.acquire)) try std.Thread.yield();

    for (0..calls) |_| {
        _ = arena_state.reset(.retain_capacity);
        if (!expected(.greet, readReply(.greet, try callOnce(session, greeter, .greet, arena)))) return error.WrongReply;
    }
}

/// Aggregate round-trip throughput when one Server thread serves `loop_conns`
/// connections at once. Prints one `loop` line. The serial bench's per-stream
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
    while (first_err == null and sync.ready.load(.acquire) < started) try std.Thread.yield();
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
    var readings: usize = 64;
    var transport: Transport = .all;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) {
            smoke = true;
        } else if (std.mem.startsWith(u8, arg, "--transport=")) {
            transport = std.meta.stringToEnum(Transport, arg["--transport=".len..]) orelse return error.UnknownTransport;
        } else if (std.mem.startsWith(u8, arg, "--row=")) {
            row = std.meta.stringToEnum(Row, arg["--row=".len..]) orelse return error.UnknownRow;
        } else if (std.mem.startsWith(u8, arg, "--frame-cap=")) {
            opts.frame_cap = try std.fmt.parseInt(usize, arg["--frame-cap=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "--readings=")) {
            readings = try std.fmt.parseInt(usize, arg["--readings=".len..], 10);
            if (readings > max_readings) return error.TooManyReadings;
        } else if (std.mem.startsWith(u8, arg, "--codec=")) {
            opts.codec = std.meta.stringToEnum(model.CodecId, arg["--codec=".len..]) orelse return error.UnknownCodec;
        } else if (std.mem.startsWith(u8, arg, "--busy-poll-us=")) {
            const us = try std.fmt.parseInt(u64, arg["--busy-poll-us=".len..], 10);
            opts.busy_poll_ns = us * std.time.ns_per_us;
        } else if (std.mem.startsWith(u8, arg, "--pin=")) {
            pin = try affinity.parsePair(arg["--pin=".len..]);
        } else {
            return error.UnknownArgument;
        }
    }
    const values = try allocator.alloc(i64, readings);
    defer allocator.free(values);
    for (values, 0..) |*value, i| {
        value.* = @intCast(100_000 + (i * 7919) % 900_000);
        report_sum += value.*;
    }
    report_samples = values;
    report_args[2] = .{ .integers = values };
    if (pin) |cores| try affinity.pinThread(cores[0]);

    const calls: usize = if (smoke) 200 else 3000;
    const warmup: usize = if (smoke) 50 else 300;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const samples = try allocator.alloc(u64, calls);
    defer allocator.free(samples);

    if (transport == .all or transport == .tcp) try benchTcp(io, allocator, warmup, samples);
    if (transport == .all or transport == .@"noise-tcp") try benchNoiseTcp(io, allocator, warmup, samples);
    if (transport == .all or transport == .inproc) try benchInproc(io, allocator, warmup, samples);
    if (transport == .all or transport == .iroh) try benchIroh(io, allocator, warmup, samples);

    // iroh's design point: aggregate throughput with many connections on one
    // serving thread, the contrast to the serial single-stream number above.
    const loop_calls: usize = if (smoke) 50 else 300;
    const loop_warmup: usize = if (smoke) 5 else 20;
    if (transport == .all or transport == .@"iroh-loop") try benchIrohLoop(io, allocator, loop_warmup, loop_calls);
}

/// `--transport=<transport>` runs one transport alone. The default runs every
/// transport.
const Transport = enum { all, tcp, @"noise-tcp", inproc, iroh, @"iroh-loop" };
