//! Driver loopback: `driver.connect` and `driver.listen`
//! over a real 127.0.0.1 socket with the keyed, verified handshake on both
//! ends, the same exchange a live Goblins peer requires. Fetch, call,
//! pipelining, URIs, local spawns, ADR-0027's grant-on-first-marshal, the
//! callback-and-step pump through a small read buffer, and the transports
//! value's refusal each ride one test.

const std = @import("std");
const glowcap = @import("glowcap");
const support_actors = @import("../support/actors.zig");

const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

const ip = std.Io.net;

const frame_cap = 4096;

/// Session options for a real loopback dial. The budgets are finite: an
/// unbounded CapTP wait against a partner that goes quiet does not fail the
/// suite, it wedges the test binary, which reads as a hang rather than a bug.
const dial_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const greeting = "hello from the owning host";

/// The published actor: answers `greet(name)` with a static greeting.
const Greeter = support_actors.StaticReplyValueActor("greet", greeting);
/// The same greeter in the wire tier's `actors.Turn` form, for the one
/// scenario that mints an export by hand through `driver.spawnAt`.
const WireGreeter = support_actors.StaticReplyActor("greet", greeting);

/// Bind a listening server on an ephemeral loopback port and return its
/// address.
fn listenLoopback(allocator: std.mem.Allocator, io: std.Io) !*driver.Server {
    return driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, dial_opts);
}

fn serverAddress(server: *driver.Server) !ip.IpAddress {
    var addr_buf: [64]u8 = undefined;
    return tcp.parseDesignator(try server.localDesignator(&addr_buf));
}

/// Accept one partner, publish the greeter, and serve until the client
/// leaves, whether it closes cleanly or drops the socket once it has its
/// reply.
fn serveOnce(server: *driver.Server) anyerror!void {
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("greeter", Greeter, .{});
    try session.serve();
}

/// Fetch a name the host never published. The partner's bootstrap answers
/// with a break ("unknown swissnum"): `fetch` surfaces the distinguished
/// `Error.FetchBroken` rather than a flat failure that could also mean a
/// non-capability fulfillment, and `fetchSettled` carries the partner's break
/// reason whole in caller-owned memory.
fn fetchMissingOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    var session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&buf, address), .ephemeral, dial_opts);
    defer session.deinit();

    try std.testing.expectError(driver.Error.FetchBroken, session.fetch("nobody-published-this"));

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const reply = try session.fetchSettled("nobody-published-this-either", arena_state.allocator());
    switch (reply) {
        .fulfilled => return error.UnexpectedFulfillment,
        .broken => |reason| try std.testing.expectEqualStrings("unknown swissnum", reason),
    }
}

test "session: a fetch of an unpublished name surfaces Error.FetchBroken and fetchSettled carries the reason" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try listenLoopback(allocator, io);
    defer server.deinit();
    const address = try serverAddress(server);

    var host_future = try io.concurrent(serveOnce, .{server});
    const client_result = fetchMissingOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

/// Dial an `ocapn://` URI via `driver.connectUri`: build the URI for the
/// bound address, parse-and-dial it in one call against the runtime's
/// transports value, then fetch and call. The URI becomes a session with no
/// transport branch in the caller: the value decides.
fn dialUriOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const loc = tcp.locatorFromAddress(&designator_buf, address);
    const uri = try model.uri.writePeer(allocator, loc);
    defer allocator.free(uri);

    var session = try driver.connectUri(allocator, io, .{ .symbols = &.{.tcp} }, uri, .ephemeral, dial_opts);
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const greeter = try session.fetch("greeter");
    const reply = try session.call(greeter, "greet", &.{.{ .string = "glowcap" }}, arena_state.allocator());
    switch (reply) {
        .fulfilled => |arg| {
            try std.testing.expect(arg == .string);
            try std.testing.expectEqualStrings(greeting, arg.string);
        },
        .broken => return error.CallBroke,
    }
}

test "session: connectUri parses an ocapn:// URI and dials it through the runtime's transports" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try listenLoopback(allocator, io);
    defer server.deinit();
    const address = try serverAddress(server);

    var host_future = try io.concurrent(serveOnce, .{server});
    const client_result = dialUriOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

test "connectUri fails closed on a URI whose transport the runtime does not serve" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A syntactically valid URI naming a transport the value does not serve:
    // the dial refuses rather than silently falling back to tcp.
    try std.testing.expectError(
        error.UnknownTransport,
        driver.connectUri(allocator, io, .{ .symbols = &.{.tcp} }, "ocapn://node123.quic", .ephemeral, dial_opts),
    );
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
            .string => |text| std.mem.eql(u8, text, greeting),
            else => false,
        },
        .broken, .give => false,
    };
}

/// The callback pump: `send`, register `on`, and `step` until the listener
/// fires. The runtime's stream stack reads through a 64-byte buffer, far
/// smaller than any handshake frame, so every inbound frame on this side
/// assembles across reads, proving the small-buffer read path over a real
/// socket.
fn stepUntilReplyOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    const transports: driver.HostRuntime.Transports = .{
        .symbols = &.{.tcp},
        .stack = .{ .read_buffer_bytes = 64 },
    };
    var session = try driver.connect(allocator, io, transports, tcp.locatorFromAddress(&buf, address), .ephemeral, dial_opts);
    defer session.deinit();

    const greeter = try session.fetch("greeter");
    const promise = try session.send(greeter, "greet", &.{.{ .string = "glowcap" }});
    var state = ReplyState{};
    try promise.on(.{ .ctx = &state, .func = onGreeting });

    while (!state.done) {
        const progress = try session.step();
        if (progress == .closed) break;
    }

    try std.testing.expect(state.done);
    try std.testing.expect(state.ok);
}

test "session: send, on, and step deliver a reply through a 64-byte read buffer" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try listenLoopback(allocator, io);
    defer server.deinit();
    const address = try serverAddress(server);

    var host_future = try io.concurrent(serveOnce, .{server});
    const client_result = stepUntilReplyOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

/// The one-call client convenience: `driver.connect` owns the peer and
/// buffers, so the client connects, fetches, calls, and closes without peer
/// or buffer setup. `call` returns the settled outcome materialized into the
/// caller's arena, no ctx/callback dance.
fn connectOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    var session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&buf, address), .ephemeral, dial_opts);
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();

    const greeter = try session.fetch("greeter");
    const settled = try session.call(greeter, "greet", &.{.{ .string = "glowcap" }}, arena_state.allocator());
    switch (settled) {
        .fulfilled => |arg| {
            try std.testing.expect(arg == .string);
            try std.testing.expectEqualStrings(greeting, arg.string);
        },
        .broken => return error.CallBroke,
    }
}

test "driver loopback: connect and listen own peers and buffers, fetch + call round-trip in one call each" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try listenLoopback(allocator, io);
    defer server.deinit();
    const address = try serverAddress(server);

    var host_future = try io.concurrent(serveOnce, .{server});
    const client_result = connectOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

/// The taskboard shapes the pipelining test drives: a board whose `create`
/// mints a fresh task capability, and a task that answers `assign`/`complete`/
/// `status`. The same shape `bench/langs/host.zig` serves. Here it proves the
/// questioner-side pipelining path end to end.
const Task = struct {
    done: bool = false,
    pub fn handle(self: *Task, ht: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
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
    pub fn handle(self: *Board, ht: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
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
/// that settle, none waits for `create` to come back, so the host queues the
/// three pipelined calls on its pending answer and drains them onto the freshly
/// spawned task when `create` resolves (ADR-0003's serving half). A correct
/// `status` of `done` proves the questioner half end to end: a dependent chain
/// crossed the wire as one batch, not four round trips.
fn pipelineUnitOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    var session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&buf, address), .ephemeral, dial_opts);
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

    var server = try listenLoopback(allocator, io);
    defer server.deinit();
    const address = try serverAddress(server);

    var host_future = try io.concurrent(serveBoardOnce, .{server});
    const client_result = pipelineUnitOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

/// The locally spawned actor for the local-call test: replies from its own
/// state, so settling it needs no partner traffic at all.
const LocalPing = struct {
    pub fn handle(self: *LocalPing, ht: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
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
    var buf: [64]u8 = undefined;
    var session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&buf, address), .ephemeral, dial_opts);
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

    var server = try listenLoopback(allocator, io);
    defer server.deinit();
    const address = try serverAddress(server);

    var host_future = try io.concurrent(serveOnce, .{server});
    const client_result = callLocalOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

/// The grant-on-marshal fixture (ADR-0027): `make` spawns two capabilities and
/// marshals exactly one into its reply. The other's export position leaks only
/// as an integer, which is data, not authority.
const TwoSpawner = struct {
    pub fn handle(self: *TwoSpawner, ht: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
        _ = self;
        _ = args;
        if (!std.mem.eql(u8, verb, "make")) return error.NoSuchMethod;
        const granted = try ht.spawn(Greeter, .{});
        // The reserved one is minted at the wire tier: the test
        // needs its export position as bare data, which the opaque surface,
        // correctly, cannot say.
        const reserved = try driver.spawnAt(ht.turn, WireGreeter, .{});
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
    var buf: [64]u8 = undefined;
    var session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&buf, address), .ephemeral, dial_opts);
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

    // The reserved position, learned out-of-band, as a number, is not a
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

test "driver loopback: a spawned capability is unreachable until first marshaled (ADR-0027)" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try listenLoopback(allocator, io);
    defer server.deinit();
    const address = try serverAddress(server);

    var host_future = try io.concurrent(serveGrantOnMarshalOnce, .{server});
    const client_result = probeReservedOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

test "Identity.ephemeral signs the unreachable-client designator" {
    // The same bytes a Host advertises for an ephemeral dialer: the
    // placeholder must not drift by entry path.
    const identity: driver.Identity = .ephemeral;
    try std.testing.expectEqualStrings(
        driver.unreachable_client_designator,
        identity.dialedDesignator(),
    );
}

/// Answers `read(capability)` with the kind of capability the Host handed it,
/// a lifted promise or a settled object, and `echo(capability)` with the
/// capability itself.
const CapabilityKindReader = struct {
    pub fn handle(_: *@This(), ht: *driver.HostTurn, verb: []const u8, args: driver.Args) !driver.Value {
        if (std.mem.eql(u8, verb, "echo")) return .{ .capability = try args.capability(0) };
        if (!std.mem.eql(u8, verb, "read")) return error.NoSuchMethod;
        const cap = try args.capability(0);
        defer ht.releaseValues(&.{.{ .capability = cap }});
        const kind: []const u8 = switch (ht.host.capabilities.resolve(cap) orelse return error.UnknownCapability) {
            .deferred => "promise",
            .local, .remote => "object",
        };
        return .{ .string = kind };
    }
};

/// Accept one partner, publish the greeter beside the kind reader, and serve
/// until the client leaves.
fn serveKindReaderOnce(server: *driver.Server) anyerror!void {
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("greeter", Greeter, .{});
    _ = try session.publish("reader", CapabilityKindReader, .{});
    try session.serve();
}

/// Pass a promise as a capability argument: the reader sees a promise, the
/// minted capability is released, and the promise still settles to its reply.
fn passPromiseOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    var session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&buf, address), .ephemeral, dial_opts);
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const greeter = try session.fetch("greeter");
    const reader = try session.fetch("reader");
    const pending = try session.send(greeter, "greet", &.{});
    const as_capability = try pending.capability();
    const kind = session.call(reader, "read", &.{.{ .capability = as_capability }}, arena);
    try session.release(as_capability);
    switch (try kind) {
        .fulfilled => |arg| {
            try std.testing.expect(arg == .string);
            try std.testing.expectEqualStrings("promise", arg.string);
        },
        .broken => return error.CallBroke,
    }
    switch (try pending.settle(arena)) {
        .fulfilled => |arg| {
            try std.testing.expect(arg == .string);
            try std.testing.expectEqualStrings(greeting, arg.string);
        },
        .broken => return error.CallBroke,
    }
}

test "session: a promise passes as a capability argument and still settles" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try listenLoopback(allocator, io);
    defer server.deinit();
    const address = try serverAddress(server);

    var host_future = try io.concurrent(serveKindReaderOnce, .{server});
    const client_result = passPromiseOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

/// A reply naming a capability arrives while another call pumps, so no
/// listener sees it. `settle` reads it from the vow row afterward, and the
/// capability it names is still live.
fn settleUnobservedCapabilityOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    var session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&buf, address), .ephemeral, dial_opts);
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const greeter = try session.fetch("greeter");
    const reader = try session.fetch("reader");
    const echoed = try session.send(reader, "echo", &.{.{ .capability = greeter }});
    // The pump inside this call drains the echo reply with no listener on it.
    switch (try session.call(reader, "read", &.{.{ .capability = greeter }}, arena)) {
        .fulfilled => |arg| try std.testing.expectEqualStrings("object", arg.string),
        .broken => return error.CallBroke,
    }
    const greeter_again = switch (try echoed.settle(arena)) {
        .fulfilled => |arg| switch (arg) {
            .capability => |cap| cap,
            else => return error.WrongReplyShape,
        },
        .broken => return error.CallBroke,
    };
    // The same promise settles once.
    try std.testing.expectError(error.NoSuchVow, echoed.settle(arena));
    try session.release(greeter);
    switch (try session.call(greeter_again, "greet", &.{}, arena)) {
        .fulfilled => |arg| try std.testing.expectEqualStrings(greeting, arg.string),
        .broken => return error.CallBroke,
    }
    try session.release(greeter_again);
}

test "session: a promise reply naming a capability survives an unobserved drain" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try listenLoopback(allocator, io);
    defer server.deinit();
    const address = try serverAddress(server);

    var host_future = try io.concurrent(serveKindReaderOnce, .{server});
    const client_result = settleUnobservedCapabilityOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}
