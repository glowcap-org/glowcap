//! The native three-party handoff, hermetic: three `driver.Host`s — an
//! exporter, a gifter, and a recipient — run the complete gifter-and-recipient
//! choreography over real loopback TCP sockets, no hand-built wire messages.
//! The gifter's published introducer simply *returns* the foreign capability
//! it fetched; the host's resolve interceptor turns that reply into a signed
//! give (deposit on the exporter leg, give to the caller), the recipient's
//! call settles as the typed `.give`, `Host.redeem` dials the exporter and
//! withdraws, and the routed call reaches the object directly. The exporter
//! serves both of its connections from one thread with `stepReadable`: a
//! withdraw that beats its deposit parks on the peer and settles when the
//! deposit lands (ADR-0056), which is what makes single-owner round-robin
//! serving correct. The live twins are `zig build goblins-handoff` (recipient
//! half against real Goblins) and `zig build deno-gifter-handoff` (all three
//! parties in the Deno binding).

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const tcp = net.tcp;

const frame_cap = 4096;

/// The gifted object, published by the exporter on every connection.
const Widget = struct {
    pub fn handle(self: *Widget, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "poke")) return error.NoSuchMethod;
        return .{ .string = "poked directly at the exporter" };
    }
};

/// The gifter's introducer: replies with the foreign capability it holds. The
/// host's interceptor is what turns this ordinary-looking reply into a give.
const Introducer = struct {
    widget: actors.Ref,
    pub fn handle(self: *Introducer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "introduce")) return error.NoSuchMethod;
        return .{ .reference = .{ .far = self.widget.far } };
    }
};

/// One published bound address, written once by its listener's task and
/// spin-read by the task that dials it.
const Addr = struct {
    buf: [64]u8 = undefined,
    len: std.atomic.Value(usize) = .init(0),

    fn publish(self: *Addr, designator: []const u8) void {
        @memcpy(self.buf[0..designator.len], designator);
        self.len.store(designator.len, .release);
    }
    fn await_(self: *Addr, io: std.Io) []const u8 {
        while (true) {
            const n = self.len.load(.acquire);
            if (n != 0) return self.buf[0..n];
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2), .real) catch {};
        }
    }
};

const Shared = struct {
    exporter_addr: Addr = .{},
    gifter_addr: Addr = .{},
    gifter_fetched: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
};

/// The exporter: publish the widget on each accepted connection, serve the
/// gifter's leg until its fetch landed, then accept the recipient's redeem
/// dial and round-robin both legs — the deposit (gifter leg) and the parked
/// withdraw (recipient leg) settle in whichever order they arrive.
fn exporterTask(allocator: std.mem.Allocator, shared: *Shared) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };
    var host = driver.Host.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x0e} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();
    var server = try host.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    shared.exporter_addr.publish(server.localDesignator(&addr_buf));
    const to_gifter = try server.accept();
    _ = try to_gifter.publish("widget", Widget, .{});
    while (!shared.gifter_fetched.load(.acquire)) {
        _ = try to_gifter.stepReadable(10);
    }
    const to_recipient = try server.accept();
    _ = try to_recipient.publish("widget", Widget, .{});
    while (!shared.done.load(.acquire)) {
        _ = try to_gifter.stepReadable(5);
        _ = try to_recipient.stepReadable(5);
    }
}

/// The gifter: fetch the widget from the exporter (its foreign home is
/// recorded by `fetch`), publish the introducer that hands it back, and serve
/// the recipient. The origination fires inside the serve, in the interceptor.
fn gifterTask(allocator: std.mem.Allocator, shared: *Shared) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };
    var host = driver.Host.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x06} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();

    const to_exporter = try host.dial(.{
        .transport = tcp.transport_name,
        .designator = shared.exporter_addr.await_(io),
        .hints = model.Hints.emptyFalse(),
    });
    const widget = try to_exporter.fetch("widget");
    shared.gifter_fetched.store(true, .release);

    var server = try host.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    shared.gifter_addr.publish(server.localDesignator(&addr_buf));
    const to_recipient = try server.accept();
    _ = try to_recipient.publish("introducer", Introducer, .{ .widget = widget });
    while (!shared.done.load(.acquire)) {
        _ = try to_recipient.stepReadable(5);
        // The deposit leg the interceptor flushed needs its socket serviced
        // too, so the exporter's ack and any parked traffic keep moving.
        _ = try to_exporter.stepReadable(5);
    }
}

test "three hosts run the full three-party handoff hermetically: originate, give, redeem, direct call" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var shared = Shared{};
    var exporter_future = try io.concurrent(exporterTask, .{ allocator, &shared });
    var gifter_future = try io.concurrent(gifterTask, .{ allocator, &shared });
    // Whatever happens, unblock the serving tasks before awaiting them.
    defer {
        shared.done.store(true, .release);
        const e = exporter_future.await(io);
        const g = gifter_future.await(io);
        e catch |err| std.debug.print("exporter task: {s}\n", .{@errorName(err)});
        g catch |err| std.debug.print("gifter task: {s}\n", .{@errorName(err)});
    }

    var resident = tcp.Resident{ .io = io };
    var host = driver.Host.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x0c} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();
    const to_gifter = try host.dial(.{
        .transport = tcp.transport_name,
        .designator = shared.gifter_addr.await_(io),
        .hints = model.Hints.emptyFalse(),
    });
    const introducer = try to_gifter.fetch("introducer");

    // The introduction: an ordinary call whose answer settles as the typed
    // third outcome, carrying the verbatim signed give.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const settled = try to_gifter.call(introducer, .{ .verb = "introduce", .args = &.{} }, arena.allocator());
    const give = switch (settled) {
        .give => |g| g,
        .fulfilled => return error.ExpectedGive,
        .broken => |reason| {
            std.debug.print("introduce broke: {s}\n", .{reason});
            return error.ExpectedGive;
        },
    };
    try std.testing.expect(give.give_bytes.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, give.exporter_locator_uri, "127.0.0.1") != null);

    // Redeem dials the exporter directly and withdraws; the returned ref
    // routes through the node to the fresh exporter connection.
    const widget = try host.redeem(to_gifter, give);
    const reply = try to_gifter.call(widget, .{ .verb = "poke", .args = &.{} }, arena.allocator());
    switch (reply) {
        .fulfilled => |arg| try std.testing.expectEqualStrings("poked directly at the exporter", arg.string),
        .broken => |reason| {
            std.debug.print("poke broke: {s}\n", .{reason});
            return error.PokeBroke;
        },
        .give => return error.ExpectedValue,
    }
}

// A crossed-hellos collision, staged deterministically and asserted from the
// wire (ADR-0030): host B has an outbound dial to A registered (bytes not yet
// moving) when A's dial arrives at B's listener. B's accepted connection
// compares the two public identifiers and either aborts its inbound (B not the
// lower key) or keeps it and marks its own outbound lost (B strictly lower). We
// run both key orderings — swapping the seeds flips the tiebreak — so each
// branch of the comparison executes, and we assert the observable outcome
// rather than only the registry's flag:
//
//   * B not lower: the typed `crossed_hellos` abort crosses the wire to A's
//     dialed connection, and B did not flag its own outbound.
//   * B lower: B flagged its outbound and its accepted inbound carries no
//     abort.
//
// What stays out of hermetic reach here: B's outbound is registered but never
// actually dialed, so `maybeAbortOutbound`'s wire emission and a call over the
// higher-keyed peer's surviving session need a genuinely concurrent dual real
// dial — racy on live sockets. Those are proven by the live handoff and interop
// steps; this test pins the sans-io tiebreak and the inbound-abort emission.

/// Stage the collision for one key ordering (host A holds `seed_a`, host B holds
/// `seed_b`) and assert the observable outcome. A must dial and B must accept
/// concurrently, because A's dial blocks on the handshake B completes in accept.
fn runCrossedHellos(
    allocator: std.mem.Allocator,
    io: std.Io,
    seed_a: [32]u8,
    seed_b: [32]u8,
) !void {
    const crypto = pancake.foundation.crypto;
    var resident = tcp.Resident{ .io = io };

    var host_a = driver.Host.initSeeded(allocator, io, &.{resident.netlayer()}, seed_a, .{ .frame_cap = frame_cap });
    defer host_a.deinit();
    var host_b = driver.Host.initSeeded(allocator, io, &.{resident.netlayer()}, seed_b, .{ .frame_cap = frame_cap });
    defer host_b.deinit();

    // Both hosts listen: each signs its real bound address into its dials,
    // which is the key the partner's registry compares against.
    var server_a = try host_a.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server_a.close();
    var server_b = try host_b.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server_b.close();
    var a_addr_buf: [64]u8 = undefined;
    const a_designator = server_a.localDesignator(&a_addr_buf);
    var b_addr_buf: [64]u8 = undefined;
    const b_designator = server_b.localDesignator(&b_addr_buf);

    // B's outbound to A is registered before its bytes move: the window a
    // crossed inbound must land in.
    const b_pid = crypto.derivePublicIdentifier(crypto.SecretKey.fromSeed(seed_b).publicKey());
    try host_b.hellos.registerOutbound(io, allocator, a_designator, b_pid);
    defer host_b.hellos.unregister(io, allocator, a_designator);

    // A dials B; A's start-session names A's bound address.
    var accept_future = try io.concurrent(acceptOne, .{&server_b});
    const a_to_b = try host_a.dial(.{
        .transport = tcp.transport_name,
        .designator = b_designator,
        .hints = model.Hints.emptyFalse(),
    });
    const accepted = try accept_future.await(io);
    // The handshake completed inside accept, but the queued start-session
    // event reaches B's inbound hook on the first drain, where the tiebreak runs.
    try accepted.cv.flush();

    // The tiebreak is the byte order of the two public identifiers, computed
    // here the same way the registry computes it.
    const a_pid = crypto.derivePublicIdentifier(crypto.SecretKey.fromSeed(seed_a).publicKey());
    const b_is_lower = std.mem.order(u8, &b_pid.bytes, &a_pid.bytes) == .lt;

    if (b_is_lower) {
        // B keeps its inbound and flags its own (here un-dialed) outbound as the
        // loser. No abort touches either real connection.
        try std.testing.expect(host_b.hellos.shouldAbortOutbound(io, a_designator));
        try std.testing.expect(accepted.cv.abortReason() == null);
    } else {
        // B is not lower: it aborts its inbound, and the typed abort crosses the
        // wire to A. Read it off A's dialed connection; the abort is already
        // flushed toward A, so a bounded step loop surfaces it on loopback.
        try std.testing.expect(!host_b.hellos.shouldAbortOutbound(io, a_designator));
        var polls: usize = 0;
        while (a_to_b.cv.abortReason() == null and polls < 100) : (polls += 1) {
            _ = a_to_b.cv.stepReadable(20) catch break;
        }
        const info = a_to_b.cv.last_abort orelse return error.NoCrossedHellosAbort;
        try std.testing.expectEqual(model.AbortKind.crossed_hellos, info.kind);
        try std.testing.expect(std.mem.indexOf(u8, a_to_b.cv.abortReason().?, "crossed hellos") != null);
    }
}

test "a crossed inbound start-session is resolved by public-identifier order, aborting the not-lower side's inbound over the wire" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Two fixed seeds hash to two distinct public identifiers with one byte
    // order; swapping which host holds which seed flips that order, so the two
    // runs together drive both branches of the tiebreak deterministically.
    const seed_a = [_]u8{0x0a} ** 32;
    const seed_b = [_]u8{0x0b} ** 32;
    try runCrossedHellos(allocator, io, seed_a, seed_b);
    try runCrossedHellos(allocator, io, seed_b, seed_a);
}

fn acceptOne(server: *driver.host.HostServer) anyerror!*driver.HostConnection {
    return server.accept();
}

// Tearing down a `HostConnection` retires it from the shared node, which queues
// fail-closed actions for the withdraws that connection was carrying — actions
// that break *other* connections' answers and belong to the redeem driver, not
// to teardown. `deinit` must leave the shared action queue untouched: a
// pop-and-discard there would eat a settle a redeem still in flight needs, or
// strand a sibling's fail. Here a dial action staged the way a redeem stages it
// must survive the close.
test "closing a host connection leaves queued node actions on the shared queue for the driver" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };

    var host_a = driver.Host.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x1a} ** 32, .{ .frame_cap = frame_cap });
    defer host_a.deinit();
    var host_b = driver.Host.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x1b} ** 32, .{ .frame_cap = frame_cap });
    defer host_b.deinit();

    var server_b = try host_b.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server_b.close();
    var b_addr_buf: [64]u8 = undefined;
    const b_designator = server_b.localDesignator(&b_addr_buf);

    var accept_future = try io.concurrent(acceptOne, .{&server_b});
    const a_to_b = try host_a.dial(.{
        .transport = tcp.transport_name,
        .designator = b_designator,
        .hints = model.Hints.emptyFalse(),
    });
    _ = try accept_future.await(io);

    // Stage a non-fail node action the way a redeem does: a give whose exporter
    // is not yet connected becomes a `dial` action on the shared queue.
    try host_a.node.acceptGive(a_to_b.conn_id, 42, "give-bytes", "ocapn://127.0.0.1%3A9.tcp");

    // Close the connection. Under a pop-and-discard teardown the queued dial is
    // eaten here; it must instead stay for the driver to consume.
    a_to_b.deinit();

    const action = host_a.node.nextAction() orelse return error.QueuedActionWasEaten;
    try std.testing.expect(action == .dial);
}

/// A counter the server publishes so the client can `send` to it and settle the
/// returned promise through node routing.
const Counter = struct {
    n: i64,
    pub fn handle(self: *Counter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "add")) return error.NoSuchMethod;
        self.n += msg.arg(0).integer;
        return .{ .integer = self.n };
    }
};

const CounterServer = struct {
    addr: Addr = .{},
    done: std.atomic.Value(bool) = .init(false),
};

/// Host, publish a counter on the accepted connection, and round-robin it until
/// the client leaves.
fn counterServerTask(allocator: std.mem.Allocator, shared: *CounterServer) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };
    var host = driver.Host.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x2a} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();
    var server = try host.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    shared.addr.publish(server.localDesignator(&addr_buf));
    const conn = try server.accept();
    _ = try conn.publish("counter", Counter, .{ .n = 0 });
    while (!shared.done.load(.acquire)) {
        _ = conn.stepReadable(5) catch break;
    }
}

// `HostConnection.send` returns a promise homed on the routed connection's vat;
// `settlePromise` re-routes the same target to drive that connection to the
// settlement. An ordinary far reference routes back to this connection, so the
// split send/settle round-trips the reply the fused `call` would have returned.
test "HostConnection.send then settlePromise round-trips through node routing" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var shared = CounterServer{};
    var server_future = try io.concurrent(counterServerTask, .{ allocator, &shared });
    defer {
        shared.done.store(true, .release);
        server_future.await(io) catch |err| std.debug.print("counter server: {s}\n", .{@errorName(err)});
    }

    var resident = tcp.Resident{ .io = io };
    var host = driver.Host.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x2c} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();
    const to_server = try host.dial(.{
        .transport = tcp.transport_name,
        .designator = shared.addr.await_(io),
        .hints = model.Hints.emptyFalse(),
    });
    const counter = try to_server.fetch("counter");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const promise = try to_server.send(counter, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });
    const settled = try to_server.settlePromise(counter, promise, arena.allocator());
    switch (settled) {
        .fulfilled => |arg| try std.testing.expectEqual(@as(i64, 5), arg.integer),
        .broken => |reason| {
            std.debug.print("add broke: {s}\n", .{reason});
            return error.AddBroke;
        },
        .give => return error.ExpectedValue,
    }
}
