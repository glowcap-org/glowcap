//! The Zig answerer for the WebRTC browser-peer proof (ADR-0035).
//!
//! A real headless Chromium is the offerer (`@glowcap/webrtc`'s `RtcPeer` over
//! `RTCPeerConnection`, driving a keyed session inside the wasm Host). This
//! process is the answerer over the Zig sidecar (`glowcap_webrtc_sidecar_*`),
//! serving a Greeter behind the keyed handshake. The harness ferries the
//! signaling between the two out of band over this process's stdio, one JSON
//! object per line (`test/support/transport/webrtc/stdio.zig`):
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
//! deliver/resolve run exactly as `webrtc-session` proves them between two
//! Zig peers. Here the far peer is a browser. The answerer signs a fixed key so
//! the harness hands the browser its designator to pin.
//!
//! Links the Rust sidecar (`zig build webrtc-sidecar-build`, needs cargo), so it is built
//! and run only by the `webrtc-browser-peer` harness, never a hermetic gate.

const std = @import("std");
const glowcap = @import("glowcap");
const webrtc = @import("webrtc");
const webrtc_harness = @import("webrtc_harness");

const stdio = webrtc_harness.stdio;
const crypto = glowcap.foundation.crypto;

const frame_cap: usize = 4096;
const greeting = "hello over webrtc";

/// The answerer's fixed key: the harness derives its designator and hands it to
/// the browser to pin, so the keyed handshake proves identity end to end.
const answerer_seed = @as([crypto.seed_bytes]u8, @splat(0x71));

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
    try webrtc_harness.serveGreeter(&resident, &peer, allocator, answerer_seed, frame_cap, greeting);
    try signaling.check();
}
