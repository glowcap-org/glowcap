//! Live WebRTC scale: many concurrent DataChannels served from one loop thread
//! (ADR-0089's generic Host adoption over the completion tier).
//!
//! One server thread runs `completion.Loop(webrtc.Backend, webrtc.DialResolver)`
//! under `driver.Bridge` + `driver_core.Host`, publishing a greeter. N client
//! threads each bring a DataChannel up as the offerer and drive a packet-fed
//! Host session over WebRTC, calling the greeter and checking every reply —
//! so the one loop thread is provably multiplexing N channels through the
//! backend's readiness fd, not serving them serially.
//!
//! Signaling is an in-process hub, the same stand-in `webrtc-mesh` uses for the
//! room-carried capability the rooms app ships in TypeScript: the hub answers
//! each client offer by creating the answerer peer on the server's resident,
//! authorizing the client's identity, and handing the peer to
//! `Backend.adoptAnswerer` — the backend's one inbound entry, since WebRTC has
//! no accept substrate. Candidates trickle both ways through the backend's
//! thread-safe `provideRemoteCandidate` and the authority's `sendCandidate`.
//!
//! Not part of the hermetic `zig build check` run set as a *runnable* (it links
//! the Rust sidecar, needs cargo); the compile-only sibling rides `check`.
//! Run: `zig build webrtc-loop`.

const std = @import("std");
const pancake = @import("pancake");
const webrtc = @import("webrtc");
const webrtc_common = @import("webrtc_common");
const harness = @import("interop_harness");

const crypto = pancake.foundation.crypto;
const model = pancake.ocapn.model;
const actors = pancake.actors;
const net = pancake.net;
const driver = pancake.driver;

const frame_cap: usize = 64 * 1024;
const num_conns: usize = 4;
const calls_per_conn: usize = 4;
const greeting = "hello from the webrtc loop host";
const bring_up_timeout_ms: usize = 20_000;

const WebrtcLoop = net.completion.Loop(webrtc.Backend, webrtc.DialResolver);
const WebrtcBridge = driver.Bridge(WebrtcLoop);
const runLoop = harness.LoopRunner(WebrtcLoop).runUntilFlag;

const Greeter = harness.StaticReplyActor("greet", greeting);
const publishGreeter = harness.publisher("greeter", Greeter);
const CapturedRef = webrtc_common.CapturedRef;
const CapturedString = webrtc_common.CapturedString;

/// The in-process signaling hub: the stand-in for the room-carried signaling
/// capability. It owns the fd-to-client routing for the server's outbound
/// candidates, and its `offer` is what a client's signaling send becomes.
const Hub = struct {
    mutex: pancake.net.sync.SpinLock = .{},
    allocator: std.mem.Allocator,
    io: std.Io,
    backend: *webrtc.Backend,
    server_resident: *webrtc.Resident,
    clients: std.AutoHashMap(i32, *ClientRoute),

    const ClientRoute = struct {
        mutex: std.Io.Mutex = .init,
        drained: std.Io.Condition = .init,
        peer: *webrtc.Peer,
        in_flight: usize = 0,
        closing: bool = false,
        refs: usize = 1,
        retired: bool = false,

        fn send(self: *ClientRoute, io: std.Io, ice: []const u8) !void {
            self.mutex.lockUncancelable(io);
            if (self.closing) {
                self.mutex.unlock(io);
                return;
            }
            self.in_flight += 1;
            const peer = self.peer;
            self.mutex.unlock(io);

            defer {
                self.mutex.lockUncancelable(io);
                self.in_flight -= 1;
                if (self.closing and self.in_flight == 0) self.drained.signal(io);
                self.mutex.unlock(io);
            }
            try peer.addRemoteCandidate(ice);
        }

        fn close(self: *ClientRoute, io: std.Io) void {
            self.mutex.lockUncancelable(io);
            self.closing = true;
            while (self.in_flight != 0) self.drained.waitUncancelable(io, &self.mutex);
            self.mutex.unlock(io);
        }
    };

    fn init(allocator: std.mem.Allocator, io: std.Io, backend: *webrtc.Backend, server_resident: *webrtc.Resident) Hub {
        return .{
            .allocator = allocator,
            .io = io,
            .backend = backend,
            .server_resident = server_resident,
            .clients = std.AutoHashMap(i32, *ClientRoute).init(allocator),
        };
    }

    fn deinit(self: *Hub) void {
        var it = self.clients.valueIterator();
        while (it.next()) |route| self.allocator.destroy(route.*);
        self.clients.deinit();
    }

    fn retainRoute(self: *Hub, fd: i32) ?*ClientRoute {
        self.mutex.lock();
        defer self.mutex.unlock();
        const route = self.clients.get(fd) orelse return null;
        route.refs += 1;
        return route;
    }

    fn releaseRoute(self: *Hub, route: *ClientRoute) void {
        const destroy = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            route.refs -= 1;
            break :blk route.retired and route.refs == 0;
        };
        if (destroy) self.allocator.destroy(route);
    }

    /// The backend never dials in this scenario; a dial reaching the authority
    /// is a harness defect, not a fallback.
    fn sendOffer(ctx: *anyopaque, fd: i32, designator: []const u8, sdp: []const u8) anyerror!void {
        _ = ctx;
        _ = fd;
        _ = designator;
        _ = sdp;
        return error.NoOutboundSignaling;
    }

    /// Route one server-side candidate to the client whose exchange `fd` names.
    fn sendCandidate(ctx: *anyopaque, fd: i32, ice: []const u8) anyerror!void {
        const hub: *Hub = @ptrCast(@alignCast(ctx));
        const route = hub.retainRoute(fd) orelse return;
        defer hub.releaseRoute(route);
        try route.send(hub.io, ice);
    }

    fn authority(self: *Hub) webrtc.SignalingAuthority {
        return .{ .ctx = self, .sendOffer = sendOffer, .sendCandidate = sendCandidate };
    }

    const OfferResult = struct { fd: i32, answer: []const u8 };

    /// Answer a client's offer: create the server-side answerer, authorize the
    /// client identity the exchange is scoped to, adopt it into the backend,
    /// and file the client for return candidates. Runs on the client's thread;
    /// `adoptAnswerer` is the backend's thread-safe entry.
    fn offer(
        self: *Hub,
        client_peer: *webrtc.Peer,
        client_key: crypto.PeerKey,
        offer_sdp: []const u8,
        answer_buf: []u8,
    ) !OfferResult {
        var answerer = try self.server_resident.newPeer(false);
        errdefer answerer.deinit();
        try answerer.setRemoteOffer(offer_sdp);
        var answer_len: usize = 0;
        const answer = try answerer.createAnswer(answer_buf, &answer_len);
        answerer.authorizeRemote(client_key);
        const fd = try self.backend.adoptAnswerer(answerer);
        const route = try self.allocator.create(ClientRoute);
        route.* = .{ .peer = client_peer };
        errdefer self.allocator.destroy(route);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.clients.put(fd, route);
        return .{ .fd = fd, .answer = answer };
    }

    /// Drop the return-candidate route once the client's channel is up (or its
    /// bring-up failed); the client peer's storage dies with its thread.
    fn forget(self: *Hub, fd: i32) void {
        const route = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const kv = self.clients.fetchRemove(fd) orelse return;
            kv.value.retired = true;
            break :blk kv.value;
        };
        route.close(self.io);
        self.releaseRoute(route);
    }
};

/// One client: own resident, offerer peer, hub-signaled bring-up, then a keyed
/// OCapN session over the open channel — fetch the greeter and call it
/// `calls_per_conn` times.
fn clientOnce(
    io: std.Io,
    allocator: std.mem.Allocator,
    hub: *Hub,
    server_designator: []const u8,
) anyerror!void {
    var resident = try webrtc.Resident.init(.{ .include_loopback_candidates = true });
    defer resident.deinit() catch |err| std.log.err("WebRTC teardown failed: {s}", .{@errorName(err)});
    var peer = try resident.newPeer(true);
    defer peer.deinit();

    var seed: [32]u8 = undefined;
    try io.randomSecure(&seed);
    const secret = crypto.SecretKey.fromSeed(seed);

    var sdp_buf: [webrtc_common.signaling_frame_bytes]u8 = undefined;
    var sdp_len: usize = 0;
    const offer_sdp = try peer.createOffer(&sdp_buf, &sdp_len);
    var signal_buf: [webrtc_common.signaling_frame_bytes]u8 = undefined;
    const answered = try hub.offer(&peer, secret.publicKey(), offer_sdp, &signal_buf);
    defer hub.forget(answered.fd);
    try peer.setRemoteAnswer(answered.answer);

    // Trickle our candidates into the backend and wait for the channel: the
    // far side's candidates arrive through the hub's `sendCandidate` route.
    var cand_len: usize = 0;
    var elapsed: usize = 0;
    while (true) {
        while (try peer.nextLocalCandidate(&signal_buf, &cand_len)) |ice| {
            try hub.backend.provideRemoteCandidate(answered.fd, ice);
        }
        if (try webrtc_common.pollOpen(&resident, &peer, 50)) break;
        elapsed += 50;
        if (elapsed >= bring_up_timeout_ms) return error.ChannelBringUpTimeout;
    }

    var session_root: [32]u8 = undefined;
    try io.randomSecure(&session_root);
    var client_host = try driver.core.Host.init(allocator, seed, session_root, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = driver.core.default_loop_local_turn_budget,
    });
    defer client_host.deinit();

    const client_designator = secret.publicKey().toDesignator();
    try client_host.setAdvertisedLocator(.{
        .transport = webrtc.transport_name,
        .designator = client_designator[0..],
        .hints = model.Hints.emptyFalse(),
    });
    const dialed = try client_host.openDialedLocator(.{
        .transport = webrtc.transport_name,
        .designator = server_designator,
        .hints = model.Hints.emptyFalse(),
    });
    defer client_host.releaseSession(dialed) catch |err|
        std.debug.panic("client session cleanup failed: {s}", .{@errorName(err)});

    const read_buf = try allocator.alloc(u8, webrtc.max_packet_bytes);
    defer allocator.free(read_buf);
    var packet_pump = webrtc_common.PacketPump{ .read_buf = read_buf };
    defer packet_pump.deinit();

    try webrtc_common.waitFor(&resident, &peer, &packet_pump, &client_host, dialed, dialed, webrtc_common.sessionOpenDone, bring_up_timeout_ms);

    var fetched = CapturedRef{};
    const fetch_vow = try client_host.fetch(dialed, "greeter");
    try client_host.vowOn(fetch_vow, .{ .ctx = &fetched, .func = CapturedRef.record });
    try webrtc_common.waitFor(&resident, &peer, &packet_pump, &client_host, dialed, &fetched, webrtc_common.refDone, bring_up_timeout_ms);
    const greeter = try fetched.require();

    var i: usize = 0;
    while (i < calls_per_conn) : (i += 1) {
        var reply = CapturedString{};
        const vow = try client_host.send(dialed, greeter, .{ .verb = "greet", .args = &.{.{ .string = "world" }} });
        try client_host.vowOn(vow, .{ .ctx = &reply, .func = CapturedString.record });
        try webrtc_common.waitFor(&resident, &peer, &packet_pump, &client_host, dialed, &reply, webrtc_common.stringDone, bring_up_timeout_ms);
        if (!std.mem.eql(u8, try reply.require(), greeting)) return error.WrongReply;
    }
    _ = try packet_pump.drive(&client_host, dialed, &peer);
    peer.close();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Seed the Host with the identity every client pins: webrtc is a
    // key-designator transport, and the signaling exchange is scoped to it.
    const server_seed: [32]u8 = @splat(0x53);
    const server_designator_buf = crypto.SecretKey.fromSeed(server_seed).publicKey().toDesignator();
    const server_designator = server_designator_buf[0..];

    var server_resident = try webrtc.Resident.init(.{ .include_loopback_candidates = true });
    defer server_resident.deinit() catch |err| std.log.err("WebRTC teardown failed: {s}", .{@errorName(err)});

    var session_root: [32]u8 = undefined;
    io.randomSecure(&session_root) catch return error.HandshakeEntropyFailed;
    var host = try driver.core.Host.init(allocator, server_seed, session_root, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = driver.core.default_loop_local_turn_budget,
    });
    defer host.deinit();
    var loop: WebrtcLoop = undefined;
    var bridge = WebrtcBridge.init(allocator, &host, io, &loop, .{ .publish = publishGreeter });
    defer bridge.deinit();

    // The hub's backend pointer targets the loop's own copy: `initWithBackend`
    // moves the backend in by value, so the address is stable only there.
    var hub = Hub.init(allocator, io, undefined, &server_resident);
    defer hub.deinit();

    const read_buffer_bytes: u32 = @intCast(@min(frame_cap, 16 * 1024));
    const backend = try webrtc.Backend.initBound(allocator, &server_resident, hub.authority(), 256, read_buffer_bytes);
    loop = try WebrtcLoop.initWithBackend(allocator, backend, WebrtcBridge.makePeer, @ptrCast(&bridge), WebrtcBridge.hookOptions(.{
        .max_conns = 64,
        .listen = 0,
    }));
    defer loop.deinit();
    hub.backend = &loop.backend;
    try bridge.attach(model.transport.Known.webrtc.metadata(), server_designator, &.{});

    var loop_err: ?anyerror = null;
    var done = std.atomic.Value(bool).init(false);
    var loop_future = try io.concurrent(runLoop, .{ &loop, &done, &loop_err });

    var futures: [num_conns]@TypeOf(io.concurrent(clientOnce, .{ io, allocator, &hub, server_designator }) catch unreachable) = undefined;
    var started: usize = 0;
    while (started < num_conns) : (started += 1) {
        futures[started] = try io.concurrent(clientOnce, .{ io, allocator, &hub, server_designator });
    }

    var first_err: ?anyerror = null;
    for (futures[0..started]) |*f| {
        if (f.await(io)) |_| {} else |err| {
            if (first_err == null) first_err = err;
            std.debug.print("webrtc-loop: a client failed: {s}\n", .{@errorName(err)});
        }
    }

    done.store(true, .release);
    try loop.backend.wake();
    loop_future.await(io);
    if (loop_err) |err| return err;
    if (first_err) |err| return err;

    std.debug.print(
        "webrtc-loop: OK, {d} concurrent DataChannels, {d} calls each, served from one loop thread over Backend + Bridge + Host\n",
        .{ num_conns, calls_per_conn },
    );
}
