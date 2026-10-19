//! The Zig answerer for the WebRTC browser-peer proof (ADR-0035).
//!
//! A real headless Chromium is the offerer (`@glowcap/webrtc`'s `RtcPeer` over
//! `RTCPeerConnection`, driving a keyed session inside the wasm Host). This
//! process is the answerer over the Zig sidecar (`glowcap_webrtc_sidecar_*`),
//! serving a Greeter behind the keyed handshake. The harness ferries the
//! signaling between the two out of band over this process's stdio, one JSON
//! object per line (`webrtc_common/stdio.zig`):
//!
//!   out  {"type":"identity","designator":"…"} this peer's key designator (first)
//!   in   {"type":"offer","sdp":"…"}            the browser's SDP offer
//!   in   {"type":"candidate","candidate":{…}}  a trickled ICE candidate
//!   out  {"type":"answer","sdp":"…"}           this peer's SDP answer
//!   out  {"type":"candidate","candidate":{…}}  a trickled ICE candidate
//!
//! The identity line goes first: it carries the key the browser pins for the
//! keyed dial, so the handshake proves this peer's identity end to end.
//!
//! Once the DataChannel opens, the keyed handshake, bootstrap fetch, and
//! deliver/resolve run exactly as `webrtc-interop` proves them between two
//! Zig peers. Here the far peer is a browser. The answerer signs a fixed key so
//! the harness hands the browser its designator to pin.
//!
//! Links the Rust sidecar (`zig build webrtc-lib`, needs cargo), so it is built
//! and run only by the `webrtc-browser-peer` harness, never a hermetic gate.

const std = @import("std");
const glowcap = @import("glowcap");
const webrtc = @import("webrtc");
const webrtc_common = @import("webrtc_common");

const stdio = webrtc_common.stdio;
const crypto = glowcap.foundation.crypto;
const model = glowcap.ocapn.model;
const actors = glowcap.actors;

const frame_cap: usize = 4096;
const greeting = "hello over webrtc";

/// The answerer's fixed key: the harness derives its designator and hands it to
/// the browser to pin, so the keyed handshake proves identity end to end.
const answerer_seed = @as([crypto.seed_bytes]u8, @splat(0x71));

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

/// Serve a Greeter behind the keyed handshake over the open channel, signing
/// with `secret` so the browser's pinned designator verifies.
fn serveKeyed(resident: *webrtc.Resident, peer: *webrtc.Peer, allocator: std.mem.Allocator, seed: [crypto.seed_bytes]u8) !void {
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var resident = try webrtc.Resident.init(.{ .include_loopback_candidates = true });
    defer resident.deinit() catch |err| std.log.err("WebRTC teardown failed: {s}", .{@errorName(err)});
    var peer = try resident.newPeer(false); // answerer
    defer peer.deinit();

    // Announce the key the browser pins before any SDP flows.
    const designator = crypto.SecretKey.fromSeed(answerer_seed).publicKey().toDesignator();
    var out_buf: [4096]u8 = undefined;
    var signaling = stdio.Signaling.init(io, .answerer, &peer, &out_buf);
    try signaling.writeIdentity(designator[0..]);

    // The reader applies the browser's offer and candidates while this thread
    // answers, trickles, and serves. Every exit stops the reader before the
    // peer it touches is freed, since cancelling interrupts its stdin read.
    var reader = try io.concurrent(stdio.Signaling.readInbound, .{ &signaling, io, allocator });
    defer reader.cancel(io);
    try signaling.openChannel(&resident, 600);
    try serveKeyed(&resident, &peer, allocator, answerer_seed);
    try signaling.check();
}
