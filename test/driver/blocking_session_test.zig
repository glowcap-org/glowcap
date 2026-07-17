//! Driver loopback test: the application surface, both halves.
//!
//! `driver.connectTcp` dials and `driver.acceptTcp` hosts. This test runs
//! the two against each other over a real 127.0.0.1 socket with the keyed,
//! verified `op:start-session` handshake on both ends (fresh random session
//! keys, signature verification on, the same exchange a live Goblins peer
//! requires): the host accepts into a connected vat, publishes an actor by
//! name, and `serve`s the connection until the client leaves; the client
//! fetches the actor, calls it, and reads the reply off the far promise.
//! Every API edge here is one a hosted application rides.

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net.tcp;
const net = pancake.net;
const syrup = pancake.ocapn.codec.syrup;
const crypto = pancake.foundation.crypto;

const ip = std.Io.net;

const frame_cap = 4096;

/// The published actor: answers `greet(name)` with a static greeting.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "greet")) return error.NoSuchMethod;
        return .{ .string = "hello from the hosting vat" };
    }
};

/// The taskboard shapes the pipelining test drives: a board whose `create`
/// mints a fresh task capability, and a task that answers `assign`/`complete`/
/// `status`. The same shape `bench/langs/host.zig` serves; here it proves the
/// questioner-side pipelining path end to end.
const Task = struct {
    done: bool = false,
    pub fn handle(self: *Task, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "assign")) return .{ .bytes = "assigned" };
        if (std.mem.eql(u8, msg.verb, "complete")) {
            self.done = true;
            return .{ .bytes = "done" };
        }
        if (std.mem.eql(u8, msg.verb, "status")) return .{ .bytes = if (self.done) "done" else "open" };
        return error.NoSuchMethod;
    }
};

const Board = struct {
    pub fn handle(self: *Board, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        if (!std.mem.eql(u8, msg.verb, "create")) return error.NoSuchMethod;
        const cap = try driver.spawnAt(turn.vat, Task, .{});
        return cap.arg();
    }
};

/// Host the board and serve until the client leaves, the pipelining test's
/// hosting half.
fn serveBoardOnce(server: *driver.Server) anyerror!void {
    var conn = try server.accept();
    defer conn.deinit();
    _ = try conn.publish("root", Board, .{});
    try conn.serve();
}

/// Drive the taskboard unit with promise pipelining: send `create`, then send
/// `assign`/`complete`/`status` addressed at the *unresolved* `create` answer,
/// and only then settle the final `status`. The four delivers flush together on
/// that settle — none waits for `create` to come back — so the host queues the
/// three pipelined calls on its pending answer and drains them onto the freshly
/// spawned task when `create` resolves (ADR-0007's serving half). A correct
/// `status` of `done` proves the questioner half end to end: a dependent chain
/// crossed the wire as one batch, not four round trips.
fn pipelineUnitOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var tcp_resident = tcp.Resident{ .io = io };
    var buf: [64]u8 = undefined;
    var conn = try driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.locator(&buf, address), .ephemeral, .{ .frame_cap = frame_cap });
    defer conn.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const root = try conn.fetch("root");
    const created = try conn.send(root, .{ .verb = "create", .args = &.{.{ .bytes = "benchmark" }} });
    _ = try conn.sendToAnswer(created, .{ .verb = "assign", .args = &.{.{ .bytes = "alice" }} });
    _ = try conn.sendToAnswer(created, .{ .verb = "complete" });
    const status = try conn.sendToAnswer(created, .{ .verb = "status" });

    const settled = try conn.settleVow(status, arena_state.allocator());
    switch (settled) {
        .fulfilled => |arg| {
            try std.testing.expect(arg == .bytes);
            try std.testing.expectEqualStrings("done", arg.bytes);
        },
        .broken, .give => return error.PipelinedStatusBroke,
    }
}

test "driver loopback: promise pipelining drives create->assign->complete->status as one batch and status settles done" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, .{ .frame_cap = frame_cap });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(server.localDesignator(&addr_buf));

    var host_future = try io.concurrent(serveBoardOnce, .{&server});
    const client_result = pipelineUnitOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

/// Accept one partner via `driver.acceptTcp` (responder keyed handshake inside),
/// publish the greeter, and `serve` until the client leaves, whether it closes
/// cleanly or just drops the socket once it has its reply.
fn hostOnce(listener: *tcp.Listener, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var cv = try driver.acceptTcp(allocator, &peer, listener, read_buf, write_buf);
    defer cv.deinit();

    _ = try cv.publish("greeter", Greeter, .{});

    // A spawned position comes from the session's one export allocator — the
    // counter that also mints bootstrap and resolver exports — so it can never
    // alias a position the session hands out for anything else.
    const spawned = try cv.spawn(Greeter, .{});
    try std.testing.expectEqual(spawned.position + 1, try peer.exportNextObject());

    try cv.serve();
}

const ReplyState = struct {
    done: bool = false,
    ok: bool = false,
};

fn onGreeting(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *ReplyState = @ptrCast(@alignCast(ctx.?));
    state.done = true;
    state.ok = switch (resolution) {
        .fulfilled => |arg| switch (arg) {
            .string => |text| std.mem.eql(u8, text, "hello from the hosting vat"),
            else => false,
        },
        .broken, .give => false,
    };
}

/// Dial via `driver.connectTcp`, fetch the published greeter, call it, and
/// assert the reply round-trips. Closing on return lets the host observe EOF.
/// The client reads through a 64-byte buffer — far smaller than any handshake
/// frame — so every inbound frame on this side assembles in the connection's
/// bounded spill, proving the small-buffer read path over a real socket.
fn callOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, 64);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var cv = try driver.connectTcp(allocator, io, &peer, address, read_buf, write_buf);
    defer cv.deinit();

    const greeter = try cv.fetch("greeter");
    const promise = try cv.send(greeter, .{
        .verb = "greet",
        .args = &.{.{ .string = "pancake" }},
    });
    var state = ReplyState{};
    try cv.on(promise, .{ .ctx = &state, .func = onGreeting });

    while (!state.done) {
        const progress = try cv.step();
        if (progress == .closed) break;
    }

    try std.testing.expect(state.done);
    try std.testing.expect(state.ok);
}

/// The one-call client convenience: `driver.connect` owns the peer and buffers,
/// so the client connects, fetches, calls, and closes without peer or buffer
/// setup. `call` returns the settled outcome materialized into the caller's
/// arena, no ctx/callback dance.
fn connectOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var tcp_resident = tcp.Resident{ .io = io };
    var buf: [64]u8 = undefined;
    var conn = try driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.locator(&buf, address), .ephemeral, .{ .frame_cap = frame_cap });
    defer conn.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const greeter = try conn.fetch("greeter");
    const settled = try conn.call(greeter, .{ .verb = "greet", .args = &.{.{ .string = "pancake" }} }, arena_state.allocator());
    switch (settled) {
        .fulfilled => |arg| {
            try std.testing.expect(arg == .string);
            try std.testing.expectEqualStrings("hello from the hosting vat", arg.string);
        },
        .broken, .give => return error.CallBroke,
    }
}

/// The one-call hosting convenience: `Server.accept` owns the partner's peer
/// and buffers, so the host accepts, publishes, and serves with the same
/// parity `connect` gives the client.
fn serveOnce(server: *driver.Server) anyerror!void {
    var conn = try server.accept();
    defer conn.deinit();
    _ = try conn.publish("greeter", Greeter, .{});
    try conn.serve();
}

test "driver loopback: connect and listen own peers and buffers, fetch + call round-trip in one call each" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, .{ .frame_cap = frame_cap });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(server.localDesignator(&addr_buf));

    var host_future = try io.concurrent(serveOnce, .{&server});
    const client_result = connectOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

test "driver loopback: acceptTcp publishes and serves the keyed session connectTcp dials, fetch + call round-trip" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    const address = listener.localAddress();

    // The host runs concurrently; the client drives this fiber.
    var host_future = try io.concurrent(hostOnce, .{ &listener, allocator });

    const client_result = callOnce(io, address, allocator);
    const host_result = host_future.await(io);

    try client_result;
    try host_result;
}

/// Dial an `ocapn://` URI via `driver.connectUri`: build the URI for the bound
/// address, parse-and-dial it in one call against a caller-owned netlayer slice,
/// then fetch + call. Proves the URI becomes a connection with no transport
/// branch in the caller, the slice decides.
fn dialUriOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const loc = tcp.locator(&designator_buf, address);
    const uri = try model.uri.writePeer(allocator, loc);
    defer allocator.free(uri);

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var tcp_resident = pancake.net.tcp.Resident{ .io = io };
    var cv = try driver.connectUri(allocator, &.{tcp_resident.netlayer()}, &peer, uri, .ephemeral, read_buf, write_buf);
    defer cv.deinit();

    const greeter = try cv.fetch("greeter");
    const promise = try cv.send(greeter, .{ .verb = "greet", .args = &.{.{ .string = "pancake" }} });
    var state = ReplyState{};
    try cv.on(promise, .{ .ctx = &state, .func = onGreeting });
    while (!state.done) {
        const progress = try cv.step();
        if (progress == .closed) break;
    }
    try std.testing.expect(state.done and state.ok);
}

test "driver loopback: connectUri parses an ocapn:// URI and dials it through the caller's netlayer slice" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    const address = listener.localAddress();

    var host_future = try io.concurrent(hostOnce, .{ &listener, allocator });
    const client_result = dialUriOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

/// Fetch a name the host never published. The partner's bootstrap answers with
/// a break ("unknown swissnum"): `fetch` surfaces the distinguished
/// `Error.FetchBroken` rather than a flat failure that could also mean a
/// non-capability fulfillment, and `fetchSettled` carries the partner's break
/// reason whole in caller-owned memory.
fn fetchMissingOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var cv = try driver.connectTcp(allocator, io, &peer, address, read_buf, write_buf);
    defer cv.deinit();

    try std.testing.expectError(driver.Error.FetchBroken, cv.fetch("nobody-published-this"));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const settled = try cv.fetchSettled("nobody-published-this-either", arena_state.allocator());
    switch (settled) {
        .fulfilled, .give => return error.UnexpectedFulfillment,
        .broken => |reason| try std.testing.expectEqualStrings("unknown swissnum", reason),
    }
}

test "driver loopback: a fetch of an unpublished name surfaces Error.FetchBroken and fetchSettled carries the reason" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    const address = listener.localAddress();

    var host_future = try io.concurrent(hostOnce, .{ &listener, allocator });
    const client_result = fetchMissingOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

/// The locally spawned actor for the local-call test: replies from its own
/// state, so settling it needs no partner traffic at all.
const LocalPing = struct {
    pub fn handle(self: *LocalPing, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "ping")) return error.NoSuchMethod;
        return .{ .string = "pong from this side" };
    }
};

/// `call` on a locally spawned capability's ref: the promise settles in the
/// flush's local drive, so the call returns without the partner sending
/// anything after the handshake (the host publishes but is never fetched).
/// Settling into the plain testing allocator and freeing with `Settled.deinit`
/// also proves the result frees exactly what `call` materialized.
fn callLocalOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var tcp_resident = tcp.Resident{ .io = io };
    var buf: [64]u8 = undefined;
    var conn = try driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.locator(&buf, address), .ephemeral, .{ .frame_cap = frame_cap });
    defer conn.deinit();

    const cap = try conn.spawn(LocalPing, .{});
    const settled = try conn.call(cap.ref, .{ .verb = "ping" }, allocator);
    defer settled.deinit(allocator);
    switch (settled) {
        .fulfilled => |arg| {
            try std.testing.expect(arg == .string);
            try std.testing.expectEqualStrings("pong from this side", arg.string);
        },
        .broken, .give => return error.CallBroke,
    }
}

test "driver loopback: call on a locally spawned ref settles with no partner traffic" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, .{ .frame_cap = frame_cap });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(server.localDesignator(&addr_buf));

    var host_future = try io.concurrent(serveOnce, .{&server});
    const client_result = callLocalOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

const abort_diagnostic = "credential rotation in progress; dial back later";

/// Accept one partner, publish the greeter, then answer the client's first
/// deliver to the greeter with a typed `op:abort` instead of a resolve. The
/// bootstrap fetch stays engine-answered, so the client holds a real far ref
/// before the abort lands.
fn abortingHostOnce(listener: *tcp.Listener, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var cv = try driver.acceptTcp(allocator, &peer, listener, read_buf, write_buf);
    defer cv.deinit();

    const cap = try cv.publish("greeter", Greeter, .{});

    // Pump until the client's deliver reaches the greeter's export, dropping
    // the event instead of serving it, the abort below is the only answer.
    outer: while (true) {
        while (cv.served.peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch continue;
            const deliver = switch (body) {
                .deliver => |deliver| deliver,
                else => continue,
            };
            const position = deliver.target.exportPosition() orelse continue;
            if (position.int() == cap.position) break :outer;
        }
        _ = try cv.conn.pump();
    }

    try cv.served.peer.sendCopying(.{ .abort = .{ .kind = .unauthorized, .message = abort_diagnostic } });
    cv.conn.flush() catch {};
}

/// Fetch the greeter and call it against a partner that answers with a typed
/// abort and leaves: the pending `call` settles broken with the partner's own
/// diagnostic, and `abortReason` retains the same message.
fn callAbortedOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var cv = try driver.connectTcp(allocator, io, &peer, address, read_buf, write_buf);
    defer cv.deinit();

    const greeter = try cv.fetch("greeter");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const settled = try cv.call(greeter, .{ .verb = "greet", .args = &.{.{ .string = "pancake" }} }, arena_state.allocator());
    switch (settled) {
        .fulfilled, .give => return error.UnexpectedFulfillment,
        .broken => |reason| try std.testing.expectEqualStrings(abort_diagnostic, reason),
    }
    try std.testing.expectEqualStrings(abort_diagnostic, cv.abortReason().?);
}

test "driver loopback: a partner's typed abort breaks the pending call with its diagnostic and abortReason retains it" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    const address = listener.localAddress();

    var host_future = try io.concurrent(abortingHostOnce, .{ &listener, allocator });
    const client_result = callAbortedOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

test "connectUri fails closed on a URI whose transport has no registered resident" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;

    var tcp_resident = pancake.net.tcp.Resident{ .io = io };

    // A syntactically valid URI naming a transport the slice does not host:
    // the dial refuses rather than silently falling back to tcp.
    try std.testing.expectError(
        driver.Error.UnknownTransport,
        driver.connectUri(allocator, &.{tcp_resident.netlayer()}, &peer, "ocapn://node123.quic", .ephemeral, &read_buf, &write_buf),
    );
}

// ── Byte-fed drive (ADR-0072) ────────────────────────────────────────────────
//
// A `driver.Served` owns no socket: the caller feeds inbound frames with
// `feedBorrowed` and drains outbound with `takeOutbound`, owning the loop
// itself. This is the sans-io driving mode `libpancake_driver` and a browser
// ride. The test shuttles a real eventual-send and its resolution between two
// byte-fed vats over an already-open in-memory session, with no `net.Connection`
// on either side, so the byte-fed path serves identically to the socket path.

const Adder = struct {
    n: i64,
    pub fn handle(self: *Adder, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "add")) return error.NoSuchMethod;
        self.n += msg.arg(0).integer;
        return .{ .integer = self.n };
    }
};

fn captureFedInt(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const slot: *i64 = @ptrCast(@alignCast(ctx.?));
    slot.* = switch (resolution) {
        .fulfilled => |value| value.integer,
        .broken, .give => -1,
    };
}

/// Encode `from`'s pending outbound and hand every frame to `to`, borrowed. The
/// byte-fed analogue of the socket shuttle: no sockets, frames moved by value.
fn shuttleFed(from: *driver.Served, to: *driver.Served) !void {
    try from.driveFed();
    while (from.takeOutbound()) |frame_value| {
        var frame = frame_value;
        defer frame.deinit();
        try to.feedBorrowed(frame.view());
    }
}

test "byte-fed Served serves an eventual-send with no socket (ADR-0072)" {
    const allocator = std.testing.allocator;
    var pair = try engine.pairing.paired(allocator);
    defer pair.deinit();

    // Both sides are byte-fed: no `net.Connection`, the test owns the loop.
    var server = driver.Served.over(allocator, &pair.p2);
    defer server.deinit();
    const adder = try server.vat.spawn(Adder, .{ .n = 10 });
    try server.vat.bindExport(adder, 7);
    // Hand-wired pairing: the client addresses position 7 out-of-band, so the
    // bound position takes an explicit grant.
    try pair.p2.exportObject(7);
    try pair.p1.importObject(7);

    var client = driver.Served.over(allocator, &pair.p1);
    defer client.deinit();
    const remote: actors.Ref = .{ .far = model.FarRef.object(7) };
    const promise = try client.vat.send(remote, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });

    var result: i64 = 0;
    try client.vat.on(promise, .{ .ctx = &result, .func = captureFedInt });

    // The deliver flows client -> server (the server's `feedBorrowed` runs the
    // actor and encodes the resolve); the resolve flows server -> client (the
    // client's `feedBorrowed` fires the promise listener). No socket touched.
    try shuttleFed(&client, &server);
    try shuttleFed(&server, &client);

    try std.testing.expectEqual(@as(i64, 15), result);
}

test "byte-fed Served opens a keyed session from scratch and serves (ADR-0072)" {
    const allocator = std.testing.allocator;
    var p_server = engine.Peer.initNegotiating(allocator);
    defer p_server.deinit();
    var p_client = engine.Peer.initNegotiating(allocator);
    defer p_client.deinit();

    // Each side proactively signs and queues its own keyed start-session, as a
    // real handshake does; the whole exchange then runs byte-fed, no socket.
    const loc_s: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:1", .hints = model.Hints.emptyFalse() };
    const loc_c: model.PeerLocator = .{ .transport = "tcp", .designator = "127.0.0.1:2", .hints = model.Hints.emptyFalse() };
    try p_server.sendKeyedStartSession(.v1_0, loc_s, crypto.SecretKey.fromSeed([_]u8{0x51} ** crypto.SEED_BYTES));
    try p_client.sendKeyedStartSession(.v1_0, loc_c, crypto.SecretKey.fromSeed([_]u8{0x52} ** crypto.SEED_BYTES));

    var server = driver.Served.over(allocator, &p_server);
    defer server.deinit();
    var client = driver.Served.over(allocator, &p_client);
    defer client.deinit();

    // Shuttle the handshake frames between the two byte-fed vats until both
    // sessions open — the full connection lifecycle, driven by the caller.
    var i: usize = 0;
    while (i < 16 and !(p_server.sessionIsOpen() and p_client.sessionIsOpen())) : (i += 1) {
        try shuttleFed(&client, &server);
        try shuttleFed(&server, &client);
    }
    try std.testing.expect(p_server.sessionIsOpen());
    try std.testing.expect(p_client.sessionIsOpen());

    // Serve real work over the byte-fed, self-opened session.
    const adder = try server.vat.spawn(Adder, .{ .n = 100 });
    try server.vat.bindExport(adder, 9);
    try p_server.exportObject(9);
    try p_client.importObject(9);
    const remote: actors.Ref = .{ .far = model.FarRef.object(9) };
    const promise = try client.vat.send(remote, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });
    var result: i64 = 0;
    try client.vat.on(promise, .{ .ctx = &result, .func = captureFedInt });
    try shuttleFed(&client, &server);
    try shuttleFed(&server, &client);
    try std.testing.expectEqual(@as(i64, 105), result);
}

/// The grant-on-marshal fixture (ADR-0074): `make` spawns two capabilities and
/// marshals exactly one into its reply. The other's export position leaks only
/// as an integer, which is data, not authority.
const TwoSpawner = struct {
    pub fn handle(self: *TwoSpawner, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        if (!std.mem.eql(u8, msg.verb, "make")) return error.NoSuchMethod;
        const granted = try driver.spawnAt(turn.vat, Greeter, .{});
        const reserved = try driver.spawnAt(turn.vat, Greeter, .{});
        const items = try turn.arena.alloc(model.Argument, 2);
        items[0] = granted.arg();
        items[1] = .{ .integer = @intCast(reserved.position) };
        return .{ .list = items };
    }
};

/// Host the factory and serve. The client's probe of the reserved position is
/// a protocol violation on this side: the session refuses it exactly like a
/// deliver to a nonexistent export, and the pump surfaces the typed abort.
fn serveGrantOnMarshalOnce(server: *driver.Server) anyerror!void {
    var conn = try server.accept();
    defer conn.deinit();
    _ = try conn.publish("factory", TwoSpawner, .{});
    try std.testing.expectError(error.ProtocolAbort, conn.serve());
}

/// Fetch the factory, prove the marshaled capability answers, then probe the
/// reserved position learned out-of-band and prove it is unaddressable.
fn probeReservedOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var tcp_resident = tcp.Resident{ .io = io };
    var buf: [64]u8 = undefined;
    var conn = try driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.locator(&buf, address), .ephemeral, .{ .frame_cap = frame_cap });
    defer conn.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const factory = try conn.fetch("factory");
    const made = try conn.call(factory, .{ .verb = "make" }, arena);
    try std.testing.expect(made == .fulfilled);
    const items = made.fulfilled.list;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    const granted = items[0].reference;
    try std.testing.expect(granted == .far);
    const reserved_position: u64 = @intCast(items[1].integer);

    // The capability that rode the reply is addressable: its marshal was the
    // grant, and the actor's turn runs.
    const greeted = try conn.call(.{ .far = granted.far }, .{ .verb = "greet" }, arena);
    try std.testing.expect(greeted == .fulfilled);

    // The reserved position — learned out-of-band, as a number — is not a
    // capability. The host refuses the deliver like a nonexistent export and
    // tears the session down, so the probe's vow breaks instead of reaching
    // the actor. (`importObject` is only this side's own bookkeeping; it moves
    // no authority on the host.)
    try conn.peer.importObject(reserved_position);
    const probed = conn.call(
        .{ .far = model.FarRef.object(reserved_position) },
        .{ .verb = "greet" },
        arena,
    ) catch |err| switch (err) {
        // The teardown can also race the settle wait; a closed connection is
        // the same refusal observed one step later.
        error.ConnectionClosed => return,
        else => return err,
    };
    try std.testing.expect(probed == .broken);
}

test "driver loopback: a spawned capability is unreachable until first marshaled (ADR-0074)" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, .{ .frame_cap = frame_cap });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(server.localDesignator(&addr_buf));

    var host_future = try io.concurrent(serveGrantOnMarshalOnce, .{&server});
    const client_result = probeReservedOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

test "Identity.ephemeral signs the unreachable-client designator" {
    // Same bytes Host / connectVia(.ephemeral) advertise — the placeholder
    // must not drift by entry path.
    const identity: driver.Identity = .ephemeral;
    try std.testing.expectEqualStrings(
        driver.unreachable_client_designator,
        identity.dialedDesignator(),
    );
}

// ── faultToClosed: the settle-path fault mapping (R3) ────────────────────────
//
// The chokepoint `settle`'s flush-catch and step-catch both route through has
// two arms — a clean transport loss becomes `ConnectionClosed` with the far
// vows broken as "connection lost", any other fault propagates raw with the
// vows broken as "connection failed". `serve`'s own catch is a separate path
// (it returns void and does not break on the non-transport arm), so it does not
// exercise these arms; only a blocking call driven to a transport fault does.
// Both arms are pinned deterministically here by feeding a `BlockingSession`
// over a fixed reader that yields the exact framing failure — no timing.

const zero_pubkey_fault = [_]u8{0} ** 32;
const zero_sig_fault = [_]u8{0} ** 64;

/// A whole stub-key `op:start-session` frame, encoded so the caller can take a
/// prefix of it to drive a mid-frame EOF (`TruncatedFrame`).
fn faultStartSessionFrame(allocator: std.mem.Allocator) !pancake.foundation.Frame {
    return syrup.encodeMessageForProfile(allocator, model.CaptpVersion.v1_0, .{
        .start_session = .{
            .captp_version = .v1_0,
            .session_pubkey = .{ .bytes = &zero_pubkey_fault },
            .acceptable_location = .{ .transport = "memory", .designator = "remote", .hints = model.Hints.emptyMap() },
            .acceptable_location_sig = .{ .bytes = &zero_sig_fault },
        },
    });
}

fn faultNoopClose(ctx: *anyopaque) void {
    _ = ctx;
}
fn faultNoopSocket(ctx: *anyopaque) ?std.Io.net.Socket.Handle {
    _ = ctx;
    return null;
}

/// Captures the break reason the far vows carry when `faultToClosed` runs.
const FaultBreakCapture = struct {
    broke: bool = false,
    reason: [64]u8 = undefined,
    reason_len: usize = 0,
    fn fire(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *FaultBreakCapture = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .broken => |reason| {
                self.broke = true;
                const n = @min(reason.len, self.reason.len);
                @memcpy(self.reason[0..n], reason[0..n]);
                self.reason_len = n;
            },
            else => {},
        }
    }
    fn reasonHas(self: *const FaultBreakCapture, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.reason[0..self.reason_len], needle) != null;
    }
};

/// Build a `BlockingSession` over an established peer and a fixed reader/writer:
/// the reader's bytes are the exact framing the settle-path step will read.
const FaultHarness = struct {
    pair: engine.pairing.Pair,
    reader: std.Io.Reader,
    write_buf: [512]u8 = undefined,
    writer: std.Io.Writer = undefined,
    cv: driver.BlockingSession = undefined,

    fn init(allocator: std.mem.Allocator, io: std.Io, inbound: []const u8) !*FaultHarness {
        const self = try allocator.create(FaultHarness);
        self.pair = try engine.pairing.pairedGoblins(allocator);
        // A far import the questioner can address; the send mints a far vow.
        try self.pair.p1.importObject(7);
        self.reader = std.Io.Reader.fixed(inbound);
        self.writer = std.Io.Writer.fixed(&self.write_buf);
        const Transport = @FieldType(net.Connection, "transport");
        const handle = Transport{ .ctx = self, .close_fn = faultNoopClose, .socket_handle_fn = faultNoopSocket };
        const conn = net.Connection.init(io, &self.pair.p1, &self.reader, &self.writer, handle);
        self.cv = driver.BlockingSession.over(allocator, &self.pair.p1, conn);
        return self;
    }

    fn deinit(self: *FaultHarness, allocator: std.mem.Allocator) void {
        self.cv.deinit();
        self.pair.deinit();
        allocator.destroy(self);
    }
};

test "faultToClosed: a transport truncation during a blocking call breaks far vows with 'connection lost' and reports ConnectionClosed" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The inbound the settle-path step reads: the first half of a whole frame,
    // then EOF — a mid-frame truncation, surfaced as `error.TruncatedFrame`.
    var whole = try faultStartSessionFrame(allocator);
    defer whole.deinit();
    const half = whole.bytes()[0 .. whole.bytes().len / 2];

    var h = try FaultHarness.init(allocator, io, half);
    defer h.deinit(allocator);

    // A vow allows one listener, and `settleVow` registers its own, so observe
    // the break on a second far vow: `breakFarVows` breaks every far vow.
    const observe = try h.cv.send(.{ .far = model.FarRef.object(7) }, .{ .verb = "x", .args = &.{} });
    var capture = FaultBreakCapture{};
    try h.cv.on(observe, .{ .ctx = &capture, .func = FaultBreakCapture.fire });
    const settle_vow = try h.cv.send(.{ .far = model.FarRef.object(7) }, .{ .verb = "x", .args = &.{} });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ConnectionClosed, h.cv.settleVow(settle_vow, arena.allocator()));
    try std.testing.expect(capture.broke);
    try std.testing.expect(capture.reasonHas("connection lost"));
}

test "faultToClosed: a non-transport fault during a blocking call breaks far vows with 'connection failed' and propagates the raw error" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Structurally invalid bytes: a length-mismatched symbol, surfaced as
    // `error.MalformedFrame` — the non-transport `else` arm.
    var h = try FaultHarness.init(allocator, io, "<7'op:foo>");
    defer h.deinit(allocator);

    const observe = try h.cv.send(.{ .far = model.FarRef.object(7) }, .{ .verb = "x", .args = &.{} });
    var capture = FaultBreakCapture{};
    try h.cv.on(observe, .{ .ctx = &capture, .func = FaultBreakCapture.fire });
    const settle_vow = try h.cv.send(.{ .far = model.FarRef.object(7) }, .{ .verb = "x", .args = &.{} });

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MalformedFrame, h.cv.settleVow(settle_vow, arena.allocator()));
    try std.testing.expect(capture.broke);
    try std.testing.expect(capture.reasonHas("connection failed"));
}

/// Manual dial (not `connectTcp`, whose bundled handshake is unbounded): dial
/// the socket, bind the vat over it, arm the deadline, then drive the keyed
/// handshake ourselves so the timeout has an entry point. A partner that
/// completes connect and then never speaks must break the handshake, not park
/// the fiber (ADR-0081, contract 2).
fn silentPartnerHandshakeTimesOut(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, 64);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var resident = tcp.Resident{ .io = io };
    const netlayers = [_]net.netlayer.Netlayer{resident.netlayer()};
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const locator = tcp.locator(&designator_buf, address);
    const nl = net.netlayer.resolve(&netlayers, locator.transport).?;
    const conn = try nl.dial(&peer, locator, .{ .read = read_buf, .write = write_buf });

    var vat = driver.BlockingSession.over(allocator, &peer, conn);
    defer vat.deinit();
    vat.handshake_timeout_ms = 200;

    const ident: driver.Identity = .ephemeral;
    const self_locator: model.PeerLocator = .{
        .transport = locator.transport,
        .designator = ident.dialedDesignator(),
        .hints = model.Hints.emptyFalse(),
    };
    try std.testing.expectError(driver.Error.HandshakeTimedOut, vat.startKeyedSession(self_locator));
}

test "driver loopback: a silent partner's keyed handshake breaks with HandshakeTimedOut, not a parked fiber" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Bind but never accept: the kernel completes connect into the backlog while
    // the peer stays silent through the whole handshake window.
    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    const address = listener.localAddress();

    try silentPartnerHandshakeTimesOut(io, address, allocator);
}

/// Host half that completes the keyed handshake and publishes, then never
/// serves — the partner opens then stalls, the settle budget's target.
fn hostAcceptPublishThenStall(server: *driver.Server, io: std.Io) anyerror!void {
    var conn = try server.accept();
    defer conn.deinit();
    _ = try conn.publish("root", Greeter, .{});
    // Hold the connection open without pumping CapTP until the client's
    // settle budget fires and it drops the socket; then exit.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2000), .real) catch {};
}

fn silentPartnerSettleTimesOut(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var tcp_resident = tcp.Resident{ .io = io };
    var buf: [64]u8 = undefined;
    var conn = try driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.locator(&buf, address), .ephemeral, .{
        .frame_cap = frame_cap,
        .settle_timeout_ms = 200,
    });
    defer conn.deinit();
    try std.testing.expectError(driver.Error.WaitTimedOut, conn.fetch("root"));
}

test "driver loopback: a partner that opens then stalls breaks settle with WaitTimedOut, not a parked fiber" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, .{ .frame_cap = frame_cap });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(server.localDesignator(&addr_buf));

    const host_thread = try std.Thread.spawn(.{}, hostAcceptPublishThenStall, .{ &server, io });
    defer host_thread.join();

    try silentPartnerSettleTimesOut(io, address, allocator);
}
