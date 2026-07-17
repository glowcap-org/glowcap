/* Generated from src/c_abi/ocapn/mod.zig by tools/gen/header/ocapn.zig.
   Do not edit by hand: run `zig build gen-header-ocapn`. Struct layouts,
   constant values, and function signatures are reflected from the Zig
   source, so this header cannot drift from the implementation.

   libpancake_ocapn is the sans-io OCapN base archive: the shared C ABI
   vocabulary (frame/context types, return codes, the codec selector)
   plus the peer-driving and locator-URI families. Multi-session
   CapTP product work uses pancake_host_* in pancake_driver.h. The
   transports ship their own archives and headers —
   pancake_net_transport_tcp.h, pancake_net_transport_inproc.h,
   pancake_net_transport_iroh.h — each of which #includes this one for
   the shared types (ADR-0059). */
#ifndef PANCAKE_OCAPN_H
#define PANCAKE_OCAPN_H

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
   take the next application event with pancake_peer_next_event (it drives
   the engine to idle itself), and drain outbound frames with
   pancake_peer_take_outbound; sockets, threads, and scheduling stay in the
   host. examples/c/echo_peer.c is a complete in-memory conversation built
   from exactly those calls, and docs/consuming-from-c.md is the guided
   route from build to first program.

   There are two inbound models; pick one per loop and do not mix them. One
   dispatches synchronously as bytes arrive: pancake_peer_recv_borrowed takes
   one whole borrowed frame, and pancake_peer_recv_stream takes a byte-stream
   buffer. The other transfers owned frames into the queue with
   pancake_peer_feed_owned and applies them in a later pancake_peer_step.
   Either way, pancake_peer_step is what encodes and drains outbound work.

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
   is the one call that takes ownership from you: it takes the frame on
   every outcome except a NULL-pointer refusal, and on failure it releases
   the frame for you (see its own contract below).

   Threading: a PancakePeer is a single-owner state machine. Serialize every
   call on a given peer onto one thread or behind one lock. pancake_last_error
   is per-thread; read it on the thread that made the failing call.

   Out parameters: out structs are written only on PANCAKE_OK;
   zero-initialize or never release on failure. */

/* ── Return codes ── */
/* Success. */
#define PANCAKE_OK 0
/* A required pointer argument was NULL. */
#define PANCAKE_ERR_NULL_POINTER (-1)
/* -2 retired, never reused */
/* A non-pointer argument was out of range or unparseable (a bad shape/codec discriminant, a zero frame cap, an unparseable host address). */
#define PANCAKE_ERR_INVALID_ARGUMENT (-3)
/* The session state machine refused the operation (a protocol violation, a resource cap, an already-closed session). */
#define PANCAKE_ERR_SESSION (-4)
/* Inbound bytes failed codec decode, or outbound work failed to encode. */
#define PANCAKE_ERR_CODEC (-5)
/* A host-internal failure (allocation, ...). */
#define PANCAKE_ERR_INTERNAL (-6)
/* Nothing to do right now: an empty queue, or a partial frame awaiting more bytes. */
#define PANCAKE_ERR_WOULD_BLOCK (-7)
/* The peer closed the stream gracefully on a frame boundary (clean EOF). */
#define PANCAKE_ERR_CLOSED (-8)
/* An underlying socket read/write failed; pancake_last_error carries the concrete cause. */
#define PANCAKE_ERR_IO (-9)
/* Inbound bytes were not a structurally valid frame. */
#define PANCAKE_ERR_MALFORMED (-10)
/* An inbound frame exceeded the endpoint's max_frame_bytes. */
#define PANCAKE_ERR_FRAME_TOO_LARGE (-11)
/* -12 retired, never reused */
/* A value SENT across the typed surface uses a variant the C ABI cannot carry (a handoff argument, an OCapN Struct argument, or a sturdy/broken reference target): refused loudly rather than marshalled wrong. There is no PANCAKE_ARG_STRUCT, so a Struct cannot be built as an argument. Received values never earn this code — pancake_peer_next_event projects an uncarriable inbound value (a Struct among them) as its raw wire frame instead. */
#define PANCAKE_ERR_UNSUPPORTED_VALUE (-13)
/* A partner broke a promise. The sans-io libpancake_ocapn surface never returns this: a break arrives there as a PANCAKE_RESOLUTION_BREAK resolve event. The owning-session transport surfaces do return it — pancake_tcp_session_fetch (pancake_net_transport_tcp.h) reports a partner break this way, and any future transport twin the same — and bindings reuse the code for that meaning. */
#define PANCAKE_ERR_BROKEN (-14)
/* A well-formed lookup found nothing: pancake_locator_hint named a key absent from the locator. Distinct from _INVALID_ARGUMENT (a malformed request). */
#define PANCAKE_ERR_NOT_FOUND (-15)
/* A caller-provided output buffer was too small for the value being written. The call still reports the required length in its out_len parameter, so a caller retries with a large enough buffer. Distinct from _INVALID_ARGUMENT (a malformed request). */
#define PANCAKE_ERR_BUFFER_TOO_SMALL (-16)

/* ── Discriminants ── */
/* codec for pancake_peer_new_negotiated and the transport endpoints: Syrup. The session's grammar and the endpoint's framing must carry the same value. */
#define PANCAKE_CODEC_SYRUP 0
/* codec for pancake_peer_new_negotiated and the transport endpoints: Cap'n Proto. */
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
#define PANCAKE_PROJECTION_NONE 0
#define PANCAKE_PROJECTION_DELIVER 1
#define PANCAKE_PROJECTION_RESOLVE 2
#define PANCAKE_PROJECTION_FRAME 3
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
#define PANCAKE_RESOLUTION_HANDOFF 2
#define PANCAKE_HINTS_EMPTY_MAP 0
#define PANCAKE_HINTS_EMPTY_FALSE 1
/* captp_version for pancake_peer_new_negotiated: the authenticated v1.0 profile. */
#define PANCAKE_CAPTP_VERSION_V1_0 0
/* captp_version for pancake_peer_new_negotiated: next, the pancake-forward private CapTP track. */
#define PANCAKE_CAPTP_VERSION_NEXT 1
/* PancakeLastAbort.domain: a codec decode/encode malformation. */
#define PANCAKE_ABORT_DOMAIN_CODEC 0
/* PancakeLastAbort.domain: the session state machine refused the operation. */
#define PANCAKE_ABORT_DOMAIN_SESSION 1
/* PancakeLastAbort.domain: a host-internal failure (allocation, ...). */
#define PANCAKE_ABORT_DOMAIN_FOREIGN 2
/* PancakeEnlivenStart.status: a fresh bootstrap-fetch was queued; drive `answer` and settle with pancake_peer_record_enlivenment. */
#define PANCAKE_ENLIVEN_FRESH 0
/* PancakeEnlivenStart.status: short-circuited to an already-enlivened reference (no wire); read import_position and kind. */
#define PANCAKE_ENLIVEN_CACHED 1
/* PancakeEnlivenStart.status: collapsed onto an enliven already outstanding on `answer`. */
#define PANCAKE_ENLIVEN_IN_FLIGHT 2
/* pancake_peer_record_enlivenment outcome: the partner fulfilled with a capability; cache it under the swissnum. */
#define PANCAKE_ENLIVEN_OUTCOME_FULFILLED 0
/* pancake_peer_record_enlivenment outcome: the partner broke the answer; clear the in-flight marker, cache nothing. */
#define PANCAKE_ENLIVEN_OUTCOME_BROKEN 1

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
    /* Internal self-release hook; never call it directly. Free the frame with
       `pancake_managed_frame_release`, which is idempotent and nulls this first. */
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
   alloc's, correct even for a size-tracking host allocator. */
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
   codec: captp_version is a PANCAKE_CAPTP_VERSION_* value (_V1_0, or _NEXT
   for the pancake-forward private CapTP track), codec a PANCAKE_CODEC_* value.
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
int32_t pancake_peer_recv_borrowed(PancakePeer *peer, const PancakeFrame *frame);
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
   pancake_peer_take_outbound and pancake_peer_poll_event afterward.
   Or let pancake_peer_next_event drive and project in one call. */
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
/* The base of the reserved redeemed-handoff-token far-id range: a far id at
   or above this names a capability the host redeemed and routes to its
   exporter connection, never a wire import, so a token can never alias a
   partner's import. A host that keys per-import state (GC, caches) by far
   id uses this bound to tell the two apart. Emitted with the ULL suffix,
   the one constant too large for the plain-int convention above. */
#define PANCAKE_REDEEMED_TOKEN_BASE 1152921504606846976ULL
/* Expose a local capability behind `swissnum` for inbound bootstrap-fetch;
   writes the allocated export position. `swissnum` is borrowed. */
int32_t pancake_peer_register_bootstrap_cap(PancakePeer *peer, const uint8_t *swissnum, size_t swissnum_len, uint64_t *out_export_position);
/* Ask the partner's bootstrap object for the capability published behind
   `name`: registers the bootstrap import if needed, allocates the answer from
   the session's one answer allocator, and queues the canonical fetch deliver.
   The question id lands in `out_answer`; the partner's resolution arrives as a
   PANCAKE_EVENT_RESOLVE keyed on it. `name` is borrowed for the call. */
int32_t pancake_peer_send_bootstrap_fetch(PancakePeer *peer, const uint8_t *name, size_t name_len, uint64_t *out_answer);

typedef struct PancakeEnlivenStart {
    /* a PANCAKE_ENLIVEN_* status selecting the live fields */
    uint32_t status;
    /* _CACHED far reference kind: a PANCAKE_REF_SUB_* value */
    uint32_t kind;
    /* _FRESH/_IN_FLIGHT question id to drive */
    uint64_t answer;
    /* _CACHED far import position */
    uint64_t import_position;
} PancakeEnlivenStart;

/* Begin enlivening the sturdyref published behind `swissnum` (ADR-0012): the
   requester half over bootstrap-fetch with the dedup cache threaded in.
   `swissnum` is borrowed; the result lands in `out`. A PANCAKE_ENLIVEN_FRESH
   status queued the fetch deliver (flush with pancake_peer_step +
   pancake_peer_take_outbound); its resolution arrives as a
   PANCAKE_EVENT_RESOLVE keyed on out.answer, after which the caller calls
   pancake_peer_record_enlivenment to cache it. A PANCAKE_ENLIVEN_CACHED status
   short-circuits with no wire traffic (read out.import_position and out.kind);
   a PANCAKE_ENLIVEN_IN_FLIGHT status names an enliven already outstanding on
   out.answer. Requires the session to have negotiated the sturdyref feature
   and be open, else PANCAKE_ERR_SESSION. */
int32_t pancake_peer_prepare_enliven(PancakePeer *peer, const uint8_t *swissnum, size_t swissnum_len, PancakeEnlivenStart *out);
/* Settle a PANCAKE_ENLIVEN_FRESH enliven once its resolution arrives
   (ADR-0012 dedup cache). On PANCAKE_ENLIVEN_OUTCOME_FULFILLED the resolved far
   reference (import_position plus kind, a PANCAKE_REF_SUB_* value read from the
   resolve event) is cached under `swissnum` so a repeat enliven short-circuits;
   on PANCAKE_ENLIVEN_OUTCOME_BROKEN the in-flight marker is cleared and nothing
   is cached. `swissnum` is borrowed for the call. */
int32_t pancake_peer_record_enlivenment(PancakePeer *peer, const uint8_t *swissnum, size_t swissnum_len, uint32_t outcome, uint64_t import_position, uint32_t kind);
/* Register a local export position and GRANT it: deliveries to it are
   admitted and surface as events immediately, without waiting for the
   capability's first marshal. The deliberate make-this-addressable-now verb
   for positions a partner learns out-of-band. */
int32_t pancake_peer_register_export(PancakePeer *peer, uint64_t export_position);
/* Allocate the next free export position from the session's one export
   allocator and RESERVE it (unlike pancake_peer_next_answer, which only
   allocates), writing it into `out_export_position`. The partner can address
   the reserved position only once the capability first marshals onto the
   wire, or after an explicit pancake_peer_register_export grant. A binding's
   `spawn` must take its position here: the same counter mints bootstrap and
   resolver exports, so a privately-counted position would eventually alias one. */
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
/* Pin the partner's Ed25519 public key before their op:start-session is fed.
   A mismatch becomes PartnerKeyMismatch and aborts the session fail-closed
   (the dial-side identity pin, ADR-0075). `key` is borrowed and `key_len` must
   be 32; anything else is refused with PANCAKE_ERR_INVALID_ARGUMENT. */
int32_t pancake_peer_expect_partner_key(PancakePeer *peer, const uint8_t *key, size_t key_len);

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
   a magnitude that fits int64_t belongs in _INTEGER and is refused here.

   The OCapN Struct has no PANCAKE_ARG_* kind and cannot cross this typed
   surface: sending one is refused with PANCAKE_ERR_UNSUPPORTED_VALUE, and an
   inbound deliver carrying a Struct lands in the PancakeAnyEvent `frame` arm
   as raw wire bytes (see pancake_peer_codec) rather than a projected argument. */
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
    /* aliases the enclosing PancakeAnyEvent's arena */
    const PancakeArgument *args;
    size_t args_len;
    uint32_t has_answer;
    uint64_t answer;
    /* freed by pancake_any_event_release */
    void *owner;
} PancakeDeliver;

typedef struct PancakeHandoffGive {
    /* verbatim signed give; feed to pancake_peer_send_withdraw_gift */
    const uint8_t *give;
    size_t give_len;
    /* exporter ocapn:// URI, or NULL when the location is not a flat locator */
    const uint8_t *exporter_locator;
    size_t exporter_locator_len;
    /* 32-byte Ed25519 key the give is addressed to */
    const uint8_t *recipient_key;
    size_t recipient_key_len;
} PancakeHandoffGive;

typedef struct PancakeResolve {
    uint64_t answer;
    /* fulfill, break, or handoff */
    uint32_t resolution_kind;
    PancakeArgument fulfill;
    const uint8_t *break_message;
    size_t break_message_len;
    /* set when resolution_kind is _HANDOFF */
    PancakeHandoffGive handoff;
    /* freed by pancake_any_event_release */
    void *owner;
} PancakeResolve;

typedef struct PancakeAnyEvent {
    /* the event's PANCAKE_EVENT_* */
    uint32_t kind;
    /* which arm is live: PANCAKE_PROJECTION_* */
    uint32_t projection;
    /* live when projection is _DELIVER */
    PancakeDeliver deliver;
    /* live when projection is _RESOLVE */
    PancakeResolve resolve;
    /* live when projection is _FRAME: the originating wire bytes (see pancake_peer_codec) */
    PancakeManagedFrame frame;
} PancakeAnyEvent;


/* ── The event loop ── */
/* Drive the engine to idle, then take the next event, fully projected — the
   one call a consumer's event loop needs. Driving first makes the loop's
   obvious shape the correct one: settling an answer can cascade (a resolve
   drains a pipelined projection, whose own resolve fires a listener, which
   queues a deliver), and each cascade step can mint fresh events and outbound
   frames; this call runs the engine to quiescence before it answers, so a
   caller never re-derives a step-then-re-poll rule. Write the queued outbound
   frames (pancake_peer_take_outbound) when this reports no event, before
   parking on the next read. `kind` carries the event's PANCAKE_EVENT_* and
   `projection` names the live arm: a deliver projects into `deliver`, a
   resolve into `resolve` (including the PANCAKE_RESOLUTION_HANDOFF give), and
   every other kind — or a deliver/resolve whose value the typed surface cannot
   carry — lands in `frame` as the originating wire bytes in the negotiated
   codec (pancake_peer_codec). Exactly one event is consumed per PANCAKE_OK.
   PANCAKE_ERR_WOULD_BLOCK when the engine is idle and no event is pending.
   Release `out` with pancake_any_event_release exactly once. */
int32_t pancake_peer_next_event(PancakePeer *peer, PancakeAnyEvent *out);
/* Release a polled PancakeAnyEvent: frees whichever arm `projection` names (the
   deliver/resolve views or the owned frame) and zeroes the struct, so a repeat
   release — or releasing a zero-initialized struct — is a no-op. */
void pancake_any_event_release(PancakeAnyEvent *event);
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
/* Queue an op:get projection (ADR-0050): export a fresh promise at `answer`
   that resolves to the `field` member of whatever `receiver` resolves to.
   `receiver` is typically a _PROMISE (the answer position a prior send_deliver
   returned), so the projection pipelines ahead of that answer settling; a _FAR
   receiver projects an already-settled capability. The settlement arrives as a
   PANCAKE_EVENT_RESOLVE keyed on `answer`, which must come from
   pancake_peer_next_answer on this peer. `field` is borrowed. */
int32_t pancake_peer_send_get(PancakePeer *peer, const PancakeReference *receiver, const uint8_t *field, size_t field_len, uint64_t answer);
/* Queue an op:index projection (ADR-0050): export a fresh promise at `answer`
   that resolves to element `index` of whatever `receiver` resolves to. Like
   pancake_peer_send_get but for a List position. `answer` must come from
   pancake_peer_next_answer on this peer. */
int32_t pancake_peer_send_index(PancakePeer *peer, const PancakeReference *receiver, int64_t index, uint64_t answer);
/* Queue an op:untag projection (ADR-0052): export a fresh promise at `answer`
   that resolves to the payload of whatever `receiver` resolves to, requiring a
   Tagged record whose tag equals `tag` (breaks on a mismatched tag or
   wrong-shape value). `answer` must come from pancake_peer_next_answer on this
   peer; `tag` is borrowed. */
int32_t pancake_peer_send_untag(PancakePeer *peer, const PancakeReference *receiver, const uint8_t *tag, size_t tag_len, uint64_t answer);
/* Queue an op:abort that tears the CapTP session down after pancake_peer_step
   commits the frame to outbound. `kind_name` is an AbortKind wire label (e.g.
   "GracefulShutdown"); unknown labels are PANCAKE_ERR_INVALID_ARGUMENT.
   `message` is borrowed and copied onto the queued abort. After a successful
   step the peer is no longer open (pancake_peer_session_is_open is false). */
int32_t pancake_peer_send_abort(PancakePeer *peer, const uint8_t *kind_name, size_t kind_name_len, const uint8_t *message, size_t message_len);
/* Construct and queue an op:gc-export releasing wire-delta counts on imports
   this peer holds: positions[i] is released by deltas[i], for `len` parallel
   entries (both borrowed; len == 0 is PANCAKE_ERR_INVALID_ARGUMENT). */
int32_t pancake_peer_send_gc_export(PancakePeer *peer, const uint64_t *positions, const uint64_t *deltas, size_t len);
/* Construct and queue an op:gc-answer releasing the answer position this peer
   no longer needs. */
int32_t pancake_peer_send_gc_answer(PancakePeer *peer, uint64_t answer);
/* Recipient half of a three-party handoff (ADR-0009): build a signed
   desc:handoff-receive embedding the verbatim `give` bytes and queue a
   withdraw-gift op:deliver to the exporter's bootstrap (far object 0) under
   `answer`. The caller must already hold an open keyed session to the exporter
   named by the give's exporter-location, opened with the same 32-byte `seed`
   the gift was deposited under (seed_len must be 32, the session must be open,
   else PANCAKE_ERR_SESSION). The monotonic handoff-count the exporter requires
   to increase is minted internally by the peer's gift registry (0 for the first
   withdrawal from a given exporter session, rising across reconnects when a
   shared registry is wired), so the caller never tracks it. The withdrawn
   reference arrives as a PANCAKE_EVENT_RESOLVE keyed on `answer`. `give` and
   `seed` are borrowed. */
int32_t pancake_peer_send_withdraw_gift(PancakePeer *peer, const uint8_t *give, size_t give_len, const uint8_t *seed, size_t seed_len, uint64_t answer);
/* Borrow the partner's verbatim location-record bytes from its op:start-session
   into out_ptr/out_len (a NULL pointer and zero length when none were captured).
   A gifter embeds these as a give's exporter location so a peer comparing
   locations matches byte-for-byte. The view aliases the session until release. */
int32_t pancake_peer_partner_locator_raw(PancakePeer *peer, const uint8_t **out_ptr, size_t *out_len);
/* Build the signed desc:handoff-give a gifter returns to a recipient, writing
   owned bytes into out_give/out_give_len (release with
   pancake_handoff_give_bytes_release). `seed` is the gifter's 32-byte identity
   seed (the key it presents on the to-exporter session, which signs the give
   and must equal the deposit's provenance); seed_len must be 32. recipient_key
   is the recipient's session public key, exporter_locator_raw the exporter's
   verbatim location bytes, exporter_session_key the exporter's session public
   key, gift_id the deposited gift's id. The gifter side and gifter-exporter
   session name are derived from the keys. All inputs are borrowed. */
int32_t pancake_build_handoff_give(const uint8_t *seed, size_t seed_len, const uint8_t *recipient_key, size_t recipient_key_len, const uint8_t *exporter_locator_raw, size_t exporter_locator_raw_len, const uint8_t *exporter_session_key, size_t exporter_session_key_len, const uint8_t *gift_id, size_t gift_id_len, uint8_t **out_give, size_t *out_give_len);
/* Release give bytes returned by pancake_build_handoff_give. NULL is a no-op. */
void pancake_handoff_give_bytes_release(uint8_t *give, size_t give_len);
/* Build the verbatim exporter location-record bytes a give names, writing owned
   bytes into out/out_len (release with pancake_peer_locator_bytes_release), the
   construct-it-yourself counterpart of pancake_peer_partner_locator_raw, for an
   exporter whose own session record carries no dial hint. transport/designator
   name the exporter; direct_addresses, when non-empty, adds the exporter's
   comma-separated socket addresses as a direct-addresses hint, so a cross-process
   recipient dials the exporter directly with no discovery service (an iroh
   exporter reachable only by address). A NULL or empty direct_addresses yields a
   hint-less location identical to the exporter's own session record, so a
   discovery-reachable or TCP exporter keeps using pancake_peer_partner_locator_raw
   instead. The bytes are in the handoff codec (Syrup, as desc:handoff-give is);
   the result feeds pancake_build_handoff_give as exporter_locator_raw. All inputs
   are borrowed. */
int32_t pancake_encode_peer_locator(const uint8_t *transport, size_t transport_len, const uint8_t *designator, size_t designator_len, const uint8_t *direct_addresses, size_t direct_addresses_len, uint8_t **out, size_t *out_len);
/* Release locator bytes returned by pancake_encode_peer_locator. NULL is a no-op. */
void pancake_peer_locator_bytes_release(uint8_t *locator, size_t locator_len);
/* Deposit a gift with this (exporter) session: queue a deposit-gift op:deliver
   to the exporter's bootstrap object (far object 0) carrying the gift id and
   the gifted reference. Fire-and-forget (no answer): the exporter records the
   gift and parks any withdraw-gift that arrives first until this deposit lands.
   gift_id is borrowed; gifted_ref is borrowed and cloned by the send. */
int32_t pancake_peer_send_deposit_gift(PancakePeer *peer, const uint8_t *gift_id, size_t gift_id_len, const PancakeReference *gifted_ref);
/* Resolve `answer` (a question the recipient asked this gifter) with a signed
   desc:handoff-give: queue an op:resolve whose fulfill carries `give` verbatim,
   so the encoder emits the exact bytes the gifter signed and the recipient
   redeems them transparently. `give` is borrowed for the call. */
int32_t pancake_peer_send_resolve_handoff_give(PancakePeer *peer, uint64_t answer, const uint8_t *give, size_t give_len);

/* ── Per-thread last error ── */
/* Copy the calling thread's last error into `out_buf`. Copies at most cap - 1
   bytes and always NUL-terminates when cap > 0. Returns the full message
   length; to receive the whole message pass a buffer of that length plus one.
   out_buf == NULL or cap == 0 queries the length. */
size_t pancake_last_error(uint8_t *out_buf, size_t cap);
/* Clear the calling thread's last error slot. */
void pancake_clear_last_error(void);

/* ── OCapN locator URIs ── */
/* The ocapn://<designator>.<transport>[/s/<swiss>][?hints] bootstrap form a
   peer or sturdyref address travels in — core OCapN vocabulary, the one
   place the grammar lives so no consumer hand-rolls a percent codec.
   Parsing and formatting are separate from dialing: parse a URI, read its
   transport, then call the matching transport's connect (pancake_tcp_connect,
   the iroh companion library's connect, ...). The pancake_uri_* verbs do the
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
   full URI length; a buffer too small is PANCAKE_ERR_BUFFER_TOO_SMALL (a NULL
   buffer is PANCAKE_ERR_INVALID_ARGUMENT) with the length still reported, so
   size with out_len then retry. */
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
/* Split the locator's designator as host:port — the address grammar a socket
   transport's designator carries. Last-colon split, bracketed IPv6 literals
   unwrapped ([::1]:9000 yields host ::1), decimal uint16 port; the one grammar
   the native TCP netlayer dials through, so a consumer dialing with its own
   sockets validates the same way. PANCAKE_ERR_INVALID_ARGUMENT (see
   pancake_last_error) when the designator does not carry the grammar. The host
   view aliases the handle until pancake_locator_release. */
int32_t pancake_locator_host_port(PancakeLocator *loc, const uint8_t **out_host, size_t *out_host_len, uint16_t *out_port);
/* Split a bare designator as host:port — same grammar as
   pancake_locator_host_port, without minting a locator handle. A DIAL action
   already carries the designator; redeem dials use this instead of
   format→parse→host_port. PANCAKE_ERR_INVALID_ARGUMENT when the designator
   does not carry the grammar. The host view aliases designator for the call. */
int32_t pancake_designator_host_port(const uint8_t *designator, size_t designator_len, const uint8_t **out_host, size_t *out_host_len, uint16_t *out_port);
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
