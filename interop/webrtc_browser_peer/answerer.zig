//! The native answerer for the WebRTC browser-peer proof (ADR-0089, phase 6).
//!
//! A real headless Chromium is the offerer (`@pancake/webrtc`'s `RtcPeer` over
//! `RTCPeerConnection`, driving a keyed session inside the wasm Host); this
//! process is the answerer over the native sidecar (`pancake_webrtc_sidecar_*`),
//! serving a Greeter behind the keyed handshake. The harness ferries the
//! signaling between the two out of band over this process's stdio, one JSON
//! object per line, the phase-1 datachannel probe's wire:
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
//! native peers; here the far peer is a browser. A concurrent reader applies the
//! browser's offer and candidates while this thread produces the answer, drains
//! its own candidates, and then serves; only this thread writes stdout. The
//! answerer signs a fixed key so the harness hands the browser its designator to
//! pin.
//!
//! Links the Rust sidecar (`zig build webrtc-lib`, needs cargo), so it is built
//! and run only by the `webrtc-browser-peer` harness, never a hermetic gate.

const std = @import("std");
const pancake = @import("pancake");
const webrtc = @import("webrtc");

const crypto = pancake.foundation.crypto;
const model = pancake.ocapn.model;
const engine = pancake.ocapn.engine;
const actors = pancake.actors;
const driver = pancake.driver;

const frame_cap: usize = 4096;
const greeting = "hello over webrtc";

/// The answerer's fixed key: the harness derives its designator and hands it to
/// the browser to pin, so the keyed handshake proves identity end to end.
const answerer_seed = [_]u8{0x71} ** crypto.SEED_BYTES;

/// The published actor: answers `greet` with a static greeting.
const Greeter = struct {
    pub fn handle(self: *Greeter, turn: *actors.Turn, msg: actors.Message) !model.Argument {
        _ = self;
        _ = turn;
        _ = msg;
        return .{ .string = greeting };
    }
};

/// Whether the browser's offer has been set as the remote description. The
/// reader flips it after `setRemoteOffer`; the main thread then produces and
/// writes the answer, so the two never call the sidecar's description setters at
/// once and only the main thread writes stdout.
var offer_seen = std.atomic.Value(bool).init(false);

/// Append `s` as a JSON string literal (escaped) to `list`.
fn appendJsonString(list: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try list.append(gpa, '"');
    for (s) |c| switch (c) {
        '"' => try list.appendSlice(gpa, "\\\""),
        '\\' => try list.appendSlice(gpa, "\\\\"),
        '\n' => try list.appendSlice(gpa, "\\n"),
        '\r' => try list.appendSlice(gpa, "\\r"),
        '\t' => try list.appendSlice(gpa, "\\t"),
        else => if (c < 0x20) {
            var buf: [8]u8 = undefined;
            try list.appendSlice(gpa, std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch "");
        } else try list.append(gpa, c),
    };
    try list.append(gpa, '"');
}

fn writeLine(io: std.Io, bytes: []const u8) void {
    const stdout = std.Io.File.stdout();
    stdout.writeStreamingAll(io, bytes) catch return;
    stdout.writeStreamingAll(io, "\n") catch return;
}

/// Emit `{"type":"answer","sdp":<sdp>}` with `sdp` JSON-escaped.
fn writeAnswer(io: std.Io, gpa: std.mem.Allocator, sdp: []const u8) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    buf.appendSlice(gpa, "{\"type\":\"answer\",\"sdp\":") catch return;
    appendJsonString(&buf, gpa, sdp) catch return;
    buf.appendSlice(gpa, "}") catch return;
    writeLine(io, buf.items);
}

/// Emit `{"type":"candidate","candidate":<json>}`; `candidate_json` is the
/// sidecar's already-serialized `RTCIceCandidateInit`, embedded verbatim.
fn writeCandidate(io: std.Io, gpa: std.mem.Allocator, candidate_json: []const u8) void {
    const line = std.fmt.allocPrint(gpa, "{{\"type\":\"candidate\",\"candidate\":{s}}}", .{candidate_json}) catch return;
    defer gpa.free(line);
    writeLine(io, line);
}

/// Read signaling from stdin until end of input: set the browser's offer as the
/// remote description (flipping `offer_seen`) and add each trickled candidate.
/// Never writes stdout.
fn readSignaling(peer: *webrtc.Peer, io: std.Io, gpa: std.mem.Allocator) void {
    var buf: [1 << 16]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &buf);
    while (true) {
        const raw = reader.interface.takeDelimiterInclusive('\n') catch return;
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) continue;
        applyLine(peer, gpa, line);
    }
}

fn applyLine(peer: *webrtc.Peer, gpa: std.mem.Allocator, line: []const u8) void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch return;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const kind = switch (obj.get("type") orelse return) {
        .string => |s| s,
        else => return,
    };
    if (std.mem.eql(u8, kind, "offer")) {
        const sdp = switch (obj.get("sdp") orelse return) {
            .string => |s| s,
            else => return,
        };
        peer.setRemoteOffer(sdp) catch return;
        offer_seen.store(true, .release);
    } else if (std.mem.eql(u8, kind, "candidate")) {
        // The candidate value is the last key: take the `{...}` substring after
        // `"candidate":`, dropping the outer object's closing brace, so it goes
        // to the sidecar verbatim without a JSON round-trip.
        const marker = "\"candidate\":";
        const at = std.mem.indexOf(u8, line, marker) orelse return;
        var cand = std.mem.trim(u8, line[at + marker.len ..], " \t");
        if (cand.len == 0 or cand[cand.len - 1] != '}') return;
        cand = cand[0 .. cand.len - 1];
        peer.addRemoteCandidate(cand) catch return;
    }
}

/// Emit `{"type":"identity","designator":<hex>}` so the harness hands the
/// browser the key to pin for the keyed dial.
fn writeIdentity(io: std.Io, gpa: std.mem.Allocator, designator: []const u8) void {
    const line = std.fmt.allocPrint(gpa, "{{\"type\":\"identity\",\"designator\":\"{s}\"}}", .{designator}) catch return;
    defer gpa.free(line);
    writeLine(io, line);
}

/// Serve a Greeter behind the keyed handshake over the open channel, signing
/// with `secret` so the browser's pinned designator verifies.
fn serveKeyed(io: std.Io, peer: *webrtc.Peer, allocator: std.mem.Allocator, secret: crypto.SecretKey) !void {
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
    const secret = crypto.SecretKey.fromSeed(answerer_seed);
    const designator = secret.publicKey().toDesignator();
    writeIdentity(io, allocator, designator[0..]);

    // The signaling reader runs concurrently: it applies the browser's offer and
    // candidates while this thread produces the answer, drains local candidates,
    // and waits for the channel to open.
    var reader_future = try io.concurrent(readSignaling, .{ &peer, io, allocator });

    var answered = false;
    var cand_buf: [4 * 1024]u8 = undefined;
    var sdp_buf: [16 * 1024]u8 = undefined;
    var len: usize = 0;
    var rounds: usize = 0;
    var opened = false;
    while (rounds < 600) : (rounds += 1) {
        var events: [16]webrtc.ReadyEvent = undefined;
        const count = try resident.pollReady(&events, 50);
        for (events[0..count]) |event| {
            if (event.subject != @intFromEnum(peer.id())) return error.UnexpectedReadySubject;
        }
        if (!answered and offer_seen.load(.acquire)) {
            var alen: usize = 0;
            if (peer.createAnswer(&sdp_buf, &alen)) |answer| {
                writeAnswer(io, allocator, answer);
                answered = true;
            } else |_| {}
        }
        while (try peer.nextLocalCandidate(&cand_buf, &len)) |candidate| {
            writeCandidate(io, allocator, candidate);
        }
        peer.checkOpen() catch |err| switch (err) {
            error.WouldBlock => continue,
            error.Closed => return error.ChannelClosed,
        };
        opened = true;
        break;
    }
    if (!opened) return error.ChannelBringUpTimeout;

    try serveKeyed(io, &peer, allocator, secret);
    // The browser has left; unblock the reader's stdin wait and collect it.
    std.Io.File.stdin().close(io);
    reader_future.await(io);
}
