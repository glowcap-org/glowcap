//! `driver.Session`'s partner-fault contract over a real 127.0.0.1 socket: a
//! partner that answers a call with a typed `op:abort` breaks the pending
//! call with its own diagnostic, the session retains the abort's kind and
//! message for the application to read, and every keyed wait against a
//! partner that goes quiet times out instead of parking a fiber.

const std = @import("std");
const glowcap = @import("glowcap");
const support_actors = @import("../support/actors.zig");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

const ip = std.Io.net;

const frame_cap = 4096;

/// Finite budgets: a partner that goes quiet fails the suite instead of
/// parking it.
const dial_opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 10_000 },
    .settle = .{ .ms = 10_000 },
};

const abort_diagnostic = "credential rotation in progress; dial back later";

/// The published actor for the stall scenario: never reached, because the
/// host that publishes it never serves.
const Greeter = support_actors.StaticReplyValueActor("greet", "hello from the stalled host");

/// The published actor: its first turn answers with a typed `op:abort`
/// through the session's raw peer instead of a resolve, and defers its
/// answer so no reply follows the abort. The bootstrap fetch stays
/// engine-answered, so the client holds a real far ref before the abort
/// lands.
const AbortingGreeter = struct {
    session: *driver.Session,

    pub fn handle(self: *AbortingGreeter, ht: *driver.HostTurn, selector: ?[]const u8, args: driver.Args) !driver.Value {
        defer ht.releaseArguments(args);
        const verb = selector orelse return error.NoSuchMethod;
        if (!std.mem.eql(u8, verb, "greet")) return error.NoSuchMethod;
        try self.session.peer().sendBorrowed(.{ .abort = .{ .kind = .unauthorized, .message = abort_diagnostic } });
        _ = try ht.deferAnswer();
        return .{ .void = {} };
    }
};

/// Accept one partner, publish the aborting greeter, and serve until the
/// abort closes the session.
fn abortingHostOnce(server: *driver.Server) anyerror!void {
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("greeter", AbortingGreeter, .{ .session = session });
    try session.serve();
}

/// Fetch the greeter and call it against a partner that answers with a typed
/// abort and leaves: the pending `call` settles broken with the partner's own
/// diagnostic, and the session retains the abort's kind and message.
fn callAbortedOnce(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    var session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&buf, address), .ephemeral, dial_opts);
    defer session.deinit();

    const greeter = try session.fetch("greeter");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const reply = try session.call(greeter, "greet", &.{.{ .string = "glowcap" }}, arena_state.allocator());
    switch (reply) {
        .fulfilled => return error.UnexpectedFulfillment,
        .broken => |reason| try std.testing.expectEqualStrings(abort_diagnostic, reason),
    }
    try std.testing.expectEqualStrings(abort_diagnostic, session.abortReason().?);
    const retained = session.partnerAbort().?;
    try std.testing.expectEqual(model.AbortKind.unauthorized, retained.kind);
    try std.testing.expectEqualStrings(abort_diagnostic, retained.message);
}

test "session: a partner's typed abort breaks the pending call with its diagnostic and partnerAbort retains it" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, dial_opts);
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    var host_future = try io.concurrent(abortingHostOnce, .{server});
    const client_result = callAbortedOnce(io, address, allocator);
    const host_result = host_future.await(io);
    try client_result;
    try host_result;
}

test "connect: a silent partner's handshake breaks with HandshakeTimedOut through the pump" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Bind but never accept: the kernel completes connect into the backlog
    // while the peer stays silent through the whole handshake window. The
    // budget is `Host.pumpHandshake`'s deadline arithmetic, so a partner
    // that completes connect and then never speaks breaks the handshake, not
    // the fiber (ADR-0030, contract 2).
    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    var buf: [64]u8 = undefined;
    try std.testing.expectError(driver.Error.HandshakeTimedOut, driver.connect(
        allocator,
        io,
        .{ .symbols = &.{.tcp} },
        tcp.locatorFromAddress(&buf, listener.localAddress()),
        .ephemeral,
        .{ .frame_cap = frame_cap, .handshake = .{ .ms = 200 }, .settle = .{ .ms = 200 } },
    ));

    // An already-expired budget times out before the first poll, in every
    // build mode. The OS poll vocabulary underneath reads zero as forever,
    // so if this guard regresses the test does not fail, it parks, which is
    // why the suite runs under a timeout wrapper. A negative budget is the
    // same expiry.
    for ([_]i32{ 0, -1 }) |expired| {
        try std.testing.expectError(driver.Error.HandshakeTimedOut, driver.connect(
            allocator,
            io,
            .{ .symbols = &.{.tcp} },
            tcp.locatorFromAddress(&buf, listener.localAddress()),
            .ephemeral,
            .{ .frame_cap = frame_cap, .handshake = .{ .ms = expired }, .settle = .{ .ms = 200 } },
        ));
    }
}

/// A raw TCP client that completes connect and then says nothing for longer
/// than the accepter's handshake budget: the ADR-0030 slowloris, aimed at the
/// accept path so its failure unwind runs under the testing allocator
/// (the accept-side handshake failure once double-freed the wire buffers).
fn silentRawDialer(io: std.Io, address: ip.IpAddress) anyerror!void {
    var addr = address;
    const stream = try std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream });
    defer stream.close(io);
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(800), .real) catch {};
}

test "accept: a connect-then-silent dialer times out and the unwind stays memory-clean" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, .{
        .frame_cap = frame_cap,
        .handshake = .{ .ms = 200 },
        .settle = .{ .ms = 200 },
    });
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    var dialer = try io.concurrent(silentRawDialer, .{ io, address });
    defer dialer.await(io) catch {};

    try std.testing.expectError(driver.Error.HandshakeTimedOut, server.accept());
}

/// Host half that completes the keyed handshake and publishes, then never
/// serves, the partner opens then stalls, the settle budget's target.
fn hostAcceptPublishThenStall(server: *driver.Server, io: std.Io) anyerror!void {
    var session = try server.accept();
    defer session.deinit();
    _ = try session.publish("root", Greeter, .{});
    // Hold the connection open without pumping CapTP until the client's
    // settle budget fires and it drops the socket; then exit.
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2000), .real) catch {};
}

fn silentPartnerSettleTimesOut(io: std.Io, address: ip.IpAddress, allocator: std.mem.Allocator) !void {
    var buf: [64]u8 = undefined;
    var session = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&buf, address), .ephemeral, .{
        .frame_cap = frame_cap,
        .handshake = .{ .ms = 10_000 },
        .settle = .{ .ms = 200 },
    });
    defer session.deinit();
    try std.testing.expectError(driver.Error.WaitTimedOut, session.fetch("root"));
}

test "driver loopback: a partner that opens then stalls breaks settle with WaitTimedOut, not a parked fiber" {
    const allocator = std.testing.allocator;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, dial_opts);
    defer server.deinit();
    var addr_buf: [64]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&addr_buf));

    const host_thread = try std.Thread.spawn(.{}, hostAcceptPublishThenStall, .{ server, io });
    defer host_thread.join();

    try silentPartnerSettleTimesOut(io, address, allocator);
}
