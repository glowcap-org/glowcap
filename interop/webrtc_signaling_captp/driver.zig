//! The WebRTC signaling object as a real OCapN capability, driven over CapTP
//! (ADR-0089).
//!
//! `webrtc-mesh` builds the signaling object and calls its
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
//! designator and the recipient-hosted inbox (a Host publication answering over
//! `currentSession`) are the room-introduction topology, deferred to the redeem
//! pass. Every signaling message here still crosses a real keyed session.
//!
//! Not part of the hermetic `zig build check`: it links the Rust sidecar
//! staticlib (`zig build webrtc-lib`, needs cargo), so it runs as the sibling
//! step `zig build webrtc-signaling-captp`.

const std = @import("std");
const glowcap = @import("glowcap");
const webrtc = @import("webrtc");
const webrtc_common = @import("webrtc_common");

/// A finite budget for the signaling session: its handshake, each answer
/// wait, and the host's wait for the recipient to dial. Unbounded would turn
/// a signaling peer that connects and then stalls into a hang rather than a
/// failure.
const signaling_budget_ms = 15_000;

const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const actors = glowcap.actors;
const driver = glowcap.driver;
const tcp = glowcap.net.tcp;
const ip = std.Io.net;

// The signaling inbox actor, the channel-bring-up client, and the SDP frame cap
// are the shared WebRTC signaling core (interop/webrtc_common.zig), driven the
// same way by any future Host-integrated WebRTC handoff.
const SignalingInbox = webrtc_common.SignalingInbox;
const bringUpViaCapTP = webrtc_common.bringUpViaCapTP;
const waitOpen = webrtc_common.waitOpen;
const signaling_frame_bytes = webrtc_common.signaling_frame_bytes;

/// The signaling session carries one bounded SDP or ICE string per frame.
const signaling_opts: driver.SessionOptions = .{
    .frame_cap = signaling_frame_bytes,
    .handshake = .{ .ms = signaling_budget_ms },
    .settle = .{ .ms = signaling_budget_ms },
};

const frame_cap: usize = 4096;
const greeting = "hello over webrtc signaling captp";

/// The published actor: answers `greet` with a static greeting.
const Greeter = struct {
    done: *std.atomic.Value(bool),

    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Delivery) !model.Argument {
        _ = turn;
        if (!std.mem.eql(u8, msg.verb, "greet")) return error.NoSuchMethod;
        self.done.store(true, .release);
        return .{ .string = greeting };
    }
};

/// The exporter half: host the signaling inbox over a keyed CapTP session until
/// the recipient's channel is up (it closes the signaling session), then serve a
/// Greeter behind the keyed handshake over the open DataChannel.
fn exporterHalf(
    server: *driver.Server,
    resident: *webrtc.Resident,
    peer: *webrtc.Peer,
    allocator: std.mem.Allocator,
    seed: [crypto.seed_bytes]u8,
) anyerror!void {
    // 1. Signaling over CapTP: accept the recipient and route offer/candidate/poll
    //    to the sidecar peer until the recipient closes the session.
    {
        if (!try server.waitAcceptable(signaling_budget_ms)) return error.WaitTimedOut;
        const sig = try server.accept();
        defer sig.deinit();
        _ = try sig.publish("signaling", SignalingInbox, .{ .peer = peer });
        try sig.serve();
    }

    // 2. The channel is up; hold the keyed OCapN session over the DataChannel.
    try waitOpen(resident, peer, 2000);

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

    // Publish before the handshake settles: the dialer's fetch can arrive in
    // the same pump round that opens the session.
    var served = std.atomic.Value(bool).init(false);
    _ = try host.publish("greeter", Greeter, .{ .done = &served });
    try webrtc_common.waitFor(resident, peer, &pump, &host, session, session, webrtc_common.sessionOpenDone, 10_000);
    try webrtc_common.serveUntil(resident, peer, &pump, &host, session, &served, webrtc_common.atomicFlagDone, 10_000);
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
    seed: [crypto.seed_bytes]u8,
    expect_designator: []const u8,
) anyerror!void {
    // 1. Signaling over CapTP: dial the exporter's inbox and drive the channel up.
    {
        var designator_buf: [tcp.designator_buf_len]u8 = undefined;
        const sig = try driver.connect(allocator, io, .{ .symbols = &.{.tcp} }, tcp.locatorFromAddress(&designator_buf, address), .ephemeral, signaling_opts);
        defer sig.deinit();
        const inbox = try sig.fetch("signaling");
        offerer.authorizeRemote(crypto.PeerKey.fromDesignator(expect_designator) orelse
            return error.InvalidDesignator);
        try bringUpViaCapTP(sig, inbox, resident, offerer, allocator);
    }

    // 2. The channel is up; hold the keyed OCapN session over the DataChannel.
    var host = try webrtc_common.hostFromSeed(allocator, seed, frame_cap);
    defer host.deinit();

    const designator = crypto.SecretKey.fromSeed(seed).publicKey().toDesignator();
    try host.setAdvertisedLocator(webrtc_common.locator(designator[0..]));
    const session = try host.openDialedLocator(webrtc_common.locator(expect_designator));
    try webrtc_common.bindAuthorizedChannel(&host, session, offerer);

    const read_buf = try allocator.alloc(u8, webrtc.max_packet_bytes);
    defer allocator.free(read_buf);
    var pump = webrtc_common.PacketPump{ .read_buf = read_buf };
    defer pump.deinit();

    try webrtc_common.waitFor(resident, offerer, &pump, &host, session, session, webrtc_common.sessionOpenDone, 10_000);
    const partner = try host.partnerIdentity(session);
    if (!std.mem.eql(u8, partner.designator, expect_designator)) return error.PartnerMismatch;

    const greeter = try webrtc_common.fetchRef(resident, offerer, &pump, &host, session, "greeter", 10_000);
    try webrtc_common.sendAndExpectString(resident, offerer, &pump, &host, session, greeter, .{
        .verb = "greet",
        .args = &.{.{ .string = "glowcap" }},
    }, greeting, 10_000);
    _ = try pump.drive(&host, session, offerer);
    offerer.close();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const exporter_seed = @as([crypto.seed_bytes]u8, @splat(0x63));
    const recipient_seed = @as([crypto.seed_bytes]u8, @splat(0x64));
    const exporter_secret = crypto.SecretKey.fromSeed(exporter_seed);
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

    // The signaling capability listens on cleartext TCP loopback (the
    // signaling proof, not the product path); the recipient dials it.
    const server = try driver.listen(allocator, io, .{ .symbols = &.{.tcp} }, model.transport.tcp, .{ .designator = "127.0.0.1:0" }, .ephemeral, signaling_opts);
    defer server.deinit();
    var address_buf: [tcp.designator_buf_len]u8 = undefined;
    const address = try tcp.parseDesignator(try server.localDesignator(&address_buf));

    var exporter_future = try io.concurrent(exporterHalf, .{ server, &answerer_resident, &answerer, allocator, exporter_seed });
    const recipient_result = recipientHalf(address, io, &offerer_resident, &offerer, allocator, recipient_seed, exporter_designator[0..]);
    const exporter_result = exporter_future.await(io);
    try recipient_result;
    try exporter_result;

    std.debug.print("webrtc-signaling-captp: the signaling capability, over CapTP, brought up a DataChannel and a keyed OCapN session round-tripped over it\n", .{});
}
