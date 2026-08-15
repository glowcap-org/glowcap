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
//! which this header includes; only the WebRTC handles, readiness record, event
//! constants, and `pancake_webrtc_*` prototypes are new here.

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
    "pancake_webrtc_netlayer_new",
    "pancake_webrtc_netlayer_new_in",
    "pancake_webrtc_netlayer_readiness_fd",
    "pancake_webrtc_netlayer_drain_ready",
    "pancake_webrtc_netlayer_release",
    "pancake_webrtc_peer_new",
    "pancake_webrtc_peer_new_in",
    "pancake_webrtc_peer_authorize_remote",
    "pancake_webrtc_peer_create_offer",
    "pancake_webrtc_peer_create_answer",
    "pancake_webrtc_peer_set_remote_offer",
    "pancake_webrtc_peer_set_remote_answer",
    "pancake_webrtc_peer_add_remote_candidate",
    "pancake_webrtc_peer_next_local_candidate",
    "pancake_webrtc_peer_id",
    "pancake_webrtc_peer_is_open",
    "pancake_webrtc_peer_try_read",
    "pancake_webrtc_peer_try_write",
    "pancake_webrtc_peer_close",
    "pancake_webrtc_peer_release",
    "pancake_webrtc_transport_provider",
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
        \\   (included below) and the archives agree on its layout; the WebRTC
        \\   handles and readiness vocabulary are declared here. The webrtc
        \\   family has its own last-error slot, read
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
        \\  1. Create one PancakeWebrtcNetlayer per host, register its
        \\     pancake_webrtc_netlayer_readiness_fd once, then create peers from
        \\     it with pancake_webrtc_peer_new: one offerer and one answerer.
        \\  2. The offerer produces an SDP offer with pancake_webrtc_peer_create_offer;
        \\     carry it to the answerer, which sets it with
        \\     pancake_webrtc_peer_set_remote_offer and produces an SDP answer with
        \\     pancake_webrtc_peer_create_answer; carry that back to the offerer's
        \\     pancake_webrtc_peer_set_remote_answer.
        \\  3. Trickle ICE candidates both ways: drain each side's
        \\     pancake_webrtc_peer_next_local_candidate (PANCAKE_ERR_WOULD_BLOCK when
        \\     none is pending) and hand each to the other side's
        \\     pancake_webrtc_peer_add_remote_candidate. The readiness fd reports
        \\     CANDIDATE while more are ready and OPEN when the channel opens.
        \\
        \\When the fd wakes, call pancake_webrtc_netlayer_drain_ready and route its
        \\stable peer-id records. Drain local candidates on CANDIDATE, check channel
        \\state on OPEN, use pancake_webrtc_peer_try_read / _try_write for raw
        \\session bytes on READABLE / WRITABLE, and stop on CLOSED. You frame the
        \\raw bytes yourself. On loopback and on a LAN the peers reach each other
        \\on host candidates alone, with no STUN or TURN.
        \\
        \\Threading: a netlayer and its peers are single-owner. Signaling submissions
        \\complete synchronously and may wait on the sidecar runtime, so perform them
        \\outside a reactor turn. Once submitted, channel progress, candidates, byte
        \\I/O, and closure are readiness-driven and do not park the reactor. Release
        \\every peer before pancake_webrtc_netlayer_release.
    );

    try b.appendSlice(gpa,
        \\
        \\/* One WebRTC runtime/readiness endpoint shared by its peers. */
        \\typedef struct PancakeWebrtcNetlayer PancakeWebrtcNetlayer;
        \\/* One WebRTC peer: its RTCPeerConnection and single reliable, ordered
        \\   data channel. Created by pancake_webrtc_peer_new; released by
        \\   pancake_webrtc_peer_release. */
        \\typedef struct PancakeWebrtcPeer PancakeWebrtcPeer;
        \\
        \\
    );

    try b.print(gpa, "#define PANCAKE_WEBRTC_EV_OPEN {d}u\n", .{c.PANCAKE_WEBRTC_EV_OPEN});
    try b.print(gpa, "#define PANCAKE_WEBRTC_EV_CANDIDATE {d}u\n", .{c.PANCAKE_WEBRTC_EV_CANDIDATE});
    try b.print(gpa, "#define PANCAKE_WEBRTC_EV_READABLE {d}u\n", .{c.PANCAKE_WEBRTC_EV_READABLE});
    try b.print(gpa, "#define PANCAKE_WEBRTC_EV_WRITABLE {d}u\n", .{c.PANCAKE_WEBRTC_EV_WRITABLE});
    try b.print(gpa, "#define PANCAKE_WEBRTC_EV_CLOSED {d}u\n", .{c.PANCAKE_WEBRTC_EV_CLOSED});
    try b.appendSlice(gpa,
        \\/* One readiness record from pancake_webrtc_netlayer_drain_ready. subject
        \\   is the stable identity returned by pancake_webrtc_peer_id. */
        \\typedef struct PancakeWebrtcReadyEvent {
        \\  uintptr_t subject;
        \\  uint32_t events;
        \\} PancakeWebrtcReadyEvent;
        \\
        \\/* One WebRTC endpoint's configuration, passed to pancake_webrtc_netlayer_new /
        \\   _new_in.
        \\   ice_servers is a comma-separated list of ICE server URLs, borrowed for the
        \\   call, and it decides how far a peer created from this endpoint can reach.
        \\   NULL or empty offers host candidates only, which connects two peers on one
        \\   network and nothing beyond it, because neither end can discover the address a
        \\   NAT gave it. A deployment crossing NAT names STUN servers here
        \\   (stun:host:port). Credentialed TURN relaying is not expressible yet; see
        \\   ADR-0089.
        \\   include_loopback_candidates (nonzero) offers loopback addresses too, which is
        \\   what lets two peers in one process or on one host connect with no STUN. It is
        \\   off unless asked for: a test wants it and says so, while a deployment neither
        \\   needs it nor wants to advertise addresses a partner can never reach.
        \\   worker_threads sizes this endpoint's runtime; 0 takes pancake's two, which is
        \\   pancake's number rather than the runtime's own core-count. It is a per-endpoint
        \\   cost, so a process holding many endpoints, or one endpoint
        \\   holding many peers, is the caller that should name it.
        \\   There is no establishment deadline here, unlike the iroh endpoint's
        \\   connect_timeout_ms, and the difference is deliberate. That sidecar performs a
        \\   dial on your behalf and is the only party that can see it fail, so it must
        \\   bound it. This one runs a state machine you feed, and publishes every terminal
        \\   outcome as a readiness event, including a connection that fails to establish.
        \\   You already own the wall clock, and a second deadline here would be a second
        \\   authority for the same fact.
        \\   Zero-initialize the whole struct before filling the fields you set (e.g.
        \\   `PancakeWebrtcConfig cfg = {0};`), so a field added in a later version
        \\   defaults to 0 rather than reading stack garbage. */
        \\typedef struct PancakeWebrtcConfig {
        \\  const uint8_t *ice_servers;
        \\  size_t ice_servers_len;
        \\  uint32_t include_loopback_candidates;
        \\  uint32_t worker_threads;
        \\} PancakeWebrtcConfig;
    );

    try emitFn(&b, gpa, "pancake_webrtc_netlayer_new", &.{ "config", "out_netlayer" }, "Create the shared WebRTC runtime/readiness endpoint. Release it after every peer\ncreated from it has been released. config carries the endpoint's settings; a\nNULL one is PANCAKE_ERR_NULL_POINTER.");
    try emitFn(&b, gpa, "pancake_webrtc_netlayer_new_in", &.{ "context", "config", "out_netlayer" }, "As pancake_webrtc_netlayer_new, allocating through context.");
    try emitFn(&b, gpa, "pancake_webrtc_netlayer_readiness_fd", &.{"netlayer"}, "Borrow the netlayer's single read-only OS readiness fd. Register it once; do not\nclose it. When it wakes, call pancake_webrtc_netlayer_drain_ready.");
    try emitFn(&b, gpa, "pancake_webrtc_netlayer_drain_ready", &.{ "netlayer", "out_events", "out_cap", "out_count" }, "Drain pending stable peer-id events without blocking. Call after the readiness fd\nwakes, then drive CANDIDATE/OPEN/READABLE/WRITABLE/CLOSED for each subject.");
    try emitFn(&b, gpa, "pancake_webrtc_netlayer_release", &.{"netlayer"}, "Release the endpoint after every peer created from it is released. NULL is a no-op.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_new", &.{ "netlayer", "is_offerer", "out_peer" }, "Create a peer from netlayer in one of the two signaling roles into out_peer.\nis_offerer nonzero creates the offerer; zero creates the answerer. Release with\npancake_webrtc_peer_release before releasing netlayer.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_new_in", &.{ "context", "netlayer", "is_offerer", "out_peer" }, "As pancake_webrtc_peer_new, allocating the peer shell through context.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_create_offer", &.{ "peer", "out", "cap", "out_len" }, "Produce the offerer's SDP offer into out (cap bytes), writing the SDP length to\nout_len and setting it as the local description. PANCAKE_ERR_BUFFER_TOO_SMALL\nstill writes the required length to out_len, so retry with a buffer that size.\nOfferer only.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_authorize_remote", &.{ "peer", "designator", "designator_len" }, "Bind the durable key authorized by the signaling authority before the channel opens.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_create_answer", &.{ "peer", "out", "cap", "out_len" }, "Produce the answerer's SDP answer into out (cap bytes), writing the SDP length\nto out_len and setting it as the local description. Answerer only, after\npancake_webrtc_peer_set_remote_offer. PANCAKE_ERR_BUFFER_TOO_SMALL still writes\nthe required length.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_set_remote_offer", &.{ "peer", "sdp", "sdp_len" }, "Set the far offerer's SDP offer (sdp/sdp_len, borrowed UTF-8) as the remote\ndescription. Answerer side.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_set_remote_answer", &.{ "peer", "sdp", "sdp_len" }, "Set the far answerer's SDP answer (sdp/sdp_len, borrowed UTF-8) as the remote\ndescription. Offerer side.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_add_remote_candidate", &.{ "peer", "cand", "cand_len" }, "Add one remote ICE candidate (cand/cand_len, the borrowed JSON the far peer's\npancake_webrtc_peer_next_local_candidate produced).");
    try emitFn(&b, gpa, "pancake_webrtc_peer_next_local_candidate", &.{ "peer", "out", "cap", "out_len" }, "Drain the next locally gathered ICE candidate into out (cap bytes) as JSON,\nwriting its length to out_len; carry it to the far peer's\npancake_webrtc_peer_add_remote_candidate. PANCAKE_ERR_WOULD_BLOCK when none is\npending yet; PANCAKE_ERR_BUFFER_TOO_SMALL still writes the required length.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_id", &.{"peer"}, "Return the peer's stable, nonzero readiness identity, or zero for NULL.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_is_open", &.{"peer"}, "Check channel establishment without blocking: PANCAKE_OK once open,\nPANCAKE_ERR_WOULD_BLOCK while pending, PANCAKE_ERR_CLOSED after close.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_try_read", &.{ "peer", "buf", "len", "out_read" }, "Non-blocking read of raw inbound bytes: PANCAKE_OK with the count in out_read,\nPANCAKE_ERR_WOULD_BLOCK until READABLE, PANCAKE_ERR_CLOSED at clean EOF, or\nPANCAKE_ERR_IO on fault.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_try_write", &.{ "peer", "buf", "len", "out_written" }, "Copy a prefix into the bounded send queue and return immediately. Advance by\nout_written; on PANCAKE_ERR_WOULD_BLOCK retry the remaining slice after\nWRITABLE.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_close", &.{"peer"}, "Close the channel without releasing the handle and report CLOSED readiness.\nIdempotent; pancake_webrtc_peer_release is still required afterward.");
    try emitFn(&b, gpa, "pancake_webrtc_peer_release", &.{"peer"}, "Release the peer and close its channel. If this consumes the endpoint's final\nlease, its teardown outcome is returned here. NULL is a no-op.");
    try emitFn(&b, gpa, "pancake_webrtc_transport_provider", &.{ "netlayer", "out_provider" }, "Fill the generic multiplexed provider package. Signaling establishes peers; the driver claims authorized open peers by stable subject.");

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
