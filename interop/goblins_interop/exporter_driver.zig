//! pancake as the three-party handoff **exporter**, against live Goblins.
//!
//! The third role, and the one that had no cross-implementation proof.
//! `goblins-handoff` has pancake redeem a give Goblins minted; `goblins-gift`
//! has pancake mint a give Goblins redeems. Neither has a live Goblins pair
//! deposit into and withdraw from a *pancake* gift registry, so pancake
//! answering `deposit-gift` and `withdraw-gift` for somebody else's
//! implementation rested on the upstream suite and an in-tree scenario.
//!
//!   Exporter (pancake)   publishes a greeter, answers deposit and withdraw
//!   Gifter  (Goblins)    enlivens that greeter, publishes an introducer over it
//!   Recipient (Goblins)  enlivens the introducer, asks for the greeter, and
//!                        receives a give naming pancake — which it can only
//!                        use by dialing pancake and presenting a receive
//!
//! What makes this a real proof rather than a shape: the recipient's greeting
//! can only arrive if pancake accepted Alice's `deposit-gift` over one session
//! and served Carol's `withdraw-gift` over a *different* one, re-resolving the
//! gifted bootstrap capability against the withdrawing session. If either verb
//! mis-answers, Carol's call never lands and this driver fails.
//!
//! Run: `zig build goblins-exporter` (needs racket + the goblins collection).

const std = @import("std");
const pancake = @import("pancake");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

const model = pancake.ocapn.model;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const tcp = pancake.net.tcp;

const host_addr = "127.0.0.1";
const default_pancake_port: u16 = 22140;
const frame_cap: usize = 1 << 16;
const gifter_script = "conformance/goblins-peer/racket/exporter-gifter-host.rkt";
const recipient_script = "conformance/goblins-peer/racket/gift-recipient.rkt";
/// The swissnum Alice enlivens. Goblins takes the swiss as raw bytes, so this
/// is the name pancake publishes under.
const greeter_swiss = "pancakeExportGreeterSwissnum0001";
const introducer_swiss = "introducerSwissnum0123456789ABCD";
const deadline_ms: u64 = 60_000;

const opts: driver.SessionOptions = .{
    .frame_cap = frame_cap,
    .handshake = .{ .ms = 20_000 },
    .settle = .{ .ms = 20_000 },
};

/// The exported capability, one stateful Host-Vat actor for every session.
/// Alice primes it with a marker before any introduction; Carol reaches it
/// only through the handoff, and her greeting must carry that marker — which
/// proves the withdrawn object is the exact mutated actor, even after the
/// alias it was discovered under has been replaced.
const Greeter = struct {
    primed: *std.atomic.Value(bool),
    mark: [64]u8 = undefined,
    mark_len: usize = 0,

    pub fn handle(self: *Greeter, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        // A Goblins `(<- greeter 'prime "…")` arrives with the method symbol
        // as the deliver's verb; the plain greet arrives with an empty verb
        // and the caller's name as the one argument.
        if (std.mem.eql(u8, verb, "prime")) {
            if (args.len != 1 or args[0] != .string) return error.BadInvocation;
            self.mark_len = @min(args[0].string.len, self.mark.len);
            @memcpy(self.mark[0..self.mark_len], args[0].string[0..self.mark_len]);
            self.primed.store(true, .release);
            return .{ .string = "primed" };
        }
        if (args.len != 1 or args[0] != .string) return error.BadInvocation;
        return .{ .string = try std.fmt.allocPrint(
            ht.turn.arena,
            "Hello {s}, I'm the pancake exporter, primed with {s}!",
            .{ args[0].string, self.mark[0..self.mark_len] },
        ) };
    }
};

/// The replacement bound after Alice's deposit path is armed. If withdrawal
/// wrongly consulted the alias, Carol's greeting would come from here and the
/// marker assert below would fail the run.
const DecoyGreeter = struct {
    pub fn handle(self: *DecoyGreeter, ht: *driver.HostTurn, verb: []const u8, args: []const driver.Value) !driver.Value {
        _ = self;
        _ = ht;
        _ = verb;
        _ = args;
        return .{ .string = "I am the decoy the alias now names" };
    }
};

/// Serve every partner that dials: Alice (who enlivens and deposits) and Carol
/// (who withdraws). Both sessions share one `driver.Server` host, which is
/// what lets the gift Alice deposited be withdrawn by Carol; the greeter is
/// one Host-wide giftable, so both Ports project the same actor (ADR-0096).
fn serveExporter(
    server: *driver.Server,
    done: *std.atomic.Value(bool),
    primed: *std.atomic.Value(bool),
    replaced: *std.atomic.Value(bool),
) anyerror!void {
    // One thread drives one host: every host verb — the publication, the
    // accepts, the pumping, and the mid-run alias replacement — lives on this
    // serving thread; main only watches the atomics.
    try server.publishGiftable(greeter_swiss, Greeter, .{ .primed = primed });

    var sessions: [4]?*driver.Session = .{ null, null, null, null };
    var count: usize = 0;
    defer for (sessions[0..count]) |s| if (s) |sess| sess.deinit();

    while (!done.load(.acquire)) {
        if (count < sessions.len and server.waitAcceptable(20) catch false) {
            const session = server.accept() catch continue;
            sessions[count] = session;
            count += 1;
        }
        for (sessions[0..count]) |s| {
            if (s) |sess| {
                _ = sess.stepReadable(10) catch {};
            }
        }
        if (primed.load(.acquire) and !replaced.load(.acquire)) {
            // Alice's prime has landed, so she holds the original actor.
            // Replace the alias with the decoy before Carol exists: the
            // withdrawal must project the deposited actor, not resolve the
            // name again.
            server.publishGiftable(greeter_swiss, DecoyGreeter, .{}) catch {};
            replaced.store(true, .release);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const pancake_port = try harness.parsePortFlag(init.minimal.args, "goblins-exporter", default_pancake_port, .{
        .max = 65533,
        .note = " (alice binds port+1, carol port+2)",
    });
    var alice_port_buf: [8]u8 = undefined;
    const alice_port_str = try std.fmt.bufPrint(&alice_port_buf, "{d}", .{pancake_port + 1});
    var carol_port_buf: [8]u8 = undefined;
    const carol_port_str = try std.fmt.bufPrint(&carol_port_buf, "{d}", .{pancake_port + 2});
    var pancake_designator_buf: [32]u8 = undefined;
    const pancake_designator = try std.fmt.bufPrint(&pancake_designator_buf, "{s}:{d}", .{ host_addr, pancake_port });

    var bind_buf: [32]u8 = undefined;
    const bind = try std.fmt.bufPrint(&bind_buf, "{s}:{d}", .{ host_addr, pancake_port });

    var tcp_resident = tcp.Resident{ .io = io };
    var server = try driver.listen(allocator, tcp_resident.netlayer(), .{ .designator = bind }, .ephemeral, opts);
    defer server.deinit();

    var primed = std.atomic.Value(bool).init(false);
    var replaced = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);
    var serving = try io.concurrent(serveExporter, .{ server, &done, &primed, &replaced });
    defer {
        done.store(true, .release);
        serving.await(io) catch {};
    }

    std.debug.print("goblins-exporter: pancake exporting greeter swiss={s} on {s}\n", .{ greeter_swiss, pancake_designator });

    // Alice enlivens pancake's greeter and publishes an introducer over it.
    const hosted = try goblins_child.spawnHostAwaitSwiss(
        io,
        allocator,
        init.environ_map,
        "goblins-exporter",
        "introducer",
        &.{ gifter_script, alice_port_str, pancake_designator, greeter_swiss },
    );
    var alice = hosted.child;
    var alice_reaped = false;
    defer if (!alice_reaped) alice.kill(io);
    defer allocator.free(hosted.swiss);

    var alice_designator_buf: [32]u8 = undefined;
    const alice_designator = try std.fmt.bufPrint(&alice_designator_buf, "{s}:{s}", .{ host_addr, alice_port_str });

    // Wait until Alice's prime landed and the serving thread bound the decoy
    // over the alias: from here, only exact-object withdrawal can carry the
    // mark.
    {
        const deadline = harness.deadlineAfter(io, deadline_ms);
        while (!replaced.load(.acquire)) {
            if (harness.expired(io, deadline)) {
                goblins_child.dumpChildStderr(io, "goblins-exporter", &alice);
                return error.PrimeNeverArrived;
            }
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .real) catch {};
        }
    }

    // Carol enlivens Alice's introducer, receives the give naming pancake, and
    // must reach pancake directly to use it.
    var carol = try std.process.spawn(io, .{
        .argv = &.{
            goblins_child.racket_path,
            recipient_script,
            alice_designator,
            introducer_swiss,
            carol_port_str,
        },
        .environ_map = init.environ_map,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var carol_reaped = false;
    defer if (!carol_reaped) carol.kill(io);

    readCarolOk(io, &carol) catch |err| {
        goblins_child.dumpChildStderr(io, "goblins-exporter", &alice);
        goblins_child.dumpChildStderr(io, "goblins-exporter", &carol);
        return err;
    };

    carol.kill(io);
    carol_reaped = true;
    alice.kill(io);
    alice_reaped = true;
    std.debug.print(
        "goblins-exporter OK: a live Goblins pair deposited into and withdrew from pancake's gift registry, reaching the exact primed actor across an alias replacement\n",
        .{},
    );
}

fn readCarolOk(io: std.Io, child: *std.process.Child) !void {
    const out = child.stdout orelse return error.NoChildStdout;
    var rbuf: [8192]u8 = undefined;
    var reader = out.readerStreaming(io, &rbuf);
    const deadline = harness.deadlineAfter(io, deadline_ms);
    while (!harness.expired(io, deadline)) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        std.debug.print("goblins-exporter: {s}", .{line});
        if (std.mem.indexOf(u8, line, "GIFT OK:") != null) {
            // The greeting must be the primed original, not the decoy the
            // alias now names: exact-object identity, proven live.
            if (std.mem.indexOf(u8, line, "primed with alice-mark-7") == null) return error.WrongObjectWithdrawn;
            return;
        }
        if (std.mem.indexOf(u8, line, "GIFT ERR:") != null or
            std.mem.indexOf(u8, line, "GIFT TIMEOUT") != null) return error.HandoffFailed;
    }
    return error.HandoffFailed;
}
