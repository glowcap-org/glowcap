//! A relayed give read by a live Goblins recipient: glowcap introduces a third
//! party to a promise it does not own, and when that promise settles the third
//! party finds a signed give in the settlement.
//!
//! Every other handoff proof in this directory settles the introduction at the
//! moment it is asked for, so the give rides an answer the recipient asked for.
//! Here the introduction is a promise living on a vat the recipient has never
//! spoken to, so the give arrives in a *listener fire* instead. That position
//! rested on glowcap's own tests until this step. This scenario asks a real
//! Goblins vat to read a give specifically from a listener fulfillment; the
//! recursive container evidence lives in the binding gifter matrix.
//!
//! Topology (TCP loopback):
//!   Bob      (Goblins exporter)  publishes a rendezvous and holds a promise he
//!                               has not settled. He hands the promise to
//!                               glowcap as a delivered argument, and settles it
//!                               when the driver writes a line to his stdin.
//!   glowcap  (introducer)        holds Bob's promise as an opaque Host
//!                               capability and answers `get-greeter` with it.
//!                               Its `driver.Server` proxies the promise onto
//!                               Carol's session and waits on Bob's.
//!   Carol    (Goblins recipient) asks glowcap for the greeter, waits on the
//!                               promise she is answered with, redeems the give
//!                               the settlement carries, dials Bob, and calls
//!                               what she withdrew.
//!
//! Why Bob hands the promise over as an *argument*: an answer carrying a local
//! promise chains through Goblins' own promise machinery and stays pending on
//! the wire, so glowcap would be handed a pending answer rather than a promise
//! it can name. An argument marshals as `desc:import-promise`, which the Host
//! lifts under Bob's session before application code sees it.
//!
//! Needs `racket` + the `goblins` collection on PATH: it compiles under
//! `zig build check` and runs only as the sibling step
//! `zig build goblins-relayed-give`.

const std = @import("std");
const glowcap = @import("glowcap");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

const model = glowcap.ocapn.model;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;

const host_addr = "127.0.0.1";
const default_bob_port: u16 = 22150;
const frame_cap: usize = 1 << 16;
const exporter_script = "conformance/goblins-peer/racket/deferred-exporter-host.rkt";
const recipient_script = "conformance/goblins-peer/racket/relayed-give-recipient.rkt";
const rendezvous_swiss = "glowcapDeferredRendezvousSwiss01";
const introducer_swiss = "introducer";
const deadline_ms: u64 = 60_000;

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 20_000 },
    .settle = .{ .ms = 20_000 },
};

/// The opaque Host capability produced when Bob's promise arrives as an
/// argument. Written by the holder inside a turn on the serving thread.
const Held = struct {
    promise: ?driver.Capability = null,
    flag: *std.atomic.Value(bool),
};

/// The capability Bob sends the promise to. The owning tier lifts the
/// delivered promise under Bob's session before this handler sees it, so the
/// opaque capability already carries the home and kind needed for handoff.
const Holder = struct {
    held: *Held,

    pub fn handle(self: *Holder, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = ht;
        if (!std.mem.eql(u8, verb, "hold")) return error.NoSuchMethod;
        if (args.len != 1 or args[0] != .capability) return error.NotACapability;
        self.held.promise = args[0].capability;
        self.held.flag.store(true, .release);
        std.debug.print("goblins-relayed-give: goblins-bob handed over an unsettled promise\n", .{});
        return .{ .string = "held" };
    }
};

/// What Carol asks. Lowering the opaque promise onto Carol's session sends the
/// host down the introducing-session proxy path.
const Introducer = struct {
    held: *Held,

    pub fn handle(self: *Introducer, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = ht;
        _ = args;
        if (!std.mem.eql(u8, verb, "get-greeter")) return error.NoSuchMethod;
        return .{ .capability = self.held.promise orelse return error.NotReady };
    }
};

/// Dial Bob, hand him a holder for his promise, publish the introducer, and
/// serve Carol until the run ends.
fn serveIntroducer(
    introducer: *driver.Server,
    bob_locator: model.PeerLocator,
    held: *Held,
    done: *std.atomic.Value(bool),
) anyerror!void {
    // A setup failure still releases the waiting main thread.
    defer held.flag.store(true, .release);
    const bob_session = try introducer.runtime.connectLocator(bob_locator, .inherit);
    const bob = try driver.Session.adopt(introducer.runtime, bob_session);
    defer bob.deinit();
    std.debug.print("goblins-relayed-give: session open (glowcap as introducer -> bob)\n", .{});
    try introducer.publish(introducer_swiss, Introducer, .{ .held = held });
    const rendezvous = try bob.fetch(rendezvous_swiss);
    std.debug.print("goblins-relayed-give: fetched goblins-bob's rendezvous\n", .{});
    // Hand Bob a capability of ours, so he can send the unresolved promise
    // back to it as a delivered argument.
    const holder = try bob.spawn(Holder, .{ .held = held });
    const held_with = try bob.send(rendezvous, "hold-with", &.{.{ .capability = holder }});
    defer held_with.release() catch {};

    var carol: ?*driver.Session = null;
    defer if (carol) |session| session.deinit();
    while (!done.load(.acquire)) {
        if (carol == null and try introducer.waitAcceptable(20)) carol = try introducer.accept();
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
        "goblins-relayed-give OK: a live Goblins recipient read a glowcap give out of a listener fire and reached the exporter directly\n",
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
    var introducer = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = host_addr ++ ":0" }, .ephemeral, opts);
    defer introducer.deinit();
    var introducer_designator_buf: [64]u8 = undefined;
    const introducer_designator = try allocator.dupe(u8, try introducer.localDesignator(&introducer_designator_buf));
    defer allocator.free(introducer_designator);

    var bob_designator_buf: [tcp.designator_buf_len]u8 = undefined;
    const bob_locator = tcp.locatorFromAddress(&bob_designator_buf, try tcp.parseHostPort(host_addr, bob_port));

    var held_flag = std.atomic.Value(bool).init(false);
    var held: Held = .{ .flag = &held_flag };
    var done = std.atomic.Value(bool).init(false);
    var serving = try io.concurrent(serveIntroducer, .{ introducer, bob_locator, &held, &done });
    var serving_joined = false;
    defer if (!serving_joined) {
        done.store(true, .release);
        serving.await(io) catch {};
    };

    // Bob has to have handed the promise over before Carol can be introduced to
    // it; the introducer answers `NotReady` until then.
    try harness.untilFlag(io, deadline_ms, &held_flag);
    if (held.promise == null) {
        done.store(true, .release);
        serving_joined = true;
        try serving.await(io);
        return error.PromiseNeverHeld;
    }
    std.debug.print(
        "goblins-relayed-give: glowcap publishing introducer swiss={s} on {s}\n",
        .{ introducer_swiss, introducer_designator },
    );

    var carol_argv: [8][]const u8 = undefined;

    var carol = try std.process.spawn(io, .{
        .argv = goblins_child.racketArgv(&carol_argv, &.{
            recipient_script,
            introducer_designator,
            introducer_swiss,
            carol_port_str,
        }),
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
    done.store(true, .release);
    serving_joined = true;
    try serving.await(io);
}
