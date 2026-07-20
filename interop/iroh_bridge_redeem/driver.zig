//! Iroh redeem dial on `driver.Bridge`: the recipient sits on
//! `completion.Loop(iroh.Backend, iroh.DialResolver)`. Introducing an E-homed
//! capability forces `Exec.dial`, then `Loop.dialLocator`, then `openDialedOver`,
//! then `exporterDialed`, so the withdraw settles on one loop thread over iroh
//! (ADR-0057, ADR-0076).
//!
//! Topology mirrors the TCP redeem theorem in `test/driver/bridge_test.zig`,
//! but every party rides Bridge+Loop: iroh has no pollable fd for a blocking
//! `stepReadable` round-robin the way a TCP Connection does.
//!
//!   G (gifter)     Bridge + Loop, the desk that introduces E's widget
//!   E (exporter)   Bridge + Loop, publishes the widget and accepts R's redeem
//!   R (recipient)  Bridge + Loop, redeems by dialing E by node id
//!
//! Not part of the hermetic `zig build check`: it links the Rust sidecar
//! staticlib, so it runs as the sibling step `zig build iroh-bridge-redeem`.

const std = @import("std");
const pancake = @import("pancake");
const iroh = @import("iroh");
const harness = @import("interop_harness");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;

const frame_cap: usize = 4096;
const deadline_ms: u64 = 30_000;

const IrohLoop = net.completion.Loop(iroh.Backend, iroh.DialResolver);
const IrohBridge = driver.Bridge(IrohLoop);

const gifter_seed: [32]u8 = @splat(0x26);
const exporter_seed: [32]u8 = @splat(0x2e);
const recipient_seed: [32]u8 = @splat(0x2c);

const Widget = harness.StaticReplyActor("poke", "poked directly at the exporter");

const RedeemShared = struct {
    gifter_id: []const u8 = &.{},
    recipient_id: []const u8 = &.{},
    fetched: std.atomic.Value(bool) = .init(false),
    poked: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
};

fn waitFlag(io: std.Io, flag: *const std.atomic.Value(bool)) !void {
    try harness.untilFlag(io, deadline_ms, flag);
}

fn waitNonEmpty(io: std.Io, slice: *const []const u8) !void {
    const deadline = harness.deadlineAfter(io, deadline_ms);
    while (slice.*.len == 0) {
        if (harness.expired(io, deadline)) return error.WaitTimedOut;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
    }
}

fn runLoop(loop: *IrohLoop, until_closed: usize, out_err: *?anyerror, loop_done: *std.atomic.Value(bool)) void {
    loop.run(.{ .after_closed = until_closed }) catch |err| {
        out_err.* = err;
    };
    loop_done.store(true, .release);
}

fn initLoop(
    allocator: std.mem.Allocator,
    resident: *iroh.Resident,
    bridge: *IrohBridge,
    serve: net.completion.Serve,
) !IrohLoop {
    const read_buffer_bytes: u32 = @intCast(@min(frame_cap, 16 * 1024));
    const backend = try iroh.Backend.initBound(allocator, resident, 256, 256, read_buffer_bytes);
    // This driver interposes its own `serve` (it watches the redeem settle),
    // so it overrides the bridge's spliced hook after `hookOptions`.
    var options = IrohBridge.hookOptions(.{
        .frame_cap = frame_cap,
        .max_conns = 8,
        .listen = 0,
    });
    options.serve = serve;
    return IrohLoop.initWithBackend(allocator, backend, IrohBridge.makePeer, @ptrCast(bridge), options);
}

fn joinLoop(io: std.Io, resident: *iroh.Resident, loop_done: *std.atomic.Value(bool), loop_future: *std.Io.Future(void), loop_err: *?anyerror) void {
    const drain_deadline = harness.deadlineAfter(io, deadline_ms);
    while (!loop_done.load(.acquire)) {
        if (harness.expired(io, drain_deadline)) break;
        resident.close();
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
    }
    loop_future.await(io);
    if (loop_err.*) |err| std.debug.print("loop: {s}\n", .{@errorName(err)});
}

// ── Exporter E ───────────────────────────────────────────────────────────────

const ExporterState = struct {
    host: *Host,
    bridge: *IrohBridge,
    g_conn: ?*HostSession = null,
};

const publishExporterTarget = harness.publisher("target", Widget);

fn exporterOnOpen(ctx: ?*anyopaque, bridge: *IrohBridge, conn: *IrohBridge.Slot) anyerror!void {
    const state: *ExporterState = @ptrCast(@alignCast(ctx.?));
    // Application dial to G (not a redeem). R's redeem is accepted, not dialed.
    // Publish runs only on accepted desks — dialed legs publish explicitly
    // (same as the TCP redeem theorem's `to_g.publish("target", …)`).
    if (conn.leg != .app_dial or conn.session.role != .dialed) return;
    if (state.g_conn != null) return;
    state.g_conn = conn.session;
    _ = try conn.session.served.publish("target", Widget, .{});
    const desk = try state.host.fetch(conn.session, "desk");
    try state.host.vowOn(desk, .{ .ctx = state, .func = onGifterDesk });
    try bridge.drainActions();
}

fn onGifterDesk(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *ExporterState = @ptrCast(@alignCast(ctx.?));
    const conn = state.g_conn orelse return;
    switch (resolution) {
        .fulfilled => |value| {
            if (value != .reference) return;
            const vow = state.host.send(conn, value.reference, .{ .verb = "ready", .args = &.{} }) catch |err| {
                std.debug.print("exporter ready send: {s}\n", .{@errorName(err)});
                return;
            };
            state.host.vowOn(vow, .{ .ctx = state, .func = onReadyAck }) catch |err| {
                std.debug.print("exporter ready vowOn: {s}\n", .{@errorName(err)});
                return;
            };
            state.bridge.drainActions() catch {};
        },
        .broken => |reason| std.debug.print("exporter desk fetch broke: {s}\n", .{reason}),
        .give => {},
    }
}

fn onReadyAck(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    _ = ctx;
    switch (resolution) {
        .broken => |reason| std.debug.print("exporter ready broke: {s}\n", .{reason}),
        else => {},
    }
}

fn exporterServe(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
    try IrohBridge.serve(conn_ctx, peer, event);
}

fn exporterTask(allocator: std.mem.Allocator, shared: *RedeemShared) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try iroh.Resident.init(io, &exporter_seed, .{ .reachability = .local_discovery });
    defer resident.deinit();
    var id_buf: [iroh.node_id_len]u8 = undefined;
    const id = resident.nodeId(&id_buf);

    var host = Host.init(allocator, exporter_seed, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer host.deinit();
    var state = ExporterState{ .host = &host, .bridge = undefined };
    var loop: IrohLoop = undefined;
    var bridge = IrohBridge.init(allocator, &host, io, &loop, .{
        .publish = publishExporterTarget,
        .on_open = exporterOnOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();
    state.bridge = &bridge;

    loop = try initLoop(allocator, &resident, &bridge, exporterServe);
    defer loop.deinit();
    try bridge.attach(iroh.transport_name, id, &.{});

    // Dial G on the loop-owner thread before `run` (same affinity as dialOutbound).
    try waitNonEmpty(io, &shared.gifter_id);
    try bridge.dialOutbound(iroh.transport_name, shared.gifter_id, "");

    var loop_err: ?anyerror = null;
    var loop_done = std.atomic.Value(bool).init(false);
    // Dialed G (deposit) + accept from R (redeem) = 2 closes at teardown.
    var loop_future = try io.concurrent(runLoop, .{ &loop, @as(usize, 2), &loop_err, &loop_done });
    defer {
        joinLoop(io, &resident, &loop_done, &loop_future, &loop_err);
    }

    try waitFlag(io, &shared.done);
}

// ── Gifter G ─────────────────────────────────────────────────────────────────

const GifterState = struct {
    host: *Host,
    bridge: *IrohBridge,
    shared: *RedeemShared,
    widget: ?model.Reference = null,
    want_fetch: bool = false,
    from_e: ?*HostSession = null,
    r_conn: ?*HostSession = null,
    dialed_r: bool = false,
    intro_started: bool = false,
};

const RedeemDesk = struct {
    state: *GifterState,
    pub fn handle(self: *RedeemDesk, turn: *actors.Turn, msg: actors.Message) !model.Argument {
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

const Introducer = struct {
    widget: model.Reference,
    pub fn handle(self: *Introducer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "introduce")) return error.NoSuchMethod;
        return .{ .reference = self.widget };
    }
};

fn publishGifterDesk(ctx: ?*anyopaque, served: *driver.Served) anyerror!void {
    const state: *GifterState = @ptrCast(@alignCast(ctx.?));
    _ = try served.publish("desk", RedeemDesk, .{ .state = state });
}

fn gifterMaybeDialRecipient(state: *GifterState) void {
    if (state.dialed_r or state.widget == null) return;
    if (state.shared.recipient_id.len == 0) return;
    state.dialed_r = true;
    state.bridge.dialOutbound(iroh.transport_name, state.shared.recipient_id, "") catch |err| {
        std.debug.print("gifter dial R: {s}\n", .{@errorName(err)});
        state.dialed_r = false;
    };
}

fn gifterServe(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
    try IrohBridge.serve(conn_ctx, peer, event);
    const shell: *IrohBridge.Slot = @ptrCast(@alignCast(conn_ctx.?));
    const state: *GifterState = @ptrCast(@alignCast(shell.bridge.publish_ctx.?));

    if (state.want_fetch and state.widget == null and state.from_e == null and shell.session.role == .accepted) {
        state.from_e = shell.session;
        const vow = try state.host.fetch(shell.session, "target");
        try state.host.vowOn(vow, .{ .ctx = state, .func = onWidget });
        try shell.bridge.drainActions();
    }

    // Dial R once the widget is in hand and R's id is published.
    gifterMaybeDialRecipient(state);
}

fn onWidget(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *GifterState = @ptrCast(@alignCast(ctx.?));
    switch (resolution) {
        .fulfilled => |value| {
            if (value != .reference) return;
            state.widget = value.reference;
            state.shared.fetched.store(true, .release);
            gifterMaybeDialRecipient(state);
        },
        .broken => |reason| std.debug.print("gifter widget fetch broke: {s}\n", .{reason}),
        .give => {},
    }
}

fn gifterOnOpen(ctx: ?*anyopaque, bridge: *IrohBridge, conn: *IrohBridge.Slot) anyerror!void {
    const state: *GifterState = @ptrCast(@alignCast(ctx.?));
    if (conn.session.role != .dialed or conn.leg != .app_dial) return;
    if (state.r_conn != null) return;
    const widget = state.widget orelse return;
    state.r_conn = conn.session;
    _ = try conn.session.served.publish("desk", Introducer, .{ .widget = widget });
    const inbox = try state.host.fetch(conn.session, "inbox");
    try state.host.vowOn(inbox, .{ .ctx = state, .func = onInbox });
    try bridge.drainActions();
}

fn onInbox(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *GifterState = @ptrCast(@alignCast(ctx.?));
    const conn = state.r_conn orelse return;
    switch (resolution) {
        .fulfilled => |value| {
            if (value != .reference) return;
            if (state.intro_started) return;
            state.intro_started = true;
            const vow = state.host.send(conn, value.reference, .{ .verb = "ready", .args = &.{} }) catch |err| {
                std.debug.print("gifter ready send: {s}\n", .{@errorName(err)});
                return;
            };
            _ = vow;
            state.bridge.drainActions() catch {};
        },
        .broken => |reason| std.debug.print("gifter inbox fetch broke: {s}\n", .{reason}),
        .give => {},
    }
}

fn gifterTask(allocator: std.mem.Allocator, shared: *RedeemShared) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try iroh.Resident.init(io, &gifter_seed, .{ .reachability = .local_discovery });
    defer resident.deinit();
    var id_buf: [iroh.node_id_len]u8 = undefined;
    const id = resident.nodeId(&id_buf);
    const id_owned = try allocator.dupe(u8, id);
    defer allocator.free(id_owned);
    shared.gifter_id = id_owned;

    var host = Host.init(allocator, gifter_seed, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer host.deinit();
    var state = GifterState{ .host = &host, .bridge = undefined, .shared = shared };
    var loop: IrohLoop = undefined;
    var bridge = IrohBridge.init(allocator, &host, io, &loop, .{
        .publish = publishGifterDesk,
        .publish_ctx = &state,
        .on_open = gifterOnOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();
    state.bridge = &bridge;

    loop = try initLoop(allocator, &resident, &bridge, gifterServe);
    defer loop.deinit();
    try bridge.attach(iroh.transport_name, id, &.{});

    var loop_err: ?anyerror = null;
    var loop_done = std.atomic.Value(bool).init(false);
    // Accept E + dialed R = 2 closes at teardown.
    var loop_future = try io.concurrent(runLoop, .{ &loop, @as(usize, 2), &loop_err, &loop_done });
    defer {
        joinLoop(io, &resident, &loop_done, &loop_future, &loop_err);
    }

    try waitFlag(io, &shared.poked);
    try waitFlag(io, &shared.done);
}

// ── Recipient R ──────────────────────────────────────────────────────────────

const RecipientState = struct {
    host: *Host,
    shared: *RedeemShared,
    gifter_conn: ?*HostSession = null,
    want_intro: bool = false,
    intro_sent: bool = false,
};

const ReadyInbox = struct {
    state: *RecipientState,
    pub fn handle(self: *ReadyInbox, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "ready")) return error.NoSuchMethod;
        self.state.want_intro = true;
        return .{ .boolean = true };
    }
};

fn publishReadyInbox(ctx: ?*anyopaque, served: *driver.Served) anyerror!void {
    const state: *RecipientState = @ptrCast(@alignCast(ctx.?));
    _ = try served.publish("inbox", ReadyInbox, .{ .state = state });
}

fn recipientServe(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
    try IrohBridge.serve(conn_ctx, peer, event);
    const shell: *IrohBridge.Slot = @ptrCast(@alignCast(conn_ctx.?));
    const state: *RecipientState = @ptrCast(@alignCast(shell.bridge.publish_ctx.?));
    if (state.want_intro and !state.intro_sent and shell.leg == .accept or shell.leg == .app_dial) {
        state.intro_sent = true;
        state.gifter_conn = shell.session;
        const vow = try state.host.fetch(shell.session, "desk");
        try state.host.vowOn(vow, .{ .ctx = state, .func = onDesk });
        try shell.bridge.drainActions();
    }
}

fn onDesk(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const self: *RecipientState = @ptrCast(@alignCast(ctx.?));
    const conn = self.gifter_conn orelse return;
    switch (resolution) {
        .fulfilled => |value| {
            if (value != .reference) return;
            const vow = self.host.send(conn, value.reference, .{ .verb = "introduce", .args = &.{} }) catch |err| {
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
    const self: *RecipientState = @ptrCast(@alignCast(ctx.?));
    const conn = self.gifter_conn orelse return;
    switch (resolution) {
        .fulfilled => |value| {
            const widget = switch (value) {
                .reference => |r| r,
                else => return,
            };
            const vow = self.host.send(conn, widget, .{ .verb = "poke", .args = &.{} }) catch |err| {
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
    const self: *RecipientState = @ptrCast(@alignCast(ctx.?));
    switch (resolution) {
        .fulfilled => |value| {
            if (value == .string and std.mem.eql(u8, value.string, "poked directly at the exporter")) {
                self.shared.poked.store(true, .release);
            }
        },
        .broken => |reason| std.debug.print("poke broke: {s}\n", .{reason}),
        .give => {},
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var shared = RedeemShared{};

    // Publish R's id and start its loop before G/E so G's dial-to-R cannot
    // race a not-yet-polling listener.
    var recipient_resident = try iroh.Resident.init(io, &recipient_seed, .{ .reachability = .local_discovery });
    defer recipient_resident.deinit();
    var recipient_id_buf: [iroh.node_id_len]u8 = undefined;
    const recipient_id = recipient_resident.nodeId(&recipient_id_buf);
    const recipient_id_owned = try allocator.dupe(u8, recipient_id);
    defer allocator.free(recipient_id_owned);
    shared.recipient_id = recipient_id_owned;

    var recipient_host = Host.init(allocator, recipient_seed, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer recipient_host.deinit();
    var state = RecipientState{ .host = &recipient_host, .shared = &shared };
    var loop: IrohLoop = undefined;
    var bridge = IrohBridge.init(allocator, &recipient_host, io, &loop, .{
        .publish = publishReadyInbox,
        .publish_ctx = &state,
    });
    defer bridge.deinit();

    loop = try initLoop(allocator, &recipient_resident, &bridge, recipientServe);
    var loop_deinited = false;
    defer if (!loop_deinited) loop.deinit();
    try bridge.attach(iroh.transport_name, recipient_id, &.{});

    var loop_err: ?anyerror = null;
    var loop_done = std.atomic.Value(bool).init(false);
    // Accept G + dialed redeem to E = 2.
    var loop_future = try io.concurrent(runLoop, .{ &loop, @as(usize, 2), &loop_err, &loop_done });
    var gifter_future = try io.concurrent(gifterTask, .{ allocator, &shared });
    var exporter_future = try io.concurrent(exporterTask, .{ allocator, &shared });

    defer {
        shared.done.store(true, .release);
        exporter_future.await(io) catch |err| std.debug.print("exporter: {s}\n", .{@errorName(err)});
        gifter_future.await(io) catch |err| std.debug.print("gifter: {s}\n", .{@errorName(err)});
        joinLoop(io, &recipient_resident, &loop_done, &loop_future, &loop_err);
        loop.deinit();
        loop_deinited = true;
    }
    try waitFlag(io, &shared.poked);

    std.debug.print(
        "iroh-bridge-redeem: OK, recipient on one loop thread redeemed an iroh handoff via Loop.dialLocator\n",
        .{},
    );
}
