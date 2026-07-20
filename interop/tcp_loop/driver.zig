//! Live TCP scale: many concurrent connections served from one loop
//! thread through `driver.Bridge` over `net.TcpLoop` (ADR-0076).
//!
//! One completion loop (`net.TcpLoop`) runs a full byte-fed multi-session
//! CapTP host (`driver.core.Host`) through `driver.Bridge`: adoption, the keyed
//! handshake, per-event serving, the budgeted drive, and the host's action
//! queue all on a single thread. Many clients dial it at once. Each client is an
//! ordinary blocking `driver.BlockingSession`. Each one fetches the published greeter, and
//! call it several times, every reply asserted. The run then repeats a second
//! wave over recycled slots, so the run covers connection churn as well as
//! concurrency.
//!
//! While the first wave's connections are all open and quiescent, the driver
//! reads the server side's live heap through a counting allocator and prints
//! the marginal bytes one bridged connection costs, the way
//! `bench-peer-scaling` reports the sans-io peer's footprint. The figure is
//! measured and printed, never gated: wall-clock and RSS-shaped numbers on
//! shared CI hardware flake, and the gating rationale lives in ADR-0073.
//!
//! Not part of the hermetic `zig build check`: it binds real loopback sockets
//! at scale, so it runs as the sibling step `zig build tcp-loop`.

const std = @import("std");
const pancake = @import("pancake");
const harness = @import("interop_harness");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;

const TcpBridge = driver.Bridge(net.TcpLoop);
const runLoop = harness.LoopRunner(net.TcpLoop).runAfterClosed;

const frame_cap: usize = 4096;
const greeting = "hello over the tcp loop";

/// Concurrent connections in each wave, all served by the one loop thread.
const conns_per_wave: usize = 128;
/// Two waves, so slot recycling and churn are covered: 256 lifecycles total.
const waves: usize = 2;

/// ADR-0082 park-metric dogfood: Loop.on_park increments this (make_ctx is the
/// bridge, so the counter lives here rather than on the hook ctx).
var park_hits: std.atomic.Value(usize) = .init(0);

fn reportPark(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque) void {
    _ = ctx;
    _ = slot;
    _ = conn_ctx;
    _ = park_hits.fetchAdd(1, .monotonic);
}
/// Calls each connection makes, several turns per connection so the proof is
/// sustained multiplexing, not a single round trip.
const calls_per_conn: usize = 4;

/// Tracks live heap bytes with a signed atomic delta per allocator op, so the
/// main thread can read a quiescent steady state the loop thread built.
const LiveBytes = struct {
    backing: std.mem.Allocator,
    live: std.atomic.Value(i64) = .init(0),

    fn allocator(self: *LiveBytes) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn add(self: *LiveBytes, delta: i64) void {
        _ = self.live.fetchAdd(delta, .acq_rel);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LiveBytes = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawAlloc(len, alignment, ret_addr);
        if (p != null) self.add(@intCast(len));
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LiveBytes = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.add(@as(i64, @intCast(new_len)) - @as(i64, @intCast(memory.len)));
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LiveBytes = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.add(@as(i64, @intCast(new_len)) - @as(i64, @intCast(memory.len)));
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LiveBytes = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ret_addr);
        self.add(-@as(i64, @intCast(memory.len)));
    }
};

/// The published actor: answers `greet` with a static greeting; a fresh
/// instance per connection through the bridge's publish callback.
const Greeter = harness.StaticReplyActor("greet", greeting);
const publishGreeter = harness.publisher("greeter", Greeter);

/// Gates the footprint measurement: wave-one clients report in when their
/// calls are done and hold their connection open until the main thread has
/// read the warmed heap.
const Barrier = struct {
    ready: std.atomic.Value(usize) = .init(0),
    measured: std.atomic.Value(bool) = .init(false),
};

/// One client lifecycle: dial, keyed handshake, fetch, `calls_per_conn`
/// asserted calls, then (in the measured wave) hold the connection open until
/// the footprint read. `barrier == null` skips the hold — the churn wave.
fn clientOnce(io: std.Io, allocator: std.mem.Allocator, port: u16, barrier: ?*Barrier) anyerror!void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var cv = try driver.connectTcp(allocator, io, &scaffold.peer, address, scaffold.read_buf, scaffold.write_buf);
    defer cv.deinit();

    const greeter = try cv.fetch("greeter");
    var i: usize = 0;
    while (i < calls_per_conn) : (i += 1) {
        try harness.expectStringReply(&cv, allocator, greeter, "greet", &.{}, greeting);
    }

    if (barrier) |b| {
        _ = b.ready.fetchAdd(1, .acq_rel);
        // Fail loud past a wall-clock deadline — an undeadlined spin here is
        // the same silent-hang class the test/support/wait harness closes for
        // the hermetic suite; the interop harness mirrors that contract.
        try harness.untilFlag(io, 15_000, &b.measured);
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Everything the server side allocates — host, bridge, loop, adopted
    // peers, vats — runs through the counting allocator, so live bytes at a
    // warmed steady state divided by the connection count is the marginal
    // cost of one bridged connection.
    var counting = LiveBytes{ .backing = allocator };
    const server_alloc = counting.allocator();

    var host = driver.core.Host.init(server_alloc, [_]u8{0x42} ** 32, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = actors.Vat.max_batch_local_turns,
    });
    defer host.deinit();
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(server_alloc, &host, io, &loop, .{ .publish = publishGreeter });
    defer bridge.deinit();

    loop = try net.TcpLoop.init(server_alloc, TcpBridge.makePeer, @ptrCast(&bridge), TcpBridge.hookOptions(.{
        .frame_cap = frame_cap,
        .max_conns = conns_per_wave * 2,
        .listen = 0,
        // ADR-0082: embedder park-metric dogfood (completion_loop_test pins the hook).
        .on_park = reportPark,
    }));
    defer loop.deinit();
    const port = loop.port.?;
    var designator_buf: [net.tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try net.tcp.parseHostPort("127.0.0.1", port);
    const designator = net.tcp.locator(&designator_buf, designator_addr).designator;
    try bridge.attach(net.tcp.transport_name, designator, &.{});

    const total_lifecycles = conns_per_wave * waves;
    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoop, .{ &loop, total_lifecycles, &loop_err });

    const baseline: i64 = counting.live.load(.acquire);

    const Future = @TypeOf(io.concurrent(clientOnce, .{ io, allocator, port, @as(?*Barrier, null) }) catch unreachable);
    var futures: [conns_per_wave]Future = undefined;

    // Wave one, measured: every client completes its calls and then holds its
    // connection open, so the footprint read sees all of them warmed at once.
    var barrier = Barrier{};
    for (&futures) |*f| f.* = try io.concurrent(clientOnce, .{ io, allocator, port, @as(?*Barrier, &barrier) });
    while (barrier.ready.load(.acquire) < conns_per_wave) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .real) catch {};
    }
    // A beat for the loop thread to go quiescent (parked in poll) before the
    // heap is read.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real) catch {};
    const warmed: i64 = counting.live.load(.acquire);
    barrier.measured.store(true, .release);

    var first_err: ?anyerror = null;
    for (&futures) |*f| f.await(io) catch |err| {
        if (first_err == null) first_err = err;
    };

    // Wave two, churn: the same count again over recycled slots, no hold.
    for (&futures) |*f| f.* = try io.concurrent(clientOnce, .{ io, allocator, port, @as(?*Barrier, null) });
    for (&futures) |*f| f.await(io) catch |err| {
        if (first_err == null) first_err = err;
    };

    loop_future.await(io);
    if (loop_err) |err| return err;
    if (first_err) |err| return err;

    const marginal = @divTrunc(warmed - baseline, @as(i64, @intCast(conns_per_wave)));
    const at_500k_mib = @divTrunc(marginal * 500_000, 1024 * 1024);
    std.debug.print(
        "tcp-loop: OK, {d} concurrent TCP connections per wave x {d} waves ({d} lifecycles), {d} calls each, one loop thread over the Host bridge\n",
        .{ conns_per_wave, waves, total_lifecycles, calls_per_conn },
    );
    std.debug.print(
        "tcp-loop: measured server-side footprint {d} bytes/connection warmed ({d} connections; ~{d} MiB at 500k), printed not gated\n",
        .{ marginal, conns_per_wave, at_500k_mib },
    );
    std.debug.print(
        "tcp-loop: on_park fired {d} time(s) (embedder metrics dogfood)\n",
        .{park_hits.load(.monotonic)},
    );
}
