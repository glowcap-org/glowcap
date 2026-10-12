//! Live three-party handoff, with glowcap as the GIFTER (the introducer),
//! served by one `driver.Server` (ADR-0068). The mirror of
//! `handoff_driver.zig` (glowcap as recipient).
//!
//! Topology (TCP loopback):
//!   Bob    (Goblins exporter)  hosts a greeter behind a fixed swiss.
//!   Gifter (glowcap)           fetches Bob's greeter, publishes an introducer
//!                              that returns it, and listens for the recipient.
//!   Carol  (Goblins recipient) dials the glowcap introducer, asks for the
//!                              greeter, redeems glowcap's give, and calls Bob
//!                              directly.
//!
//! Needs `racket` + the `goblins` collection on PATH, runs as the sibling step
//! `zig build goblins-gift`, not in the in-tree check.
//!
//! With `--hinted-exporter` (the sibling step `zig build goblins-gift-hints`),
//! Bob's advertised location carries an opaque `route-token` entry in a hints
//! mapping. The glowcap gifter embeds that hinted
//! location verbatim in its signed give, Carol decodes the mapping-shaped
//! hints through the upstream unmarshaller, dials the hinted node, and
//! re-encodes the give inside her signed `desc:handoff-receive`, Bob then
//! verifies the gifter's give signature over his own re-encoding. A green run
//! therefore proves a mapping-shaped hinted locator survives live Goblins
//! decode, session-table lookup, and byte-exact re-canonicalization at both
//! Goblins peers. The driver additionally requires Carol's netlayer trace to
//! report the hint (`HINT SEEN:`), so the run cannot pass vacuously with an
//! unhinted locator. (The give's locator must equal the exporter's
//! hello-declared location hints-and-all: Goblins keys its withdrawal
//! session lookup by the full node value, so a hint the hello did not carry
//! breaks redemption: the pinned finding beside the hints-type one.)

const std = @import("std");
const glowcap = @import("glowcap");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

const host_addr = "127.0.0.1";
const default_bob_port: u16 = 22120;
const frame_cap: usize = 1 << 16;
const exporter_script = "conformance/goblins-peer/racket/gift-exporter-host.rkt";
const recipient_script = "conformance/goblins-peer/racket/gift-recipient.rkt";
const greeter_swiss = "glowcapGiftGreeterSwissnum000001";
const introducer_swiss = "introducer";
const deadline_ms: u64 = 60_000;

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 20_000 },
    .settle = .{ .ms = 20_000 },
};

const route_hint_name = "route-token";
const route_hint_bytes = @as([64]u8, @splat(0xa5));

const Introducer = struct {
    greeter: driver.Capability,

    pub fn handle(self: *Introducer, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = ht;
        _ = args;
        if (!std.mem.eql(u8, verb, "get-greeter")) return error.NoSuchMethod;
        return .{ .capability = self.greeter };
    }
};

/// Fetch Bob's greeter over the gifter's own runtime, publish the introducer
/// that hands it out, then serve the recipient until the run ends. One
/// runtime holds both sessions, so the give names a session the gifter owns.
fn serveGifter(
    gifter: *driver.Server,
    bob_locator: model.PeerLocator,
    settled: *std.atomic.Value(bool),
    published: *std.atomic.Value(bool),
    done: *std.atomic.Value(bool),
) anyerror!void {
    // A setup failure still releases the waiting main thread.
    defer settled.store(true, .release);
    const bob_session = try gifter.runtime.connectLocator(bob_locator, .inherit);
    const bob = try driver.Session.adopt(gifter.runtime, bob_session);
    defer bob.deinit();
    std.debug.print("goblins-gift: session open (glowcap as gifter -> bob)\n", .{});
    const greeter = try bob.fetch(greeter_swiss);
    std.debug.print("goblins-gift: fetched goblins-bob's greeter\n", .{});
    try gifter.publish(introducer_swiss, Introducer, .{ .greeter = greeter });
    published.store(true, .release);
    settled.store(true, .release);

    var carol: ?*driver.Session = null;
    defer if (carol) |session| session.deinit();
    while (!done.load(.acquire)) {
        if (carol == null and try gifter.waitAcceptable(20)) carol = try gifter.accept();
        // Bob's session carries the recipient's withdraw; both must turn.
        _ = bob.stepReadable(10) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => {},
            else => |e| return e,
        };
        if (carol) |session| _ = session.stepReadable(10) catch |err| switch (err) {
            error.ConnectionClosed, error.ProtocolAbort => {},
            else => |e| return e,
        };
    }
}

fn readCarolOk(io: std.Io, child: *std.process.Child, expect_hint: bool) !void {
    const out = child.stdout orelse return error.NoChildStdout;
    var rbuf: [8192]u8 = undefined;
    var reader = out.readerStreaming(io, &rbuf);
    const deadline = harness.deadlineAfter(io, deadline_ms);
    var saw_ok = false;
    var saw_hint = false;
    while (!harness.expired(io, deadline)) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        std.debug.print("goblins-gift: {s}", .{line});
        if (std.mem.indexOf(u8, line, "HINT SEEN: " ++ route_hint_name) != null) {
            saw_hint = true;
        }
        if (std.mem.indexOf(u8, line, "GIFT OK:") != null and std.mem.indexOf(u8, line, "goblins-carol") != null) {
            saw_ok = true;
            break;
        }
        if (std.mem.indexOf(u8, line, "GIFT ERR:") != null or std.mem.indexOf(u8, line, "GIFT TIMEOUT") != null) {
            return error.GiftFailed;
        }
    }
    if (!saw_ok) return error.GiftFailed;
    // A hinted run that redeems without the trace marker means the hinted
    // locator never reached Carol's dial, vacuous, so it fails.
    if (expect_hint and !saw_hint) return error.HintNotObserved;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const bob_port = try harness.parsePortFlag(init.minimal.args, "goblins-gift", default_bob_port, .{
        .max = 65534,
        .note = " (carol binds port+1)",
        .tolerated = &.{"--hinted-exporter"},
    });
    const hinted_exporter = harness.hasFlag(init.minimal.args, "--hinted-exporter");
    var bob_port_buf: [8]u8 = undefined;
    const bob_port_str = try std.fmt.bufPrint(&bob_port_buf, "{d}", .{bob_port});
    var carol_port_buf: [8]u8 = undefined;
    const carol_port_str = try std.fmt.bufPrint(&carol_port_buf, "{d}", .{bob_port + 1});

    var hint_hex_buf: [route_hint_bytes.len * 2]u8 = undefined;
    const bob_argv_hinted = [_][]const u8{
        exporter_script,
        host_addr,
        bob_port_str,
        route_hint_name,
        std.fmt.bufPrint(&hint_hex_buf, "{x}", .{route_hint_bytes[0..]}) catch unreachable,
    };
    const bob_argv: []const []const u8 = if (hinted_exporter) bob_argv_hinted[0..] else bob_argv_hinted[0..3];

    const hosted = try goblins_child.spawnHostAwaitSwiss(io, allocator, init.environ_map, "goblins-gift", "greeter", bob_argv);
    var bob = hosted.child;
    var bob_reaped = false;
    defer if (!bob_reaped) bob.kill(io);

    const published = hosted.swiss;
    defer allocator.free(published);
    std.debug.print("goblins-gift: goblins-bob exporting greeter swiss={s} on {s}:{s}\n", .{ greeter_swiss, host_addr, bob_port_str });

    gifterStep(io, allocator, init.environ_map, bob_port, carol_port_str, hinted_exporter) catch |err| {
        goblins_child.dumpChildStderr(io, "goblins-gift", &bob);
        return err;
    };

    bob.kill(io);
    bob_reaped = true;
    if (hinted_exporter) {
        std.debug.print(
            "goblins-gift-hints OK: live Goblins decoded, re-encoded, and verified a give whose exporter locator carries the {s} hint dict\n",
            .{route_hint_name},
        );
    } else {
        std.debug.print(
            "goblins-gift OK: glowcap minted a three-party handoff give that live Goblins redeemed, reaching the exporter directly\n",
            .{},
        );
    }
}

fn gifterStep(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    bob_port: u16,
    carol_port_str: []const u8,
    hinted_exporter: bool,
) !void {
    var gifter = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = host_addr ++ ":0" }, .ephemeral, opts);
    defer gifter.deinit();
    var gifter_designator_buf: [64]u8 = undefined;
    const gifter_designator = try allocator.dupe(u8, try gifter.localDesignator(&gifter_designator_buf));
    defer allocator.free(gifter_designator);

    var bob_designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const bob_locator = tcp.locatorFromAddress(&bob_designator_buf, try tcp.parseHostPort(host_addr, bob_port));

    var settled = std.atomic.Value(bool).init(false);
    var published = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);
    var serving = try io.concurrent(serveGifter, .{ gifter, bob_locator, &settled, &published, &done });
    var serving_joined = false;
    defer if (!serving_joined) {
        done.store(true, .release);
        serving.await(io) catch {};
    };

    try harness.untilFlag(io, deadline_ms, &settled);
    if (!published.load(.acquire)) {
        done.store(true, .release);
        serving_joined = true;
        try serving.await(io);
        return error.FetchFailed;
    }
    std.debug.print("goblins-gift: glowcap publishing introducer swiss={s} on {s}\n", .{ introducer_swiss, gifter_designator });

    const carol_script_argv = [_][]const u8{
        recipient_script,
        gifter_designator,
        introducer_swiss,
        carol_port_str,
        route_hint_name,
    };
    var carol_argv: [8][]const u8 = undefined;
    var carol = try std.process.spawn(io, .{
        .argv = goblins_child.racketArgv(&carol_argv, if (hinted_exporter) carol_script_argv[0..] else carol_script_argv[0..4]),
        .environ_map = environ_map,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var carol_reaped = false;
    defer if (!carol_reaped) carol.kill(io);

    readCarolOk(io, &carol, hinted_exporter) catch |err| {
        goblins_child.dumpChildStderr(io, "goblins-gift", &carol);
        return err;
    };
    carol.kill(io);
    carol_reaped = true;
    done.store(true, .release);
    serving_joined = true;
    try serving.await(io);
}
