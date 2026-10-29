//! Live Goblins over Tor: a glowcap peer and a real Spritely Goblins vat
//! hold an OCapN CapTP session across a hidden service circuit.
//!
//! This is the check the onion netlayer was written for. `onion` is the one
//! transport symbol the OCapN draft standardizes and the one upstream Goblins
//! ships, so it is the only ground where a glowcap peer and a Goblins vat meet
//! without either having written the other's transport. Every other live interop
//! in this tree runs over something this repository authored for the partner: the
//! cleartext socket in `tcp-netlayer.rkt`, the endpoint in `iroh-netlayer.rkt`.
//! Here the vat uses `goblins/ocapn/netlayer/onion`, which glowcap had no hand in,
//! and glowcap uses its own resident, and the two agree because both follow the
//! draft.
//!
//! The dialing bracket: glowcap starts a Tor, spawns the Goblins vat
//! (`goblins-onion-host.rkt`) pointed at that same daemon, reads the service id
//! and the published echo swiss-num off the vat's NDJSON readiness lines, dials
//! `ocapn://<service-id>.onion`, and bootstrap-fetches and calls the echo cap.
//!
//! The listening bracket: glowcap publishes its own onion service and a real
//! Goblins client (`glowcap-onion-caller.rkt`) dials in and calls a Greeter.
//!
//! The hinted-hello probe: glowcap dials the same vat once more with a hello
//! whose signed location carries the `glowcap/*` profile hints, the exact
//! bytes a glowcap peer handed the glowcap form of an onion address sends
//! (ADR-0042). The pinned `captp.rkt` start-session arm is transport-blind
//! and stores any claimed node, so the vat must open the session, ignore the
//! hints, settle the baseline, and answer the echo. This is the live
//! observation behind the finding that only the Goblins *dial* arm refuses a
//! hinted onion locator, never the hello.
//!
//! Two things about the daemon are decided by the partner rather than by glowcap.
//! Its control endpoint takes no credential, because Goblins sends a bare
//! `AUTHENTICATE`, so the check runs the narrower of the two peers' capabilities.
//! And both peers share one Tor, a thing a deployment would not do but is
//! exactly right here: the bytes still cross the network between two hidden
//! service circuits, and one bootstrap is paid once instead of twice.
//!
//! Not part of the self-contained `zig build check`: it needs `tor` and outbound
//! network access plus `racket` and the `goblins` collection on PATH, so it runs
//! as the sibling step `zig build goblins-onion`.

const std = @import("std");
const glowcap = @import("glowcap");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const net = glowcap.net;
const Tor = harness.Tor;

const frame_cap = 16 * 1024;
/// Tor's default `SocksTimeout`: how long it holds a dial unattached when the
/// service's descriptor has not reached the directories yet, before it answers status-allow: pending state or quoted runtime label
/// the SOCKS request with a refusal.
const tor_socks_timeout_ms = 120_000;
/// One dial attempt's budget. The handshake budget covers the SOCKS connect as
/// well as the hello, and the vat announces its service id before the
/// descriptor is uploaded, so an attempt has to outlast Tor's hold for the
/// verdict to arrive and be retried, plus a hello across a fresh circuit.
const handshake_budget_ms = tor_socks_timeout_ms + 60_000;
/// How long to keep retrying a dial while a freshly minted service's descriptor
/// reaches the directories the other side will ask.
const publish_budget_ms = 240_000;

/// Session budgets for every session here: the handshake under its own
/// budget, and each blocking answer wait under the publish budget, because a
/// first call across a fresh circuit can wait on the network.
const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = handshake_budget_ms },
    .settle = .{ .ms = publish_budget_ms },
};

const host_script = "conformance/goblins-peer/racket/goblins-onion-host.rkt";
const caller_script = "conformance/goblins-peer/racket/glowcap-onion-caller.rkt";

const caller_name = "goblins";
const greeter_swiss = "glowcap-onion-greeter";
const echo_payload = "glowcap-over-tor";

// Positional, because a Goblins client invokes a cap with `(<- actor "name")`
// and carries no verb.
const Greeter = harness.PositionalReplyBehavior("hello {s}, from glowcap over tor");

/// The listening bracket's server half: accept the one circuit Tor forwards,
/// publish the Greeter, and serve until the Goblins client hangs up.
const serveOne = harness.AcceptServeOne(Greeter, greeter_swiss, null).run;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // No cookie: the partner's netlayer authenticates with a bare `AUTHENTICATE`.
    var daemon = try Tor.start(allocator, io, .{ .cookie_authentication = false });
    defer daemon.stop();
    std.debug.print("goblins-onion: tor bootstrapped\n", .{});

    try dialGoblinsVat(io, allocator, init.environ_map, &daemon);
    try serveGoblinsClient(io, allocator, init.environ_map, &daemon);

    std.debug.print(
        "goblins-onion: OK, a real Goblins vat and glowcap held OCapN sessions over Tor in both directions\n",
        .{},
    );
}

/// Bracket one: the Goblins vat publishes an onion service and glowcap dials it.
fn dialGoblinsVat(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    daemon: *Tor,
) !void {
    const work_dir = try std.fmt.allocPrint(allocator, "{s}/goblins", .{daemon.dir});
    defer allocator.free(work_dir);

    const ready = try goblins_child.spawnHostAwaitReadiness(
        io,
        allocator,
        environ_map,
        "goblins-onion",
        "echo cap",
        goblins_child.swiss_field,
        &.{ host_script, daemon.control_path, daemon.socks_path, work_dir },
        .inherit,
    );
    defer allocator.free(ready.block);
    var child = ready.child;
    var reaped = false;
    defer if (!reaped) child.kill(io);

    const service_id = goblins_child.extractField(ready.block, "\"service-id\":\"") orelse
        return error.NoGoblinsServiceId;
    const swiss = goblins_child.extractField(ready.block, goblins_child.swiss_field) orelse
        return error.NoGoblinsSwiss;
    std.debug.print(
        "goblins-onion: the vat is reachable at ocapn://{s}.onion, publishing echo swiss={s}\n",
        .{ service_id, swiss },
    );

    // Dial-only: no control endpoint, so this side can publish nothing.
    const transports: driver.Transports = .{
        .symbols = &.{.onion},
        .onion = .{ .socks = try net.tcp.parseDesignator(daemon.socks_tcp) },
    };

    callEcho(io, allocator, transports, service_id, swiss) catch |err| {
        std.debug.print("goblins-onion: dialing the vat failed: {s}\n", .{@errorName(err)});
        goblins_child.dumpChildStderr(io, "goblins-onion", &child);
        child.kill(io);
        reaped = true;
        return err;
    };
    std.debug.print("goblins-onion: the vat's echo cap answered across a circuit\n", .{});

    probeHintedHello(io, allocator, transports, service_id, swiss) catch |err| {
        std.debug.print("goblins-onion: hinted-hello probe failed: {s}\n", .{@errorName(err)});
        goblins_child.dumpChildStderr(io, "goblins-onion", &child);
        child.kill(io);
        reaped = true;
        return err;
    };
    child.kill(io);
    reaped = true;
    std.debug.print(
        "goblins-onion: the vat accepted a glowcap-hinted hello, settled the baseline, and answered the echo\n",
        .{},
    );
}

/// Dial the vat's service, fetch its echo cap, and assert the payload survived.
fn callEcho(
    io: std.Io,
    allocator: std.mem.Allocator,
    transports: driver.Transports,
    service_id: []const u8,
    swiss: []const u8,
) !void {
    // No hints, and the ephemeral identity that goes with an address designator:
    // an onion service id says where to dial, never who answers, and the pinned
    // Goblins refuses a hinted onion locator (ADR-0042).
    const locator: model.PeerLocator = .{
        .transport = model.transport.onion,
        .designator = service_id,
        .hints = model.Hints.emptyFalse(),
    };

    const session = try connectWhilePublishing(io, allocator, transports, locator, opts);
    defer session.deinit();
    std.debug.print("goblins-onion: session open with the vat over Tor\n", .{});

    try expectEchoAnswer(session, allocator, swiss);
}

/// Fetch the vat's echo cap and require the payload back. The echo actor is
/// `(lambda args args)`, so it answers with its argument list, Goblins
/// invokes a cap positionally, so the call carries no verb.
fn expectEchoAnswer(session: *driver.Session, allocator: std.mem.Allocator, swiss: []const u8) !void {
    const echo = try session.fetch(swiss);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const reply = try session.call(echo, null, &.{.{ .bytes = echo_payload }}, arena_state.allocator());
    switch (reply) {
        .fulfilled => |payload| {
            if (payload != .list or payload.list.len != 1) return error.EchoWrongPayload;
            const text: []const u8 = switch (payload.list[0]) {
                .bytes, .string => |t| t,
                else => return error.EchoWrongPayload,
            };
            if (!std.mem.eql(u8, text, echo_payload)) return error.EchoWrongPayload;
        },
        .broken => |reason| {
            std.debug.print("goblins-onion: echo broke: {s}\n", .{reason});
            return error.EchoBroke;
        },
    }
}

/// Dial the vat as though someone handed us the glowcap form of its address
/// (a hinted onion locator naming a partner that is Goblins) and
/// require the full baseline conversation on the session that opens. The
/// dial mints partner knowledge from the handed form exactly as a real one
/// would, and the send path refuses a hello whose hints fail to state the
/// configured preference (`validateExactAdvertisedProfile`), so an open
/// session is proof the hinted hello reached the vat and was accepted, and
/// the settled baseline is proof the vat ignored the hints rather than
/// following them: misapplied knowledge degrades to the baseline, never to
/// a failure.
fn probeHintedHello(
    io: std.Io,
    allocator: std.mem.Allocator,
    transports: driver.Transports,
    service_id: []const u8,
    swiss: []const u8,
) !void {
    var hinted_opts = opts;
    hinted_opts.captp_version = .next;
    hinted_opts.codec = .capnp;

    const handed_hints = [_]model.HintEntry{.{
        .name = model.transport.hint_captp_version,
        .value = .{ .string = model.CaptpVersion.next.wireString() },
    }};
    const locator: model.PeerLocator = .{
        .transport = model.transport.onion,
        .designator = service_id,
        .hints = .{ .entries = &handed_hints },
    };
    const session = try connectWhilePublishing(io, allocator, transports, locator, hinted_opts);
    defer session.deinit();

    const state = &session.peer().session_state;
    if (state.captp_version != .v1_0 or state.codec != .syrup) {
        std.debug.print(
            "goblins-onion: hinted-hello probe settled captp={s} codec={s}, expected the baseline\n",
            .{ @tagName(state.captp_version), @tagName(state.codec) },
        );
        return error.HintedHelloSettledOffBaseline;
    }
    try expectEchoAnswer(session, allocator, swiss);
}

/// Bracket two: glowcap publishes an onion service and the Goblins client dials.
fn serveGoblinsClient(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    daemon: *Tor,
) !void {
    const server = try driver.listen(allocator, io, .{
        .symbols = &.{.onion},
        .onion = .{
            .socks = try net.tcp.parseDesignator(daemon.socks_tcp),
            .control = try net.tcp.parseDesignator(daemon.control_tcp),
        },
    }, model.transport.onion, .{ .designator = "" }, .ephemeral, opts);
    defer server.deinit();
    var service_id_buf: [128]u8 = undefined;
    const service_id = try server.localDesignator(&service_id_buf);
    std.debug.print("goblins-onion: glowcap is reachable at ocapn://{s}.onion\n", .{service_id});

    var serving = try io.concurrent(serveOne, .{ io, server, @as(u64, publish_budget_ms) });

    // The Goblins client retries its own dial while the descriptor publishes, so
    // this side only has to be listening before the child starts.
    var child_argv: [8][]const u8 = undefined;
    var child = try std.process.spawn(io, .{
        .argv = goblins_child.racketArgv(&child_argv, &.{
            caller_script,
            service_id,
            greeter_swiss,
            caller_name,
            daemon.control_path,
            daemon.socks_path,
        }),
        .environ_map = environ_map,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    try serving.await(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("goblins-onion: the goblins client exited {d}\n", .{code});
            return error.GoblinsClientFailed;
        },
        else => return error.GoblinsClientFailed,
    }
    std.debug.print("goblins-onion: a Goblins client called a glowcap actor across a circuit\n", .{});
}

/// `driver.connect`, retried while Tor answers "no such service".
///
/// A freshly minted version 3 service is not reachable the instant `ADD_ONION`
/// returns: its descriptor has to reach the hash ring the client will ask, and
/// until then Tor holds the dial for `tor_socks_timeout_ms` and then refuses
/// it.
fn connectWhilePublishing(
    io: std.Io,
    allocator: std.mem.Allocator,
    transports: driver.Transports,
    locator: model.PeerLocator,
    session_opts: driver.SessionOptions,
) !*driver.Session {
    const deadline = harness.deadlineAfter(io, publish_budget_ms);
    while (true) {
        return driver.connect(allocator, io, transports, locator, .ephemeral, session_opts) catch |err| switch (err) {
            error.ConnectionRefused, error.ConnectionLost, error.NetworkUnreachable => {
                if (harness.expired(io, deadline)) return err;
                try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(2_000), .real);
                continue;
            },
            else => return err,
        };
    }
}
