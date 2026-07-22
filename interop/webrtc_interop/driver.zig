//! Live WebRTC transport: two native pancake peers hold a real keyed OCapN
//! conversation over one reliable, ordered `RTCDataChannel` (ADR-0089 phase 2).
//!
//! There is no netlayer dial yet (that is phase 4), so this drives the transport
//! at the level below the netlayer. One peer is the offerer, the other the
//! answerer; the driver ferries their SDP offer, answer, and ICE candidates
//! between them in-process (the "out of band" signaling phase 2 stands on, in
//! place of the OCapN signaling capability phase 5 adds). On loopback the two
//! reach each other on host candidates alone, with no STUN or TURN.
//!
//! Once the channel opens, each peer's connection is presented as an ordinary
//! `net.Connection`, and the two run the same keyed handshake, bootstrap fetch,
//! and deliver/resolve every other transport runs: the answerer publishes a
//! Greeter and serves; the offerer completes the keyed handshake, pins the
//! answerer's key, fetches the Greeter, and calls it. The bytes on the wire are
//! DTLS-encrypted SCTP over the DataChannel; the keyed handshake proves each
//! peer's Ed25519 identity end to end on top of it.
//!
//! Goblins ships no WebRTC netlayer, so this is pancake-to-pancake by
//! construction, exactly like `iroh-interop`: it proves the netlayer contract
//! carries a peer-to-peer encrypted transport, not Goblins interop (the
//! conversation is the one the TCP gates already prove against Goblins).
//!
//! Not part of the hermetic `zig build check`: it links the Rust sidecar
//! staticlib (`zig build webrtc-lib`, needs cargo), so it runs as the sibling
//! step `zig build webrtc-interop`.

const std = @import("std");
const pancake = @import("pancake");
const webrtc = @import("webrtc");

const crypto = pancake.foundation.crypto;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const net = pancake.net;

const frame_cap: usize = 4096;
const greeting = "hello over webrtc";

/// The published actor: answers `greet` with a static greeting.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        _ = msg;
        return .{ .string = greeting };
    }
};

/// Bring the DataChannel up by ferrying signaling between the two peers in this
/// process: exchange the offer and answer, then trickle ICE candidates both ways
/// until each peer reports its channel open. Bounded so a stuck ICE or DTLS
/// negotiation fails the gate instead of hanging it.
fn bringUpChannel(offerer: *webrtc.Peer, answerer: *webrtc.Peer) !void {
    var sdp_buf: [16 * 1024]u8 = undefined;
    var cand_buf: [4 * 1024]u8 = undefined;
    var len: usize = 0;

    const offer = try offerer.createOffer(&sdp_buf, &len);
    try answerer.setRemoteOffer(offer);
    const answer = try answerer.createAnswer(&sdp_buf, &len);
    try offerer.setRemoteAnswer(answer);

    // Up to ~30s of 100ms poll windows: on loopback the channel opens in well
    // under a second, so this bounds only a failure.
    var rounds: usize = 0;
    while (rounds < 300) : (rounds += 1) {
        while (try offerer.nextLocalCandidate(&cand_buf, &len)) |candidate| {
            try answerer.addRemoteCandidate(candidate);
        }
        while (try answerer.nextLocalCandidate(&cand_buf, &len)) |candidate| {
            try offerer.addRemoteCandidate(candidate);
        }
        if (offerer.waitOpen(50) and answerer.waitOpen(50)) return;
    }
    return error.ChannelBringUpTimeout;
}

/// The answerer half: run the responder keyed handshake over the open channel
/// signing with `secret`, publish the Greeter, and serve until the offerer
/// leaves.
fn answererHalf(
    io: std.Io,
    peer: *webrtc.Peer,
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
) anyerror!void {
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

    const designator = secret.publicKey().toDesignator();
    const self_locator: model.PeerLocator = .{
        .transport = webrtc.transport_name,
        .designator = designator[0..],
        .hints = model.Hints.emptyFalse(),
    };
    try vat.startKeyedSessionWithSecret(self_locator, secret);
    _ = try vat.publish("greeter", Greeter, .{});
    try vat.serve();
}

/// The offerer half: run the initiator keyed handshake signing with `secret`,
/// pinning the answerer's key so a wrong partner refuses, then assert the
/// partner's signed designator, fetch the Greeter, and call it.
fn offererHalf(
    io: std.Io,
    peer: *webrtc.Peer,
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
    expect_designator: []const u8,
) anyerror!void {
    var engine_peer = engine.Peer.initNegotiating(allocator);
    defer engine_peer.deinit();
    engine_peer.session_state.limits.max_frame_bytes = frame_cap;
    // Pin the answerer's key: the engine refuses an `op:start-session` signed by
    // any other key before the session opens, so the DataChannel's far end must
    // prove the identity we expect.
    engine_peer.expectPartnerKey(crypto.PeerKey.fromDesignator(expect_designator) orelse return error.InvalidDesignator);

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const conn = try peer.connection(io, &engine_peer, .{ .read = read_buf, .write = write_buf });
    var vat = driver.BlockingSession.over(allocator, &engine_peer, conn);
    defer vat.deinit();

    const designator = secret.publicKey().toDesignator();
    const self_locator: model.PeerLocator = .{
        .transport = webrtc.transport_name,
        .designator = designator[0..],
        .hints = model.Hints.emptyFalse(),
    };
    try vat.startKeyedSessionWithSecret(self_locator, secret);

    const partner = engine_peer.session_state.partnerDesignator() orelse return error.NoPartnerDesignator;
    if (!std.mem.eql(u8, partner, expect_designator)) return error.PartnerMismatch;

    const greeter = try vat.fetch("greeter");
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const settled = try vat.call(greeter, .{ .verb = "greet", .args = &.{.{ .string = "pancake" }} }, arena_state.allocator());
    switch (settled) {
        .fulfilled => |arg| {
            if (arg != .string or !std.mem.eql(u8, arg.string, greeting)) return error.WrongReply;
        },
        .broken, .give => return error.CallBroke,
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Deterministic keys: the designators the two peers sign and pin against.
    const answerer_secret = crypto.SecretKey.fromSeed([_]u8{0x51} ** crypto.SEED_BYTES);
    const offerer_secret = crypto.SecretKey.fromSeed([_]u8{0x52} ** crypto.SEED_BYTES);
    const answerer_designator = answerer_secret.publicKey().toDesignator();

    var offerer = try webrtc.Peer.init(true);
    defer offerer.deinit();
    var answerer = try webrtc.Peer.init(false);
    defer answerer.deinit();

    try bringUpChannel(&offerer, &answerer);

    // The answerer serves on its own thread; the offerer drives the conversation
    // on this one. Each peer handle is used by exactly one thread past bring-up.
    var answerer_future = try io.concurrent(answererHalf, .{ io, &answerer, allocator, answerer_secret });
    const offerer_result = offererHalf(io, &offerer, allocator, offerer_secret, answerer_designator[0..]);
    const answerer_result = answerer_future.await(io);
    try offerer_result;
    try answerer_result;

    std.debug.print("webrtc-interop: keyed OCapN session opened and greet round-tripped over a real DataChannel\n", .{});
}
