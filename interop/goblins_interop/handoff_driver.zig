//! Live three-party handoff, with pancake as the recipient (Carol), driven
//! through `driver.Node` (ADR-0066).
//!
//! pancake dials a Goblins introducer (Alice), enlivens it, and calls
//! `(introducer 'get-greeter)` — the introduction. A three-party introduction
//! hands the greeter over as a `desc:handoff-give` pointing at the exporter
//! (Bob), so the recipient dials Bob directly and presents a
//! `desc:handoff-receive`. The router that makes that transparent — the retained
//! recipient identity, the shared gift registry, the signed receive, and the
//! redeemed-token routing — is the sans-io `driver.Node`; this driver is the
//! thin I/O shell over it. The Node owns each connection's peer (the embedder
//! pumps `tcp.connect` over `node.peer(conn_id)`), mints the withdraw with
//! `node.sendWithdraw`, enrolls the redeemed greeter under a token with
//! `node.enrollRedeemed`, and resolves a call to that token back to the exporter
//! with `node.routeReference`. That makes the router its own oracle against live
//! Goblins.
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

    try recipientStep1(io, allocator, swiss, alice_port_str);

    child.kill(io);
    reaped = true;
}

/// Dial Alice, enliven the introducer, call get-greeter, capture the give that
/// the introduction resolves to, then redeem it through the node.
fn recipientStep1(io: std.Io, allocator: std.mem.Allocator, swiss: []const u8, alice_port_str: []const u8) !void {
    // The node's retained identity is drawn once at the I/O boundary (the sans-io
    // node never generates entropy) and reused for every connection it opens, so
    // the gift Alice deposits names this key and the later withdraw on Bob's
    // session signs with the same one.
    var seed: [crypto.SEED_BYTES]u8 = undefined;
    io.randomSecure(&seed) catch return error.HandshakeEntropyFailed;
    var node = Node.init(allocator, seed);
    defer node.deinit();

    const recipient_conn = try node.registerConn();
    const peer = node.peer(recipient_conn).?;
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    var designator_buf: [64]u8 = undefined;
    const alice_designator = try std.fmt.bufPrint(&designator_buf, "{s}:{s}", .{ host, alice_port_str });
    const dial: model.PeerLocator = .{
        .transport = tcp.transport_name,
        .designator = alice_designator,
        .hints = model.Hints.emptyFalse(),
    };
    var conn = try tcp.connect(io, peer, dial, read_buf, write_buf);
    defer conn.deinit();

    // Keyed handshake (a `tcp`/`#f`-hints locator so Goblins verifies our
    // signature), signing with the node's retained identity.
    try goblins_child.openKeyedSessionWith(peer, &conn, host ++ ":1", node.secretKey());
    std.debug.print("goblins-handoff: session open (pancake as recipient -> alice)\n", .{});

    // Enliven the introducer by its swiss-num.
    const introducer = try goblins_child.fetchCap(allocator, peer, &conn, swiss);
    defer model.freeReference(allocator, introducer);
    std.debug.print("goblins-handoff: enlivened alice's introducer\n", .{});

    // Call (introducer 'get-greeter): a leading symbol is the method verb.
    const answer: u64 = 9100;
    try peer.sendCopying(.{ .deliver = .{
        .target = introducer,
        .args = &.{.{ .symbol = "get-greeter" }},
        .answer = model.AnswerId.from(answer),
    } });

    // The introduction resolves to a handoff-give that names the exporter (Bob).
    // Capture the exporter's address and the give's *exact* signed bytes (the
    // recipient forwards them verbatim so the exporter re-verifies the gifter's
    // signature).
    var exporter_designator: ?[]u8 = null;
    defer if (exporter_designator) |d| allocator.free(d);
    var raw_give: ?[]u8 = null;
    defer if (raw_give) |g| allocator.free(g);
    var settled = false;
    while (!settled) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch continue;
            if (body == .resolve and body.resolve.answer.int() == answer) {
                settled = true;
                switch (body.resolve.resolution) {
                    .fulfill => |arg| {
                        if (arg == .handoff) {
                            const give = arg.handoff.give;
                            const designator = give.exporter_location.locator.designator;
                            std.debug.print("goblins-handoff: get-greeter resolved to a handoff-give; exporter={s} gift_id.len={}\n", .{ designator, give.gift_id.len });
                            exporter_designator = try allocator.dupe(u8, designator);
                            const span = codec.syrup.spanSignedHandoffGive(event.bytes()) orelse return error.NoSignedGive;
                            raw_give = try allocator.dupe(u8, span);
                        } else {
                            std.debug.print("goblins-handoff: get-greeter resolved to a {s} (expected a handoff)\n", .{@tagName(arg)});
                        }
                    },
                    .@"break" => |b| std.debug.print("goblins-handoff: get-greeter BROKE: {s}\n", .{b.message}),
                }
            }
        }
        if (progress == .closed) break;
    }
    if (!settled) return error.IntroductionNeverSettled;

    const designator = exporter_designator orelse return error.NoHandoffGive;
    const give_bytes = raw_give orelse return error.NoHandoffGive;

    // The recipient redeem: dial the exporter directly and withdraw through the node.
    try withdrawAndCall(io, allocator, &node, recipient_conn, designator, give_bytes);
}

/// The recipient redeem, driven through the node: register a fresh exporter
/// connection, dial Bob and open a keyed session under the node's retained
/// identity, mint the signed `withdraw-gift` with `node.sendWithdraw` (the one
/// definition of the recipient receive, with the handoff-count minted from the
/// shared registry), enroll the resulting greeter under a node token, and ask
/// the node where a call to that token routes, proving the redeemed cap is
/// transparently addressable rather than hand-forwarded to the exporter.
fn withdrawAndCall(
    io: std.Io,
    allocator: std.mem.Allocator,
    node: *Node,
    recipient_conn: pancake.driver.ConnId,
    designator: []const u8,
    give_bytes: []const u8,
) !void {
    const exporter_conn = try node.registerConn();
    const peer = node.peer(exporter_conn).?;
    peer.session_state.limits.max_frame_bytes = frame_cap;

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const dial: model.PeerLocator = .{ .transport = tcp.transport_name, .designator = designator, .hints = model.Hints.emptyFalse() };
    var conn = try tcp.connect(io, peer, dial, read_buf, write_buf);
    defer conn.deinit();

    // The node's retained identity: the deposited gift names that key as the
    // recipient, so this session must present it.
    try goblins_child.openKeyedSessionWith(peer, &conn, host ++ ":1", node.secretKey());
    std.debug.print("goblins-handoff: session open (pancake -> exporter {s})\n", .{designator});

    // Mint and send the signed `withdraw-gift` through the node, then flush it.
    const withdraw_answer: u64 = 9200;
    try node.sendWithdraw(exporter_conn, give_bytes, withdraw_answer);
    _ = conn.pump() catch {};

    const greeter = try awaitResolution(allocator, peer, &conn, withdraw_answer) orelse {
        std.debug.print("goblins-handoff: withdraw did not resolve to a reference\n", .{});
        return error.WithdrawFailed;
    };
    defer model.freeReference(allocator, greeter);
    std.debug.print("goblins-handoff: withdraw succeeded, got the greeter ref directly from the exporter\n", .{});

    // Enroll the greeter under a node token, then route a call to that token: the
    // node forwards it to the exporter connection with the real reference swapped
    // in, so the application holds an ordinary far cap and the node owns the
    // three-party transparency.
    const token = try node.enrollRedeemed(exporter_conn, greeter);
    defer model.freeReference(allocator, token);
    const routed = node.routeReference(recipient_conn, token) orelse return error.TokenUnroutable;
    const target_peer = node.peer(routed.conn_id).?;

    const call_answer: u64 = 9300;
    try target_peer.sendCopying(.{ .deliver = .{
        .target = routed.target,
        .args = &.{.{ .string = "pancake-carol" }},
        .answer = model.AnswerId.from(call_answer),
    } });
    var greeted = false;
    while (!greeted) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch continue;
            if (body == .resolve and body.resolve.answer.int() == call_answer) {
                greeted = true;
                switch (body.resolve.resolution) {
                    // The greeter builds its reply around the caller's name:
                    // assert the name we sent came back in the content, so the
                    // handoff proves data integrity, not just choreography.
                    .fulfill => |arg| {
                        const reply: []const u8 = switch (arg) {
                            .string, .bytes => |t| t,
                            else => return error.GreeterWrongPayload,
                        };
                        if (std.mem.indexOf(u8, reply, "pancake-carol") == null) {
                            return error.GreeterWrongPayload;
                        }
                        std.debug.print("goblins-handoff: greeter replied: {s}\n", .{reply});
                    },
                    .@"break" => |b| {
                        std.debug.print("goblins-handoff: greeter call broke: {s}\n", .{b.message});
                        return error.GreeterBroke;
                    },
                }
            }
        }
        if (progress == .closed) break;
    }
    if (!greeted) return error.GreeterNeverReplied;
    std.debug.print("goblins-handoff: OK, full three-party handoff: pancake withdrew a gift from Goblins and called it directly\n", .{});
}

/// Pump until answer `id` resolves; return the fulfilled reference (caller owns it)
/// or null if it resolved to a non-reference / broke.
fn awaitResolution(allocator: std.mem.Allocator, peer: *engine.Peer, conn: anytype, id: u64) !?model.Reference {
    while (true) {
        const progress = conn.pump() catch |e| {
            const buffered = conn.r.buffered();
            std.debug.print("goblins-handoff: withdraw response pump error {s}; {} bytes goblins sent:\n", .{ @errorName(e), buffered.len });
            dumpFrameBytes(buffered);
            return e;
        };
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch continue;
            if (body == .resolve and body.resolve.answer.int() == id) {
                switch (body.resolve.resolution) {
                    .fulfill => |arg| {
                        if (arg != .reference) {
                            std.debug.print("goblins-handoff: answer {} resolved to a {s} (expected a reference)\n", .{ id, @tagName(arg) });
                            return null;
                        }
                        // The owned decode is the raw V1.0 resolver-callback deliver
                        // (`[fulfill <ref>]`), not a re-projected resolve, so pull the
                        // reference from whichever shape it materializes as.
                        const owned = try event.decodeOwned(allocator);
                        defer model.freeMessage(allocator, owned);
                        const ref = ownedFulfillReference(owned) orelse return null;
                        return try model.cloneReference(allocator, ref);
                    },
                    .@"break" => |b| {
                        std.debug.print("goblins-handoff: answer {} broke: {s}\n", .{ id, b.message });
                        return null;
                    },
                }
            }
        }
        if (progress == .closed) {
            std.debug.print("goblins-handoff: connection closed before answer {} resolved\n", .{id});
            return null;
        }
    }
}

/// Pull the fulfilled reference out of either an `op:resolve` or a V1.0
/// resolver-callback deliver (`[fulfill <ref>]`).
fn ownedFulfillReference(msg: model.Message) ?model.Reference {
    return switch (msg) {
        .resolve => |r| if (r.resolution == .fulfill and r.resolution.fulfill == .reference) r.resolution.fulfill.reference else null,
        .deliver => |d| if (d.args.len >= 2 and d.args[1] == .reference) d.args[1].reference else null,
        else => null,
    };
}

/// Print a frame as a Syrup-readable ascii rendering (printables verbatim,
/// non-printables as `\xNN`), so we can see exactly which descriptor goblins
/// emitted that pancake's decoder rejected.
fn dumpFrameBytes(bytes: []const u8) void {
    var buf: [4096]u8 = undefined;
    var w: usize = 0;
    for (bytes) |b| {
        if (w + 4 >= buf.len) break;
        if (b >= 0x20 and b < 0x7f) {
            buf[w] = b;
            w += 1;
        } else {
            const hex = "0123456789abcdef";
            buf[w] = '\\';
            buf[w + 1] = 'x';
            buf[w + 2] = hex[b >> 4];
            buf[w + 3] = hex[b & 0xf];
            w += 4;
        }
    }
    std.debug.print("goblins-handoff:   {s}\n", .{buf[0..w]});
}
