//! Driver loopback: the application surface, both halves, over a real
//! 127.0.0.1 socket with the keyed, verified handshake on both ends — the
//! same exchange a live Goblins peer requires. Connect and accept own their
//! peers and buffers; fetch, call, pipelining, URIs, typed aborts, local
//! spawns, and ADR-0074's grant-on-first-marshal each ride one test.

const std = @import("std");
const pancake = @import("pancake");
const support_actors = @import("../../support/actors.zig");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net.tcp;
const net = pancake.net;
const syrup = pancake.ocapn.codec.syrup;
const crypto = pancake.foundation.crypto;

const ip = std.Io.net;

const harness = @import("harness.zig");
const handshake_budget = harness.handshake_budget;
const frame_cap = harness.frame_cap;
const dial_opts = harness.dial_opts;
const connectPlain = harness.connectPlain;
const acceptPlain = harness.acceptPlain;
const Greeter = harness.Greeter;
const HostedGreeter = harness.HostedGreeter;

/// The taskboard shapes the pipelining test drives: a board whose `create`
/// mints a fresh task capability, and a task that answers `assign`/`complete`/
/// `status`. The same shape `bench/langs/host.zig` serves; here it proves the
/// questioner-side pipelining path end to end.
const Task = struct {
    done: bool = false,
    pub fn handle(self: *Task, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = ht;
        _ = args;
        if (std.mem.eql(u8, verb, "assign")) return .{ .bytes = "assigned" };
        if (std.mem.eql(u8, verb, "complete")) {
            self.done = true;
            return .{ .bytes = "done" };
        }
        if (std.mem.eql(u8, verb, "status")) return .{ .bytes = if (self.done) "done" else "open" };
        return error.NoSuchMethod;
    }
};

const Board = struct {
    pub fn handle(self: *Board, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = self;
        _ = args;
        if (!std.mem.eql(u8, verb, "create")) return error.NoSuchMethod;
        return .{ .capability = try ht.spawn(Task, .{}) };
    }
};

/// Host the board and serve until the client leaves, the pipelining test's
/// hosting half.
fn serveBoardOnce(server: *driver.Server) anyerror!void {
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("root", Board, .{});
    try session.serve();
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
    var session = try driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.locatorFromAddress(&buf, address), .ephemeral, dial_opts);
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const root = try session.fetch("root");
    const created = try session.send(root, "create", &.{.{ .bytes = "benchmark" }});
    _ = try created.send("assign", &.{.{ .bytes = "alice" }});
    _ = try created.send("complete", &.{});
    const status = try created.send("status", &.{});

    const settled = try status.settle(arena_state.allocator());
    switch (settled) {
        .fulfilled => |arg| {
            try std.testing.expect(arg == .bytes);
            try std.testing.expectEqualStrings("done", arg.bytes);
        },
        .broken => return error.PipelinedStatusBroke,
    }
}

test "driver loopback: promise pipelining drives create->assign->complete->status as one batch and status settles done" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, dial_opts);
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    var host_future = try io.concurrent(serveBoardOnce, .{server});
    const client_result = pipelineUnitOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

/// Accept one partner via `driver.acceptVia` (responder keyed handshake inside),
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

    var cv = try acceptPlain(allocator, &peer, listener, read_buf, write_buf, .{ .handshake = handshake_budget, .settle = dial_opts.settle });
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

/// Dial via `driver.connectVia`, fetch the published greeter, call it, and
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

    var cv = try connectPlain(allocator, io, &peer, address, read_buf, write_buf, .{ .handshake = handshake_budget, .settle = dial_opts.settle });
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
    var session = try driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.locatorFromAddress(&buf, address), .ephemeral, dial_opts);
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const greeter = try session.fetch("greeter");
    const settled = try session.call(greeter, "greet", &.{.{ .string = "pancake" }}, arena_state.allocator());
    switch (settled) {
        .fulfilled => |arg| {
            try std.testing.expect(arg == .string);
            try std.testing.expectEqualStrings("hello from the hosting vat", arg.string);
        },
        .broken => return error.CallBroke,
    }
}

/// The one-call hosting convenience: `Server.accept` owns the partner's peer
/// and buffers, so the host accepts, publishes, and serves with the same
/// parity `connect` gives the client.
fn serveOnce(server: *driver.Server) anyerror!void {
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("greeter", HostedGreeter, .{});
    try session.serve();
}

test "driver loopback: connect and listen own peers and buffers, fetch + call round-trip in one call each" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, dial_opts);
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    var host_future = try io.concurrent(serveOnce, .{server});
    const client_result = connectOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

test "driver loopback: acceptVia publishes and serves the keyed session connectVia dials, fetch + call round-trip" {
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
    const loc = tcp.locatorFromAddress(&designator_buf, address);
    const uri = try model.uri.writePeer(allocator, loc);
    defer allocator.free(uri);

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var tcp_resident = pancake.net.tcp.plain.Resident{ .io = io };
    var cv = try driver.connectUri(allocator, &.{tcp_resident.netlayer()}, &peer, uri, .ephemeral, read_buf, write_buf, .{ .handshake = handshake_budget, .settle = dial_opts.settle });
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

    var cv = try connectPlain(allocator, io, &peer, address, read_buf, write_buf, .{ .handshake = handshake_budget, .settle = dial_opts.settle });
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
    pub fn handle(self: *LocalPing, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = self;
        _ = ht;
        _ = args;
        if (!std.mem.eql(u8, verb, "ping")) return error.NoSuchMethod;
        return .{ .string = "pong from this side" };
    }
};

/// `call` on a locally spawned capability: the promise settles in the
/// flush's local drive, so the call returns without the partner sending
/// anything after the handshake (the host publishes but is never fetched).
fn callLocalOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var tcp_resident = tcp.Resident{ .io = io };
    var buf: [64]u8 = undefined;
    var session = try driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.locatorFromAddress(&buf, address), .ephemeral, dial_opts);
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const cap = try session.spawn(LocalPing, .{});
    const settled = try session.call(cap, "ping", &.{}, arena_state.allocator());
    switch (settled) {
        .fulfilled => |arg| {
            try std.testing.expect(arg == .string);
            try std.testing.expectEqualStrings("pong from this side", arg.string);
        },
        .broken => return error.CallBroke,
    }
}

test "driver loopback: call on a locally spawned ref settles with no partner traffic" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, dial_opts);
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    var host_future = try io.concurrent(serveOnce, .{server});
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

    var cv = try acceptPlain(allocator, &peer, listener, read_buf, write_buf, .{ .handshake = handshake_budget, .settle = dial_opts.settle });
    defer cv.deinit();

    const cap = try cv.publish("greeter", Greeter, .{});

    // Pump until the client's deliver reaches the greeter's export, dropping
    // the event instead of serving it, the abort below is the only answer.
    outer: while (true) {
        while (cv.served.port.peer.pollEvent()) |event_value| {
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

    try cv.served.port.peer.sendCopying(.{ .abort = .{ .kind = .unauthorized, .message = abort_diagnostic } });
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

    var cv = try connectPlain(allocator, io, &peer, address, read_buf, write_buf, .{ .handshake = handshake_budget, .settle = dial_opts.settle });
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

    var tcp_resident = pancake.net.tcp.plain.Resident{ .io = io };

    // A syntactically valid URI naming a transport the slice does not host:
    // the dial refuses rather than silently falling back to tcp.
    try std.testing.expectError(
        driver.Error.UnknownTransport,
        driver.connectUri(allocator, &.{tcp_resident.netlayer()}, &peer, "ocapn://node123.quic", .ephemeral, &read_buf, &write_buf, .{ .handshake = handshake_budget, .settle = dial_opts.settle }),
    );
}

/// The grant-on-marshal fixture (ADR-0074): `make` spawns two capabilities and
/// marshals exactly one into its reply. The other's export position leaks only
/// as an integer, which is data, not authority.
const TwoSpawner = struct {
    pub fn handle(self: *TwoSpawner, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = self;
        _ = args;
        if (!std.mem.eql(u8, verb, "make")) return error.NoSuchMethod;
        const granted = try ht.spawn(HostedGreeter, .{});
        // The reserved one is deliberately minted at the wire tier: the test
        // needs its export position as bare data, which the opaque surface —
        // correctly — cannot say.
        const reserved = try driver.spawnAt(ht.turn, Greeter, .{});
        const items = try ht.turn.arena.alloc(driver.Value, 2);
        items[0] = .{ .capability = granted };
        items[1] = .{ .integer = @intCast(reserved.position) };
        return .{ .list = items };
    }
};

/// Host the factory and serve. The client's probe of the reserved position is
/// a protocol violation on this side: the session refuses it exactly like a
/// deliver to a nonexistent export, and the pump surfaces the typed abort.
fn serveGrantOnMarshalOnce(server: *driver.Server) anyerror!void {
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("factory", TwoSpawner, .{});
    try std.testing.expectError(error.ProtocolAbort, session.serve());
}

/// Fetch the factory, prove the marshaled capability answers, then probe the
/// reserved position learned out-of-band and prove it is unaddressable.
fn probeReservedOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var tcp_resident = tcp.Resident{ .io = io };
    var buf: [64]u8 = undefined;
    var session = try driver.connect(allocator, &.{tcp_resident.netlayer()}, tcp.locatorFromAddress(&buf, address), .ephemeral, dial_opts);
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const factory = try session.fetch("factory");
    const made = try session.call(factory, "make", &.{}, arena);
    try std.testing.expect(made == .fulfilled);
    const items = made.fulfilled.list;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expect(items[0] == .capability);
    const granted = items[0].capability;
    const reserved_position: u64 = @intCast(items[1].integer);

    // The capability that rode the reply is addressable: its marshal was the
    // grant, and the actor's turn runs.
    const greeted = try session.call(granted, "greet", &.{}, arena);
    try std.testing.expect(greeted == .fulfilled);

    // The reserved position — learned out-of-band, as a number — is not a
    // capability. Forging one takes two deliberate wire-tier escapes
    // (`peer().importObject` bookkeeping plus a raw core lift); the host still
    // refuses the deliver like a nonexistent export and tears the session
    // down, so the probe's vow breaks instead of reaching the actor.
    try session.peer().importObject(reserved_position);
    const forged = try session.runtime.core.liftCapability(session.hs, .{ .far = model.FarRef.object(reserved_position) });
    const probed = session.call(forged, "greet", &.{}, arena) catch |err| switch (err) {
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
    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = "127.0.0.1:0" }, .ephemeral, dial_opts);
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    var host_future = try io.concurrent(serveGrantOnMarshalOnce, .{server});
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
