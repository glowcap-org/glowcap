//! Live three-party handoff, with pancake as the recipient (Carol), driven
//! through `driver.Node` (ADR-0066).
//!
//! pancake dials a Goblins introducer (Alice), enlivens it, and calls
//! `(introducer 'get-greeter)` — the introduction. A three-party introduction
//! hands the greeter over as a `desc:handoff-give` pointing at the exporter
//! (Bob), so the recipient dials Bob directly and presents a
//! `desc:handoff-receive`. The whole redeem is sequenced by the node's sans-io
//! serve step: this driver feeds the give in (`node.acceptGive`), executes the
//! actions that come back (`dial`, `flush`), reports the dial's outcome
//! (`node.exporterDialed`), offers the exporter's resolves back
//! (`node.claimResolve`), and receives the `settle` action carrying the
//! routable token, which `node.routeReference` forwards to the exporter with
//! the real reference swapped in. The node owns every decision — the retained
//! recipient identity, the exporter cache, the pending withdraw, the signed
//! receive, the enrollment — and this driver owns only sockets, which makes
//! the serve step its own oracle against live Goblins.
//!
//! Needs `racket` + the `goblins` collection on PATH; runs as the sibling step
//! `zig build goblins-handoff`, not in the hermetic gate.

const std = @import("std");
const pancake = @import("pancake");
const goblins_child = @import("goblins_child.zig");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const codec = pancake.ocapn.codec;
const crypto = pancake.foundation.crypto;
const tcp = pancake.net.tcp;
const Node = pancake.driver.Node;

const host = "127.0.0.1";
/// Alice's and Bob's listening ports. `--port=N` (from
/// `zig build goblins-handoff -Dport=N`) moves the pair to N and N+1 when the
/// defaults are taken.
const default_alice_port: u16 = 22110;
const frame_cap: usize = 1 << 16;
const host_script = "conformance/goblins-peer/racket/handoff-introducer-host.rkt";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    var alice_port: u16 = default_alice_port;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            alice_port = std.fmt.parseInt(u16, arg["--port=".len..], 10) catch 0;
            if (alice_port == 0 or alice_port == 65535) {
                std.debug.print("goblins-handoff: --port must be an integer in 1..65534 (bob listens on port+1)\n", .{});
                return error.BadPort;
            }
        } else {
            std.debug.print("goblins-handoff: unknown argument '{s}'\n", .{arg});
            return error.BadArgument;
        }
    }
    var alice_port_buf: [8]u8 = undefined;
    const alice_port_str = try std.fmt.bufPrint(&alice_port_buf, "{d}", .{alice_port});
    var bob_port_buf: [8]u8 = undefined;
    const bob_port_str = try std.fmt.bufPrint(&bob_port_buf, "{d}", .{alice_port + 1});

    var child = try std.process.spawn(io, .{
        .argv = &.{ goblins_child.racket_path, host_script, alice_port_str, bob_port_str },
        .environ_map = init.environ_map,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var reaped = false;
    defer if (!reaped) child.kill(io);

    const swiss = goblins_child.readPublishedSwiss(io, allocator, &child) catch |err| {
        std.debug.print("goblins-handoff: never saw the introducer readiness line: {s}\n", .{@errorName(err)});
        goblins_child.dumpChildStderr(io, "goblins-handoff", &child);
        return err;
    };
    defer allocator.free(swiss);
    std.debug.print("goblins-handoff: alice published introducer swiss={s} on {s}:{s}\n", .{ swiss, host, alice_port_str });

    recipientStep1(io, allocator, swiss, alice_port_str) catch |err| {
        goblins_child.dumpChildStderr(io, "goblins-handoff", &child);
        return err;
    };

    child.kill(io);
    reaped = true;
}

/// Dial Alice, enliven the introducer, and call `get-greeter` through the
/// typed surface: the introduction settles as a `.give`, `Host.redeem` dials
/// Bob and withdraws under the host identity, and the routed call reaches the
/// greeter directly. The serve step owns every decision; the driver holds one
/// `Host` and its verbs, which makes the live Goblins conversation the native
/// surface's oracle.
fn recipientStep1(io: std.Io, allocator: std.mem.Allocator, swiss: []const u8, alice_port_str: []const u8) !void {
    var seed: [crypto.SEED_BYTES]u8 = undefined;
    io.randomSecure(&seed) catch return error.HandshakeEntropyFailed;
    var tcp_resident = tcp.Resident{ .io = io };
    var h = pancake.driver.Host.initSeeded(allocator, io, &.{tcp_resident.netlayer()}, seed, .{ .frame_cap = frame_cap });
    defer h.deinit();

    var designator_buf: [64]u8 = undefined;
    const alice_designator = try std.fmt.bufPrint(&designator_buf, "{s}:{s}", .{ host, alice_port_str });
    const alice = try h.dial(.{
        .transport = tcp.transport_name,
        .designator = alice_designator,
        .hints = model.Hints.emptyFalse(),
    });
    defer alice.deinit();
    std.debug.print("goblins-handoff: session open (pancake as recipient -> alice)\n", .{});

    // Enliven the introducer by its swiss-num.
    const introducer = try goblins_child.fetchCap(allocator, alice.cv.peer, &alice.cv.conn, swiss);
    defer model.freeReference(allocator, introducer);
    std.debug.print("goblins-handoff: enlivened alice's introducer\n", .{});

    // Call (introducer 'get-greeter): the introduction settles as the typed
    // third outcome, the give, with its verbatim envelope and dialable locator.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const settled = try alice.call(.{ .far = introducer.far }, .{ .verb = "get-greeter", .args = &.{} }, arena.allocator());
    const give = switch (settled) {
        .give => |g| g,
        .fulfilled => |arg| {
            std.debug.print("goblins-handoff: get-greeter resolved to a {s} (expected a give)\n", .{@tagName(arg)});
            return error.NoHandoffGive;
        },
        .broken => |reason| {
            std.debug.print("goblins-handoff: get-greeter BROKE: {s}\n", .{reason});
            return error.NoHandoffGive;
        },
    };
    std.debug.print("goblins-handoff: get-greeter resolved to a handoff-give; exporter={s}\n", .{give.exporter_locator_uri});

    // Redeem: the host dials Bob under the node identity, withdraws, and hands
    // back the greeter as an ordinary routable capability.
    const greeter = try h.redeem(alice, give);
    std.debug.print("goblins-handoff: session open (pancake -> exporter)\n", .{});
    std.debug.print("goblins-handoff: withdraw succeeded, got the greeter ref directly from the exporter\n", .{});

    // Call the greeter (a Goblins lambda: no verb, one argument). The token
    // routes through the node to Bob's connection.
    const reply = try alice.call(greeter, .{ .verb = "", .args = &.{.{ .string = "pancake-carol" }} }, arena.allocator());
    switch (reply) {
        .fulfilled => |arg| {
            const text: []const u8 = switch (arg) {
                .string, .bytes => |t| t,
                else => return error.GreeterWrongPayload,
            };
            // The greeter builds its reply around the caller's name: assert the
            // name round-tripped, so the handoff proves data integrity, not
            // just choreography.
            if (std.mem.indexOf(u8, text, "pancake-carol") == null) return error.GreeterWrongPayload;
            std.debug.print("goblins-handoff: greeter replied: {s}\n", .{text});
        },
        .broken => |reason| {
            std.debug.print("goblins-handoff: greeter call broke: {s}\n", .{reason});
            return error.GreeterBroke;
        },
        .give => return error.GreeterWrongPayload,
    }
    std.debug.print("goblins-handoff: OK, full three-party handoff: pancake withdrew a gift from Goblins and called it directly\n", .{});
}
