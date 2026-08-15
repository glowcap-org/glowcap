//! The WebRTC signaling object as a real OCapN capability, driven over CapTP
//! (ADR-0089 phase 6, native half).
//!
//! `webrtc-mesh` builds the signaling object (phase 5) and calls its
//! `offer` / `candidate` verbs directly, in process. This proof hosts the same
//! verbs on a `Host` and routes every one of them over a real keyed OCapN
//! session, which is the wire-capability shape the browser arm and a
//! room-introduction redeem both build on: the offer, the answer, and the ICE
//! candidates all cross a CapTP session before the DataChannel exists.
//!
//! The exporter hosts a signaling inbox behind a keyed CapTP session over TCP
//! loopback. The inbox holds the exporter's sidecar `webrtc.Peer` and answers
//! three verbs, the phase-5 object's shape narrowed to one exporter:
//!
//!   offer(sdp)   -> the exporter's SDP answer (produced through its sidecar)
//!   candidate(ice) -> apply one trickled ICE candidate to the sidecar
//!   poll()       -> the exporter's next locally gathered candidate, or ""
//!
//! The recipient dials the inbox, drives the channel up entirely through these
//! verbs over the signaling session, and once its DataChannel opens closes the
//! signaling session. The exporter's `serve` returns, and both peers then hold
//! the direct keyed OCapN session over the DataChannel exactly as
//! `webrtc-interop` proves it. A green run proves the signaling capability, over
//! the wire, brings up a real channel that carries a real session.
//!
//! `poll` is the one narrowing from the ADR's push-trickle shape: a pull keeps
//! the recipient from having to host its own inbox for the exporter to call
//! back on, so this stays a single-session proof. The routing hub keyed by
//! designator and the recipient-hosted inbox (a giftable answering over
//! `currentSession`) are the room-introduction topology, deferred to the redeem
//! pass. Every signaling message here still crosses a real keyed session.
//!
//! Not part of the hermetic `zig build check`: it links the Rust sidecar
//! staticlib (`zig build webrtc-lib`, needs cargo), so it runs as the sibling
//! step `zig build webrtc-signaling-captp`.

const std = @import("std");
const pancake = @import("pancake");
const webrtc = @import("webrtc");
const webrtc_common = @import("webrtc_common");

/// A finite handshake budget for the signaling dial. Unbounded would turn a
/// signaling host that accepts and then stalls into a hang rather than a
/// failure.
const handshake_budget: driver.Budget = .{ .ms = 15_000 };

const crypto = pancake.foundation.crypto;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;
const tcp = pancake.net.tcp;
const ip = std.Io.net;

// The signaling inbox actor, the channel-bring-up client, and the SDP frame cap
// are the shared WebRTC signaling core (interop/webrtc_common.zig), driven the
// same way by any future Host-integrated WebRTC handoff.
const SignalingInbox = webrtc_common.SignalingInbox;
const bringUpViaCapTP = webrtc_common.bringUpViaCapTP;
const waitOpen = webrtc_common.waitOpen;
const sig_frame_cap = webrtc_common.sig_frame_cap;

const frame_cap: usize = 4096;
const greeting = "hello over webrtc signaling captp";

/// The published actor: answers `greet` with a static greeting.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        _ = msg;
        return .{ .string = greeting };
    }
};

/// The exporter half: host the signaling inbox over a keyed CapTP session until
/// the recipient's channel is up (it closes the signaling session), then serve a
/// Greeter behind the keyed handshake over the open DataChannel.
fn exporterHalf(
    io: std.Io,
    listener: *tcp.Listener,
    resident: *webrtc.Resident,
    peer: *webrtc.Peer,
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
) anyerror!void {
    // 1. Signaling over CapTP: accept the recipient and route offer/candidate/poll
    //    to the sidecar peer until the recipient closes the session.
    {
        var sig_peer = engine.Peer.initNegotiating(allocator);
        defer sig_peer.deinit();
        sig_peer.session_state.limits.max_frame_bytes = sig_frame_cap;

        const read_buf = try allocator.alloc(u8, sig_frame_cap);
        defer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, sig_frame_cap);
        defer allocator.free(write_buf);

        var sig = try driver.acceptVia(allocator, listener.asNetlayer(), &sig_peer, .ephemeral, read_buf, write_buf, .{
            .handshake = handshake_budget,
            .settle = handshake_budget,
        });
        defer sig.deinit();
        _ = try sig.publish("signaling", SignalingInbox, .{ .peer = peer });
        try sig.serve();
    }

    // 2. The channel is up; hold the keyed OCapN session over the DataChannel.
    try waitOpen(resident, peer, 2000);

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

/// The recipient half: bring the channel up over the signaling session, then
/// complete the keyed handshake over the DataChannel, pin the exporter's key,
/// fetch the Greeter, and call it.
fn recipientHalf(
    address: ip.IpAddress,
    io: std.Io,
    resident: *webrtc.Resident,
    offerer: *webrtc.Peer,
    allocator: std.mem.Allocator,
    secret: crypto.SecretKey,
    expect_designator: []const u8,
) anyerror!void {
    // 1. Signaling over CapTP: dial the exporter's inbox and drive the channel up.
    {
        var sig_peer = engine.Peer.initNegotiating(allocator);
        defer sig_peer.deinit();
        sig_peer.session_state.limits.max_frame_bytes = sig_frame_cap;

        const read_buf = try allocator.alloc(u8, sig_frame_cap);
        defer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, sig_frame_cap);
        defer allocator.free(write_buf);

        const tcp_provider = try tcp.Provider.create(allocator, io, .{});
        defer tcp_provider.destroy(allocator);
        const netlayers = tcp_provider.netlayers();
        var designator_buf: [tcp.designator_buf_len]u8 = undefined;
        var sig = try driver.connectVia(allocator, &netlayers, &sig_peer, tcp.locatorFromAddress(&designator_buf, address), .ephemeral, read_buf, write_buf, .{
            .handshake = handshake_budget,
            .settle = handshake_budget,
        });
        defer sig.deinit();
        const inbox = try sig.fetch("signaling");
        try bringUpViaCapTP(&sig, inbox, resident, offerer, allocator);
    }

    // 2. The channel is up; hold the keyed OCapN session over the DataChannel.
    var engine_peer = engine.Peer.initNegotiating(allocator);
    defer engine_peer.deinit();
    engine_peer.session_state.limits.max_frame_bytes = frame_cap;
    // Demand the identity the far peer must claim, before any byte is fed
    // (ADR-0105). The channel came up through the signaling capability above,
    // but nothing told the WebRTC resident whose channel it is. The resident
    // asserts nothing, so this is a target check and provenance remains
    // unauthenticated.
    engine_peer.demandPartnerDurableKey(
        crypto.PeerKey.fromDesignator(expect_designator) orelse return error.InvalidDesignator,
    );

    const read_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(read_buf);
    const write_buf = try allocator.alloc(u8, frame_cap);
    defer allocator.free(write_buf);

    const conn = try offerer.connection(io, &engine_peer, .{ .read = read_buf, .write = write_buf });
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

    const exporter_secret = crypto.SecretKey.fromSeed([_]u8{0x63} ** crypto.SEED_BYTES);
    const recipient_secret = crypto.SecretKey.fromSeed([_]u8{0x64} ** crypto.SEED_BYTES);
    const exporter_designator = exporter_secret.publicKey().toDesignator();

    // The recipient offers (it initiates the reach); the exporter answers.
    var offerer_resident = try webrtc.Resident.init(.{ .include_loopback_candidates = true });
    defer offerer_resident.deinit() catch |err| std.log.err("WebRTC teardown failed: {s}", .{@errorName(err)});
    var answerer_resident = try webrtc.Resident.init(.{ .include_loopback_candidates = true });
    defer answerer_resident.deinit() catch |err| std.log.err("WebRTC teardown failed: {s}", .{@errorName(err)});
    var offerer = try offerer_resident.newPeer(true);
    defer offerer.deinit();
    var answerer = try answerer_resident.newPeer(false);
    defer answerer.deinit();

    // The signaling capability listens on TCP loopback; the recipient dials it.
    var listener = try tcp.Listener.bind(io, .{ .ip4 = ip.Ip4Address.loopback(0) });
    defer listener.deinit();
    const address = listener.localAddress();

    var exporter_future = try io.concurrent(exporterHalf, .{ io, &listener, &answerer_resident, &answerer, allocator, exporter_secret });
    const recipient_result = recipientHalf(address, io, &offerer_resident, &offerer, allocator, recipient_secret, exporter_designator[0..]);
    const exporter_result = exporter_future.await(io);
    try recipient_result;
    try exporter_result;

    std.debug.print("webrtc-signaling-captp: the signaling capability, over CapTP, brought up a DataChannel and a keyed OCapN session round-tripped over it\n", .{});
}
