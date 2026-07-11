//! `driver.LoopBridge` end to end: one completion-loop thread serving a full
//! multi-connection node. The theorem is the three-party handoff across two
//! connections of one loop — the gifter G runs `Host` + `net.Loop` +
//! `LoopBridge`, the exporter E and the recipient R are blocking hosts on
//! their own threads — because the deposit leg is the one frame only the
//! bridge's cross-connection arm can put on the wire: it is originated while
//! the loop serves R's connection and must leave on E's connection, which
//! the loop is not serving at that moment. The second test pins the budget
//! contract over the bridge: a flooding client's connection closes with the
//! typed `resource_exhausted` abort while a sibling connection keeps
//! answering.
//!
//! Choreography note: G's fetch of the exporter's object rides a `ready`
//! poke E sends *after* publishing, not the session-open edge — same-socket
//! ordering makes that deterministic, where a fetch fired at session open
//! can race the partner's own post-handshake publish. The desk actors are
//! published at adoption (`LoopBridge`'s publish callback) for the same
//! reason: they exist before any inbound frame is served.

const std = @import("std");
const builtin = @import("builtin");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const tcp = net.tcp;

const Host = driver.core.Host;
const HostConnection = driver.core.HostConnection;
const LoopBridge = driver.LoopBridge;
const wait = @import("../support/wait.zig");

const frame_cap = 4096;

// ── The theorem: three-party handoff across two connections of one loop ─────

/// The gifted object, published by the exporter on its gifter leg.
const Widget = struct {
    pub fn handle(self: *Widget, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "poke")) return error.NoSuchMethod;
        return .{ .string = "poked directly at the exporter" };
    }
};

const Shared = struct {
    /// The exporter listener's port, for the teardown poke that unblocks a
    /// still-parked `accept` when the test fails before R redeems.
    exporter_port: std.atomic.Value(u16) = .init(0),
    /// Set by G's fetch-settle listener: the introducer holds the token and
    /// the exporter location is recorded, so R may now ask to be introduced.
    fetched: std.atomic.Value(bool) = .init(false),
    /// Counts the bridge's `on_open` firings — once per connection whose
    /// session opened, from the loop thread.
    opened: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
};

/// The bridge's session-open edge: one firing per connection, top-level
/// verbs legal (unused here — the fetch rides the `ready` poke, see the
/// module header).
fn onOpen(ctx: ?*anyopaque, bridge: *LoopBridge, conn: *LoopBridge.Conn) anyerror!void {
    _ = bridge;
    _ = conn;
    const shared: *Shared = @ptrCast(@alignCast(ctx.?));
    _ = shared.opened.fetchAdd(1, .acq_rel);
}

/// G's loop-thread state: the shared introducer payload every per-connection
/// desk points at, and the fetch choreography flags. Touched only on the loop
/// thread (the `fetched` event is the one cross-thread edge, set last).
const GifterState = struct {
    host: *Host,
    shared: *Shared,
    widget: ?model.Reference = null,
    exporter_conn: ?*HostConnection = null,
    want_fetch: bool = false,
    fetch_sent: bool = false,

    /// The fetch vow's settle listener. Fires under the host's callback
    /// latch, so only enqueueing verbs are legal here — and the `fetched`
    /// signal is plain memory. No `setExporterLocation` override is needed:
    /// E listened before dialing G, so its signed hello already names its
    /// dialable address and the give embeds that session record.
    fn onFetched(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *GifterState = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| {
                if (value == .reference) self.widget = value.reference;
            },
            .broken => |reason| std.debug.print("gifter fetch broke: {s}\n", .{reason}),
            .give => {},
        }
        self.shared.fetched.store(true, .release);
    }
};

/// The per-connection desk G publishes at adoption: E pokes `ready` once its
/// widget is published, and R asks `introduce`, whose ordinary-looking reply
/// (the E-homed token) the host core turns into a signed give.
const Desk = struct {
    state: *GifterState,
    pub fn handle(self: *Desk, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "ready")) {
            self.state.want_fetch = true;
            return .{ .boolean = true };
        }
        if (std.mem.eql(u8, msg.verb, "introduce")) {
            const widget = self.state.widget orelse return error.NotReady;
            return .{ .reference = widget };
        }
        return error.NoSuchMethod;
    }
};

fn publishDesk(ctx: ?*anyopaque, served: *driver.Served) anyerror!void {
    const state: *GifterState = @ptrCast(@alignCast(ctx.?));
    _ = try served.publish("desk", Desk, .{ .state = state });
}

/// The loop's serve hook: the bridge's serve, then the top-level follow-up a
/// desk poke asked for — the fetch of the exporter's widget, sent on the
/// very connection the poke arrived on. Top-level host verbs are legal here
/// (the bridge's serve released the latch), and the drain afterwards flushes
/// what they queued.
fn gifterServe(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
    try LoopBridge.serve(conn_ctx, peer, event);
    const shell: *LoopBridge.Conn = @ptrCast(@alignCast(conn_ctx.?));
    const state: *GifterState = @ptrCast(@alignCast(shell.bridge.publish_ctx.?));
    if (state.want_fetch and !state.fetch_sent) {
        state.fetch_sent = true;
        state.exporter_conn = shell.conn;
        const vow = try state.host.fetch(shell.conn, "target");
        try state.host.vowOn(vow, .{ .ctx = state, .func = GifterState.onFetched });
        try shell.bridge.drainActions();
    }
}

fn runLoopCapturing(loop: *net.Loop, until_closed: usize, out_err: *?anyerror, loop_done: *std.atomic.Value(bool)) void {
    loop.run(.{ .after_closed = until_closed }) catch |err| {
        out_err.* = err;
    };
    loop_done.store(true, .release);
}

/// Unblock a loop thread still waiting for its close count after a failed
/// test: each poke is one accepted-then-dropped connection, one more close.
fn drainLoopThread(io: std.Io, port: u16, loop_done: *const std.atomic.Value(bool)) !void {
    const deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!loop_done.load(.acquire)) {
        if (wait.expired(io, deadline)) return error.WaitTimedOut;
        pokeListener(io, port);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
    }
}

/// The exporter E: a blocking host that listens on its own dialable URI,
/// dials G (so G's exporter connection is *accepted* — the bridge never
/// dials), publishes the widget on that connection, pokes G's desk, serves
/// until G's fetch settled, then accepts R's redeem leg and round-robins
/// both — the deposit (gifter leg) and the parked withdraw (redeem leg)
/// settle in whichever order they arrive (ADR-0056).
fn exporterTask(allocator: std.mem.Allocator, shared: *Shared, gifter_designator: []const u8) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };
    var host = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x0e} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();

    var server = try host.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    const bound = server.localDesignator(&addr_buf);
    // Listening before dialing G matters: the bound address becomes the
    // designator E's hello signs, which is the exporter location G's give
    // will name and R's redeem will dial.
    const colon = std.mem.lastIndexOfScalar(u8, bound, ':') orelse return error.BadDesignator;
    shared.exporter_port.store(try std.fmt.parseInt(u16, bound[colon + 1 ..], 10), .release);

    const to_g = try host.dial(.{
        .transport = tcp.transport_name,
        .designator = gifter_designator,
        .hints = model.Hints.emptyFalse(),
    });
    _ = try to_g.publish("target", Widget, .{});

    // Announce readiness on the same socket the publish precedes: G's fetch
    // arrives after this deliver, so it cannot beat the publish.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const desk = try to_g.fetch("desk");
    const ready = try to_g.call(desk, .{ .verb = "ready", .args = &.{} }, arena.allocator());
    if (ready != .fulfilled) return error.ReadyRefused;

    // Serve the gifter leg until G's fetch settled (the settle sets the
    // event from the loop thread; polling it between bounded pumps is the
    // wait, not a sleep). Fail loud past a wall-clock deadline.
    const fetch_deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!shared.fetched.load(.acquire)) {
        if (wait.expired(io, fetch_deadline)) return error.WaitTimedOut;
        _ = try to_g.stepReadable(5);
    }

    // R redeems by dialing this listener; the deposit arrives on the gifter
    // leg. Round-robin both until the test is done: the deposit and the
    // parked withdraw settle in whichever order they arrive (ADR-0056). A
    // failed accept during teardown is the poke that unblocks a test that
    // errored before R redeemed.
    const to_r = server.accept() catch |err| {
        if (shared.done.load(.acquire)) return;
        return err;
    };
    // The gift names the node-local swissnum, and the withdraw re-resolves
    // it against the withdrawing session's own bootstrap registry — so the
    // object is published on the redeem leg too, the exporter contract the
    // blocking three-party test carries.
    _ = try to_r.publish("target", Widget, .{});
    const done_deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!shared.done.load(.acquire)) {
        if (wait.expired(io, done_deadline)) return error.WaitTimedOut;
        _ = try to_g.stepReadable(5);
        _ = try to_r.stepReadable(5);
    }
}

/// Connect-and-drop against a listener, so a teardown that finds a task
/// still parked in a blocking `accept` unblocks it (the accept's handshake
/// then fails, and the task sees `done` set).
fn pokeListener(io: std.Io, port: u16) void {
    if (port == 0) return;
    const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return;
    var stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

test "three-party handoff across one loop: the deposit leaves on a connection only armOutbound can reach" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var shared = Shared{};

    // G: the byte-fed host under the loop, bridged. The budget is set — the
    // fan-out posture this tier ships with — and never hit here.
    var gifter_host = Host.init(allocator, [_]u8{0x06} ** 32, .{
        .frame_cap = frame_cap,
        .local_turn_budget = 64,
    });
    defer gifter_host.deinit();
    var state = GifterState{ .host = &gifter_host, .shared = &shared };
    var bridge = LoopBridge.init(allocator, &gifter_host, io, .{
        .publish = publishDesk,
        .publish_ctx = &state,
        .on_open = onOpen,
        .on_open_ctx = &shared,
    });
    defer bridge.deinit();

    var loop = try net.Loop.init(allocator, LoopBridge.makePeer, @ptrCast(&bridge), .{
        .frame_cap = frame_cap,
        .max_conns = 8,
        .listen = 0,
        .make_conn_ctx = LoopBridge.makeConnCtx,
        .serve = gifterServe,
        .free_conn_ctx = LoopBridge.freeConnCtx,
    });
    defer loop.deinit();
    var designator_buf: [64]u8 = undefined;
    const gifter_designator = try std.fmt.bufPrint(&designator_buf, "127.0.0.1:{d}", .{loop.port.?});
    try bridge.attach(&loop, tcp.transport_name, gifter_designator);

    var loop_err: ?anyerror = null;
    var loop_done = std.atomic.Value(bool).init(false);
    const loop_thread = try std.Thread.spawn(.{}, runLoopCapturing, .{ &loop, @as(usize, 2), &loop_err, &loop_done });

    var exporter_future = try io.concurrent(exporterTask, .{ allocator, &shared, @as([]const u8, gifter_designator) });
    defer {
        shared.done.store(true, .release);
        shared.fetched.store(true, .release);
        // A test that failed before R redeemed leaves E parked in `accept`;
        // the poke pops it so the await below cannot wedge.
        pokeListener(io, shared.exporter_port.load(.acquire));
        exporter_future.await(io) catch |err| std.debug.print("exporter task: {s}\n", .{@errorName(err)});
        drainLoopThread(io, loop.port.?, &loop_done) catch |err| std.debug.print("drain loop: {s}\n", .{@errorName(err)});
        loop_thread.join();
        if (loop_err) |err| std.debug.print("gifter loop: {s}\n", .{@errorName(err)});
    }

    // R waits for G to hold the token, then runs the ordinary two calls.
    try wait.untilFlag(io, wait.default_deadline_ms, &shared.fetched);
    try std.testing.expect(state.widget != null);

    var resident = tcp.Resident{ .io = io };
    var recipient = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x0c} ** 32, .{ .frame_cap = frame_cap });
    defer recipient.deinit();
    const to_g = try recipient.dial(.{
        .transport = tcp.transport_name,
        .designator = gifter_designator,
        .hints = model.Hints.emptyFalse(),
    });
    const desk = try to_g.fetch("desk");

    // The introduction: G's reply becomes a signed give — its deposit leaves
    // on E's connection through the bridge's armOutbound — and R's host
    // claims and auto-redeems it inside this wait.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const settled = try to_g.call(desk, .{ .verb = "introduce", .args = &.{} }, arena.allocator());
    const widget = switch (settled) {
        .fulfilled => |arg| switch (arg) {
            .reference => |reference| reference,
            else => return error.ExpectedReference,
        },
        .broken => |reason| {
            std.debug.print("introduce broke: {s}\n", .{reason});
            return error.IntroduceBroke;
        },
        .give => return error.GiveShouldHaveBeenRedeemed,
    };
    try std.testing.expect(widget == .far);
    try std.testing.expect(widget.far.import_position.int() >= engine.Node.REDEEMED_TOKEN_BASE);

    // The direct call: the token routes to the fresh exporter leg; the
    // gifter (and its loop) are out of the path.
    const reply = try to_g.call(widget, .{ .verb = "poke", .args = &.{} }, arena.allocator());
    switch (reply) {
        .fulfilled => |arg| try std.testing.expectEqualStrings("poked directly at the exporter", arg.string),
        .broken => |reason| {
            std.debug.print("poke broke: {s}\n", .{reason});
            return error.PokeBroke;
        },
        .give => return error.ExpectedValue,
    }

    // Both of G's connections (E's and R's) opened through the bridge's
    // session-open edge, exactly once each.
    try std.testing.expectEqual(@as(usize, 2), shared.opened.load(.acquire));
}

// ── Budget runaway over the bridge ───────────────────────────────────────────

const Counter = struct {
    hits: i64 = 0,
    pub fn handle(self: *Counter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "hit")) return error.NoSuchMethod;
        self.hits += 1;
        return .{ .integer = self.hits };
    }
};

const runaway_budget: usize = 4;

/// One `flood` queues more local turns than the budget admits.
const SelfFlood = struct {
    amp: actors.Ref,
    pub fn handle(self: *SelfFlood, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "flood")) return error.NoSuchMethod;
        var i: usize = 0;
        while (i < runaway_budget + 2) : (i += 1) {
            try turn.vat.tell(self.amp, .{ .verb = "hit", .args = &.{} });
        }
        return .{ .boolean = true };
    }
};

fn publishRunaway(ctx: ?*anyopaque, served: *driver.Served) anyerror!void {
    _ = ctx;
    const amp = try served.vat.spawn(Counter, .{});
    _ = try served.publish("flood", SelfFlood, .{ .amp = amp });
    _ = try served.publish("echo", Counter, .{});
}

test "budget runaway over the bridge: the flooding connection closes typed, a sibling keeps answering" {
    if (!(builtin.os.tag == .linux or builtin.os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host = Host.init(allocator, [_]u8{0x0b} ** 32, .{
        .frame_cap = frame_cap,
        .local_turn_budget = runaway_budget,
    });
    defer host.deinit();
    var bridge = LoopBridge.init(allocator, &host, io, .{ .publish = publishRunaway });
    defer bridge.deinit();

    var loop = try net.Loop.init(allocator, LoopBridge.makePeer, @ptrCast(&bridge), .{
        .frame_cap = frame_cap,
        .max_conns = 8,
        .listen = 0,
        .make_conn_ctx = LoopBridge.makeConnCtx,
        .serve = LoopBridge.serve,
        .free_conn_ctx = LoopBridge.freeConnCtx,
    });
    defer loop.deinit();
    var designator_buf: [64]u8 = undefined;
    const designator = try std.fmt.bufPrint(&designator_buf, "127.0.0.1:{d}", .{loop.port.?});
    try bridge.attach(&loop, tcp.transport_name, designator);

    var loop_err: ?anyerror = null;
    var loop_done = std.atomic.Value(bool).init(false);
    const loop_thread = try std.Thread.spawn(.{}, runLoopCapturing, .{ &loop, @as(usize, 2), &loop_err, &loop_done });
    defer {
        drainLoopThread(io, loop.port.?, &loop_done) catch |err| std.debug.print("drain loop: {s}\n", .{@errorName(err)});
        loop_thread.join();
        if (loop_err) |err| std.debug.print("bridge loop: {s}\n", .{@errorName(err)});
    }

    var resident = tcp.Resident{ .io = io };

    // The sibling connects first and stays healthy throughout.
    var sibling = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x1a} ** 32, .{ .frame_cap = frame_cap });
    defer sibling.deinit();
    const sibling_conn = try sibling.dial(.{
        .transport = tcp.transport_name,
        .designator = designator,
        .hints = model.Hints.emptyFalse(),
    });
    const echo = try sibling_conn.fetch("echo");

    // The flooder: its one call amplifies past the budget, so the host
    // condemns the connection and the bridge closes it — the answer breaks
    // with the typed abort's own words.
    {
        var flooder = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x1b} ** 32, .{ .frame_cap = frame_cap });
        defer flooder.deinit();
        const flood_conn = try flooder.dial(.{
            .transport = tcp.transport_name,
            .designator = designator,
            .hints = model.Hints.emptyFalse(),
        });
        const flood = try flood_conn.fetch("flood");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        // The flood's own answer may still fulfill: the reply resolves at
        // dispatch, and the budget breach is discovered in the pump right
        // after. What the budget guarantees is what follows — the connection
        // is condemned and closed with the typed abort. (The abort *kind* is
        // pinned hermetically in host_budget_test.zig.)
        _ = flood_conn.call(flood, .{ .verb = "flood", .args = &.{} }, arena.allocator()) catch {};
        var polls: usize = 0;
        while (flood_conn.abortReason() == null and polls < 500) : (polls += 1) {
            _ = flood_conn.stepReadable(10) catch break;
        }
        const reason = flood_conn.abortReason() orelse return error.NoBudgetAbort;
        try std.testing.expect(std.mem.indexOf(u8, reason, "local turn budget") != null);
    }

    // The sibling still gets ordinary answers after the flooder was closed.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const reply = try sibling_conn.call(echo, .{ .verb = "hit", .args = &.{} }, arena.allocator());
    switch (reply) {
        .fulfilled => |arg| try std.testing.expectEqual(@as(i64, 1), arg.integer),
        .broken => |reason| {
            std.debug.print("echo broke: {s}\n", .{reason});
            return error.EchoBroke;
        },
        .give => return error.ExpectedValue,
    }
}
