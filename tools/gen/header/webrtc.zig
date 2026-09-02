//! Generates `include/glowcap_net_transport_webrtc.h` from the Zig
//! `c_abi_net_transport_webrtc` source.
//!
//! The public WebRTC transport C ABI is a separate archive from
//! `libglowcap_ocapn` (ADR-0089, ADR-0059), so it gets its own header. As with
//! `tools/gen/header/iroh.zig`, the function signatures are *reflected* from the
//! real `src/c_abi/net_transport/webrtc/mod.zig` exports, so the header cannot
//! disagree with the implementation, and the prose lives here.
//! `zig build gen-header-net-transport-webrtc-check` is the staleness gate;
//! `zig build gen-header-net-transport-webrtc` is the fixer. Both run cargo-free:
//! the generator reflects types only and links the sidecar stubs
//! (`tools/gen/stub/webrtc_sidecar.zig`).
//!
//! The shared frame/peer/context vocabulary is declared in `glowcap_ocapn.h`,
//! which this header includes; only the WebRTC handles, readiness record, event
//! constants, and `glowcap_webrtc_*` prototypes are new here.

const std = @import("std");
const c = @import("c_abi_net_transport_webrtc");
const header_emit = @import("header_emit.zig");

// Force sidecar stubs so reflection-only gen links cargo-free.
comptime {
    _ = @import("webrtc_sidecar_stub");
}

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/glowcap_net_transport_webrtc.h", .generate = generate },
};
pub const step_name = "gen-header-net-transport-webrtc";

// Every prototype the header emits, in order. `emitFn` refuses a name missing
// here; the comptime guard below holds the table against the real
// `c_abi_net_transport_webrtc` declarations in both directions, so a new
// `pub export fn glowcap_webrtc_*` cannot silently miss the header while the
// gate stays green.
const emitted_fn_names = [_][]const u8{
    "glowcap_webrtc_archive_fingerprint",
    "glowcap_webrtc_netlayer_new",
    "glowcap_webrtc_netlayer_new_in",
    "glowcap_webrtc_netlayer_readiness_fd",
    "glowcap_webrtc_netlayer_drain_ready",
    "glowcap_webrtc_netlayer_release",
    "glowcap_webrtc_peer_new",
    "glowcap_webrtc_peer_new_in",
    "glowcap_webrtc_peer_authorize_remote",
    "glowcap_webrtc_peer_create_offer",
    "glowcap_webrtc_peer_create_answer",
    "glowcap_webrtc_peer_set_remote_offer",
    "glowcap_webrtc_peer_set_remote_answer",
    "glowcap_webrtc_peer_add_remote_candidate",
    "glowcap_webrtc_peer_next_local_candidate",
    "glowcap_webrtc_peer_id",
    "glowcap_webrtc_peer_is_open",
    "glowcap_webrtc_peer_try_receive_packet",
    "glowcap_webrtc_peer_try_send_packet",
    "glowcap_webrtc_peer_close",
    "glowcap_webrtc_peer_release",
    "glowcap_webrtc_transport_provider",
    "glowcap_webrtc_last_error",
    "glowcap_webrtc_clear_last_error",
};

const Spec = struct {
    pub const c = @import("c_abi_net_transport_webrtc");
    pub const emitted_fns: []const []const u8 = &emitted_fn_names;
};
const E = header_emit.Emit(Spec);
const Buf = header_emit.Buf;
const emitDoc = header_emit.emitDoc;
const emitFn = E.emitFn;

// Coverage guard, both directions: every `pub export fn glowcap_webrtc_*` in
// `c_abi_net_transport_webrtc` must be listed, and every listed name must be real.
comptime {
    E.guardFns("c_abi_net_transport_webrtc", "glowcap_webrtc_");
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
        \\   (libglowcap_net_transport_webrtc) that links the Rust webrtc sidecar
        \\   (ADR-0089). It is a companion, not a superset: it exports only the
        \\   glowcap_webrtc_* family and shares no core symbol with libglowcap_ocapn,
        \\   so a consumer links BOTH archives and includes BOTH headers. The
        \\   shared frame, peer, and context vocabulary lives in glowcap_ocapn.h
        \\   (included below) and the archives agree on its layout; the WebRTC
        \\   handles and readiness vocabulary are declared here. The webrtc
        \\   family has its own last-error slot, read
        \\   through glowcap_webrtc_last_error rather than glowcap_ocapn's
        \\   glowcap_last_error. */
        \\#ifndef GLOWCAP_NET_TRANSPORT_WEBRTC_H
        \\#define GLOWCAP_NET_TRANSPORT_WEBRTC_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "glowcap_ocapn.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    try emitDoc(&b, gpa,
        \\Orientation: the WebRTC transport is a peer-to-peer DataChannel that
        \\carries one bare OCapN codec frame per DataChannel message, at least
        \\one end of which is usually a browser. Unlike iroh, a peer has no dialable address, so
        \\there is no connect(addr). The channel comes up through an out-of-band
        \\signaling exchange you drive:
        \\
        \\  1. Create one GlowcapWebrtcNetlayer per host, register its
        \\     glowcap_webrtc_netlayer_readiness_fd once, then create peers from
        \\     it with glowcap_webrtc_peer_new: one offerer and one answerer.
        \\  2. The offerer produces an SDP offer with glowcap_webrtc_peer_create_offer;
        \\     carry it to the answerer, which sets it with
        \\     glowcap_webrtc_peer_set_remote_offer and produces an SDP answer with
        \\     glowcap_webrtc_peer_create_answer; carry that back to the offerer's
        \\     glowcap_webrtc_peer_set_remote_answer.
        \\  3. Trickle ICE candidates both ways: drain each side's
        \\     glowcap_webrtc_peer_next_local_candidate (GLOWCAP_ERR_WOULD_BLOCK when
        \\     none is pending) and hand each to the other side's
        \\     glowcap_webrtc_peer_add_remote_candidate. The readiness fd reports
        \\     CANDIDATE while more are ready and OPEN when the channel opens.
        \\
        \\When the fd wakes, call glowcap_webrtc_netlayer_drain_ready and route its
        \\stable peer-id records. Drain local candidates on CANDIDATE, check channel
        \\state on OPEN, use glowcap_webrtc_peer_try_receive_packet /
        \\_try_send_packet for whole DataChannel packets on READABLE / WRITABLE,
        \\and stop on CLOSED. On loopback and on a LAN the peers reach each other
        \\on host candidates alone, with no STUN or TURN.
        \\
        \\Threading: a netlayer and its peers are single-owner. Signaling submissions
        \\complete synchronously and may wait on the sidecar runtime, so perform them
        \\outside a reactor turn. Once submitted, channel progress, candidates, byte
        \\I/O, and closure are readiness-driven and do not park the reactor. Release
        \\every peer before glowcap_webrtc_netlayer_release.
    );

    try b.appendSlice(gpa,
        \\
        \\/* One WebRTC runtime/readiness endpoint shared by its peers. */
        \\typedef struct GlowcapWebrtcNetlayer GlowcapWebrtcNetlayer;
        \\/* One WebRTC peer: its RTCPeerConnection and single reliable, ordered
        \\   data channel. Created by glowcap_webrtc_peer_new; released by
        \\   glowcap_webrtc_peer_release. */
        \\typedef struct GlowcapWebrtcPeer GlowcapWebrtcPeer;
        \\
        \\
    );

    try b.print(gpa, "#define GLOWCAP_WEBRTC_EV_OPEN {d}u\n", .{c.GLOWCAP_WEBRTC_EV_OPEN});
    try b.print(gpa, "#define GLOWCAP_WEBRTC_EV_CANDIDATE {d}u\n", .{c.GLOWCAP_WEBRTC_EV_CANDIDATE});
    try b.print(gpa, "#define GLOWCAP_WEBRTC_EV_READABLE {d}u\n", .{c.GLOWCAP_WEBRTC_EV_READABLE});
    try b.print(gpa, "#define GLOWCAP_WEBRTC_EV_WRITABLE {d}u\n", .{c.GLOWCAP_WEBRTC_EV_WRITABLE});
    try b.print(gpa, "#define GLOWCAP_WEBRTC_EV_CLOSED {d}u\n", .{c.GLOWCAP_WEBRTC_EV_CLOSED});
    try b.print(gpa, "#define GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES {d}u\n", .{c.GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES});
    try b.print(gpa, "#define GLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES {d}u\n", .{c.GLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES});
    try b.print(gpa, "#define GLOWCAP_WEBRTC_MAX_ICE_SERVERS {d}u\n", .{c.GLOWCAP_WEBRTC_MAX_ICE_SERVERS});
    try b.print(gpa, "#define GLOWCAP_WEBRTC_MAX_ICE_URLS_PER_SERVER {d}u\n", .{c.GLOWCAP_WEBRTC_MAX_ICE_URLS_PER_SERVER});
    try b.print(gpa, "#define GLOWCAP_WEBRTC_MAX_ICE_URL_BYTES {d}u\n", .{c.GLOWCAP_WEBRTC_MAX_ICE_URL_BYTES});
    try b.print(gpa, "#define GLOWCAP_WEBRTC_MAX_ICE_CREDENTIAL_BYTES {d}u\n", .{c.GLOWCAP_WEBRTC_MAX_ICE_CREDENTIAL_BYTES});
    try b.print(gpa, "#define GLOWCAP_WEBRTC_MAX_PENDING_ICE_CANDIDATES {d}u\n", .{c.GLOWCAP_WEBRTC_MAX_PENDING_ICE_CANDIDATES});
    try b.print(gpa, "#define GLOWCAP_WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES {d}u\n", .{c.GLOWCAP_WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES});
    try b.print(gpa, "#define GLOWCAP_WEBRTC_DATA_CHANNEL_QUEUE_BYTES {d}u\n", .{c.GLOWCAP_WEBRTC_DATA_CHANNEL_QUEUE_BYTES});
    try b.appendSlice(gpa,
        \\/* One readiness record from glowcap_webrtc_netlayer_drain_ready. subject
        \\   is the stable identity returned by glowcap_webrtc_peer_id. */
        \\typedef struct GlowcapWebrtcReadyEvent {
        \\  uintptr_t subject;
        \\  uint32_t events;
        \\} GlowcapWebrtcReadyEvent;
        \\
        \\/* Borrowed UTF-8 text in WebRTC configuration records. A zero length may use
        \\   NULL. */
        \\typedef struct GlowcapWebrtcStringView {
        \\  const uint8_t *ptr;
        \\  size_t len;
        \\} GlowcapWebrtcStringView;
        \\
        \\/* One STUN or TURN record. urls points to url_count borrowed URL views.
        \\   username and credential are empty for ordinary STUN and set together for
        \\   credentialed TURN. */
        \\typedef struct GlowcapWebrtcIceServer {
        \\  const GlowcapWebrtcStringView *urls;
        \\  size_t url_count;
        \\  GlowcapWebrtcStringView username;
        \\  GlowcapWebrtcStringView credential;
        \\} GlowcapWebrtcIceServer;
        \\
        \\/* One WebRTC endpoint's configuration. Zero-initialize before filling fields.
        \\   ice_servers is a borrowed array of STUN/TURN records; NULL or empty gathers
        \\   host candidates only. Each record has 1-GLOWCAP_WEBRTC_MAX_ICE_URLS_PER_SERVER
        \\   non-empty UTF-8 stun:, stuns:, turn:, or turns: URLs, and a config has at
        \\   most GLOWCAP_WEBRTC_MAX_ICE_SERVERS records. TURN records require both
        \\   username and credential; STUN-only records must leave them empty. Provider
        \\   tokens, expiry, and refresh policy stay outside this ABI.
        \\   include_loopback_candidates offers loopback candidates for same-host tests.
        \\   worker_threads sizes this endpoint's runtime; 0 selects glowcap's default.
        \\   Establishment deadlines belong to the caller that drives signaling. */
        \\typedef struct GlowcapWebrtcConfig {
        \\  const GlowcapWebrtcIceServer *ice_servers;
        \\  size_t ice_server_count;
        \\  uint32_t include_loopback_candidates;
        \\  uint32_t worker_threads;
        \\} GlowcapWebrtcConfig;
        \\
    );

    try emitFn(&b, gpa, "glowcap_webrtc_archive_fingerprint", &.{}, "Return the exact callable-surface fingerprint. Compare it with the binding-generated GLOWCAP_WEBRTC_ARCHIVE_FINGERPRINT before any other call.");
    try emitFn(&b, gpa, "glowcap_webrtc_netlayer_new", &.{ "config", "out_netlayer" }, "Create the shared WebRTC runtime/readiness endpoint. Release it after every peer\ncreated from it has been released. config carries the endpoint's settings; a\nNULL one is GLOWCAP_ERR_NULL_POINTER.");
    try emitFn(&b, gpa, "glowcap_webrtc_netlayer_new_in", &.{ "context", "config", "out_netlayer" }, "As glowcap_webrtc_netlayer_new, allocating through context.");
    try emitFn(&b, gpa, "glowcap_webrtc_netlayer_readiness_fd", &.{"netlayer"}, "Borrow the netlayer's single read-only OS readiness fd. Register it once; do not\nclose it. When it wakes, call glowcap_webrtc_netlayer_drain_ready.");
    try emitFn(&b, gpa, "glowcap_webrtc_netlayer_drain_ready", &.{ "netlayer", "out_events", "out_cap", "out_count" }, "Drain pending stable peer-id events without blocking. Call after the readiness fd\nwakes, then drive CANDIDATE/OPEN/READABLE/WRITABLE/CLOSED for each subject.");
    try emitFn(&b, gpa, "glowcap_webrtc_netlayer_release", &.{"netlayer"}, "Release the endpoint after every peer created from it is released. NULL is a no-op.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_new", &.{ "netlayer", "is_offerer", "out_peer" }, "Create a peer from netlayer in one of the two signaling roles into out_peer.\nis_offerer nonzero creates the offerer; zero creates the answerer. Release with\nglowcap_webrtc_peer_release before releasing netlayer.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_new_in", &.{ "context", "netlayer", "is_offerer", "out_peer" }, "As glowcap_webrtc_peer_new, allocating the peer shell through context.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_create_offer", &.{ "peer", "out", "cap", "out_len" }, "Produce the offerer's SDP offer into out (cap bytes), writing the SDP length to\nout_len and setting it as the local description. GLOWCAP_ERR_BUFFER_TOO_SMALL\nstill writes the required length to out_len, so retry with a buffer that size.\nGLOWCAP_ERR_INVALID_ARGUMENT means the generated SDP exceeds\nGLOWCAP_WEBRTC_MAX_SIGNAL_BYTES and no larger buffer can make it valid.\nOfferer only.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_authorize_remote", &.{ "peer", "designator", "designator_len" }, "Bind the durable key authorized by the signaling authority before the channel\nopens. designator is the borrowed canonical lowercase-hex durable key;\nGLOWCAP_ERR_INVALID_ARGUMENT leaves the peer unchanged.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_create_answer", &.{ "peer", "out", "cap", "out_len" }, "Produce the answerer's SDP answer into out (cap bytes), writing the SDP length\nto out_len and setting it as the local description. Answerer only, after\nglowcap_webrtc_peer_set_remote_offer. GLOWCAP_ERR_BUFFER_TOO_SMALL still writes\nthe required length. GLOWCAP_ERR_INVALID_ARGUMENT means the generated SDP\nexceeds GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES and no larger buffer can make it valid.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_set_remote_offer", &.{ "peer", "sdp", "sdp_len" }, "Set the far offerer's SDP offer (sdp/sdp_len, borrowed UTF-8) as the remote\ndescription. Answerer side. GLOWCAP_ERR_INVALID_ARGUMENT means the description\nexceeds GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES and the sidecar state is unchanged.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_set_remote_answer", &.{ "peer", "sdp", "sdp_len" }, "Set the far answerer's SDP answer (sdp/sdp_len, borrowed UTF-8) as the remote\ndescription. Offerer side. GLOWCAP_ERR_INVALID_ARGUMENT means the description\nexceeds GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES and the sidecar state is unchanged.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_add_remote_candidate", &.{ "peer", "cand", "cand_len" }, "Add one remote ICE candidate (cand/cand_len, the borrowed JSON the far peer's\nglowcap_webrtc_peer_next_local_candidate produced). GLOWCAP_ERR_INVALID_ARGUMENT\nmeans the candidate exceeds GLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES and the sidecar\nstate is unchanged.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_next_local_candidate", &.{ "peer", "out", "cap", "out_len" }, "Drain the next locally gathered ICE candidate into out (cap bytes) as JSON,\nwriting its length to out_len; carry it to the far peer's\nglowcap_webrtc_peer_add_remote_candidate. GLOWCAP_ERR_WOULD_BLOCK when none is\npending yet; GLOWCAP_ERR_BUFFER_TOO_SMALL still writes the required length.\nGLOWCAP_ERR_INVALID_ARGUMENT means the local candidate exceeds\nGLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES and no larger buffer can make it valid.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_id", &.{"peer"}, "Return the peer's stable, nonzero readiness identity, or zero for NULL.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_is_open", &.{"peer"}, "Check channel establishment without blocking: GLOWCAP_OK once open,\nGLOWCAP_ERR_WOULD_BLOCK while pending, GLOWCAP_ERR_CLOSED after clean close,\nor GLOWCAP_ERR_IO when setup faulted.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_try_receive_packet", &.{ "peer", "buf", "len", "out_read" }, "Non-blocking receive of one inbound packet: GLOWCAP_OK with the packet length\nin out_read, GLOWCAP_ERR_BUFFER_TOO_SMALL with the packet still queued,\nGLOWCAP_ERR_WOULD_BLOCK until READABLE, GLOWCAP_ERR_CLOSED at clean EOF, or\nGLOWCAP_ERR_IO on fault.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_try_send_packet", &.{ "peer", "buf", "len", "out_written" }, "Copy one whole packet into the bounded send queue and return immediately.\nout_written is len on success. On GLOWCAP_ERR_WOULD_BLOCK retry the same packet\nafter WRITABLE; GLOWCAP_ERR_BUFFER_TOO_SMALL means the packet exceeds this\ntransport's packet cap.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_close", &.{"peer"}, "Close the channel without releasing the handle and report CLOSED readiness.\nIdempotent; glowcap_webrtc_peer_release is still required afterward.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_release", &.{"peer"}, "Release the peer and close its channel. If this consumes the endpoint's final\nlease, its teardown outcome is returned here. NULL is a no-op.");
    try emitFn(&b, gpa, "glowcap_webrtc_transport_provider", &.{ "netlayer", "out_provider" }, "Fill the generic multiplexed provider package. Signaling establishes peers; the driver claims authorized open peers by stable subject.");

    try emitFn(&b, gpa, "glowcap_webrtc_last_error", &.{ "out_buf", "cap" }, "Copy the calling thread's last webrtc-transport error into out_buf, the webrtc\nsibling of glowcap_last_error, reading libglowcap_net_transport_webrtc's own\nper-thread slot. A glowcap_webrtc_* call that returns GLOWCAP_ERR_IO records its\nconcrete cause here. Copies at most cap-1 bytes and NUL-terminates when cap>0;\nout_buf NULL or cap 0 queries the length. Returns the full message length, or 0\nwhen none is set." ++ header_emit.last_error_freshness_doc);
    try emitFn(&b, gpa, "glowcap_webrtc_clear_last_error", &.{}, "Clear the calling thread's webrtc-transport last-error slot.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* GLOWCAP_NET_TRANSPORT_WEBRTC_H */
        \\
    );

    try E.assertAllEmitted(&b, "gen-header-net-transport-webrtc");
    return b.toOwnedSlice(gpa);
}
