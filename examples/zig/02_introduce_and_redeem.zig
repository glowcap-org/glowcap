//! Chapter 02 — an introduction: the capability pattern pancake exists for.
//!
//! Chapter 01 held one session. This chapter holds several: a directory you
//! already trust *introduces* you to a service, and after the introduction you
//! talk to the service directly — the directory drops out of the path. On the
//! wire this is OCapN's three-party handoff. The Zig multi-session CapTP spine is
//! `driver.core.Host` + `driver.Bridge` + `net.TcpLoop` (ADR-0068, ADR-0076).
//!
//! Three Bridge parties in one process: widget (exporter), directory (gifter),
//! client (recipient). The choreography matches the hermetic deposit theorem in
//! `test/driver/bridge_test.zig`.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const tcp = net.tcp;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const TcpBridge = driver.Bridge(net.TcpLoop);

const frame_cap = 4096;
const deadline_ms: u64 = 15_000;

const Widget = struct {
    pub fn handle(self: *Widget, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "poke")) return error.NoSuchMethod;
        return .{ .string = "poked — directly, the directory is out of the path" };
    }
};

const Shared = struct {
    exporter_port: std.atomic.Value(u16) = .init(0),
    fetched: std.atomic.Value(bool) = .init(false),
    poked: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
};

fn deadlineAfter(io: std.Io) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = std.Io.Duration.fromMilliseconds(deadline_ms),
        .clock = .real,
    });
}

fn expired(io: std.Io, d: std.Io.Clock.Timestamp) bool {
    return std.Io.Clock.Timestamp.now(io, .real).compare(.gte, d);
}

fn waitFlag(io: std.Io, flag: *const std.atomic.Value(bool)) !void {
    const d = deadlineAfter(io);
    while (!flag.load(.acquire)) {
        if (expired(io, d)) return error.WaitTimedOut;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
    }
}

fn runLoopUntil(loop: *net.TcpLoop, done: *const std.atomic.Value(bool), out_err: *?anyerror, loop_done: *std.atomic.Value(bool)) void {
    loop.runUntil(done) catch |err| {
        out_err.* = err;
        loop_done.store(true, .release);
        return;
    };
    loop.closeAndDrain() catch |err| {
        out_err.* = err;
    };
    loop_done.store(true, .release);
}

fn pokeListener(io: std.Io, port: u16) void {
    if (port == 0) return;
    const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return;
    var stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

// ── Exporter E ───────────────────────────────────────────────────────────────

const ExporterState = struct {
    host: *Host,
    bridge: *TcpBridge,
    g_conn: ?*HostSession = null,
};

fn publishTarget(ctx: ?*anyopaque, served: *driver.Served) anyerror!void {
    _ = ctx;
    _ = try served.publish("widget", Widget, .{});
}

fn exporterOnOpen(ctx: ?*anyopaque, bridge: *TcpBridge, conn: *TcpBridge.Slot) anyerror!void {
    const state: *ExporterState = @ptrCast(@alignCast(ctx.?));
    if (conn.leg != .app_dial or conn.session.role != .dialed) return;
    if (state.g_conn != null) return;
    state.g_conn = conn.session;
    _ = try conn.session.served.publish("widget", Widget, .{});
    const desk = try state.host.fetch(conn.session, "introducer");
    try state.host.vowOn(desk, .{ .ctx = state, .func = onDesk });
    try bridge.drainActions();
}

fn onDesk(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *ExporterState = @ptrCast(@alignCast(ctx.?));
    const conn = state.g_conn orelse return;
    switch (resolution) {
        .fulfilled => |value| {
            if (value != .reference) return;
            _ = state.host.send(conn, value.reference, .{ .verb = "ready", .args = &.{} }) catch return;
            state.bridge.drainActions() catch {};
        },
        else => {},
    }
}

fn exporterTask(allocator: std.mem.Allocator, shared: *Shared, gifter_designator: []const u8) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var host = Host.init(allocator, [_]u8{0x0e} ** 32, .{ .frame_cap = frame_cap, .local_turn_budget = 64 });
    defer host.deinit();
    var state = ExporterState{ .host = &host, .bridge = undefined };
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &host, io, &loop, .{
        .publish = publishTarget,
        .on_open = exporterOnOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();
    state.bridge = &bridge;

    loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&bridge), .{
        .frame_cap = frame_cap,
        .max_conns = 8,
        .listen = 0,
        .make_conn_ctx = TcpBridge.makeConnCtx,
        .serve = TcpBridge.serve,
        .free_conn_ctx = TcpBridge.freeConnCtx,
        .on_close = TcpBridge.onClose,
    });
    defer loop.deinit();
    var buf: [tcp.designator_buf_len]u8 = undefined;
    const address = try tcp.parseHostPort("127.0.0.1", loop.port.?);
    const loc = tcp.locator(&buf, address);
    shared.exporter_port.store(loop.port.?, .release);
    try bridge.attach(tcp.transport_name, loc.designator, &.{});
    try bridge.dialOutbound(tcp.transport_name, gifter_designator, "");

    var loop_err: ?anyerror = null;
    var loop_done = std.atomic.Value(bool).init(false);
    var loop_future = try io.concurrent(runLoopUntil, .{ &loop, &shared.done, &loop_err, &loop_done });
    defer {
        shared.done.store(true, .release);
        pokeListener(io, loop.port.?);
        loop_future.await(io);
        if (loop_err) |err| std.debug.print("02: exporter loop: {s}\n", .{@errorName(err)});
    }

    try waitFlag(io, &shared.done);
}

// ── Gifter G ─────────────────────────────────────────────────────────────────

const GifterState = struct {
    host: *Host,
    shared: *Shared,
    widget: ?model.Reference = null,
    want_fetch: bool = false,
    fetch_sent: bool = false,

    fn onFetched(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *GifterState = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| {
                if (value == .reference) self.widget = value.reference;
            },
            else => {},
        }
        self.shared.fetched.store(true, .release);
    }
};

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
    _ = try served.publish("introducer", Desk, .{ .state = state });
}

fn gifterServe(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
    try TcpBridge.serve(conn_ctx, peer, event);
    const shell: *TcpBridge.Slot = @ptrCast(@alignCast(conn_ctx.?));
    const state: *GifterState = @ptrCast(@alignCast(shell.bridge.publish_ctx.?));
    if (state.want_fetch and !state.fetch_sent) {
        state.fetch_sent = true;
        const vow = try state.host.fetch(shell.session, "widget");
        try state.host.vowOn(vow, .{ .ctx = state, .func = GifterState.onFetched });
        try shell.bridge.drainActions();
    }
}

// ── Recipient R ──────────────────────────────────────────────────────────────

const ClientState = struct {
    host: *Host,
    poked: *std.atomic.Value(bool),
    g_conn: ?*HostSession = null,

    fn onIntroducer(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *ClientState = @ptrCast(@alignCast(ctx.?));
        const conn = self.g_conn orelse return;
        switch (resolution) {
            .fulfilled => |value| {
                if (value != .reference) return;
                const vow = self.host.send(conn, value.reference, .{ .verb = "introduce", .args = &.{} }) catch return;
                self.host.vowOn(vow, .{ .ctx = self, .func = onIntroduced }) catch return;
            },
            else => {},
        }
    }

    fn onIntroduced(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *ClientState = @ptrCast(@alignCast(ctx.?));
        const conn = self.g_conn orelse return;
        switch (resolution) {
            .fulfilled => |value| {
                const widget = switch (value) {
                    .reference => |r| r,
                    else => return,
                };
                std.debug.print("02: introduced to a capability on another peer, redeemed inside the settle\n", .{});
                const vow = self.host.send(conn, widget, .{ .verb = "poke", .args = &.{} }) catch return;
                self.host.vowOn(vow, .{ .ctx = self, .func = onPoked }) catch return;
            },
            .broken => |reason| std.debug.print("02: introduce broke: {s}\n", .{reason}),
            else => {},
        }
    }

    fn onPoked(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *ClientState = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| {
                if (value == .string) std.debug.print("02: {s}\n", .{value.string});
                self.poked.store(true, .release);
            },
            .broken => |reason| std.debug.print("02: poke broke: {s}\n", .{reason}),
            else => {},
        }
    }
};

fn clientOnOpen(ctx: ?*anyopaque, bridge: *TcpBridge, conn: *TcpBridge.Slot) anyerror!void {
    const state: *ClientState = @ptrCast(@alignCast(ctx.?));
    if (conn.leg != .app_dial or conn.session.role != .dialed) return;
    if (state.g_conn != null) return;
    state.g_conn = conn.session;
    const vow = try state.host.fetch(conn.session, "introducer");
    try state.host.vowOn(vow, .{ .ctx = state, .func = ClientState.onIntroducer });
    try bridge.drainActions();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var shared = Shared{};
    var gifter_host = Host.init(allocator, [_]u8{0x06} ** 32, .{ .frame_cap = frame_cap, .local_turn_budget = 64 });
    defer gifter_host.deinit();
    var g_state = GifterState{ .host = &gifter_host, .shared = &shared };
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &gifter_host, io, &loop, .{
        .publish = publishDesk,
        .publish_ctx = &g_state,
    });
    defer bridge.deinit();

    loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&bridge), .{
        .frame_cap = frame_cap,
        .max_conns = 8,
        .listen = 0,
        .make_conn_ctx = TcpBridge.makeConnCtx,
        .serve = gifterServe,
        .free_conn_ctx = TcpBridge.freeConnCtx,
        .on_close = TcpBridge.onClose,
    });
    defer loop.deinit();
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const gifter_designator_addr = try tcp.parseHostPort("127.0.0.1", loop.port.?);
    const gifter_designator = tcp.locator(&designator_buf, gifter_designator_addr).designator;
    try bridge.attach(tcp.transport_name, gifter_designator, &.{});

    var loop_err: ?anyerror = null;
    var loop_done = std.atomic.Value(bool).init(false);
    var loop_future = try io.concurrent(runLoopUntil, .{ &loop, &shared.done, &loop_err, &loop_done });
    defer {
        shared.done.store(true, .release);
        pokeListener(io, loop.port.?);
        loop_future.await(io);
        if (loop_err) |err| std.debug.print("02: gifter loop: {s}\n", .{@errorName(err)});
    }
    var exporter_future = try io.concurrent(exporterTask, .{ allocator, &shared, @as([]const u8, gifter_designator) });
    defer exporter_future.await(io) catch |err| std.debug.print("02: exporter: {s}\n", .{@errorName(err)});

    try waitFlag(io, &shared.fetched);

    var poked = std.atomic.Value(bool).init(false);
    var recipient_host = Host.init(allocator, [_]u8{0x0c} ** 32, .{ .frame_cap = frame_cap, .local_turn_budget = 64 });
    defer recipient_host.deinit();
    var r_state = ClientState{ .host = &recipient_host, .poked = &poked };
    var r_loop: net.TcpLoop = undefined;
    var r_bridge = TcpBridge.init(allocator, &recipient_host, io, &r_loop, .{
        .on_open = clientOnOpen,
        .on_open_ctx = &r_state,
    });
    defer r_bridge.deinit();
    r_loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&r_bridge), .{
        .frame_cap = frame_cap,
        .max_conns = 8,
        .listen = 0,
        .make_conn_ctx = TcpBridge.makeConnCtx,
        .serve = TcpBridge.serve,
        .free_conn_ctx = TcpBridge.freeConnCtx,
        .on_close = TcpBridge.onClose,
    });
    defer r_loop.deinit();
    var r_buf: [tcp.designator_buf_len]u8 = undefined;
    const r_designator_addr = try tcp.parseHostPort("127.0.0.1", r_loop.port.?);
    const r_designator = tcp.locator(&r_buf, r_designator_addr).designator;
    try r_bridge.attach(tcp.transport_name, r_designator, &.{});
    try r_bridge.dialOutbound(tcp.transport_name, gifter_designator, "");

    var r_err: ?anyerror = null;
    var r_done = std.atomic.Value(bool).init(false);
    var r_future = try io.concurrent(runLoopUntil, .{ &r_loop, &shared.done, &r_err, &r_done });
    defer {
        shared.done.store(true, .release);
        pokeListener(io, r_loop.port.?);
        r_future.await(io);
        if (r_err) |err| std.debug.print("02: recipient loop: {s}\n", .{@errorName(err)});
    }

    try waitFlag(io, &poked);

    shared.done.store(true, .release);
    pokeListener(io, loop.port.?);
    pokeListener(io, r_loop.port.?);
    pokeListener(io, shared.exporter_port.load(.acquire));
    std.debug.print("02: introduce and redeem OK\n", .{});
}
