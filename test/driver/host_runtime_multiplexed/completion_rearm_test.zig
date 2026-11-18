//! A completion listener whose re-arm the resident's allocator refused, served
//! by a real `driver.Server` over 127.0.0.1 on both faces of the runtime. The
//! refusal is the resident's own: a burst of arrivals served by its
//! `beforeWait` under a lasting allocator refusal fails the reservation of the
//! next re-arm, so the owed state is reached by the owner under test, never
//! forged. A partner that dials after that completes its session through the
//! paced retry, and its session is the one `accept` returns. Two assertions, kept apart: a raw client whose
//! `connect` returned while the listener was unarmed proves the kernel held
//! it in the backlog before the retry could run (the runtime acts only inside
//! the test's own pumps), and a partner that dials and handshakes proves the
//! end-to-end session (starting its thread is no barrier, so only the raw
//! client claims the order). Cadence (no early attempt, one attempt per due
//! epoch, a joining core deadline) is exact only on a stepped clock, in
//! `host_runtime_step/resident_retry_test.zig`. A stop through `Server.close`
//! or the runtime call the C loop's close makes reconciles the deadline.
//! Every wait here is bounded by the monotonic clock.

const std = @import("std");
const FailingOnce = @import("../../support/failing_once.zig").FailingOnce;

const glowcap = @import("glowcap");
const fixtures = @import("residents.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;
const HostRuntime = driver.HostRuntime;

const TcpResident = net.completion_resident.Resident(net.Backend, tcp.CompletionPolicy(net.Backend));

/// Partners the listener accepts before the runtime claims any of them: more
/// than the accepted list's capacity, so a re-arm must reserve growth.
const burst = 48;

const Face = enum { blocking, stepped };

const retry_ms = HostRuntime.testing.memory_retry_ms;
/// Monotonic bound on every wait in this file, past the handshake budget of a
/// partner the runtime stopped serving, so a lost re-arm fails the test.
const budget_ms: i64 = 8_000;
/// The spin window both faces use, so the runtime's post-spin clamp runs.
const spin_ns: u64 = 200 * std.time.ns_per_us;

fn awakeMs(io: std.Io) i64 {
    return std.Io.Clock.awake.now(io).toMilliseconds();
}

/// One partner that dials, completes its handshake, and holds its session
/// until released. `outcome` tells a completed dial from a refused one.
const Dial = struct {
    hold: std.atomic.Value(bool) = .init(false),
    future: std.Io.Future(void) = undefined,
    joined: bool = true,
    outcome: std.atomic.Value(Outcome) = .init(.pending),

    const Outcome = enum(u8) { pending, connected, refused };

    fn run(io: std.Io, address: std.Io.net.IpAddress, allocator: std.mem.Allocator, self: *Dial) void {
        var buf: [64]u8 = undefined;
        var session = driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&buf, address), .ephemeral, fixtures.opts) catch {
            self.outcome.store(.refused, .release);
            return;
        };
        defer session.deinit();
        self.outcome.store(.connected, .release);
        while (!self.hold.load(.acquire)) std.Io.sleep(io, .fromMilliseconds(5), .awake) catch return; // tolerant: only bounds this fixture's own wait
    }

    fn start(self: *Dial, io: std.Io, address: std.Io.net.IpAddress) !void {
        self.future = try io.concurrent(run, .{ io, address, std.testing.allocator, self });
        self.joined = false;
    }

    /// Release the partner and join it. A partner still handshaking is ended
    /// by closing the server first, so the join waits for nothing the
    /// runtime stopped serving.
    fn finish(self: *Dial, live: *Live) void {
        if (self.joined) return;
        self.joined = true;
        self.hold.store(true, .release);
        if (live.server.close()) |failure| std.debug.panic("server close failed: {s}", .{failure.chain.primaryName()});
        self.future.await(live.io());
    }
};

/// A listening server whose completion resident draws from `failing`.
const Live = struct {
    threaded: std.Io.Threaded,
    failing: FailingOnce,
    resident: TcpResident,
    observed: fixtures.ObservedOpen = .{},
    providers: [1]HostRuntime.ProviderRegistration,
    server: *driver.Server,
    address: std.Io.net.IpAddress,
    silent: [burst]std.Io.net.Stream = undefined,
    silent_count: usize = 0,

    fn create(face: Face) !*Live {
        const allocator = std.testing.allocator;
        const live = try allocator.create(Live);
        errdefer allocator.destroy(live);
        live.threaded = std.Io.Threaded.init(allocator, .{});
        errdefer live.threaded.deinit();
        live.failing = FailingOnce.init(allocator, std.math.maxInt(usize));
        live.observed = .{};
        live.silent_count = 0;
        live.resident = try TcpResident.init(live.failing.allocator(), try net.Backend.init(allocator, 64, 16, fixtures.frame_cap), .{});
        errdefer retire(&live.resident);
        live.providers = .{.{ .profile = model.transport.Known.tcp.metadata(), .resident = live.resident.resident() }};
        var options = switch (face) {
            .blocking => fixtures.opts,
            .stepped => live.observed.steppedOpts(),
        };
        options.busy_poll_ns = spin_ns;
        live.server = try driver.listen(allocator, live.threaded.io(), .{ .residents = &live.providers }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, options);
        errdefer live.server.deinit();
        try std.testing.expectEqual(spin_ns, live.server.runtime.opts.busy_poll_ns);
        var buf: [64]u8 = undefined;
        live.address = try tcp.parseDesignator(try live.server.localDesignator(&buf));
        return live;
    }

    fn destroy(self: *Live) void {
        for (self.silent[0..self.silent_count]) |*stream| stream.close(self.io());
        self.server.deinit();
        retire(&self.resident);
        self.threaded.deinit();
        std.testing.allocator.destroy(self);
    }

    fn io(self: *Live) std.Io {
        return self.threaded.io();
    }

    fn runtime(self: *Live) *HostRuntime {
        return self.server.runtime;
    }

    /// Serve the runtime for up to `ms`, returning early when a session is ready.
    fn pump(self: *Live, ms: i32) !void {
        _ = try self.server.waitAcceptable(ms);
    }

    fn owed(self: *Live) bool {
        return self.resident.rearm_owed_count != 0;
    }

    fn settled(self: *Live) bool {
        return self.resident.rearm_owed_count == 0 and self.resident.accept_seats == 1;
    }
};

/// A resident outlives its runtime and retires the operations it still owes.
fn retire(resident: *TcpResident) void {
    resident.closeAndDrain(2_000) catch |err| std.debug.panic("completion resident drain failed: {t}", .{err});
    resident.deinit();
}

/// A listener whose re-arm the resident's own allocator refused. The
/// allocator refuses everything while the resident itself serves a burst of
/// arrivals (its `beforeWait`, the call the runtime makes), before the
/// runtime has turned to claim any, so the refusal lands on a re-arm's
/// reservation and the claim-time admission that a later slice owns is not in
/// the window. Memory returns before the runtime serves the claims.
fn owedLive(face: Face) !*Live {
    const live = try Live.create(face);
    errdefer live.destroy();
    live.failing.lasting = true;
    live.failing.fail_index = live.failing.alloc_index;
    while (live.silent_count < burst) : (live.silent_count += 1) {
        live.silent[live.silent_count] = try std.Io.net.IpAddress.connect(&live.address, live.io(), .{ .mode = .stream });
    }
    const start = awakeMs(live.io());
    while (!live.owed()) {
        live.resident.resident().beforeWait(.park);
        std.Io.sleep(live.io(), .fromMilliseconds(5), .awake) catch return error.TestTimedOut;
        if (awakeMs(live.io()) - start > budget_ms) return error.TestTimedOut;
    }
    live.failing.lasting = false;
    live.failing.fail_index = std.math.maxInt(usize);
    try std.testing.expect(live.failing.induced);
    try std.testing.expectEqual(@as(usize, 1), live.resident.rearm_owed_count);
    try std.testing.expectEqual(@as(usize, 0), live.resident.accept_seats);
    try std.testing.expectEqual(@as(?anyerror, null), live.resident.failure);
    // The runtime now claims the arrivals and learns the debt at its flush tail.
    try live.pump(30);
    try std.testing.expect(live.server.listener_active);
    try std.testing.expect(live.owed());
    return live;
}

test "a raw client whose connect completed while the re-arm was owed is accepted by the paced retry alone" {
    for ([_]Face{ .blocking, .stepped }) |face| {
        const live = try owedLive(face);
        defer live.destroy();
        const runtime = live.runtime();
        try std.testing.expectEqual(@as(usize, 0), live.resident.accept_seats);
        try std.testing.expect(live.owed());

        // `connect` returns when the kernel has completed the connection into
        // the listen backlog. Nothing has pumped since the listener was owed,
        // so no accept was armed to take it and no retry could have run.
        var raw = try std.Io.net.IpAddress.connect(&live.address, live.io(), .{ .mode = .stream });
        defer raw.close(live.io());
        try std.testing.expect(live.owed());
        try std.testing.expectEqual(@as(usize, 0), live.resident.accept_seats);
        const rows = runtime.pending_opens.items.len;

        // Only the paced retry can arm the accept that takes the backlog,
        // this connection with the burst's remaining ones: the accepted
        // connections wait in handshake rows the runtime opened for them.
        const start = awakeMs(live.io());
        while (live.owed() or runtime.pending_opens.items.len < burst + 1) {
            try live.pump(20);
            if (awakeMs(live.io()) - start > budget_ms) return error.TestTimedOut;
        }
        try std.testing.expect(runtime.pending_opens.items.len > rows);
        try std.testing.expect(live.settled());
    }
}

test "a partner that dials after the re-arm is owed completes its session through the paced retry" {
    for ([_]Face{ .blocking, .stepped }) |face| {
        const live = try owedLive(face);
        defer live.destroy();
        const runtime = live.runtime();
        // The resident owes the re-arm, and no accept is armed for the partner.
        try std.testing.expectEqual(@as(usize, 0), live.resident.accept_seats);
        _ = runtime.resident_retry_due_ms orelse return error.ResidentDeadlineNotArmed;

        var backlog: Dial = .{};
        try backlog.start(live.io(), live.address);
        // Registered after `destroy`, so it joins the partner first.
        defer backlog.finish(live);

        // Serve until the partner's session is acceptable. Only the paced
        // retry can arm the accept the kernel's queued connection needs.
        const start = awakeMs(live.io());
        while (!try live.server.waitAcceptable(20)) {
            if (awakeMs(live.io()) - start > budget_ms) return error.TestTimedOut;
        }
        // `waitAcceptable` is true, so `accept` returns without waiting.
        const session = try live.server.accept();
        defer session.deinit();
        try std.testing.expect(live.settled());
        // The session is the partner's: its dial completed, and the silent
        // sockets never handshake, so no other client could have produced it.
        const dialed = awakeMs(live.io());
        while (backlog.outcome.load(.acquire) == .pending) {
            if (awakeMs(live.io()) - dialed > budget_ms) return error.TestTimedOut;
            std.Io.sleep(live.io(), .fromMilliseconds(5), .awake) catch return error.TestTimedOut;
        }
        try std.testing.expectEqual(Dial.Outcome.connected, backlog.outcome.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), live.server.accepted_count);
    }
}

test "Server.close of an owed listener releases the resident's debt and seat" {
    // `close` releases the shared runtime on its way out, so the runtime's
    // deadline cannot be read afterward; the resident's own counters can, and
    // the deadline's reconcile after the same `stopOwnedListener` call is
    // read in the test below.
    for ([_]Face{ .blocking, .stepped }) |face| {
        const live = try owedLive(face);
        defer live.destroy();
        _ = live.runtime().resident_retry_due_ms orelse return error.ResidentDeadlineNotArmed;
        try std.testing.expect(live.server.close() == null);
        try std.testing.expectEqual(@as(usize, 0), live.resident.rearm_owed_count);
        try std.testing.expectEqual(@as(usize, 0), live.resident.accept_seats);
    }
}

test "the runtime stop the C loop's listener close makes releases an owed listener's deadline" {
    // The C loop's close is `enterDriver; stopOwnedListener(tag); leaveDriver`
    // (src/c_abi/driver/loop/listeners.zig). Its allocator is the host's, not
    // the resident's, so the owed listener is reached here through the same
    // runtime call under the same turn guard.
    for ([_]Face{ .blocking, .stepped }) |face| {
        const live = try owedLive(face);
        defer live.destroy();
        const runtime = live.runtime();
        _ = runtime.resident_retry_due_ms orelse return error.ResidentDeadlineNotArmed;
        runtime.enterDriver();
        const outcome = runtime.stopOwnedListener(live.server.listener_tag);
        runtime.leaveDriver();
        try std.testing.expect(outcome.found);
        try std.testing.expect(!outcome.pending);
        try std.testing.expectEqual(@as(usize, 0), live.resident.rearm_owed_count);
        try std.testing.expectEqual(@as(?i64, null), runtime.resident_retry_due_ms);
        try std.testing.expect(live.server.close() == null);
    }
}
