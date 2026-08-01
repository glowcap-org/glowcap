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

/// Park-duration reclaims seen during the run. A healthy wave must produce
/// none: every connection here drains, so a reclaim would mean the throttle
/// parked something it never released.
var park_kills: std.atomic.Value(usize) = .init(0);
var drain_kills: std.atomic.Value(usize) = .init(0);
var closes_seen: std.atomic.Value(usize) = .init(0);

/// Watch the close reason on the way past, then hand off to the bridge, which
/// discards it. `CloseReason` exists for exactly this — an embedder telling
/// backpressure reclaim apart from ordinary peer loss — and nothing else in
/// the tree reads it.
fn watchClose(
    ctx: ?*anyopaque,
    slot: usize,
    conn_ctx: ?*anyopaque,
    opened: bool,
    reason: net.completion.CloseReason,
) void {
    // Counted first, and unconditionally. The two reclaim counters below are
    // only ever read as "still zero", so a `watchClose` that stopped being
    // called — or a `reason` arm that stopped matching — would satisfy the
    // gate forever. This is the witness that the observation happened at all.
    _ = closes_seen.fetchAdd(1, .monotonic);
    switch (reason) {
        .park_kill => _ = park_kills.fetchAdd(1, .monotonic),
        // Counted apart from the park kill. Both are reclaims, but the failure
        // message names one of them, and reporting a terminal-flush timeout as
        // a slow-reader kill sends the reader to the wrong knob.
        .drain_kill => _ = drain_kills.fetchAdd(1, .monotonic),
        .ordinary => {},
    }
    TcpBridge.onClose(ctx, slot, conn_ctx, opened, reason);
}

/// Parks where this connection's own partner stopped draining, counted apart
/// from fan-in victims. An operator needs that distinction to tell a slow
/// peer from a peer being throttled for someone else's slowness, and this
/// gate needs it because the two are indistinguishable from the outside.
var sink_parks: std.atomic.Value(usize) = .init(0);

fn reportPark(ctx: ?*anyopaque, slot: usize, conn_ctx: ?*anyopaque, reason: net.completion.ParkReason) void {
    _ = ctx;
    _ = slot;
    _ = conn_ctx;
    _ = park_hits.fetchAdd(1, .monotonic);
    if (reason == .sink) _ = sink_parks.fetchAdd(1, .monotonic);
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

/// How long a client waits on the server before calling it a failure.
///
/// The budgets default to unbounded, and unbounded here would turn every
/// property this driver proves into a hang: a park that never resumes, a reply
/// that never arrives, and a handshake that never completes all read as "still
/// running" rather than as the regression they are. Generous against a loopback
/// server so an ordinary slow machine still passes, and finite so a broken one
/// reports.
const client_budget: driver.Budget = .{ .ms = 30_000 };

/// One client lifecycle: dial, keyed handshake, fetch, `calls_per_conn`
/// asserted calls, then (in the measured wave) hold the connection open until
/// the footprint read. `barrier == null` skips the hold — the churn wave.
fn clientOnce(io: std.Io, allocator: std.mem.Allocator, port: u16, barrier: ?*Barrier) anyerror!void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var cv = try driver.connectTcp(allocator, io, &scaffold.peer, address, scaffold.read_buf, scaffold.write_buf, client_budget);
    defer cv.deinit();
    cv.settle = client_budget;

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

/// How many replies to ask for before checking whether the server has parked.
///
/// A client that stops reading does not create backpressure until its receive
/// buffer and the server's send buffer are both full: until then the server's
/// writes complete into the kernel and its queue drains as fast as it fills, so
/// `pendingOut` never approaches the 4 KiB mark. A few hundred replies vanish
/// into buffer space. So the requests go out in batches and the park is checked
/// between them, rather than as one fixed count chosen to beat whatever the
/// kernel happens to buffer.
const backpressure_batch: usize = 512;

/// How many batches to try before calling it a failure. The product is the old
/// fixed count, so a machine that needs every one of them still passes; a
/// machine that parks early stops early instead of pushing the rest uphill into
/// a pipe the server has already stopped reading.
const backpressure_batches: usize = 12;

/// Force the parked-sink path against a real kernel.
///
/// Every other client here reads each reply, so the server's outbound never
/// crosses the high-water mark and the ADR-0042 park never fires. This one
/// asks for far more than it reads: it queues eventual sends in batches and
/// never reads a reply. The server answers, its outbound queue passes the mark,
/// and it parks this connection's read rather than piling more replies onto a
/// socket nobody is draining.
///
/// Batched, and stopping at the first park, because how many replies it takes
/// is a property of the kernel's buffer sizing rather than of anything this
/// driver controls. A single fixed count large enough for a small buffer also
/// pushes several hundred kilobytes of *requests* uphill into a server whose
/// read seat has already parked, which can wedge the flush and be reclaimed by
/// the park deadline — a failure that reads as a bug and is a machine.
///
/// The park is observed, not assumed: the loop runs in this process, so
/// `on_park` increments a counter this function waits on. Then it reads,
/// which is the other half of the contract — the queue drains, the read
/// re-arms, every reply lands, and the connection still works afterwards.
fn backpressureOnce(io: std.Io, allocator: std.mem.Allocator, port: u16) anyerror!void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var cv = try driver.connectTcp(allocator, io, &scaffold.peer, address, scaffold.read_buf, scaffold.write_buf, client_budget);
    defer cv.deinit();
    cv.settle = client_budget;

    const greeter = try cv.fetch("greeter");

    // Heap, not stack: this many vows is more than a thread stack should hold.
    const vows = try allocator.alloc(actors.Vow, backpressure_batch * backpressure_batches);
    defer allocator.free(vows);

    // Ask in batches, and stop as soon as the server has parked. Counted at
    // the decision, not sampled from outside: the park is transient — the
    // kernel keeps accepting, the queue drains, the read re-arms — so polling
    // the loop's state from this thread misses it. An earlier version of this
    // proof did exactly that and reported no park while eight were firing.
    // A baseline, not a reset. The earlier version zeroed the counter after
    // awaiting the previous wave's clients, but a client returning does not
    // mean the loop thread has finished tearing its connection down, and the
    // reset was ordered against nothing — so a straggler park from that wave
    // could satisfy this wait, and the proof would pass without this
    // connection ever having been parked.
    const parks_before = sink_parks.load(.monotonic);
    const deadline = harness.deadlineAfter(io, 10_000);
    var sent: usize = 0;
    while (sent < vows.len and sink_parks.load(.monotonic) == parks_before) {
        for (vows[sent .. sent + backpressure_batch]) |*v| {
            v.* = try cv.send(greeter, .{ .verb = "greet", .args = &.{} });
        }
        sent += backpressure_batch;
        // Write-only: `flush` drains outbound without touching the read side.
        try cv.flush();
        if (harness.expired(io, deadline)) return error.NoSinkParkUnderBackpressure;
    }

    // The server is now answering into a queue we are not draining. Give the
    // last batch's replies time to cross the mark if they have not already.
    while (sink_parks.load(.monotonic) == parks_before) {
        if (harness.expired(io, deadline)) return error.NoSinkParkUnderBackpressure;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .real) catch {};
    }

    // Read again. Every queued reply must arrive, which proves the park held
    // the replies rather than dropping them.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    for (vows[0..sent]) |*v| {
        const settled = try cv.settleVow(v.*, arena_state.allocator());
        const ok = switch (settled) {
            .fulfilled => |arg| arg == .string and std.mem.eql(u8, arg.string, greeting),
            .broken, .give => false,
        };
        if (!ok) return error.WrongReply;
    }

    // And the connection is still usable: the read seat re-armed on drain.
    try harness.expectStringReply(&cv, allocator, greeter, "greet", &.{}, greeting);
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
        // ADR-0082's resource posture, enabled over real sockets. The unit
        // tests drive each part with a scripted backend; this is the only
        // place the set runs against a kernel, at scale, under a bridge and a
        // host.
        //
        // What this proves and what it does not: the throttle's accounting
        // and its per-arm check run on every armed read of 256 connection
        // lifecycles without stalling the loop or reclaiming anything, and
        // the close reason reaches an embedder. These clients read every
        // reply, so none of them crosses the mark; the park itself is forced
        // by `backpressureOnce` below, which stops reading mid-conversation
        // and waits for the loop to park it.
        //
        // `fan_in_throttle` needs a park deadline beside it: a sink the
        // partner never drains would otherwise park every other read with
        // nothing to wake the poll. The bound is generous, because tripping
        // it here would mean a genuinely wedged connection, not a slow one.
        .on_park = reportPark,
        .fan_in_throttle = true,
        .park_kill_ms = 30_000,
    }));
    // After `hookOptions`, which installs the bridge's own `on_close`.
    loop.on_close = watchClose;
    defer loop.deinit();
    const port = loop.port.?;
    var designator_buf: [net.tcp.designator_buf_len]u8 = undefined;
    const designator_addr = try net.tcp.parseHostPort("127.0.0.1", port);
    const designator = net.tcp.locator(&designator_buf, designator_addr).designator;
    try bridge.attach(net.tcp.transport_name, designator, &.{});

    // The two waves plus the one backpressure connection below.
    const total_lifecycles = conns_per_wave * waves + 1;
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

    // `park_hits` is only reported, so a reset here is harmless. `sink_parks`
    // is *waited on*, and this reset was ordered against nothing — a client
    // returning does not mean the loop thread has finished with its
    // connection. `backpressureOnce` takes its own baseline instead.
    park_hits.store(0, .monotonic);
    backpressureOnce(io, allocator, port) catch |err| {
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
        "tcp-loop: fan-in throttle and a 30s park deadline on; a non-reading client forced {d} sink park(s) of {d} total, no reclaims\n",
        .{ sink_parks.load(.monotonic), park_hits.load(.monotonic) },
    );
    // A park-kill here means a connection sat parked for thirty seconds while
    // its peers finished, which is a wedge rather than backpressure. A
    // drain-kill means a terminal flush ran out of budget, which is a different
    // fault and a different knob, so it is reported as itself.
    // The reclaim gate below tests for zero, so it needs proof the counter was
    // ever reachable. Every one of these lifecycles ends in a close, so a run
    // that observed none observed nothing.
    if (closes_seen.load(.monotonic) < total_lifecycles) {
        std.debug.print(
            "tcp-loop: FAIL close hook saw {d} of {d} connection endings; the reclaim gate below reads zero from a counter nothing reached\n",
            .{ closes_seen.load(.monotonic), total_lifecycles },
        );
        return error.CloseHookMissedConnections;
    }
    if (park_kills.load(.monotonic) != 0 or drain_kills.load(.monotonic) != 0) {
        std.debug.print(
            "tcp-loop: FAIL {d} connection(s) reclaimed by the park deadline, {d} by the drain deadline\n",
            .{ park_kills.load(.monotonic), drain_kills.load(.monotonic) },
        );
        return error.ReclaimDuringHealthyRun;
    }
}
