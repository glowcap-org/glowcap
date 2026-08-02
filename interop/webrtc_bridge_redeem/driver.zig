//! WebRTC redeem dial on `driver.Bridge`: the recipient sits on
//! `completion.Loop(webrtc.Backend, webrtc.DialResolver)`. Introducing an
//! E-homed capability forces `Exec.dial`, then `Loop.dialLocator`, then the
//! backend's signaling bring-up, then `openDialedOver` and `exporterDialed`,
//! so the withdraw settles on one loop thread over a real DataChannel — the
//! native mirror of the rooms app's `rooms-web-dm-webrtc` proof (ADR-0089).
//!
//! Topology mirrors `interop/iroh_bridge_redeem/driver.zig`; every leg is a
//! DataChannel, and all signaling rides one in-process hub — the stand-in for
//! the room-carried capability — through the backends' thread-safe entries:
//!
//!   G (gifter)     Bridge + Loop, the desk that introduces E's widget
//!   E (exporter)   Bridge + Loop, publishes the widget and accepts R's redeem
//!   R (recipient)  Bridge + Loop, redeems by dialing E's bare webrtc designator
//!
//! Not part of the hermetic `zig build check` as a runnable (it links the Rust
//! sidecar); the compile-only sibling rides `check`. Run:
//! `zig build webrtc-bridge-redeem`.

const std = @import("std");
const pancake = @import("pancake");
const webrtc = @import("webrtc");
const harness = @import("interop_harness");

const crypto = pancake.foundation.crypto;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;

const frame_cap: usize = 4096;
const deadline_ms: u64 = 30_000;

const WebrtcLoop = net.completion.Loop(webrtc.Backend, webrtc.DialResolver);
const WebrtcBridge = driver.Bridge(WebrtcLoop);
const runLoop = harness.LoopRunner(WebrtcLoop).runUntilFlag;

const gifter_seed: [32]u8 = @splat(0x26);
const exporter_seed: [32]u8 = @splat(0x2e);
const recipient_seed: [32]u8 = @splat(0x2c);

const Widget = harness.StaticReplyActor("poke", "poked directly at the exporter");

const RedeemShared = struct {
    fetched: std.atomic.Value(bool) = .init(false),
    poked: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
};

fn waitFlag(io: std.Io, flag: *const std.atomic.Value(bool)) !void {
    try harness.untilFlag(io, deadline_ms, flag);
}

// ── The in-process signaling hub ─────────────────────────────────────────────
//
// The stand-in for the room-carried signaling capability: it routes each
// offer to the target node's backend (creating and adopting the answerer
// there), pairs the two exchange fds, and ferries answers and candidates
// between the paired backends through their thread-safe entries. Every entry
// runs on some node's loop thread; the hub's own tables take a SpinLock.

const Node = struct {
    designator: [crypto.PeerKey.designator_len]u8,
    key: crypto.PeerKey,
    resident: *webrtc.Resident,
    backend: *webrtc.Backend,
};

const PairEnd = struct { node: *Node, fd: i32 };

const Hub = struct {
    mutex: pancake.net.sync.SpinLock = .{},
    allocator: std.mem.Allocator,
    nodes: [3]?*Node = .{ null, null, null },
    pairs: std.AutoHashMap(u64, PairEnd),

    fn init(allocator: std.mem.Allocator) Hub {
        return .{ .allocator = allocator, .pairs = std.AutoHashMap(u64, PairEnd).init(allocator) };
    }

    fn deinit(self: *Hub) void {
        self.pairs.deinit();
    }

    fn pairKey(node: *Node, fd: i32) u64 {
        return (@as(u64, @intFromPtr(node)) << 16) ^ @as(u64, @bitCast(@as(i64, fd))) & 0xffff;
    }

    fn register(self: *Hub, node: *Node) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.nodes) |*slot| {
            if (slot.* == null) {
                slot.* = node;
                return;
            }
        }
        unreachable; // three parties, three slots
    }

    fn byDesignator(self: *Hub, designator: []const u8) ?*Node {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.nodes) |slot| {
            const node = slot orelse continue;
            if (std.mem.eql(u8, node.designator[0..], designator)) return node;
        }
        return null;
    }

    fn pair(self: *Hub, a: PairEnd, b: PairEnd) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.pairs.put(pairKey(a.node, a.fd), b);
        try self.pairs.put(pairKey(b.node, b.fd), a);
    }

    fn peerOf(self: *Hub, node: *Node, fd: i32) ?PairEnd {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.pairs.get(pairKey(node, fd));
    }
};

/// One node's face on the hub: the `SignalingAuthority` ctx, carrying who is
/// offering so the target can authorize the exchange's identity.
const Port = struct {
    hub: *Hub,
    self_node: *Node,

    fn authority(self: *Port) webrtc.SignalingAuthority {
        return .{ .ctx = self, .sendOffer = sendOffer, .sendCandidate = sendCandidate };
    }

    /// Bring up the answerer at the target and route the answer back — the
    /// whole exchange the room carries in the rooms app, inlined.
    fn sendOffer(ctx: *anyopaque, fd: i32, designator: []const u8, sdp: []const u8) anyerror!void {
        const port: *Port = @ptrCast(@alignCast(ctx));
        const target = port.hub.byDesignator(designator) orelse return error.UnknownPeer;
        var answerer = try target.resident.newPeer(false);
        errdefer answerer.deinit();
        try answerer.setRemoteOffer(sdp);
        var answer_buf: [16 * 1024]u8 = undefined;
        var answer_len: usize = 0;
        const answer = try answerer.createAnswer(&answer_buf, &answer_len);
        // The exchange is scoped to the offerer's durable identity: the
        // authenticated-transport binding the target's accepted session pins.
        answerer.authorizeRemote(port.self_node.key);
        const target_fd = try target.backend.adoptAnswerer(answerer);
        try port.hub.pair(
            .{ .node = port.self_node, .fd = fd },
            .{ .node = target, .fd = target_fd },
        );
        try port.self_node.backend.provideAnswer(fd, answer);
    }

    fn sendCandidate(ctx: *anyopaque, fd: i32, ice: []const u8) anyerror!void {
        const port: *Port = @ptrCast(@alignCast(ctx));
        const other = port.hub.peerOf(port.self_node, fd) orelse return;
        try other.node.backend.provideRemoteCandidate(other.fd, ice);
    }
};

fn designatorOf(seed: [32]u8) [crypto.PeerKey.designator_len]u8 {
    return crypto.SecretKey.fromSeed(seed).publicKey().toDesignator();
}

fn initLoop(
    allocator: std.mem.Allocator,
    resident: *webrtc.Resident,
    port: *Port,
    bridge: *WebrtcBridge,
    serve: net.completion.Serve,
) !WebrtcLoop {
    const read_buffer_bytes: u32 = @intCast(@min(frame_cap, 16 * 1024));
    const backend = try webrtc.Backend.initBound(allocator, resident, port.authority(), 256, read_buffer_bytes);
    // This driver interposes its own `serve` (it watches the redeem settle),
    // so it overrides the bridge's spliced hook after `hookOptions`.
    var options = WebrtcBridge.hookOptions(.{
        .frame_cap = frame_cap,
        .max_conns = 8,
        .listen = 0,
    });
    options.serve = serve;
    return WebrtcLoop.initWithBackend(allocator, backend, WebrtcBridge.makePeer, @ptrCast(bridge), options);
}

// ── Exporter E ───────────────────────────────────────────────────────────────

const ExporterState = struct {
    host: *Host,
    bridge: *WebrtcBridge,
    g_conn: ?*HostSession = null,
};

const publishExporterTarget = harness.publisher("target", Widget);

fn exporterOnOpen(ctx: ?*anyopaque, bridge: *WebrtcBridge, conn: *WebrtcBridge.Slot) anyerror!void {
    const state: *ExporterState = @ptrCast(@alignCast(ctx.?));
    if (conn.leg != .app_dial or conn.session.role != .dialed) return;
    if (state.g_conn != null) return;
    state.g_conn = conn.session;
    _ = try conn.session.served.publish(&conn.session.host.vat, "target", Widget, .{});
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
            _ = state.host.send(conn, value.reference, .{ .verb = "ready", .args = &.{} }) catch |err| {
                std.debug.print("exporter ready send: {s}\n", .{@errorName(err)});
                return;
            };
            state.bridge.drainActions() catch {};
        },
        .broken => |reason| std.debug.print("exporter desk fetch broke: {s}\n", .{reason}),
        .give => {},
    }
}

fn exporterServe(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
    try WebrtcBridge.serve(conn_ctx, peer, event);
}

fn exporterTask(allocator: std.mem.Allocator, hub: *Hub, shared: *RedeemShared, gifter_designator: []const u8) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try webrtc.Resident.init();
    defer resident.deinit();
    var node = Node{
        .designator = designatorOf(exporter_seed),
        .key = crypto.SecretKey.fromSeed(exporter_seed).publicKey(),
        .resident = &resident,
        .backend = undefined,
    };
    var port = Port{ .hub = hub, .self_node = &node };

    var host = Host.init(allocator, exporter_seed, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer host.deinit();
    var state = ExporterState{ .host = &host, .bridge = undefined };
    var loop: WebrtcLoop = undefined;
    var bridge = WebrtcBridge.init(allocator, &host, io, &loop, .{
        .publish = publishExporterTarget,
        .on_open = exporterOnOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();
    state.bridge = &bridge;

    loop = try initLoop(allocator, &resident, &port, &bridge, exporterServe);
    defer loop.deinit();
    node.backend = &loop.backend;
    hub.register(&node);
    try bridge.attach(webrtc.transport_name, node.designator[0..], &.{});

    // Dial G on the loop-owner thread before `run` (same affinity as dialOutbound).
    try bridge.dialOutbound(webrtc.transport_name, gifter_designator, "");

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoop, .{ &loop, &shared.done, &loop_err });
    defer {
        loop_future.await(io);
        if (loop_err) |err| std.debug.print("exporter loop: {s}\n", .{@errorName(err)});
    }

    try waitFlag(io, &shared.done);
}

// ── Gifter G ─────────────────────────────────────────────────────────────────

const GifterState = struct {
    host: *Host,
    bridge: *WebrtcBridge,
    shared: *RedeemShared,
    recipient_designator: []const u8,
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

fn publishGifterDesk(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
    const state: *GifterState = @ptrCast(@alignCast(ctx.?));
    _ = try served.publish(vat, "desk", RedeemDesk, .{ .state = state });
}

fn gifterMaybeDialRecipient(state: *GifterState) void {
    if (state.dialed_r or state.widget == null) return;
    state.dialed_r = true;
    state.bridge.dialOutbound(webrtc.transport_name, state.recipient_designator, "") catch |err| {
        std.debug.print("gifter dial R: {s}\n", .{@errorName(err)});
        state.dialed_r = false;
    };
}

fn gifterServe(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
    try WebrtcBridge.serve(conn_ctx, peer, event);
    const shell: *WebrtcBridge.Slot = @ptrCast(@alignCast(conn_ctx.?));
    const state: *GifterState = @ptrCast(@alignCast(shell.bridge.publish_ctx.?));

    if (state.want_fetch and state.widget == null and state.from_e == null and shell.session.role == .accepted) {
        state.from_e = shell.session;
        const vow = try state.host.fetch(shell.session, "target");
        try state.host.vowOn(vow, .{ .ctx = state, .func = onWidget });
        try shell.bridge.drainActions();
    }

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

fn gifterOnOpen(ctx: ?*anyopaque, bridge: *WebrtcBridge, conn: *WebrtcBridge.Slot) anyerror!void {
    const state: *GifterState = @ptrCast(@alignCast(ctx.?));
    if (conn.session.role != .dialed or conn.leg != .app_dial) return;
    if (state.r_conn != null) return;
    const widget = state.widget orelse return;
    state.r_conn = conn.session;
    _ = try conn.session.served.publish(&conn.session.host.vat, "desk", Introducer, .{ .widget = widget });
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
            _ = state.host.send(conn, value.reference, .{ .verb = "ready", .args = &.{} }) catch |err| {
                std.debug.print("gifter ready send: {s}\n", .{@errorName(err)});
                return;
            };
            state.bridge.drainActions() catch {};
        },
        .broken => |reason| std.debug.print("gifter inbox fetch broke: {s}\n", .{reason}),
        .give => {},
    }
}

fn gifterTask(allocator: std.mem.Allocator, hub: *Hub, shared: *RedeemShared, recipient_designator: []const u8) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try webrtc.Resident.init();
    defer resident.deinit();
    var node = Node{
        .designator = designatorOf(gifter_seed),
        .key = crypto.SecretKey.fromSeed(gifter_seed).publicKey(),
        .resident = &resident,
        .backend = undefined,
    };
    var port = Port{ .hub = hub, .self_node = &node };

    var host = Host.init(allocator, gifter_seed, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer host.deinit();
    var state = GifterState{
        .host = &host,
        .bridge = undefined,
        .shared = shared,
        .recipient_designator = recipient_designator,
    };
    var loop: WebrtcLoop = undefined;
    var bridge = WebrtcBridge.init(allocator, &host, io, &loop, .{
        .publish = publishGifterDesk,
        .publish_ctx = &state,
        .on_open = gifterOnOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();
    state.bridge = &bridge;

    loop = try initLoop(allocator, &resident, &port, &bridge, gifterServe);
    defer loop.deinit();
    node.backend = &loop.backend;
    hub.register(&node);
    try bridge.attach(webrtc.transport_name, node.designator[0..], &.{});

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoop, .{ &loop, &shared.done, &loop_err });
    defer {
        loop_future.await(io);
        if (loop_err) |err| std.debug.print("gifter loop: {s}\n", .{@errorName(err)});
    }

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

fn publishReadyInbox(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
    const state: *RecipientState = @ptrCast(@alignCast(ctx.?));
    _ = try served.publish(vat, "inbox", ReadyInbox, .{ .state = state });
}

fn recipientServe(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
    try WebrtcBridge.serve(conn_ctx, peer, event);
    const shell: *WebrtcBridge.Slot = @ptrCast(@alignCast(conn_ctx.?));
    const state: *RecipientState = @ptrCast(@alignCast(shell.bridge.publish_ctx.?));
    if (state.want_intro and !state.intro_sent and shell.leg == .accept) {
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
    var hub = Hub.init(allocator);
    defer hub.deinit();

    const gifter_designator = designatorOf(gifter_seed);
    const recipient_designator = designatorOf(recipient_seed);

    // R's loop starts first so G's dial-to-R cannot race a hub with no R row.
    var recipient_resident = try webrtc.Resident.init();
    defer recipient_resident.deinit();
    var recipient_node = Node{
        .designator = recipient_designator,
        .key = crypto.SecretKey.fromSeed(recipient_seed).publicKey(),
        .resident = &recipient_resident,
        .backend = undefined,
    };
    var recipient_port = Port{ .hub = &hub, .self_node = &recipient_node };

    var recipient_host = Host.init(allocator, recipient_seed, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer recipient_host.deinit();
    var state = RecipientState{ .host = &recipient_host, .shared = &shared };
    var loop: WebrtcLoop = undefined;
    var bridge = WebrtcBridge.init(allocator, &recipient_host, io, &loop, .{
        .publish = publishReadyInbox,
        .publish_ctx = &state,
    });
    defer bridge.deinit();

    loop = try initLoop(allocator, &recipient_resident, &recipient_port, &bridge, recipientServe);
    defer loop.deinit();
    recipient_node.backend = &loop.backend;
    hub.register(&recipient_node);
    try bridge.attach(webrtc.transport_name, recipient_designator[0..], &.{});

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoop, .{ &loop, &shared.done, &loop_err });
    var gifter_future = try io.concurrent(gifterTask, .{ allocator, &hub, &shared, recipient_designator[0..] });
    var exporter_future = try io.concurrent(exporterTask, .{ allocator, &hub, &shared, gifter_designator[0..] });

    defer {
        shared.done.store(true, .release);
        exporter_future.await(io) catch |err| std.debug.print("exporter: {s}\n", .{@errorName(err)});
        gifter_future.await(io) catch |err| std.debug.print("gifter: {s}\n", .{@errorName(err)});
        loop_future.await(io);
        if (loop_err) |err| std.debug.print("recipient loop: {s}\n", .{@errorName(err)});
    }
    try waitFlag(io, &shared.poked);

    std.debug.print(
        "webrtc-bridge-redeem: OK, recipient on one loop thread redeemed a bare webrtc give via Loop.dialLocator over a real DataChannel\n",
        .{},
    );
}
