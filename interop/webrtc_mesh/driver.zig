//! Live WebRTC signaling mesh: two native pancake peers bring up a DataChannel
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
const pancake = @import("pancake");
const webrtc = @import("webrtc");

const crypto = pancake.foundation.crypto;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;

const frame_cap: usize = 4096;
const greeting = "hello over webrtc mesh";

/// The published actor: answers `greet` with a static greeting.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        _ = msg;
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
    var sdp_buf: [16 * 1024]u8 = undefined;
    var answer_buf: [16 * 1024]u8 = undefined;
    var cand_buf: [4 * 1024]u8 = undefined;
    var len: usize = 0;
    var alen: usize = 0;

    const offer_sdp = try offerer.createOffer(&sdp_buf, &len);
    const answer_sdp = try hub.offer(answerer_designator, offer_sdp, &answer_buf, &alen);
    try offerer.setRemoteAnswer(answer_sdp);

    var rounds: usize = 0;
    while (rounds < 300) : (rounds += 1) {
        var offerer_events: [16]webrtc.ReadyEvent = undefined;
        const offerer_count = try offerer_resident.pollReady(&offerer_events, 50);
        for (offerer_events[0..offerer_count]) |event| {
            if (event.subject != @intFromEnum(offerer.id())) return error.UnexpectedReadySubject;
        }
        var answerer_events: [16]webrtc.ReadyEvent = undefined;
        const answerer_count = try answerer_resident.pollReady(&answerer_events, 50);
        for (answerer_events[0..answerer_count]) |event| {
            if (event.subject != @intFromEnum(answerer.id())) return error.UnexpectedReadySubject;
        }
        while (try offerer.nextLocalCandidate(&cand_buf, &len)) |ice| {
            try hub.candidate(answerer_designator, ice);
        }
        while (try answerer.nextLocalCandidate(&cand_buf, &len)) |ice| {
            try hub.candidate(offerer_designator, ice);
        }
        offerer.checkOpen() catch |err| switch (err) {
            error.WouldBlock => continue,
            error.Closed => return error.ChannelClosed,
        };
        answerer.checkOpen() catch |err| switch (err) {
            error.WouldBlock => continue,
            error.Closed => return error.ChannelClosed,
        };
        return;
    }
    return error.ChannelBringUpTimeout;
}

/// The exporter half: the answerer serves a Greeter behind the keyed handshake.
fn exporterHalf(
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

/// The recipient half: the offerer completes the keyed handshake, pins the
/// exporter's key, fetches the Greeter, and calls it.
fn recipientHalf(
    io: std.Io,
    peer: *webrtc.Peer,
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
    expect_designator: []const u8,
) anyerror!void {
    var engine_peer = engine.Peer.initNegotiating(allocator);
    defer engine_peer.deinit();
    engine_peer.session_state.limits.max_frame_bytes = frame_cap;
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

    // The exporter answers; the recipient offers and reaches it. Deterministic
    // keys are the designators the two peers sign, pin, and register under.
    const exporter_secret = crypto.SecretKey.fromSeed([_]u8{0x61} ** crypto.SEED_BYTES);
    const recipient_secret = crypto.SecretKey.fromSeed([_]u8{0x62} ** crypto.SEED_BYTES);
    const exporter_designator = exporter_secret.publicKey().toDesignator();
    const recipient_designator = recipient_secret.publicKey().toDesignator();

    // The offerer is the recipient (it initiates the reach); the answerer is the
    // exporter (it is being reached).
    var offerer_resident = try webrtc.Resident.init();
    defer offerer_resident.deinit();
    var answerer_resident = try webrtc.Resident.init();
    defer answerer_resident.deinit();
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
    var exporter_future = try io.concurrent(exporterHalf, .{ io, &answerer, allocator, exporter_secret });
    const recipient_result = recipientHalf(io, &offerer, allocator, recipient_secret, exporter_designator[0..]);
    const exporter_result = exporter_future.await(io);
    try recipient_result;
    try exporter_result;

    std.debug.print("webrtc-mesh: signaling hub brought up a DataChannel and a keyed OCapN session round-tripped over it\n", .{});
}
