#ifndef PANCAKE_H
#define PANCAKE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PANCAKE_OK 0
#define PANCAKE_ERR_NULL_POINTER -1
#define PANCAKE_ERR_INVALID_HANDLE -2
/* A non-pointer argument was out of range or unparseable (e.g. a zero frame
   cap, or a host string that is not an address). Distinct from _NULL_POINTER
   (a required pointer was null) and _IO (the network itself failed). */
#define PANCAKE_ERR_INVALID_ARGUMENT -3
#define PANCAKE_ERR_SESSION -4
#define PANCAKE_ERR_CODEC -5
#define PANCAKE_ERR_INTERNAL -6
#define PANCAKE_ERR_WOULD_BLOCK -7
/* The peer closed the stream gracefully on a frame boundary (clean EOF). */
#define PANCAKE_ERR_CLOSED -8
/* An underlying socket read/write failed; see `pancake_last_error`. */
#define PANCAKE_ERR_IO -9
/* Inbound bytes were not a structurally valid frame. */
#define PANCAKE_ERR_MALFORMED -10
/* An inbound frame exceeded the endpoint's `max_frame_bytes`. */
#define PANCAKE_ERR_FRAME_TOO_LARGE -11

/* Codec selector for endpoint framing (the grammar that delimits frames). */
#define PANCAKE_CODEC_SYRUP 0u
#define PANCAKE_CODEC_CAPNP 1u

#define PANCAKE_FRAME_SHAPE_BYTE 0u
#define PANCAKE_FRAME_SHAPE_WORD 1u
#define PANCAKE_EVENT_DELIVER 1u
#define PANCAKE_EVENT_RESOLVE 2u
#define PANCAKE_EVENT_GC_EXPORT 3u
#define PANCAKE_EVENT_GC_ANSWER 4u
#define PANCAKE_EVENT_HANDOFF 5u
#define PANCAKE_EVENT_START_SESSION 6u
#define PANCAKE_EVENT_ABORT 7u
#define PANCAKE_EVENT_LISTEN 8u
#define PANCAKE_EVENT_GET 9u
#define PANCAKE_EVENT_INDEX 10u

typedef struct PancakeFrame {
    /* Borrowed byte view. The caller owns `bytes`; pancake will not retain it
       after the function receiving this value returns. */
    const uint8_t *bytes;
    size_t len;
    uint32_t shape;
} PancakeFrame;

typedef struct PancakeManagedFrame PancakeManagedFrame;
typedef struct PancakePeer PancakePeer;
typedef void (*PancakeReleaseFn)(PancakeManagedFrame *frame);

struct PancakeManagedFrame {
    /* Managed byte buffer. Ownership follows the API that produced or consumed
       the frame. If `release` is non-NULL, call `pancake_managed_frame_release`
       exactly once when done; repeated release is safe. */
    uint8_t *bytes;
    size_t len;
    uint32_t shape;
    PancakeReleaseFn release;
    void *private_data;
};

typedef struct PancakeEvent {
    uint32_t kind;
    /* Managed frame for the event payload. It carries the originating message
       bytes in the session's negotiated wire encoding; pancake does not decode
       and re-encode the payload. Call `pancake_event_release` exactly once when
       done; repeated release is safe. */
    PancakeManagedFrame frame;
} PancakeEvent;

void pancake_managed_frame_release(PancakeManagedFrame *frame);
void pancake_frame_release(PancakeManagedFrame *frame);
void pancake_event_release(PancakeEvent *event);

int32_t pancake_peer_new(PancakePeer **peer);
void pancake_peer_release(PancakePeer *peer);
/* Synchronously dispatches a borrowed frame. The caller retains ownership. */
int32_t pancake_peer_feed_borrowed(PancakePeer *peer, const PancakeFrame *frame);
/* Transfers a managed frame into the peer's inbound queue for
   `pancake_peer_step`. On success the caller's descriptor is cleared. The frame
   moves through dispatch into the surfaced event and is released when that event
   is released (or when the peer is released, if the event is never polled). */
int32_t pancake_peer_feed_owned(PancakePeer *peer, PancakeManagedFrame *frame);
int32_t pancake_peer_step(PancakePeer *peer);
/* Returns a managed frame owned by the caller until released. */
int32_t pancake_peer_take_outbound(PancakePeer *peer, PancakeManagedFrame *out_frame);
/* Returns the next event, transferring ownership to the caller. The event's
   managed frame carries the originating message bytes in the session's
   negotiated wire encoding (no re-encode); release it with
   `pancake_event_release`. Returns PANCAKE_ERR_WOULD_BLOCK when none is queued. */
int32_t pancake_peer_poll_event(PancakePeer *peer, PancakeEvent *out_event);

/* Expose a local capability behind `swissnum` for inbound bootstrap-fetch.
   Writes the allocated export id into `out_export_id`. `swissnum` is borrowed. */
int32_t pancake_peer_register_bootstrap_cap(PancakePeer *peer,
                                            const uint8_t *swissnum,
                                            size_t swissnum_len,
                                            uint64_t *out_export_id);

/* Copy the calling thread's last error message into `out_buf` (NUL-terminated
   if it fits), returning the full message length. `out_buf` may be NULL to
   query the length only. errno-style: the slot is meaningful only immediately
   after a call that returned an error code documenting a cause (currently
   PANCAKE_ERR_IO and the address-parse PANCAKE_ERR_INVALID_ARGUMENT); a
   subsequent successful call does not clear it. Returns 0 when none is set. */
size_t pancake_last_error(char *out_buf, size_t cap);
/* Clear the calling thread's last error slot. */
void pancake_clear_last_error(void);

/* ── Blocking TCP endpoint handles (`tcp-testing-only`) ────────────────────────

   The host-driven netlayer seam: the host owns the peer and shuttles frames
   (read_frame -> feed_owned -> step -> take_outbound -> write_frame). These
   calls block; framing uses the codec selected at connect/accept. Cleartext,
   loopback-grade — production transports layer above the same adapter.

   The netlayer handle owns the I/O backend the endpoints run on. Create it,
   make connections/listeners from it, then free it *after* every endpoint made
   from it is closed (each borrows the netlayer's backend). */
typedef struct PancakeTcpNetlayer PancakeTcpNetlayer;
typedef struct PancakeTcpConn PancakeTcpConn;
typedef struct PancakeTcpListener PancakeTcpListener;

int32_t pancake_tcp_netlayer_new(PancakeTcpNetlayer **out_netlayer);
void pancake_tcp_netlayer_free(PancakeTcpNetlayer *netlayer);

int32_t pancake_endpoint_tcp_testing_connect(PancakeTcpNetlayer *netlayer,
                                             const char *host, size_t host_len,
                                             uint16_t port, uint32_t codec,
                                             size_t max_frame_bytes,
                                             PancakeTcpConn **out_conn);
int32_t pancake_endpoint_tcp_testing_listen(PancakeTcpNetlayer *netlayer,
                                            const char *host, size_t host_len,
                                            uint16_t port,
                                            PancakeTcpListener **out_listener);
int32_t pancake_endpoint_tcp_listener_port(PancakeTcpListener *listener,
                                           uint16_t *out_port);
int32_t pancake_endpoint_tcp_testing_accept(PancakeTcpListener *listener,
                                            uint32_t codec,
                                            size_t max_frame_bytes,
                                            PancakeTcpConn **out_conn);
/* Block for one whole frame, written as an owned managed frame into `out_frame`
   (release it, or hand it to `pancake_peer_feed_owned`). Returns
   PANCAKE_ERR_CLOSED on graceful EOF, PANCAKE_ERR_IO on a socket fault,
   PANCAKE_ERR_MALFORMED / PANCAKE_ERR_FRAME_TOO_LARGE for a bad frame. */
int32_t pancake_endpoint_tcp_read_frame(PancakeTcpConn *conn,
                                        PancakeManagedFrame *out_frame);
/* Write one frame's borrowed bytes and flush. */
int32_t pancake_endpoint_tcp_write_frame(PancakeTcpConn *conn,
                                         const PancakeFrame *frame);
void pancake_endpoint_tcp_conn_close(PancakeTcpConn *conn);
void pancake_endpoint_tcp_listener_close(PancakeTcpListener *listener);

#ifdef __cplusplus
}
#endif

#endif
