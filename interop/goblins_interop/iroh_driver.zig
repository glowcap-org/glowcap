//! Live Goblins over iroh: a native pancake peer and a real Spritely Goblins vat
//! hold an OCapN CapTP session over encrypted QUIC, in both directions.
//!
//! A netlayer is a byte-stream provider plus a locator, and CapTP is transport
//! agnostic, so nothing here changes what either side speaks. The Goblins vat
//! runs its own CapTP, marshals its own Syrup, and keeps its own session keys.
//! What is new is what carries the bytes: `conformance/goblins-peer/racket/
//! iroh-netlayer.rkt` gives the vat an iroh endpoint through the pancake Racket
//! binding's byte-channel surface, where until now the only netlayer this
//! repository wrote for Goblins was a cleartext socket.
//!
//! That makes iroh's first outside CapTP peer. `iroh-interop` is pancake on both
//! ends by construction; here the partner is a foreign implementation of the
//! protocol, reached over the same QUIC transport.
//!
//! The dialing bracket: pancake spawns the Goblins vat (`goblins-iroh-host.rkt`),
//! reads its endpoint id, direct addresses and published echo swiss-num off the
//! NDJSON readiness lines, dials that `iroh` locator, runs the keyed
//! `op:start-session` handshake, bootstrap-fetches the echo cap and calls it.
//! Because iroh names a peer by an Ed25519 endpoint key, the dial demands that
//! durable identity of the partner before a byte is fed: the vat's hello has to
//! claim the endpoint id pancake dialed, and QUIC has already proved the far end
//! holds it. pancake names itself in the same way, advertising the id of the
//! endpoint it dialed from and signing under that key, and this driver then
//! reads back what the vat's netlayer concluded: the accepting side has to
//! report `authenticated-transport` and name pancake's endpoint, which it can
//! do because the iroh C ABI hands an accepted connection its QUIC-verified
//! remote id.
//!
//! The listening bracket: pancake binds its own seeded iroh endpoint, publishes
//! a Greeter actor, and a real Goblins client (`pancake-iroh-caller.rkt`) dials
//! in by endpoint id and calls the actor. The Goblins netlayer prints what its
//! own session trace concluded, and this driver asserts the verdict is
//! `authenticated-transport`: the vat dialed a key, so the transport itself
//! proved the partner's durable name. Over `tcp` the same vat correctly reports
//! `unauthenticated`, because a socket address proves nothing.
//!
//! Not part of the hermetic `zig build check`: it links the Rust iroh sidecar
//! (`zig build iroh-lib`, needs cargo) and needs `racket` plus the `goblins`
//! collection on PATH, so it runs as the sibling step `zig build goblins-iroh`.

const std = @import("std");
const pancake = @import("pancake");
const iroh = @import("iroh");
const goblins_child = @import("goblins_child.zig");
const harness = @import("interop_harness");

const model = pancake.ocapn.model;
const driver = pancake.driver;
const net = pancake.net;
const crypto = pancake.foundation.crypto;

const frame_cap: usize = 1 << 16;

/// The wait the dialing bracket allows the Goblins vat's handshake. Finite is
/// the contract: an unbounded wait is a hang, not a slow test. Sixty seconds
/// matches the sibling Goblins drivers, which share a machine with other Racket
/// and cargo steps.
const handshake_budget_ms: i32 = 60_000;

/// How long the dialing bracket waits for the vat to print what its netlayer
/// concluded about the session. The vat writes that line as it reads pancake's
/// hello, line-buffered, so it is already on the wire by the time the echo call
/// has answered; the budget is only there so a vat that says nothing ends this
/// wait instead of parking a driver whose child runs until it is killed.
const session_line_budget_ms: i32 = 10_000;

const host_script = "conformance/goblins-peer/racket/goblins-iroh-host.rkt";
const caller_script = "conformance/goblins-peer/racket/pancake-iroh-caller.rkt";

/// The swiss-num the pancake actor is published behind in the listening bracket.
const actor_swiss = "pancakeIrohActorSwissnumABCD1234";
/// What the Goblins client sends the actor.
const greeting_arg = "world";

/// The actor the listening bracket publishes for the Goblins client to call, and
/// the reply that client has to read back. Both come off one template, so the
/// assertion cannot drift from what the actor says.
const greeting_template = "Hello {s}, from a pancake actor over iroh!";
const Greeter = harness.PositionalReplyActor(greeting_template);
const expected_reply = std.fmt.comptimePrint(greeting_template, .{greeting_arg});

/// The listening bracket's server half: accept one partner over iroh signing with
/// `secret` — the endpoint's own key, so the designator the vat verifies is the
/// endpoint id it dialed — publish the Greeter, and serve until the vat hangs up.
const serveGreeter = harness.AcceptServeOne(
    Greeter,
    actor_swiss,
    frame_cap,
    "goblins-iroh: pancake accepted a QUIC stream and opened the keyed session",
).run;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try dialGoblinsVat(io, allocator, init.environ_map);
    try serveGoblinsClient(io, allocator, init.environ_map);

    std.debug.print("goblins-iroh: OK, a real Goblins vat and pancake held OCapN sessions over encrypted QUIC in both directions\n", .{});
}

/// Bracket one: the Goblins vat hosts over iroh and pancake dials it.
fn dialGoblinsVat(io: std.Io, allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) !void {
    // The vat announces its endpoint id and direct addresses on its `vat-ready`
    // line and the echo cap's swiss-num on the line after it, so the readiness
    // block carries all three.
    const ready = try goblins_child.spawnHostAwaitReadiness(
        io,
        allocator,
        environ_map,
        "goblins-iroh",
        "echo cap",
        goblins_child.swiss_field,
        &.{host_script},
        .inherit,
    );
    defer allocator.free(ready.block);
    var child = ready.child;
    var reaped = false;
    defer if (!reaped) child.kill(io);

    const node_id = goblins_child.extractField(ready.block, "\"node-id\":\"") orelse return error.NoGoblinsNodeId;
    const direct_addrs = goblins_child.extractField(ready.block, "\"direct-addresses\":\"") orelse return error.NoGoblinsDirectAddrs;
    const swiss = goblins_child.extractField(ready.block, goblins_child.swiss_field) orelse return error.NoGoblinsSwiss;
    std.debug.print(
        "goblins-iroh: goblins vat is reachable at ocapn://{s}.iroh with direct addresses {s}, publishing echo swiss={s}\n",
        .{ node_id, direct_addrs, swiss },
    );

    // pancake's own endpoint. `direct` is relay-less and lookup-less: the dial
    // carries the vat's addresses, so nothing leaves the machine. Seeded,
    // because this dialer names itself: it binds an endpoint a partner can
    // reach, so it advertises that endpoint's id as its own designator. The
    // iroh channel proves endpoint identity. A dialer that signed the unreachable-client
    // placeholder would be telling the vat nothing about who called.
    const client_seed: [32]u8 = @splat(0xc1);
    var endpoint = iroh.Resident.init(io, &client_seed, .{ .reachability = .direct }) catch |err| {
        std.debug.print("goblins-iroh: client endpoint bind failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer endpoint.deinit();
    const entries = [_]net.netlayer.Netlayer{endpoint.netlayer()};
    var client_id_buf: [iroh.node_id_len]u8 = undefined;
    const client_node_id = endpoint.nodeId(&client_id_buf);

    callEcho(&entries, allocator, node_id, direct_addrs, swiss, .{
        .secret = crypto.SecretKey.fromSeed(client_seed),
        .designator = client_node_id,
    }) catch |err| {
        std.debug.print("goblins-iroh: dialing the goblins vat failed: {s}\n", .{@errorName(err)});
        goblins_child.dumpChildStderr(io, "goblins-iroh", &child);
        child.kill(io);
        reaped = true;
        return err;
    };

    // What the vat's own netlayer concluded about the peer that just called it.
    // The accept side is where a transport proof used to be unreadable: QUIC
    // authenticated this dialer's endpoint id, and until the iroh C ABI handed
    // that id out, the vat had nothing to weigh pancake's claim against and
    // reported an unproven partner. It reads the id off the connection now, so
    // a hello claiming the endpoint QUIC verified is the transport's own word.
    //
    // The partner name in the same line is what ties the verdict to this dialer.
    // An accessor answering some other connection's id, or a stale one, would
    // leave the vat naming a peer that is not the one on the wire, and this
    // fails rather than reporting a session somebody else's proof vouched for.
    var trace_buf: [4096]u8 = undefined;
    const session_line = goblins_child.awaitChildStdoutLine(io, &child, "SESSION ", &trace_buf, session_line_budget_ms) orelse {
        std.debug.print("goblins-iroh: the goblins vat never reported the session it accepted\n", .{});
        goblins_child.dumpChildStderr(io, "goblins-iroh", &child);
        return error.GoblinsReportedNoSession;
    };
    std.debug.print("goblins-iroh: goblins vat says: {s}\n", .{session_line});
    const accepted_claims = [_]struct { needle: []const u8, missing: anyerror }{
        .{ .needle = "transport=iroh", .missing = error.GoblinsReportedWrongTransport },
        .{ .needle = "provenance=authenticated-transport", .missing = error.GoblinsReportedUnprovenPartner },
        .{ .needle = client_node_id, .missing = error.GoblinsNamedAnotherPartner },
    };
    for (accepted_claims) |claim| {
        if (std.mem.indexOf(u8, session_line, claim.needle) != null) continue;
        goblins_child.dumpChildStderr(io, "goblins-iroh", &child);
        return claim.missing;
    }

    std.debug.print("goblins-iroh: OK (pancake as client), keyed handshake + bootstrap fetch + echo call with a live Goblins vat over QUIC, and the vat proved the caller's endpoint id\n", .{});
    child.kill(io);
    reaped = true;
}

/// Dial the Goblins vat's `iroh` locator, fetch its echo cap, and call it.
///
/// The dial demands the partner's durable identity because iroh designates a
/// peer by key: the vat's hello must claim the endpoint id named here, and the
/// realizer's QUIC proof is what settles the claim. A vat answering under some
/// other key is refused before its first byte reaches the session.
///
/// `self` is what this side signs: the dialing endpoint's own key and the id it
/// is named by, so the vat hears a caller that names itself and can weigh that
/// name against the endpoint QUIC verified.
fn callEcho(
    netlayers: []const net.netlayer.Netlayer,
    allocator: std.mem.Allocator,
    node_id: []const u8,
    direct_addrs: []const u8,
    swiss: []const u8,
    self: struct { secret: crypto.SecretKey, designator: []const u8 },
) !void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();

    const hint_entries = [_]model.HintEntry{.{
        .name = iroh.hint_direct_addresses,
        .value = .{ .string = direct_addrs },
    }};
    const locator: model.PeerLocator = .{
        .transport = iroh.transport_name,
        .designator = node_id,
        .hints = .{ .entries = &hint_entries },
    };

    var cv = try driver.connectVia(
        allocator,
        netlayers,
        &scaffold.peer,
        locator,
        .{ .keyed = .{ .secret = self.secret, .designator = self.designator } },
        scaffold.read_buf,
        scaffold.write_buf,
        .{
            .handshake = .{ .ms = handshake_budget_ms },
            .settle = .{ .ms = handshake_budget_ms },
        },
    );
    defer cv.deinit();
    std.debug.print("goblins-iroh: keyed session open with the goblins vat over QUIC\n", .{});

    const echo = try cv.fetch(swiss);
    std.debug.print("goblins-iroh: bootstrap-fetched the vat's echo cap\n", .{});

    // The echo actor is `(lambda args args)`, so it answers with its argument
    // list. Assert the content survived the round trip rather than merely that
    // something resolved. Goblins invokes a cap positionally, so the call
    // carries no verb.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const settled = try cv.call(
        echo,
        .{ .verb = "", .args = &.{.{ .bytes = "pancake-over-iroh" }} },
        arena_state.allocator(),
    );
    switch (settled) {
        .fulfilled => |payload| {
            if (payload != .list or payload.list.len != 1) return error.EchoWrongPayload;
            const text: []const u8 = switch (payload.list[0]) {
                .bytes, .string => |t| t,
                else => return error.EchoWrongPayload,
            };
            if (!std.mem.eql(u8, text, "pancake-over-iroh")) return error.EchoWrongPayload;
        },
        .broken => |reason| {
            std.debug.print("goblins-iroh: echo broke: {s}\n", .{reason});
            return error.EchoBroke;
        },
        .give => return error.EchoGaveAnIntroduction,
    }
    std.debug.print("goblins-iroh: the vat echoed pancake's argument back over QUIC\n", .{});
}

/// Bracket two: pancake hosts over iroh and a real Goblins client dials it.
///
/// The proof this bracket exists for is the Goblins netlayer's own verdict. The
/// vat dialed an endpoint id, QUIC completed a handshake only with the holder of
/// that key, and pancake's hello claims the same id, so the netlayer reports
/// `authenticated-transport`. That is what makes a Goblins vat over iroh a peer
/// whose durable name something checked, rather than one that merely asserted it.
fn serveGoblinsClient(io: std.Io, allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) !void {
    // Seeded, so pancake's accept signs under the very key its endpoint is named
    // by: iroh is a key-designator transport, and the vat pins the session to the
    // endpoint id it dialed.
    const seed: [32]u8 = @splat(0x5a);
    const secret = crypto.SecretKey.fromSeed(seed);
    var endpoint = iroh.Resident.init(io, &seed, .{ .reachability = .direct }) catch |err| {
        std.debug.print("goblins-iroh: server endpoint bind failed: {s}\n", .{@errorName(err)});
        return err;
    };
    defer endpoint.deinit();

    var id_buf: [iroh.node_id_len]u8 = undefined;
    const node_id = endpoint.nodeId(&id_buf);
    var addrs_buf: [512]u8 = undefined;
    const direct_addrs = try endpoint.directAddrs(&addrs_buf);
    std.debug.print(
        "goblins-iroh: pancake is reachable at ocapn://{s}.iroh with direct addresses {s}\n",
        .{ node_id, direct_addrs },
    );

    const entries = [_]net.netlayer.Netlayer{endpoint.netlayer()};
    var listener = try net.netlayer.resolve(&entries, iroh.transport_name).?.listen(allocator, .{
        .designator = "",
        .hints = model.Hints.emptyFalse(),
    });
    defer listener.close();

    var serving = try io.concurrent(serveGreeter, .{ listener, allocator, secret });

    var child = try std.process.spawn(io, .{
        .argv = &.{ goblins_child.racket_path, caller_script, node_id, direct_addrs, actor_swiss, greeting_arg },
        .environ_map = environ_map,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var reaped = false;
    defer if (!reaped) child.kill(io);

    // The client prints its session line and its reply, then exits, so its
    // stdout ends. Read it to end of file; a client that never dials still ends
    // its own wait and exits, so this cannot park indefinitely.
    var stdout_buf: [8192]u8 = undefined;
    const stdout_len = goblins_child.drainChildStdout(io, &child, &stdout_buf);
    const stdout_text = stdout_buf[0..stdout_len];

    // Close the endpoint before collecting the server: it releases a parked
    // accept and ends a live serve, so a client that died before dialing cannot
    // wedge this bracket.
    endpoint.close();
    // The serve's own error is not the proof and is not weighed: closing the
    // endpoint under it is how this bracket ends, and what the vat received is
    // the evidence.
    _ = serving.await(io) catch {};

    // What the Goblins client's stdout has to say, and what each absence means.
    // The reply proves the actor ran; the three session facts are the netlayer's
    // own verdict, and the endpoint id is what ties that verdict to this peer
    // rather than to whatever else the vat may have talked to.
    const claims = [_]struct { needle: []const u8, missing: anyerror }{
        .{ .needle = "DIAL OK", .missing = error.GoblinsClientFailed },
        .{ .needle = expected_reply, .missing = error.GoblinsReadWrongReply },
        .{ .needle = "transport=iroh", .missing = error.GoblinsReportedWrongTransport },
        .{ .needle = "provenance=authenticated-transport", .missing = error.GoblinsReportedUnprovenPartner },
        .{ .needle = node_id, .missing = error.GoblinsNamedAnotherPartner },
    };
    for (claims) |claim| {
        if (std.mem.indexOf(u8, stdout_text, claim.needle) != null) continue;
        std.debug.print("goblins-iroh: goblins client stdout: {s}\n", .{stdout_text});
        goblins_child.dumpChildStderr(io, "goblins-iroh", &child);
        return claim.missing;
    }

    std.debug.print("goblins-iroh: {s}", .{stdout_text});
    std.debug.print("goblins-iroh: OK (pancake as host), a real Goblins vat called a pancake actor over QUIC and named the partner an authenticated transport identity\n", .{});
    child.kill(io);
    reaped = true;
}
