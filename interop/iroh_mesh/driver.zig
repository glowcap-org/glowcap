//! The mesh: a three-party handoff carried over iroh (Milestone 2).
//!
//! Peer A introduces peer B to peer C, a peer B has never met. B then **reaches
//! C over iroh, by the node id the gift named**, withdraws the gifted capability
//! through C's own bootstrap, and calls it. This is the vision's "a set of
//! connections becomes a mesh": pancake's handoff substrate (the gift registry,
//! certificate verification, ADR-0009/ADR-0056) meeting netlayer reachability
//! (dial-by-id over iroh), with nothing in between.
//!
//! The payoff of key unification rides here too: B's one Ed25519 key is at once
//! its iroh node id, its keyed-session signing key, and the `recipient-key` the
//! gift names. So the recipient A introduces and the endpoint B dials C from are
//! provably the same key, and the driver asserts the three spellings agree.
//!
//! Topology (three real iroh endpoints, one process, `local_discovery` so the
//! dial-by-id is deterministic and infrastructure-free. It uses the same posture that
//! carries `iroh-interop`, not the public-internet `iroh-reachability`):
//!
//!   A (gifter)    hosts an introducer; B fetches it and calls `get-greeter`,
//!                 and A returns a `desc:handoff-give` naming C by iroh node id,
//!                 signed with A's key.
//!   C (exporter)  hosts the greeter, deposits it under the gift id with A's key
//!                 as provenance, and serves. Its engine answers B's
//!                 `withdraw-gift` after verifying both certificates.
//!   B (recipient) dials A by id, gets the give, then dials C by the **gifted**
//!                 node id, withdraws the greeter, and calls it.
//!
//! Needs cargo (the iroh sidecar); runs as the sibling step `zig build iroh-mesh`.

const std = @import("std");
const pancake = @import("pancake");
const iroh = @import("iroh");
const harness = @import("interop_harness");

const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;
const codec = pancake.ocapn.codec;
const crypto = pancake.foundation.crypto;

const frame_cap: usize = 1 << 16;
const greeting = "hello from the introduced exporter";
const gift_id = [_]u8{0x42} ** 32;
const zero32 = [_]u8{0} ** 32;

const a_seed = [_]u8{0xA1} ** 32;
const b_seed = [_]u8{0xB2} ** 32;
const c_seed = [_]u8{0xC3} ** 32;

/// The exported, gifted capability: answers `greet` with a static greeting.
const Greeter = harness.StaticReplyActor("greet", greeting);

/// A's introducer: on `get-greeter` it returns a signed `desc:handoff-give` that
/// names the recipient (B's session key, read from the live session) and the
/// exporter (C, as a structural PeerLocator: iroh transport + node-id designator),
/// gift id, and A's signature. The whole give is built in the turn arena so it
/// lives exactly as long as the reply it rides in.
const Introducer = struct {
    gifter_secret: crypto.SecretKey,
    exporter_designator: []const u8,

    pub fn handle(self: *Introducer, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        if (!std.mem.eql(u8, msg.verb, "get-greeter")) return error.NoSuchMethod;
        const peer = turn.vat.peer orelse return error.NoPeer;
        const recipient_key = peer.session_state.partnerSessionKey() orelse return error.NoPartnerKey;

        var give: model.HandoffGive = .{
            .recipient_key = recipient_key,
            .exporter = .{
                .transport = iroh.transport_name,
                .designator = self.exporter_designator,
            },
            .gifter_exporter_session = &zero32,
            .gifter_side = &zero32,
            .gift_id = &gift_id,
            .signature = "",
        };
        const signed = try codec.syrup.canonicalHandoffGiveSignedBytes(turn.arena, give);
        const sig = crypto.sign(&self.gifter_secret, signed);
        give.signature = try turn.arena.dupe(u8, sig.asBytes());

        const handoff = try turn.arena.create(model.Handoff);
        handoff.* = .{ .give = give };
        return .{ .handoff = handoff };
    }
};

/// C: accept B's session, publish the greeter, deposit it under the gift id with
/// A's key as the gifter provenance, and serve. The engine answers the inbound
/// `withdraw-gift` once both handoff certificates verify.
fn hostExporter(listener: net.netlayer.Listener, allocator: std.mem.Allocator, gifter_key: []const u8) anyerror!void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();

    const secret = crypto.SecretKey.fromSeed(c_seed);
    var cv = try driver.acceptVia(allocator, listener, &scaffold.peer, .{ .keyed = secret }, scaffold.read_buf, scaffold.write_buf, 0);
    defer cv.deinit();

    const greeter = try cv.publish("greeter", Greeter, .{});
    try cv.served.peer.giftRegistry().depositOwned(
        cv.served.peer.allocator,
        cv.served.peer.session_state.limits,
        &gift_id,
        greeter.nearRef(),
        gifter_key,
    );
    std.debug.print("iroh-mesh: exporter C accepted B, published + deposited the greeter under the gift id\n", .{});
    try cv.serve();
}

/// A: accept B's session and host the introducer that hands back the give.
fn hostIntroducer(listener: net.netlayer.Listener, allocator: std.mem.Allocator, exporter_designator: []const u8) anyerror!void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();

    const secret = crypto.SecretKey.fromSeed(a_seed);
    var cv = try driver.acceptVia(allocator, listener, &scaffold.peer, .{ .keyed = secret }, scaffold.read_buf, scaffold.write_buf, 0);
    defer cv.deinit();

    _ = try cv.publish("introducer", Introducer, .{
        .gifter_secret = crypto.SecretKey.fromSeed(a_seed),
        .exporter_designator = exporter_designator,
    });
    std.debug.print("iroh-mesh: gifter A accepted B and is serving the introducer\n", .{});
    try cv.serve();
}

/// B's first leg: dial A by id, fetch the introducer, call `get-greeter`, and
/// capture both the gifted exporter's node id and the verbatim signed-give bytes
/// (relayed unaltered so C re-verifies A's signature over the exact domain).
fn fetchGive(
    netlayers: []const net.netlayer.Netlayer,
    allocator: std.mem.Allocator,
    a_id: []const u8,
    exporter_id_out: *[]u8,
    give_bytes_out: *[]u8,
) !void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();

    const secret = crypto.SecretKey.fromSeed(b_seed);
    const locator: model.PeerLocator = .{ .transport = iroh.transport_name, .designator = a_id, .hints = model.Hints.emptyFalse() };
    var cv = try driver.connectVia(allocator, netlayers, &scaffold.peer, locator, .{ .keyed = .{ .secret = secret, .designator = a_id } }, scaffold.read_buf, scaffold.write_buf, 0);
    defer cv.deinit();

    const introducer = try cv.fetch("introducer");
    const target: model.Reference = .{ .far = introducer.far };

    const answer: u64 = 7001;
    try cv.served.peer.sendCopying(.{ .deliver = .{
        .target = target,
        .args = &.{.{ .symbol = "get-greeter" }},
        .answer = model.AnswerPosition.from(answer),
    } });

    var settled = false;
    while (!settled) {
        const progress = try cv.conn.pump();
        while (cv.served.peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch continue;
            if (body == .resolve and body.resolve.answer.int() == answer) {
                settled = true;
                switch (body.resolve.resolution) {
                    .fulfill => |arg| {
                        if (arg != .handoff) return error.NotAHandoff;
                        const give = arg.handoff.give;
                        const designator = give.exporter.designator;
                        const span = codec.syrup.spanSignedHandoffGive(event.bytes()) orelse return error.NoSignedGive;
                        exporter_id_out.* = try allocator.dupe(u8, designator);
                        give_bytes_out.* = try allocator.dupe(u8, span);
                        std.debug.print("iroh-mesh: B got the give from A; it names exporter (iroh id) {s}\n", .{designator});
                    },
                    .@"break" => |b| {
                        std.debug.print("iroh-mesh: get-greeter broke: {s}\n", .{b.message});
                        return error.IntroductionBroke;
                    },
                }
            }
        }
        if (progress == .closed) break;
    }
    if (!settled) return error.IntroductionNeverSettled;
}

/// B's second leg, the mesh edge: dial the gifted exporter **over iroh, by the
/// node id the give named**, present a `withdraw-gift` whose receive embeds A's
/// verbatim give and is signed with B's own key, and call the withdrawn greeter.
fn withdrawAndCall(
    netlayers: []const net.netlayer.Netlayer,
    allocator: std.mem.Allocator,
    exporter_id: []const u8,
    b_id: []const u8,
    give_bytes: []const u8,
) !void {
    var scaffold = try harness.PeerScaffold.init(allocator, frame_cap);
    defer scaffold.deinit();

    const secret = crypto.SecretKey.fromSeed(b_seed);
    const locator: model.PeerLocator = .{ .transport = iroh.transport_name, .designator = exporter_id, .hints = model.Hints.emptyFalse() };
    var cv = try driver.connectVia(allocator, netlayers, &scaffold.peer, locator, .{ .keyed = .{ .secret = secret, .designator = b_id } }, scaffold.read_buf, scaffold.write_buf, 0);
    defer cv.deinit();
    std.debug.print("iroh-mesh: B dialed the introduced exporter C over iroh, by the gifted node id\n", .{});

    const receiving_session = [_]u8{0xdd} ** 32;
    const receiving_side = [_]u8{0x22} ** 32;
    var receive: model.HandoffReceive = .{
        .receiving_session = &receiving_session,
        .receiving_side = &receiving_side,
        .handoff_count = 1,
        .signed_give = .{
            .recipient_key = "",
            .exporter = .{ .transport = "", .designator = "" },
            .gifter_exporter_session = "",
            .gifter_side = "",
            .gift_id = "",
            .signature = "",
            .raw_signed = give_bytes,
        },
        .signature = "",
    };
    const receive_signed = try codec.syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    var handoff = model.Handoff{ .receive = receive };
    const withdraw_answer: u64 = 7100;
    try cv.served.peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = model.FarRef.object(0) }, // the exporter's bootstrap
            .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &handoff } },
            .answer = model.AnswerPosition.from(withdraw_answer),
        },
    });

    const greeter = try awaitFulfilledReference(allocator, cv.served.peer, &cv.conn, withdraw_answer) orelse return error.WithdrawFailed;
    defer model.freeReference(allocator, greeter);
    std.debug.print("iroh-mesh: C verified both certificates and handed B the greeter directly\n", .{});

    const call_answer: u64 = 7200;
    try cv.served.peer.sendCopying(.{ .deliver = .{
        .target = greeter,
        .args = &.{ .{ .symbol = "greet" }, .{ .string = "pancake-b" } },
        .answer = model.AnswerPosition.from(call_answer),
    } });

    var greeted = false;
    while (!greeted) {
        const progress = try cv.conn.pump();
        while (cv.served.peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch continue;
            if (body == .resolve and body.resolve.answer.int() == call_answer) {
                greeted = true;
                switch (body.resolve.resolution) {
                    .fulfill => |arg| {
                        const reply: []const u8 = switch (arg) {
                            .string, .bytes => |t| t,
                            else => return error.GreeterWrongPayload,
                        };
                        if (!std.mem.eql(u8, reply, greeting)) return error.GreeterWrongPayload;
                        std.debug.print("iroh-mesh: greeter replied over the meshed session: {s}\n", .{reply});
                    },
                    .@"break" => |b| {
                        std.debug.print("iroh-mesh: greeter call broke: {s}\n", .{b.message});
                        return error.GreeterBroke;
                    },
                }
            }
        }
        if (progress == .closed) break;
    }
    if (!greeted) return error.GreeterNeverReplied;
}

/// Pump until `id` resolves; return the fulfilled reference (caller owns it) or
/// null if it broke or resolved to a non-reference.
fn awaitFulfilledReference(allocator: std.mem.Allocator, peer: *engine.Peer, conn: anytype, id: u64) !?model.Reference {
    while (true) {
        const progress = try conn.pump();
        while (peer.pollEvent()) |event_value| {
            var event = event_value;
            defer event.deinit();
            const body = event.view() catch continue;
            if (body == .resolve and body.resolve.answer.int() == id) {
                switch (body.resolve.resolution) {
                    .fulfill => |arg| {
                        if (arg != .reference) return null;
                        const owned = try event.decodeOwned(allocator);
                        defer model.freeMessage(allocator, owned);
                        const ref = ownedFulfillReference(owned) orelse return null;
                        return try model.cloneReference(allocator, ref);
                    },
                    .@"break" => |b| {
                        std.debug.print("iroh-mesh: answer {d} broke: {s}\n", .{ id, b.message });
                        return null;
                    },
                }
            }
        }
        if (progress == .closed) return null;
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var a = try iroh.Resident.init(io, &a_seed, .{ .reachability = .local_discovery });
    defer a.deinit();
    var b = try iroh.Resident.init(io, &b_seed, .{ .reachability = .local_discovery });
    defer b.deinit();
    var c = try iroh.Resident.init(io, &c_seed, .{ .reachability = .local_discovery });
    defer c.deinit();

    var a_id_buf: [iroh.node_id_len]u8 = undefined;
    var b_id_buf: [iroh.node_id_len]u8 = undefined;
    var c_id_buf: [iroh.node_id_len]u8 = undefined;
    const a_id = a.nodeId(&a_id_buf);
    const b_id = b.nodeId(&b_id_buf);
    const c_id = c.nodeId(&c_id_buf);

    const b_secret = crypto.SecretKey.fromSeed(b_seed);
    const b_key_hex = std.fmt.bytesToHex(b_secret.publicKey().bytes, .lower);
    if (!std.mem.eql(u8, b_id, &b_key_hex)) return error.BNodeIdNotItsKey;
    std.debug.print("iroh-mesh: B's node id is the hex of its session/recipient key, one key, three roles\n", .{});

    const a_secret = crypto.SecretKey.fromSeed(a_seed);
    const a_key = a_secret.publicKey().asBytes();

    const a_entries = [_]net.netlayer.Netlayer{a.netlayer()};
    const c_entries = [_]net.netlayer.Netlayer{c.netlayer()};
    const b_entries = [_]net.netlayer.Netlayer{b.netlayer()};

    var a_listener = try net.netlayer.resolve(&a_entries, iroh.transport_name).?.listen(allocator, .{ .designator = "", .hints = model.Hints.emptyFalse() });
    defer a_listener.close();
    var c_listener = try net.netlayer.resolve(&c_entries, iroh.transport_name).?.listen(allocator, .{ .designator = "", .hints = model.Hints.emptyFalse() });
    defer c_listener.close();

    var a_host = try io.concurrent(hostIntroducer, .{ a_listener, allocator, c_id });
    var c_host = try io.concurrent(hostExporter, .{ c_listener, allocator, a_key });

    var exporter_id: []u8 = &.{};
    var give_bytes: []u8 = &.{};
    const leg1 = fetchGive(&b_entries, allocator, a_id, &exporter_id, &give_bytes);
    if (leg1) |_| {} else |err| {
        std.debug.print("iroh-mesh: B failed to fetch the give: {s}\n", .{@errorName(err)});
        a.close();
        c.close();
        _ = a_host.await(io) catch {};
        _ = c_host.await(io) catch {};
        return err;
    }
    defer allocator.free(exporter_id);
    defer allocator.free(give_bytes);

    if (!std.mem.eql(u8, exporter_id, c_id)) return error.GiftedExporterNotC;

    const leg2 = withdrawAndCall(&b_entries, allocator, exporter_id, b_id, give_bytes);
    if (leg2) |_| {} else |err| {
        std.debug.print("iroh-mesh: B failed to withdraw/call over the mesh: {s}\n", .{@errorName(err)});
        a.close();
        c.close();
        _ = a_host.await(io) catch {};
        _ = c_host.await(io) catch {};
        return err;
    }

    a.close();
    const a_result = a_host.await(io);
    const c_result = c_host.await(io);
    try a_result;
    try c_result;

    std.debug.print("iroh-mesh: OK — A introduced B to C, and B reached C over iroh by the gifted node id and called the gifted capability — the connection set became a mesh\n", .{});
}
