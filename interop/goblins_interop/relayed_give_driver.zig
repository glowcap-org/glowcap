//! A relayed give read by a live Goblins recipient: pancake introduces a third
//! party to a promise it does not own, and when that promise settles the third
//! party finds a signed give in the settlement.
//!
//! Every other handoff proof in this directory settles the introduction at the
//! moment it is asked for, so the give rides an answer the recipient asked for.
//! Here the introduction is a promise living on a vat the recipient has never
//! spoken to, so the give arrives in a *listener fire* instead. That position
//! rested on pancake's own tests until this step; the draft specification allows
//! a give wherever a Passable value goes, and this asks a real Goblins vat to
//! read one there.
//!
//! Topology (TCP loopback):
//!   Bob      (Goblins exporter)  publishes a rendezvous and holds a promise he
//!                               has not settled. He hands the promise to
//!                               pancake as a delivered argument, and settles it
//!                               when the driver writes a line to his stdin.
//!   pancake  (introducer)        holds Bob's promise, enrolls it as a promise,
//!                               and answers `get-greeter` with it. Its host
//!                               proxies the promise onto Carol's session and
//!                               waits on Bob's.
//!   Carol    (Goblins recipient) asks pancake for the greeter, waits on the
//!                               promise she is answered with, redeems the give
//!                               the settlement carries, dials Bob, and calls
//!                               what she withdrew.
//!
//! Why Bob hands the promise over as an *argument*: an answer carrying a local
//! promise chains through Goblins' own promise machinery and stays pending on
//! the wire, so pancake would be handed a pending answer rather than a promise
//! it can name. An argument marshals as `desc:import-promise`, which is the one
//! shape pancake can enroll and introduce.
//!
//! Needs `racket` + the `goblins` collection on PATH: it compiles under
//! `zig build check` and runs only as the sibling step
//! `zig build goblins-relayed-give`.

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
const default_bob_port: u16 = 22150;
const frame_cap: usize = 1 << 16;
const exporter_script = "conformance/goblins-peer/racket/deferred-exporter-host.rkt";
const recipient_script = "conformance/goblins-peer/racket/relayed-give-recipient.rkt";
const rendezvous_swiss = "pancakeDeferredRendezvousSwiss01";
const introducer_swiss = "introducer";
const holder_swiss = "holder";
const deadline_ms: u64 = 60_000;

fn pokeListener(io: std.Io, port: u16) void {
    if (port == 0) return;
    const address = std.Io.net.IpAddress.parse(host_addr, port) catch return;
    var stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

/// What the introducer half of pancake knows: Bob's session, the capability it
/// published for Bob to send the promise to, and the routing token the promise
/// is enrolled under once it arrives.
const IntroducerState = struct {
    host: *Host,
    bridge: *TcpBridge,
    bob_conn: ?*HostSession = null,
    holder: ?model.Reference = null,
    promise_token: ?u64 = null,
    held: *std.atomic.Value(bool),

    fn onRendezvous(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        const self: *IntroducerState = @ptrCast(@alignCast(ctx.?));
        const conn = self.bob_conn orelse return;
        const holder = self.holder orelse return;
        switch (resolution) {
            .fulfilled => |value| {
                if (value != .reference) {
                    std.debug.print("goblins-relayed-give: rendezvous fetch settled to a non-reference\n", .{});
                    return;
                }
                std.debug.print("goblins-relayed-give: fetched goblins-bob's rendezvous\n", .{});
                // Hand Bob a capability of ours, so he can send the unresolved
                // promise back to it as a delivered argument.
                const vow = self.host.send(conn, value.reference, .{
                    .verb = "hold-with",
                    .args = &.{.{ .reference = holder }},
                }) catch |err| {
                    std.debug.print("goblins-relayed-give: hold-with send: {s}\n", .{@errorName(err)});
                    return;
                };
                self.host.vowOn(vow, .{ .ctx = self, .func = onHeldWith }) catch {};
                self.bridge.drainActions() catch {};
            },
            .broken => |reason| std.debug.print("goblins-relayed-give: rendezvous fetch broke: {s}\n", .{reason}),
            .give => {},
        }
    }

    fn onHeldWith(ctx: ?*anyopaque, resolution: actors.Resolution) void {
        _ = ctx;
        switch (resolution) {
            .broken => |reason| std.debug.print("goblins-relayed-give: hold-with broke: {s}\n", .{reason}),
            .fulfilled, .give => {},
        }
    }
};

/// The capability Bob sends the promise to. Its one job is the product verb this
/// scenario exists to exercise: a promise lifted from a delivered argument is
/// enrolled *as a promise*, which is what lets the node proxy it onto a third
/// party's session instead of shipping a position that means nothing there.
const Holder = struct {
    state: *IntroducerState,

    pub fn handle(self: *Holder, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "hold")) return error.NoSuchMethod;
        const arg = try msg.arg(0);
        if (arg != .reference or arg.reference != .far) return error.NotAReference;
        const far = arg.reference.far;
        if (far.kind != .promise) return error.NotAPromise;
        const conn = self.state.bob_conn orelse return error.NotReady;
        const token = try self.state.host.enrollCapability(conn, far.import_position.int(), .promise);
        self.state.promise_token = token;
        self.state.held.store(true, .release);
        std.debug.print("goblins-relayed-give: goblins-bob handed over an unsettled promise\n", .{});
        return .{ .string = "held" };
    }
};

/// What Carol asks. Answering with the enrolled promise token is what sends the
/// host down the introducing-session proxy path.
const Introducer = struct {
    state: *IntroducerState,

    pub fn handle(self: *Introducer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "get-greeter")) return error.NoSuchMethod;
        const token = self.state.promise_token orelse return error.NotReady;
        return .{ .reference = .{ .far = model.FarRef.promise(token) } };
    }
};

fn publishIntroducer(ctx: ?*anyopaque, served: *driver.Served, vat: *actors.Vat) anyerror!void {
    const state: *IntroducerState = @ptrCast(@alignCast(ctx.?));
    _ = try served.publish(vat, introducer_swiss, Introducer, .{ .state = state });
}

fn introducerOnOpen(ctx: ?*anyopaque, bridge: *TcpBridge, conn: *TcpBridge.Slot) anyerror!void {
    const state: *IntroducerState = @ptrCast(@alignCast(ctx.?));
    if (conn.leg != .app_dial or conn.session.role != .dialed) return;
    if (state.bob_conn != null) return;
    state.bob_conn = conn.session;
    std.debug.print("goblins-relayed-give: session open (pancake as introducer -> bob)\n", .{});
    const holder = try conn.session.served.publish(&conn.session.host.vat, holder_swiss, Holder, .{ .state = state });
    state.holder = holder.nearRef();
    const vow = try state.host.fetch(conn.session, rendezvous_swiss);
    try state.host.vowOn(vow, .{ .ctx = state, .func = IntroducerState.onRendezvous });
    try bridge.drainActions();
}

/// Follow Carol's stdout. `LISTENING` means Goblins has subscribed to the
/// promise, which is the driver's cue to have Bob settle it, so the settlement
/// finds a subscriber rather than only the store.
fn readCarolOk(io: std.Io, carol: *std.process.Child, bob: *std.process.Child) !void {
    const out = carol.stdout orelse return error.NoChildStdout;
    var rbuf: [8192]u8 = undefined;
    var reader = out.readerStreaming(io, &rbuf);
    const deadline = harness.deadlineAfter(io, deadline_ms);
    var saw_ok = false;
    // Carol's partial listener fires on every step of the promise chain, so
    // `LISTENING` can be printed more than once. Bob settles once by
    // construction; asking once keeps the transcript readable.
    var asked_bob_to_settle = false;
    while (!harness.expired(io, deadline)) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        std.debug.print("goblins-relayed-give: carol: {s}", .{line});
        if (std.mem.indexOf(u8, line, "LISTENING") != null) {
            if (asked_bob_to_settle) continue;
            asked_bob_to_settle = true;
            const stdin = bob.stdin orelse return error.NoChildStdin;
            try stdin.writeStreamingAll(io, "settle\n");
            std.debug.print("goblins-relayed-give: asked goblins-bob to settle the promise\n", .{});
            continue;
        }
        // `from goblins-bob` is the half of the greeting only Bob's greeter can
        // write; Carol sent her own name in, so it proves nothing on its own.
        if (std.mem.indexOf(u8, line, "GIFT OK:") != null and
            std.mem.indexOf(u8, line, "goblins-carol") != null and
            std.mem.indexOf(u8, line, "from goblins-bob") != null)
        {
            saw_ok = true;
            break;
        }
        if (std.mem.indexOf(u8, line, "GIFT ERR") != null or std.mem.indexOf(u8, line, "GIFT TIMEOUT") != null) {
            return error.RelayedGiveFailed;
        }
    }
    if (!saw_ok) return error.RelayedGiveFailed;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const bob_port = try harness.parsePortFlag(init.minimal.args, "goblins-relayed-give", default_bob_port, .{
        .max = 65534,
        .note = " (carol binds port+1)",
    });
    var bob_port_buf: [8]u8 = undefined;
    const bob_port_str = try std.fmt.bufPrint(&bob_port_buf, "{d}", .{bob_port});
    var carol_port_buf: [8]u8 = undefined;
    const carol_port_str = try std.fmt.bufPrint(&carol_port_buf, "{d}", .{bob_port + 1});

    // Bob's stdin stays a pipe: the driver decides when the promise settles.
    const hosted = try goblins_child.spawnHostAwaitSwissWithStdin(
        io,
        allocator,
        init.environ_map,
        "goblins-relayed-give",
        "rendezvous",
        &.{ exporter_script, host_addr, bob_port_str },
    );
    var bob = hosted.child;
    var bob_reaped = false;
    defer if (!bob_reaped) bob.kill(io);

    const published = hosted.swiss;
    defer allocator.free(published);
    std.debug.print(
        "goblins-relayed-give: goblins-bob holding an unsettled promise behind rendezvous swiss={s} on {s}:{s}\n",
        .{ rendezvous_swiss, host_addr, bob_port_str },
    );

    introducerStep(io, allocator, init.environ_map, bob_port, carol_port_str, &bob) catch |err| {
        goblins_child.dumpChildStderr(io, "goblins-relayed-give", &bob);
        return err;
    };

    bob.kill(io);
    bob_reaped = true;
    std.debug.print(
        "goblins-relayed-give OK: a live Goblins recipient read a pancake give out of a listener fire and reached the exporter directly\n",
        .{},
    );
}

fn introducerStep(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *std.process.Environ.Map,
    bob_port: u16,
    carol_port_str: []const u8,
    bob: *std.process.Child,
) !void {
    var seed: [crypto.SEED_BYTES]u8 = undefined;
    io.randomSecure(&seed) catch return error.HandshakeEntropyFailed;

    var host = Host.init(allocator, seed, blk: {
        var o = Host.Options.withFrameCap(frame_cap);
        o.local_turn_budget = 64;
        break :blk o;
    });
    defer host.deinit();

    var held = std.atomic.Value(bool).init(false);
    var state: IntroducerState = undefined;
    var loop: net.TcpLoop = undefined;
    var bridge = TcpBridge.init(allocator, &host, io, &loop, .{
        .publish = publishIntroducer,
        .publish_ctx = &state,
        .on_open = introducerOnOpen,
        .on_open_ctx = &state,
    });
    defer bridge.deinit();
    state = .{
        .host = &host,
        .bridge = &bridge,
        .held = &held,
    };

    loop = try net.TcpLoop.init(allocator, TcpBridge.makePeer, @ptrCast(&bridge), TcpBridge.hookOptions(.{
        .frame_cap = frame_cap,
        .max_conns = 8,
        .listen = 0,
    }));
    defer loop.deinit();
    const introducer_port = loop.port.?;
    var designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const bound_addr = try tcp.parseHostPort(host_addr, introducer_port);
    const bound = tcp.locator(&designator_buf, bound_addr).designator;
    try bridge.attach(tcp.transport_name, bound, &.{});

    var bob_designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const bob_addr = try tcp.parseHostPort(host_addr, bob_port);
    const bob_designator = tcp.locator(&bob_designator_buf, bob_addr).designator;
    try bridge.dialOutbound(tcp.transport_name, bob_designator, "");

    var loop_done = std.atomic.Value(bool).init(false);
    var loop_err: ?anyerror = null;
    var loop_future = try io.concurrent(runLoop, .{ &loop, &loop_done, &loop_err });
    defer {
        loop_done.store(true, .release);
        pokeListener(io, introducer_port);
        loop_future.await(io);
    }

    // Bob has to have handed the promise over before Carol can be introduced to
    // it; the introducer answers `NotReady` until then.
    try harness.untilFlag(io, deadline_ms, &held);
    if (state.promise_token == null) return error.PromiseNeverHeld;

    var introducer_designator_buf: [64]u8 = undefined;
    const introducer_designator = try std.fmt.bufPrint(
        &introducer_designator_buf,
        "{s}:{d}",
        .{ host_addr, introducer_port },
    );
    std.debug.print(
        "goblins-relayed-give: pancake publishing introducer swiss={s} on {s}\n",
        .{ introducer_swiss, introducer_designator },
    );

    var carol = try std.process.spawn(io, .{
        .argv = &.{
            goblins_child.racket_path,
            recipient_script,
            introducer_designator,
            introducer_swiss,
            carol_port_str,
        },
        .environ_map = environ_map,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var carol_reaped = false;
    defer if (!carol_reaped) carol.kill(io);

    readCarolOk(io, &carol, bob) catch |err| {
        goblins_child.dumpChildStderr(io, "goblins-relayed-give", &carol);
        return err;
    };
    carol.kill(io);
    carol_reaped = true;
    if (loop_err) |err| return err;
}
