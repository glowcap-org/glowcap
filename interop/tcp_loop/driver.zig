//! Live TCP scale: many concurrent connections served from one thread by a
//! `driver.Server` (ADR-0193).
//!
//! One Server's runtime runs the full multi-session CapTP host: adoption, the
//! keyed handshake, per-event serving, and the host's action queue, all on
//! its one serving thread over the runtime's stream stack. Many clients dial
//! it at once. Each client is its own `driver.Session`. Each fetches the
//! published greeter and calls it several times, every reply asserted. The
//! run then repeats a second wave of fresh connections, so the run covers
//! connection churn as well as concurrency.
//!
//! While the first wave's connections are all open and quiescent, the driver
//! reads the server side's live heap through a counting allocator and prints
//! the marginal bytes one served connection costs, the way
//! `bench-peer-scaling` reports the sans-io peer's footprint. The figure is
//! measured and printed, never gated: wall-clock and RSS-shaped numbers on
//! shared CI hardware flake, and the gating rationale lives in ADR-0073.
//!
//! Not part of the hermetic `zig build check`: it binds real loopback sockets
//! at scale, so it runs as the sibling step `zig build tcp-loop`.

const std = @import("std");
const glowcap = @import("glowcap");
const harness = @import("interop_harness");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

const frame_cap: usize = 4096;
const greeting = "hello over the tcp loop";

/// Concurrent connections in each wave, all served by the one thread.
const conns_per_wave: usize = 128;
/// Two waves, so connection churn is covered: 256 lifecycles total.
const waves: usize = 2;
/// Calls each connection makes, several turns per connection so the proof is
/// sustained multiplexing, not a single round trip.
const calls_per_conn: usize = 4;

/// Generous against a loopback server so an ordinary slow machine still
/// passes, and finite so a broken one reports instead of hanging.
const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 30_000 },
    .settle = .{ .ms = 30_000 },
};

/// Tracks live heap bytes with a signed atomic delta per allocator op, so the
/// main thread can read a quiescent steady state the serving thread built.
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

/// The published actor: answers `greet` with a static greeting.
const Greeter = harness.StaticReplyBehavior("greet", greeting);

/// Gates the footprint measurement: wave-one clients report in when their
/// calls are done and hold their connection open until the main thread has
/// read the warmed heap.
const Barrier = struct {
    ready: std.atomic.Value(usize) = .init(0),
    measured: std.atomic.Value(bool) = .init(false),
};

/// One client lifecycle: dial, keyed handshake, fetch, `calls_per_conn`
/// asserted calls, then (in the measured wave) hold the connection open until
/// the footprint read. `barrier == null` skips the hold: the churn wave.
fn clientOnce(io: std.Io, allocator: std.mem.Allocator, address: std.Io.net.IpAddress, barrier: ?*Barrier) anyerror!void {
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, glowcap.net.tcp.locatorFromAddress(&designator_buf, address), .ephemeral, opts);
    defer session.deinit();

    const greeter = try session.fetch("greeter");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (0..calls_per_conn) |_| {
        _ = arena.reset(.retain_capacity);
        switch (try session.call(greeter, "greet", &.{}, arena.allocator())) {
            .fulfilled => |value| if (value != .string or !std.mem.eql(u8, value.string, greeting)) return error.WrongReply,
            .broken => return error.BrokenReply,
        }
    }

    if (barrier) |b| {
        _ = b.ready.fetchAdd(1, .acq_rel);
        // Fail loud past a wall-clock deadline: an undeadlined spin here is
        // the silent-hang class the test/support/wait harness closes.
        try harness.untilFlag(io, 15_000, &b.measured);
    }
}

/// Accept every connection and serve them all from this one thread until the
/// main thread has joined both waves.
fn serve(server: *driver.Server, allocator: std.mem.Allocator, done: *std.atomic.Value(bool)) anyerror!void {
    var sessions: std.ArrayListUnmanaged(*driver.Session) = .empty;
    defer {
        for (sessions.items) |session| session.deinit();
        sessions.deinit(allocator);
    }
    while (!done.load(.acquire)) {
        if (try server.waitAcceptable(0)) {
            const session = try server.accept();
            sessions.append(allocator, session) catch |err| {
                session.deinit();
                return err;
            };
            // An accepted session dispatches nothing until its owner attends.
            try session.attend();
            continue;
        }
        _ = try server.runtime.stepAny(10);
    }
    if (sessions.items.len != conns_per_wave * waves) return error.MissingAccepts;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Everything the server side allocates, from its runtime and stream stack
    // to adopted sessions and the Host Vat, runs through the counting
    // allocator, so live bytes at a warmed steady state divided by the
    // connection count is the marginal cost of one served connection.
    var counting = LiveBytes{ .backing = allocator };
    const server_alloc = counting.allocator();

    var server = try driver.listen(server_alloc, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, opts);
    defer server.deinit();
    try server.publish("greeter", Greeter, .{});
    var designator_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&designator_buf));

    var done = std.atomic.Value(bool).init(false);
    var serving = try io.concurrent(serve, .{ server, server_alloc, &done });
    var serving_joined = false;
    defer if (!serving_joined) {
        done.store(true, .release);
        // best-effort: this unwind already returns the run's own error, and the serving thread's failure would only repeat it.
        serving.await(io) catch {};
    };

    const baseline: i64 = counting.live.load(.acquire);

    const Future = @TypeOf(io.concurrent(clientOnce, .{ io, allocator, address, @as(?*Barrier, null) }) catch unreachable);
    var futures: [conns_per_wave]Future = undefined;

    // Wave one, measured: every client completes its calls and then holds its
    // connection open, so the footprint read sees all of them warmed at once.
    var barrier = Barrier{};
    for (&futures) |*f| f.* = try io.concurrent(clientOnce, .{ io, allocator, address, @as(?*Barrier, &barrier) });
    const ready_deadline = harness.deadlineAfter(io, 60_000);
    while (barrier.ready.load(.acquire) < conns_per_wave) {
        if (harness.expired(io, ready_deadline)) {
            // Release the holders so the joins below report the real failure.
            barrier.measured.store(true, .release);
            break;
        }
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(5), .real);
    }
    // A beat for the serving thread to go quiescent (parked on readiness)
    // before the heap is read.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real);
    const warmed: i64 = counting.live.load(.acquire);
    barrier.measured.store(true, .release);

    var first_err: ?anyerror = null;
    for (&futures) |*f| f.await(io) catch |err| {
        if (first_err == null) first_err = err;
    };

    // Wave two, churn: the same count again over fresh connections, no hold.
    for (&futures) |*f| f.* = try io.concurrent(clientOnce, .{ io, allocator, address, @as(?*Barrier, null) });
    for (&futures) |*f| f.await(io) catch |err| {
        if (first_err == null) first_err = err;
    };

    done.store(true, .release);
    serving_joined = true;
    const served = serving.await(io);
    if (first_err) |err| return err;
    try served;

    const marginal = @divTrunc(warmed - baseline, @as(i64, @intCast(conns_per_wave)));
    const at_500k_mib = @divTrunc(marginal * 500_000, 1024 * 1024);
    std.debug.print(
        "tcp-loop: OK, {d} concurrent TCP connections per wave x {d} waves ({d} lifecycles), {d} calls each, one Server thread\n",
        .{ conns_per_wave, waves, conns_per_wave * waves, calls_per_conn },
    );
    std.debug.print(
        "tcp-loop: measured server-side footprint {d} bytes/connection warmed ({d} connections; ~{d} MiB at 500k), printed not gated\n",
        .{ marginal, conns_per_wave, at_500k_mib },
    );
}
