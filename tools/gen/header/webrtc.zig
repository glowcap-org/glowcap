//! Generates `include/pancake_net_transport_webrtc.h` from the Zig
//! `c_abi_net_transport_webrtc` source.
//!
//! The public WebRTC transport C ABI is a separate archive from
//! `libpancake_ocapn` (ADR-0089, ADR-0059), so it gets its own header. As with
//! `tools/gen/header/iroh.zig`, the function signatures are *reflected* from the
//! real `src/c_abi/net_transport/webrtc/mod.zig` exports, so the header cannot
//! disagree with the implementation, and the prose lives here.
//! `zig build gen-header-net-transport-webrtc-check` is the staleness gate;
//! `zig build gen-header-net-transport-webrtc` is the fixer. Both run cargo-free:
//! the generator reflects types only and links the sidecar stubs
//! (`tools/gen/stub/webrtc_sidecar.zig`).
//!
//! The shared frame/peer/context vocabulary is declared in `pancake_ocapn.h`,
//! which this header includes; only the `PancakeWebrtcPeer` handle and the
//! `pancake_webrtc_*` prototypes are new here.

const std = @import("std");
const c = @import("c_abi_net_transport_webrtc");
const header_emit = @import("header_emit.zig");

// Force sidecar stubs so reflection-only gen links cargo-free.
comptime {
    _ = @import("webrtc_sidecar_stub");
}

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/pancake_net_transport_webrtc.h", .generate = generate },
};
pub const step_name = "gen-header-net-transport-webrtc";

// Every prototype the header emits, in order. `emitFn` refuses a name missing
// here; the comptime guard below holds the table against the real
// `c_abi_net_transport_webrtc` declarations in both directions, so a new
// `pub export fn pancake_webrtc_*` cannot silently miss the header while the
// gate stays green.
const emitted_fn_names = [_][]const u8{
    "pancake_webrtc_peer_new",
    "pancake_webrtc_peer_new_in",
    "pancake_webrtc_peer_create_offer",
    "pancake_webrtc_peer_create_answer",
    "pancake_webrtc_peer_set_remote_offer",
    "pancake_webrtc_peer_set_remote_answer",
    "pancake_webrtc_peer_add_remote_candidate",
    "pancake_webrtc_peer_next_local_candidate",
    "pancake_webrtc_peer_wait_open",
    "pancake_webrtc_peer_read",
    "pancake_webrtc_peer_write",
    "pancake_webrtc_peer_close",
    "pancake_webrtc_peer_release",
    "pancake_webrtc_last_error",
    "pancake_webrtc_clear_last_error",
};

const Spec = struct {
    pub const c = @import("c_abi_net_transport_webrtc");
    pub const emitted_fns: []const []const u8 = &emitted_fn_names;
};
const E = header_emit.Emit(Spec);
const Buf = header_emit.Buf;
const emitDoc = header_emit.emitDoc;
const emitFn = E.emitFn;

// Coverage guard, both directions: every `pub export fn pancake_webrtc_*` in
// `c_abi_net_transport_webrtc` must be listed, and every listed name must be real.
comptime {
    E.guardFns("c_abi_net_transport_webrtc", "pancake_webrtc_");
}

/// Build the full header text. Caller owns the returned bytes.
fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/net_transport/webrtc/mod.zig by tools/gen/header/webrtc.zig.
        \\   Do not edit by hand: run `zig build gen-header-net-transport-webrtc`.
        \\   Function signatures are reflected from the Zig source, so this header
        \\   cannot drift from the implementation.
        \\
        \\   The WebRTC transport's public C ABI: a separate artifact
        \\   (libpancake_net_transport_webrtc) that links the Rust webrtc sidecar
        \\   (ADR-0089). It is a companion, not a superset: it exports only the
        \\   pancake_webrtc_* family and shares no core symbol with libpancake_ocapn,
        \\   so a consumer links BOTH archives and includes BOTH headers. The
        \\   shared frame, peer, and context vocabulary lives in pancake_ocapn.h
        \\   (included below) and the archives agree on its layout; only the
        \\   PancakeWebrtcPeer handle and the pancake_webrtc_* prototypes are
        \\   declared here. The webrtc family has its own last-error slot, read
        \\   through pancake_webrtc_last_error rather than pancake_ocapn's
        \\   pancake_last_error. */
        \\#ifndef PANCAKE_NET_TRANSPORT_WEBRTC_H
        \\#define PANCAKE_NET_TRANSPORT_WEBRTC_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "pancake_ocapn.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    try emitDoc(&b, gpa,
        \\Orientation: the WebRTC transport is a peer-to-peer DataChannel that
        \\carries one keyed OCapN session byte-for-byte, at least one end of which
        \\is usually a browser. Unlike iroh, a peer has no dialable address, so
        \\there is no connect(addr). The channel comes up through an out-of-band
        \\signaling exchange you drive:
        \\
        \\  1. Create both ends with pancake_webrtc_peer_new, one offerer (nonzero
        \\     is_offerer, which creates the data channel) and one answerer.
        \\  2. The offerer produces an SDP offer with pancake_webrtc_peer_create_offer;
        \\     carry it to the answerer, which sets it with
        \\     pancake_webrtc_peer_set_remote_offer and produces an SDP answer with
        \\     pancake_webrtc_peer_create_answer; carry that back to the offerer's
        \\     pancake_webrtc_peer_set_remote_answer.
        \\  3. Trickle ICE candidates both ways: drain each side's
        \\     pancake_webrtc_peer_next_local_candidate (PANCAKE_ERR_WOULD_BLOCK when
        \\     none is pending) and hand each to the other side's
        \\     pancake_webrtc_peer_add_remote_candidate, until
        \\     pancake_webrtc_peer_wait_open reports the channel open.
        \\
        \\Then pancake_webrtc_peer_read and pancake_webrtc_peer_write move raw
        \\session bytes, which you frame yourself (feed them to a PancakePeer's
        \\stream input and write its outbound frames back), the same shape the iroh
        \\and TCP consumers use. On loopback and on a LAN the two peers reach each
        \\other on host candidates alone, with no STUN or TURN.
        \\
        \\Threading: a peer is single-owner; serialize calls on one onto one thread.
        \\pancake_webrtc_peer_read blocks until bytes arrive or the channel closes,
        \\and pancake_webrtc_peer_wait_open blocks until the channel opens, so run
        \\both off your event loop. Release every peer with
        \\pancake_webrtc_peer_release.
    );

    try b.appendSlice(gpa,
        \\
        \\/* One WebRTC peer: its RTCPeerConnection and single reliable, ordered
        \\   data channel. Created by pancake_webrtc_peer_new; released by
        \\   pancake_webrtc_peer_release. */
        \\typedef struct PancakeWebrtcPeer PancakeWebrtcPeer;
        \\
        \\
    );

    try emitFn(&b, gpa, "pancake_webrtc_peer_new", &.{ "is_offerer", "out_peer" }, "Create a peer in one of the two signaling roles into out_peer: is_offerer\nnonzero makes the offerer (which creates the data channel and produces the SDP\noffer), zero the answerer (which receives the channel and produces the answer).\nPANCAKE_ERR_IO (see pancake_webrtc_last_error) if the sidecar cannot create the\npeer connection. Release with pancake_webrtc_peer_release.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_new_in", &.{ "context", "is_offerer", "out_peer" }, "As pancake_webrtc_peer_new, but the handle allocates through context's\nallocator instead of the library allocator. Released the same way, with\npancake_webrtc_peer_release.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_create_offer", &.{ "peer", "out", "cap", "out_len" }, "Produce the offerer's SDP offer into out (cap bytes), writing the SDP length to\nout_len and setting it as the local description. PANCAKE_ERR_BUFFER_TOO_SMALL\nstill writes the required length to out_len, so retry with a buffer that size.\nOfferer only.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_create_answer", &.{ "peer", "out", "cap", "out_len" }, "Produce the answerer's SDP answer into out (cap bytes), writing the SDP length\nto out_len and setting it as the local description. Answerer only, after\npancake_webrtc_peer_set_remote_offer. PANCAKE_ERR_BUFFER_TOO_SMALL still writes\nthe required length.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_set_remote_offer", &.{ "peer", "sdp", "sdp_len" }, "Set the far offerer's SDP offer (sdp/sdp_len, borrowed UTF-8) as the remote\ndescription. Answerer side.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_set_remote_answer", &.{ "peer", "sdp", "sdp_len" }, "Set the far answerer's SDP answer (sdp/sdp_len, borrowed UTF-8) as the remote\ndescription. Offerer side.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_add_remote_candidate", &.{ "peer", "cand", "cand_len" }, "Add one remote ICE candidate (cand/cand_len, the borrowed JSON the far peer's\npancake_webrtc_peer_next_local_candidate produced).");
    try emitFn(&b, gpa, "pancake_webrtc_peer_next_local_candidate", &.{ "peer", "out", "cap", "out_len" }, "Drain the next locally gathered ICE candidate into out (cap bytes) as JSON,\nwriting its length to out_len; carry it to the far peer's\npancake_webrtc_peer_add_remote_candidate. PANCAKE_ERR_WOULD_BLOCK when none is\npending yet; PANCAKE_ERR_BUFFER_TOO_SMALL still writes the required length.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_wait_open", &.{ "peer", "timeout_ms" }, "Block until the data channel opens, or timeout_ms elapses: PANCAKE_OK once open,\nPANCAKE_ERR_WOULD_BLOCK on timeout. Runs the ICE/DTLS/SCTP bring-up, so call it\noff your event loop while trickling candidates.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_read", &.{ "peer", "buf", "len", "out_read" }, "Blocking read of raw inbound session bytes into buf: PANCAKE_OK with the byte\ncount in out_read, PANCAKE_ERR_CLOSED on a clean end of stream, or\nPANCAKE_ERR_IO on a fault (out_read untouched on any non-OK return). Parks the\ncalling thread until bytes arrive, so run it off your event loop. You frame\nthese bytes yourself, feeding a PancakePeer's stream input.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_write", &.{ "peer", "buf", "len", "out_written" }, "Write len raw session bytes from buf: PANCAKE_OK with the count written (the\nwhole slice, all-or-nothing) in out_written, or PANCAKE_ERR_IO on a fault\n(out_written untouched on any non-OK return).");
    try emitFn(&b, gpa, "pancake_webrtc_peer_close", &.{"peer"}, "Close the channel and connection without releasing the handle, waking any parked\nreader with end of stream. Idempotent. The shutdown lever for a host whose read\nparks on another thread; the handle is still released with\npancake_webrtc_peer_release.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_release", &.{"peer"}, "Release the peer, closing its channel and shutting down its runtime. NULL is a\nno-op.");

    try emitFn(&b, gpa, "pancake_webrtc_last_error", &.{ "out_buf", "cap" }, "Copy the calling thread's last webrtc-transport error into out_buf, the webrtc\nsibling of pancake_last_error, reading libpancake_net_transport_webrtc's own\nper-thread slot. A pancake_webrtc_* call that returns PANCAKE_ERR_IO records its\nconcrete cause here. Copies at most cap-1 bytes and NUL-terminates when cap>0;\nout_buf NULL or cap 0 queries the length. Returns the full message length, or 0\nwhen none is set.");
    try emitFn(&b, gpa, "pancake_webrtc_clear_last_error", &.{}, "Clear the calling thread's webrtc-transport last-error slot.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* PANCAKE_NET_TRANSPORT_WEBRTC_H */
        \\
    );

    try E.assertAllEmitted(&b, "gen-header-net-transport-webrtc");
    return b.toOwnedSlice(gpa);
}
