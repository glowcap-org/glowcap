//! The native three-party handoff, hermetic: three `driver.BlockingHost`s —
//! an exporter, a gifter, and a recipient — run the complete
//! gifter-and-recipient choreography over real loopback TCP sockets, no
//! hand-built wire messages. The gifter's published introducer simply
//! *returns* the foreign capability it fetched; the host core's resolve
//! interceptor turns that reply into a signed give (deposit on the exporter
//! leg, give to the caller), and the recipient's host claims the give and
//! redeems it inside the blocking call — the core's `dial` action becomes a
//! real dial, the withdraw settles over the fresh leg — so the call settles
//! directly with a routable reference and the routed poke reaches the object.
//! The exporter serves both of its connections from one thread with
//! `stepReadable`: a withdraw that beats its deposit parks on the peer and
//! settles when the deposit lands (ADR-0056), which is what makes
//! single-owner round-robin serving correct. The live twins are `zig build
//! goblins-handoff` (recipient half against real Goblins) and `zig build
//! deno-gifter-handoff` (all three parties in the Deno binding).

const std = @import("std");
const pancake = @import("pancake");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const tcp = net.tcp;
const wait = @import("../support/wait.zig");

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
/// host core's interceptor is what turns this ordinary-looking reply into a
/// give.
const Introducer = struct {
    widget: model.Reference,
    pub fn handle(self: *Introducer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "introduce")) return error.NoSuchMethod;
        return .{ .reference = self.widget };
    }
};

/// One published bound address, written once by its listener's task and
/// spin-read by the task that dials it.
const Addr = wait.PublishedAddr;

const Shared = struct {
    exporter_addr: Addr = .{},
    gifter_addr: Addr = .{},
    gifter_fetched: std.atomic.Value(bool) = .init(false),
    /// Set by the dead-exporter scenario once its first introduction settled;
    /// the happy-path scenario never sets it.
    first_redeem_done: std.atomic.Value(bool) = .init(false),
    /// Set by the dead-exporter scenario's exporter once it has closed its
    /// redeem leg — the happens-before edge the second introduction waits on,
    /// so the test cannot race the close against the second introduce.
    exporter_closed: std.atomic.Value(bool) = .init(false),
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
    var host = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x0e} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();
    var server = try host.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    shared.exporter_addr.publish(server.localDesignator(&addr_buf));
    const to_gifter = try server.accept();
    _ = try to_gifter.publish("widget", Widget, .{});
    const shared_gifter_fetched_deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!shared.gifter_fetched.load(.acquire)) {
        if (wait.expired(io, shared_gifter_fetched_deadline)) return error.WaitTimedOut;
        _ = try to_gifter.stepReadable(10);
    }
    const to_recipient = try server.accept();
    _ = try to_recipient.publish("widget", Widget, .{});
    const shared_done_deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!shared.done.load(.acquire)) {
        if (wait.expired(io, shared_done_deadline)) return error.WaitTimedOut;
        _ = try to_gifter.stepReadable(5);
        _ = try to_recipient.stepReadable(5);
    }
}

/// The gifter: fetch the widget from the exporter (its foreign home is
/// recorded by `fetch`), publish the introducer that hands it back, and serve
/// the recipient. The origination fires inside the serve, in the core's
/// interceptor. Shared by the happy-path and dead-exporter scenarios: the
/// gifter's role is identical in both.
fn gifterTask(allocator: std.mem.Allocator, shared: *Shared) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };
    var host = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x06} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();

    const to_exporter = try host.dial(.{
        .transport = tcp.transport_name,
        .designator = try shared.exporter_addr.await_(io, wait.default_deadline_ms),
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
    const shared_done_deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!shared.done.load(.acquire)) {
        if (wait.expired(io, shared_done_deadline)) return error.WaitTimedOut;
        _ = try to_recipient.stepReadable(5);
        // The deposit leg the interceptor flushed needs its socket serviced
        // too, so the exporter's ack and any parked traffic keep moving.
        _ = try to_exporter.stepReadable(5);
    }
}

test "three hosts run the full three-party handoff hermetically: originate, give, auto-redeem, direct call" {
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
    var host = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x0c} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();
    const to_gifter = try host.dial(.{
        .transport = tcp.transport_name,
        .designator = try shared.gifter_addr.await_(io, wait.default_deadline_ms),
        .hints = model.Hints.emptyFalse(),
    });
    const introducer = try to_gifter.fetch("introducer");

    // The introduction: an ordinary call. The gifter's reply is a signed give;
    // the recipient's host claims it and redeems it inside this wait — the
    // core's dial action opens the exporter leg, the withdraw settles over it —
    // so the call settles directly with the routable reference.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const settled = try to_gifter.call(introducer, .{ .verb = "introduce", .args = &.{} }, arena.allocator());
    const widget = switch (settled) {
        .fulfilled => |arg| switch (arg) {
            .reference => |reference| reference,
            else => return error.ExpectedReference,
        },
        .broken => |reason| {
            std.debug.print("introduce broke: {s}\n", .{reason});
            return error.IntroduceBroke;
        },
        .give => return error.GiveShouldHaveBeenRedeemed,
    };
    // The redeemed capability arrives as a node-unique routing token.
    try std.testing.expect(widget == .far);
    try std.testing.expect(widget.far.import_position.int() >= pancake.ocapn.engine.Node.REDEEMED_TOKEN_BASE);

    // The direct call: the token routes through the node to the fresh
    // exporter connection; the gifter is out of the path.
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

/// The exporter arm of the dead-exporter scenario: serve the first redeem
/// normally, then close the redeem leg — so the recipient's second
/// introduction finds the node's cached exporter connection pointing at a
/// partner that is gone — and keep the gifter leg alive so the second deposit
/// still lands.
fn exporterDiesTask(allocator: std.mem.Allocator, shared: *Shared) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };
    var host = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x1e} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();
    var server = try host.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    shared.exporter_addr.publish(server.localDesignator(&addr_buf));
    const to_gifter = try server.accept();
    _ = try to_gifter.publish("widget", Widget, .{});
    const shared_gifter_fetched_deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!shared.gifter_fetched.load(.acquire)) {
        if (wait.expired(io, shared_gifter_fetched_deadline)) return error.WaitTimedOut;
        _ = try to_gifter.stepReadable(10);
    }
    const to_recipient = try server.accept();
    _ = try to_recipient.publish("widget", Widget, .{});
    const shared_first_redeem_done_deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!shared.first_redeem_done.load(.acquire)) {
        if (wait.expired(io, shared_first_redeem_done_deadline)) return error.WaitTimedOut;
        _ = try to_gifter.stepReadable(5);
        _ = try to_recipient.stepReadable(5);
    }
    // The exporter leaves: close the redeem leg while the recipient's node
    // still holds it in the exporter cache. The flag is the happens-before
    // edge the recipient's second introduction waits on.
    to_recipient.deinit();
    shared.exporter_closed.store(true, .release);
    const shared_done_deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!shared.done.load(.acquire)) {
        if (wait.expired(io, shared_done_deadline)) return error.WaitTimedOut;
        _ = try to_gifter.stepReadable(5);
    }
}

test "an introduction whose cached exporter died settles broken and evicts the cache for a re-dial" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var shared = Shared{};
    var exporter_future = try io.concurrent(exporterDiesTask, .{ allocator, &shared });
    var gifter_future = try io.concurrent(gifterTask, .{ allocator, &shared });
    defer {
        shared.done.store(true, .release);
        shared.first_redeem_done.store(true, .release);
        const e = exporter_future.await(io);
        const g = gifter_future.await(io);
        e catch |err| std.debug.print("exporter task: {s}\n", .{@errorName(err)});
        g catch |err| std.debug.print("gifter task: {s}\n", .{@errorName(err)});
    }

    var resident = tcp.Resident{ .io = io };
    var host = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x1c} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();
    const to_gifter = try host.dial(.{
        .transport = tcp.transport_name,
        .designator = try shared.gifter_addr.await_(io, wait.default_deadline_ms),
        .hints = model.Hints.emptyFalse(),
    });
    const introducer = try to_gifter.fetch("introducer");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // The first handoff runs whole: the auto-redeem dials the exporter and
    // the node caches that connection for the give's locator.
    const settled1 = try to_gifter.call(introducer, .{ .verb = "introduce", .args = &.{} }, arena.allocator());
    switch (settled1) {
        .fulfilled => |arg| try std.testing.expect(arg == .reference),
        else => return error.ExpectedReference,
    }
    try std.testing.expectEqual(@as(usize, 1), host.core.node.exporters.count());
    shared.first_redeem_done.store(true, .release);
    try wait.untilFlag(io, wait.default_deadline_ms, &shared.exporter_closed);

    // The second handoff meets a cached exporter connection whose partner is
    // gone. The withdraw fails closed — the introduction settles broken —
    // and the failed leg's teardown must evict the cache row, so a later
    // introduction for this exporter re-dials instead of failing against the
    // dead row forever.
    const settled2 = try to_gifter.call(introducer, .{ .verb = "introduce", .args = &.{} }, arena.allocator());
    switch (settled2) {
        .broken => {},
        else => return error.ExpectedBrokenIntroduction,
    }
    try std.testing.expectEqual(@as(usize, 0), host.core.node.exporters.count());
}

// A crossed-hellos collision, staged deterministically and asserted from the
// wire (ADR-0030): host B has an outbound dial to A registered (bytes not yet
// moving) when A's dial arrives at B's listener. B's accepted connection
// compares the two public identifiers and either condemns its inbound (B not
// the lower key) or keeps it (B strictly lower — with the outbound registered
// but never dialed, there is no dialed connection to condemn). We run both
// key orderings — swapping the seeds flips the tiebreak — so each branch of
// the comparison executes, and we assert the observable outcome:
//
//   * B not lower: the accepted connection comes back condemned and the typed
//     `crossed_hellos` abort crosses the wire to A's dialed connection.
//   * B lower: the accepted connection is kept and no abort touches either
//     side.
//
// What stays out of hermetic reach here: a genuinely concurrent dual real
// dial — racy on live sockets — is proven by the live handoff and interop
// steps; this test pins the tiebreak verdict and the inbound-abort emission
// over a real wire.

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

    var host_a = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, seed_a, .{ .frame_cap = frame_cap });
    defer host_a.deinit();
    var host_b = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, seed_b, .{ .frame_cap = frame_cap });
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
    try host_b.core.hellos.registerOutbound(allocator, a_designator, b_pid);
    defer host_b.core.hellos.unregister(allocator, a_designator);

    // A dials B; A's start-session names A's bound address. The tiebreak runs
    // inside B's accept, where the inbound start-session is served.
    var accept_future = try io.concurrent(acceptOne, .{&server_b});
    const a_to_b = try host_a.dial(.{
        .transport = tcp.transport_name,
        .designator = b_designator,
        .hints = model.Hints.emptyFalse(),
    });
    const accepted = try accept_future.await(io);

    // The tiebreak is the byte order of the two public identifiers, computed
    // here the same way the registry computes it.
    const a_pid = crypto.derivePublicIdentifier(crypto.SecretKey.fromSeed(seed_a).publicKey());
    const b_is_lower = std.mem.order(u8, &b_pid.bytes, &a_pid.bytes) == .lt;

    if (b_is_lower) {
        // B keeps its inbound; its registered (never-dialed) outbound is the
        // loser, and no abort touches either real connection.
        try std.testing.expect(!accepted.core.condemned);
        try std.testing.expect(accepted.abortReason() == null);
    } else {
        // B is not lower: its accepted connection comes back condemned with
        // the typed abort already flushed toward A. Read it off A's dialed
        // connection; a bounded step loop surfaces it on loopback.
        try std.testing.expect(accepted.core.condemned);
        var polls: usize = 0;
        while (a_to_b.abortReason() == null and polls < 100) : (polls += 1) {
            _ = a_to_b.stepReadable(20) catch break;
        }
        const info = a_to_b.core.served.last_abort orelse return error.NoCrossedHellosAbort;
        try std.testing.expectEqual(model.AbortKind.crossed_hellos, info.kind);
        try std.testing.expect(std.mem.indexOf(u8, a_to_b.abortReason().?, "crossed hellos") != null);
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

fn acceptOne(server: *driver.BlockingHost.Server) anyerror!*driver.BlockingHost.Connection {
    return server.accept();
}

// Tearing down a `HostConnection` retires it from the shared node, which
// queues fail-closed work for the withdraws that connection was carrying —
// work that belongs to the embedder's action loop, not to teardown. `deinit`
// must leave that work on the core's action queue: a pop-and-execute (or
// pop-and-discard) there would run a dial inside a teardown or eat a sibling's
// completion. Here a dial staged the way an auto-redeem stages it must survive
// the close and pop from the action queue afterwards.
test "closing a host connection leaves queued core actions for the action loop" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };

    var host_a = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x1a} ** 32, .{ .frame_cap = frame_cap });
    defer host_a.deinit();
    var host_b = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x1b} ** 32, .{ .frame_cap = frame_cap });
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

    // Stage a dial the way an auto-redeem does: a give whose exporter is not
    // yet connected becomes a dial the core hands the embedder.
    try host_a.core.node.acceptGive(a_to_b.conn_id, 42, "give-bytes", "ocapn://127.0.0.1%3A9.tcp");

    // Close the connection. The staged dial must come out of the action queue
    // afterwards, not be executed or eaten inside the teardown.
    a_to_b.deinit();

    var found_dial = false;
    while (try host_a.core.nextAction()) |action| {
        if (action == .dial) {
            found_dial = true;
            break;
        }
    }
    try std.testing.expect(found_dial);
}

/// A counter the server publishes so the client can `send` to it and settle the
/// returned vow through node routing.
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
    var host = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x2a} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();
    var server = try host.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    shared.addr.publish(server.localDesignator(&addr_buf));
    const conn = try server.accept();
    _ = try conn.publish("counter", Counter, .{ .n = 0 });
    const shared_done_deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!shared.done.load(.acquire)) {
        if (wait.expired(io, shared_done_deadline)) return error.WaitTimedOut;
        _ = conn.stepReadable(5) catch break;
    }
}

// `HostConnection.send` mints a host vow id and puts the deliver on the wire;
// `settleVow` blocks on that id later, collecting a completion that settled
// in the meantime from the parked table. The split send/settle round-trips
// the reply the fused `call` would have returned.
test "HostConnection.send then settleVow round-trips through node routing" {
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
    var host = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x2c} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();
    const to_server = try host.dial(.{
        .transport = tcp.transport_name,
        .designator = try shared.addr.await_(io, wait.default_deadline_ms),
        .hints = model.Hints.emptyFalse(),
    });
    const counter = try to_server.fetch("counter");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const vow = try to_server.send(counter, .{ .verb = "add", .args = &.{.{ .integer = 5 }} });
    const settled = try to_server.settleVow(vow, arena.allocator());
    switch (settled) {
        .fulfilled => |arg| try std.testing.expectEqual(@as(i64, 5), arg.integer),
        .broken => |reason| {
            std.debug.print("add broke: {s}\n", .{reason});
            return error.AddBroke;
        },
        .give => return error.ExpectedValue,
    }
}

// The regression for ADR-0069: a gifter that introduces *two* exporters must
// route each introduction to its own exporter. The gifter fetches a widget from
// each exporter over a separate connection; with a fresh session each import
// lands at the same wire position, so the old position-keyed home map collided
// and every introduction resolved to the last-fetched exporter. Two distinct
// labels make the mis-route observable: introducing to A must poke A, not B.

/// A widget that answers `poke` with its exporter's label, so a mis-routed
/// introduction comes back as the wrong label.
const LabeledWidget = struct {
    label: []const u8,
    pub fn handle(self: *LabeledWidget, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "poke")) return error.NoSuchMethod;
        return .{ .string = self.label };
    }
};

/// The gifter's introducer holding two foreign widgets; `a`/`b` return the
/// matching one. The core's interceptor turns each reply into a give toward
/// that widget's own exporter.
const TwoIntroducer = struct {
    widget_a: model.Reference,
    widget_b: model.Reference,
    pub fn handle(self: *TwoIntroducer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (std.mem.eql(u8, msg.verb, "a")) return .{ .reference = self.widget_a };
        if (std.mem.eql(u8, msg.verb, "b")) return .{ .reference = self.widget_b };
        return error.NoSuchMethod;
    }
};

const TwoShared = struct {
    a_addr: Addr = .{},
    b_addr: Addr = .{},
    gifter_addr: Addr = .{},
    fetched_a: std.atomic.Value(bool) = .init(false),
    fetched_b: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
};

/// One exporter: publish its labeled widget on the gifter leg, wait for the
/// gifter's fetch, then accept the recipient's redeem dial and round-robin both.
fn labeledExporterTask(
    allocator: std.mem.Allocator,
    addr: *Addr,
    label: []const u8,
    fetched: *std.atomic.Value(bool),
    done: *std.atomic.Value(bool),
    seed: [32]u8,
) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };
    var host = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, seed, .{ .frame_cap = frame_cap });
    defer host.deinit();
    var server = try host.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    addr.publish(server.localDesignator(&addr_buf));
    const to_gifter = try server.accept();
    _ = try to_gifter.publish("widget", LabeledWidget, .{ .label = label });
    const fetched_deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!fetched.load(.acquire)) {
        if (wait.expired(io, fetched_deadline)) return error.WaitTimedOut;
        _ = try to_gifter.stepReadable(10);
    }
    const to_recipient = try server.accept();
    _ = try to_recipient.publish("widget", LabeledWidget, .{ .label = label });
    const done_deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!done.load(.acquire)) {
        if (wait.expired(io, done_deadline)) return error.WaitTimedOut;
        _ = try to_gifter.stepReadable(5);
        _ = try to_recipient.stepReadable(5);
    }
}

/// The gifter: fetch a widget from each exporter (two connections, same wire
/// position — the collision), publish an introducer holding both, and serve the
/// recipient and both deposit legs.
fn twoGifterTask(allocator: std.mem.Allocator, shared: *TwoShared) anyerror!void {
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var resident = tcp.Resident{ .io = io };
    var host = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x16} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();

    const to_a = try host.dial(.{ .transport = tcp.transport_name, .designator = try shared.a_addr.await_(io, wait.default_deadline_ms), .hints = model.Hints.emptyFalse() });
    const widget_a = try to_a.fetch("widget");
    shared.fetched_a.store(true, .release);
    const to_b = try host.dial(.{ .transport = tcp.transport_name, .designator = try shared.b_addr.await_(io, wait.default_deadline_ms), .hints = model.Hints.emptyFalse() });
    const widget_b = try to_b.fetch("widget");
    shared.fetched_b.store(true, .release);

    var server = try host.listen(resident.netlayer(), .{ .designator = "127.0.0.1:0" });
    defer server.close();
    var addr_buf: [64]u8 = undefined;
    shared.gifter_addr.publish(server.localDesignator(&addr_buf));
    const to_recipient = try server.accept();
    _ = try to_recipient.publish("introducer", TwoIntroducer, .{ .widget_a = widget_a, .widget_b = widget_b });
    const shared_done_deadline = wait.deadlineAfter(io, wait.default_deadline_ms);
    while (!shared.done.load(.acquire)) {
        if (wait.expired(io, shared_done_deadline)) return error.WaitTimedOut;
        _ = try to_recipient.stepReadable(5);
        _ = try to_a.stepReadable(5);
        _ = try to_b.stepReadable(5);
    }
}

/// Introduce via `verb` (the call settles with the redeemed reference) and
/// poke the introduced widget; assert it answers with `expect_label` (the
/// exporter the introduction named).
fn introducePoke(
    to_gifter: *driver.BlockingHost.Connection,
    introducer: model.Reference,
    verb: []const u8,
    expect_label: []const u8,
    arena: std.mem.Allocator,
) !void {
    const settled = try to_gifter.call(introducer, .{ .verb = verb, .args = &.{} }, arena);
    const widget = switch (settled) {
        .fulfilled => |arg| switch (arg) {
            .reference => |reference| reference,
            else => return error.ExpectedReference,
        },
        .broken => |reason| {
            std.debug.print("introduce({s}) broke: {s}\n", .{ verb, reason });
            return error.IntroduceBroke;
        },
        .give => return error.GiveShouldHaveBeenRedeemed,
    };
    const reply = try to_gifter.call(widget, .{ .verb = "poke", .args = &.{} }, arena);
    switch (reply) {
        .fulfilled => |arg| try std.testing.expectEqualStrings(expect_label, arg.string),
        .broken => |reason| {
            std.debug.print("poke broke: {s}\n", .{reason});
            return error.PokeBroke;
        },
        .give => return error.ExpectedValue,
    }
}

test "a gifter introducing two exporters routes each introduction to its own exporter (ADR-0069)" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var shared = TwoShared{};
    var a_future = try io.concurrent(labeledExporterTask, .{ allocator, &shared.a_addr, @as([]const u8, "exporter-A"), &shared.fetched_a, &shared.done, [_]u8{0x1e} ** 32 });
    var b_future = try io.concurrent(labeledExporterTask, .{ allocator, &shared.b_addr, @as([]const u8, "exporter-B"), &shared.fetched_b, &shared.done, [_]u8{0x1f} ** 32 });
    var gifter_future = try io.concurrent(twoGifterTask, .{ allocator, &shared });
    defer {
        shared.done.store(true, .release);
        const a = a_future.await(io);
        const b = b_future.await(io);
        const g = gifter_future.await(io);
        a catch |err| std.debug.print("exporter A task: {s}\n", .{@errorName(err)});
        b catch |err| std.debug.print("exporter B task: {s}\n", .{@errorName(err)});
        g catch |err| std.debug.print("gifter task: {s}\n", .{@errorName(err)});
    }

    var resident = tcp.Resident{ .io = io };
    var host = driver.BlockingHost.initSeeded(allocator, io, &.{resident.netlayer()}, [_]u8{0x1c} ** 32, .{ .frame_cap = frame_cap });
    defer host.deinit();
    const to_gifter = try host.dial(.{ .transport = tcp.transport_name, .designator = try shared.gifter_addr.await_(io, wait.default_deadline_ms), .hints = model.Hints.emptyFalse() });
    const introducer = try to_gifter.fetch("introducer");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Under the position-keyed map both introductions resolved to the last
    // exporter fetched (B); the token enrollment routes each to its own.
    try introducePoke(to_gifter, introducer, "a", "exporter-A", arena.allocator());
    try introducePoke(to_gifter, introducer, "b", "exporter-B", arena.allocator());
}
