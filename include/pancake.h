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
#define PANCAKE_VERSION_MAJOR 0
#define PANCAKE_VERSION_MINOR 1
#define PANCAKE_VERSION_PATCH 0
/* Report the ABI version the linked library implements; any out-pointer may
   be NULL to skip that component. */
void pancake_abi_version(uint32_t *out_major, uint32_t *out_minor, uint32_t *out_patch);

/* Orientation: a PancakePeer is a sans-I/O CapTP state machine. It owns no
   socket and never blocks: feed inbound bytes with pancake_peer_recv_stream,
   advance with pancake_peer_step, and drain outbound frames with
   pancake_peer_take_outbound; sockets, threads, and scheduling stay in the
   host. examples/c/echo_peer.c is a complete in-memory conversation built
   from exactly those calls, and docs/consuming-from-c.md is the guided
   route from build to first program.

   This header is the peer-driving substrate. The nine-verb application
   surface the bindings expose (connect, listen, fetch, publish, spawn,
   send, tell, serve, close) is built above these primitives, not in them;
   bindings/README.md names that contract.

   Ownership is four rules, restated per function below. Pointers you pass
   are borrowed for that one call. Values the library fills for you to keep
   have exactly one matching pancake_*_release. Handles release through
   their constructor's family (peer, context, netlayer, connection,
   listener). Release is the only verb that frees; a *_close is a
   shutdown lever that leaves the handle alive. pancake_peer_feed_owned
   is the one call that takes ownership from you, and only on success.

   Threading: a PancakePeer is a single-owner state machine. Serialize every
   call on a given peer onto one thread or behind one lock. pancake_last_error
   is per-thread; read it on the thread that made the failing call.

   Out parameters: out structs are written only on PANCAKE_OK;
   zero-initialize or never release on failure. */

/* ── Return codes ── */
/* Success. */
#define PANCAKE_OK 0
/* A required pointer argument was NULL. */
#define PANCAKE_ERR_NULL_POINTER -1
/* reserved — returned by nothing today. */
#define PANCAKE_ERR_INVALID_HANDLE -2
/* A non-pointer argument was out of range or unparseable (a bad shape/codec discriminant, a zero frame cap, an unparseable host address). */
#define PANCAKE_ERR_INVALID_ARGUMENT -3
/* The session state machine refused the operation (a protocol violation, a resource cap, an already-closed session). */
#define PANCAKE_ERR_SESSION -4
/* Inbound bytes failed codec decode, or outbound work failed to encode. */
#define PANCAKE_ERR_CODEC -5
/* A host-internal failure (allocation, ...). */
#define PANCAKE_ERR_INTERNAL -6
/* Nothing to do right now: an empty queue, or a partial frame awaiting more bytes. */
#define PANCAKE_ERR_WOULD_BLOCK -7
/* The peer closed the stream gracefully on a frame boundary (clean EOF). */
#define PANCAKE_ERR_CLOSED -8
/* An underlying socket read/write failed; pancake_last_error carries the concrete cause. */
#define PANCAKE_ERR_IO -9
/* Inbound bytes were not a structurally valid frame. */
#define PANCAKE_ERR_MALFORMED -10
/* An inbound frame exceeded the endpoint's max_frame_bytes. */
#define PANCAKE_ERR_FRAME_TOO_LARGE -11
/* A typed poll_event_* was called but the next event is a different kind; the event is left queued — route on pancake_peer_peek_event first. */
#define PANCAKE_ERR_WRONG_EVENT -12
/* A value crossed the typed surface that the C ABI cannot carry (e.g. a handoff argument); on a typed poll the event stays queued for pancake_peer_poll_event. */
#define PANCAKE_ERR_UNSUPPORTED_VALUE -13
/* Never returned by a C ABI function: the shared code a binding surfaces when a partner breaks a promise (the break arrives as a PANCAKE_RESOLUTION_BREAK resolve event). */
#define PANCAKE_ERR_BROKEN -14
/* A well-formed lookup found nothing: pancake_locator_hint named a key absent from the locator. Distinct from _INVALID_ARGUMENT (a malformed request). */
#define PANCAKE_ERR_NOT_FOUND -15

/* ── Discriminants ── */
/* codec for pancake_peer_new_negotiated and the tcp endpoints: Syrup. The session's grammar and the endpoint's framing must carry the same value. */
#define PANCAKE_CODEC_SYRUP 0
/* codec for pancake_peer_new_negotiated and the tcp endpoints: Cap'n Proto. */
#define PANCAKE_CODEC_CAPNP 1
#define PANCAKE_FRAME_SHAPE_BYTE 0
/* Word-aligned storage: pointer 8-byte aligned, length divisible by 8; anything else is PANCAKE_ERR_INVALID_ARGUMENT. */
#define PANCAKE_FRAME_SHAPE_WORD 1
/* The no-event sentinel pancake_event_release zeroes a released event's kind to; never returned by a successful poll. */
#define PANCAKE_EVENT_NONE 0
#define PANCAKE_EVENT_DELIVER 1
#define PANCAKE_EVENT_RESOLVE 2
#define PANCAKE_EVENT_GC_EXPORT 3
#define PANCAKE_EVENT_GC_ANSWER 4
#define PANCAKE_EVENT_HANDOFF 5
#define PANCAKE_EVENT_START_SESSION 6
#define PANCAKE_EVENT_ABORT 7
#define PANCAKE_EVENT_LISTEN 8
#define PANCAKE_EVENT_GET 9
#define PANCAKE_EVENT_INDEX 10
#define PANCAKE_EVENT_UNTAG 11
#define PANCAKE_REF_NEAR 0
#define PANCAKE_REF_FAR 1
#define PANCAKE_REF_PROMISE 2
#define PANCAKE_REF_STURDY 3
#define PANCAKE_REF_BROKEN 4
/* PancakeReference.sub_kind for a near/far reference: the position names a plain object. The SUB names are their own namespace, never `kind` values. */
#define PANCAKE_REF_SUB_OBJECT 0
/* PancakeReference.sub_kind for a near/far reference: the position names a promise (desc:import-promise rather than desc:import-object). */
#define PANCAKE_REF_SUB_PROMISE 1
#define PANCAKE_ARG_INTEGER 0
#define PANCAKE_ARG_FLOAT64 1
#define PANCAKE_ARG_BOOLEAN 2
#define PANCAKE_ARG_BYTES 3
#define PANCAKE_ARG_STRING 4
#define PANCAKE_ARG_SYMBOL 5
#define PANCAKE_ARG_VOID 6
#define PANCAKE_ARG_REFERENCE 7
#define PANCAKE_ARG_LIST 8
#define PANCAKE_ARG_SET 9
#define PANCAKE_ARG_TAGGED 10
#define PANCAKE_ARG_KEYWORD 11
#define PANCAKE_ARG_BIG_INTEGER 12
#define PANCAKE_RESOLUTION_FULFILL 0
#define PANCAKE_RESOLUTION_BREAK 1
#define PANCAKE_HINTS_EMPTY_MAP 0
#define PANCAKE_HINTS_EMPTY_FALSE 1
/* captp_version for pancake_peer_new_negotiated: the authenticated v1.0 profile. */
#define PANCAKE_CAPTP_VERSION_V1_0 0
/* captp_version for pancake_peer_new_negotiated: PreSpec, the upstream OCapN prerelease profile. */
#define PANCAKE_CAPTP_VERSION_PRE_SPEC 1
/* PancakeLastAbort.domain: a codec decode/encode malformation. */
#define PANCAKE_ABORT_DOMAIN_CODEC 0
/* PancakeLastAbort.domain: the session state machine refused the operation. */
#define PANCAKE_ABORT_DOMAIN_SESSION 1
/* PancakeLastAbort.domain: a host-internal failure (allocation, ...). */
#define PANCAKE_ABORT_DOMAIN_FOREIGN 2

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
struct PancakeManagedFrame {
    /* Owned and self-releasing: release with `pancake_managed_frame_release`. */
    uint8_t *bytes;
    size_t len;
    uint32_t shape;
    PancakeReleaseFn release;
    void *private_data;
};

typedef struct PancakeEvent {
    uint32_t kind;
    /* Originating message bytes in the negotiated codec (no re-encode); release
       with `pancake_event_release`. */
    PancakeManagedFrame frame;
} PancakeEvent;

/* Release a managed frame. Idempotent; call when done. */
void pancake_managed_frame_release(PancakeManagedFrame *frame);
/* Release an event's frame and zero its kind to PANCAKE_EVENT_NONE. Idempotent. */
void pancake_event_release(PancakeEvent *event);

/* ── Allocation context ── */
/* A context owns allocation policy for a family of handles. The simple
   constructors use the library allocator; the `*_in` constructors allocate
   from a context you supply, and everything those handles own frees back
   through it. The context must outlive every handle created in it:
   releasing it while a handle is live leaves the handle pointing into
   freed memory, and its next allocation or release is undefined behavior.
   A host-backed context stores the PancakeAllocator callbacks and
   user_data as given, so both must stay valid until
   pancake_context_release.

   Host allocator contract: alloc returns memory aligned to `alignment` (a
   power of two) or NULL on failure; free receives the exact size and
   alignment the allocation was made with. There is no realloc by design:
   the library never resizes in place, so free's size always equals
   alloc's — correct even for a size-tracking host allocator. */
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
int32_t pancake_context_new(PancakeContext **out_context);
/* Create a context that routes every allocation through host callbacks.
   The callbacks must be thread-safe. */
int32_t pancake_context_new_with_allocator(const PancakeAllocator *allocator, PancakeContext **out_context);
/* Release a context after every handle created in it has been released. */
void pancake_context_release(PancakeContext *context);

/* ── Peer lifecycle and frame I/O ── */
/* Create a peer in the authenticated v1.0 negotiating state. Pair with
   pancake_peer_start_session, pump frames, then wait for
   pancake_peer_session_is_open before application traffic. */
int32_t pancake_peer_new(PancakePeer **out_peer);
/* Context-backed counterpart of pancake_peer_new. */
int32_t pancake_peer_new_in(PancakeContext *context, PancakePeer **out_peer);
/* Create a negotiating peer carrying an out-of-band negotiated profile and
   codec: captp_version is a PANCAKE_CAPTP_VERSION_* value (_V1_0, or _PRE_SPEC
   for the upstream OCapN prerelease profile), codec a PANCAKE_CODEC_* value.
   Both ends of a connection must construct with the same pair —
   op:start-session carries the profile but no codec operand, so codec
   agreement is the caller's, the same agreement the matching codec argument
   to pancake_tcp_connect / pancake_tcp_accept records.
   pancake_peer_start_session signs with the profile chosen here. */
int32_t pancake_peer_new_negotiated(uint32_t captp_version, uint32_t codec, PancakePeer **out_peer);
/* Context-backed counterpart of pancake_peer_new_negotiated. */
int32_t pancake_peer_new_negotiated_in(PancakeContext *context, uint32_t captp_version, uint32_t codec, PancakePeer **out_peer);
/* Create an already-open peer for low-level tests and harnesses that inject
   frames directly. This is a fixture surface; real OCapN connections should use
   pancake_peer_new. */
int32_t pancake_peer_new_raw_open(PancakePeer **out_peer);
/* Context-backed counterpart of pancake_peer_new_raw_open. */
int32_t pancake_peer_new_raw_open_in(PancakeContext *context, PancakePeer **out_peer);
/* Release a peer and everything it still owns: queued inbound frames,
   undrained outbound frames and events, and the session tables. Frames already
   taken out carry their own release and stay valid. NULL is a no-op. */
void pancake_peer_release(PancakePeer *peer);
/* Dispatch a borrowed frame synchronously; the caller retains ownership. */
int32_t pancake_peer_feed_borrowed(PancakePeer *peer, const PancakeFrame *frame);
/* Transfer a managed frame into the inbound queue for `pancake_peer_step`.
   Ownership always transfers once peer, frame, and frame->bytes are non-NULL:
   on failure the frame is released through its own callback and the caller's
   struct is cleared, so a late pancake_managed_frame_release is a no-op. Only
   PANCAKE_ERR_NULL_POINTER leaves the caller owning the frame. */
int32_t pancake_peer_feed_owned(PancakePeer *peer, PancakeManagedFrame *frame);
/* Frame and dispatch one inbound frame from a byte-stream buffer, writing the
   bytes consumed into `out_consumed`. PANCAKE_ERR_WOULD_BLOCK (out_consumed 0)
   means the buffer holds only part of a frame — read more and retry; an empty
   buffer (len == 0, bytes may be NULL) reports the same. The sans-I/O
   stream-input primitive: the caller owns the socket and buffer. */
int32_t pancake_peer_recv_stream(PancakePeer *peer, const uint8_t *bytes, size_t len, size_t *out_consumed);
/* Advance the peer: validate and apply queued inbound frames and encode
   pending outbound work. No I/O happens here — drain
   pancake_peer_take_outbound and pancake_peer_poll_event afterward. */
int32_t pancake_peer_step(PancakePeer *peer);
/* Take the next outbound frame as an owned managed frame, or
   PANCAKE_ERR_WOULD_BLOCK when the queue is empty. On PANCAKE_ERR_INTERNAL the
   dequeued frame could not be wrapped for C and was freed; it is not
   retrievable. */
int32_t pancake_peer_take_outbound(PancakePeer *peer, PancakeManagedFrame *out_frame);
/* Take the next event (opaque frame in the negotiated codec), or
   PANCAKE_ERR_WOULD_BLOCK when none is queued. */
int32_t pancake_peer_poll_event(PancakePeer *peer, PancakeEvent *out_event);
/* The codec the peer's session speaks, as a PANCAKE_CODEC_* value. Event and
   outbound frames are encoded in it, so a consumer that drains an event
   through the opaque pancake_peer_poll_event knows how to read the raw frame. */
int32_t pancake_peer_codec(const PancakePeer *peer, uint32_t *out_codec);

/* ── Capability registration ── */
/* The well-known bootstrap export position every OCapN peer answers `fetch`
   on. Use this name instead of re-deriving the magic 0. */
#define PANCAKE_BOOTSTRAP_POSITION 0
/* Expose a local capability behind `swissnum` for inbound bootstrap-fetch;
   writes the allocated export position. `swissnum` is borrowed. */
int32_t pancake_peer_register_bootstrap_cap(PancakePeer *peer, const uint8_t *swissnum, size_t swissnum_len, uint64_t *out_export_position);
/* Ask the partner's bootstrap object for the capability published behind
   `name`: registers the bootstrap import if needed, allocates the answer from
   the session's one answer allocator, and queues the canonical fetch deliver.
   The question id lands in `out_answer`; the partner's resolution arrives as a
   PANCAKE_EVENT_RESOLVE keyed on it. `name` is borrowed for the call. */
int32_t pancake_peer_send_bootstrap_fetch(PancakePeer *peer, const uint8_t *name, size_t name_len, uint64_t *out_answer);
/* Register a local export position so deliveries to it surface as events. */
int32_t pancake_peer_register_export(PancakePeer *peer, uint64_t export_position);
/* Allocate the next free export position from the session's one export
   allocator and REGISTER it (unlike pancake_peer_next_answer, which only
   allocates), writing it into `out_export_position`. A binding's `spawn` must
   take its position here: the same counter mints bootstrap and resolver
   exports, so a privately-counted position would eventually alias one. */
int32_t pancake_peer_next_export(PancakePeer *peer, uint64_t *out_export_position);
/* Allocate the next outbound answer position — the question id for a
   send_deliver that wants a reply — writing it into `out_answer`. A binding's
   eventual-send must take its answer here: the same counter backs every
   outbound question on the session, so a privately-counted position would
   eventually alias a live answer and route the partner's op:resolve to the
   wrong caller. */
int32_t pancake_peer_next_answer(PancakePeer *peer, uint64_t *out_answer);

typedef struct PancakeLastAbort {
    /* a PANCAKE_ABORT_DOMAIN_* value */
    uint32_t domain;
    /* nonzero when an op:abort kind was projected */
    uint32_t has_kind;
    /* wire name of the abort kind (process-static) */
    const uint8_t *kind_name;
    size_t kind_name_len;
    /* static diagnostic */
    const uint8_t *message;
    size_t message_len;
    /* originating error name (process-static) */
    const uint8_t *error_name;
    size_t error_name_len;
} PancakeLastAbort;

/* Read the typed cause of the peer's most recent local dispatch failure into
   `out` (the counterpart of the Zig `Peer.lastAbort`). PANCAKE_OK when one was
   recorded, PANCAKE_ERR_WOULD_BLOCK when none. The string views are
   process-static — read them, never free them. The per-feed return code names
   the failure family; this names the member. */
int32_t pancake_peer_last_abort(PancakePeer *peer, PancakeLastAbort *out);
/* Track a partner-hosted import this peer holds, so a _FAR send_deliver to it
   is admitted (e.g. the bootstrap import). */
int32_t pancake_peer_register_import(PancakePeer *peer, uint64_t import_position);
/* Sign and queue op:start-session for a negotiating peer. Derives the session
   key from the 32-byte `seed`, signs the canonical location bytes for the
   (transport, designator) locator, and enqueues the handshake frame. `hints`
   selects the wire spelling of the locator's empty hints —
   PANCAKE_HINTS_EMPTY_MAP encodes {}, PANCAKE_HINTS_EMPTY_FALSE encodes #f
   (the spelling Goblins emits) — any other value is refused with
   PANCAKE_ERR_INVALID_ARGUMENT. For a Goblins target use profile v1.0, Syrup,
   transport "tcp", and PANCAKE_HINTS_EMPTY_FALSE. The handshake speaks the
   profile the peer was constructed with; the peer already knows it, so this
   call never re-takes it. `seed` is borrowed and `seed_len` must be 32;
   anything else is refused with PANCAKE_ERR_INVALID_ARGUMENT. */
int32_t pancake_peer_start_session(PancakePeer *peer, const uint8_t *transport, size_t transport_len, const uint8_t *designator, size_t designator_len, uint32_t hints, const uint8_t *seed, size_t seed_len);
/* Whether the session has completed the handshake and is open for traffic:
   1 when open, 0 when not. A NULL peer has no open session, so it reports 0;
   the result is never negative, so a plain `if` on it reads correctly in C. */
int32_t pancake_peer_session_is_open(PancakePeer *peer);

/* ── Typed OCapN driving surface ── */
/* Construct a call and read a delivery as structured values without authoring
   a codec. Send borrows the C structs for the call (the clone owns the copy);
   receive projects views aliasing an internal arena, released by `*_release`.
   These struct layouts are frozen ABI (ADR-0031).

   PancakeArgument field mapping by kind: _BYTES, _STRING, _SYMBOL, and
   _KEYWORD carry their payload in `bytes`/`bytes_len`. _LIST and _SET carry
   their elements in `items`/`items_len`. _TAGGED carries the tag in
   `bytes`/`bytes_len` and the value list in `items`/`items_len`.
   _BIG_INTEGER carries the canonical decimal magnitude in `bytes`/`bytes_len`
   (ASCII digits, no leading zero) and the sign in `boolean` (1 = negative);
   a magnitude that fits int64_t belongs in _INTEGER and is refused here. */
typedef struct PancakeReference {
    /* _NEAR export position, _FAR import position, or _PROMISE answer position. */
    uint32_t kind;
    /* object/promise for near/far */
    uint32_t sub_kind;
    uint64_t id;
} PancakeReference;

typedef struct PancakeArgument {
    /* selects the live field */
    uint32_t kind;
    /* _BOOLEAN value; also the _BIG_INTEGER sign (1 = negative) */
    uint32_t boolean;
    int64_t integer;
    double float64;
    /* _BYTES/_STRING/_SYMBOL/_KEYWORD payload; a _TAGGED's tag; a _BIG_INTEGER's digits */
    const uint8_t *bytes;
    size_t bytes_len;
    PancakeReference reference;
    /* a _LIST's or _SET's elements; a _TAGGED's value list */
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
    /* release with pancake_deliver_release */
    void *owner;
} PancakeDeliver;

typedef struct PancakeResolve {
    uint64_t answer;
    /* fulfill or break */
    uint32_t resolution_kind;
    PancakeArgument fulfill;
    const uint8_t *break_message;
    size_t break_message_len;
    /* release with pancake_resolve_release */
    void *owner;
} PancakeResolve;

/* The kind of the next event without consuming it: a positive PANCAKE_EVENT_*
   or PANCAKE_ERR_WOULD_BLOCK. */
int32_t pancake_peer_peek_event(PancakePeer *peer);
/* Construct and queue an op:deliver. When `has_answer` is nonzero the call
   expects a reply on `answer`, which must come from pancake_peer_next_answer
   on this same peer (a privately-counted id eventually aliases a live answer).
   When `has_answer` is zero, `answer` is ignored. */
int32_t pancake_peer_send_deliver(PancakePeer *peer, const PancakeReference *target, const PancakeArgument *args, size_t args_len, uint32_t has_answer, uint64_t answer);
/* Construct and queue an op:resolve settling `answer`. */
int32_t pancake_peer_send_resolve(PancakePeer *peer, uint64_t answer, uint32_t resolution_kind, const PancakeArgument *fulfill, const uint8_t *break_message, size_t break_message_len);
/* Construct and queue an op:gc-export releasing wire-delta counts on imports
   this peer holds: positions[i] is released by deltas[i], for `len` parallel
   entries (both borrowed; len == 0 is PANCAKE_ERR_INVALID_ARGUMENT). */
int32_t pancake_peer_send_gc_export(PancakePeer *peer, const uint64_t *positions, const uint64_t *deltas, size_t len);
/* Construct and queue an op:gc-answer releasing the answer position this peer
   no longer needs. */
int32_t pancake_peer_send_gc_answer(PancakePeer *peer, uint64_t answer);
/* Take the next event as a structured deliver, or PANCAKE_ERR_WRONG_EVENT /
   PANCAKE_ERR_WOULD_BLOCK. PANCAKE_ERR_WRONG_EVENT, PANCAKE_ERR_UNSUPPORTED_VALUE,
   and decode failures leave the event queued; drain it with
   pancake_peer_poll_event or the queue never advances (pancake_peer_codec names
   the raw frame's codec). Release with the matching *_release. */
int32_t pancake_peer_poll_event_deliver(PancakePeer *peer, PancakeDeliver *out);
/* Take the next event as a structured resolve; same routing contract as
   pancake_peer_poll_event_deliver, including the leave-queued fallback to
   pancake_peer_poll_event on PANCAKE_ERR_UNSUPPORTED_VALUE and decode failures. */
int32_t pancake_peer_poll_event_resolve(PancakePeer *peer, PancakeResolve *out);
/* Release a deliver projection; the `args` views aliasing its arena die with
   it. Idempotent: the struct is cleared, so releasing again (or a
   zero-initialized struct) is a no-op. */
void pancake_deliver_release(PancakeDeliver *deliver);
/* Release a resolve projection; the `fulfill` and `break_message` views
   aliasing its arena die with it. Idempotent: the struct is cleared, so
   releasing again (or a zero-initialized struct) is a no-op. */
void pancake_resolve_release(PancakeResolve *resolve);

/* ── Per-thread last error ── */
/* Copy the calling thread's last error into `out_buf`. Copies at most cap - 1
   bytes and always NUL-terminates when cap > 0. Returns the full message
   length; to receive the whole message pass a buffer of that length plus one.
   out_buf == NULL or cap == 0 queries the length. */
size_t pancake_last_error(uint8_t *out_buf, size_t cap);
/* Clear the calling thread's last error slot. */
void pancake_clear_last_error(void);

/* ── Blocking TCP endpoints ── */
/* The host owns the peer and shuttles whole frames. The netlayer owns the I/O
   backend; create it, make connections/listeners from it, then release it
   after every endpoint made from it is released. Blocking, cleartext TCP; no
   TLS. */
typedef struct PancakeTcpNetlayer PancakeTcpNetlayer;
typedef struct PancakeTcpConn PancakeTcpConn;
typedef struct PancakeTcpListener PancakeTcpListener;
/* Create the netlayer handle that owns the blocking I/O backend, allocating
   through the library allocator. Release with pancake_tcp_netlayer_release
   after releasing every endpoint made from it. */
int32_t pancake_tcp_netlayer_new(PancakeTcpNetlayer **out_netlayer);
/* Create a netlayer whose backend and per-connection buffers allocate through
   `context`. */
int32_t pancake_tcp_netlayer_new_in(PancakeContext *context, PancakeTcpNetlayer **out_netlayer);
/* Release the netlayer and its I/O backend. Every connection and listener
   made from it must already be released. */
void pancake_tcp_netlayer_release(PancakeTcpNetlayer *netlayer);
/* Connect to host:port and return an owned connection framing on `codec`,
   refusing inbound frames over max_frame_bytes. Blocking; `host` is borrowed.
   PANCAKE_ERR_INVALID_ARGUMENT for a bad codec, a zero frame cap, or an
   unparseable address; PANCAKE_ERR_IO (see pancake_last_error) when the dial
   fails. Release with pancake_tcp_conn_release. */
int32_t pancake_tcp_connect(PancakeTcpNetlayer *netlayer, const uint8_t *host, size_t host_len, uint16_t port, uint32_t codec, size_t max_frame_bytes, PancakeTcpConn **out_conn);
/* Bind and listen on host:port (port 0 picks an OS-chosen port; read it back
   with pancake_tcp_listener_port). Release with pancake_tcp_listener_release. */
int32_t pancake_tcp_listen(PancakeTcpNetlayer *netlayer, const uint8_t *host, size_t host_len, uint16_t port, PancakeTcpListener **out_listener);
/* The OS-resolved local port of a listener (useful after binding to port 0). */
int32_t pancake_tcp_listener_port(PancakeTcpListener *listener, uint16_t *out_port);
/* Block until a client connects, returning an owned connection framing on
   `codec`. Same argument and release contract as pancake_tcp_connect. */
int32_t pancake_tcp_accept(PancakeTcpListener *listener, uint32_t codec, size_t max_frame_bytes, PancakeTcpConn **out_conn);
/* Block for one whole frame as an owned managed frame. Returns PANCAKE_ERR_CLOSED
   on graceful EOF, PANCAKE_ERR_IO on a socket fault. */
int32_t pancake_tcp_conn_read_frame(PancakeTcpConn *conn, PancakeManagedFrame *out_frame);
/* Write one frame's borrowed bytes and flush. */
int32_t pancake_tcp_conn_write_frame(PancakeTcpConn *conn, const PancakeFrame *frame);
/* Close the connection and free the handle; do not use `conn` afterward. */
void pancake_tcp_conn_release(PancakeTcpConn *conn);
/* Close the listener and free the handle; do not use `listener` afterward. */
void pancake_tcp_listener_release(PancakeTcpListener *listener);

/* ── In-process endpoints ── */
/* The socket-free sibling of the TCP endpoints: two peers in one process
   wired by in-process pipes, no kernel transport and no file descriptors.
   Same host-owns-the-peer frame shuttle and same netlayer lifecycle — create
   the netlayer, make connections/listeners from it, release them, then release
   it — but a listener binds to a string designator (any opaque token, not a
   host:port) and a dialer names that designator. This is the path a binding's
   smoke test dials to run a full OCapN conversation without touching a
   socket. Blocking; in-process only. */
typedef struct PancakeInprocNetlayer PancakeInprocNetlayer;
typedef struct PancakeInprocConn PancakeInprocConn;
typedef struct PancakeInprocListener PancakeInprocListener;
/* Create the in-process netlayer handle that owns the switchboard and its I/O
   backend, allocating through the library allocator. Release with
   pancake_inproc_netlayer_release after releasing every endpoint made from it. */
int32_t pancake_inproc_netlayer_new(PancakeInprocNetlayer **out_netlayer);
/* Create an in-process netlayer whose switchboard, backend, and per-connection
   buffers allocate through `context`. */
int32_t pancake_inproc_netlayer_new_in(PancakeContext *context, PancakeInprocNetlayer **out_netlayer);
/* Release the in-process netlayer. Every connection and listener made from it
   must already be released. */
void pancake_inproc_netlayer_release(PancakeInprocNetlayer *netlayer);
/* Dial the listener bound at `designator` and return an owned connection
   framing on `codec`, refusing inbound frames over max_frame_bytes.
   `designator` is borrowed. PANCAKE_ERR_INVALID_ARGUMENT for a bad codec or a
   zero frame cap; PANCAKE_ERR_IO (see pancake_last_error) when no listener is
   bound there. Release with pancake_inproc_conn_release. */
int32_t pancake_inproc_connect(PancakeInprocNetlayer *netlayer, const uint8_t *designator, size_t designator_len, uint32_t codec, size_t max_frame_bytes, PancakeInprocConn **out_conn);
/* Bind an in-process listener on `designator` (any opaque token; borrowed).
   PANCAKE_ERR_INVALID_ARGUMENT for an empty or already-bound designator. Release
   with pancake_inproc_listener_release. */
int32_t pancake_inproc_listen(PancakeInprocNetlayer *netlayer, const uint8_t *designator, size_t designator_len, PancakeInprocListener **out_listener);
/* Block until a dialer connects, returning an owned connection framing on
   `codec`. Same argument and release contract as pancake_inproc_connect. */
int32_t pancake_inproc_accept(PancakeInprocListener *listener, uint32_t codec, size_t max_frame_bytes, PancakeInprocConn **out_conn);
/* Block for one whole frame as an owned managed frame. Returns
   PANCAKE_ERR_CLOSED on graceful EOF. */
int32_t pancake_inproc_conn_read_frame(PancakeInprocConn *conn, PancakeManagedFrame *out_frame);
/* Write one frame's borrowed bytes into the partner's pipe. */
int32_t pancake_inproc_conn_write_frame(PancakeInprocConn *conn, const PancakeFrame *frame);
/* Close the connection and free the handle; do not use `conn` afterward. */
void pancake_inproc_conn_release(PancakeInprocConn *conn);
/* Close the listener and free the handle; do not use `listener` afterward. */
void pancake_inproc_listener_release(PancakeInprocListener *listener);

/* ── OCapN locator URIs ── */
/* The ocapn://<designator>.<transport>[/s/<swiss>][?hints] bootstrap form a
   peer or sturdyref address travels in — core OCapN vocabulary, the one
   place the grammar lives so no consumer hand-rolls a percent codec.
   Parsing and formatting are separate from dialing: parse a URI, read its
   transport, then call the matching transport's connect (pancake_tcp_connect,
   the iroh superset's connect, ...). The pancake_uri_* verbs do the
   string<->structure conversion; a parse returns one owned PancakeLocator
   read through the pancake_locator_* accessors. One handle carries both a
   peer and a sturdyref — a sturdyref is a peer locator plus a swissnum — so
   a parsed peer reports a zero-length swissnum. Accessor views alias the
   handle and are valid until pancake_locator_release. Locator handles
   allocate through the library allocator; there is no context-backed
   parse, so a context cannot account for them. */
typedef struct PancakeLocator PancakeLocator;
/* Parse an ocapn:// peer URI into an owned locator handle; `uri` is borrowed.
   PANCAKE_ERR_INVALID_ARGUMENT (see pancake_last_error) for a malformed URI.
   Release with pancake_locator_release. */
int32_t pancake_uri_parse_peer(const uint8_t *uri, size_t uri_len, PancakeLocator **out_locator);
/* Parse an ocapn://.../s/<swiss> sturdyref URI into an owned locator handle
   carrying its swissnum. Same borrow, error, and release contract as
   pancake_uri_parse_peer. */
int32_t pancake_uri_parse_sturdyref(const uint8_t *uri, size_t uri_len, PancakeLocator **out_locator);
/* Format a peer locator as an ocapn:// URI into `out`. Hints are parallel
   key/value string arrays (hint_keys[i]/hint_key_lens[i] and the val pair) of
   hint_count entries; all inputs are borrowed. `out_len` always receives the
   full URI length; a buffer too small or NULL is PANCAKE_ERR_INVALID_ARGUMENT
   with the length still reported, so size with out_len then retry. */
int32_t pancake_uri_format_peer(const uint8_t *transport, size_t transport_len, const uint8_t *designator, size_t designator_len, const uint8_t **hint_keys, const size_t *hint_key_lens, const uint8_t **hint_vals, const size_t *hint_val_lens, size_t hint_count, uint8_t *out, size_t cap, size_t *out_len);
/* Format a sturdyref locator (peer plus swissnum) as an ocapn://.../s/<swiss>
   URI. Same hint-array and buffer contract as pancake_uri_format_peer;
   `swissnum` is borrowed. */
int32_t pancake_uri_format_sturdyref(const uint8_t *transport, size_t transport_len, const uint8_t *designator, size_t designator_len, const uint8_t *swissnum, size_t swissnum_len, const uint8_t **hint_keys, const size_t *hint_key_lens, const uint8_t **hint_vals, const size_t *hint_val_lens, size_t hint_count, uint8_t *out, size_t cap, size_t *out_len);
/* Borrow the locator's transport ("tcp", "iroh", "inproc", ...): the field a
   dispatcher reads to pick a netlayer. The view aliases the handle until
   release. */
int32_t pancake_locator_transport(PancakeLocator *loc, const uint8_t **out_ptr, size_t *out_len);
/* Borrow the locator's designator — the transport-specific address (a TCP
   host:port string, an iroh node id, an inproc designator). */
int32_t pancake_locator_designator(PancakeLocator *loc, const uint8_t **out_ptr, size_t *out_len);
/* Borrow the locator's swissnum: zero-length (NULL pointer) for a peer URI, the
   swiss bytes for a sturdyref. The discriminator a C caller reads instead of a
   second handle type. */
int32_t pancake_locator_swissnum(PancakeLocator *loc, const uint8_t **out_ptr, size_t *out_len);
/* Borrow the value of the hint named by `key` (e.g. "direct-addresses").
   PANCAKE_ERR_NOT_FOUND when no hint carries that key. `key` is borrowed. */
int32_t pancake_locator_hint(PancakeLocator *loc, const uint8_t *key, size_t key_len, const uint8_t **out_ptr, size_t *out_len);
/* The number of hints on the locator, for index enumeration with
   pancake_locator_hint_at. */
int32_t pancake_locator_hint_count(PancakeLocator *loc, size_t *out_count);
/* Borrow the key and value of hint `idx` (0-based). PANCAKE_ERR_INVALID_ARGUMENT
   when idx is out of range. Both views alias the handle until release. */
int32_t pancake_locator_hint_at(PancakeLocator *loc, size_t idx, const uint8_t **out_key, size_t *out_key_len, const uint8_t **out_val, size_t *out_val_len);
/* Release a locator handle and the parse allocations it owns. NULL is a no-op. */
void pancake_locator_release(PancakeLocator *loc);

#ifdef __cplusplus
}
#endif

#endif
