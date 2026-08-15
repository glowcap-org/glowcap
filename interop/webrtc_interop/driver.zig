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
//! Channel establishment is driven from each resident's readiness fd and checked
//! with non-blocking open calls. Before CapTP starts, the peers exchange raw bytes
//! in both directions through try-I/O. The same channels are then presented as
//! ordinary `net.Connection`s for the keyed handshake, bootstrap fetch, and
//! deliver/resolve conversation every other transport runs. The bytes on the
//! wire are DTLS-encrypted SCTP; the keyed handshake proves each peer's Ed25519
//! identity end to end on top of it.
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
fn drainReady(resident: *webrtc.Resident, peer: *webrtc.Peer) !u32 {
    var flags: u32 = 0;
    var events: [16]webrtc.ReadyEvent = undefined;
    while (true) {
        const count = try resident.drainReady(&events);
        for (events[0..count]) |event| {
            if (event.subject != @intFromEnum(peer.id())) return error.UnexpectedReadySubject;
            flags |= event.events;
        }
        if (count < events.len) return flags;
    }
}

fn pollReady(resident: *webrtc.Resident, peer: *webrtc.Peer, timeout_ms: i32) !u32 {
    var events: [16]webrtc.ReadyEvent = undefined;
    const count = try resident.pollReady(&events, timeout_ms);
    var flags: u32 = 0;
    for (events[0..count]) |event| {
        if (event.subject != @intFromEnum(peer.id())) return error.UnexpectedReadySubject;
        flags |= event.events;
    }
    if (count == events.len) flags |= try drainReady(resident, peer);
    return flags;
}

fn checkOpen(peer: *webrtc.Peer) !bool {
    peer.checkOpen() catch |err| return switch (err) {
        error.WouldBlock => false,
        error.Closed => error.ChannelClosed,
    };
    return true;
}

fn bringUpChannel(
    offerer_resident: *webrtc.Resident,
    offerer: *webrtc.Peer,
    answerer_resident: *webrtc.Resident,
    answerer: *webrtc.Peer,
) !void {
    var sdp_buf: [16 * 1024]u8 = undefined;
    var cand_buf: [4 * 1024]u8 = undefined;
    var len: usize = 0;

    const offer = try offerer.createOffer(&sdp_buf, &len);
    try answerer.setRemoteOffer(offer);
    const answer = try answerer.createAnswer(&sdp_buf, &len);
    try offerer.setRemoteAnswer(answer);

    // Up to ~30s of readiness polling: on loopback the channel opens in well
    // under a second, so this bounds only a failure.
    var rounds: usize = 0;
    while (rounds < 300) : (rounds += 1) {
        _ = try pollReady(offerer_resident, offerer, 50);
        _ = try pollReady(answerer_resident, answerer, 50);
        while (try offerer.nextLocalCandidate(&cand_buf, &len)) |candidate| {
            try answerer.addRemoteCandidate(candidate);
        }
        while (try answerer.nextLocalCandidate(&cand_buf, &len)) |candidate| {
            try offerer.addRemoteCandidate(candidate);
        }
        if (try checkOpen(offerer) and try checkOpen(answerer)) return;
    }
    return error.ChannelBringUpTimeout;
}

fn trySend(resident: *webrtc.Resident, peer: *webrtc.Peer, bytes: []const u8) !void {
    var offset: usize = 0;
    var rounds: usize = 0;
    while (offset < bytes.len and rounds < 300) : (rounds += 1) {
        const count = peer.tryWrite(bytes[offset..]) catch |err| switch (err) {
            error.WouldBlock => {
                _ = try pollReady(resident, peer, 100);
                continue;
            },
            error.Closed => return error.ChannelClosed,
            error.Failed => return error.ChannelWriteFailed,
        };
        if (count == 0) return error.WriteMadeNoProgress;
        offset += count;
    }
    if (offset != bytes.len) return error.ChannelWriteTimeout;
}

fn tryReceive(resident: *webrtc.Resident, peer: *webrtc.Peer, expected: []const u8) !void {
    var received: [128]u8 = undefined;
    if (expected.len > received.len) return error.ProbeTooLarge;
    var offset: usize = 0;
    var rounds: usize = 0;
    while (offset < expected.len and rounds < 300) : (rounds += 1) {
        const count = peer.tryRead(received[offset..expected.len]) catch |err| switch (err) {
            error.WouldBlock => {
                _ = try pollReady(resident, peer, 100);
                continue;
            },
            error.Closed => return error.ChannelClosed,
            error.Failed => return error.ChannelReadFailed,
        };
        offset += count;
    }
    if (offset != expected.len) return error.ChannelReadTimeout;
    if (!std.mem.eql(u8, received[0..offset], expected)) return error.WrongProbeBytes;
}

fn proveReadinessBytes(
    offerer_resident: *webrtc.Resident,
    offerer: *webrtc.Peer,
    answerer_resident: *webrtc.Resident,
    answerer: *webrtc.Peer,
) !void {
    const to_answerer = "offerer readiness probe";
    try trySend(offerer_resident, offerer, to_answerer);
    try tryReceive(answerer_resident, answerer, to_answerer);

    const to_offerer = "answerer readiness probe";
    try trySend(answerer_resident, answerer, to_offerer);
    try tryReceive(offerer_resident, offerer, to_offerer);
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
    var vat = driver.BlockingSession.over(allocator, &engine_peer, conn, .{
        .handshake = .unbounded,
        .settle = .unbounded,
    });
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
    // Demand the answerer's durable identity: the engine refuses a hello that
    // does not claim it, before the session opens. What *proves* the claim is
    // the DataChannel's DTLS handshake under capability-authorized signaling,
    // and the resident asserts that itself when it hands back a connection
    // (ADR-0105), so this side states only what it asked for.
    engine_peer.demandPartnerDurableKey(
        crypto.PeerKey.fromDesignator(expect_designator) orelse return error.InvalidDesignator,
    );

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const conn = try peer.connection(io, &engine_peer, .{ .read = read_buf, .write = write_buf });
    var vat = driver.BlockingSession.over(allocator, &engine_peer, conn, .{
        .handshake = .unbounded,
        .settle = .unbounded,
    });
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

    var offerer_resident = try webrtc.Resident.init(.{ .include_loopback_candidates = true });
    defer offerer_resident.deinit() catch |err| std.log.err("WebRTC teardown failed: {s}", .{@errorName(err)});
    var answerer_resident = try webrtc.Resident.init(.{ .include_loopback_candidates = true });
    defer answerer_resident.deinit() catch |err| std.log.err("WebRTC teardown failed: {s}", .{@errorName(err)});
    var offerer = try offerer_resident.newPeer(true);
    defer offerer.deinit();
    var answerer = try answerer_resident.newPeer(false);
    defer answerer.deinit();

    // The capability-authorized binding (ADR-0105): the in-process signaling
    // ferry stands in for a signaling capability scoped to each peer, so each
    // side authorizes the identity it exchanged SDP with, and the adapter
    // installs the binding before the first CapTP byte.
    offerer.authorizeRemote(answerer_secret.publicKey());
    answerer.authorizeRemote(offerer_secret.publicKey());

    try bringUpChannel(&offerer_resident, &offerer, &answerer_resident, &answerer);
    try proveReadinessBytes(&offerer_resident, &offerer, &answerer_resident, &answerer);

    // The answerer serves on its own thread; the offerer drives the conversation
    // on this one. Each peer handle is used by exactly one thread past bring-up.
    var answerer_future = try io.concurrent(answererHalf, .{ io, &answerer, allocator, answerer_secret });
    const offerer_result = offererHalf(io, &offerer, allocator, offerer_secret, answerer_designator[0..]);
    const answerer_result = answerer_future.await(io);
    try offerer_result;
    try answerer_result;

    std.debug.print("webrtc-interop: readiness-driven try-I/O and keyed OCapN round-tripped over a real DataChannel\n", .{});
}
