//! Generates `include/glowcap_net_transport_webrtc.h` from the Zig
//! `c_abi_net_transport_webrtc` source.
//!
//! The public WebRTC transport C ABI is a separate archive from
//! `libglowcap_ocapn` (ADR-0035, ADR-0022), so it gets its own header. As with
//! `tools/gen/header/iroh.zig`, the function signatures are *reflected* from the
//! real `src/c_abi/net_transport/webrtc/mod.zig` exports, so the header cannot
//! disagree with the implementation, and the prose lives here.
//! `zig build gen-header-net-transport-webrtc-check` is the staleness gate,
//! `zig build gen-header-net-transport-webrtc` is the fixer. Both run cargo-free:
//! the generator reflects types only and links the sidecar stubs
//! (`tools/gen/stub/webrtc_sidecar.zig`).
//!
//! The shared frame/peer/context vocabulary is declared in `glowcap_ocapn.h`,
//! which this header includes. Only the WebRTC handles, readiness record, event
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
    "glowcap_webrtc_netlayer_provide_offer",
    "glowcap_webrtc_netlayer_provide_answer",
    "glowcap_webrtc_netlayer_provide_candidate",
    "glowcap_webrtc_netlayer_fail_exchange",
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
        \\   (libglowcap_net_transport_webrtc) that links a Rust WebRTC library
        \\   (ADR-0035). It is a companion, not a superset: it exports only the
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
        \\signaling exchange, carried by something you already hold, such as an
        \\OCapN capability both peers can reach.
        \\
        \\The usual way is to let the netlayer run that exchange. Fill
        \\GlowcapWebrtcConfig.signaling with callbacks that carry an offer, an
        \\answer, and each local candidate to the peer an exchange names, install
        \\glowcap_webrtc_transport_provider in a driver loop, and dial a webrtc
        \\locator with glowcap_driver_dial or listen with glowcap_driver_listen.
        \\For a dial, hand the far peer's answer and candidates back with
        \\glowcap_webrtc_netlayer_provide_answer and
        \\glowcap_webrtc_netlayer_provide_candidate, or give the dial up with
        \\glowcap_webrtc_netlayer_fail_exchange when your signaling fails. For
        \\the listener, hand each inbound offer in with
        \\glowcap_webrtc_netlayer_provide_offer and the offerer's candidates with
        \\glowcap_webrtc_netlayer_provide_candidate. Every one of these calls
        \\belongs on the thread that steps the driver. The driver reports the
        \\session as it does for any transport, with the far peer's designator as
        \\its authenticated identity.
        \\
        \\To drive the exchange yourself instead:
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
        \\and stop on CLOSED. Or, once OPEN, give the peer to a driver loop with
        \\glowcap_driver_adopt_external and let it carry the session. On loopback
        \\and on a LAN the peers reach each other on host candidates alone, with
        \\no STUN or TURN.
        \\
        \\Threading: a netlayer and its peers are single-owner. Signaling submissions
        \\complete synchronously and may wait on the WebRTC library's runtime, so perform them
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
    try b.print(gpa, "#define GLOWCAP_WEBRTC_MAX_ACCEPTS_IN_FLIGHT {d}u\n", .{c.GLOWCAP_WEBRTC_MAX_ACCEPTS_IN_FLIGHT});
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
        \\/* Carry one SDP offer to the peer designator names, for the dial exchange.
        \\   introducer is the designator of the session that handed over the
        \\   reference this dial follows, so the application can carry the offer
        \\   through the party that knows the peer. It is null with a zero length for
        \\   a dial the application started itself or whose introducing session
        \\   signed no designator. The answer comes back through
        \\   glowcap_webrtc_netlayer_provide_answer. Return 0 to accept. Any other
        \\   value refuses the dial, which then fails with GLOWCAP_ERR_IO. */
        \\typedef int32_t (*GlowcapWebrtcSendOfferFn)(void *ctx, uint64_t exchange, const uint8_t *designator, size_t designator_len, const uint8_t *introducer, size_t introducer_len, const uint8_t *sdp, size_t sdp_len);
        \\/* Carry one SDP answer back to the offerer designator names, for the accept
        \\   exchange glowcap_webrtc_netlayer_provide_offer returned. Return 0 to
        \\   accept. Any other value refuses the accept, which closes the answerer
        \\   before the offerer ever learns of it. */
        \\typedef int32_t (*GlowcapWebrtcSendAnswerFn)(void *ctx, uint64_t exchange, const uint8_t *designator, size_t designator_len, const uint8_t *sdp, size_t sdp_len);
        \\/* Carry one local ICE candidate, as JSON, to the peer the exchange is for.
        \\   Return 0 to accept. Any other value fails the exchange. */
        \\typedef int32_t (*GlowcapWebrtcSendCandidateFn)(void *ctx, uint64_t exchange, const uint8_t *ice, size_t ice_len);
        \\/* The exchange is over: it became a connection, failed, or was cancelled.
        \\   Nothing more arrives for it. */
        \\typedef void (*GlowcapWebrtcExchangeDoneFn)(void *ctx, uint64_t exchange);
        \\
        \\/* How the application carries signaling for the exchanges a netlayer runs
        \\   on the driver's behalf. send_offer lets it dial: the provider fills the
        \\   connect verbs. send_answer lets it accept: the provider fills the listen
        \\   verbs. Either needs send_candidate. All zero means the netlayer runs no
        \\   exchange and the driver refuses a webrtc dial or listen as unsupported.
        \\   done is optional; ctx is passed back to each callback unread. Every
        \\   callback runs on the thread that steps the driver and returns at once.
        \\   done fires once for every exchange whose offer send_offer accepted and
        \\   once for every exchange glowcap_webrtc_netlayer_provide_offer returned. */
        \\typedef struct GlowcapWebrtcSignaling {
        \\  void *ctx;
        \\  GlowcapWebrtcSendOfferFn send_offer;
        \\  GlowcapWebrtcSendAnswerFn send_answer;
        \\  GlowcapWebrtcSendCandidateFn send_candidate;
        \\  GlowcapWebrtcExchangeDoneFn done;
        \\} GlowcapWebrtcSignaling;
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
        \\   Establishment deadlines belong to the caller that drives signaling.
        \\   signaling lets the netlayer run dials and accepts for the driver; see
        \\   GlowcapWebrtcSignaling. */
        \\typedef struct GlowcapWebrtcConfig {
        \\  const GlowcapWebrtcIceServer *ice_servers;
        \\  size_t ice_server_count;
        \\  uint32_t include_loopback_candidates;
        \\  uint32_t worker_threads;
        \\  GlowcapWebrtcSignaling signaling;
        \\} GlowcapWebrtcConfig;
        \\
    );

    try emitFn(&b, gpa, "glowcap_webrtc_archive_fingerprint", &.{}, "Return the exact callable-surface fingerprint. Compare it with the binding-generated GLOWCAP_WEBRTC_ARCHIVE_FINGERPRINT before any other call.");
    try emitFn(&b, gpa, "glowcap_webrtc_netlayer_new", &.{ "config", "out_netlayer" }, "Create the shared WebRTC runtime/readiness endpoint. Release it after every peer\ncreated from it has been released. config carries the endpoint's settings; a\nNULL one is GLOWCAP_ERR_NULL_POINTER.");
    try emitFn(&b, gpa, "glowcap_webrtc_netlayer_new_in", &.{ "context", "config", "out_netlayer" }, "As glowcap_webrtc_netlayer_new, allocating through context.");
    try emitFn(&b, gpa, "glowcap_webrtc_netlayer_readiness_fd", &.{"netlayer"}, "Borrow the netlayer's single read-only OS readiness fd. Register it once; do not\nclose it. When it wakes, call glowcap_webrtc_netlayer_drain_ready.");
    try emitFn(&b, gpa, "glowcap_webrtc_netlayer_drain_ready", &.{ "netlayer", "out_events", "out_cap", "out_count" }, "Drain pending stable peer-id events without blocking. Call after the readiness fd\nwakes, then drive CANDIDATE/OPEN/READABLE/WRITABLE/CLOSED for each subject.");
    try emitFn(&b, gpa, "glowcap_webrtc_netlayer_provide_offer", &.{ "netlayer", "designator", "designator_len", "sdp", "sdp_len", "out_exchange" }, "Answer an inbound SDP offer (sdp/sdp_len, borrowed UTF-8) from the peer\ndesignator names (its borrowed lowercase-hex durable key). Call it on the\nthread that steps the driver, while a webrtc listener is active. The netlayer\ncreates the answerer, authorizes designator as the channel's remote key, sets\nthe offer, and hands the answer to send_answer under the exchange id written\nto out_exchange. Route the offerer's later candidates to that id with\nglowcap_webrtc_netlayer_provide_candidate, and expect send_candidate under it.\nThe channel opening is the listener's accept, and done fires once the driver\nhas claimed it or the exchange has ended. Every refusal has no effect:\nGLOWCAP_ERR_CLOSED when no listener is active, GLOWCAP_ERR_INVALID_ARGUMENT\nwhen designator names no key, GLOWCAP_ERR_WOULD_BLOCK while the most accepts\nthe netlayer holds are already signaling, and GLOWCAP_ERR_IO when the WebRTC\nlibrary refuses the offer or send_answer refuses the answer. Every exchange has\nits own id, so an offer from a peer this netlayer is also dialing runs beside\nthat dial, and CapTP's crossed-hellos rule keeps one of the two sessions.");
    try emitFn(&b, gpa, "glowcap_webrtc_netlayer_provide_answer", &.{ "netlayer", "exchange", "sdp", "sdp_len" }, "Hand the far peer's SDP answer (sdp/sdp_len, borrowed UTF-8) to the dial\nexchange, the id send_offer received. Call it on the thread that steps the\ndriver. GLOWCAP_ERR_INVALID_ARGUMENT with no effect when no such dial is in\nprogress, which a late answer after done or after fail_exchange earns too, and\nwhen the exchange is an accept, whose answer this netlayer sent itself.");
    try emitFn(&b, gpa, "glowcap_webrtc_netlayer_provide_candidate", &.{ "netlayer", "exchange", "ice", "ice_len" }, "Hand one of the far peer's ICE candidates (ice/ice_len, the borrowed JSON it\nproduced) to the exchange, a dial or an accept. Same thread and same refusals\nas glowcap_webrtc_netlayer_provide_answer. A candidate that arrives before the\nanswer waits and is added with it.");
    try emitFn(&b, gpa, "glowcap_webrtc_netlayer_fail_exchange", &.{ "netlayer", "exchange" }, "Give up on the exchange because your signaling failed: the peer is\nunreachable, refused, or the channel carrying the offer or answer broke. A\ndial fails with GLOWCAP_ERR_IO and the cause SignalingFailed at the driver's\nnext step instead of at its handshake deadline. An accept ends quietly with\ndone. Same thread as glowcap_webrtc_netlayer_provide_answer, and never from\ninside a signaling callback: a callback that cannot carry its text returns\nnonzero instead. GLOWCAP_ERR_INVALID_ARGUMENT with no effect when no such\nexchange is in progress or its channel has already opened.");
    try emitFn(&b, gpa, "glowcap_webrtc_netlayer_release", &.{"netlayer"}, "Release the endpoint after every peer created from it is released. NULL is a no-op.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_new", &.{ "netlayer", "is_offerer", "out_peer" }, "Create a peer from netlayer in one of the two signaling roles into out_peer.\nis_offerer nonzero creates the offerer; zero creates the answerer. Release with\nglowcap_webrtc_peer_release before releasing netlayer.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_new_in", &.{ "context", "netlayer", "is_offerer", "out_peer" }, "As glowcap_webrtc_peer_new, allocating the peer shell through context.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_create_offer", &.{ "peer", "out", "cap", "out_len" }, "Produce the offerer's SDP offer into out (cap bytes), writing the SDP length to\nout_len and setting it as the local description. GLOWCAP_ERR_BUFFER_TOO_SMALL\nstill writes the required length to out_len, so retry with a buffer that size.\nGLOWCAP_ERR_INVALID_ARGUMENT means the generated SDP exceeds\nGLOWCAP_WEBRTC_MAX_SIGNAL_BYTES and no larger buffer can make it valid.\nOfferer only.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_authorize_remote", &.{ "peer", "designator", "designator_len" }, "Bind the durable key authorized by the signaling authority before the channel\nopens. designator is the borrowed canonical lowercase-hex durable key;\nGLOWCAP_ERR_INVALID_ARGUMENT leaves the peer unchanged.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_create_answer", &.{ "peer", "out", "cap", "out_len" }, "Produce the answerer's SDP answer into out (cap bytes), writing the SDP length\nto out_len and setting it as the local description. Answerer only, after\nglowcap_webrtc_peer_set_remote_offer. GLOWCAP_ERR_BUFFER_TOO_SMALL still writes\nthe required length. GLOWCAP_ERR_INVALID_ARGUMENT means the generated SDP\nexceeds GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES and no larger buffer can make it valid.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_set_remote_offer", &.{ "peer", "sdp", "sdp_len" }, "Set the far offerer's SDP offer (sdp/sdp_len, borrowed UTF-8) as the remote\ndescription. Answerer side. GLOWCAP_ERR_INVALID_ARGUMENT means the description\nexceeds GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES and the WebRTC library's state is unchanged.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_set_remote_answer", &.{ "peer", "sdp", "sdp_len" }, "Set the far answerer's SDP answer (sdp/sdp_len, borrowed UTF-8) as the remote\ndescription. Offerer side. GLOWCAP_ERR_INVALID_ARGUMENT means the description\nexceeds GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES and the WebRTC library's state is unchanged.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_add_remote_candidate", &.{ "peer", "cand", "cand_len" }, "Add one remote ICE candidate (cand/cand_len, the borrowed JSON the far peer's\nglowcap_webrtc_peer_next_local_candidate produced). GLOWCAP_ERR_INVALID_ARGUMENT\nmeans the candidate exceeds GLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES and the WebRTC\nlibrary's state is unchanged.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_next_local_candidate", &.{ "peer", "out", "cap", "out_len" }, "Drain the next locally gathered ICE candidate into out (cap bytes) as JSON,\nwriting its length to out_len; carry it to the far peer's\nglowcap_webrtc_peer_add_remote_candidate. GLOWCAP_ERR_WOULD_BLOCK when none is\npending yet; GLOWCAP_ERR_BUFFER_TOO_SMALL still writes the required length.\nGLOWCAP_ERR_INVALID_ARGUMENT means the local candidate exceeds\nGLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES and no larger buffer can make it valid.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_id", &.{"peer"}, "Return the peer's stable, nonzero readiness identity, or zero for NULL.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_is_open", &.{"peer"}, "Check channel establishment without blocking: GLOWCAP_OK once open,\nGLOWCAP_ERR_WOULD_BLOCK while pending, GLOWCAP_ERR_CLOSED after clean close,\nor GLOWCAP_ERR_IO when setup faulted.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_try_receive_packet", &.{ "peer", "buf", "len", "out_read" }, "Non-blocking receive of one inbound packet: GLOWCAP_OK with the packet length\nin out_read, GLOWCAP_ERR_BUFFER_TOO_SMALL with the packet still queued,\nGLOWCAP_ERR_WOULD_BLOCK until READABLE, GLOWCAP_ERR_CLOSED at clean EOF, or\nGLOWCAP_ERR_IO on fault.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_try_send_packet", &.{ "peer", "buf", "len", "out_written" }, "Copy one whole packet into the bounded send queue and return immediately.\nout_written is len on success. On GLOWCAP_ERR_WOULD_BLOCK retry the same packet\nafter WRITABLE; GLOWCAP_ERR_BUFFER_TOO_SMALL means the packet exceeds this\ntransport's packet cap.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_close", &.{"peer"}, "Close the channel without releasing the handle and report CLOSED readiness.\nIdempotent; glowcap_webrtc_peer_release is still required afterward.");
    try emitFn(&b, gpa, "glowcap_webrtc_peer_release", &.{"peer"}, "Release the peer and close its channel. If this consumes the endpoint's final\nlease, its teardown outcome is returned here. NULL is a no-op.");
    try emitFn(&b, gpa, "glowcap_webrtc_transport_provider", &.{ "netlayer", "out_provider" }, "Fill the generic multiplexed provider package. The driver claims a peer you\nsignaled by hand through claim_external, by the stable subject\nglowcap_webrtc_peer_id returns, dials through the connect verbs when the\nnetlayer's signaling carries send_offer, and listens through the listen verbs\nwhen it carries send_answer.");

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
