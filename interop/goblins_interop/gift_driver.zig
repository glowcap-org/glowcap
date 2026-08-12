//! Live three-party handoff, with pancake as the GIFTER (the introducer),
//! driven through `driver.core.Host` + `driver.Bridge` + `net.TcpLoop`
//! (ADR-0068, ADR-0076). The mirror of `handoff_driver.zig` (pancake as
//! recipient).
//!
//! Topology (TCP loopback):
//!   Bob    (Goblins exporter)  hosts a greeter behind a fixed swiss.
//!   Gifter (pancake)           fetches Bob's greeter, publishes an introducer
//!                              that returns it, and listens for the recipient.
//!   Carol  (Goblins recipient) dials the pancake introducer, asks for the
//!                              greeter, redeems pancake's give, and calls Bob
//!                              directly.
//!
//! Needs `racket` + the `goblins` collection on PATH; runs as the sibling step
//! `zig build goblins-gift`, not in the in-tree check.
//!
//! With `--hinted-exporter` (the sibling step `zig build goblins-gift-hints`),
//! Bob's advertised location carries an opaque `route-token` entry in a hints
//! mapping. The pancake gifter embeds that hinted
//! location verbatim in its signed give; Carol decodes the mapping-shaped
//! hints through the upstream unmarshaller, dials the hinted node, and
//! re-encodes the give inside her signed `desc:handoff-receive`; Bob then
//! verifies the gifter's give signature over his own re-encoding. A green run
//! therefore proves a mapping-shaped hinted locator survives live Goblins
//! decode, session-table lookup, and byte-exact re-canonicalization at both
//! Goblins peers. The driver additionally requires Carol's netlayer trace to
//! report the hint (`HINT SEEN:`), so the run cannot pass vacuously with an
//! unhinted locator. (The give's locator must equal the exporter's
//! hello-declared location hints-and-all: Goblins keys its withdrawal
//! session lookup by the full node value, so a hint the hello did not carry
//! breaks redemption — the pinned finding beside the hints-type one.)

const std = @import("std");
const pancake = @import("pancake");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const crypto = pancake.foundation.crypto;
const driver = pancake.driver;
const net = pancake.net;
const tcp = pancake.net.tcp;

const Host = driver.core.Host;
const HostSession = driver.core.HostSession;
const TcpBridge = driver.Bridge(net.TcpLoop);
const runLoop = harness.LoopRunner(net.TcpLoop).runUntilFlag;

const host_addr = "127.0.0.1";
const default_bob_port: u16 = 22120;
const frame_cap: usize = 1 << 16;
const exporter_script = "conformance/goblins-peer/racket/gift-exporter-host.rkt";
const recipient_script = "conformance/goblins-peer/racket/gift-recipient.rkt";
const greeter_swiss = "pancakeGiftGreeterSwissnum000001";
const introducer_swiss = "introducer";
const deadline_ms: u64 = 60_000;

fn pokeListener(io: std.Io, port: u16) void {
    if (port == 0) return;
    const address = std.Io.net.IpAddress.parse(host_addr, port) catch return;
    var stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

const route_hint_name = "route-token";
const route_hint_bytes = [_]u8{0xa5} ** 64;

const GifterState = struct {
    host: *Host,
    bridge: *TcpBridge,
    bob_conn: ?*HostSession = null,
    greeter: ?model.Reference = null,
    fetched: *std.atomic.Value(bool),

    fn onFetched(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *GifterState = @ptrCast(@alignCast(ctx.?));
        switch (resolution) {
            .fulfilled => |value| {
                if (value == .reference) {
                    self.greeter = value.reference;
                    std.debug.print("goblins-gift: fetched goblins-bob's greeter\n", .{});
                } else {
                    std.debug.print("goblins-gift: fetch settled to a non-reference\n", .{});
                }
            },
            .broken => |reason| std.debug.print("goblins-gift: fetch broke: {s}\n", .{reason}),
            .give => {},
        }
        self.fetched.store(true, .release);
    }
};

const Introducer = struct {
    state: *GifterState,

    pub fn handle(self: *Introducer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "get-greeter")) return error.NoSuchMethod;
        const greeter = self.state.greeter orelse return error.NotReady;
        return .{ .reference = greeter };
    }
};

fn publishIntroducer(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
    const state: *GifterState = @ptrCast(@alignCast(ctx.?));
    _ = try served.publish(vat, introducer_swiss, Introducer, .{ .state = state });
}

fn gifterOnOpen(ctx: ?*anyopaque, bridge: *TcpBridge, conn: *TcpBridge.Slot) anyerror!void {
    const state: *GifterState = @ptrCast(@alignCast(ctx.?));
    if (conn.leg != .app_dial or conn.session.role != .dialed) return;
    if (state.bob_conn != null) return;
    state.bob_conn = conn.session;
    std.debug.print("goblins-gift: session open (pancake as gifter -> bob)\n", .{});
    const vow = try state.host.fetch(conn.session, greeter_swiss);
    try state.host.vowOn(vow, .{ .ctx = state, .func = GifterState.onFetched });
    try bridge.drainActions();
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
    // locator never reached Carol's dial — vacuous, so it fails.
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
            "goblins-gift OK: pancake minted a three-party handoff give that live Goblins redeemed, reaching the exporter directly\n",
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
    var seed: [crypto.SEED_BYTES]u8 = undefined;
    io.randomSecure(&seed) catch return error.HandshakeEntropyFailed;
    var session_root: [crypto.SEED_BYTES]u8 = undefined;
    io.randomSecure(&session_root) catch return error.HandshakeEntropyFailed;

    var host = Host.init(allocator, seed, session_root, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer host.deinit();

    var fetched = std.atomic.Value(bool).init(false);
    var state: GifterState = undefined;
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &host, io, &loop, .{
        .publish = publishIntroducer,
        .publish_ctx = &state,
        .on_open = gifterOnOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();
    state = .{
        .host = &host,
        .bridge = &bridge,
        .fetched = &fetched,
    };

    loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&bridge), TcpBridge.hookOptions(.{
        .max_conns = 8,
        .listen = 0,
    }));
    defer loop.deinit();
    const gifter_port = loop.port().?;
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const bound_addr = try tcp.parseHostPort(host_addr, gifter_port);
    const bound = tcp.locator(&designator_buf, bound_addr).designator;
    try bridge.attach(model.transport.Known.tcp.metadata(), bound, &.{});

    var bob_designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const bob_addr = try tcp.parseHostPort(host_addr, bob_port);
    const bob_locator = tcp.locator(&bob_designator_buf, bob_addr);
    try bridge.dialOutbound(bob_locator);

    var loop_done = std.atomic.Value(bool).init(false);
    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoop, .{ &loop, &loop_done, &loop_err });
    defer {
        loop_done.store(true, .release);
        pokeListener(io, gifter_port);
        loop_future.await(io);
    }

    try harness.untilFlag(io, deadline_ms, &fetched);
    if (state.greeter == null) return error.FetchFailed;

    var gifter_designator_buf: [64]u8 = undefined;
    const gifter_designator = try std.fmt.bufPrint(&gifter_designator_buf, "{s}:{d}", .{ host_addr, gifter_port });
    std.debug.print("goblins-gift: pancake publishing introducer swiss={s} on {s}\n", .{ introducer_swiss, gifter_designator });

    const carol_argv_hinted = [_][]const u8{
        goblins_child.racket_path,
        recipient_script,
        gifter_designator,
        introducer_swiss,
        carol_port_str,
        route_hint_name,
    };
    var carol = try std.process.spawn(io, .{
        .argv = if (hinted_exporter) carol_argv_hinted[0..] else carol_argv_hinted[0..5],
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
    if (loop_err) |err| return err;
}
