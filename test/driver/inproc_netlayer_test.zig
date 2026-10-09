//! The in-process netlayer, driven through the contract.
//!
//! This is the second real resident proving the netlayer contract generalizes.
//! Unlike the `x-loopback` test transport (which rides tcp under the hood), the
//! `inproc` netlayer has no sockets and no file descriptors: dial and accept
//! rendezvous by designator on an in-process switchboard, and the bytes flow over
//! in-process pipes. The driver dials and hosts it through the same transport-
//! neutral `connectVia` / `acceptVia` with the same verified keyed handshake it
//! uses for tcp, and neither the driver nor the core was edited to add it. A full
//! OCapN conversation: keyed `op:start-session`, bootstrap fetch, deliver, and
//! the fulfilled reply round-trip entirely in process.

const std = @import("std");
const glowcap = @import("glowcap");
const netlayer_test = @import("../support/netlayer.zig");
const support_actors = @import("../support/actors.zig");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const actors = glowcap.actors;
const driver = glowcap.driver;
const net = glowcap.net;
const inproc = net.inproc;

const frame_cap = 4096;
const node_designator = "greeter-node";

const Greeter = support_actors.StaticReplyActor("greet", "hello over inproc");

const ReplyState = struct {
    done: bool = false,
    ok: bool = false,
};

fn onGreeting(ctx: ?*anyopaque, resolution: actors.Resolution) void {
    const state: *ReplyState = @ptrCast(@alignCast(ctx.?));
    state.done = true;
    state.ok = switch (resolution) {
        .fulfilled => |arg| switch (arg) {
            .string => |text| std.mem.eql(u8, text, "hello over inproc"),
            else => false,
        },
        .broken, .give => false,
    };
}

/// Accept one partner over the bound in-process listener, publish the greeter, and
/// serve until the client leaves. The listener is bound by the test body before
/// the client dials, so there is no accept-before-bind race.
fn hostOnce(listener: net.netlayer.Listener, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var cv = try driver.acceptVia(allocator, listener, &peer, .ephemeral, read_buf, write_buf, .{ .handshake = .unbounded, .settle = .unbounded });
    defer cv.deinit();

    _ = try cv.publish("greeter", Greeter, .{});
    try cv.serve();
}

/// Dial the in-process node by designator through `connectVia`, fetch the greeter,
/// call it, and assert the reply.
fn callOnce(network: *inproc.Network, allocator: std.mem.Allocator) !void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const netlayers = [_]net.netlayer.Netlayer{network.netlayer()};
    var cv = try driver.connectVia(allocator, &netlayers, &peer, .{
        .transport = inproc.transport_name,
        .designator = node_designator,
        .hints = model.Hints.emptyFalse(),
    }, .ephemeral, read_buf, write_buf, .{ .handshake = .unbounded, .settle = .unbounded });
    defer cv.deinit();

    const greeter = try cv.fetch("greeter");
    const promise = try cv.send(greeter, .{ .verb = "greet", .args = &.{.{ .string = "glowcap" }} });
    var state = ReplyState{};
    try cv.on(promise, .{ .ctx = &state, .func = onGreeting });
    while (!state.done) {
        const progress = try cv.step();
        if (progress == .closed) break;
    }
    try std.testing.expect(state.done and state.ok);
}

test "inproc netlayer: full keyed handshake + fetch + call round-trips with no socket" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var network = inproc.Network.init(allocator, io);
    defer network.deinit();

    // Bind the listener before the client dials, so the switchboard has the node.
    const listener = try netlayer_test.listenBlocking(network.netlayer(), allocator, .{ .designator = node_designator });
    defer netlayer_test.close(listener);

    var host_future = try io.concurrent(hostOnce, .{ listener, allocator });
    const client_result = callOnce(&network, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

test "inproc netlayer: dialing an unbound designator fails closed" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var network = inproc.Network.init(allocator, io);
    defer network.deinit();

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;

    const netlayers = [_]net.netlayer.Netlayer{network.netlayer()};
    // No listener bound at that designator is the in-memory refused-partner
    // case (ADR-0081): the dial fails closed with ConnectionRefused, the typed
    // reason a reconnecting caller acts on.
    try std.testing.expectError(error.ConnectionRefused, driver.connectVia(allocator, &netlayers, &peer, .{
        .transport = inproc.transport_name,
        .designator = "no-such-node",
        .hints = model.Hints.emptyFalse(),
    }, .ephemeral, &read_buf, &write_buf, .{ .handshake = .unbounded, .settle = .unbounded }));
}

/// Park an accept on the listener and expect the clean closed verdict: the
/// listener was closed with nothing pending, so accept reports the partner-less
/// close as `error.ConnectionLost`.
fn acceptUntilClosed(listener: net.netlayer.Listener, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;
    try std.testing.expectError(
        error.ConnectionLost,
        listener.accept(&peer, .{ .read = &read_buf, .write = &write_buf }),
    );
}

test "inproc netlayer: closing the listener wakes a parked accept cleanly" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var network = inproc.Network.init(allocator, io);
    defer network.deinit();

    const listener = try netlayer_test.listenBlocking(network.netlayer(), allocator, .{ .designator = "close-me" });

    // Park an accept on its own fiber, give it time to reach the wait, then
    // close the listener out from under it. The woken accepter must observe
    // the close and return before the listener frees its mutex and pending
    // list, the waiter accounting in the close path is what makes that safe.
    var accept_future = try io.concurrent(acceptUntilClosed, .{ listener, allocator });
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
    netlayer_test.close(listener);
    try accept_future.await(io);
}

fn waitFiniteUntilClosed(listener: net.netlayer.Listener) anyerror!void {
    try std.testing.expectError(error.ConnectionLost, listener.waitAcceptable(10_000));
}

test "inproc netlayer: close joins a finite readiness wait before freeing storage" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var network = inproc.Network.init(allocator, io);
    defer network.deinit();

    const listener = try netlayer_test.listenBlocking(network.netlayer(), allocator, .{ .designator = "finite-close" });
    var waiter = try io.concurrent(waitFiniteUntilClosed, .{listener});
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
    netlayer_test.close(listener);
    try waiter.await(io);
}

fn waitAcceptableForever(listener: net.netlayer.Listener, outcome: *std.atomic.Value(u8)) anyerror!void {
    const ready = try listener.waitAcceptable(-1);
    outcome.store(if (ready) 1 else 2, .release);
    try std.testing.expect(ready);
}

test "inproc netlayer: unbounded waitAcceptable parks until a dial arrives" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var network = inproc.Network.init(allocator, io);
    defer network.deinit();

    const listener = try netlayer_test.listenBlocking(network.netlayer(), allocator, .{ .designator = "wait-forever" });
    defer netlayer_test.close(listener);

    var outcome = std.atomic.Value(u8).init(0);
    var waiter = try io.concurrent(waitAcceptableForever, .{ listener, &outcome });
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
    try std.testing.expectEqual(@as(u8, 0), outcome.load(.acquire));

    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;
    var conn = try network.netlayer().dial(&peer, .{
        .transport = inproc.transport_name,
        .designator = "wait-forever",
        .hints = model.Hints.emptyFalse(),
    }, .{ .read = &read_buf, .write = &write_buf }, .inherit);
    defer conn.deinit();

    try waiter.await(io);
    try std.testing.expectEqual(@as(u8, 1), outcome.load(.acquire));
}

/// One racing dial: either it wins (a connection comes back, whose pipes the
/// close has already EOF'd, so it is torn down immediately) or the close wins
/// and the dial fails closed with `ConnectionLost`. Anything else — in
/// particular touching the listener after `close` freed it — is the race this
/// test exists to catch.
fn dialAgainstClose(network: *inproc.Network, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;

    var conn = network.netlayer().dial(&peer, .{
        .transport = inproc.transport_name,
        .designator = "race-me",
        .hints = model.Hints.emptyFalse(),
    }, .{ .read = &read_buf, .write = &write_buf }, .inherit) catch |err| switch (err) {
        // The close won, two ways (ADR-0081): the listener was flagged closed
        // after this dial pinned it but before enqueue (ConnectionLost), or it
        // was already unregistered when the dial looked it up, so the dial never
        // found a listener at all (ConnectionRefused). Both are the race
        // resolving cleanly; anything else is a real fault.
        error.ConnectionLost, error.ConnectionRefused => return,
        else => return err,
    };
    conn.deinit();
}

test "inproc netlayer: closing the listener races concurrent dials without touching freed state" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var network = inproc.Network.init(allocator, io);
    defer network.deinit();

    const listener = try netlayer_test.listenBlocking(network.netlayer(), allocator, .{ .designator = "race-me" });

    // Fire a burst of dials and close the listener while they are in flight.
    // The dial path pins the listener between the registry lookup and the
    // enqueue, and `listenerClose` waits the pins out between unregister and
    // its frees, so every dial lands on live state: it is accepted into the
    // pending sweep, refused by the closed flag, or never finds the listener
    // at all.
    const dials = 8;
    var futures: [dials]std.Io.Future(anyerror!void) = undefined;
    for (&futures) |*f| f.* = try io.concurrent(dialAgainstClose, .{ &network, allocator });
    netlayer_test.close(listener);
    var first_err: ?anyerror = null;
    for (&futures) |*f| f.await(io) catch |err| {
        if (first_err == null) first_err = err;
    };
    if (first_err) |err| return err;

    // The listener is gone from the switchboard: a late dial finds no listener
    // and fails closed with the refused-partner reason (ADR-0081).
    try std.testing.expectError(error.ConnectionRefused, dialAgainstCloseDirect(&network, allocator));
}

const SlowArrival = struct {
    entered: *std.atomic.Value(bool),
    release: *std.atomic.Value(bool),

    fn notify(ctx: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.entered.store(true, .release);
        while (!self.release.load(.acquire)) std.Thread.yield() catch {};
    }
};

fn dialWhileArrivalNotifies(network: *inproc.Network) anyerror!void {
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;
    var stream = try network.connectFrameStream("notify-close", .syrup, frame_cap, &read_buf, &write_buf);
    stream.deinit();
}

fn closeRawListener(listener: *inproc.InprocListener, returned: *std.atomic.Value(bool)) void {
    std.testing.expect(listener.close() == null) catch unreachable;
    returned.store(true, .release);
}

test "inproc listener close drains an in-flight arrival notification" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var network = inproc.Network.init(allocator, io);
    defer network.deinit();

    const listener = try network.bindFrame(allocator, "notify-close");
    var entered = std.atomic.Value(bool).init(false);
    var release = std.atomic.Value(bool).init(false);
    var slow = SlowArrival{ .entered = &entered, .release = &release };
    listener.setArrivalNotifier(.{ .ctx = &slow, .notify_fn = SlowArrival.notify });

    var dial = try io.concurrent(dialWhileArrivalNotifies, .{&network});
    while (!entered.load(.acquire)) std.Thread.yield() catch {};

    var close_returned = std.atomic.Value(bool).init(false);
    var close = try io.concurrent(closeRawListener, .{ listener, &close_returned });
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
    try std.testing.expect(!close_returned.load(.acquire));

    release.store(true, .release);
    try dial.await(io);
    close.await(io);
    try std.testing.expect(close_returned.load(.acquire));
}

/// As `dialAgainstClose`, but surfacing the dial error to the caller so the
/// post-close assertion can demand the refused-partner reason.
fn dialAgainstCloseDirect(network: *inproc.Network, allocator: std.mem.Allocator) anyerror!void {
    var peer = engine.Peer.initNegotiating(allocator);
    defer peer.deinit();
    var read_buf: [256]u8 = undefined;
    var write_buf: [256]u8 = undefined;
    var conn = try network.netlayer().dial(&peer, .{
        .transport = inproc.transport_name,
        .designator = "race-me",
        .hints = model.Hints.emptyFalse(),
    }, .{ .read = &read_buf, .write = &write_buf }, .inherit);
    conn.deinit();
}
