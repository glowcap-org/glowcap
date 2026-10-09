//! Live WebRTC signaling mesh: two native glowcap peers bring up a DataChannel
//! through an OCapN-shaped signaling object, then hold a keyed OCapN session
//! over it (ADR-0089 phase 5).
//!
//! This is WebRTC's capability-routed signaling shape: an introducer routes the
//! peers to each other. Here the introducer is the `SignalingHub`, a
//! rendezvous keyed by designator that carries the offer, the answer, and the
//! ICE candidates between the two peers. The hub holds no WebRTC state and
//! parses no payload; it moves opaque strings between the two designators it was
//! given references to, the same byte-transparency a room or the relay holds.
//! That is the ADR-0089 signaling-capability shape, proven natively before the
//! browser arm (phase 6) drives the same verbs over the wire.
//!
//! The delta from `webrtc-interop` is exactly the signaling path: there the
//! driver ferries SDP and ICE between the two peers directly; here every offer,
//! answer, and candidate routes through the hub's `offer` / `candidate` verbs.
//! Once the channel is open, the keyed handshake and the greet round-trip are
//! identical, so a green mesh run proves the signaling object brings up a real
//! channel that carries a real session.
//!
//! Not part of the hermetic `zig build check`: it links the Rust sidecar
//! staticlib (`zig build webrtc-lib`, needs cargo), so it runs as the sibling
//! step `zig build webrtc-mesh`.

const std = @import("std");
const glowcap = @import("glowcap");
const webrtc = @import("webrtc");
const webrtc_common = @import("webrtc_common");

const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const actors = glowcap.actors;

const frame_cap: usize = 4096;
const greeting = "hello over webrtc mesh";

/// The published actor: answers `greet` with a static greeting.
const Greeter = struct {
    done: *std.atomic.Value(bool),

    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "greet")) return error.NoSuchMethod;
        self.done.store(true, .release);
        return .{ .string = greeting };
    }
};

/// The in-tree signaling object (ADR-0089 phase 5): a rendezvous keyed by peer
/// designator that routes the offer, the answer, and the ICE candidates between
/// two webrtc peers. It holds references to the two peers it introduces and
/// forwards opaque strings between them, the same way a room routes a chat line.
/// It parses no SDP and no candidate. This native proof calls it directly; the
/// capability version (phase 6) hosts the same two verbs on a Host and routes
/// them over CapTP.
const SignalingHub = struct {
    const Entry = struct { designator: []const u8, peer: *webrtc.Peer };
    entries: [2]?Entry = .{ null, null },

    fn register(self: *SignalingHub, designator: []const u8, peer: *webrtc.Peer) void {
        for (&self.entries) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .designator = designator, .peer = peer };
                return;
            }
        }
        unreachable; // exactly two peers register per mesh
    }

    fn find(self: *SignalingHub, designator: []const u8) ?*webrtc.Peer {
        for (self.entries) |slot| {
            if (slot) |entry| if (std.mem.eql(u8, entry.designator, designator)) return entry.peer;
        }
        return null;
    }

    /// The `offer` verb: route `sdp` to `to` and return `to`'s SDP answer.
    fn offer(self: *SignalingHub, to: []const u8, sdp: []const u8, answer_buf: []u8, out_len: *usize) ![]const u8 {
        const target = self.find(to) orelse return error.UnknownSignalingPeer;
        try target.setRemoteOffer(sdp);
        return target.createAnswer(answer_buf, out_len);
    }

    /// The `candidate` verb: route one trickled ICE candidate to `to`.
    fn candidate(self: *SignalingHub, to: []const u8, ice: []const u8) !void {
        const target = self.find(to) orelse return error.UnknownSignalingPeer;
        try target.addRemoteCandidate(ice);
    }
};

/// Bring the channel up through the hub: the offerer's offer routes to the
/// answerer through `hub.offer`, and every ICE candidate routes through
/// `hub.candidate`, until both peers report their channel open.
fn bringUpViaHub(
    hub: *SignalingHub,
    offerer_resident: *webrtc.Resident,
    offerer: *webrtc.Peer,
    answerer_resident: *webrtc.Resident,
    answerer: *webrtc.Peer,
    offerer_designator: []const u8,
    answerer_designator: []const u8,
) !void {
    offerer.authorizeRemote(crypto.PeerKey.fromDesignator(answerer_designator) orelse
        return error.InvalidDesignator);
    answerer.authorizeRemote(crypto.PeerKey.fromDesignator(offerer_designator) orelse
        return error.InvalidDesignator);

    var sdp_buf: [webrtc.max_signal_bytes]u8 = undefined;
    var signal_buf: [webrtc.max_signal_bytes]u8 = undefined;
    var len: usize = 0;
    var alen: usize = 0;

    const offer_sdp = try offerer.createOffer(&sdp_buf, &len);
    const answer_sdp = try hub.offer(answerer_designator, offer_sdp, &signal_buf, &alen);
    try offerer.setRemoteAnswer(answer_sdp);

    var rounds: usize = 0;
    while (rounds < 300) : (rounds += 1) {
        var offerer_events: [16]webrtc.ReadyEvent = undefined;
        const offerer_count = try offerer_resident.pollReady(&offerer_events, 50);
        for (offerer_events[0..offerer_count]) |event| {
            if (event.subject != @backingInt(offerer.id())) return error.UnexpectedReadySubject;
        }
        var answerer_events: [16]webrtc.ReadyEvent = undefined;
        const answerer_count = try answerer_resident.pollReady(&answerer_events, 50);
        for (answerer_events[0..answerer_count]) |event| {
            if (event.subject != @backingInt(answerer.id())) return error.UnexpectedReadySubject;
        }
        while (try offerer.nextLocalCandidate(&signal_buf, &len)) |ice| {
            try hub.candidate(answerer_designator, ice);
        }
        while (try answerer.nextLocalCandidate(&signal_buf, &len)) |ice| {
            try hub.candidate(offerer_designator, ice);
        }
        offerer.checkOpen() catch |err| switch (err) {
            error.WouldBlock => continue,
            error.Closed => return error.ChannelClosed,
            error.Failed => return error.ChannelFailed,
        };
        answerer.checkOpen() catch |err| switch (err) {
            error.WouldBlock => continue,
            error.Closed => return error.ChannelClosed,
            error.Failed => return error.ChannelFailed,
        };
        return;
    }
    return error.ChannelBringUpTimeout;
}

/// The exporter half: the answerer serves a Greeter behind the keyed handshake.
fn exporterHalf(
    resident: *webrtc.Resident,
    peer: *webrtc.Peer,
    allocator: std.mem.Allocator,
    seed: [crypto.SEED_BYTES]u8,
) anyerror!void {
    var host = try webrtc_common.hostFromSeed(allocator, seed, frame_cap);
    defer host.deinit();

    const designator = crypto.SecretKey.fromSeed(seed).publicKey().toDesignator();
    try host.setAdvertisedLocator(webrtc_common.locator(designator[0..]));
    const session = try host.openAcceptedAdvertised(webrtc.transport_name);
    try webrtc_common.bindAuthorizedChannel(&host, session, peer);

    const read_buf = try allocator.alloc(u8, webrtc.max_packet_bytes);
    defer allocator.free(read_buf);
    var pump = webrtc_common.PacketPump{ .read_buf = read_buf };
    defer pump.deinit();

    try webrtc_common.waitFor(resident, peer, &pump, &host, session, session, webrtc_common.sessionOpenDone, 10_000);
    var served = std.atomic.Value(bool).init(false);
    _ = try host.sessionPublish(session, "greeter", Greeter, .{ .done = &served });
    try webrtc_common.serveUntil(resident, peer, &pump, &host, session, &served, webrtc_common.atomicFlagDone, 30_000);
}

/// The recipient half: the offerer completes the keyed handshake, pins the
/// exporter's key, fetches the Greeter, and calls it.
fn recipientHalf(
    resident: *webrtc.Resident,
    peer: *webrtc.Peer,
    allocator: std.mem.Allocator,
    seed: [crypto.SEED_BYTES]u8,
    expect_designator: []const u8,
) anyerror!void {
    var host = try webrtc_common.hostFromSeed(allocator, seed, frame_cap);
    defer host.deinit();

    const designator = crypto.SecretKey.fromSeed(seed).publicKey().toDesignator();
    try host.setAdvertisedLocator(webrtc_common.locator(designator[0..]));
    const session = try host.openDialedLocator(webrtc_common.locator(expect_designator));
    try webrtc_common.bindAuthorizedChannel(&host, session, peer);

    const read_buf = try allocator.alloc(u8, webrtc.max_packet_bytes);
    defer allocator.free(read_buf);
    var pump = webrtc_common.PacketPump{ .read_buf = read_buf };
    defer pump.deinit();

    try webrtc_common.waitFor(resident, peer, &pump, &host, session, session, webrtc_common.sessionOpenDone, 10_000);
    const partner = try host.partnerIdentity(session);
    if (!std.mem.eql(u8, partner.designator, expect_designator)) return error.PartnerMismatch;

    const greeter = try webrtc_common.fetchRef(resident, peer, &pump, &host, session, "greeter", 10_000);
    try webrtc_common.sendAndExpectString(resident, peer, &pump, &host, session, greeter, .{
        .verb = "greet",
        .args = &.{.{ .string = "glowcap" }},
    }, greeting, 10_000);
    _ = try pump.drive(&host, session, peer);
    peer.close();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The exporter answers; the recipient offers and reaches it. Deterministic
    // keys are the designators the two peers sign, pin, and register under.
    const exporter_seed = @as([crypto.SEED_BYTES]u8, @splat(0x61));
    const recipient_seed = @as([crypto.SEED_BYTES]u8, @splat(0x62));
    const exporter_secret = crypto.SecretKey.fromSeed(exporter_seed);
    const recipient_secret = crypto.SecretKey.fromSeed(recipient_seed);
    const exporter_designator = exporter_secret.publicKey().toDesignator();
    const recipient_designator = recipient_secret.publicKey().toDesignator();

    // The offerer is the recipient (it initiates the reach); the answerer is the
    // exporter (it is being reached).
    var offerer_resident = try webrtc.Resident.init(.{ .include_loopback_candidates = true });
    defer offerer_resident.deinit() catch |err| std.log.err("WebRTC teardown failed: {s}", .{@errorName(err)});
    var answerer_resident = try webrtc.Resident.init(.{ .include_loopback_candidates = true });
    defer answerer_resident.deinit() catch |err| std.log.err("WebRTC teardown failed: {s}", .{@errorName(err)});
    var offerer = try offerer_resident.newPeer(true);
    defer offerer.deinit();
    var answerer = try answerer_resident.newPeer(false);
    defer answerer.deinit();

    // Introduce both peers to the signaling hub under their designators, then
    // bring the channel up entirely through its offer/candidate verbs.
    var hub = SignalingHub{};
    hub.register(recipient_designator[0..], &offerer);
    hub.register(exporter_designator[0..], &answerer);
    try bringUpViaHub(&hub, &offerer_resident, &offerer, &answerer_resident, &answerer, recipient_designator[0..], exporter_designator[0..]);

    // The exporter serves on its own thread; the recipient drives on this one.
    var exporter_future = try io.concurrent(exporterHalf, .{ &answerer_resident, &answerer, allocator, exporter_seed });
    const recipient_result = recipientHalf(&offerer_resident, &offerer, allocator, recipient_seed, exporter_designator[0..]);
    const exporter_result = exporter_future.await(io);
    try recipient_result;
    try exporter_result;

    std.debug.print("webrtc-mesh: signaling hub brought up a DataChannel and a keyed OCapN session round-tripped over it\n", .{});
}
