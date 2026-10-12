//! Live Tor: two glowcap peers hold a real OCapN conversation over a hidden
//! service (ADR-0108).
//!
//! Everything else in the tree that exercises the onion transport drives a fake
//! daemon on loopback, so it proves glowcap agrees with the bytes pinned against
//! the pinned Spritely Goblins netlayer and the upstream OCapN suite. This is the
//! step that proves a real Tor accepts those bytes. One peer asks Tor for a
//! service, records its sturdyref, and withdraws it. A fresh child process
//! restores the saved service key and serves a Greeter behind the same address,
//! the parent resolves the pre-restart sturdyref through Tor and calls it. The
//! bytes in between cross the Tor network.
//!
//! The driver starts its own Tor through the shared `harness.Tor`, so the check
//! is one command rather than a setup procedure.
//!
//! Two waits dominate the runtime and neither is glowcap's. Tor bootstraps into
//! the network, which takes seconds, and a freshly minted service's descriptor
//! takes tens of seconds more to reach the directories the client will ask. The
//! dial retries across that window rather than failing on the first refusal.
//!
//! Needs Tor on `PATH` and outbound network access, so it is a sibling of
//! `zig build check` rather than a member: `zig build onion-interop`.

const std = @import("std");
const glowcap = @import("glowcap");
const harness = @import("interop_harness");

const model = glowcap.ocapn.model;
const engine = glowcap.ocapn.engine;
const driver = glowcap.driver;
const actors = glowcap.actors;
const onion = glowcap.net.onion;
const Tor = harness.Tor;

const frame_cap = 16 * 1024;
const swiss = "greeter";
const greeting = "hello from a hidden service";

/// How long to keep retrying the dial while the service descriptor publishes. A
/// fresh v3 service is commonly reachable inside a minute. This is generous
/// because a failure here should mean unreachable, not merely slow.
const publish_budget_ms = 240_000;

const Greeter = harness.StaticReplyActor("greet", greeting);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    const executable = args.next() orelse return error.MissingExecutable;
    if (args.next()) |mode| {
        if (!std.mem.eql(u8, mode, "--restore-server")) return error.BadArgument;
        const socks = args.next() orelse return error.BadArgument;
        const control = args.next() orelse return error.BadArgument;
        const cookie_path = args.next() orelse return error.BadArgument;
        const expected_service_id = args.next() orelse return error.BadArgument;
        if (args.next() != null) return error.BadArgument;
        return serveRestored(gpa, io, socks, control, cookie_path, expected_service_id);
    }

    var daemon = try Tor.start(gpa, io, .{ .cookie_authentication = true });
    defer daemon.stop();
    std.debug.print("onion-interop: tor bootstrapped, socks {s}\n", .{daemon.socks_path});

    var first_listener = switch (onion.Listener.create(gpa, io, .{
        .socks = daemon.socks_path,
        .control_endpoint = daemon.control_path,
        .auth = .{ .cookie = daemon.cookie() },
    })) {
        .ready => |listener| listener,
        .failed => |failure| return failure.cause,
    };
    const service_id = try gpa.dupe(u8, first_listener.designator());
    defer gpa.free(service_id);
    const service_key = try gpa.dupe(u8, first_listener.serviceKey());
    defer gpa.free(service_key);
    if (service_key.len == 0) return error.MissingServiceKey;

    // This is the sturdyref an application keeps across the server process's
    // lifetime. Withdraw the first listener before the replacement starts, so
    // a successful fetch cannot have reached stale in-process state.
    const sturdyref: model.SturdyRef = .{
        .peer = .{
            .transport = onion.transport_name,
            .designator = service_id,
            .hints = model.Hints.emptyFalse(),
        },
        .swissnum = swiss,
    };
    if (first_listener.deinit()) |failure| return failure.cause;
    std.debug.print("onion-interop: recorded ocapn://{s}.onion before server restart\n", .{service_id});

    const cookie_path = try std.fmt.allocPrint(gpa, "{s}/control_auth_cookie", .{daemon.dir});
    defer gpa.free(cookie_path);
    var child = try std.process.spawn(io, .{
        .argv = &.{
            executable,
            "--restore-server",
            daemon.socks_path,
            daemon.control_path,
            cookie_path,
            service_id,
        },
        .environ_map = init.environ_map,
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    var reaped = false;
    defer if (!reaped) child.kill(io);
    {
        const child_stdin = child.stdin orelse return error.MissingChildStdin;
        child.stdin = null;
        defer child_stdin.close(io);
        try child_stdin.writeStreamingAll(io, service_key);
        try child_stdin.writeStreamingAll(io, "\n");
    }

    // The dialing side has no control endpoint, so it cannot publish a service.
    var dial_res: onion.Resident = .{ .io = io, .config = .{ .socks = daemon.socks_path } };
    try dialAndGreet(gpa, io, &dial_res, sturdyref);

    const term = try child.wait(io);
    reaped = true;
    switch (term) {
        .exited => |code| if (code != 0) return error.RestoredServerFailed,
        else => return error.RestoredServerFailed,
    }

    std.debug.print("onion-interop: OK, a pre-restart sturdyref resolved through the restored onion service\n", .{});
}

fn serveRestored(
    gpa: std.mem.Allocator,
    io: std.Io,
    socks: []const u8,
    control: []const u8,
    cookie_path: []const u8,
    expected_service_id: []const u8,
) !void {
    // The service key is authority. Receive it over the inherited pipe rather
    // than exposing it in argv and the host's process listing.
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    const service_key_line = try stdin_reader.interface.takeDelimiterInclusive('\n');
    const service_key = std.mem.trimEnd(u8, service_key_line, "\r\n");
    if (service_key.len == 0) return error.MissingServiceKey;

    const cookie = try std.Io.Dir.cwd().readFileAlloc(io, cookie_path, gpa, .limited(4096));
    defer gpa.free(cookie);
    var listener = switch (onion.Listener.create(gpa, io, .{
        .socks = socks,
        .control_endpoint = control,
        .auth = .{ .cookie = cookie },
        .service_key = service_key,
    })) {
        .ready => |listener| listener,
        .failed => |failure| return failure.cause,
    };
    defer std.debug.assert(listener.deinit() == null);
    if (!std.mem.eql(u8, listener.designator(), expected_service_id))
        return error.RestoredServiceChangedAddress;
    std.debug.print("onion-interop: fresh server process restored ocapn://{s}.onion\n", .{listener.designator()});

    var server_err: ?anyerror = null;
    var server = try io.concurrent(serve, .{ gpa, listener, &server_err });
    server.await(io);
    if (server_err) |err| return err;
}

/// Accept the one circuit Tor forwards, publish the Greeter, and serve until the
/// partner hangs up.
fn serve(gpa: std.mem.Allocator, listener: *onion.Listener, out_err: *?anyerror) void {
    var scaffold = harness.PeerScaffold.init(gpa, frame_cap) catch |err| {
        out_err.* = err;
        return;
    };
    defer scaffold.deinit();

    var session = driver.acceptVia(
        gpa,
        listener.asNetlayer(),
        &scaffold.peer,
        .ephemeral,
        scaffold.read_buf,
        scaffold.write_buf,
        .{
            .handshake = .{ .ms = 60_000 },
            .settle = .{ .ms = 60_000 },
        },
    ) catch |err| {
        out_err.* = err;
        return;
    };
    defer session.deinit();

    _ = session.publish(swiss, Greeter, .{}) catch |err| {
        out_err.* = err;
        return;
    };
    session.serve() catch |err| {
        out_err.* = err;
    };
}

/// Dial the service through Tor, fetch the Greeter, and call it.
fn dialAndGreet(
    gpa: std.mem.Allocator,
    io: std.Io,
    res: *onion.Resident,
    sturdyref: model.SturdyRef,
) !void {
    var scaffold = try harness.PeerScaffold.init(gpa, frame_cap);
    defer scaffold.deinit();

    const layers = [_]glowcap.net.netlayer.Netlayer{res.netlayer()};
    var session = try connectWhileDescriptorPublishes(gpa, io, &layers, &scaffold, sturdyref.peer);
    defer session.deinit();

    const greeter = try session.fetch(sturdyref.swissnum);
    try harness.expectStringReply(&session, gpa, greeter, "greet", &.{}, greeting);
}

/// `connectVia`, retried while Tor answers "no such service".
///
/// A freshly minted v3 service is not reachable the instant `ADD_ONION` returns:
/// the descriptor has to reach the hash ring the client will ask, and until it
/// does Tor refuses the dial. Failing on the first refusal would make this step
/// report a broken transport whenever it ran promptly.
fn connectWhileDescriptorPublishes(
    gpa: std.mem.Allocator,
    io: std.Io,
    layers: []const glowcap.net.netlayer.Netlayer,
    scaffold: *harness.PeerScaffold,
    locator: model.PeerLocator,
) !driver.BlockingSession {
    const deadline = harness.deadlineAfter(io, publish_budget_ms);
    var attempts: usize = 0;
    while (true) {
        attempts += 1;
        return driver.connectVia(
            gpa,
            layers,
            &scaffold.peer,
            locator,
            .ephemeral,
            scaffold.read_buf,
            scaffold.write_buf,
            .{
                .handshake = .{ .ms = 60_000 },
                .settle = .{ .ms = 60_000 },
            },
        ) catch |err| switch (err) {
            error.ConnectionRefused, error.ConnectionLost, error.NetworkUnreachable => {
                if (harness.expired(io, deadline)) {
                    std.debug.print(
                        "onion-interop: the service never became reachable after {d} dials\n",
                        .{attempts},
                    );
                    return err;
                }
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2_000), .real) catch {};
                continue;
            },
            else => return err,
        };
    }
}
