//! A three-party handoff redeemed over WebRTC by signaling-then-handshake
//! (ADR-0089, the `webrtc` give redeem).
//!
//! This is webrtc's `iroh-mesh`. A gifter A signs a `desc:handoff-give` that
//! names the recipient B (by session key) and the exporter C (by `webrtc`
//! designator). B redeems it the way a `webrtc` locator is always reached: it
//! brings up a direct DataChannel to C through C's signaling capability, runs
//! the keyed handshake over the channel, and presents a `withdraw-gift` whose
//! receive embeds A's give and is signed with B's own key. C's engine verifies
//! both certificates against the gifter key it recorded at deposit and hands B
//! the gifted greeter directly, which B then calls. The introduction names the
//! exporter's identity; the channel to it comes up by signaling.
//!
//! The delta from `webrtc-signaling-captp` is the handoff: there the recipient
//! fetches a bootstrap greeter over the channel it brought up; here it redeems a
//! gifted capability over that same channel, so the handoff substrate (the gift
//! registry, certificate verification, ADR-0009/ADR-0056) meets the WebRTC
//! netlayer. The give is built in process with A's key rather than fetched from
//! a live introducer session (that leg is `iroh-mesh`'s to prove); the novel
//! claim here is that a `webrtc` give redeems over CapTP by
//! signaling-then-handshake, and that C's built-in withdraw verifier authorizes
//! it over a channel that had no dialable address.
//!
//! B reaches C's signaling inbox at an address it is handed, the way both peers
//! would share a room: the give attests C's identity, and the signaling object
//! is the shared rendezvous. The routing hub keyed by designator and the
//! recipient-hosted giftable are `webrtc-signaling-captp`'s deferred topology;
//! this proof keeps the single-exporter signaling inbox and adds the redeem.
//!
//! Not part of the hermetic `zig build check`: it links the Rust sidecar
//! staticlib (`zig build webrtc-lib`, needs cargo), so it runs as the sibling
//! step `zig build webrtc-handoff`.

const std = @import("std");
const pancake = @import("pancake");
const webrtc = @import("webrtc");
const webrtc_common = @import("webrtc_common");

const crypto = pancake.foundation.crypto;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const codec = pancake.ocapn.codec;
const tcp = pancake.net.tcp;
const ip = std.Io.net;

// The signaling inbox actor and the channel-bring-up client are the shared
// WebRTC signaling core (interop/webrtc_common.zig), the same spine
// webrtc-signaling-captp drives; here the recipient adds the give redeem on top.
const SignalingInbox = webrtc_common.SignalingInbox;
const bringUpViaCapTP = webrtc_common.bringUpViaCapTP;
const sig_frame_cap = webrtc_common.sig_frame_cap;

const frame_cap: usize = 1 << 16;
const greeting = "hello from the introduced exporter over webrtc";
const gift_id = [_]u8{0x42} ** 32;
const zero32 = [_]u8{0} ** 32;

const a_seed = [_]u8{0xA1} ** crypto.SEED_BYTES; // gifter
const b_seed = [_]u8{0xB2} ** crypto.SEED_BYTES; // recipient
const c_seed = [_]u8{0xC3} ** crypto.SEED_BYTES; // exporter

/// The exported, gifted capability: answers `greet` with a static greeting.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        _ = msg;
        return .{ .string = greeting };
    }
};

/// C, the exporter. First host the signaling inbox over a keyed CapTP session
/// until B's channel is up (B closes it), then hold the keyed OCapN session over
/// the DataChannel: publish the greeter, deposit it under the gift id with A's
/// key as the gifter provenance, and serve. The engine answers B's
/// `withdraw-gift` once both certificates verify against that recorded key.
fn exporterHalf(
    io: std.Io,
    listener: *tcp.Listener,
    peer: *webrtc.Peer,
    allocator: std.mem.Allocator,
    gifter_key: []const u8,
) anyerror!void {
    // 1. Signaling over CapTP until the channel is up.
    {
        var sig_peer = engine.Peer.initNegotiating(allocator);
        defer sig_peer.deinit();
        sig_peer.session_state.limits.max_frame_bytes = sig_frame_cap;
        const read_buf = try allocator.alloc(u8, sig_frame_cap);
        defer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, sig_frame_cap);
        defer allocator.free(write_buf);

        var sig = try driver.acceptTcp(allocator, &sig_peer, listener, read_buf, write_buf);
        defer sig.deinit();
        _ = try sig.publish("signaling", SignalingInbox, .{ .peer = peer });
        try sig.serve();
    }
    if (!peer.waitOpen(2000)) return error.ChannelNotOpen;

    // 2. The gifted keyed session over the DataChannel.
    var engine_peer = engine.Peer.initNegotiating(allocator);
    defer engine_peer.deinit();
    engine_peer.session_state.limits.max_frame_bytes = frame_cap;
    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const conn = try peer.connection(io, &engine_peer, .{ .read = read_buf, .write = write_buf });
    var vat = driver.BlockingSession.over(allocator, &engine_peer, conn);
    defer vat.deinit();

    const secret = crypto.SecretKey.fromSeed(c_seed);
    const designator = secret.publicKey().toDesignator();
    const self_locator: model.PeerLocator = .{
        .transport = webrtc.transport_name,
        .designator = designator[0..],
        .hints = model.Hints.emptyFalse(),
    };
    try vat.startKeyedSessionWithSecret(self_locator, secret);

    const greeter = try vat.publish("greeter", Greeter, .{});
    try engine_peer.giftRegistry().depositOwned(
        engine_peer.allocator,
        engine_peer.session_state.limits,
        &gift_id,
        greeter.nearRef(),
        gifter_key,
    );
    std.debug.print("webrtc-handoff: exporter C accepted B over the DataChannel, published + deposited the greeter under the gift id\n", .{});
    try vat.serve();
}

/// B, the recipient. Bring up the DataChannel to C through C's signaling inbox,
/// run the keyed handshake pinning C's designator, then present a `withdraw-gift`
/// whose receive embeds A's give and is signed with B's key, and call the
/// greeter C hands back.
fn recipientHalf(
    signaling_address: ip.IpAddress,
    io: std.Io,
    offerer: *webrtc.Peer,
    allocator: std.mem.Allocator,
    give: model.HandoffGive,
    exporter_designator: []const u8,
) anyerror!void {
    // 1. Bring up the DataChannel to C via its signaling inbox over CapTP.
    {
        var sig_peer = engine.Peer.initNegotiating(allocator);
        defer sig_peer.deinit();
        sig_peer.session_state.limits.max_frame_bytes = sig_frame_cap;
        const read_buf = try allocator.alloc(u8, sig_frame_cap);
        defer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, sig_frame_cap);
        defer allocator.free(write_buf);

        var sig = try driver.connectTcp(allocator, io, &sig_peer, signaling_address, read_buf, write_buf);
        defer sig.deinit();
        const inbox = try sig.fetch("signaling");
        try bringUpViaCapTP(&sig, inbox, offerer, allocator);
    }

    // 2. The keyed session over the DataChannel, pinning C's key.
    const b_secret = crypto.SecretKey.fromSeed(b_seed);
    var engine_peer = engine.Peer.initNegotiating(allocator);
    defer engine_peer.deinit();
    engine_peer.session_state.limits.max_frame_bytes = frame_cap;
    engine_peer.expectPartnerKey(crypto.PeerKey.fromDesignator(exporter_designator) orelse return error.InvalidDesignator);
    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const conn = try offerer.connection(io, &engine_peer, .{ .read = read_buf, .write = write_buf });
    var vat = driver.BlockingSession.over(allocator, &engine_peer, conn);
    defer vat.deinit();

    const b_designator = b_secret.publicKey().toDesignator();
    const self_locator: model.PeerLocator = .{
        .transport = webrtc.transport_name,
        .designator = b_designator[0..],
        .hints = model.Hints.emptyFalse(),
    };
    try vat.startKeyedSessionWithSecret(self_locator, b_secret);
    std.debug.print("webrtc-handoff: B brought up the DataChannel to C by signaling and completed the keyed handshake\n", .{});

    // 3. Present the withdraw-gift: a receive embedding A's give, signed with B's
    //    key. C's engine verifies both certificates and hands back the greeter.
    const receiving_session = [_]u8{0xdd} ** 32;
    const receiving_side = [_]u8{0x22} ** 32;
    var receive: model.HandoffReceive = .{
        .receiving_session = &receiving_session,
        .receiving_side = &receiving_side,
        .handoff_count = 1,
        .signed_give = give,
        .signature = "",
    };
    const receive_signed = try codec.syrup.canonicalHandoffReceiveSignedBytes(allocator, receive);
    defer allocator.free(receive_signed);
    const receive_sig = crypto.sign(&b_secret, receive_signed);
    receive.signature = receive_sig.asBytes();

    var handoff = model.Handoff{ .receive = receive };
    const withdraw_answer: u64 = 7100;
    try engine_peer.sendCopying(.{
        .deliver = .{
            .target = .{ .far = model.FarRef.object(0) }, // the exporter's bootstrap
            .args = &.{ .{ .symbol = "withdraw-gift" }, .{ .handoff = &handoff } },
            .answer = model.AnswerPosition.from(withdraw_answer),
        },
    });

    const greeter = try awaitFulfilledReference(allocator, &engine_peer, &vat.conn, withdraw_answer) orelse return error.WithdrawFailed;
    defer model.freeReference(allocator, greeter);
    std.debug.print("webrtc-handoff: C verified both certificates and handed B the gifted greeter over the DataChannel\n", .{});

    // 4. Call the withdrawn greeter over the meshed session.
    const call_answer: u64 = 7200;
    try engine_peer.sendCopying(.{ .deliver = .{
        .target = greeter,
        .args = &.{ .{ .symbol = "greet" }, .{ .string = "pancake-b" } },
        .answer = model.AnswerPosition.from(call_answer),
    } });

    var greeted = false;
    while (!greeted) {
        const progress = try vat.conn.pump();
        while (engine_peer.pollEvent()) |event_value| {
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
                        std.debug.print("webrtc-handoff: greeter replied over the meshed session: {s}\n", .{reply});
                    },
                    .@"break" => |b| {
                        std.debug.print("webrtc-handoff: greeter call broke: {s}\n", .{b.message});
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
                        std.debug.print("webrtc-handoff: answer {d} broke: {s}\n", .{ id, b.message });
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

    const a_secret = crypto.SecretKey.fromSeed(a_seed);
    const b_secret = crypto.SecretKey.fromSeed(b_seed);
    const c_secret = crypto.SecretKey.fromSeed(c_seed);
    const a_pub = a_secret.publicKey();
    const b_pub = b_secret.publicKey();
    const c_designator = c_secret.publicKey().toDesignator();

    // A signs a give naming B (recipient key) and C (webrtc designator). Built in
    // process with A's key; the introduction leg is `iroh-mesh`'s to prove.
    var give: model.HandoffGive = .{
        .recipient_key = b_pub.asBytes(),
        .exporter = .{ .transport = webrtc.transport_name, .designator = c_designator[0..] },
        .gifter_exporter_session = &zero32,
        .gifter_side = &zero32,
        .gift_id = &gift_id,
        .signature = "",
    };
    const give_signed = try codec.syrup.canonicalHandoffGiveSignedBytes(allocator, give);
    defer allocator.free(give_signed);
    const give_sig = crypto.sign(&a_secret, give_signed);
    give.signature = give_sig.asBytes();

    // B is the offerer (it reaches C); C is the answerer (it is reached).
    var offerer = try webrtc.Peer.init(true);
    defer offerer.deinit();
    var answerer = try webrtc.Peer.init(false);
    defer answerer.deinit();

    // C's signaling inbox listens on TCP loopback; B reaches it at that address,
    // the shared rendezvous both peers can name.
    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    const signaling_address = listener.localAddress();

    var exporter_future = try io.concurrent(exporterHalf, .{ io, &listener, &answerer, allocator, a_pub.asBytes() });
    const recipient_result = recipientHalf(signaling_address, io, &offerer, allocator, give, c_designator[0..]);
    const exporter_result = exporter_future.await(io);
    try recipient_result;
    try exporter_result;

    std.debug.print("webrtc-handoff: OK — a webrtc give redeemed over CapTP by signaling-then-handshake; C verified the certificates and B called the gifted capability over the DataChannel\n", .{});
}
