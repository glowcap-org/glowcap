//! The Zig offerer the binding listen proofs accept (ADR-0035).
//!
//! The one argument is the listener's key designator. This process is the
//! offerer over the Zig sidecar: it dials that key with a keyed session over
//! the DataChannel, fetches the listener's `greeter`, calls `greet`, and
//! exits 0 once a string came back. The harness carries the signaling over
//! this process's stdio, one JSON object per line
//! (`test/support/transport/webrtc/stdio.zig`):
//!
//!   out  {"type":"identity","designator":"…"}  this peer's key designator (first)
//!   out  {"type":"offer","sdp":"…"}             this peer's SDP offer
//!   in   {"type":"answer","sdp":"…"}            the listener's SDP answer
//!   out  {"type":"candidate","candidate":{…}}   a trickled ICE candidate
//!   in   {"type":"candidate","candidate":{…}}   a trickled ICE candidate
//!
//! The identity line goes first: the listener hands it to its library with
//! the offer, so the accepted session names this peer. This peer pins the
//! listener's key the same way, so the handshake proves both identities.
//!
//! Links the Rust sidecar (`zig build webrtc-sidecar-build`, needs cargo), so it is built
//! and run only by the binding proofs, never a hermetic gate.

const std = @import("std");
const glowcap = @import("glowcap");
const webrtc = @import("webrtc");
const webrtc_harness = @import("webrtc_harness");

const stdio = webrtc_harness.stdio;
const crypto = glowcap.foundation.crypto;

const frame_cap: usize = 4096;

/// The offerer's fixed key, whose designator the identity line announces.
const offerer_seed = @as([crypto.seed_bytes]u8, @splat(0x73));

/// Dial the keyed session over the open channel, pinning the listener's key,
/// then fetch its greeter and call it.
fn dialKeyed(
    resident: *webrtc.Resident,
    peer: *webrtc.Peer,
    allocator: std.mem.Allocator,
    listener_designator: []const u8,
) !void {
    var host = try webrtc_harness.hostFromSeed(allocator, offerer_seed, frame_cap);
    defer host.deinit();

    const designator = crypto.SecretKey.fromSeed(offerer_seed).publicKey().toDesignator();
    try host.setAdvertisedLocator(webrtc_harness.locator(designator[0..]));
    const session = try host.openDialedLocator(webrtc_harness.locator(listener_designator));
    try webrtc_harness.bindAuthorizedChannel(&host, session, peer);

    const read_buf = try allocator.alloc(u8, webrtc.max_packet_bytes);
    defer allocator.free(read_buf);
    var pump = webrtc_harness.PacketPump{ .read_buf = read_buf };
    defer pump.deinit();

    try webrtc_harness.waitFor(resident, peer, &pump, &host, session, session, webrtc_harness.sessionOpenDone, 10_000);
    const partner = try host.partnerIdentity(session);
    if (!std.mem.eql(u8, partner.designator, listener_designator)) return error.PartnerMismatch;

    const greeter = try webrtc_harness.fetchRef(resident, peer, &pump, &host, session, "greeter", 10_000);
    var captured = webrtc_harness.CapturedString{};
    const vow = try host.send(session, greeter, .{ .verb = "greet", .args = &.{} });
    try host.vowOn(vow, .{ .ctx = &captured, .func = webrtc_harness.CapturedString.record });
    try webrtc_harness.waitFor(resident, peer, &pump, &host, session, &captured, webrtc_harness.stringDone, 10_000);
    if ((try captured.require()).len == 0) return error.EmptyGreeting;
    _ = try pump.drive(&host, session, peer);
    peer.close();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const listener_designator = args.next() orelse return error.MissingListenerDesignator;
    const listener_key = crypto.PeerKey.fromDesignator(listener_designator) orelse return error.ListenerDesignatorNamesNoKey;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try webrtc.Resident.init(.{ .include_loopback_candidates = true });
    defer resident.deinit() catch |err| std.log.err("WebRTC teardown failed: {s}", .{@errorName(err)});
    var peer = try resident.newPeer(true); // offerer
    defer peer.deinit();
    peer.authorizeRemote(listener_key);

    // Announce the key the listener names this peer by before any SDP flows.
    const designator = crypto.SecretKey.fromSeed(offerer_seed).publicKey().toDesignator();
    var out_buf: [4096]u8 = undefined;
    var signaling = stdio.Signaling.init(io, .offerer, &peer, &out_buf);
    try signaling.writeIdentity(designator[0..]);

    // The reader applies the listener's answer and candidates while this
    // thread offers, trickles, and dials. Every exit stops the reader before
    // the peer it touches is freed, since cancelling interrupts its stdin read.
    var reader = try io.concurrent(stdio.Signaling.readInbound, .{ &signaling, io, allocator });
    defer reader.cancel(io);
    try signaling.openChannel(&resident, 600);
    try dialKeyed(&resident, &peer, allocator, listener_designator);
    try signaling.check();
}
