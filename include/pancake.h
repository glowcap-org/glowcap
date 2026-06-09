/* Generated from src/c_abi/mod.zig by tools/header_gen.zig.
   Do not edit by hand: run `zig build gen-header`. Struct layouts,
   constant values, and function signatures are reflected from the Zig
   source, so this header cannot drift from the implementation. */
#ifndef PANCAKE_H
#define PANCAKE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
/* ABI version. While MAJOR is 0 the ABI is unstable: any release may change
   symbols, layouts, or return codes. These macros are the version the header
   was compiled against; `pancake_abi_version` reports the linked library's. */
#define PANCAKE_VERSION_MAJOR 0u
#define PANCAKE_VERSION_MINOR 1u
#define PANCAKE_VERSION_PATCH 0u
/* Report the ABI version the linked library implements; any out-pointer may
   be NULL to skip that component. */
void pancake_abi_version(uint32_t *out_major, uint32_t *out_minor, uint32_t *out_patch);

/* ── Return codes ── */
#define PANCAKE_OK 0
#define PANCAKE_ERR_NULL_POINTER -1
#define PANCAKE_ERR_INVALID_HANDLE -2
#define PANCAKE_ERR_INVALID_ARGUMENT -3
#define PANCAKE_ERR_SESSION -4
#define PANCAKE_ERR_CODEC -5
#define PANCAKE_ERR_INTERNAL -6
#define PANCAKE_ERR_WOULD_BLOCK -7
#define PANCAKE_ERR_CLOSED -8
#define PANCAKE_ERR_IO -9
#define PANCAKE_ERR_MALFORMED -10
#define PANCAKE_ERR_FRAME_TOO_LARGE -11
#define PANCAKE_ERR_WRONG_EVENT -12
#define PANCAKE_ERR_UNSUPPORTED_VALUE -13
#define PANCAKE_ERR_BROKEN -14

/* ── Discriminants ── */
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
#define PANCAKE_REF_NEAR 0u
#define PANCAKE_REF_FAR 1u
#define PANCAKE_REF_PROMISE 2u
#define PANCAKE_REF_STURDY 3u
#define PANCAKE_REF_BROKEN 4u
#define PANCAKE_REF_OBJECT 0u
#define PANCAKE_REF_PROMISE_KIND 1u
#define PANCAKE_ARG_INTEGER 0u
#define PANCAKE_ARG_FLOAT64 1u
#define PANCAKE_ARG_BOOLEAN 2u
#define PANCAKE_ARG_BYTES 3u
#define PANCAKE_ARG_STRING 4u
#define PANCAKE_ARG_SYMBOL 5u
#define PANCAKE_ARG_VOID 6u
#define PANCAKE_ARG_REFERENCE 7u
#define PANCAKE_ARG_LIST 8u
#define PANCAKE_ARG_SET 9u
#define PANCAKE_ARG_TAGGED 10u
#define PANCAKE_ARG_KEYWORD 11u
#define PANCAKE_RESOLUTION_FULFILL 0u
#define PANCAKE_RESOLUTION_BREAK 1u

/* ── Frames and events ── */

typedef struct PancakeFrame {
    /* Borrowed for one call; the caller keeps owning the bytes. */
    const uint8_t *bytes;
    size_t len;
    uint32_t shape;
} PancakeFrame;

typedef struct PancakeManagedFrame PancakeManagedFrame;
typedef struct PancakePeer PancakePeer;
typedef void (*PancakeReleaseFn)(PancakeManagedFrame *frame);
typedef struct PancakeManagedFrame {
    /* Owned and self-releasing: call `pancake_managed_frame_release` exactly
       once (repeated release is safe). */
    uint8_t *bytes;
    size_t len;
    uint32_t shape;
    PancakeReleaseFn release;
    void *private_data;
} PancakeManagedFrame;

typedef struct PancakeEvent {
    uint32_t kind;
    /* Originating message bytes in the negotiated codec (no re-encode); release
       with `pancake_event_release`. */
    PancakeManagedFrame frame;
} PancakeEvent;

void pancake_managed_frame_release(PancakeManagedFrame *frame);
void pancake_event_release(PancakeEvent *event);

/* ── Allocation context ── */
/* A context owns allocation policy for a family of handles. The simple
   constructors use the library allocator; the `*_in` constructors allocate
   from a context you supply, and everything those handles own frees back
   through it. The context must outlive every handle created in it. */
typedef struct PancakeContext PancakeContext;
typedef void *(*PancakeAllocFn)(void *user_data, size_t size, size_t alignment);
typedef void (*PancakeFreeFn)(void *user_data, void *ptr, size_t size, size_t alignment);
typedef struct PancakeAllocator {
    /* required */
    PancakeAllocFn alloc;
    /* required */
    PancakeFreeFn free;
    /* optional; passed back to every callback */
    void *user_data;
} PancakeAllocator;

/* Create a context backed by the library-owned allocator. */
int32_t pancake_context_new_default(PancakeContext **out_context);
/* Create a context that routes every allocation through host callbacks.
   The callbacks must be thread-safe. */
int32_t pancake_context_new_with_allocator(const PancakeAllocator *allocator, PancakeContext **out_context);
/* Release a context after every handle created in it has been released. */
void pancake_context_release(PancakeContext *context);

/* ── Peer lifecycle and frame I/O ── */
int32_t pancake_peer_new(PancakePeer **out_peer);
/* Create a peer whose allocations route through `context`. */
int32_t pancake_peer_new_in(PancakeContext *context, PancakePeer **out_peer);
/* Create a peer that begins negotiating, awaiting the keyed op:start-session
   handshake. Pair with pancake_peer_start_session_keyed to talk to a peer that
   requires the handshake (a real Goblins vat). */
int32_t pancake_peer_new_negotiating(PancakePeer **out_peer);
/* Negotiating counterpart of pancake_peer_new_in. */
int32_t pancake_peer_new_negotiating_in(PancakeContext *context, PancakePeer **out_peer);
void pancake_peer_release(PancakePeer *peer);
/* Dispatch a borrowed frame synchronously; the caller retains ownership. */
int32_t pancake_peer_feed_borrowed(PancakePeer *peer, const PancakeFrame *frame);
/* Transfer a managed frame into the inbound queue for `pancake_peer_step`;
   on success the caller's descriptor is cleared. */
int32_t pancake_peer_feed_owned(PancakePeer *peer, PancakeManagedFrame *frame);
/* Frame and dispatch one inbound frame from a byte-stream buffer, writing the
   bytes consumed into `out_consumed`. PANCAKE_ERR_WOULD_BLOCK (out_consumed 0)
   means the buffer holds only part of a frame — read more and retry. The
   sans-I/O stream-input primitive: the caller owns the socket and buffer. */
int32_t pancake_peer_recv_stream(PancakePeer *peer, const uint8_t *bytes, size_t len, size_t *out_consumed);
int32_t pancake_peer_step(PancakePeer *peer);
/* Take the next outbound frame as an owned managed frame, or
   PANCAKE_ERR_WOULD_BLOCK when the queue is empty. */
int32_t pancake_peer_take_outbound(PancakePeer *peer, PancakeManagedFrame *out_frame);
/* Take the next event (opaque frame in the negotiated codec), or
   PANCAKE_ERR_WOULD_BLOCK when none is queued. */
int32_t pancake_peer_poll_event(PancakePeer *peer, PancakeEvent *out_event);

/* ── Capability registration ── */
/* Expose a local capability behind `swissnum` for inbound bootstrap-fetch;
   writes the allocated export id. `swissnum` is borrowed. */
int32_t pancake_peer_register_bootstrap_cap(PancakePeer *peer, const uint8_t *swissnum, size_t swissnum_len, uint64_t *out_export_id);
/* Register a local export position so deliveries to it surface as events. */
int32_t pancake_peer_register_export(PancakePeer *peer, uint64_t export_id);
/* Track a partner-hosted import this peer holds, so a _FAR send_deliver to it
   is admitted (e.g. the bootstrap import). */
int32_t pancake_peer_register_import(PancakePeer *peer, uint64_t import_id);
/* Sign and queue a keyed op:start-session for a negotiating peer. Derives the
   session key from the 32-byte `seed`, signs the canonical location bytes for
   the (transport, designator) locator, and enqueues the handshake frame. For a
   Goblins partner use transport "tcp" with `hints_empty_false` nonzero.
   `captp_version` is 0 for v1.0 or 1 for pre-spec. `seed` is borrowed. */
int32_t pancake_peer_start_session_keyed(PancakePeer *peer, uint32_t captp_version, const uint8_t *transport, size_t transport_len, const uint8_t *designator, size_t designator_len, uint32_t hints_empty_false, const uint8_t *seed);
/* Whether the session has completed the handshake and is open for traffic:
   1 when open, 0 when not, negative PANCAKE_ERR_* for a null peer. */
int32_t pancake_peer_session_is_open(PancakePeer *peer);

/* ── Typed OCapN driving surface ── */
/* Construct a call and read a delivery as structured values without authoring
   a codec. Send borrows the C structs for the call (the clone owns the copy);
   receive projects views aliasing an internal arena, released by `*_free`.
   These struct layouts are frozen ABI (ADR-0031). */
typedef struct PancakeReference {
    /* _NEAR export id, _FAR import id, or _PROMISE answer id. */
    uint32_t kind;
    /* object/promise for near/far */
    uint32_t sub_kind;
    uint64_t id;
} PancakeReference;

typedef struct PancakeArgument {
    /* selects the live field */
    uint32_t kind;
    uint32_t boolean;
    int64_t integer;
    double float64;
    /* _BYTES/_STRING/_SYMBOL */
    const uint8_t *bytes;
    size_t bytes_len;
    PancakeReference reference;
    /* a _LIST's children */
    const struct PancakeArgument *items;
    size_t items_len;
} PancakeArgument;

typedef struct PancakeDeliver {
    PancakeReference target;
    /* aliases an internal arena */
    const PancakeArgument *args;
    size_t args_len;
    uint32_t has_answer;
    uint64_t answer;
    /* release with pancake_deliver_free */
    void *owner;
} PancakeDeliver;

typedef struct PancakeResolve {
    uint64_t answer;
    /* fulfill or break */
    uint32_t resolution_kind;
    PancakeArgument fulfill;
    const uint8_t *break_message;
    size_t break_message_len;
    /* release with pancake_resolve_free */
    void *owner;
} PancakeResolve;

/* The kind of the next event without consuming it: a positive PANCAKE_EVENT_*
   or PANCAKE_ERR_WOULD_BLOCK. */
int32_t pancake_peer_peek_event(PancakePeer *peer);
/* Construct and queue an op:deliver. When `has_answer` is nonzero the call
   expects a reply on `answer`. */
int32_t pancake_peer_send_deliver(PancakePeer *peer, const PancakeReference *target, const PancakeArgument *args, size_t args_len, uint32_t has_answer, uint64_t answer);
/* Construct and queue an op:resolve settling `answer`. */
int32_t pancake_peer_send_resolve(PancakePeer *peer, uint64_t answer, uint32_t resolution_kind, const PancakeArgument *fulfill, const uint8_t *break_message, size_t break_message_len);
/* Take the next event as a structured deliver, or PANCAKE_ERR_WRONG_EVENT
   (left queued) / PANCAKE_ERR_WOULD_BLOCK. Release with the matching *_free. */
int32_t pancake_peer_poll_event_deliver(PancakePeer *peer, PancakeDeliver *out);
int32_t pancake_peer_poll_event_resolve(PancakePeer *peer, PancakeResolve *out);
void pancake_deliver_free(PancakeDeliver *deliver);
void pancake_resolve_free(PancakeResolve *resolve);

/* ── Per-thread last error ── */
/* Copy the calling thread's last error into `out_buf` (NUL-terminated if it
   fits), returning the full length. `out_buf` may be NULL to query the length. */
size_t pancake_last_error(uint8_t *out_buf, size_t cap);
void pancake_clear_last_error();

/* ── Blocking TCP endpoints (tcp-testing-only) ── */
/* The host owns the peer and shuttles whole frames. The netlayer owns the I/O
   backend; create it, make connections/listeners from it, then release it
   after every endpoint made from it is closed. Cleartext, loopback-grade. */
typedef struct PancakeTcpNetlayer PancakeTcpNetlayer;
typedef struct PancakeTcpConn PancakeTcpConn;
typedef struct PancakeTcpListener PancakeTcpListener;
int32_t pancake_tcp_netlayer_new(PancakeTcpNetlayer **out_netlayer);
/* Create a netlayer whose backend and per-connection buffers allocate through
   `context`. */
int32_t pancake_tcp_netlayer_new_in(PancakeContext *context, PancakeTcpNetlayer **out_netlayer);
void pancake_tcp_netlayer_release(PancakeTcpNetlayer *netlayer);
int32_t pancake_endpoint_tcp_testing_connect(PancakeTcpNetlayer *netlayer, const uint8_t *host, size_t host_len, uint16_t port, uint32_t codec, size_t max_frame_bytes, PancakeTcpConn **out_conn);
int32_t pancake_endpoint_tcp_testing_listen(PancakeTcpNetlayer *netlayer, const uint8_t *host, size_t host_len, uint16_t port, PancakeTcpListener **out_listener);
int32_t pancake_endpoint_tcp_listener_port(PancakeTcpListener *listener, uint16_t *out_port);
int32_t pancake_endpoint_tcp_testing_accept(PancakeTcpListener *listener, uint32_t codec, size_t max_frame_bytes, PancakeTcpConn **out_conn);
/* Block for one whole frame as an owned managed frame. Returns PANCAKE_ERR_CLOSED
   on graceful EOF, PANCAKE_ERR_IO on a socket fault. */
int32_t pancake_endpoint_tcp_read_frame(PancakeTcpConn *conn, PancakeManagedFrame *out_frame);
/* Write one frame's borrowed bytes and flush. */
int32_t pancake_endpoint_tcp_write_frame(PancakeTcpConn *conn, const PancakeFrame *frame);
void pancake_endpoint_tcp_conn_close(PancakeTcpConn *conn);
void pancake_endpoint_tcp_listener_close(PancakeTcpListener *listener);

#ifdef __cplusplus
}
#endif

#endif
