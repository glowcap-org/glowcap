//! Live WebRTC transport: two Zig glowcap peers hold a real keyed OCapN
//! conversation over one reliable, ordered `RTCDataChannel` (ADR-0035).
//!
//! There is no netlayer dial here, so this drives the transport at the level
//! below the netlayer. One peer is the offerer, the other the answerer. The
//! driver ferries their SDP offer, answer, and ICE candidates between them
//! in-process, as out-of-band signaling in place of the OCapN signaling
//! capability (see `webrtc-mesh`). On loopback the two
//! reach each other on host candidates alone, with no STUN or TURN.
//!
//! Channel establishment is driven from each resident's readiness fd and checked
//! with non-blocking open calls. Before CapTP starts, the peers exchange one
//! probe packet in each direction through try-I/O. CapTP then runs through the
//! same Host packet seam the generic WebRTC completion backend uses. The bytes
//! on the wire are DTLS-encrypted SCTP. The keyed handshake proves each peer's
//! Ed25519 identity end to end on top of it.
//!
//! Goblins ships no WebRTC netlayer, so this is glowcap-to-glowcap by
//! construction, exactly like `iroh-session`: it proves the netlayer contract
//! carries a peer-to-peer encrypted transport, not Goblins interop (the
//! conversation is the one the TCP gates already prove against Goblins).
//!
//! Not part of the hermetic `zig build check`: it links the Rust sidecar
//! staticlib (`zig build webrtc-sidecar-build`, needs cargo), so it runs as the sibling
//! step `zig build webrtc-session`.

const std = @import("std");
const glowcap = @import("glowcap");
const webrtc = @import("webrtc");
const webrtc_harness = @import("webrtc_harness");

const crypto = glowcap.foundation.crypto;

const frame_cap: usize = 4096;
const greeting = "hello over webrtc";

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
            if (event.subject != @backingInt(peer.id())) return error.UnexpectedReadySubject;
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
        if (event.subject != @backingInt(peer.id())) return error.UnexpectedReadySubject;
        flags |= event.events;
    }
    if (count == events.len) flags |= try drainReady(resident, peer);
    return flags;
}

fn checkOpen(peer: *webrtc.Peer) !bool {
    peer.checkOpen() catch |err| return switch (err) {
        error.WouldBlock => false,
        error.Closed => error.ChannelClosed,
        error.Failed => error.ChannelFailed,
    };
    return true;
}

fn bringUpChannel(
    offerer_resident: *webrtc.Resident,
    offerer: *webrtc.Peer,
    answerer_resident: *webrtc.Resident,
    answerer: *webrtc.Peer,
) !void {
    var signal_buf: [webrtc.max_signal_bytes]u8 = undefined;
    var len: usize = 0;

    const offer = try offerer.createOffer(&signal_buf, &len);
    try answerer.setRemoteOffer(offer);
    const answer = try answerer.createAnswer(&signal_buf, &len);
    try offerer.setRemoteAnswer(answer);

    // Up to ~30s of readiness polling: on loopback the channel opens in well
    // under a second, so this bounds only a failure.
    var rounds: usize = 0;
    while (rounds < 300) : (rounds += 1) {
        _ = try pollReady(offerer_resident, offerer, 50);
        _ = try pollReady(answerer_resident, answerer, 50);
        while (try offerer.nextLocalCandidate(&signal_buf, &len)) |candidate| {
            try answerer.addRemoteCandidate(candidate);
        }
        while (try answerer.nextLocalCandidate(&signal_buf, &len)) |candidate| {
            try offerer.addRemoteCandidate(candidate);
        }
        if (try checkOpen(offerer) and try checkOpen(answerer)) return;
    }
    return error.ChannelBringUpTimeout;
}

fn trySend(resident: *webrtc.Resident, peer: *webrtc.Peer, bytes: []const u8) !void {
    var rounds: usize = 0;
    while (rounds < 300) : (rounds += 1) {
        const count = peer.trySendPacket(bytes) catch |err| switch (err) {
            error.WouldBlock => {
                _ = try pollReady(resident, peer, 100);
                continue;
            },
            error.BufferTooSmall => return error.ProbeTooLarge,
            error.Closed => return error.ChannelClosed,
            error.Failed => return error.ChannelWriteFailed,
        };
        if (count != bytes.len) return error.ShortPacketSend;
        return;
    }
    return error.ChannelWriteTimeout;
}

fn tryReceive(resident: *webrtc.Resident, peer: *webrtc.Peer, expected: []const u8) !void {
    var received: [128]u8 = undefined;
    if (expected.len > received.len) return error.ProbeTooLarge;
    var rounds: usize = 0;
    while (rounds < 300) : (rounds += 1) {
        const count = peer.tryReceivePacket(&received) catch |err| switch (err) {
            error.WouldBlock => {
                _ = try pollReady(resident, peer, 100);
                continue;
            },
            error.BufferTooSmall => return error.ProbeTooLarge,
            error.Closed => return error.ChannelClosed,
            error.Failed => return error.ChannelReadFailed,
        };
        if (count != expected.len) return error.WrongProbeBytes;
        if (!std.mem.eql(u8, received[0..count], expected)) return error.WrongProbeBytes;
        return;
    }
    return error.ChannelReadTimeout;
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Deterministic keys: the designators the two peers sign and pin against.
    const answerer_seed = @as([crypto.seed_bytes]u8, @splat(0x51));
    const offerer_seed = @as([crypto.seed_bytes]u8, @splat(0x52));
    const answerer_secret = crypto.SecretKey.fromSeed(answerer_seed);
    const offerer_secret = crypto.SecretKey.fromSeed(offerer_seed);
    const answerer_designator = answerer_secret.publicKey().toDesignator();

    var offerer_resident = try webrtc.Resident.init(.{ .include_loopback_candidates = true });
    defer offerer_resident.deinit() catch |err| std.log.err("WebRTC teardown failed: {s}", .{@errorName(err)});
    var answerer_resident = try webrtc.Resident.init(.{ .include_loopback_candidates = true });
    defer answerer_resident.deinit() catch |err| std.log.err("WebRTC teardown failed: {s}", .{@errorName(err)});
    var offerer = try offerer_resident.newPeer(true);
    defer offerer.deinit();
    var answerer = try answerer_resident.newPeer(false);
    defer answerer.deinit();

    // The capability-authorized binding (ADR-0028): the in-process signaling
    // ferry stands in for a signaling capability scoped to each peer, so each
    // side authorizes the identity it exchanged SDP with, and the adapter
    // installs the binding before the first CapTP byte.
    offerer.authorizeRemote(answerer_secret.publicKey());
    answerer.authorizeRemote(offerer_secret.publicKey());

    try bringUpChannel(&offerer_resident, &offerer, &answerer_resident, &answerer);
    try proveReadinessBytes(&offerer_resident, &offerer, &answerer_resident, &answerer);

    // The answerer serves on its own thread; the offerer drives the conversation
    // on this one. Each peer handle is used by exactly one thread past bring-up.
    var answerer_future = try io.concurrent(webrtc_harness.serveGreeter, .{ &answerer_resident, &answerer, allocator, answerer_seed, frame_cap, greeting });
    const offerer_result = webrtc_harness.dialAndGreet(&offerer_resident, &offerer, allocator, offerer_seed, answerer_designator[0..], frame_cap, greeting);
    const answerer_result = answerer_future.await(io);
    try offerer_result;
    try answerer_result;

    std.debug.print("webrtc-session: readiness-driven try-I/O and keyed OCapN round-tripped over a real DataChannel\n", .{});
}
