//! Three-party redeem over WebRTC: a recipient's runtime dials the exporter's
//! bare webrtc designator through its configured signaling authority, inside
//! the call that receives the introduction (ADR-0035). The Zig mirror of
//! the rooms app's `rooms-web-dm-webrtc` proof.
//!
//!   E (exporter)   `driver.Server`, publishes the widget
//!   G (gifter)     `driver.Server`, fetches E's widget and introduces it
//!   R (recipient)  `driver.Server`, redeems by dialing E's bare designator
//!
//! Every party runs a WebRTC completion resident. Every leg is a DataChannel,
//! and all signaling rides one in-process hub: the stand-in for the
//! room-carried signaling capability. R is a Server rather than a plain
//! Session because each exchange is scoped to the offerer's durable key.
//!
//! Not part of the hermetic `zig build check` as a runnable (it links the Rust
//! sidecar). The compile-only sibling rides `check`. Run:
//! `zig build webrtc-redeem`.

const std = @import("std");
const glowcap = @import("glowcap");
const webrtc = @import("webrtc");
const harness = @import("interop_harness");

const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const net = glowcap.net;
const driver = glowcap.driver;

const frame_cap: usize = 4096;
const deadline_ms: u64 = 30_000;
const poked = "poked directly at the exporter";

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 30_000 },
    .settle = .{ .ms = 30_000 },
};

const exporter_seed: [32]u8 = @splat(0x2e);
const gifter_seed: [32]u8 = @splat(0x26);
const recipient_seed: [32]u8 = @splat(0x2c);

const WebrtcResident = net.completion_resident.Resident(webrtc.Backend, webrtc.ResidentPolicy);

const Widget = harness.StaticReplyBehavior("poke", poked);

const Introducer = struct {
    widget: driver.Capability,

    pub fn handle(self: *Introducer, ht: *driver.HostTurn, selector: ?[]const u8, args: driver.Args) !driver.Value {
        defer ht.releaseArguments(args);
        const verb = selector orelse return error.NoSuchMethod;
        if (!std.mem.eql(u8, verb, "introduce")) return error.NoSuchMethod;
        return .{ .capability = self.widget };
    }
};

// ── The in-process signaling hub ─────────────────────────────────────────────
//
// It hands each offer to the target node's backend, which builds the
// answerer and sends the answer back through its own authority. The hub pairs
// the two exchange fds there and ferries answers and candidates between the
// paired backends through their thread-safe entries. Entries run on whichever
// node's runtime thread is dialing; the hub's own tables take a SpinLock.

/// One party: its WebRTC sidecar, its completion resident, and its key.
const Node = struct {
    designator: [crypto.PeerKey.designator_len]u8,
    key: crypto.PeerKey,
    sidecar: webrtc.Resident,
    resident: WebrtcResident,
    port: Port,

    fn init(self: *Node, allocator: std.mem.Allocator, hub: *Hub, seed: [32]u8) !void {
        const key = crypto.SecretKey.fromSeed(seed).publicKey();
        self.designator = key.toDesignator();
        self.key = key;
        self.port = .{ .hub = hub, .self_node = self };
        self.sidecar = try webrtc.Resident.init(.{ .include_loopback_candidates = true });
        // best-effort: this unwind returns the backend's init error, and a failed sidecar close would only mask it.
        errdefer self.sidecar.deinit() catch {};
        const read_buffer_bytes: u32 = @intCast(@min(frame_cap, 16 * 1024));
        self.resident = try WebrtcResident.init(
            allocator,
            try webrtc.Backend.initBound(allocator, &self.sidecar, self.port.authority(), 256, read_buffer_bytes),
            .{},
        );
        hub.register(self);
    }

    fn deinit(self: *Node) void {
        self.resident.closeAndDrain(5_000) catch |err| std.log.err("WebRTC resident drain failed: {s}", .{@errorName(err)});
        self.resident.deinit();
        self.sidecar.deinit() catch |err| std.log.err("WebRTC teardown failed: {s}", .{@errorName(err)});
    }

    fn backend(self: *Node) *webrtc.Backend {
        return &self.resident.backend;
    }

    fn locator(self: *const Node) model.PeerLocator {
        return .{ .transport = webrtc.transport_name, .designator = self.designator[0..], .hints = model.Hints.emptyFalse() };
    }

    /// A Server keyed with this node's seed, listening on its signaling inbox.
    fn listen(self: *Node, io: std.Io, allocator: std.mem.Allocator, seed: [32]u8, providers: *[1]driver.HostRuntime.ProviderRegistration) !*driver.Server {
        providers.* = .{.{ .profile = model.transport.Known.webrtc.metadata(), .resident = self.resident.resident() }};
        return driver.listen(allocator, io, .{ .residents = providers }, model.transport.webrtc, .{ .designator = "" }, .{
            .keyed = crypto.SecretKey.fromSeed(seed),
        }, opts);
    }
};

const PairEnd = struct { node: *Node, fd: i32 };

const Hub = struct {
    mutex: glowcap.net.sync.SpinLock = .{},
    nodes: [3]?*Node = .{ null, null, null },
    pairs: std.AutoHashMap(u64, PairEnd),
    /// The exchange each offering node waits on an answer for. One dial is in
    /// flight per node at a time in this scenario.
    offers: std.AutoHashMap(*Node, i32),

    fn init(allocator: std.mem.Allocator) Hub {
        return .{
            .pairs = std.AutoHashMap(u64, PairEnd).init(allocator),
            .offers = std.AutoHashMap(*Node, i32).init(allocator),
        };
    }

    fn deinit(self: *Hub) void {
        self.pairs.deinit();
        self.offers.deinit();
    }

    fn expectAnswer(self: *Hub, offerer: PairEnd) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.offers.contains(offerer.node)) return error.OfferInFlight;
        try self.offers.put(offerer.node, offerer.fd);
    }

    fn takeExpectedAnswer(self: *Hub, offerer: *Node) ?PairEnd {
        self.mutex.lock();
        defer self.mutex.unlock();
        const kv = self.offers.fetchRemove(offerer) orelse return null;
        return .{ .node = offerer, .fd = kv.value };
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
        return .{ .ctx = self, .sendOffer = sendOffer, .sendAnswer = sendAnswer, .sendCandidate = sendCandidate };
    }

    /// Carry the offer to the target, whose backend answers it under this
    /// node's designator: the whole exchange the room carries in the rooms
    /// app, inlined. The target's `sendAnswer` fires inside `startAnswer`, so
    /// the offering exchange is filed first.
    fn sendOffer(ctx: *anyopaque, fd: i32, designator: []const u8, sdp: []const u8) anyerror!void {
        const port: *Port = @ptrCast(@alignCast(ctx));
        const target = port.hub.byDesignator(designator) orelse return error.UnknownPeer;
        try port.hub.expectAnswer(.{ .node = port.self_node, .fd = fd });
        errdefer _ = port.hub.takeExpectedAnswer(port.self_node);
        _ = try target.backend().startAnswer(port.self_node.designator[0..], sdp);
    }

    /// Route the answer this node's backend produced to the offerer the
    /// exchange is scoped to, and pair the two exchange fds for candidates.
    fn sendAnswer(ctx: *anyopaque, fd: i32, designator: []const u8, sdp: []const u8) anyerror!void {
        const port: *Port = @ptrCast(@alignCast(ctx));
        const offerer_node = port.hub.byDesignator(designator) orelse return error.UnknownPeer;
        const offerer = port.hub.takeExpectedAnswer(offerer_node) orelse return error.UnexpectedAnswer;
        try port.hub.pair(offerer, .{ .node = port.self_node, .fd = fd });
        try offerer_node.backend().provideAnswer(offerer.fd, sdp);
    }

    fn sendCandidate(ctx: *anyopaque, fd: i32, ice: []const u8) anyerror!void {
        const port: *Port = @ptrCast(@alignCast(ctx));
        const other = port.hub.peerOf(port.self_node, fd) orelse return;
        try other.node.backend().provideRemoteCandidate(other.fd, ice);
    }
};

/// Accept and serve every session `server` receives until `done`.
fn serveAll(server: *driver.Server, done: *std.atomic.Value(bool)) anyerror!void {
    var sessions: [4]*driver.Session = undefined;
    var accepted: usize = 0;
    defer for (sessions[0..accepted]) |session| session.deinit();
    while (!done.load(.acquire)) {
        if (accepted < sessions.len and try server.waitAcceptable(0)) {
            sessions[accepted] = try server.accept();
            accepted += 1;
            // An accepted session dispatches nothing until its owner attends.
            try sessions[accepted - 1].attend();
            continue;
        }
        _ = try server.runtime.stepAny(10);
    }
}

/// G: fetch E's widget over G's own runtime, publish the introducer, serve.
fn serveGifter(
    gifter: *driver.Server,
    exporter_locator: model.PeerLocator,
    ready: *std.atomic.Value(bool),
    published: *std.atomic.Value(bool),
    done: *std.atomic.Value(bool),
) anyerror!void {
    defer ready.store(true, .release);
    const to_exporter = try gifter.runtime.connectLocator(exporter_locator, .inherit);
    const exporter = try driver.Session.adopt(gifter.runtime, to_exporter);
    defer exporter.deinit();
    const widget = try exporter.fetch("widget");
    try gifter.publish("introducer", Introducer, .{ .widget = widget });
    published.store(true, .release);
    ready.store(true, .release);
    try serveAll(gifter, done);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var hub = Hub.init(allocator);
    defer hub.deinit();
    var exporter_node: Node = undefined;
    try exporter_node.init(allocator, &hub, exporter_seed);
    defer exporter_node.deinit();
    var gifter_node: Node = undefined;
    try gifter_node.init(allocator, &hub, gifter_seed);
    defer gifter_node.deinit();
    var recipient_node: Node = undefined;
    try recipient_node.init(allocator, &hub, recipient_seed);
    defer recipient_node.deinit();

    var exporter_providers: [1]driver.HostRuntime.ProviderRegistration = undefined;
    var exporter = try exporter_node.listen(io, allocator, exporter_seed, &exporter_providers);
    defer exporter.deinit();
    try exporter.publish("widget", Widget, .{});
    var gifter_providers: [1]driver.HostRuntime.ProviderRegistration = undefined;
    var gifter = try gifter_node.listen(io, allocator, gifter_seed, &gifter_providers);
    defer gifter.deinit();
    var recipient_providers: [1]driver.HostRuntime.ProviderRegistration = undefined;
    var recipient = try recipient_node.listen(io, allocator, recipient_seed, &recipient_providers);
    defer recipient.deinit();

    var done = std.atomic.Value(bool).init(false);
    var gifter_ready = std.atomic.Value(bool).init(false);
    var gifter_published = std.atomic.Value(bool).init(false);
    var exporter_future = try io.concurrent(serveAll, .{ exporter, &done });
    var gifter_future = try io.concurrent(serveGifter, .{ gifter, exporter_node.locator(), &gifter_ready, &gifter_published, &done });
    var joined = false;
    defer if (!joined) {
        done.store(true, .release);
        gifter_future.await(io) catch |err| std.debug.print("webrtc-redeem: gifter: {s}\n", .{@errorName(err)});
        exporter_future.await(io) catch |err| std.debug.print("webrtc-redeem: exporter: {s}\n", .{@errorName(err)});
    };
    try harness.untilFlag(io, deadline_ms, &gifter_ready);
    if (!gifter_published.load(.acquire)) return error.GifterSetupFailed;

    // R: dial G, receive the introduction, and poke the widget directly.
    const to_gifter_session = try recipient.runtime.connectLocator(gifter_node.locator(), .inherit);
    const to_gifter = try driver.Session.adopt(recipient.runtime, to_gifter_session);
    defer to_gifter.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const introducer = try to_gifter.fetch("introducer");
    const widget = switch (try to_gifter.call(introducer, "introduce", &.{}, arena.allocator())) {
        .fulfilled => |value| if (value == .capability) value.capability else return error.NoIntroduction,
        .broken => |reason| {
            std.debug.print("webrtc-redeem: introduce broke: {s}\n", .{reason});
            return error.NoIntroduction;
        },
    };
    try expectHomedAt(to_gifter, widget, exporter_node.designator[0..]);
    switch (try to_gifter.call(widget, "poke", &.{}, arena.allocator())) {
        .fulfilled => |value| if (value != .string or !std.mem.eql(u8, value.string, poked)) return error.WrongReply,
        .broken => return error.WrongReply,
    }

    done.store(true, .release);
    joined = true;
    const gifter_result = gifter_future.await(io);
    const exporter_result = exporter_future.await(io);
    try gifter_result;
    try exporter_result;
    std.debug.print("webrtc-redeem: OK, R redeemed a bare webrtc give by dialing E over a signaled DataChannel and poked the widget directly\n", .{});
}

/// The widget lives on R's own session to E, whose key the signaling
/// exchange authorized, not on R's session to G.
fn expectHomedAt(to_gifter: *driver.Session, widget: driver.Capability, exporter_id: []const u8) !void {
    const core = to_gifter.runtime.core;
    const target = core.capabilities.resolve(widget) orelse return error.UnknownCapability;
    const peer_handle = switch (target) {
        .remote => |remote| remote.peer_handle,
        else => return error.MissingExporterRoute,
    };
    const home = core.sessionForPeer(peer_handle) orelse return error.MissingExporterSession;
    if (home == to_gifter.hs) return error.GiftWasProxied;
    const identity = try core.partnerIdentity(home);
    if (!std.mem.eql(u8, identity.designator, exporter_id)) return error.WrongExporter;
    if (identity.provenance != .authenticated_transport) return error.UnprovenExporter;
}
