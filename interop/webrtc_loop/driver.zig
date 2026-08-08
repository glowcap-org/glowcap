//! Live WebRTC scale: many concurrent DataChannels served from one loop thread
//! (ADR-0089's generic Host adoption over the completion tier).
//!
//! One server thread runs `completion.Loop(webrtc.Backend, webrtc.DialResolver)`
//! under `driver.Bridge` + `driver_core.Host`, publishing a greeter. N client
//! threads each bring a DataChannel up as the offerer and hold a keyed OCapN
//! session over it, calling the greeter and checking every reply — so the one
//! loop thread is provably multiplexing N channels through the backend's
//! readiness fd, not serving them serially.
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
const engine = pancake.ocapn.engine;
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
const runLoop = harness.LoopRunner(WebrtcLoop).runAfterClosed;

const Greeter = harness.StaticReplyActor("greet", greeting);
const publishGreeter = harness.publisher("greeter", Greeter);

/// The in-process signaling hub: the stand-in for the room-carried signaling
/// capability. It owns the fd-to-client routing for the server's outbound
/// candidates, and its `offer` is what a client's signaling send becomes.
const Hub = struct {
    mutex: pancake.net.sync.SpinLock = .{},
    allocator: std.mem.Allocator,
    backend: *webrtc.Backend,
    server_resident: *webrtc.Resident,
    clients: std.AutoHashMap(i32, *webrtc.Peer),

    fn init(allocator: std.mem.Allocator, backend: *webrtc.Backend, server_resident: *webrtc.Resident) Hub {
        return .{
            .allocator = allocator,
            .backend = backend,
            .server_resident = server_resident,
            .clients = std.AutoHashMap(i32, *webrtc.Peer).init(allocator),
        };
    }

    fn deinit(self: *Hub) void {
        self.clients.deinit();
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
        hub.mutex.lock();
        defer hub.mutex.unlock();
        const client = hub.clients.get(fd) orelse return;
        try client.addRemoteCandidate(ice);
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
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.clients.put(fd, client_peer);
        return .{ .fd = fd, .answer = answer };
    }

    /// Drop the return-candidate route once the client's channel is up (or its
    /// bring-up failed); the client peer's storage dies with its thread.
    fn forget(self: *Hub, fd: i32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.clients.remove(fd); // tolerant: a failed offer never filed one
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
    defer resident.deinit();
    var peer = try resident.newPeer(true);
    defer peer.deinit();

    var seed: [32]u8 = undefined;
    try io.randomSecure(&seed);
    const secret = crypto.SecretKey.fromSeed(seed);

    var sdp_buf: [webrtc_common.sig_frame_cap]u8 = undefined;
    var sdp_len: usize = 0;
    const offer_sdp = try peer.createOffer(&sdp_buf, &sdp_len);
    var answer_buf: [webrtc_common.sig_frame_cap]u8 = undefined;
    const answered = try hub.offer(&peer, secret.publicKey(), offer_sdp, &answer_buf);
    defer hub.forget(answered.fd);
    try peer.setRemoteAnswer(answered.answer);

    // Trickle our candidates into the backend and wait for the channel: the
    // far side's candidates arrive through the hub's `sendCandidate` route.
    var cand_buf: [4 * 1024]u8 = undefined;
    var cand_len: usize = 0;
    var elapsed: usize = 0;
    while (true) {
        while (try peer.nextLocalCandidate(&cand_buf, &cand_len)) |ice| {
            try hub.backend.provideRemoteCandidate(answered.fd, ice);
        }
        if (try webrtc_common.pollOpen(&resident, &peer, 50)) break;
        elapsed += 50;
        if (elapsed >= bring_up_timeout_ms) return error.ChannelBringUpTimeout;
    }

    var engine_peer = engine.Peer.initNegotiating(allocator);
    defer engine_peer.deinit();
    engine_peer.session_state.limits.max_frame_bytes = frame_cap;
    // Demand the server's durable identity. The signaling exchange was aimed
    // at it and the DataChannel's DTLS binding under that exchange is what
    // proves it, which the resident asserts for itself (ADR-0105).
    engine_peer.demandPartnerDurableKey(
        crypto.PeerKey.fromDesignator(server_designator) orelse return error.InvalidDesignator,
    );

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);
    const conn = try peer.connection(io, &engine_peer, .{ .read = read_buf, .write = write_buf });
    var vat = driver.BlockingSession.over(allocator, &engine_peer, conn);
    defer vat.deinit();

    const designator = secret.publicKey().toDesignator();
    const self_locator: model.PeerLocator = .{
        .transport = webrtc.transport_name,
        .designator = designator[0..],
        .hints = model.Hints.emptyFalse(),
    };
    try vat.startKeyedSessionWithSecret(self_locator, secret);

    const greeter = try vat.fetch("greeter");
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var i: usize = 0;
    while (i < calls_per_conn) : (i += 1) {
        _ = arena_state.reset(.retain_capacity);
        const settled = try vat.call(greeter, .{ .verb = "greet", .args = &.{.{ .string = "world" }} }, arena_state.allocator());
        switch (settled) {
            .fulfilled => |arg| {
                if (arg != .string or !std.mem.eql(u8, arg.string, greeting)) return error.WrongReply;
            },
            .broken, .give => return error.CallBroke,
        }
    }
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
    defer server_resident.deinit();

    var host = driver.core.Host.init(allocator, server_seed, .{
        .limits = .{ .max_frame_bytes = frame_cap },
        .local_turn_budget = actors.Vat.max_batch_local_turns,
    });
    defer host.deinit();
    var loop: WebrtcLoop = undefined;
    var bridge = WebrtcBridge.init(allocator, &host, io, &loop, .{ .publish = publishGreeter });
    defer bridge.deinit();

    // The hub's backend pointer targets the loop's own copy: `initWithBackend`
    // moves the backend in by value, so the address is stable only there.
    var hub = Hub.init(allocator, undefined, &server_resident);
    defer hub.deinit();

    const read_buffer_bytes: u32 = @intCast(@min(frame_cap, 16 * 1024));
    const backend = try webrtc.Backend.initBound(allocator, &server_resident, hub.authority(), 256, read_buffer_bytes);
    loop = try WebrtcLoop.initWithBackend(allocator, backend, WebrtcBridge.makePeer, @ptrCast(&bridge), WebrtcBridge.hookOptions(.{
        .frame_cap = frame_cap,
        .max_conns = 64,
        .listen = 0,
    }));
    defer loop.deinit();
    hub.backend = &loop.backend;
    try bridge.attach(webrtc.transport_name, server_designator, &.{});

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoop, .{ &loop, num_conns, &loop_err });

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

    loop_future.await(io);
    if (loop_err) |err| return err;
    if (first_err) |err| return err;

    std.debug.print(
        "webrtc-loop: OK, {d} concurrent DataChannels, {d} calls each, served from one loop thread over Backend + Bridge + Host\n",
        .{ num_conns, calls_per_conn },
    );
}
