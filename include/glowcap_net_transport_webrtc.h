/* Generated from src/c_abi/net_transport/webrtc/mod.zig by tools/gen/header/webrtc.zig.
   Do not edit by hand: run `zig build gen-header-net-transport-webrtc`.
   Function signatures are reflected from the Zig source, so this header
   cannot drift from the implementation.

   The WebRTC transport's public C ABI: a separate artifact
   (libglowcap_net_transport_webrtc) that links the Rust webrtc sidecar
   (ADR-0089). It is a companion, not a superset: it exports only the
   glowcap_webrtc_* family and shares no core symbol with libglowcap_ocapn,
   so a consumer links BOTH archives and includes BOTH headers. The
   shared frame, peer, and context vocabulary lives in glowcap_ocapn.h
   (included below) and the archives agree on its layout; the WebRTC
   handles and readiness vocabulary are declared here. The webrtc
   family has its own last-error slot, read
   through glowcap_webrtc_last_error rather than glowcap_ocapn's
   glowcap_last_error. */
#ifndef GLOWCAP_NET_TRANSPORT_WEBRTC_H
#define GLOWCAP_NET_TRANSPORT_WEBRTC_H

#include <stddef.h>
#include <stdint.h>
#include "glowcap_ocapn.h"

#ifdef __cplusplus
extern "C" {
#endif
/* Orientation: the WebRTC transport is a peer-to-peer DataChannel that
   carries one bare OCapN codec frame per DataChannel message, at least
   one end of which is usually a browser. Unlike iroh, a peer has no dialable address, so
   there is no connect(addr). The channel comes up through an out-of-band
   signaling exchange you drive:

     1. Create one GlowcapWebrtcNetlayer per host, register its
        glowcap_webrtc_netlayer_readiness_fd once, then create peers from
        it with glowcap_webrtc_peer_new: one offerer and one answerer.
     2. The offerer produces an SDP offer with glowcap_webrtc_peer_create_offer;
        carry it to the answerer, which sets it with
        glowcap_webrtc_peer_set_remote_offer and produces an SDP answer with
        glowcap_webrtc_peer_create_answer; carry that back to the offerer's
        glowcap_webrtc_peer_set_remote_answer.
     3. Trickle ICE candidates both ways: drain each side's
        glowcap_webrtc_peer_next_local_candidate (GLOWCAP_ERR_WOULD_BLOCK when
        none is pending) and hand each to the other side's
        glowcap_webrtc_peer_add_remote_candidate. The readiness fd reports
        CANDIDATE while more are ready and OPEN when the channel opens.

   When the fd wakes, call glowcap_webrtc_netlayer_drain_ready and route its
   stable peer-id records. Drain local candidates on CANDIDATE, check channel
   state on OPEN, use glowcap_webrtc_peer_try_receive_packet /
   _try_send_packet for whole DataChannel packets on READABLE / WRITABLE,
   and stop on CLOSED. On loopback and on a LAN the peers reach each other
   on host candidates alone, with no STUN or TURN.

   Threading: a netlayer and its peers are single-owner. Signaling submissions
   complete synchronously and may wait on the sidecar runtime, so perform them
   outside a reactor turn. Once submitted, channel progress, candidates, byte
   I/O, and closure are readiness-driven and do not park the reactor. Release
   every peer before glowcap_webrtc_netlayer_release. */

/* One WebRTC runtime/readiness endpoint shared by its peers. */
typedef struct GlowcapWebrtcNetlayer GlowcapWebrtcNetlayer;
/* One WebRTC peer: its RTCPeerConnection and single reliable, ordered
   data channel. Created by glowcap_webrtc_peer_new; released by
   glowcap_webrtc_peer_release. */
typedef struct GlowcapWebrtcPeer GlowcapWebrtcPeer;

#define GLOWCAP_WEBRTC_EV_OPEN 1u
#define GLOWCAP_WEBRTC_EV_CANDIDATE 2u
#define GLOWCAP_WEBRTC_EV_READABLE 4u
#define GLOWCAP_WEBRTC_EV_WRITABLE 8u
#define GLOWCAP_WEBRTC_EV_CLOSED 16u
#define GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES 16384u
#define GLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES 16384u
#define GLOWCAP_WEBRTC_MAX_ICE_SERVERS 16u
#define GLOWCAP_WEBRTC_MAX_ICE_URLS_PER_SERVER 16u
#define GLOWCAP_WEBRTC_MAX_ICE_URL_BYTES 2048u
#define GLOWCAP_WEBRTC_MAX_ICE_CREDENTIAL_BYTES 4096u
#define GLOWCAP_WEBRTC_MAX_PENDING_ICE_CANDIDATES 256u
#define GLOWCAP_WEBRTC_PENDING_ICE_CANDIDATE_QUEUE_BYTES 65536u
#define GLOWCAP_WEBRTC_DATA_CHANNEL_QUEUE_BYTES 1048576u
/* One readiness record from glowcap_webrtc_netlayer_drain_ready. subject
   is the stable identity returned by glowcap_webrtc_peer_id. */
typedef struct GlowcapWebrtcReadyEvent {
  uintptr_t subject;
  uint32_t events;
} GlowcapWebrtcReadyEvent;

/* Borrowed UTF-8 text in WebRTC configuration records. A zero length may use
   NULL. */
typedef struct GlowcapWebrtcStringView {
  const uint8_t *ptr;
  size_t len;
} GlowcapWebrtcStringView;

/* One STUN or TURN record. urls points to url_count borrowed URL views.
   username and credential are empty for ordinary STUN and set together for
   credentialed TURN. */
typedef struct GlowcapWebrtcIceServer {
  const GlowcapWebrtcStringView *urls;
  size_t url_count;
  GlowcapWebrtcStringView username;
  GlowcapWebrtcStringView credential;
} GlowcapWebrtcIceServer;

/* One WebRTC endpoint's configuration. Zero-initialize before filling fields.
   ice_servers is a borrowed array of STUN/TURN records; NULL or empty gathers
   host candidates only. Each record has 1-GLOWCAP_WEBRTC_MAX_ICE_URLS_PER_SERVER
   non-empty UTF-8 stun:, stuns:, turn:, or turns: URLs, and a config has at
   most GLOWCAP_WEBRTC_MAX_ICE_SERVERS records. TURN records require both
   username and credential; STUN-only records must leave them empty. Provider
   tokens, expiry, and refresh policy stay outside this ABI.
   include_loopback_candidates offers loopback candidates for same-host tests.
   worker_threads sizes this endpoint's runtime; 0 selects glowcap's default.
   Establishment deadlines belong to the caller that drives signaling. */
typedef struct GlowcapWebrtcConfig {
  const GlowcapWebrtcIceServer *ice_servers;
  size_t ice_server_count;
  uint32_t include_loopback_candidates;
  uint32_t worker_threads;
} GlowcapWebrtcConfig;
/* Return the exact callable-surface fingerprint. Compare it with the binding-generated GLOWCAP_WEBRTC_ARCHIVE_FINGERPRINT before any other call. */
uint64_t glowcap_webrtc_archive_fingerprint(void);
/* Create the shared WebRTC runtime/readiness endpoint. Release it after every peer
   created from it has been released. config carries the endpoint's settings; a
   NULL one is GLOWCAP_ERR_NULL_POINTER. */
int32_t glowcap_webrtc_netlayer_new(const GlowcapWebrtcConfig *config, GlowcapWebrtcNetlayer **out_netlayer);
/* As glowcap_webrtc_netlayer_new, allocating through context. */
int32_t glowcap_webrtc_netlayer_new_in(GlowcapContext *context, const GlowcapWebrtcConfig *config, GlowcapWebrtcNetlayer **out_netlayer);
/* Borrow the netlayer's single read-only OS readiness fd. Register it once; do not
   close it. When it wakes, call glowcap_webrtc_netlayer_drain_ready. */
int32_t glowcap_webrtc_netlayer_readiness_fd(GlowcapWebrtcNetlayer *netlayer);
/* Drain pending stable peer-id events without blocking. Call after the readiness fd
   wakes, then drive CANDIDATE/OPEN/READABLE/WRITABLE/CLOSED for each subject. */
int32_t glowcap_webrtc_netlayer_drain_ready(GlowcapWebrtcNetlayer *netlayer, GlowcapWebrtcReadyEvent *out_events, size_t out_cap, size_t *out_count);
/* Release the endpoint after every peer created from it is released. NULL is a no-op. */
int32_t glowcap_webrtc_netlayer_release(GlowcapWebrtcNetlayer *netlayer);
/* Create a peer from netlayer in one of the two signaling roles into out_peer.
   is_offerer nonzero creates the offerer; zero creates the answerer. Release with
   glowcap_webrtc_peer_release before releasing netlayer. */
int32_t glowcap_webrtc_peer_new(GlowcapWebrtcNetlayer *netlayer, int32_t is_offerer, GlowcapWebrtcPeer **out_peer);
/* As glowcap_webrtc_peer_new, allocating the peer shell through context. */
int32_t glowcap_webrtc_peer_new_in(GlowcapContext *context, GlowcapWebrtcNetlayer *netlayer, int32_t is_offerer, GlowcapWebrtcPeer **out_peer);
/* Produce the offerer's SDP offer into out (cap bytes), writing the SDP length to
   out_len and setting it as the local description. GLOWCAP_ERR_BUFFER_TOO_SMALL
   still writes the required length to out_len, so retry with a buffer that size.
   GLOWCAP_ERR_INVALID_ARGUMENT means the generated SDP exceeds
   GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES and no larger buffer can make it valid.
   Offerer only. */
int32_t glowcap_webrtc_peer_create_offer(GlowcapWebrtcPeer *peer, uint8_t *out, size_t cap, size_t *out_len);
/* Bind the durable key authorized by the signaling authority before the channel
   opens. designator is the borrowed canonical lowercase-hex durable key;
   GLOWCAP_ERR_INVALID_ARGUMENT leaves the peer unchanged. */
int32_t glowcap_webrtc_peer_authorize_remote(GlowcapWebrtcPeer *peer, const uint8_t *designator, size_t designator_len);
/* Produce the answerer's SDP answer into out (cap bytes), writing the SDP length
   to out_len and setting it as the local description. Answerer only, after
   glowcap_webrtc_peer_set_remote_offer. GLOWCAP_ERR_BUFFER_TOO_SMALL still writes
   the required length. GLOWCAP_ERR_INVALID_ARGUMENT means the generated SDP
   exceeds GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES and no larger buffer can make it valid. */
int32_t glowcap_webrtc_peer_create_answer(GlowcapWebrtcPeer *peer, uint8_t *out, size_t cap, size_t *out_len);
/* Set the far offerer's SDP offer (sdp/sdp_len, borrowed UTF-8) as the remote
   description. Answerer side. GLOWCAP_ERR_INVALID_ARGUMENT means the description
   exceeds GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES and the sidecar state is unchanged. */
int32_t glowcap_webrtc_peer_set_remote_offer(GlowcapWebrtcPeer *peer, const uint8_t *sdp, size_t sdp_len);
/* Set the far answerer's SDP answer (sdp/sdp_len, borrowed UTF-8) as the remote
   description. Offerer side. GLOWCAP_ERR_INVALID_ARGUMENT means the description
   exceeds GLOWCAP_WEBRTC_MAX_SIGNAL_BYTES and the sidecar state is unchanged. */
int32_t glowcap_webrtc_peer_set_remote_answer(GlowcapWebrtcPeer *peer, const uint8_t *sdp, size_t sdp_len);
/* Add one remote ICE candidate (cand/cand_len, the borrowed JSON the far peer's
   glowcap_webrtc_peer_next_local_candidate produced). GLOWCAP_ERR_INVALID_ARGUMENT
   means the candidate exceeds GLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES and the sidecar
   state is unchanged. */
int32_t glowcap_webrtc_peer_add_remote_candidate(GlowcapWebrtcPeer *peer, const uint8_t *cand, size_t cand_len);
/* Drain the next locally gathered ICE candidate into out (cap bytes) as JSON,
   writing its length to out_len; carry it to the far peer's
   glowcap_webrtc_peer_add_remote_candidate. GLOWCAP_ERR_WOULD_BLOCK when none is
   pending yet; GLOWCAP_ERR_BUFFER_TOO_SMALL still writes the required length.
   GLOWCAP_ERR_INVALID_ARGUMENT means the local candidate exceeds
   GLOWCAP_WEBRTC_MAX_ICE_CANDIDATE_BYTES and no larger buffer can make it valid. */
int32_t glowcap_webrtc_peer_next_local_candidate(GlowcapWebrtcPeer *peer, uint8_t *out, size_t cap, size_t *out_len);
/* Return the peer's stable, nonzero readiness identity, or zero for NULL. */
size_t glowcap_webrtc_peer_id(GlowcapWebrtcPeer *peer);
/* Check channel establishment without blocking: GLOWCAP_OK once open,
   GLOWCAP_ERR_WOULD_BLOCK while pending, GLOWCAP_ERR_CLOSED after clean close,
   or GLOWCAP_ERR_IO when setup faulted. */
int32_t glowcap_webrtc_peer_is_open(GlowcapWebrtcPeer *peer);
/* Non-blocking receive of one inbound packet: GLOWCAP_OK with the packet length
   in out_read, GLOWCAP_ERR_BUFFER_TOO_SMALL with the packet still queued,
   GLOWCAP_ERR_WOULD_BLOCK until READABLE, GLOWCAP_ERR_CLOSED at clean EOF, or
   GLOWCAP_ERR_IO on fault. */
int32_t glowcap_webrtc_peer_try_receive_packet(GlowcapWebrtcPeer *peer, uint8_t *buf, size_t len, size_t *out_read);
/* Copy one whole packet into the bounded send queue and return immediately.
   out_written is len on success. On GLOWCAP_ERR_WOULD_BLOCK retry the same packet
   after WRITABLE; GLOWCAP_ERR_BUFFER_TOO_SMALL means the packet exceeds this
   transport's packet cap. */
int32_t glowcap_webrtc_peer_try_send_packet(GlowcapWebrtcPeer *peer, const uint8_t *buf, size_t len, size_t *out_written);
/* Close the channel without releasing the handle and report CLOSED readiness.
   Idempotent; glowcap_webrtc_peer_release is still required afterward. */
void glowcap_webrtc_peer_close(GlowcapWebrtcPeer *peer);
/* Release the peer and close its channel. If this consumes the endpoint's final
   lease, its teardown outcome is returned here. NULL is a no-op. */
int32_t glowcap_webrtc_peer_release(GlowcapWebrtcPeer *peer);
/* Fill the generic multiplexed provider package. Signaling establishes peers; the driver claims authorized open peers by stable subject. */
int32_t glowcap_webrtc_transport_provider(GlowcapWebrtcNetlayer *netlayer, GlowcapTransportProvider *out_provider);
/* Copy the calling thread's last webrtc-transport error into out_buf, the webrtc
   sibling of glowcap_last_error, reading libglowcap_net_transport_webrtc's own
   per-thread slot. A glowcap_webrtc_* call that returns GLOWCAP_ERR_IO records its
   concrete cause here. Copies at most cap-1 bytes and NUL-terminates when cap>0;
   out_buf NULL or cap 0 queries the length. Returns the full message length, or 0
   when none is set. Every status-returning call clears the slot before validation; read it immediately after a failing call, and treat zero length as no additional detail. */
size_t glowcap_webrtc_last_error(uint8_t *out_buf, size_t cap);
/* Clear the calling thread's webrtc-transport last-error slot. */
void glowcap_webrtc_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* GLOWCAP_NET_TRANSPORT_WEBRTC_H */
