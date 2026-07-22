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
   (included below) and the archives agree on its layout; only the
   PancakeWebrtcPeer handle and the pancake_webrtc_* prototypes are
   declared here. The webrtc family has its own last-error slot, read
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

     1. Create both ends with pancake_webrtc_peer_new, one offerer (nonzero
        is_offerer, which creates the data channel) and one answerer.
     2. The offerer produces an SDP offer with pancake_webrtc_peer_create_offer;
        carry it to the answerer, which sets it with
        pancake_webrtc_peer_set_remote_offer and produces an SDP answer with
        pancake_webrtc_peer_create_answer; carry that back to the offerer's
        pancake_webrtc_peer_set_remote_answer.
     3. Trickle ICE candidates both ways: drain each side's
        pancake_webrtc_peer_next_local_candidate (PANCAKE_ERR_WOULD_BLOCK when
        none is pending) and hand each to the other side's
        pancake_webrtc_peer_add_remote_candidate, until
        pancake_webrtc_peer_wait_open reports the channel open.

   Then pancake_webrtc_peer_read and pancake_webrtc_peer_write move raw
   session bytes, which you frame yourself (feed them to a PancakePeer's
   stream input and write its outbound frames back), the same shape the iroh
   and TCP consumers use. On loopback and on a LAN the two peers reach each
   other on host candidates alone, with no STUN or TURN.

   Threading: a peer is single-owner; serialize calls on one onto one thread.
   pancake_webrtc_peer_read blocks until bytes arrive or the channel closes,
   and pancake_webrtc_peer_wait_open blocks until the channel opens, so run
   both off your event loop. Release every peer with
   pancake_webrtc_peer_release. */

/* One WebRTC peer: its RTCPeerConnection and single reliable, ordered
   data channel. Created by pancake_webrtc_peer_new; released by
   pancake_webrtc_peer_release. */
typedef struct PancakeWebrtcPeer PancakeWebrtcPeer;

/* Create a peer in one of the two signaling roles into out_peer: is_offerer
   nonzero makes the offerer (which creates the data channel and produces the SDP
   offer), zero the answerer (which receives the channel and produces the answer).
   PANCAKE_ERR_IO (see pancake_webrtc_last_error) if the sidecar cannot create the
   peer connection. Release with pancake_webrtc_peer_release. */
int32_t pancake_webrtc_peer_new(int32_t is_offerer, PancakeWebrtcPeer **out_peer);
/* As pancake_webrtc_peer_new, but the handle allocates through context's
   allocator instead of the library allocator. Released the same way, with
   pancake_webrtc_peer_release. */
int32_t pancake_webrtc_peer_new_in(PancakeContext *context, int32_t is_offerer, PancakeWebrtcPeer **out_peer);
/* Produce the offerer's SDP offer into out (cap bytes), writing the SDP length to
   out_len and setting it as the local description. PANCAKE_ERR_BUFFER_TOO_SMALL
   still writes the required length to out_len, so retry with a buffer that size.
   Offerer only. */
int32_t pancake_webrtc_peer_create_offer(PancakeWebrtcPeer *peer, uint8_t *out, size_t cap, size_t *out_len);
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
/* Block until the data channel opens, or timeout_ms elapses: PANCAKE_OK once open,
   PANCAKE_ERR_WOULD_BLOCK on timeout. Runs the ICE/DTLS/SCTP bring-up, so call it
   off your event loop while trickling candidates. */
int32_t pancake_webrtc_peer_wait_open(PancakeWebrtcPeer *peer, uint64_t timeout_ms);
/* Blocking read of raw inbound session bytes into buf: PANCAKE_OK with the byte
   count in out_read, PANCAKE_ERR_CLOSED on a clean end of stream, or
   PANCAKE_ERR_IO on a fault (out_read untouched on any non-OK return). Parks the
   calling thread until bytes arrive, so run it off your event loop. You frame
   these bytes yourself, feeding a PancakePeer's stream input. */
int32_t pancake_webrtc_peer_read(PancakeWebrtcPeer *peer, uint8_t *buf, size_t len, size_t *out_read);
/* Write len raw session bytes from buf: PANCAKE_OK with the count written (the
   whole slice, all-or-nothing) in out_written, or PANCAKE_ERR_IO on a fault
   (out_written untouched on any non-OK return). */
int32_t pancake_webrtc_peer_write(PancakeWebrtcPeer *peer, const uint8_t *buf, size_t len, size_t *out_written);
/* Close the channel and connection without releasing the handle, waking any parked
   reader with end of stream. Idempotent. The shutdown lever for a host whose read
   parks on another thread; the handle is still released with
   pancake_webrtc_peer_release. */
void pancake_webrtc_peer_close(PancakeWebrtcPeer *peer);
/* Release the peer, closing its channel and shutting down its runtime. NULL is a
   no-op. */
void pancake_webrtc_peer_release(PancakeWebrtcPeer *peer);
/* Copy the calling thread's last webrtc-transport error into out_buf, the webrtc
   sibling of pancake_last_error, reading libpancake_net_transport_webrtc's own
   per-thread slot. A pancake_webrtc_* call that returns PANCAKE_ERR_IO records its
   concrete cause here. Copies at most cap-1 bytes and NUL-terminates when cap>0;
   out_buf NULL or cap 0 queries the length. Returns the full message length, or 0
   when none is set. */
size_t pancake_webrtc_last_error(uint8_t *out_buf, size_t cap);
/* Clear the calling thread's webrtc-transport last-error slot. */
void pancake_webrtc_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_NET_TRANSPORT_WEBRTC_H */
