//! `driver.Bridge` end to end: one completion-loop thread serving a full
//! multi-session CapTP host. The three-party handoff theorem runs G, E, and R
//! each as `Host` + `net.TcpLoop` + `Bridge`. The deposit leg is the one
//! frame only the bridge's cross-session arm can put on the wire, and the
//! recipient's redeem dial settles on one loop thread via `Loop.dialLocator`. A
//! third test pins the budget contract over the bridge: a flooding client's
//! session closes with the typed `resource_exhausted` abort while a
//! sibling session keeps answering.
//!
//! Choreography note: G's fetch of the exporter's object rides a `ready`
//! poke E sends *after* publishing, not the session-open edge. Same-socket
//! ordering makes that deterministic, where a fetch fired at session open
//! can race the partner's own post-handshake publish. The desk actors are
//! published at adoption (`Bridge`'s publish callback) for the same
//! reason: they exist before any inbound frame is served.

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");
const test_host = @import("../support/core_host.zig");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const TcpBridge = driver.Bridge(net.TcpLoop);
const wait = @import("../support/wait.zig");

const frame_cap = 4096;

/// Session options for a real loopback dial. The budgets are finite on purpose:
/// an unbounded CapTP wait against a partner that goes quiet does not fail the
/// suite, it wedges the test binary, which reads as a hang rather than a bug.
const dial_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

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
    /// The exporter listener's port (diagnostic / failure poke).
    exporter_port: std.atomic.Value(u16) = .init(0),
    /// Set by G's fetch-settle listener: the introducer holds the token and
    /// the exporter location is recorded, so R may now ask to be introduced.
    fetched: std.atomic.Value(bool) = .init(false),
    /// Counts the bridge's `on_open` firings — once per session, from the loop
    /// thread.
    opened: std.atomic.Value(usize) = .init(0),
    /// CapTP done: every party’s `runUntil` closes and drains, then `deinit`.
    done: std.atomic.Value(bool) = .init(false),
};

/// The bridge's session-open edge: one firing per session, top-level
/// verbs legal (unused here — the fetch rides the `ready` poke, see the
/// module header).
fn onOpen(ctx: ?*anyopaque, bridge: *TcpBridge, conn: *TcpBridge.Slot) anyerror!void {
    _ = bridge;
    _ = conn;
    const shared: *Shared = @ptrCast(@alignCast(ctx.?));
    _ = shared.opened.fetchAdd(1, .acq_rel);
}

/// G's loop-thread state: the shared introducer payload every per-session
/// desk points at, and the fetch choreography flags. Touched only on the loop
/// thread (the `fetched` event is the one cross-thread edge, set last).
const GifterState = struct {
    host: *Host,
    shared: *Shared,
    widget: ?model.Reference = null,
    exporter_session: ?*HostSession = null,
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

/// The per-session desk G publishes at adoption: E pokes `ready` once its
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

fn publishDesk(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
    const state: *GifterState = @ptrCast(@alignCast(ctx.?));
    _ = try served.publish(vat, "desk", Desk, .{ .state = state });
}

/// The loop's serve hook: the bridge's serve, then the top-level follow-up a
/// desk poke asked for — the fetch of the exporter's widget, sent on the
/// very session the poke arrived on. Top-level host verbs are legal here
/// (the bridge's serve released the latch), and the drain afterwards flushes
/// what they queued.
fn gifterServe(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
    try TcpBridge.serve(conn_ctx, peer, event);
    const shell: *TcpBridge.Slot = @ptrCast(@alignCast(conn_ctx.?));
    const state: *GifterState = @ptrCast(@alignCast(shell.bridge.publish_ctx.?));
    if (state.want_fetch and !state.fetch_sent) {
        state.fetch_sent = true;
        state.exporter_session = shell.session;
        const vow = try state.host.fetch(shell.session, "target");
        try state.host.vowOn(vow, .{ .ctx = state, .func = GifterState.onFetched });
        try shell.bridge.drainActions();
    }
}

pub fn runLoopUntilCapturing(loop: *net.TcpLoop, done: *const std.atomic.Value(bool), out_err: *?anyerror, loop_done: *std.atomic.Value(bool)) void {
    loop.runUntil(done, 0) catch |err| {
        out_err.* = err;
        loop_done.store(true, .release);
        return;
    };
    loop.closeAndDrain() catch |err| {
        out_err.* = err;
    };
    loop_done.store(true, .release);
}

pub fn runLoopCapturing(loop: *net.TcpLoop, until_closed: usize, out_err: *?anyerror, loop_done: *std.atomic.Value(bool)) void {
    loop.run(.{ .after_closed = until_closed }) catch |err| {
        out_err.* = err;
    };
    // `run` returns on the close count alone, so other slots can still hold an
    // armed recv, most often a connection the drain poke opened. `deinit`
    // refuses to free a slot with an op in flight, because a submitted send
    // borrows that slot's buffer until the backend retires it, so the drain
    // belongs here on the loop-owner thread rather than at the assertion.
    loop.closeAndDrain() catch |err| {
        out_err.* = err;
    };
    loop_done.store(true, .release);
}

/// Unblock a loop thread still waiting for its close count after a failed
/// test: each poke is one accepted-then-dropped connection, one more close.
pub fn drainLoopThread(io: std.Io, port: u16, loop_done: *const std.atomic.Value(bool)) !void {
    const deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!loop_done.load(.acquire)) {
        if (wait.expired(io, deadline)) return error.WaitTimedOut;
        pokeListener(io, port);
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
    }
}

/// The exporter E: Bridge+TcpLoop — listens (so its hello names a dialable
/// address), dials G, publishes the widget, pokes ready, and accepts R's
/// redeem on the same Host identity.
const ExporterState = struct {
    host: *Host,
    bridge: *TcpBridge,
    gifter_session: ?*HostSession = null,
};

fn publishExporterTarget(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
    _ = ctx;
    _ = try served.publish(vat, "target", Widget, .{});
}

fn exporterOnOpen(ctx: ?*anyopaque, bridge: *TcpBridge, conn: *TcpBridge.Slot) anyerror!void {
    const state: *ExporterState = @ptrCast(@alignCast(ctx.?));
    if (conn.leg != .app_dial or conn.session.role != .dialed) return;
    if (state.gifter_session != null) return;
    state.gifter_session = conn.session;
    _ = try conn.session.served.publish(&conn.session.host.vat, "target", Widget, .{});
    const desk = try state.host.fetch(conn.session, "desk");
    try state.host.vowOn(desk, .{ .ctx = state, .func = onGifterDesk });
    try bridge.drainActions();
}

fn onGifterDesk(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *ExporterState = @ptrCast(@alignCast(ctx.?));
    const session = state.gifter_session orelse return;
    switch (resolution) {
        .fulfilled => |value| {
            if (value != .reference) return;
            const vow = state.host.send(session, value.reference, .{ .verb = "ready", .args = &.{} }) catch |err| {
                std.debug.print("exporter ready send: {s}\n", .{@errorName(err)});
                return;
            };
            _ = vow;
            state.bridge.drainActions() catch {};
        },
        .broken => |reason| std.debug.print("exporter desk fetch broke: {s}\n", .{reason}),
        .give => {},
    }
}

fn exporterTask(allocator: std.mem.Allocator, shared: *Shared, gifter_designator: []const u8) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host = test_host.init(allocator, @as([32]u8, @splat(0x0e)), blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer host.deinit();
    var state = ExporterState{ .host = &host, .bridge = undefined };
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &host, io, &loop, .{
        .publish = publishExporterTarget,
        .on_open = exporterOnOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();
    state.bridge = &bridge;

    loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&bridge), TcpBridge.hookOptions(.{
        .max_conns = 8,
        .listen = 0,
    }));
    defer loop.deinit();
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const bound_addr = try tcp.parseHostPort("127.0.0.1", loop.port().?);
    const bound = tcp.locatorFromAddress(&designator_buf, bound_addr).designator;
    shared.exporter_port.store(loop.port().?, .release);
    try bridge.attach(model.transport.Known.tcp.metadata(), bound, &.{});

    try bridge.dialOutbound(.{
        .transport = tcp.transport_name,
        .designator = gifter_designator,
        .hints = model.Hints.emptyFalse(),
    });

    var loop_err: ?anyerror = null;
    var loop_done = std.atomic.Value(bool).init(false);
    var loop_future = try io.concurrent(runLoopUntilCapturing, .{ &loop, &shared.done, &loop_err, &loop_done });
    defer {
        shared.done.store(true, .release);
        pokeListener(io, loop.port().?);
        loop_future.await(io);
        if (loop_err) |err| std.debug.print("exporter loop: {s}\n", .{@errorName(err)});
    }

    try wait.untilFlag(io, wait.default_deadline_ms, &shared.done);
}

/// Connect-and-drop against a listener, so a teardown that finds a task
/// still parked in a blocking `accept` unblocks it (the accept's handshake
/// then fails, and the task sees `done` set).
pub fn pokeListener(io: std.Io, port: u16) void {
    if (port == 0) return;
    const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return;
    var stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

/// R for the deposit theorem: Bridge party that dials G and redeems.
const FirstRecipientState = struct {
    host: *Host,
    poked: *std.atomic.Value(bool),
    gifter_session: ?*HostSession = null,
    redeemed_ok: bool = false,

    fn onDesk(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *FirstRecipientState = @ptrCast(@alignCast(ctx.?));
        const session = self.gifter_session orelse return;
        switch (resolution) {
            .fulfilled => |value| {
                if (value != .reference) return;
                const vow = self.host.send(session, value.reference, .{ .verb = "introduce", .args = &.{} }) catch |err| {
                    std.debug.print("introduce send: {s}\n", .{@errorName(err)});
                    return;
                };
                self.host.vowOn(vow, .{ .ctx = self, .func = onIntroduced }) catch |err| {
                    std.debug.print("introduce vowOn: {s}\n", .{@errorName(err)});
                    return;
                };
            },
            .broken => |reason| std.debug.print("desk fetch broke: {s}\n", .{reason}),
            .give => {},
        }
    }

    fn onIntroduced(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *FirstRecipientState = @ptrCast(@alignCast(ctx.?));
        const session = self.gifter_session orelse return;
        switch (resolution) {
            .fulfilled => |value| {
                const widget = switch (value) {
                    .reference => |r| r,
                    else => return,
                };
                if (widget == .routed) self.redeemed_ok = true;
                const vow = self.host.send(session, widget, .{ .verb = "poke", .args = &.{} }) catch |err| {
                    std.debug.print("poke send: {s}\n", .{@errorName(err)});
                    return;
                };
                self.host.vowOn(vow, .{ .ctx = self, .func = onPoked }) catch |err| {
                    std.debug.print("poke vowOn: {s}\n", .{@errorName(err)});
                    return;
                };
            },
            .broken => |reason| std.debug.print("introduce broke: {s}\n", .{reason}),
            .give => {},
        }
    }

    fn onPoked(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *FirstRecipientState = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| {
                if (value == .string and std.mem.eql(u8, value.string, "poked directly at the exporter"))
                    self.poked.store(true, .release);
            },
            .broken => |reason| std.debug.print("poke broke: {s}\n", .{reason}),
            .give => {},
        }
    }
};

fn firstRecipientOnOpen(ctx: ?*anyopaque, bridge: *TcpBridge, conn: *TcpBridge.Slot) anyerror!void {
    const state: *FirstRecipientState = @ptrCast(@alignCast(ctx.?));
    if (conn.leg != .app_dial or conn.session.role != .dialed) return;
    if (state.gifter_session != null) return;
    state.gifter_session = conn.session;
    const vow = try state.host.fetch(conn.session, "desk");
    try state.host.vowOn(vow, .{ .ctx = state, .func = FirstRecipientState.onDesk });
    try bridge.drainActions();
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
    // Page allocator: Host/Loop/Bridge are touched from the loop thread and
    // this test thread; `std.testing.allocator` is not thread-safe. Teardown
    // still calls `Loop.deinit` after `runUntil` → `closeAndDrain`.
    const g_alloc = std.heap.page_allocator;
    var gifter_host = test_host.init(g_alloc, @as([32]u8, @splat(0x06)), .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = 64,
    });
    defer gifter_host.deinit();
    var state = GifterState{ .host = &gifter_host, .shared = &shared };
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(g_alloc, &gifter_host, io, &loop, .{
        .publish = publishDesk,
        .publish_ctx = &state,
        .on_open = onOpen,
        .on_open_ctx = &shared,
    });
    defer bridge.deinit();

    var gifter_options = TcpBridge.hookOptions(net.completion.Options{
        .max_conns = 8,
        .listen = 0,
    });
    gifter_options.serve = gifterServe;
    loop = try net.TcpLoop.init(g_alloc, TcpBridge.makePeer, @ptrCast(&bridge), gifter_options);
    defer loop.deinit();
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const gifter_designator_addr = try tcp.parseHostPort("127.0.0.1", loop.port().?);
    const gifter_designator = tcp.locatorFromAddress(&designator_buf, gifter_designator_addr).designator;
    try bridge.attach(model.transport.Known.tcp.metadata(), gifter_designator, &.{});

    var loop_err: ?anyerror = null;
    var loop_done = std.atomic.Value(bool).init(false);
    var loop_future = try io.concurrent(runLoopUntilCapturing, .{ &loop, &shared.done, &loop_err, &loop_done });
    defer {
        shared.done.store(true, .release);
        pokeListener(io, loop.port().?);
        loop_future.await(io);
        if (loop_err) |err| std.debug.print("gifter loop: {s}\n", .{@errorName(err)});
    }

    var exporter_future = try io.concurrent(exporterTask, .{ std.heap.page_allocator, &shared, @as([]const u8, gifter_designator) });
    defer exporter_future.await(io) catch |err| std.debug.print("exporter task: {s}\n", .{@errorName(err)});

    // R waits for G to hold the token, then runs the ordinary two calls.
    try wait.untilFlag(io, wait.default_deadline_ms, &shared.fetched);
    try std.testing.expect(state.widget != null);

    // R: Bridge+TcpLoop — dials G, introduces, redeems via Loop.dialLocator, pokes.
    var poked = std.atomic.Value(bool).init(false);
    const r_alloc = std.heap.page_allocator;
    var recipient_host = test_host.init(r_alloc, @as([32]u8, @splat(0x0c)), .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = 64,
    });
    defer recipient_host.deinit();
    var r_state = FirstRecipientState{ .host = &recipient_host, .poked = &poked };
    var r_loop: net.TcpLoop = undefined;
    var r_bridge = TcpBridge.init(r_alloc, &recipient_host, io, &r_loop, .{
        .on_open = firstRecipientOnOpen,
        .on_open_ctx = &r_state,
    });
    defer r_bridge.deinit();
    r_loop = try net.TcpLoop.init(r_alloc, TcpBridge.makePeer, @ptrCast(&r_bridge), TcpBridge.hookOptions(.{
        .max_conns = 8,
        .listen = 0,
    }));
    defer r_loop.deinit();
    var r_designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const r_designator_addr = try tcp.parseHostPort("127.0.0.1", r_loop.port().?);
    const r_designator = tcp.locatorFromAddress(&r_designator_buf, r_designator_addr).designator;
    try r_bridge.attach(model.transport.Known.tcp.metadata(), r_designator, &.{});
    try r_bridge.dialOutbound(.{
        .transport = tcp.transport_name,
        .designator = gifter_designator,
        .hints = model.Hints.emptyFalse(),
    });

    var r_loop_err: ?anyerror = null;
    var r_loop_done = std.atomic.Value(bool).init(false);
    var r_loop_future = try io.concurrent(runLoopUntilCapturing, .{ &r_loop, &shared.done, &r_loop_err, &r_loop_done });
    defer {
        shared.done.store(true, .release);
        pokeListener(io, r_loop.port().?);
        r_loop_future.await(io);
        if (r_loop_err) |err| std.debug.print("recipient loop: {s}\n", .{@errorName(err)});
    }

    try wait.untilFlag(io, wait.default_deadline_ms, &poked);
    try std.testing.expect(r_state.redeemed_ok);

    // Both of G's connections (E's and R's) opened through the bridge's
    // session-open edge, exactly once each.
    try std.testing.expectEqual(@as(usize, 2), shared.opened.load(.acquire));

    // Cross-thread `done`: wake each listening poll so `runUntil` observes the
    // flag, then `closeAndDrain` retires armed recvs before `deinit`.
    shared.done.store(true, .release);
    pokeListener(io, loop.port().?);
    pokeListener(io, r_loop.port().?);
    pokeListener(io, shared.exporter_port.load(.acquire));
}

// ── Budget runaway over the bridge ───────────────────────────────────────────
