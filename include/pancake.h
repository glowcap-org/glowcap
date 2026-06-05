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
#define PANCAKE_ERR_SESSION -4
#define PANCAKE_ERR_CODEC -5
#define PANCAKE_ERR_INTERNAL -6
#define PANCAKE_ERR_WOULD_BLOCK -7

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

#ifdef __cplusplus
}
#endif

#endif
