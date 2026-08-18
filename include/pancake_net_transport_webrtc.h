/* Generated from src/c_abi/net_transport/webrtc/mod.zig by tools/gen/header/webrtc.zig.
   Do not edit by hand: run `zig build gen-header-net-transport-webrtc`.
   Function signatures are reflected from the Zig source, so this header
   cannot drift from the implementation.

   The WebRTC transport's public C ABI: a separate artifact
   (libpancake_net_transport_webrtc) that links the Rust webrtc sidecar
   (ADR-0089). It is a companion, not a superset: it exports only the
   pancake_webrtc_* family and shares no core symbol with libpancake_ocapn,
   so a consumer links BOTH archives and includes BOTH headers. The
   shared frame, peer, and context vocabulary lives in pancake_ocapn.h
   (included below) and the archives agree on its layout; the WebRTC
   handles and readiness vocabulary are declared here. The webrtc
   family has its own last-error slot, read
   through pancake_webrtc_last_error rather than pancake_ocapn's
   pancake_last_error. */
#ifndef PANCAKE_NET_TRANSPORT_WEBRTC_H
#define PANCAKE_NET_TRANSPORT_WEBRTC_H

#include <stddef.h>
#include <stdint.h>
#include "pancake_ocapn.h"

#ifdef __cplusplus
extern "C" {
#endif
/* Orientation: the WebRTC transport is a peer-to-peer DataChannel that
   carries one keyed OCapN session byte-for-byte, at least one end of which
   is usually a browser. Unlike iroh, a peer has no dialable address, so
   there is no connect(addr). The channel comes up through an out-of-band
   signaling exchange you drive:

     1. Create one PancakeWebrtcNetlayer per host, register its
        pancake_webrtc_netlayer_readiness_fd once, then create peers from
        it with pancake_webrtc_peer_new: one offerer and one answerer.
     2. The offerer produces an SDP offer with pancake_webrtc_peer_create_offer;
        carry it to the answerer, which sets it with
        pancake_webrtc_peer_set_remote_offer and produces an SDP answer with
        pancake_webrtc_peer_create_answer; carry that back to the offerer's
        pancake_webrtc_peer_set_remote_answer.
     3. Trickle ICE candidates both ways: drain each side's
        pancake_webrtc_peer_next_local_candidate (PANCAKE_ERR_WOULD_BLOCK when
        none is pending) and hand each to the other side's
        pancake_webrtc_peer_add_remote_candidate. The readiness fd reports
        CANDIDATE while more are ready and OPEN when the channel opens.

   When the fd wakes, call pancake_webrtc_netlayer_drain_ready and route its
   stable peer-id records. Drain local candidates on CANDIDATE, check channel
   state on OPEN, use pancake_webrtc_peer_try_read / _try_write for raw
   session bytes on READABLE / WRITABLE, and stop on CLOSED. You frame the
   raw bytes yourself. On loopback and on a LAN the peers reach each other
   on host candidates alone, with no STUN or TURN.

   Threading: a netlayer and its peers are single-owner. Signaling submissions
   complete synchronously and may wait on the sidecar runtime, so perform them
   outside a reactor turn. Once submitted, channel progress, candidates, byte
   I/O, and closure are readiness-driven and do not park the reactor. Release
   every peer before pancake_webrtc_netlayer_release. */

/* One WebRTC runtime/readiness endpoint shared by its peers. */
typedef struct PancakeWebrtcNetlayer PancakeWebrtcNetlayer;
/* One WebRTC peer: its RTCPeerConnection and single reliable, ordered
   data channel. Created by pancake_webrtc_peer_new; released by
   pancake_webrtc_peer_release. */
typedef struct PancakeWebrtcPeer PancakeWebrtcPeer;

#define PANCAKE_WEBRTC_EV_OPEN 1u
#define PANCAKE_WEBRTC_EV_CANDIDATE 2u
#define PANCAKE_WEBRTC_EV_READABLE 4u
#define PANCAKE_WEBRTC_EV_WRITABLE 8u
#define PANCAKE_WEBRTC_EV_CLOSED 16u
/* One readiness record from pancake_webrtc_netlayer_drain_ready. subject
   is the stable identity returned by pancake_webrtc_peer_id. */
typedef struct PancakeWebrtcReadyEvent {
  uintptr_t subject;
  uint32_t events;
} PancakeWebrtcReadyEvent;

/* One WebRTC endpoint's configuration, passed to pancake_webrtc_netlayer_new /
   _new_in.
   ice_servers is a comma-separated list of ICE server URLs, borrowed for the
   call, and it decides how far a peer created from this endpoint can reach.
   NULL or empty offers host candidates only, which connects two peers on one
   network and nothing beyond it, because neither end can discover the address a
   NAT gave it. A deployment crossing NAT names STUN servers here
   (stun:host:port). Credentialed TURN relaying is not expressible yet; see
   ADR-0089.
   include_loopback_candidates (nonzero) offers loopback addresses too, which is
   what lets two peers in one process or on one host connect with no STUN. It is
   off unless asked for: a test wants it and says so, while a deployment neither
   needs it nor wants to advertise addresses a partner can never reach.
   worker_threads sizes this endpoint's runtime; 0 takes pancake's two, which is
   pancake's number rather than the runtime's own core-count. It is a per-endpoint
   cost, so a process holding many endpoints, or one endpoint
   holding many peers, is the caller that should name it.
   There is no establishment deadline here, unlike the iroh endpoint's
   connect_timeout_ms, and the difference is deliberate. That sidecar performs a
   dial on your behalf and is the only party that can see it fail, so it must
   bound it. This one runs a state machine you feed, and publishes every terminal
   outcome as a readiness event, including a connection that fails to establish.
   You already own the wall clock, and a second deadline here would be a second
   authority for the same fact.
   Zero-initialize the whole struct before filling the fields you set (e.g.
   `PancakeWebrtcConfig cfg = {0};`), so a field added in a later version
   defaults to 0 rather than reading stack garbage. */
typedef struct PancakeWebrtcConfig {
  const uint8_t *ice_servers;
  size_t ice_servers_len;
  uint32_t include_loopback_candidates;
  uint32_t worker_threads;
} PancakeWebrtcConfig;/* Return the exact callable-surface fingerprint. Compare it with the binding-generated PANCAKE_WEBRTC_ARCHIVE_FINGERPRINT before any other call. */
uint64_t pancake_webrtc_archive_fingerprint(void);
/* Create the shared WebRTC runtime/readiness endpoint. Release it after every peer
   created from it has been released. config carries the endpoint's settings; a
   NULL one is PANCAKE_ERR_NULL_POINTER. */
int32_t pancake_webrtc_netlayer_new(const PancakeWebrtcConfig *config, PancakeWebrtcNetlayer **out_netlayer);
/* As pancake_webrtc_netlayer_new, allocating through context. */
int32_t pancake_webrtc_netlayer_new_in(PancakeContext *context, const PancakeWebrtcConfig *config, PancakeWebrtcNetlayer **out_netlayer);
/* Borrow the netlayer's single read-only OS readiness fd. Register it once; do not
   close it. When it wakes, call pancake_webrtc_netlayer_drain_ready. */
int32_t pancake_webrtc_netlayer_readiness_fd(PancakeWebrtcNetlayer *netlayer);
/* Drain pending stable peer-id events without blocking. Call after the readiness fd
   wakes, then drive CANDIDATE/OPEN/READABLE/WRITABLE/CLOSED for each subject. */
int32_t pancake_webrtc_netlayer_drain_ready(PancakeWebrtcNetlayer *netlayer, PancakeWebrtcReadyEvent *out_events, size_t out_cap, size_t *out_count);
/* Release the endpoint after every peer created from it is released. NULL is a no-op. */
int32_t pancake_webrtc_netlayer_release(PancakeWebrtcNetlayer *netlayer);
/* Create a peer from netlayer in one of the two signaling roles into out_peer.
   is_offerer nonzero creates the offerer; zero creates the answerer. Release with
   pancake_webrtc_peer_release before releasing netlayer. */
int32_t pancake_webrtc_peer_new(PancakeWebrtcNetlayer *netlayer, int32_t is_offerer, PancakeWebrtcPeer **out_peer);
/* As pancake_webrtc_peer_new, allocating the peer shell through context. */
int32_t pancake_webrtc_peer_new_in(PancakeContext *context, PancakeWebrtcNetlayer *netlayer, int32_t is_offerer, PancakeWebrtcPeer **out_peer);
/* Produce the offerer's SDP offer into out (cap bytes), writing the SDP length to
   out_len and setting it as the local description. PANCAKE_ERR_BUFFER_TOO_SMALL
   still writes the required length to out_len, so retry with a buffer that size.
   Offerer only. */
int32_t pancake_webrtc_peer_create_offer(PancakeWebrtcPeer *peer, uint8_t *out, size_t cap, size_t *out_len);
/* Bind the durable key authorized by the signaling authority before the channel opens. */
int32_t pancake_webrtc_peer_authorize_remote(PancakeWebrtcPeer *peer, const uint8_t *designator, size_t designator_len);
/* Produce the answerer's SDP answer into out (cap bytes), writing the SDP length
   to out_len and setting it as the local description. Answerer only, after
   pancake_webrtc_peer_set_remote_offer. PANCAKE_ERR_BUFFER_TOO_SMALL still writes
   the required length. */
int32_t pancake_webrtc_peer_create_answer(PancakeWebrtcPeer *peer, uint8_t *out, size_t cap, size_t *out_len);
/* Set the far offerer's SDP offer (sdp/sdp_len, borrowed UTF-8) as the remote
   description. Answerer side. */
int32_t pancake_webrtc_peer_set_remote_offer(PancakeWebrtcPeer *peer, const uint8_t *sdp, size_t sdp_len);
/* Set the far answerer's SDP answer (sdp/sdp_len, borrowed UTF-8) as the remote
   description. Offerer side. */
int32_t pancake_webrtc_peer_set_remote_answer(PancakeWebrtcPeer *peer, const uint8_t *sdp, size_t sdp_len);
/* Add one remote ICE candidate (cand/cand_len, the borrowed JSON the far peer's
   pancake_webrtc_peer_next_local_candidate produced). */
int32_t pancake_webrtc_peer_add_remote_candidate(PancakeWebrtcPeer *peer, const uint8_t *cand, size_t cand_len);
/* Drain the next locally gathered ICE candidate into out (cap bytes) as JSON,
   writing its length to out_len; carry it to the far peer's
   pancake_webrtc_peer_add_remote_candidate. PANCAKE_ERR_WOULD_BLOCK when none is
   pending yet; PANCAKE_ERR_BUFFER_TOO_SMALL still writes the required length. */
int32_t pancake_webrtc_peer_next_local_candidate(PancakeWebrtcPeer *peer, uint8_t *out, size_t cap, size_t *out_len);
/* Return the peer's stable, nonzero readiness identity, or zero for NULL. */
size_t pancake_webrtc_peer_id(PancakeWebrtcPeer *peer);
/* Check channel establishment without blocking: PANCAKE_OK once open,
   PANCAKE_ERR_WOULD_BLOCK while pending, PANCAKE_ERR_CLOSED after close. */
int32_t pancake_webrtc_peer_is_open(PancakeWebrtcPeer *peer);
/* Non-blocking read of raw inbound bytes: PANCAKE_OK with the count in out_read,
   PANCAKE_ERR_WOULD_BLOCK until READABLE, PANCAKE_ERR_CLOSED at clean EOF, or
   PANCAKE_ERR_IO on fault. */
int32_t pancake_webrtc_peer_try_read(PancakeWebrtcPeer *peer, uint8_t *buf, size_t len, size_t *out_read);
/* Copy a prefix into the bounded send queue and return immediately. Advance by
   out_written; on PANCAKE_ERR_WOULD_BLOCK retry the remaining slice after
   WRITABLE. */
int32_t pancake_webrtc_peer_try_write(PancakeWebrtcPeer *peer, const uint8_t *buf, size_t len, size_t *out_written);
/* Close the channel without releasing the handle and report CLOSED readiness.
   Idempotent; pancake_webrtc_peer_release is still required afterward. */
void pancake_webrtc_peer_close(PancakeWebrtcPeer *peer);
/* Release the peer and close its channel. If this consumes the endpoint's final
   lease, its teardown outcome is returned here. NULL is a no-op. */
int32_t pancake_webrtc_peer_release(PancakeWebrtcPeer *peer);
/* Fill the generic multiplexed provider package. Signaling establishes peers; the driver claims authorized open peers by stable subject. */
int32_t pancake_webrtc_transport_provider(PancakeWebrtcNetlayer *netlayer, PancakeTransportProvider *out_provider);
/* Copy the calling thread's last webrtc-transport error into out_buf, the webrtc
   sibling of pancake_last_error, reading libpancake_net_transport_webrtc's own
   per-thread slot. A pancake_webrtc_* call that returns PANCAKE_ERR_IO records its
   concrete cause here. Copies at most cap-1 bytes and NUL-terminates when cap>0;
   out_buf NULL or cap 0 queries the length. Returns the full message length, or 0
   when none is set. Every status-returning call clears the slot before validation; read it immediately after a failing call, and treat zero length as no additional detail. */
size_t pancake_webrtc_last_error(uint8_t *out_buf, size_t cap);
/* Clear the calling thread's webrtc-transport last-error slot. */
void pancake_webrtc_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_NET_TRANSPORT_WEBRTC_H */
