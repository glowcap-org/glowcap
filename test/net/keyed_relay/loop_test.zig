//! The keyed-relay completion loop: a wrapped connect failure reclaimed
//! unopened, the evented cold dial fetching through the relay, and the dial
//! and listen configuration refusals.

const std = @import("std");
const glowcap = @import("glowcap");
const netlayer_test = @import("../../support/netlayer.zig");

const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const net = glowcap.net;
const keyed_relay = net.relay;
const ws_relay = @import("../../support/ws_relay.zig");
const fetch_pump = @import("../../support/fetch_pump.zig");
const handshake = @import("../../support/handshake.zig");
const wait = @import("../../support/wait.zig");

const Io = std.Io;
const ip = std.Io.net;

const admission = @import("../../support/keyed_relay_admission.zig");
const AdmissionBackend = admission.AdmissionBackend;
const admissionBackend = admission.admissionBackend;
const deinitAdmissionBackend = admission.deinitAdmissionBackend;

const frame_cap = admission.frame_cap;

const relay_support = @import("harness.zig");
const stubNegotiatingPeer = relay_support.stubNegotiatingPeer;
const startSession = relay_support.startSession;
const serveRegistered = relay_support.serveRegistered;

const LoopClientCtx = struct {
    allocator: std.mem.Allocator,
    done: *std.atomic.Value(bool),
    fetch_sent: bool = false,
    answer_position: model.AnswerPosition = .from(0),
    resolver_export: ?model.ExportPosition = null,

    fn serve(conn_ctx: ?*anyopaque, peer: *engine.Peer, event: *engine.Event) anyerror!void {
        const self: *LoopClientCtx = @ptrCast(@alignCast(conn_ctx.?));
        if (!self.fetch_sent and peer.sessionIsOpen()) {
            const prepared = try engine.fetch.prepareFetchSwissnum(self.allocator, &peer.session_state, "thermostat");
            self.answer_position = prepared.answer.position;
            self.resolver_export = prepared.resolver_export;
            self.fetch_sent = true;
            try peer.send(prepared.message);
            return;
        }
        if (!self.fetch_sent) return;

        const matched = try fetch_pump.matchFetchEvent(
            self.allocator,
            self.resolver_export,
            self.answer_position,
            event,
        );
        if (matched) |reference| {
            model.freeReference(self.allocator, reference);
            self.done.store(true, .release);
        }
    }
};

fn makeLoopClientPeer(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!engine.Peer {
    _ = ctx;
    var peer = stubNegotiatingPeer(allocator);
    errdefer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;
    try peer.sendBorrowed(startSession("client"));
    return peer;
}

fn makeLoopClientCtx(ctx: ?*anyopaque, _: *engine.Peer, _: usize) anyerror!?*anyopaque {
    return ctx;
}

const FailedDialJournal = struct {
    closes: usize = 0,
    opened: bool = true,

    fn onClose(
        ctx: ?*anyopaque,
        _: usize,
        conn_ctx: ?*anyopaque,
        report: net.completion.CloseReport,
    ) void {
        const self: *FailedDialJournal = @ptrCast(@alignCast(ctx.?));
        std.debug.assert(conn_ctx == null);
        self.closes += 1;
        self.opened = report.opened;
    }
};

test "keyed-relay completion loop reclaims a wrapped connect failure unopened" {
    const Loop = net.completion.Loop(AdmissionBackend, keyed_relay.DialResolver);
    var journal: FailedDialJournal = .{};
    const backend = try admissionBackend(std.testing.allocator);
    var loop = try Loop.initWithBackend(
        std.testing.allocator,
        backend,
        makeLoopClientPeer,
        @ptrCast(&journal),
        .{
            .max_conns = 1,
            .on_close = FailedDialJournal.onClose,
        },
    );
    defer loop.deinit();

    const designator = @as([64]u8, @splat('a'));
    _ = try loop.dialLocator(.{
        .transport = keyed_relay.transport_name,
        .designator = &designator,
        .hints = model.Hints.emptyFalse(),
    });
    loop.backend.platform.pending_connect.?.result = -1;

    try loop.run(.{ .after_closed = 1 });
    try loop.closeAndDrain();

    try std.testing.expectEqual(@as(usize, 1), journal.closes);
    try std.testing.expect(!journal.opened);
    try std.testing.expectEqual(@as(usize, 0), loop.backend.conns.count());
    // The failed address leg has already retired its connect completion, so
    // the race closes that private descriptor directly before publishing the
    // synthetic dial failure. The Loop's later synthetic close has no second
    // platform descriptor to retire.
    try std.testing.expectEqual(@as(usize, 0), loop.backend.platform.close_submits);
    try std.testing.expectEqual(@as(usize, 1), loop.backend.platform.close_calls);
    try std.testing.expect(loop.backend.platform.pending_close == null);
}

fn runKeyedRelayLoopUntil(
    loop: *net.KeyedRelayLoop,
    done: *const std.atomic.Value(bool),
    out_err: *?anyerror,
) void {
    loop.runUntil(done, 5_000) catch |err| {
        out_err.* = err;
    };
    loop.closeAndDrain() catch |err| {
        out_err.* = err;
    };
}

test "keyed-relay completion loop: evented cold dial fetches through relay" {
    if (!(@import("builtin").os.tag == .linux or @import("builtin").os.tag.isDarwin())) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const relay_addr: ip.IpAddress = .{ .ip4 = ip.Ip4Address.loopback(0) };
    var server = try ip.IpAddress.listen(&relay_addr, io, .{ .reuse_address = true });
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var relay_url_buf: [64]u8 = undefined;
    const relay_url = try std.fmt.bufPrint(&relay_url_buf, "ws://127.0.0.1:{d}/relay", .{port});
    var register_url_buf: [64]u8 = undefined;
    const register_url = try std.fmt.bufPrint(&register_url_buf, "ws://127.0.0.1:{d}/register", .{port});

    const identity = crypto.SecretKey.fromSeed(@as([crypto.seed_bytes]u8, @splat(0x71)));

    var registered = try keyed_relay.Resident.initRegistered(
        allocator,
        io,
        relay_url,
        register_url,
        identity.publicKey(),
    );
    defer _ = registered.deinit();

    var relay_future = try io.concurrent(ws_relay.bridgeOneRendezvous, .{ io, &server, allocator });

    const registered_nl = registered.netlayer();
    const listener = try netlayer_test.listenBlocking(registered_nl, allocator, .{
        .designator = "",
        .identity = identity.publicKey(),
    });
    defer netlayer_test.close(listener);

    var serve_future = try io.concurrent(serveRegistered, .{ listener, identity.publicKey(), allocator });

    // The same sequencing the blocking test needs: the fixture accepts the
    // registration leg first, so the cold dial waits for the background
    // registration through the listener's readiness edge.

    var done = std.atomic.Value(bool).init(false);
    var client_ctx = LoopClientCtx{ .allocator = allocator, .done = &done };

    var relay_seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    try io.randomSecure(&relay_seed);
    const backend = try net.KeyedRelayBackend.initWithRelay(allocator, 64, 16, frame_cap, .{
        .url = relay_url,
        .entropy_seed = relay_seed,
        // Force the live CapTP conversation through multiple complete binary
        // messages; the relay and both byte-stream readers must erase those
        // WebSocket boundaries.
        .send_staging_bytes = keyed_relay.max_header_len + keyed_relay.max_control_payload,
    });
    var loop = try net.KeyedRelayLoop.initWithBackend(allocator, backend, makeLoopClientPeer, @ptrCast(&client_ctx), .{
        .max_conns = 4,
        .make_conn_ctx = makeLoopClientCtx,
        .serve = LoopClientCtx.serve,
        .free_conn_ctx = null,
    });
    defer loop.deinit();

    const designator = identity.publicKey().toDesignator();
    _ = try loop.dialLocator(.{
        .transport = keyed_relay.transport_name,
        .designator = designator[0..],
        .hints = model.Hints.emptyFalse(),
    });

    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runKeyedRelayLoopUntil, .{ &loop, &done, &loop_err });
    loop_future.await(io);
    const serve_result = serve_future.await(io);
    const relay_result = relay_future.await(io);

    if (loop_err) |err| return err;
    try serve_result;
    try relay_result;
    try std.testing.expect(done.load(.acquire));
}

test "keyed-relay dial refuses a non-key designator and a listen without registration config" {
    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try keyed_relay.Resident.init(allocator, io, "ws://127.0.0.1:1/relay");
    defer _ = resident.deinit();
    const nl = resident.netlayer();

    var peer = stubNegotiatingPeer(allocator);
    defer peer.deinit();
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;

    // A non-key designator refuses before any I/O.
    const bad: model.PeerLocator = .{
        .transport = keyed_relay.transport_name,
        .designator = "not-a-key",
        .hints = model.Hints.emptyMap(),
    };
    try std.testing.expectError(
        error.InvalidAddress,
        nl.dial(&peer, bad, .{ .read = &read_buf, .write = &write_buf }, .inherit),
    );
    var backend = try admissionBackend(allocator);
    defer deinitAdmissionBackend(&backend);
    try std.testing.expectError(
        error.InvalidAddress,
        backend.startDial(1, .{ .keyed_relay = .{ .designator = "not-a-key\r\nInjected: yes", .relay = null } }),
    );

    // A dial-only resident (no register URL, no identity) refuses listen.
    const listen_outcome = nl.listen(allocator, .{ .designator = "" });
    try std.testing.expect(listen_outcome == .failed);
    try std.testing.expectEqual(error.InvalidAddress, listen_outcome.failed.cause);
}
