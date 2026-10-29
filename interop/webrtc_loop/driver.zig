//! Live WebRTC scale: many concurrent DataChannels served from one HostRuntime
//! thread (ADR-0035 over ADR-0018's completion resident).
//!
//! One server thread steps a `driver.HostRuntime` whose WebRTC listener is a
//! `net.completion_resident` over `webrtc.Backend` with `webrtc.ResidentPolicy`,
//! publishing a greeter. N client
//! threads each bring a DataChannel up as the offerer and drive a packet-fed
//! Host session over WebRTC, calling the greeter and checking every reply,
//! so the one runtime thread is provably multiplexing N channels through the
//! backend's readiness descriptor, not serving them serially.
//!
//! Signaling is an in-process hub, the same stand-in `webrtc-mesh` uses for the
//! room-carried capability the rooms app ships in TypeScript: the hub hands
//! each client offer to `Backend.startAnswer` with the client's designator,
//! and the backend builds the answerer, scopes the channel to that identity,
//! and sends the answer back through the authority's `sendAnswer`. Candidates
//! trickle both ways through the backend's thread-safe
//! `provideRemoteCandidate` and the authority's `sendCandidate`. Every
//! accepted session names the client's designator as its authenticated
//! partner.
//!
//! Not part of the hermetic `zig build check` run set as a *runnable* (it links
//! the Rust sidecar, needs cargo). The compile-only sibling rides `check`.
//! Run: `zig build webrtc-loop`.

const std = @import("std");
const glowcap = @import("glowcap");
const webrtc = @import("webrtc");
const webrtc_common = @import("webrtc_common");

const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const net = glowcap.net;
const driver = glowcap.driver;

const frame_cap: usize = 64 * 1024;
const num_conns: usize = 4;
const calls_per_conn: usize = 4;
const greeting = "hello from the webrtc loop host";
const bring_up_timeout_ms: usize = 20_000;

const WebrtcResident = net.completion_resident.Resident(webrtc.Backend, webrtc.ResidentPolicy);

const Greeter = struct {
    pub fn handle(_: *Greeter, ht: *driver.HostTurn, selector: ?[]const u8, args: driver.Args) !driver.Value {
        defer ht.releaseArguments(args);
        const verb = selector orelse return error.NoSuchMethod;
        if (!std.mem.eql(u8, verb, "greet")) return error.NoSuchMethod;
        return .{ .string = greeting };
    }
};
const CapturedRef = webrtc_common.CapturedRef;
const CapturedString = webrtc_common.CapturedString;

const Designator = [crypto.PeerKey.designator_len]u8;

/// The in-process signaling hub: the stand-in for the room-carried signaling
/// capability. It owns the fd-to-client routing for the server's outbound
/// candidates, and its `offer` is what a client's signaling send becomes.
const Hub = struct {
    mutex: glowcap.net.sync.SpinLock = .{},
    allocator: std.mem.Allocator,
    io: std.Io,
    backend: *webrtc.Backend,
    clients: std.AutoHashMap(i32, *ClientRoute),
    /// Clients whose offer is being answered, by designator, until the
    /// backend's `sendAnswer` names their exchange fd.
    pending: std.AutoHashMap(Designator, *ClientRoute),
    /// Answers the backend produced, by exchange fd, until the offering
    /// client collects its own.
    answers: std.AutoHashMap(i32, []u8),
    /// Every designator the backend answered, for the final identity check.
    answered: [num_conns]Designator = undefined,
    answered_count: usize = 0,

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

    fn init(allocator: std.mem.Allocator, io: std.Io, backend: *webrtc.Backend) Hub {
        return .{
            .allocator = allocator,
            .io = io,
            .backend = backend,
            .clients = std.AutoHashMap(i32, *ClientRoute).init(allocator),
            .pending = std.AutoHashMap(Designator, *ClientRoute).init(allocator),
            .answers = std.AutoHashMap(i32, []u8).init(allocator),
        };
    }

    fn deinit(self: *Hub) void {
        var it = self.clients.valueIterator();
        while (it.next()) |route| self.allocator.destroy(route.*);
        self.clients.deinit();
        var pending_it = self.pending.valueIterator();
        while (pending_it.next()) |route| self.allocator.destroy(route.*);
        self.pending.deinit();
        var answer_it = self.answers.valueIterator();
        while (answer_it.next()) |answer| self.allocator.free(answer.*);
        self.answers.deinit();
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

    /// The backend never dials in this scenario. A dial reaching the authority
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

    /// Carry the server's answer to the client `designator` names. The
    /// backend calls this inside `startAnswer`, on the client's own thread,
    /// so the client's route is filed under its exchange fd before any
    /// server candidate can look for it, and the client collects the answer
    /// as soon as `startAnswer` returns.
    fn sendAnswer(ctx: *anyopaque, fd: i32, designator: []const u8, sdp: []const u8) anyerror!void {
        const hub: *Hub = @ptrCast(@alignCast(ctx));
        if (designator.len != crypto.PeerKey.designator_len) return error.UnknownOfferer;
        const copy = try hub.allocator.dupe(u8, sdp);
        errdefer hub.allocator.free(copy);
        hub.mutex.lock();
        defer hub.mutex.unlock();
        try hub.clients.ensureUnusedCapacity(1);
        try hub.answers.ensureUnusedCapacity(1);
        if (hub.answered_count == hub.answered.len) return error.TooManyOffers;
        const route = hub.pending.fetchRemove(designator[0..crypto.PeerKey.designator_len].*) orelse return error.UnknownOfferer;
        hub.clients.putAssumeCapacity(fd, route.value);
        hub.answers.putAssumeCapacity(fd, copy);
        hub.answered[hub.answered_count] = route.key;
        hub.answered_count += 1;
    }

    fn authority(self: *Hub) webrtc.SignalingAuthority {
        return .{ .ctx = self, .sendOffer = sendOffer, .sendAnswer = sendAnswer, .sendCandidate = sendCandidate };
    }

    const OfferResult = struct { fd: i32, answer: []const u8 };

    /// Carry a client's offer to the server's backend, which builds the
    /// answerer scoped to the client's identity, and collect the answer it
    /// sent back. Runs on the client's thread: `startAnswer` is the backend's
    /// thread-safe entry.
    fn offer(
        self: *Hub,
        client_peer: *webrtc.Peer,
        client_designator: *const Designator,
        offer_sdp: []const u8,
        answer_buf: []u8,
    ) !OfferResult {
        const route = try self.allocator.create(ClientRoute);
        route.* = .{ .peer = client_peer };
        {
            errdefer self.allocator.destroy(route);
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.pending.putNoClobber(client_designator.*, route);
        }
        const fd = self.backend.startAnswer(client_designator, offer_sdp) catch |err| {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.pending.fetchRemove(client_designator.*)) |kv| self.allocator.destroy(kv.value);
            return err;
        };
        const answer = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            const kv = self.answers.fetchRemove(fd) orelse return error.AnswerNotCarried;
            break :blk kv.value;
        };
        defer self.allocator.free(answer);
        if (answer.len > answer_buf.len) return error.AnswerTooLarge;
        @memcpy(answer_buf[0..answer.len], answer);
        return .{ .fd = fd, .answer = answer_buf[0..answer.len] };
    }

    /// Drop the return-candidate route once the client's channel is up (or its
    /// bring-up failed). The client peer's storage dies with its thread.
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
/// OCapN session over the open channel, fetch the greeter and call it
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

    const client_designator = secret.publicKey().toDesignator();
    var sdp_buf: [webrtc_common.signaling_frame_bytes]u8 = undefined;
    var sdp_len: usize = 0;
    const offer_sdp = try peer.createOffer(&sdp_buf, &sdp_len);
    var signal_buf: [webrtc_common.signaling_frame_bytes]u8 = undefined;
    const answered = try hub.offer(&peer, &client_designator, offer_sdp, &signal_buf);
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
    });
    defer client_host.deinit();

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

/// The serving side: one HostRuntime listener whose accepted sessions all
/// serve the published greeter, stepped on one thread. Each accepted
/// session's authenticated partner is recorded for the final check.
const Server = struct {
    host: *driver.core.Host,
    failure: ?anyerror = null,
    accepted: [num_conns]Designator = undefined,
    accepted_count: usize = 0,

    const listener_tag: u64 = 1;

    fn observer(self: *Server) driver.HostRuntime.SessionAcceptObserver {
        return .{ .ctx = self, .opened = opened, .failed = failed };
    }

    /// The channel was scoped to the client's designator when the backend
    /// answered its offer, so the session opens with that identity proved by
    /// the transport.
    fn opened(ctx: *anyopaque, _: u64, session: *driver.core.HostSession) anyerror!void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        const identity = try self.host.partnerIdentity(session);
        if (identity.provenance != .authenticated_transport) return error.UnprovenClient;
        if (identity.designator.len != crypto.PeerKey.designator_len) return error.UnprovenClient;
        if (self.accepted_count == self.accepted.len) return error.TooManyClients;
        self.accepted[self.accepted_count] = identity.designator[0..crypto.PeerKey.designator_len].*;
        self.accepted_count += 1;
    }

    fn failed(ctx: *anyopaque, _: u64, failure: driver.OperationFailure) void {
        const self: *Server = @ptrCast(@alignCast(ctx));
        if (self.failure == null) self.failure = failure.chain.cause;
    }

    fn listen(self: *Server, runtime: *driver.HostRuntime, allocator: std.mem.Allocator) !void {
        var listener = try runtime.bindListener(model.transport.webrtc, "", .{});
        var owns_listener = true;
        errdefer if (owns_listener) {
            if (runtime.closeListener(&listener)) |failure| runtime.noteTerminalOperationFailure(failure);
        };
        var prepared = switch (runtime.prepareListenerLocatorOutcome(&listener)) {
            .ready => |value| value,
            .failed => |failure| return failure.cause,
        };
        var owns_prepared = true;
        defer if (owns_prepared) prepared.deinit(allocator);
        try runtime.activateOwnedListener(&listener, &prepared, listener_tag, self.observer());
        owns_listener = false;
        owns_prepared = false;
        if (!try runtime.selectOwnedListener(listener_tag)) return error.ListenerNotSelected;
    }

    fn run(runtime: *driver.HostRuntime, done: *const std.atomic.Value(bool), out_err: *?anyerror) void {
        while (!done.load(.acquire)) {
            _ = runtime.stepAny(20) catch |err| {
                out_err.* = err;
                return;
            };
        }
    }
};

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
    });
    defer host.deinit();

    var hub = Hub.init(allocator, io, undefined);
    defer hub.deinit();

    const read_buffer_bytes: u32 = @intCast(@min(frame_cap, 16 * 1024));
    var resident = try WebrtcResident.init(
        allocator,
        try webrtc.Backend.initBound(allocator, &server_resident, hub.authority(), 256, read_buffer_bytes),
        .{},
    );
    defer {
        resident.closeAndDrain(5_000) catch |err| std.log.err("WebRTC resident drain failed: {s}", .{@errorName(err)});
        resident.deinit();
    }
    // The resident owns the backend in place, so the hub can hold its address.
    hub.backend = &resident.backend;

    var runtime = try driver.HostRuntime.initWithCore(allocator, io, &host, .{}, .{
        .handshake = .{ .ms = 30_000 },
        .settle = .{ .ms = 30_000 },
    });
    defer runtime.deinit();
    _ = try runtime.addResident(model.transport.Known.webrtc.metadata(), resident.resident());
    try runtime.publish("greeter", Greeter, .{});
    var server = Server{ .host = &host };
    try server.listen(&runtime, allocator);

    var loop_err: ?anyerror = null;
    var done = std.atomic.Value(bool).init(false);
    var loop_future = try io.concurrent(Server.run, .{ &runtime, &done, &loop_err });

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
    loop_future.await(io);
    if (loop_err) |err| return err;
    if (server.failure) |err| return err;
    if (first_err) |err| return err;

    // Every accepted session named the client whose offer the backend
    // answered, and nothing else was accepted.
    if (server.accepted_count != num_conns or hub.answered_count != num_conns) return error.AcceptedCountMismatch;
    for (server.accepted) |accepted| {
        var answered = false;
        for (hub.answered) |designator| answered = answered or std.mem.eql(u8, &designator, &accepted);
        if (!answered) return error.AcceptedUnansweredClient;
    }

    std.debug.print(
        "webrtc-loop: OK, {d} concurrent DataChannels answered by the backend, {d} calls each, served from one HostRuntime thread over a completion resident\n",
        .{ num_conns, calls_per_conn },
    );
}
