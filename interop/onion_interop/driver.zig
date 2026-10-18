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
const driver = glowcap.driver;
const net = glowcap.net;
const Tor = harness.Tor;

const frame_cap = 16 * 1024;
const swiss = "greeter";
const greeting = "hello from a hidden service";

/// How long to keep retrying the dial while the service descriptor publishes. A
/// fresh v3 service is commonly reachable inside a minute. This is generous
/// because a failure here should mean unreachable, not merely slow.
const publish_budget_ms = 240_000;

/// Session budgets for both processes: a handshake and each blocking answer
/// wait complete well inside a minute once a circuit exists.
const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 60_000 },
    .settle = .{ .ms = 60_000 },
};

const Greeter = harness.StaticReplyBehavior("greet", greeting);

/// Accept the one circuit Tor forwards, publish the Greeter, and serve until
/// the partner hangs up. The dialing parent retries across the publish
/// budget, so the accept waits that long.
const serve = harness.AcceptServeOne(Greeter, swiss, null).run;

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
    std.debug.print("onion-interop: tor bootstrapped, socks {s}\n", .{daemon.socks_tcp});

    const service_id, const service_key = try mintService(gpa, io, &daemon);
    defer gpa.free(service_id);
    defer gpa.free(service_key);

    // This is the sturdyref an application keeps across the server process's
    // lifetime. The first server was withdrawn before the replacement starts,
    // so a successful fetch cannot have reached stale in-process state.
    const sturdyref: model.SturdyRef = .{
        .peer = .{
            .transport = model.transport.onion,
            .designator = service_id,
            .hints = model.Hints.emptyFalse(),
        },
        .swissnum = swiss,
    };
    std.debug.print("onion-interop: recorded ocapn://{s}.onion before server restart\n", .{service_id});

    const cookie_path = try std.fmt.allocPrint(gpa, "{s}/control_auth_cookie", .{daemon.dir});
    defer gpa.free(cookie_path);
    var child = try std.process.spawn(io, .{
        .argv = &.{
            executable,
            "--restore-server",
            daemon.socks_tcp,
            daemon.control_tcp,
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
    const dial_transports: driver.Transports = .{
        .symbols = &.{.onion},
        .onion = .{ .socks = try net.tcp.parseDesignator(daemon.socks_tcp) },
    };
    try dialAndGreet(gpa, io, dial_transports, sturdyref);

    const term = try child.wait(io);
    reaped = true;
    switch (term) {
        .exited => |code| if (code != 0) return error.RestoredServerFailed,
        else => return error.RestoredServerFailed,
    }

    std.debug.print("onion-interop: OK, a pre-restart sturdyref resolved through the restored onion service\n", .{});
}

/// Ask Tor for a fresh service, record its id and the key that restores it,
/// and withdraw the service again. Both are owned by the caller.
fn mintService(gpa: std.mem.Allocator, io: std.Io, daemon: *const Tor) !struct { []u8, []u8 } {
    const first = try driver.listen(gpa, io, .{
        .symbols = &.{.onion},
        .onion = .{
            .socks = try net.tcp.parseDesignator(daemon.socks_tcp),
            .control = try net.tcp.parseDesignator(daemon.control_tcp),
            .auth = .{ .cookie = daemon.cookie() },
        },
    }, model.transport.onion, .{ .designator = "" }, .ephemeral, opts);
    defer first.deinit();

    var id_buf: [128]u8 = undefined;
    const service_id = try gpa.dupe(u8, try first.localDesignator(&id_buf));
    errdefer gpa.free(service_id);

    // The service key is transport-owned restoration state: ask its size,
    // then copy it out.
    var probe: [0]u8 = .{};
    const key_len = (try first.restorationState(&probe)) orelse return error.MissingServiceKey;
    if (key_len == 0) return error.MissingServiceKey;
    const service_key = try gpa.alloc(u8, key_len);
    errdefer gpa.free(service_key);
    if ((try first.restorationState(service_key)) != key_len) return error.MissingServiceKey;

    if (first.close()) |failure| return failure.chain.cause;
    return .{ service_id, service_key };
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
    const server = try driver.listen(gpa, io, .{
        .symbols = &.{.onion},
        .onion = .{
            .socks = try net.tcp.parseDesignator(socks),
            .control = try net.tcp.parseDesignator(control),
            .auth = .{ .cookie = cookie },
            .service_key = service_key,
        },
    }, model.transport.onion, .{ .designator = "" }, .ephemeral, opts);
    defer server.deinit();
    var id_buf: [128]u8 = undefined;
    const restored_id = try server.localDesignator(&id_buf);
    if (!std.mem.eql(u8, restored_id, expected_service_id))
        return error.RestoredServiceChangedAddress;
    std.debug.print("onion-interop: fresh server process restored ocapn://{s}.onion\n", .{restored_id});

    try serve(io, server, publish_budget_ms);
}

/// Dial the service through Tor, fetch the Greeter, and call it.
fn dialAndGreet(
    gpa: std.mem.Allocator,
    io: std.Io,
    transports: driver.Transports,
    sturdyref: model.SturdyRef,
) !void {
    const session = try connectWhileDescriptorPublishes(gpa, io, transports, sturdyref.peer);
    defer session.deinit();

    const greeter = try session.fetch(sturdyref.swissnum);
    try harness.expectStringReply(session, gpa, greeter, "greet", &.{}, greeting);
}

/// `driver.connect`, retried while Tor answers "no such service".
///
/// A freshly minted v3 service is not reachable the instant `ADD_ONION` returns:
/// the descriptor has to reach the hash ring the client will ask, and until it
/// does Tor refuses the dial. Failing on the first refusal would make this step
/// report a broken transport whenever it ran promptly.
fn connectWhileDescriptorPublishes(
    gpa: std.mem.Allocator,
    io: std.Io,
    transports: driver.Transports,
    locator: model.PeerLocator,
) !*driver.Session {
    const deadline = harness.deadlineAfter(io, publish_budget_ms);
    var attempts: usize = 0;
    while (true) {
        attempts += 1;
        return driver.connect(gpa, io, transports, locator, .ephemeral, opts) catch |err| switch (err) {
            error.ConnectionRefused, error.ConnectionLost, error.NetworkUnreachable => {
                if (harness.expired(io, deadline)) {
                    std.debug.print(
                        "onion-interop: the service never became reachable after {d} dials\n",
                        .{attempts},
                    );
                    return err;
                }
                try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2_000), .real);
                continue;
            },
            else => return err,
        };
    }
}
