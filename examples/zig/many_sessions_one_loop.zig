//! Many sessions on one loop thread, with a handoff crossing them.
//!
//! Chapter 02 shows the introduction on the plain application surface, where
//! one `call` settles as the introduced service. This program shows the same
//! move on the completion-loop tier — `driver.core.Host` + `driver.Bridge` +
//! `net.TcpLoop` (ADR-0068, ADR-0076) — the tier you reach for when one
//! thread must serve many connections rather than one.
//!
//! What it costs is visible below: explicit readiness flags, a loop that owns
//! the sockets, and hooks the embedder supplies. That is the trade — the
//! chapter-02 surface hides all of it, and cannot serve at this scale.
//!
//! Three parties in one process: widget (exporter), directory (gifter),
//! client (recipient). The choreography matches the deposit theorem in
//! `test/driver/bridge_test.zig`.
//!
//! Run: `zig build examples` (it also runs under `zig build check`).

const std = @import("std");
const builtin = @import("builtin");
const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const driver = glowcap.driver;
const net = glowcap.net;
const tcp = net.tcp;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const TcpBridge = driver.Bridge(net.TcpLoop);

const frame_cap = 4096;
const read_buffer_bytes = 4096;
const deadline_ms: u64 = 15_000;

const Widget = struct {
    pub fn handle(self: *Widget, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "poke")) return error.NoSuchMethod;
        return .{ .string = "poked: directly, the directory is out of the path" };
    }
};

const Shared = struct {
    exporter_port: std.atomic.Value(u16) = .init(0),
    fetched: std.atomic.Value(bool) = .init(false),
    poked: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    err_int: std.atomic.Value(u16) = .init(0),

    fn noteErr(self: *Shared, err: anyerror) void {
        _ = self.err_int.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
        self.failed.store(true, .seq_cst);
    }

    fn takeErr(self: *const Shared) ?anyerror {
        const n = self.err_int.load(.seq_cst);
        if (n == 0) return null;
        return @errorFromInt(n);
    }
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

fn waitFlag(io: std.Io, flag: *const std.atomic.Value(bool), shared: *const Shared) !void {
    const d = deadlineAfter(io);
    while (!flag.load(.acquire)) {
        if (shared.failed.load(.seq_cst)) return shared.takeErr() orelse error.ObserverFailed;
        if (expired(io, d)) return error.WaitTimedOut;
        // tolerant: an interrupted poll sleep only rechecks the flag sooner.
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
    }
    if (shared.failed.load(.seq_cst)) return shared.takeErr() orelse error.ObserverFailed;
}

fn runLoopUntil(loop: *net.TcpLoop, done: *const std.atomic.Value(bool)) !void {
    try loop.runUntil(done, 0);
    try loop.closeAndDrain();
}

fn pokeListener(io: std.Io, port: u16) void {
    if (port == 0) return;
    // best-effort: the poke exists only to unblock a parked accept; a refused
    // dial means nothing is parked there any more.
    const address = std.Io.net.IpAddress.parse("127.0.0.1", port) catch return;
    var stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

// ── Exporter E ───────────────────────────────────────────────────────────────

const ExporterState = struct {
    host: *Host,
    bridge: *TcpBridge,
    shared: *Shared,
    g_session: ?*HostSession = null,
};

fn publishTarget(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
    _ = ctx;
    _ = try served.publish(vat, "widget", Widget, .{});
}

fn exporterOnOpen(ctx: ?*anyopaque, bridge: *TcpBridge, slot: *TcpBridge.Slot) anyerror!void {
    const state: *ExporterState = @ptrCast(@alignCast(ctx.?));
    if (slot.leg != .app_dial or slot.session.role != .dialed) return;
    if (state.g_session != null) return;
    state.g_session = slot.session;
    _ = try slot.session.served.publish(&state.host.vat, "widget", Widget, .{});
    const desk = try state.host.fetch(slot.session, "introducer");
    try state.host.vowOn(desk, .{ .ctx = state, .func = onDesk });
    try bridge.drainActions();
}

fn onDesk(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *ExporterState = @ptrCast(@alignCast(ctx.?));
    const session = state.g_session orelse {
        state.shared.noteErr(error.MissingGifterSession);
        return;
    };
    switch (resolution) {
        .fulfilled => |value| {
            if (value != .reference) {
                state.shared.noteErr(error.UnexpectedDeskPayload);
                return;
            }
            _ = state.host.send(session, value.reference, .{ .verb = "ready", .args = &.{} }) catch |err| {
                state.shared.noteErr(err);
                return;
            };
            // The completion loop drains. drainActions from this listener is
            // ReenteredHost; that refusal is not a failed ready.
        },
        .broken => state.shared.noteErr(error.DeskBroke),
        .give => state.shared.noteErr(error.UnexpectedGive),
    }
}

fn exporterTask(allocator: std.mem.Allocator, shared: *Shared, gifter_designator: []const u8) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var session_root: [32]u8 = undefined;
    try io.randomSecure(&session_root);
    var host = try Host.init(allocator, @as([32]u8, @splat(0x0e)), session_root, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer host.deinit();
    var state = ExporterState{ .host = &host, .bridge = undefined, .shared = shared };
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &host, io, &loop, .{
        .publish = publishTarget,
        .on_open = exporterOnOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();
    state.bridge = &bridge;

    loop = try net.TcpLoop.initWithBackendOptions(allocator, .{
        .read_buffer_bytes = read_buffer_bytes,
    }, TcpBridge.makePeer, @ptrCast(&bridge), TcpBridge.hookOptions(.{
        .max_conns = 8,
        .listen = 0,
    }));
    defer loop.deinit();
    var buf: [tcp.designator_buf_len]u8 = undefined;
    const address = try tcp.parseHostPort("127.0.0.1", loop.port().?);
    const loc = tcp.locatorFromAddress(&buf, address);
    shared.exporter_port.store(loop.port().?, .release);
    try bridge.attach(model.transport.Known.tcp.metadata(), loc.designator, &.{});
    try bridge.dialOutbound(.{
        .transport = tcp.transport_name,
        .designator = gifter_designator,
        .hints = model.Hints.emptyFalse(),
    });

    var loop_future = try io.concurrent(runLoopUntil, .{ &loop, &shared.done });
    try loop_future.await(io);
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
                if (value != .reference) {
                    self.shared.noteErr(error.UnexpectedFetchPayload);
                    return;
                }
                self.widget = value.reference;
                self.shared.fetched.store(true, .release);
            },
            .broken => self.shared.noteErr(error.FetchBroke),
            .give => self.shared.noteErr(error.UnexpectedGive),
        }
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

fn publishDesk(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
    const state: *GifterState = @ptrCast(@alignCast(ctx.?));
    _ = try served.publish(vat, "introducer", Desk, .{ .state = state });
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
    shared: *Shared,
    g_session: ?*HostSession = null,

    fn onIntroducer(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *ClientState = @ptrCast(@alignCast(ctx.?));
        const session = self.g_session orelse {
            self.shared.noteErr(error.MissingGifterSession);
            return;
        };
        switch (resolution) {
            .fulfilled => |value| {
                if (value != .reference) {
                    self.shared.noteErr(error.UnexpectedIntroducerPayload);
                    return;
                }
                const vow = self.host.send(session, value.reference, .{ .verb = "introduce", .args = &.{} }) catch |err| {
                    self.shared.noteErr(err);
                    return;
                };
                self.host.vowOn(vow, .{ .ctx = self, .func = onIntroduced }) catch |err| self.shared.noteErr(err);
            },
            .broken => self.shared.noteErr(error.IntroducerBroke),
            .give => self.shared.noteErr(error.UnexpectedGive),
        }
    }

    fn onIntroduced(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *ClientState = @ptrCast(@alignCast(ctx.?));
        const session = self.g_session orelse {
            self.shared.noteErr(error.MissingGifterSession);
            return;
        };
        switch (resolution) {
            .fulfilled => |value| {
                const widget = switch (value) {
                    .reference => |r| r,
                    else => {
                        self.shared.noteErr(error.UnexpectedIntroducePayload);
                        return;
                    },
                };
                std.debug.print("many-sessions: introduced to a capability on another peer, redeemed inside the settle\n", .{});
                const vow = self.host.send(session, widget, .{ .verb = "poke", .args = &.{} }) catch |err| {
                    self.shared.noteErr(err);
                    return;
                };
                self.host.vowOn(vow, .{ .ctx = self, .func = onPoked }) catch |err| self.shared.noteErr(err);
            },
            .broken => |reason| {
                std.debug.print("many-sessions: introduce broke: {s}\n", .{reason});
                self.shared.noteErr(error.IntroduceBroke);
            },
            .give => self.shared.noteErr(error.UnexpectedGive),
        }
    }

    fn onPoked(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *ClientState = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| {
                if (value != .string) {
                    self.shared.noteErr(error.UnexpectedPokePayload);
                    return;
                }
                std.debug.print("many-sessions: {s}\n", .{value.string});
                self.shared.poked.store(true, .release);
            },
            .broken => |reason| {
                std.debug.print("many-sessions: poke broke: {s}\n", .{reason});
                self.shared.noteErr(error.PokeBroke);
            },
            .give => self.shared.noteErr(error.UnexpectedGive),
        }
    }
};

fn clientOnOpen(ctx: ?*anyopaque, bridge: *TcpBridge, slot: *TcpBridge.Slot) anyerror!void {
    const state: *ClientState = @ptrCast(@alignCast(ctx.?));
    if (slot.leg != .app_dial or slot.session.role != .dialed) return;
    if (state.g_session != null) return;
    state.g_session = slot.session;
    const vow = try state.host.fetch(slot.session, "introducer");
    try state.host.vowOn(vow, .{ .ctx = state, .func = ClientState.onIntroducer });
    try bridge.drainActions();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var shared = Shared{};
    var gifter_session_root: [32]u8 = undefined;
    try io.randomSecure(&gifter_session_root);
    var gifter_host = try Host.init(allocator, @as([32]u8, @splat(0x06)), gifter_session_root, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer gifter_host.deinit();
    var g_state = GifterState{ .host = &gifter_host, .shared = &shared };
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &gifter_host, io, &loop, .{
        .publish = publishDesk,
        .publish_ctx = &g_state,
    });
    defer bridge.deinit();

    // The gifter interposes its own `serve` (it watches the introduce
    // settle), so it overrides the bridge's spliced hook after `hookOptions`.
    var gifter_options = TcpBridge.hookOptions(.{
        .max_conns = 8,
        .listen = 0,
    });
    gifter_options.serve = gifterServe;
    loop = try net.TcpLoop.initWithBackendOptions(
        allocator,
        .{ .read_buffer_bytes = read_buffer_bytes },
        TcpBridge.makePeer,
        @ptrCast(&bridge),
        gifter_options,
    );
    defer loop.deinit();
    if (comptime builtin.os.tag == .linux) {
        const backend_status = net.tcpBackendStatus(&loop);
        if (backend_status.fallback_reason) |reason| {
            std.debug.print("many-sessions: Linux backend={s} because {s}\n", .{
                @tagName(backend_status.implementation),
                reason.message(),
            });
        } else {
            std.debug.print("many-sessions: Linux backend={s}\n", .{@tagName(backend_status.implementation)});
        }
    }
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const gifter_designator_addr = try tcp.parseHostPort("127.0.0.1", loop.port().?);
    const gifter_designator = tcp.locatorFromAddress(&designator_buf, gifter_designator_addr).designator;
    try bridge.attach(model.transport.Known.tcp.metadata(), gifter_designator, &.{});

    var loop_future = try io.concurrent(runLoopUntil, .{ &loop, &shared.done });
    var exporter_future = try io.concurrent(exporterTask, .{ allocator, &shared, @as([]const u8, gifter_designator) });
    var gifter_joined = false;
    defer {
        if (!gifter_joined) {
            shared.done.store(true, .release);
            pokeListener(io, loop.port().?);
            pokeListener(io, shared.exporter_port.load(.acquire));
            // best-effort: unwind join only. The success path uses `try await`
            // before printing, so the error that got us here is the one reported.
            loop_future.await(io) catch {};
            exporter_future.await(io) catch {};
        }
    }

    try waitFlag(io, &shared.fetched, &shared);

    var recipient_session_root: [32]u8 = undefined;
    try io.randomSecure(&recipient_session_root);
    var recipient_host = try Host.init(allocator, @as([32]u8, @splat(0x0c)), recipient_session_root, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer recipient_host.deinit();
    var r_state = ClientState{ .host = &recipient_host, .shared = &shared };
    var r_loop: net.TcpLoop = undefined;
    var r_bridge = TcpBridge.init(allocator, &recipient_host, io, &r_loop, .{
        .on_open = clientOnOpen,
        .on_open_ctx = &r_state,
    });
    defer r_bridge.deinit();
    r_loop = try net.TcpLoop.initWithBackendOptions(allocator, .{
        .read_buffer_bytes = read_buffer_bytes,
    }, TcpBridge.makePeer, @ptrCast(&r_bridge), TcpBridge.hookOptions(.{
        .max_conns = 8,
        .listen = 0,
    }));
    defer r_loop.deinit();
    var r_buf: [tcp.designator_buf_len]u8 = undefined;
    const r_designator_addr = try tcp.parseHostPort("127.0.0.1", r_loop.port().?);
    const r_designator = tcp.locatorFromAddress(&r_buf, r_designator_addr).designator;
    try r_bridge.attach(model.transport.Known.tcp.metadata(), r_designator, &.{});
    try r_bridge.dialOutbound(.{
        .transport = tcp.transport_name,
        .designator = gifter_designator,
        .hints = model.Hints.emptyFalse(),
    });

    var r_future = try io.concurrent(runLoopUntil, .{ &r_loop, &shared.done });
    var recipient_joined = false;
    defer {
        if (!recipient_joined) {
            shared.done.store(true, .release);
            pokeListener(io, r_loop.port().?);
            // best-effort: unwind join only. The success path uses `try await`
            // before printing, so the error that got us here is the one reported.
            r_future.await(io) catch {};
        }
    }

    try waitFlag(io, &shared.poked, &shared);

    shared.done.store(true, .release);
    pokeListener(io, loop.port().?);
    pokeListener(io, r_loop.port().?);
    pokeListener(io, shared.exporter_port.load(.acquire));
    try r_future.await(io);
    recipient_joined = true;
    try exporter_future.await(io);
    try loop_future.await(io);
    gifter_joined = true;
    std.debug.print("many-sessions: introduce and redeem OK\n", .{});
}
