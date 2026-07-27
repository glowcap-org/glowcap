//! In-process CapTP adapter golden: `cmdListen` + `cmdCall` over loopback.
//!
//! Proves the product CLI fronts wire `driver.Session` correctly (exit 0 and
//! greeter payload). Not Goblins/suite wire evidence — see community-review.
const std = @import("std");
const cli = @import("cli");
const pancake = @import("pancake");

const Ctx = cli.ctx.Ctx;

fn testSecret(seed: u8) pancake.foundation.crypto.SecretKey {
    return pancake.foundation.crypto.SecretKey.fromSeed([_]u8{seed} ** 32);
}

fn makeCtx(io: std.Io, gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, seed: u8) Ctx {
    return .{
        .io = io,
        .gpa = gpa,
        .environ = environ,
        .front = .argv,
        .json = .json,
        .secret = testSecret(seed),
    };
}

const ListenArgs = struct {
    ctx: *Ctx,
    parsed: *cli.cmd_types.Parsed,
};

fn runListen(args: *ListenArgs) !u8 {
    return cli.ocapn.cmdListen(args.ctx, args.parsed);
}

/// Publish `greeter` on a one-shot listener, dial it, call `verb arg`, and
/// assert exit 0 plus every needle in the client output (and that the host
/// printed its locator). The say-verb round-trips differ only in the seeds,
/// the verb, the argument, and the needles.
fn expectPublishedCallRoundTrip(
    host_seed: u8,
    client_seed: u8,
    verb: []const u8,
    arg: []const u8,
    needles: []const []const u8,
) !void {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    cli.signals.resetForTest();
    defer cli.signals.resetForTest();

    var host = makeCtx(io, gpa, &environ, host_seed);
    defer host.deinit();
    var host_capture: std.ArrayList(u8) = .empty;
    defer host_capture.deinit(gpa);
    host.sink = .{ .buffer = &host_capture };

    var listen_parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer listen_parsed.deinit();
    try listen_parsed.bools.put(gpa, "once", true);
    try listen_parsed.strings.put(gpa, "publish", "greeter");
    try listen_parsed.strings.put(gpa, "bind", "127.0.0.1:0");

    var listen_args = ListenArgs{ .ctx = &host, .parsed = &listen_parsed };
    var host_future = try io.concurrent(runListen, .{&listen_args});

    const uri = try waitListenLocator(&host, &host_future, io);

    var client = makeCtx(io, gpa, &environ, client_seed);
    defer client.deinit();
    var client_capture: std.ArrayList(u8) = .empty;
    defer client_capture.deinit(gpa);
    client.sink = .{ .buffer = &client_capture };

    const positionals = [_][]const u8{ uri, "greeter", verb, arg };
    var call_parsed = cli.cmd_types.Parsed{ .gpa = gpa, .positionals = &positionals };
    defer call_parsed.deinit();

    try std.testing.expectEqual(cli.exit_codes.ok, try cli.ocapn.cmdCall(&client, &call_parsed));
    for (needles) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, client_capture.items, needle) != null);
    }

    const host_code = try host_future.await(io);
    try std.testing.expectEqual(cli.exit_codes.ok, host_code);
    try std.testing.expect(std.mem.indexOf(u8, host_capture.items, "ocapn://") != null);
}

test "listen publish greeter once then call round-trips through cli.ocapn" {
    // Same shape as README / examples: fetch greeter, verb greet, one string arg.
    try expectPublishedCallRoundTrip(11, 22, "greet", "world", &.{"Hello, world"});
}

test "MCP locator call retains session for a follow-up call" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    cli.signals.resetForTest();
    defer cli.signals.resetForTest();

    var host = makeCtx(io, gpa, &environ, 61);
    defer host.deinit();
    var host_capture: std.ArrayList(u8) = .empty;
    defer host_capture.deinit(gpa);
    host.sink = .{ .buffer = &host_capture };

    var listen_parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer listen_parsed.deinit();
    try listen_parsed.bools.put(gpa, "once", true);
    try listen_parsed.strings.put(gpa, "publish", "greeter");
    try listen_parsed.strings.put(gpa, "bind", "127.0.0.1:0");

    var listen_args = ListenArgs{ .ctx = &host, .parsed = &listen_parsed };
    var host_future = try io.concurrent(runListen, .{&listen_args});

    const uri = try waitListenLocator(&host, &host_future, io);

    var client = makeCtx(io, gpa, &environ, 62);
    defer client.deinit();
    client.front = .mcp;
    var client_capture: std.ArrayList(u8) = .empty;
    defer client_capture.deinit(gpa);
    client.sink = .{ .buffer = &client_capture };

    const first = [_][]const u8{ uri, "greeter", "greet", "retained" };
    var first_parsed = cli.cmd_types.Parsed{ .gpa = gpa, .positionals = &first };
    defer first_parsed.deinit();
    try std.testing.expectEqual(cli.exit_codes.ok, try cli.ocapn.cmdCall(&client, &first_parsed));
    try std.testing.expect(client.session != null);
    try std.testing.expect(std.mem.indexOf(u8, client_capture.items, "Hello, retained") != null);

    client_capture.clearRetainingCapacity();
    const second = [_][]const u8{ "greeter", "greet", "again" };
    var second_parsed = cli.cmd_types.Parsed{ .gpa = gpa, .positionals = &second };
    defer second_parsed.deinit();
    try std.testing.expectEqual(cli.exit_codes.ok, try cli.ocapn.cmdCall(&client, &second_parsed));
    try std.testing.expect(std.mem.indexOf(u8, client_capture.items, "Hello, again") != null);

    client.closeSession();
    const host_code = try host_future.await(io);
    try std.testing.expectEqual(cli.exit_codes.ok, host_code);
}

test "argv locator call does not retain a session" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    cli.signals.resetForTest();
    defer cli.signals.resetForTest();

    var host = makeCtx(io, gpa, &environ, 63);
    defer host.deinit();
    var host_capture: std.ArrayList(u8) = .empty;
    defer host_capture.deinit(gpa);
    host.sink = .{ .buffer = &host_capture };

    var listen_parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer listen_parsed.deinit();
    try listen_parsed.bools.put(gpa, "once", true);
    try listen_parsed.strings.put(gpa, "publish", "greeter");
    try listen_parsed.strings.put(gpa, "bind", "127.0.0.1:0");

    var listen_args = ListenArgs{ .ctx = &host, .parsed = &listen_parsed };
    var host_future = try io.concurrent(runListen, .{&listen_args});

    const uri = try waitListenLocator(&host, &host_future, io);

    var client = makeCtx(io, gpa, &environ, 64);
    defer client.deinit();
    var client_capture: std.ArrayList(u8) = .empty;
    defer client_capture.deinit(gpa);
    client.sink = .{ .buffer = &client_capture };

    const positionals = [_][]const u8{ uri, "greeter", "greet", "oneshot" };
    var call_parsed = cli.cmd_types.Parsed{ .gpa = gpa, .positionals = &positionals };
    defer call_parsed.deinit();
    try std.testing.expectEqual(cli.exit_codes.ok, try cli.ocapn.cmdCall(&client, &call_parsed));
    try std.testing.expect(client.session == null);

    const host_code = try host_future.await(io);
    try std.testing.expectEqual(cli.exit_codes.ok, host_code);
}

test "listen publish greeter once then pancakesay round-trips through cli.ocapn" {
    // Face cake in formatPancakesay: `(_|^_^|__)`.
    try expectPublishedCallRoundTrip(14, 24, "pancakesay", "flapjacks", &.{ "< flapjacks >", "|^_^|", "~~syrup~~" });
}

test "listen publish greeter once then goblinsay round-trips through cli.ocapn" {
    try expectPublishedCallRoundTrip(15, 25, "goblinsay", "ocapn", &.{ "< ocapn >", "( o.o )" });
}

test "listen publish greeter once then cowsay round-trips through cli.ocapn" {
    try expectPublishedCallRoundTrip(13, 23, "cowsay", "moo", &.{ "< moo >", "^__^" });
}

fn waitListenLocator(host: *Ctx, host_future: anytype, io: std.Io) ![]const u8 {
    var spins: usize = 0;
    while (true) : (spins += 1) {
        if (host.last_locator) |loc| return loc;
        if (spins > 50_000) {
            cli.signals.requestStop();
            _ = host_future.await(io) catch {};
            return error.ListenLocatorTimeout;
        }
        std.Thread.yield() catch {};
    }
}

test "listen exits promptly on requestStop while accepting" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    cli.signals.resetForTest();
    defer cli.signals.resetForTest();

    var host = makeCtx(io, gpa, &environ, 33);
    defer host.deinit();
    var host_capture: std.ArrayList(u8) = .empty;
    defer host_capture.deinit(gpa);
    host.sink = .{ .buffer = &host_capture };

    var listen_parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer listen_parsed.deinit();
    try listen_parsed.strings.put(gpa, "publish", "greeter");
    try listen_parsed.strings.put(gpa, "bind", "127.0.0.1:0");

    var listen_args = ListenArgs{ .ctx = &host, .parsed = &listen_parsed };
    var host_future = try io.concurrent(runListen, .{&listen_args});

    _ = try waitListenLocator(&host, &host_future, io);

    // Parked in accept: SIGINT-equivalent must exit without BADF panic.
    cli.signals.requestStop();
    const host_code = try host_future.await(io);
    try std.testing.expectEqual(cli.exit_codes.ok, host_code);
}

test "listen exits promptly on requestStop while serving" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    cli.signals.resetForTest();
    defer cli.signals.resetForTest();

    var host = makeCtx(io, gpa, &environ, 44);
    defer host.deinit();
    var host_capture: std.ArrayList(u8) = .empty;
    defer host_capture.deinit(gpa);
    host.sink = .{ .buffer = &host_capture };

    var listen_parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer listen_parsed.deinit();
    try listen_parsed.strings.put(gpa, "publish", "greeter");
    try listen_parsed.strings.put(gpa, "bind", "127.0.0.1:0");

    var listen_args = ListenArgs{ .ctx = &host, .parsed = &listen_parsed };
    var host_future = try io.concurrent(runListen, .{&listen_args});

    const uri = try waitListenLocator(&host, &host_future, io);

    var client = makeCtx(io, gpa, &environ, 55);
    defer client.deinit();
    // Dial proves accept+publish completed; keep the session open so the host
    // parks in serveUntilStop (unbounded Session.serve would ignore stop).
    const held = try cli.ocapn.dialUriWithOpts(&client, uri, .{
        .handshake_timeout_ms = 2_000,
        .settle_timeout_ms = 2_000,
    });
    defer held.deinit();
    _ = try held.fetch("greeter");

    cli.signals.requestStop();
    const host_code = try host_future.await(io);
    try std.testing.expectEqual(cli.exit_codes.ok, host_code);
}

test "await queue detaches its vat listener when the partner vanishes mid-wait" {
    const gpa = std.testing.allocator;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    cli.signals.resetForTest();
    defer cli.signals.resetForTest();

    var host = makeCtx(io, gpa, &environ, 71);
    defer host.deinit();
    var host_capture: std.ArrayList(u8) = .empty;
    defer host_capture.deinit(gpa);
    host.sink = .{ .buffer = &host_capture };

    var listen_parsed = cli.cmd_types.Parsed{ .gpa = gpa };
    defer listen_parsed.deinit();
    try listen_parsed.bools.put(gpa, "once", true);
    try listen_parsed.strings.put(gpa, "publish", "greeter");
    try listen_parsed.strings.put(gpa, "bind", "127.0.0.1:0");

    var listen_args = ListenArgs{ .ctx = &host, .parsed = &listen_parsed };
    var host_future = try io.concurrent(runListen, .{&listen_args});
    const uri = try waitListenLocator(&host, &host_future, io);

    var client = makeCtx(io, gpa, &environ, 72);
    defer client.deinit();
    client.front = .repl;
    var client_capture: std.ArrayList(u8) = .empty;
    defer client_capture.deinit(gpa);
    client.sink = .{ .buffer = &client_capture };

    client.session = try cli.ocapn.dialUriWithOpts(&client, uri, .{
        .handshake_timeout_ms = 2_000,
        .settle_timeout_ms = 2_000,
    });

    // The partner leaves for good before the wait is registered: stop the host
    // and join it, so the queue's fetch listener can only settle through the
    // dead-transport paths (clean-close vow break or the fault arm's own break).
    cli.signals.requestStop();
    try std.testing.expectEqual(cli.exit_codes.ok, try host_future.await(io));

    var store = cli.repl_blocks.Store.init(gpa);
    defer store.deinit();
    var progress = cli.repl_teach.Progress{ .has_session = true };
    var complete_state = cli.repl_complete.State.init(gpa);
    defer complete_state.deinit();
    var queue = cli.repl_await_queue.Queue.init(gpa);
    defer queue.deinit();

    try queue.enqueue(&client, "call greeter greet boom", &store, &progress);
    var spins: usize = 0;
    while (queue.busy() and spins < 1_000) : (spins += 1) {
        _ = queue.tick(&client, &store, &progress, &complete_state) catch {};
    }
    try std.testing.expect(!queue.busy());

    // Closing the session fires every listener still on the vat; a wait that
    // died above must have taken its listener with it, not left one aimed at
    // the freed Active.
    client.closeSession();
}

test "publishBuiltin rejects unknown names" {
    const Stub = struct {
        called: bool = false,
        pub fn publish(self: *@This(), name: []const u8, comptime T: type, init: anytype) !pancake.driver.Capability {
            _ = name;
            _ = T;
            _ = init;
            self.called = true;
            return error.Unexpected;
        }
    };
    var stub: Stub = .{};
    try std.testing.expectError(error.UnknownBuiltin, cli.ocapn.publishBuiltin(&stub, "nope"));
    try std.testing.expect(!stub.called);
}
