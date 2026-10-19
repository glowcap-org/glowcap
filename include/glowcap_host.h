/* Generated from src/c_abi/host/mod.zig by tools/gen/header/host.zig.
   Do not edit by hand: run `zig build gen-header-host`.
   Function signatures are reflected from the Zig source, so this header
   cannot drift from the implementation.

   The byte-fed host tier's public C ABI: a separate archive
   (libglowcap_host) from libglowcap_ocapn (ADR-0022). It is a
   companion, not a superset: it exports only the glowcap_host_* family and
   shares the value vocabulary (GlowcapFrame, GlowcapManagedFrame,
   GlowcapContext, GlowcapArgument, GlowcapReference, GlowcapLastAbort) and
   the return codes by layout with glowcap_ocapn.h (included below), so a
   consumer links BOTH archives and includes BOTH headers. The family has
   its own last-error slot, read through glowcap_host_last_error rather
   than glowcap_ocapn's glowcap_last_error. */
#ifndef GLOWCAP_HOST_H
#define GLOWCAP_HOST_H

#include <stddef.h>
#include <stdint.h>
#include "glowcap_ocapn.h"

#ifdef __cplusplus
extern "C" {
#endif
/* A GlowcapHost is the multi-session CapTP host for an embedder that
   owns its own loop, sockets, and entropy (ADR-0022). The library owns every
   decision (routing, three-party redeem, gift origination). The embedder
   moves transport packets: feed inbound packets with glowcap_host_session_feed_packet,
   write what glowcap_host_session_take_packet drains, and honor the action queue.
   examples/c/host_embedder_pump.c is a complete embedder built from exactly
   these calls, and the host section of docs/consuming-from-c.md is the
   guided route; read one before wiring the action queue below.

   A vow is this tier's observation handle for the eventual result of a
   send. It is distinct from the passable OCapN promise reference and the
   CapTP answer position that names a session slot. A session_send /
   session_fetch returns a vow; you pipeline more sends against it
   (vow_send / vow_get / …) before it settles, and its outcome
   arrives later as a SETTLE or FAIL action naming that vow's ticket.

   THE ONE LOOP RULE. After any top-level glowcap_host_* call returns OK,
   drain glowcap_host_next_action until GLOWCAP_ERR_WOULD_BLOCK, honoring each
   action. DIAL: borrow the pending view with
   glowcap_host_pending_dial(ticket, route_index), open your own channel from it,
   mint the session from the same view
   (glowcap_host_session_open_dialed_locator), drive
   its session open, then report glowcap_host_dialed (or
   glowcap_host_dial_failed); FLUSH: drain
   that session's transport output until WOULD_BLOCK and write it;
   NEED_GIFT_ID: draw 32 random bytes and call glowcap_host_provide_gift_id,
   or call glowcap_host_gift_id_failed when entropy cannot be provided;
   SETTLE / FAIL: route the outcome to whatever awaits the vow the action's
   ticket names. Nothing in the library enforces the drain. Honoring it is
   the embedder's side of the contract, and an ignored action strands the
   dial, flush, handoff, or settlement it carries.

   THREADING AND REENTRANCY. One thread (or one green-thread scheduler)
   drives one host; nothing locks. The one callback (a behavior answering
   a deliver) fires on the thread executing the enclosing glowcap_host_*
   call. Inside it the enqueueing verbs are legal (among them
   session_send/session_tell, session_listen, session_resolve,
   vow_send/vow_index/vow_untag/vow_get, the turn verbs (with the callback's own turn),
   ref_release, session_set_exporter_location, session_is_open, the error
   readers) and their effects encode and pump when the enclosing call
   unwinds. The host-driving verbs (among them feed, take_outbound,
   next_action, pump_drain, the dial reports, open_*, publish/spawn,
   fetch/enliven, close and release) are refused there with
   GLOWCAP_ERR_INVALID_ARGUMENT. */

/* A byte-fed multi-session CapTP host: one identity, one routing and
   redeem authority, many sessions. Created by glowcap_host_new /
   glowcap_host_new_in; released by glowcap_host_release, always after its
   sessions. */
typedef struct GlowcapHost GlowcapHost;

/* One byte-fed CapTP session a host minted. Released by
   glowcap_host_session_release, always before the host. */
typedef struct GlowcapHostSession GlowcapHostSession;

/* The current turn, passed to a behavior callback so it can forward and
   eventual-send while handling a deliver (glowcap_host_turn_*). Valid only
   for the duration of that callback: stashing the pointer and using it
   after the callback returns is undefined behavior. */
typedef struct GlowcapHostTurn GlowcapHostTurn;

/* A hosted object's behavior, invoked on each deliver. verb/args are
   borrowed for the call; each GlowcapReference leaf is nevertheless
   one application retain and must eventually be returned with
   glowcap_host_ref_release. Copying its { id } bytes does not create
   another retain. The vat copies *out_reply's payload the
   instant you return, so its bytes must stay valid across the return
   (point them at your ctx or a buffer you own, not a callback stack
   local). Any non-OK return settles the answer broken
   with a generic reason. */
typedef int32_t (*GlowcapHostBehavior)(void *ctx, GlowcapHostTurn *turn,
    const uint8_t *verb, size_t verb_len, const GlowcapArgument *args,
    size_t args_len, GlowcapArgument *out_reply);

/* Release a hosted object's ctx when the object is torn down. NULL to keep
   ctx. Runs exactly once per registration that took ownership; must call
   no glowcap_host_* function. */
typedef void (*GlowcapHostCtxFree)(void *ctx);
#define GLOWCAP_TRACE_SESSION_OPEN 0
#define GLOWCAP_TRACE_MESSAGE 1
#define GLOWCAP_TRACE_SESSION_CLOSE 2
#define GLOWCAP_TRACE_DIGEST_BYTES 16

/* One live-trace fact (glowcap_host_set_trace). kind selects the live
   fields; string views are borrowed for the callback only. SESSION_OPEN
   carries session, partner, verified, and the negotiated GLOWCAP_CODEC_*,
   using GLOWCAP_CODEC_UNKNOWN only when this C ABI cannot name it;
   MESSAGE carries session, outbound, and the deliver's verb;
   SESSION_CLOSE carries session. Unused fields are zeroed. */
typedef struct GlowcapTraceEvent {
    /* A GLOWCAP_TRACE_* value. */
    uint32_t kind;
    /* The session the fact is about, stable for the session's life. */
    uint64_t session;
    /* MESSAGE: nonzero when the message left this host. */
    uint8_t outbound;
    /* SESSION_OPEN: whether the realized channel proved the partner's durable name, as a GLOWCAP_DURABLE_PROVENANCE_* value. */
    uint32_t provenance;
    /* SESSION_OPEN: the negotiated GLOWCAP_CODEC_*, or GLOWCAP_CODEC_UNKNOWN when this C ABI cannot name it. */
    uint32_t codec;
    /* SESSION_OPEN: the negotiated GLOWCAP_CAPTP_* profile. */
    uint32_t captp_version;
    /* SESSION_OPEN: the partner's OCapN Designator (dialed, or claimed by its hello). Borrowed. Half a name on its own: OCapN requires a designator and a transport together to tell two locations apart. */
    const uint8_t *designator;
    /* Length of designator. */
    size_t designator_len;
    /* SESSION_OPEN: the locator's OCapN Transport, the netlayer symbol this session runs over (tcp, keyed-tcp, keyed-relay, iroh, webrtc, inproc). Borrowed. */
    const uint8_t *transport;
    /* Length of transport. */
    size_t transport_len;
    /* SESSION_OPEN: the OCapN Session ID, 64 lowercase hex digits, which BOTH peers of this session derive to the same value; empty when the partner sent no session key. Borrowed. Not session above, which is this host's own handle and means nothing to anyone else. */
    const uint8_t *session_id;
    /* Length of session_id. */
    size_t session_id_len;
    /* MESSAGE: the deliver's verb. Borrowed. */
    const uint8_t *verb;
    /* Length of verb. */
    size_t verb_len;
    /* MESSAGE: the message's wire frame, borrowed; both directions carry it (the fact sites sit at the wire boundary). */
    const uint8_t *frame;
    /* Length of frame, as readable here. */
    size_t frame_len;
    /* MESSAGE: how long the frame really was; equal to frame_len on the callback path, larger when a queued record clipped it to its payload window. */
    size_t frame_total_len;
    /* Records the host dropped between the previous record and this one; always zero on the callback path. */
    uint64_t dropped;
    /* MESSAGE: a tag over the frame's bytes, naming this one message across the two peers that carried it, so a consumer merging two observers of one session folds their sightings into one. Zero on the other kinds. */
    uint8_t digest[16];
} GlowcapTraceEvent;
/* The trace callback: called synchronously at the fact site, on the host's
   one thread, with event and its views borrowed for the call. Must call no
   host-driving verb; stamp, copy, and return. */
typedef void (*GlowcapTraceCallback)(void *ctx, const GlowcapTraceEvent *event);

/* GlowcapHostAction.kind: dial the exporter named by ticket (borrow the pending view with glowcap_host_pending_dial), then report glowcap_host_dialed / glowcap_host_dial_failed. */
#define GLOWCAP_HOST_ACTION_DIAL 0
/* GlowcapHostAction.kind: drain the session's transport-ready output until WOULD_BLOCK and write it. */
#define GLOWCAP_HOST_ACTION_FLUSH 1
/* GlowcapHostAction.kind: draw 32 random bytes and feed them to glowcap_host_provide_gift_id with the ticket, or report failure through glowcap_host_gift_id_failed. */
#define GLOWCAP_HOST_ACTION_NEED_GIFT_ID 2
/* GlowcapHostAction.kind: the vow named by ticket settled fulfilled with value; route the outcome to whatever awaits it. */
#define GLOWCAP_HOST_ACTION_SETTLE 3
/* GlowcapHostAction.kind: the vow named by ticket failed with result and message; route the outcome to whatever awaits it. */
#define GLOWCAP_HOST_ACTION_FAIL 4
/* GlowcapHostAction.kind: the host retired this session; write any queued terminal frame, close its transport, and release the session. */
#define GLOWCAP_HOST_ACTION_CLOSE 5
/* GlowcapHostAction.kind: the finite host scheduler yielded with internal work remaining; continue draining actions, with no session or I/O payload. */
#define GLOWCAP_HOST_ACTION_RESUME 6
/* GlowcapHostAction.kind: interrupt and join the external dial named by ticket, then report glowcap_host_dial_cancelled. */
#define GLOWCAP_HOST_ACTION_CANCEL_DIAL 7
/* glowcap_host_close pending policy: seal admission, cancel admitted work, and begin terminal session shutdown. */
#define GLOWCAP_PENDING_CANCEL 0
/* glowcap_host_close pending policy: seal admission and keep driving admitted work before terminal session shutdown. */
#define GLOWCAP_PENDING_FINISH 1
/* GlowcapCloseOptions.abi_version. */
#define GLOWCAP_CLOSE_OPTIONS_ABI_VERSION 1
/* Largest finite GlowcapCloseOptions.grace_ms value. */
#define GLOWCAP_CLOSE_MAX_GRACE_MS 4294967295
/* GlowcapCloseOptions.grace_mode: no grace argument was supplied. */
#define GLOWCAP_CLOSE_GRACE_UNSPECIFIED 0
/* GlowcapCloseOptions.grace_mode: grace_ms is a finite budget. */
#define GLOWCAP_CLOSE_GRACE_FINITE 1
/* GlowcapCloseOptions.grace_mode: finish has no deadline. */
#define GLOWCAP_CLOSE_GRACE_UNBOUNDED 2
/* GlowcapSessionLimitOptions.abi_version. */
#define GLOWCAP_SESSION_LIMIT_OPTIONS_ABI_VERSION 1
/* The owner still admits application work. */
#define GLOWCAP_LIFECYCLE_ACTIVE 0
/* Admission is sealed while admitted work runs. */
#define GLOWCAP_LIFECYCLE_FINISHING 1
/* Terminal resource shutdown is in progress. */
#define GLOWCAP_LIFECYCLE_TERMINATING 2
/* The owner's execution state has reached its close barrier. */
#define GLOWCAP_LIFECYCLE_CLOSED 3
/* Default maximum admissible frame for glowcap_host_new / glowcap_host_new_in (bytes): mirrors session.SessionLimits.max_frame_bytes. */
#define GLOWCAP_DEFAULT_FRAME_CAP 1048576
/* Bound on one turn's synchronous local Forward chase (caretaker over attenuator). Hop N+1 breaks the answer instead of spinning. */
#define GLOWCAP_MAX_LOCAL_FORWARD_HOPS 256
/* Discovery-posture dial retry interval in milliseconds, projected from the shared driver_core default. */
#define GLOWCAP_DISCOVERY_DIAL_RETRY_MS 3000
/* Discovery-posture dial attempt budget, including the first attempt. */
#define GLOWCAP_DISCOVERY_DIAL_MAX_ATTEMPTS 24
/* GlowcapPartnerIdentity.provenance: a lower layer proved the partner holds the durable key it claims, and that key names the far end of the byte channel this session runs over, so the partner and the endpoint this session is encrypted to are one node. */
#define GLOWCAP_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT 0
/* GlowcapPartnerIdentity.provenance: nothing proved the name. A partner that claimed no durable identity at all lands here too, having no identity to have authenticated. */
#define GLOWCAP_DURABLE_PROVENANCE_UNAUTHENTICATED 1

typedef struct GlowcapCloseOptions {
    /* GLOWCAP_CLOSE_OPTIONS_ABI_VERSION. */
    uint32_t abi_version;
    /* sizeof(GlowcapCloseOptions). */
    size_t struct_size;
    /* GLOWCAP_PENDING_CANCEL or GLOWCAP_PENDING_FINISH. */
    uint32_t pending;
    /* GLOWCAP_CLOSE_GRACE_*; CANCEL requires UNSPECIFIED. */
    uint32_t grace_mode;
    /* Finite finish grace in milliseconds; CANCEL requires zero. */
    uint32_t grace_ms;
} GlowcapCloseOptions;

typedef struct GlowcapSessionLimitOptions {
    /* GLOWCAP_SESSION_LIMIT_OPTIONS_ABI_VERSION. */
    uint32_t abi_version;
    /* sizeof(GlowcapSessionLimitOptions). */
    size_t struct_size;
    /* Maximum inbound frame bytes; zero leaves the current value unchanged. */
    size_t max_frame_bytes;
    /* Maximum queued calls per pending answer; zero leaves the current value unchanged. */
    size_t queue_cap;
    /* Transient outbound byte waterline; zero leaves the current value unchanged. */
    size_t outbound_high_water_bytes;
    /* Durable sent-answer bytes retained after transient flow accounting; zero leaves the current value unchanged and values above UINT32_MAX are refused. */
    size_t max_retained_sent_answer_bytes;
} GlowcapSessionLimitOptions;

/* One embedder effect popped from glowcap_host_next_action. kind selects the
   live fields: DIAL carries ticket and route_index (borrow the pending view with
   glowcap_host_pending_dial). DIAL and CANCEL_DIAL also carry route_index.
   FLUSH and CLOSE carry session;
   NEED_GIFT_ID carries ticket. SETTLE carries the settled vow id in ticket
   and the fulfilled value in value; FAIL carries the vow id in ticket and
   the typed failure code in result and the reason in message/message_len.
   RESUME carries no payload and
   means the finite host scheduler yielded with internal work remaining.
   Every popped byte view and
   value's sub-structure are host-owned and valid until the NEXT
   glowcap_host_next_action call, which frees them. Unused fields are zeroed. */
typedef struct GlowcapHostAction {
    /* A GLOWCAP_HOST_ACTION_* value. */
    uint32_t kind;
    /* DIAL: the report-back handle; SETTLE/FAIL: the vow that settled. */
    uint64_t ticket;
    /* DIAL/CANCEL_DIAL: the concrete route within ticket's logical dial; zero otherwise. */
    size_t route_index;
    /* FLUSH/CLOSE: the session to drain or condemn; NULL otherwise. */
    GlowcapHostSession *session;
    /* SETTLE: the fulfilled value; zeroed otherwise. */
    GlowcapArgument value;
    /* FAIL: the break reason; NULL otherwise. */
    const uint8_t *message;
    size_t message_len;
    /* CLOSE: GLOWCAP_OK or GLOWCAP_ERR_TIMEOUT. FAIL: GLOWCAP_ERR_BROKEN or GLOWCAP_ERR_CLOSED; zero otherwise. */
    int32_t result;
} GlowcapHostAction;

/* One shared arm callback for GlowcapHostPumpHooks (flush, close,
   need_gift_id, complete for SETTLE/FAIL, dial). Return GLOWCAP_OK or a
   real GLOWCAP_ERR_*. When out_progressed is non-NULL, set it to 1 if the
   arm counts as quiescence progress; leave 0 for a handled notice a
   sibling shuttle already covers. action views are host-owned until the
   next glowcap_host_next_action (glowcap_host_pump_drain pops internally). */
typedef int32_t (*GlowcapHostPumpArmFn)(void *ctx, GlowcapHost *host,
    const GlowcapHostAction *action, uint32_t *out_progressed);
/* Opt-in embedder hooks for glowcap_host_pump_drain (ADR-0022).
   NULL arm pointers skip that kind (no error, no progress).
   The pull-queue remains normative. This is a convenience wrapper's
   callback surface, not a replacement for glowcap_host_next_action. */
typedef struct GlowcapHostPumpHooks {
    /* Caller context passed to every arm. */
    void *ctx;
    /* FLUSH arm, or NULL to skip. */
    GlowcapHostPumpArmFn flush;
    /* CLOSE arm, or NULL to skip. */
    GlowcapHostPumpArmFn close;
    /* NEED_GIFT_ID arm, or NULL to skip. */
    GlowcapHostPumpArmFn need_gift_id;
    /* SETTLE and FAIL arm, or NULL to skip. */
    GlowcapHostPumpArmFn complete;
    /* DIAL arm, or NULL to skip. */
    GlowcapHostPumpArmFn dial;
} GlowcapHostPumpHooks;

/* Read the exact reflected callable and layout identity of this Host archive. */
uint64_t glowcap_host_archive_fingerprint(void);
/* Create a byte-fed host bound to a caller-drawn 64-byte seed buffer (the host
   never draws entropy), allocating through the library allocator.

   seed_len must be 64. The first 32 bytes are the durable identity and must
   stay stable across restarts, because a keyed locator's designator derives
   from them. The next 32 are the session-key root, and they must be FRESH PER
   PROCESS: they are what makes each CapTP session sign with its own key, so an
   old handoff certificate cannot resolve against a session opened after a
   restart. A durable-only 32-byte seed is refused. CapTP session keys must not
   silently reuse the identity seed (ADR-0028).

   frame_cap sizes every session's maximum admissible frame; a
   nonzero verify_partner keeps partner-signature verification on (the secure
   default); codec is GLOWCAP_CODEC_SYRUP or GLOWCAP_CODEC_CAPNP.
   GLOWCAP_CODEC_UNKNOWN is an output sentinel and is refused here.
   captp_version is the GLOWCAP_CAPTP_* profile this host prefers, and features is
   the GLOWCAP_FEATURE_* bitmask this host offers. The signed hello carries those
   preferences as locator hints; each session settles version and codec with its
   partner, falling back to v1.0/Syrup when needed, and runs only the intersection
   of the two offered feature sets. An absent feature hint means the baseline set,
   which excludes GLOWCAP_FEATURE_UNTAG because Goblins does not implement it.
   GLOWCAP_CAPTP_V1_0 with GLOWCAP_CODEC_SYRUP remains the interop floor; callers
   may pass GLOWCAP_FEATURE_FULL on that same wire version, and the hello and
   settled session use only the v1.0-eligible subset.
   local_turn_budget caps local-turn amplification per session (ADR-0018):
   GLOWCAP_LOCAL_TURN_BUDGET_DEFAULT applies the Zig Host's finite default,
   GLOWCAP_LOCAL_TURN_BUDGET_UNBOUNDED turns the cap off, and any other value
   is the cap.
   release_on_drop is the Host-wide setting a binding reads when it projects a
   far capability (ADR-0025): nonzero means the capability releases its Host
   retain when the language's scope end for it is observed. A binding whose
   release rides a finalizer passes 0 and keeps its per-session opt-in. Read it
   with glowcap_host_release_on_drop and change it with
   glowcap_host_set_release_on_drop. The Host attaches no behavior to it.
   *out_host receives the handle; release with glowcap_host_release. */
int32_t glowcap_host_new(const uint8_t *seed, size_t seed_len, size_t frame_cap, uint32_t verify_partner, uint32_t codec, uint32_t captp_version, uint32_t features, uint32_t local_turn_budget, uint32_t release_on_drop, GlowcapHost **out_host);
/* glowcap_host_new allocating every byte the host owns through context's host
   allocator (glowcap_context_new_with_allocator). */
int32_t glowcap_host_new_in(GlowcapContext *context, const uint8_t *seed, size_t seed_len, size_t frame_cap, uint32_t verify_partner, uint32_t codec, uint32_t captp_version, uint32_t features, uint32_t local_turn_budget, uint32_t release_on_drop, GlowcapHost **out_host);
/* Read the Host-wide release-on-drop setting (ADR-0025) into *out_enabled as 0 or 1. */
int32_t glowcap_host_release_on_drop(GlowcapHost *host, uint32_t *out_enabled);
/* Set the Host-wide release-on-drop setting (ADR-0025) for capabilities the
   Host projects after this call: nonzero turns it on. A binding whose release
   rides a finalizer leaves it off and keeps its per-session opt-in. */
int32_t glowcap_host_set_release_on_drop(GlowcapHost *host, uint32_t enabled);
/* Return the Host's stable identity in its owning Context's diagnostic namespace. The context-less convenience constructor reports zero because it has no Context diagnostic namespace to allocate from. */
int32_t glowcap_host_diagnostic_id(GlowcapHost *host, uint64_t *out_id);
/* Seal application admission and begin or escalate terminal Host close. now_ms is
   a reading from the embedder's monotonic millisecond clock. FINISH keeps
   already-admitted work running under its finite or explicitly unbounded grace.
   Repeated calls share the first deadline: CANCEL may escalate FINISH and FINISH
   never weakens or restarts an existing barrier. This closes without releasing
   the Host handle. */
int32_t glowcap_host_close(GlowcapHost *host, const GlowcapCloseOptions *options, int64_t now_ms);
/* Apply the current monotonic clock reading to a started close and write its
   GLOWCAP_LIFECYCLE_* state. Expired FINISH escalates through the shared CANCEL
   path. After teardown reaches CLOSED, a finite grace expiry returns
   GLOWCAP_ERR_TIMEOUT together with CLOSED. */
int32_t glowcap_host_close_progress(GlowcapHost *host, int64_t now_ms, uint32_t *out_state);
/* The longest a close driver may wait for new input before calling
   glowcap_host_close_progress again: milliseconds until the nearest FINISH grace
   deadline (the Host's own or any session's), clamped at zero. Writes -1 when no
   finite deadline is pending; only feed, action-drain, settle, or escalation
   activity can then advance terminal progress, so the embedder may park on
   activity alone. The value drops straight into a wait primitive's timeout
   argument. */
int32_t glowcap_host_close_wait_ms(GlowcapHost *host, int64_t now_ms, int64_t *out_wait_ms);
/* Observe the current GLOWCAP_LIFECYCLE_* state without advancing time. The
   ordinary byte-feed and action-drain cycle advances terminal work; call
   glowcap_host_close_progress when the embedder clock advances. CLOSED means every
   session and queued Host effect has retired. A prior finite grace expiry returns
   GLOWCAP_ERR_TIMEOUT together with CLOSED. */
int32_t glowcap_host_lifecycle_state(GlowcapHost *host, uint32_t *out_state);
/* Release the host and everything it owns: every still-open session (each
   still-parked vow breaks inside this call, its undrained completion freed
   with the rest of the action queue), the vow map, parked actions, the node,
   and the publication rows (each publication's free runs exactly once here). NULL is
   a no-op. Session (GlowcapHostSession) handles this host minted are freed with it.
   Never touch one after its host is gone. Because release is terminal, an embedder
   may transfer exclusive ownership to a finalizer thread after every Host call has
   returned; no live Host verb gains cross-thread permission. Refusal from inside a
   callback sets last error and leaves the handle live. A teardown failure also sets
   last error but consumes the handle after completing the ownership sweep. */
int32_t glowcap_host_release(GlowcapHost *host);
/* Derive the canonical key designator (exactly 64 lowercase hex digits) from a
   32-byte Ed25519 durable identity seed, the public half of the first half of
   the 64-byte buffer glowcap_host_new takes. CapTP session signing keys come
   from the second half (ADR-0028), not from this designator seed. Writes 64
   bytes into out (out_len must be at least 64). Used by a keyed-tcp listener
   whose locator designator is this durable identity (ADR-0028). */
int32_t glowcap_host_designator_from_seed(const uint8_t *seed, size_t seed_len, uint8_t *out, size_t out_len);
/* Retain and select this host's complete acceptable location. The Host validates and deep-copies the borrowed locator view. Later dialed and accepted sessions sign this selection regardless of the transport carrying them. */
int32_t glowcap_host_set_advertised_locator(GlowcapHost *host, const GlowcapLocatorView *locator);
/* Retain a dial fallback for transport unless one already exists. It becomes the
   acceptable location only when the Host has no selection; it never displaces a
   route selected for another transport. Key-designator transports use this Host's
   public key; address transports use the unreachable-client placeholder. A
   reachable adapter must publish its complete locator explicitly. */
int32_t glowcap_host_ensure_advertised_locator(GlowcapHost *host, const uint8_t *transport, size_t transport_len);
/* Remove the retained locator for transport. Removing the selected route leaves
   no acceptable location until one is set or ensured; another retained route is
   never chosen implicitly. Existing sessions retain the signed hello snapshot
   they already sent. */
int32_t glowcap_host_remove_advertised_locator(GlowcapHost *host, const uint8_t *transport, size_t transport_len);
/* Apply versioned selective session-limit overrides before minting sessions.
   Zero fields leave the current value unchanged. Already-open peers keep the
   limits they were minted with. `options` is borrowed and must not be NULL. */
int32_t glowcap_host_set_session_limits(GlowcapHost *host, const GlowcapSessionLimitOptions *options);
/* Configure independent per-ingress queue bounds before any session or
   eventual send. Bytes include spines and queue rows. All limits are positive;
   a complete queue chunk must fit the aggregate byte allowance. No eager
   payload allocation occurs. Later reconfiguration is refused. */
int32_t glowcap_host_set_ingress_limits(GlowcapHost *host, uint32_t max_pending_turns, uint32_t max_pending_bytes, uint32_t max_chunk_bytes);
/* Mint the dialing half after an embedder has opened the byte channel for
   locator. The one locator vocabulary is taken whole: the designator keys
   duplicate-dial refusal and, on a key transport, demands the partner's durable
   key; route hints carry no semantics here because the caller's dial executor
   spent them realizing the channel. A DIAL action identifies one admitted
   (ticket, route_index) attempt: project its typed locator with
   glowcap_host_pending_dial, open the channel it names, and report that exact
   attempt. The host retains its own dial default for the locator's transport
   first, never displacing an advertised locator the embedder explicitly selected,
   so a bare client host dials without publishing anything. A sealed session
   derives its Noise ephemeral from the Host's unique per-session seed under a
   separate KDF domain, so callers do not branch on transport policy or supply
   per-open entropy. The keyed op:start-session is signed under the host identity
   and encoded before this returns, so drain take_outbound (a FLUSH action is
   queued) and drive the handshake byte-fed. Host-wide aliases remain lazily
   discoverable through the new session. *out_session is host-owned; release with
   glowcap_host_session_release. */
int32_t glowcap_host_session_open_dialed_locator(GlowcapHost *host, const GlowcapLocatorView *locator, GlowcapHostSession **out_session);
/* Mint the accepting half of a connection your listener produced.
   designator_scheme is the provider's GLOWCAP_DESIGNATOR_SCHEME_* declaration;
   server_designator is the listener's own signing designator (its key for a key
   transport, unused for an address transport); accepted_local_addr is the route
   the accept reported (NULL/0 when unavailable). The host retains the locator
   this accept would sign without displacing an acceptable location the embedder
   already selected: an explicit glowcap_host_set_advertised_locator is deployment
   policy and wins, and the accept-derived locator becomes the selection only when
   there is none. The session signs the selected snapshot even when it names
   another transport. Sealed-channel entropy follows the dialed half's Host-owned
   derivation. Host-wide aliases remain lazily discoverable, with the same flush
   and release contract as the dialed half. */
int32_t glowcap_host_session_open_accepted(GlowcapHost *host, const uint8_t *transport, size_t transport_len, uint32_t designator_scheme, const uint8_t *server_designator, size_t server_designator_len, const uint8_t *accepted_local_addr, size_t accepted_local_addr_len, GlowcapHostSession **out_session);

/* GlowcapDialPlan.shape: open a TCP socket to host:port (tcp, keyed-tcp). */
#define GLOWCAP_DIAL_SHAPE_HOST_PORT 0
/* GlowcapDialPlan.shape: peer-id open (node-id designator + addresses + reach, from the iroh locator scheme). */
#define GLOWCAP_DIAL_SHAPE_PEER_ID 1
/* GlowcapDialPlan.shape: signaling-mediated open (webrtc); no dialable address, the channel comes up through offer/answer/ICE (ADR-0035). */
#define GLOWCAP_DIAL_SHAPE_SIGNALING 2
/* GlowcapDialPlan.shape: rendezvous-bridged open (keyed-relay); no dialable address, the dialer opens the relay rendezvous leg its host is configured for (ADR-0034). */
#define GLOWCAP_DIAL_SHAPE_RENDEZVOUS 3
/* GlowcapDialPlan.reach_kind (peer-id shape): the relay-less direct posture. */
#define GLOWCAP_DIAL_REACH_DIRECT 0
/* GlowcapDialPlan.reach_kind (peer-id shape): the node's own configured redeem posture. */
#define GLOWCAP_DIAL_REACH_CONFIGURED 1
/* GlowcapDialPlan.reach_kind (peer-id shape): the caller posture carried in reach_value. */
#define GLOWCAP_DIAL_REACH_EXPLICIT 2
/* glowcap_host_plan_dial posture_policy: a redeem (a DIAL action): direct when a hint is present, else the node's configured posture. */
#define GLOWCAP_DIAL_POSTURE_REDEEM 0
/* glowcap_host_plan_dial posture_policy: a connect carrying a posture in posture_value. */
#define GLOWCAP_DIAL_POSTURE_EXPLICIT 1
/* glowcap_host_plan_dial posture_policy: a connect that named no posture; a peer-id dial refuses GLOWCAP_ERR_INVALID_ARGUMENT. */
#define GLOWCAP_DIAL_POSTURE_EXPLICIT_NONE 2
/* glowcap_host_session_open_accepted designator_scheme: the listener designator names a dialable address. */
#define GLOWCAP_DESIGNATOR_SCHEME_ADDRESS 0
/* glowcap_host_session_open_accepted designator_scheme: the listener designator names a peer key. */
#define GLOWCAP_DESIGNATOR_SCHEME_KEY 1
/* glowcap_host_new local_turn_budget: the Host's finite default cap, the same one the Zig Host applies. */
#define GLOWCAP_LOCAL_TURN_BUDGET_DEFAULT 0
/* glowcap_host_new local_turn_budget: no cap. Safe only when every partner is trusted. */
#define GLOWCAP_LOCAL_TURN_BUDGET_UNBOUNDED 4294967295
/* Minimum out_prefix capacity for glowcap_host_session_take_outbound. */
#define GLOWCAP_HOST_OUTBOUND_PREFIX_CAP 32
/* Exact caller-supplied entropy length for glowcap_host_publish_durable. */
#define GLOWCAP_HOST_DURABLE_ENTROPY_LEN 16
/* Required output capacity and written length for glowcap_host_publish_durable. */
#define GLOWCAP_HOST_DURABLE_SWISS_LEN 50

/* A resolved dial from glowcap_host_plan_dial: what byte channel to open and
   how. shape (GLOWCAP_DIAL_SHAPE_*) selects the live fields: HOST_PORT fills
   host/host_len/port, PEER_ID fills addresses/addresses_len and the reachability.
   Every view borrows the transport/designator/hint the caller passed in, so
   the plan is valid only while those buffers are. */
typedef struct GlowcapDialPlan {
    /* A GLOWCAP_DIAL_SHAPE_* value. */
    uint32_t shape;
    /* HOST_PORT: the resolved TCP host (borrows the designator or hint). */
    const uint8_t *host;
    size_t host_len;
    /* HOST_PORT: the resolved TCP port. */
    uint16_t port;
    /* PEER_ID: the direct-addresses to dial (borrows the hint verbatim). */
    const uint8_t *addresses;
    size_t addresses_len;
    /* PEER_ID: a GLOWCAP_DIAL_REACH_* value. */
    uint32_t reach_kind;
    /* PEER_ID: the caller posture when reach_kind is GLOWCAP_DIAL_REACH_EXPLICIT. */
    uint32_t reach_value;
} GlowcapDialPlan;

/* Project one concrete in-flight route for ticket into out_locator, using the
   caller-owned hint_storage array. route_index comes from the DIAL action and is
   part of its report-back authority. On GLOWCAP_OK, *out_hint_count is the number
   of initialized hints and the locator plus all nested byte views remain
   Host-owned until glowcap_host_dialed / glowcap_host_dial_failed consumes that
   attempt (or Host teardown); hint_storage remains caller-owned. A null
   hint_storage with hint_capacity 0 is the size probe: when hints exist the call
   returns GLOWCAP_ERR_BUFFER_TOO_SMALL, writes the exact required capacity to
   *out_hint_count, and leaves *out_locator untouched. The locator was parsed and
   retained once when the give was accepted; no URI is reparsed and no hint is
   discarded. Unknown or stale attempts return GLOWCAP_ERR_INVALID_ARGUMENT. */
int32_t glowcap_host_pending_dial(GlowcapHost *host, uint64_t ticket, size_t route_index, GlowcapLocatorHintView *hint_storage, size_t hint_capacity, GlowcapLocatorView *out_locator, size_t *out_hint_count);
/* Borrow the live session that supplied the oldest remaining give for this
   pending dial, or write NULL when no live introducer remains (including a
   purely application-owned dial). Unknown or stale attempts return
   GLOWCAP_ERR_INVALID_ARGUMENT and leave the output untouched. A deduplicated
   dial may have several introducing sessions; this projects one source, not
   authority over the others. Bindings capture it before starting the route effect
   to select application-owned signaling context without a global capture window.
   The borrowed handle lives with that session; do not release it here. Waiter
   retirement can change a later observation; this call retains no session and
   mints no capability. */
int32_t glowcap_host_pending_dial_introducer(GlowcapHost *host, uint64_t ticket, size_t route_index, GlowcapHostSession **out_session);
/* Write the live session homing remote reference into *out_session, or NULL for
   a local, stale, foreign-Host, or closed-session capability. Bindings compare
   this result with the sending session after a call: the same session is an
   ordinary reply, while another session is the exporter reached through handoff.
   The answer comes from the reference's own Host row, with no dial-completion
   capture window. The returned handle is Host-owned and lives with that session;
   do not release it here. */
int32_t glowcap_host_reference_exporter(GlowcapHost *host, const GlowcapReference *reference, GlowcapHostSession **out_session);
/* Resolve a dial without opening a socket: the transport dispatch, designator
   validation, host:port resolution, and peer-id reachability decision every binding
   used to re-express, done once here. transport/designator are the locator's
   pieces (from glowcap_host_pending_dial or glowcap_uri_parse_peer);
   direct_addresses_hint is the locator's direct-addresses hint (NULL/0 = none);
   posture_policy is a GLOWCAP_DIAL_POSTURE_* choosing the peer-id reachability rule,
   with posture_value the caller's posture under GLOWCAP_DIAL_POSTURE_EXPLICIT.
   On GLOWCAP_OK *out_plan is filled with views borrowing the caller's buffers; a
   bad locator returns GLOWCAP_ERR_INVALID_ARGUMENT (glowcap_host_last_error
   carries which). Open the channel the plan names, then pass the same
   locator view to glowcap_host_session_open_dialed_locator. */
int32_t glowcap_host_plan_dial(const uint8_t *transport, size_t transport_len, const uint8_t *designator, size_t designator_len, const uint8_t *direct_addresses_hint, size_t direct_addresses_hint_len, uint32_t posture_policy, uint32_t posture_value, GlowcapDialPlan *out_plan);

/* Seal one byte-fed session's application admission and begin or escalate its
   terminal close. now_ms is the embedder's monotonic millisecond reading. The
   shared controller retains the first FINISH deadline while the embedder keeps
   feeding bytes and draining actions. This closes without releasing the handle. */
int32_t glowcap_host_session_close(GlowcapHostSession *session, const GlowcapCloseOptions *options, int64_t now_ms);
/* Apply the current monotonic clock reading to one started session close and write
   its GLOWCAP_LIFECYCLE_* phase. Expired FINISH escalates through CANCEL. CLOSED
   means the terminal transport action crossed its retryable delivery boundary; a
   timed-out close returns GLOWCAP_ERR_TIMEOUT together with CLOSED. */
int32_t glowcap_host_session_close_progress(GlowcapHostSession *session, int64_t now_ms, uint32_t *out_state);
/* Observe one session's GLOWCAP_LIFECYCLE_* phase without advancing time. CLOSED
   means the terminal transport action crossed its retryable delivery boundary while
   the retained shell remains valid for explicit release. A prior finite grace expiry
   returns GLOWCAP_ERR_TIMEOUT together with CLOSED. */
int32_t glowcap_host_session_lifecycle_state(GlowcapHostSession *session, uint32_t *out_state);
/* Release one session: its still-parked far vows break (their FAIL
   completions queue inside this call), the node retires it (stranded
   withdraws fail closed, so SIBLING sessions' vows may break here too), and
   the shell is freed. NULL is a no-op; refused (last error set, the session
   kept) from inside a callback. */
int32_t glowcap_host_session_release(GlowcapHostSession *session);
/* Nonzero once the keyed handshake has completed and the session is open. */
int32_t glowcap_host_session_is_open(GlowcapHostSession *session);
/* Read the complete profile this session settled with its partner into the three required GLOWCAP_CAPTP_*, GLOWCAP_CODEC_*, and GLOWCAP_FEATURE_* outputs. Before the keyed handshake opens this returns GLOWCAP_ERR_WOULD_BLOCK; after the CapTP session becomes terminal it returns GLOWCAP_ERR_CLOSED. Failure leaves all outputs untouched. */
int32_t glowcap_host_session_profile(GlowcapHostSession *session, uint32_t *out_captp_version, uint32_t *out_codec, uint32_t *out_features);
/* Borrow the exact netlayer symbol this session was opened through. Both outputs are required and remain valid until session release. This is local connection metadata, not the partner's signed locator claim. */
int32_t glowcap_host_session_transport_name(GlowcapHostSession *session, const uint8_t **out_name, size_t *out_name_len);
/* The id the live trace names this session's rows by (GlowcapTraceEvent's session), so an embedder can annotate the same session a trace consumer is watching. Stable for the session's life and never reused by this host. */
int32_t glowcap_host_session_trace_id(GlowcapHostSession *session, uint64_t *out_id);
/* Feed one inbound frame you read from your own transport (borrowed for the
   call): behavior callbacks fire and vow completions queue inside, then the
   node actions the dispatch queued pump and every touched session's outbound
   encodes. GLOWCAP_ERR_WOULD_BLOCK is the preflight high-water refusal: the frame
   was not consumed, so drain actions / outbound frames and retry it. Other
   failures classify through GLOWCAP_ERR_CODEC / _SESSION / _INTERNAL. When
   glowcap_host_session_last_abort succeeds, the frame was consumed and the
   session is closing; drain its typed op:abort and release it. GLOWCAP_ERR_INTERNAL
   with no last-abort is allocation failure before frame admission, so the same
   borrowed frame remains retryable. */
int32_t glowcap_host_session_feed(GlowcapHostSession *session, const GlowcapFrame *frame_in);
/* Feed a byte-stream chunk you read from your own transport (borrowed for the
   call). The library owns outer framing and the tail: each bare codec frame is
   one canonical Syrup byte string (decimal length, colon, body). Split prefixes
   and bodies stay buffered in the session; coalesced byte strings dispatch in
   order, each body exactly as glowcap_host_session_feed. Dispatch pauses at the
   frame that completes the keyed handshake: frames coalesced behind the hello
   wait in the session's tail while you act on the fresh session (publish, fetch),
   and glowcap_host_session_resume_feed feeds them once that post-open authority
   is installed. GLOWCAP_ERR_WOULD_BLOCK is the preflight high-water refusal and
   consumes no bytes from this call. Internal pressure after any prefix commits is
   retained in the session tail and returns success; GLOWCAP_ERR_INTERNAL with no
   last-abort therefore means the first direct frame was not admitted and the same
   chunk is retryable. A recorded last-abort means the input was consumed and the
   session is closing; drain the typed abort and release it. A declared body
   exceeding the session's frame cap is GLOWCAP_ERR_FRAME_TOO_LARGE; malformed or
   non-canonical outer syntax is a codec error. */
int32_t glowcap_host_session_feed_bytes(GlowcapHostSession *session, const uint8_t *bytes, size_t len);
/* Feed one transport packet (borrowed for the call). Byte-stream transports pass
   arbitrary chunks carrying ADR-0012's outer Syrup byte-string envelope;
   message-framed transports pass one bare codec frame per packet. The Host
   transport profile owns that choice, so embedders do not branch on concrete
   transport names. A real empty message-framed packet is malformed because it is
   not a codec frame; use glowcap_host_session_resume_feed to resume retained
   byte-stream input without supplying new transport bytes. */
int32_t glowcap_host_session_feed_packet(GlowcapHostSession *session, const uint8_t *bytes, size_t len);
/* Resume input retained by an earlier feed, without treating an empty transport
   packet as new input. Byte-stream sessions may dispatch a held tail; message-
   framed sessions have no hidden tail and no-op. Refused inside a callback. */
int32_t glowcap_host_session_resume_feed(GlowcapHostSession *session);
/* Drain one transport-ready packet. Write
   out_prefix[0..*out_prefix_len] and then the owned out_frame bytes. Byte-stream
   sessions return their canonical outer Syrup prefix; message-framed sessions
   return an empty prefix and one bare codec frame. Free out_frame through
   glowcap_managed_frame_release. prefix_cap must be at least
   GLOWCAP_HOST_OUTBOUND_PREFIX_CAP; undersizing is refused before the payload
   leaves the queue. Returns GLOWCAP_OK with outputs set, or
   GLOWCAP_ERR_WOULD_BLOCK with outputs untouched. Refused inside a callback. */
int32_t glowcap_host_session_take_packet(GlowcapHostSession *session, GlowcapManagedFrame *out_frame, uint8_t *out_prefix, size_t prefix_cap, size_t *out_prefix_len);
/* Drain one transport-ready byte-stream vector. Write
   out_prefix[0..*out_prefix_len] and then the owned out_frame bytes. Clear
   sessions return their canonical outer Syrup prefix; sealed sessions return an
   empty prefix because out_frame is already wire-ready ciphertext. Free out_frame
   through glowcap_managed_frame_release. prefix_cap must be at least
   GLOWCAP_HOST_OUTBOUND_PREFIX_CAP; undersizing is refused before the payload
   leaves the queue. Returns GLOWCAP_OK with outputs set, or
   GLOWCAP_ERR_WOULD_BLOCK with outputs untouched. Refused inside a callback. */
int32_t glowcap_host_session_take_outbound(GlowcapHostSession *session, GlowcapManagedFrame *out_frame, uint8_t *out_prefix, size_t prefix_cap, size_t *out_prefix_len);
/* Pop the next embedder action into *out_action, or return
   GLOWCAP_ERR_WOULD_BLOCK when none is pending. Before the pop, queued Host work
   resumes and may invoke GlowcapHostBehavior synchronously; binding runtimes must
   install their Host delivery context around every drain. A DIAL carries ticket
   and route_index (borrow the exact pending view with glowcap_host_pending_dial).
   A SETTLE's value and a FAIL's message are host-owned until the NEXT
   glowcap_host_next_action call, which frees them. Deferred work may return
   GLOWCAP_ERR_INTERNAL under allocator pressure before an action is popped; no
   action or authority is lost, and the embedder retries this same drain call when
   pressure subsides. See the one loop rule in the header preamble. Refused inside
   a callback. */
int32_t glowcap_host_next_action(GlowcapHost *host, GlowcapHostAction *out_action);
/* Opt-in convenience drain over glowcap_host_next_action (ADR-0022). Still pops through the pull-queue internally; does not replace
   it. hooks may be NULL (every action is discarded). *out_acted is 1 when any
   arm reported progress (optional, may be NULL). *out_yielded is 1 when the
   finite Host scheduler requested another embedder turn (optional, may be NULL);
   return to the reactor before draining again. Resuming work may invoke
   GlowcapHostBehavior synchronously before an action hook runs, so binding
   runtimes must install their Host delivery context around this whole call. See
   GlowcapHostPumpHooks. */
int32_t glowcap_host_pump_drain(GlowcapHost *host, const GlowcapHostPumpHooks *hooks, uint32_t *out_acted, uint32_t *out_yielded);
/* Report a DIAL attempt's success. session is an open_dialed_locator against the
   exact ticket/route_index view, driven open. *out_adopted is one when this route
   won the logical dial and zero when another route already won or the attempt was
   not running; the executor must close and release an unadopted session. A non-OK
   return consumes neither attempt nor session. */
int32_t glowcap_host_dialed(GlowcapHost *host, uint64_t ticket, size_t route_index, GlowcapHostSession *session, uint8_t *out_adopted);
/* Report one DIAL attempt's failure. Strong identity routes maintain their bounded
   race before ordered weak fallbacks begin; waiters break only after every eligible
   route fails. A stale or non-running attempt is a no-op success. */
int32_t glowcap_host_dial_failed(GlowcapHost *host, uint64_t ticket, size_t route_index, const uint8_t *reason, size_t reason_len);
/* Acknowledge that a CANCEL_DIAL attempt's physical operation has stopped and its
   executor state can be released. Host close remains pending until this report. */
int32_t glowcap_host_dial_cancelled(GlowcapHost *host, uint64_t ticket, size_t route_index);
/* Answer a NEED_GIFT_ID action with 32 caller-drawn random bytes: the host
   originates the claimed handoff and this call flushes its legs, exporter
   first. A stale ticket is a no-op success. */
int32_t glowcap_host_provide_gift_id(GlowcapHost *host, uint64_t ticket, const uint8_t *gift_id, size_t gift_id_len);
/* Report that a NEED_GIFT_ID action could not obtain or provide entropy. The
   claimed handoff settles broken instead of retaining a ticket the embedder has
   already consumed. A stale ticket is a no-op success. */
int32_t glowcap_host_gift_id_failed(GlowcapHost *host, uint64_t ticket);
/* Publish a hosted object a partner on this session can fetch by name (a
   swiss-number). The Host Vat owns the object; this session selects its first
   Port projection. Releasing that session does not run free. On success, free,
   if non-NULL, runs exactly once at Host teardown; a failed construction runs it
   after this call takes ownership. *out_ref receives the opaque Host-scoped
   capability. Refused inside a callback (ctx stays yours on a null-pointer or
   reentry refusal). */
int32_t glowcap_host_session_publish(GlowcapHostSession *session, const uint8_t *name, size_t name_len, GlowcapHostBehavior behavior, void *ctx, GlowcapHostCtxFree free, GlowcapReference *out_ref);
/* Spawn a hosted object in the Host Vat and create its first projection on this
   session, without a fetchable name. It becomes reachable once a reply or
   argument carries the opaque Host-scoped capability written to *out_ref. Same
   free contract as glowcap_host_session_publish. */
int32_t glowcap_host_session_spawn(GlowcapHostSession *session, GlowcapHostBehavior behavior, void *ctx, GlowcapHostCtxFree free, GlowcapReference *out_ref);
/* Spawn a hosted actor and adopt its first root into an owned Host reference.
   No session, alias or wire export is created. Release the returned reference
   through glowcap_host_ref_release. ctx/free follows glowcap_host_publish: null
   and reentry refusals leave ctx yours; after admission free runs exactly once
   on failure, final actor collection or Host release. */
int32_t glowcap_host_spawn(GlowcapHost *host, GlowcapHostBehavior behavior, void *ctx, GlowcapHostCtxFree free, GlowcapReference *out_ref);
/* Publish one hosted object in the Vat owned by this Host and bind name as its
   host-wide alias. Fetch lazily projects the actor onto the requesting Port; a
   deposited gift retains the exact actor and never consults the alias at
   withdrawal. The publication row owns ctx: free, if non-NULL, runs exactly once, at
   glowcap_host_release on success or before this returns on any non-OK outcome
   (the null-pointer and reentry refusals touch nothing and leave ctx yours).
   All-or-nothing over this call's own work: registration failure discards the
   fresh actor and frees ctx, so a retry starts with no partial alias or projection. */
int32_t glowcap_host_publish(GlowcapHost *host, const uint8_t *name, size_t name_len, GlowcapHostBehavior behavior, void *ctx, GlowcapHostCtxFree free);
/* Remove the host-wide alias name. Discovery-only, alias-only: a later fetch of
   the name misses on every session, while capabilities already issued, live Port
   projections, and deposited gifts keep naming the exact actor, which stays in
   the Host's Vat until glowcap_host_release. An absent alias returns
   GLOWCAP_ERR_NOT_FOUND, so a typo is loud instead of an idempotent no-op. A name
   in the reserved durable namespace is refused INVALID_ARGUMENT: minted durable
   publications leave through glowcap_host_remove_durable. */
int32_t glowcap_host_unpublish(GlowcapHost *host, const uint8_t *name, size_t name_len);
/* Publish one hosted object under a freshly minted durable swiss name: a
   reserved-prefix namespace mutable aliases structurally cannot enter,
   unpredictable, never reassigned, and removable only through
   glowcap_host_remove_durable. entropy supplies exactly GLOWCAP_HOST_DURABLE_ENTROPY_LEN caller-drawn
   random bytes (the embedder owns the entropy boundary, as for gift ids). The minted
   swiss is written into out_swiss (swiss_cap of at least GLOWCAP_HOST_DURABLE_SWISS_LEN, or
   BUFFER_TOO_SMALL and nothing published) and the written length is returned.
   ctx/free follow glowcap_host_publish's ownership exactly. The core stores no
   registry across processes: preserve the entropy and republish the actor with
   the same bytes at startup to reproduce the sturdyref; losing either makes the
   old name miss, fail-closed. */
int32_t glowcap_host_publish_durable(GlowcapHost *host, const uint8_t *entropy, size_t entropy_len, GlowcapHostBehavior behavior, void *ctx, GlowcapHostCtxFree free, uint8_t *out_swiss, size_t swiss_cap);
/* Publish an already-held local capability under a durable name. The
   publication retains its own root; the caller's reference stays owned by
   the caller on success and failure. Entropy and output use the same bounds
   as glowcap_host_publish_durable. Foreign capabilities are refused. */
int32_t glowcap_host_publish_reference(GlowcapHost *host, const GlowcapReference *reference, const uint8_t *entropy, size_t entropy_len, uint8_t *out_swiss, size_t swiss_cap);
/* Remove a minted durable publication: the old sturdyref misses from now on,
   while capabilities already issued and deposited gifts keep the exact actor. A
   swiss outside the durable namespace returns INVALID_ARGUMENT (mutable aliases
   leave through glowcap_host_unpublish); an unknown durable name returns
   GLOWCAP_ERR_NOT_FOUND. */
int32_t glowcap_host_remove_durable(GlowcapHost *host, const uint8_t *swiss, size_t swiss_len);
/* Fetch the partner capability published as name, minting a host vow whose id
   lands in *out_vow; the outcome arrives as that vow's SETTLE or FAIL action.
   A fulfilled far capability settles ALREADY enrolled under a node-unique
   token, recorded before the completion is queued, so a reply that
   immediately re-gifts it routes to the right exporter. Refused inside a
   callback. */
int32_t glowcap_host_session_fetch(GlowcapHostSession *session, const uint8_t *name, size_t name_len, uint64_t *out_vow);
/* Enliven the complete canonical persistent sturdyref URI (ADR-0007), minting
   a host vow whose id lands in *out_vow; the live reference arrives as that
   vow's SETTLE action. The URI form is independent of the selected session's
   negotiated profile. Its transport and designator must match that session
   before the swiss namespace is consulted or wire traffic is emitted. A
   dedup-cache hit settles before this returns; a fresh enliven rides
   bootstrap-fetch. Refused inside a callback. */
int32_t glowcap_host_session_enliven(GlowcapHostSession *session, const uint8_t *sturdyref_uri, size_t sturdyref_uri_len, uint64_t *out_vow);
/* Select-or-dial enliven of a canonical persistent sturdyref URI (ADR-0007):
   enliven it over a live session this host already dialed to that peer, or
   stage a dial and finish when you report it. The host vow id lands in
   *out_vow and its outcome arrives as that vow's SETTLE or FAIL action either
   way. A staged dial surfaces as an ordinary GLOWCAP_HOST_ACTION_DIAL: borrow
   it with glowcap_host_pending_dial and answer it with glowcap_host_dialed /
   glowcap_host_dial_failed exactly as a handoff redeem's, so a parked vow's
   id has no session and no row until it settles. Alternate profile spellings use
   glowcap_host_enliven_for_version. Refused inside a callback. */
int32_t glowcap_host_enliven(GlowcapHost *host, const uint8_t *sturdyref_uri, size_t sturdyref_uri_len, uint64_t *out_vow);
/* The same Host-level select-or-dial enliven, parsing the sturdyref's swiss authority under the explicit GLOWCAP_CAPTP_* version that defined its spelling. Use this when the sturdyref arrived over a session whose settled version differs from the Host preference. Invalid versions are refused before any authority or dial state changes. */
int32_t glowcap_host_enliven_for_version(GlowcapHost *host, uint32_t captp_version, const uint8_t *sturdyref_uri, size_t sturdyref_uri_len, uint64_t *out_vow);
/* Fetch a named publication at a typed peer locator through this Host's configured profile. Concrete locators select or open one physical session; an id/via locator is expanded by the Host's Node into its bounded authenticated route schedule. The caller names no CapTP version or codec. The host vow id lands in *out_vow and settles through the ordinary action queue. The locator and name are borrowed for this call; staged work retains its own copy. Refused inside a callback. */
int32_t glowcap_host_fetch_at(GlowcapHost *host, const GlowcapLocatorView *locator, const uint8_t *name, size_t name_len, uint64_t *out_vow);
/* Listen on a far capability this session holds (CapTP op:listen), minting a
   host vow whose id lands in *out_vow; the listen notification arrives as that
   vow's SETTLE or FAIL action. In 1.0, the target may be a far promise or live
   far object; a live object answers immediately. In glowcap-next, the target
   must be a far promise because shortening and settling are promise-only. A
   re-gifted promise routes to its exporter session transparently, and a give in
   the settlement auto-redeems exactly as a fetch's would. The vow is plain: a
   listen makes no claim the result is a capability. Legal inside a callback. */
int32_t glowcap_host_session_listen(GlowcapHostSession *session, const GlowcapReference *target, uint64_t *out_vow);
/* Resolve an opaque capability. An object returns one owned application retain
   in *out_reference and zero in *out_vow, without wire traffic. Release that
   retain with glowcap_host_ref_release. A promise returns a zero reference and
   a settlement vow in *out_vow; its SETTLE/FAIL may carry any value. Inline
   handoffs redeem through the Host. All pointers are required; outputs change
   only on success. Legal inside a callback. */
int32_t glowcap_host_session_resolve(GlowcapHostSession *session, const GlowcapReference *target, GlowcapReference *out_reference, uint64_t *out_vow);
/* Eventual-send through this Host without borrowing a network session. The
   actual target determines its local or foreign home. Input values borrow
   this call; the existing queue owns their copies and capability retains.
   The returned vow is await-only and settles through Host actions. Releasing
   its observer does not cancel admitted work. Refused inside a callback;
   turn_send owns that turn's transactional delivery instead. */
int32_t glowcap_host_send(GlowcapHost *host, const GlowcapReference *target, const uint8_t *verb, size_t verb_len, const GlowcapArgument *args, size_t args_len, uint64_t *out_vow);
/* Eventual-send to an opaque Host-scoped target and mint a host vow for the
   answer; the outcome arrives as that vow's SETTLE or FAIL action. The Host
   chooses local delivery or the owning exporter session. A target or nested
   argument from another Host, or a retired identity, is refused rather than
   being interpreted as a wire position. verb/args are borrowed; the host copies
   what it queues. An empty verb (including (NULL, 0), which the family's ptr+len
   contract admits) is a real message, not an error: it delivers positionally,
   the way Goblins invokes a capability. Legal inside a callback (the send
   encodes when the enclosing call unwinds). */
int32_t glowcap_host_session_send(GlowcapHostSession *session, const GlowcapReference *target, const uint8_t *verb, size_t verb_len, const GlowcapArgument *args, size_t args_len, uint64_t *out_vow);
/* Notification through the target's actual home, with no reply or vow. Input
   values borrow this call; the owning queue retains admitted work. Refused
   inside a callback, where turn_tell owns transactional delivery. */
int32_t glowcap_host_tell(GlowcapHost *host, const GlowcapReference *target, const uint8_t *verb, size_t verb_len, const GlowcapArgument *args, size_t args_len);
/* Fire-and-forget eventual-send: glowcap_host_session_send with no answer and no
   vow. Same routing, refusals, and empty-verb contract. */
int32_t glowcap_host_session_tell(GlowcapHostSession *session, const GlowcapReference *target, const uint8_t *verb, size_t verb_len, const GlowcapArgument *args, size_t args_len);
/* Promise pipelining: eventual-send to a host vow before it resolves, minting a
   new vow for this call's own answer. A local vow (a NEAR send's answer) has no
   wire answer to pipeline against and is refused GLOWCAP_ERR_INVALID_ARGUMENT
   (NotPipelineable); an unknown vow reports GLOWCAP_ERR_NOT_FOUND. The
   empty-verb contract is glowcap_host_session_send's. */
int32_t glowcap_host_vow_send(GlowcapHost *host, uint64_t vow, const uint8_t *verb, size_t verb_len, const GlowcapArgument *args, size_t args_len, uint64_t *out_vow);
/* Fire-and-forget promise-pipelined send: glowcap_host_vow_send with no answer
   and no returned vow. Same target, argument, and empty-verb contract. */
int32_t glowcap_host_vow_tell(GlowcapHost *host, uint64_t vow, const uint8_t *verb, size_t verb_len, const GlowcapArgument *args, size_t args_len);
/* Release one public Host vow. Settlement does not consume the handle: until
   this call succeeds it remains a valid promise-pipeline target, including after
   a fast peer has resolved it. Releasing a far answer emits op:gc-answer; a local
   answer only drops its Host observer. A row already retired with its session is
   a wire-free success. Any other non-OK return consumes nothing and is retryable.
   Single-thread affinity applies: finalizers park the id for the owning runtime
   loop rather than calling this directly. */
int32_t glowcap_host_vow_release(GlowcapHost *host, uint64_t vow);
/* Pipeline an op:index projection against a far host vow, minting a new vow for
   the projected element. Same local-vow and unknown-vow refusals as
   glowcap_host_vow_send; an index above INT64_MAX is refused
   GLOWCAP_ERR_INVALID_ARGUMENT (the wire index is a signed integer). */
int32_t glowcap_host_vow_index(GlowcapHost *host, uint64_t vow, uint64_t index, uint64_t *out_vow);
/* Pipeline an op:untag projection against a far host vow, minting a new vow for
   the unwrapped payload (a single-value Tagged unwraps to that value; a
   variadic one to its value list). tag is borrowed. */
int32_t glowcap_host_vow_untag(GlowcapHost *host, uint64_t vow, const uint8_t *tag, size_t tag_len, uint64_t *out_vow);
/* Pipeline an op:get projection against a far host vow, minting a new vow for
   the named Struct field. Same local-vow and unknown-vow refusals as
   glowcap_host_vow_send; field is borrowed. */
int32_t glowcap_host_vow_get(GlowcapHost *host, uint64_t vow, const uint8_t *field, size_t field_len, uint64_t *out_vow);
/* Install (or clear, with a NULL callback) the live trace: the host reports
   its own session opens, every message's verb in both directions, and session
   closes through callback, on the host's one thread. Views in the event are
   borrowed for the call. The callback must call no host-driving verb. */
int32_t glowcap_host_set_trace(GlowcapHost *host, GlowcapTraceCallback callback, void *ctx);
/* Install (or clear, with a zero capacity) the drained live trace: the host
   captures each fact into a fixed ring of capacity records, each holding up to
   payload_cap bytes of that record's strings, and the embedder pops them with
   glowcap_host_next_trace. This is the route for an embedder that cannot hand
   the library a function pointer. Nothing here grows: a full ring drops the
   newest record and reports the count on the next one it captures, so tracing
   never makes the protocol wait. */
int32_t glowcap_host_set_trace_queue(GlowcapHost *host, size_t capacity, size_t payload_cap);
/* Pop the oldest captured trace record into out_event. Its string views point
   into the queue and stay valid until the next glowcap_host_next_trace call,
   the same borrow glowcap_host_next_action carries. Returns
   GLOWCAP_ERR_WOULD_BLOCK when nothing is captured, so an embedder drains in a
   loop until it sees that code. */
int32_t glowcap_host_next_trace(GlowcapHost *host, GlowcapTraceEvent *out_event);
/* Settle a resolver vow fulfilled with one capability-free value (a value
   naming a capability refuses whole; owning-thread capability values use
   resolver_fulfill_value instead). Top-level: refused inside a callback; the
   settle runs the deferred answers and pumps the sessions they dirtied. A
   successful settle consumes the resolver; preparation failure is retryable.
   A consumed resolver refuses a second settle as INVALID_ARGUMENT, and an id
   this host never minted refuses as NOT_FOUND. */
int32_t glowcap_host_resolver_fulfill(GlowcapHost *host, uint64_t resolver_id, const GlowcapArgument *value);
/* Fulfill a deferred answer with an owning-thread application value.
   Capabilities are projected in the original caller session, using ordinary
   handoff staging for foreign authority. Failed preparation preserves the
   resolver for retry. Top-level and
   consume-on-success, like resolver_fulfill. Plain worker/mailbox data continues
   to use resolver_fulfill. */
int32_t glowcap_host_resolver_fulfill_value(GlowcapHost *host, uint64_t resolver_id, const GlowcapArgument *value);
/* Settle a resolver vow broken with a diagnostic borrowed for the call. The
   same top-level, consume-on-success contract as
   glowcap_host_resolver_fulfill. */
int32_t glowcap_host_resolver_break(GlowcapHost *host, uint64_t resolver_id, const uint8_t *message, size_t message_len);
/* Abandon a deferred answer, top-level. A resolver already consumed by
   session teardown or settlement is complete cleanup. Unminted ids refuse
   NOT_FOUND; other failures leave the operation retryable. */
int32_t glowcap_host_resolver_abandon(GlowcapHost *host, uint64_t resolver_id, const uint8_t *message, size_t message_len);
/* Borrow the session whose Port delivered this callback turn. Trusted local
   owning delivery succeeds with a null session. A nonnull handle is Host-owned
   and lives with that session; do not release it. This identifies the arriving
   connection without reconstructing delivery state outside the core. */
int32_t glowcap_host_turn_session(GlowcapHostTurn *turn, GlowcapHostSession **out_session);
/* From inside a behavior callback, forward this turn's call to an opaque
   Host-scoped target and let this object's own answer settle on the forwarded
   result. This is the caretaker/attenuator primitive. The Host resolves the target and
   every nested capability; a stale or foreign-Host identity is refused. In a
   local eventual or wire-served turn the real answer rides the forwarded vow and *out_reply gets a
   void placeholder; pass your behavior's own out_reply and return GLOWCAP_OK.
   The written reply is BORROWED and valid until the next turn verb or drive on
   this host. The empty-verb contract is glowcap_host_session_send's. */
int32_t glowcap_host_turn_forward(GlowcapHostTurn *turn, const GlowcapReference *target, const uint8_t *verb, size_t verb_len, const GlowcapArgument *args, size_t args_len, GlowcapArgument *out_reply);
/* Atomically defer this turn's answer onto a fresh resolver vow (ADR-0014).
   *out_resolver_id receives the one-shot settle authority used by
   glowcap_host_resolver_fulfill / _break. All rows and the forward listener are
   reserved before publication, so refusal leaves no live resolver and no
   forwarded effect. The behavior returns normally after success; its return
   value resolves nothing once the turn is deferred. */
int32_t glowcap_host_turn_defer(GlowcapHostTurn *turn, uint64_t *out_resolver_id);
/* Defer an answered call; a tell succeeds with zero and creates no resolver.
   Nonzero IDs carry the same one-shot authority as glowcap_host_turn_defer.
   Refusal zeros the output and leaves the current turn unchanged. */
int32_t glowcap_host_turn_defer_if_answer(GlowcapHostTurn *turn, uint64_t *out_resolver_id);
/* From inside a behavior callback, eventual-send to target and mint a Host
   vow for the answer. Trusted local callbacks use the target's actual local
   or foreign home; wire callbacks use their Session routing. Local public
   vows settle through Host actions and support release, without a wire
   pipeline or raw wire listener. Delivery commits with the enclosing turn.
   The empty-verb contract is glowcap_host_session_send's. */
int32_t glowcap_host_turn_send(GlowcapHostTurn *turn, const GlowcapReference *target, const uint8_t *verb, size_t verb_len, const GlowcapArgument *args, size_t args_len, uint64_t *out_vow);
/* From inside a behavior callback, fire-and-forget eventual-send:
   glowcap_host_turn_send with no answer and no vow. Same empty-verb contract. */
int32_t glowcap_host_turn_tell(GlowcapHostTurn *turn, const GlowcapReference *target, const uint8_t *verb, size_t verb_len, const GlowcapArgument *args, size_t args_len);
/* From inside a behavior callback, spawn a hosted object in the Host Vat and
   create its first projection on the Port that delivered this turn. This is how a
   served factory mints a capability it replies with (a task board's create, a
   caretaker wrapping a target), the turn-time form of
   glowcap_host_session_spawn. Same free contract; *out_ref receives the opaque
   Host-scoped capability, ready to ride this turn's own reply. */
int32_t glowcap_host_turn_spawn(GlowcapHostTurn *turn, GlowcapHostBehavior behavior, void *ctx, GlowcapHostCtxFree free, GlowcapReference *out_ref);
/* From inside a behavior callback, break this turn's own answer with message.
   This is how a behavior refuses with a diagnostic, since a non-OK return settles the
   answer broken with only a generic reason. A wire answer breaks inside this
   call; a local eventual answer breaks when its turn unwinds. A no-answer tell
   breaks nothing. Leave out_reply untouched and
   return GLOWCAP_OK from the behavior, whose return value then resolves
   nothing. message is borrowed and copied. */
int32_t glowcap_host_turn_break(GlowcapHostTurn *turn, const uint8_t *message, size_t message_len);
/* Release delta application retains on one opaque Host capability. The Host
   resolves the owning session and emits any required op:gc-exports itself; the
   caller never pairs a capability with a session-local wire position. If that
   session already closed, its already-issued application units remain releaseable
   as wire-free success; every other use is stale. A fully released or foreign-Host
   identity is refused. A non-OK return commits no release, so the same (ref, delta)
   may be retried. OK consumes the release; any later pump cleanup failure becomes
   typed session close and must not invite a duplicate release. Single-thread
   affinity applies: never call this from a finalizer thread. */
int32_t glowcap_host_ref_release(GlowcapHost *host, const GlowcapReference *ref, uint64_t delta);
/* Write to *out_ref the opaque Host-scoped capability currently published under
   name, or return GLOWCAP_ERR_NOT_FOUND when the Host has no such alias. The actor
   in the Host-owned Vat is lazily projected onto session when needed; the
   returned identity itself carries no export position and retains no name. */
int32_t glowcap_host_session_published_ref(GlowcapHostSession *session, const uint8_t *name, size_t name_len, GlowcapReference *out_ref);
/* Break every far vow currently parked on session, queueing each vow's FAIL
   completion inside this call with the partner's retained abort diagnostic when
   one arrived and message otherwise. The session remains open to later work; use
   glowcap_host_session_transport_closed when the byte channel is gone. */
int32_t glowcap_host_session_break_far_vows(GlowcapHostSession *session, const uint8_t *message, size_t message_len);
/* Report that this session's transport is gone. The Host seals session
   admission, retires its routing authority, and queues each pending far vow's
   FAIL completion inside this call, using the partner's retained abort
   diagnostic when one arrived and message otherwise. Memory remains owned until
   glowcap_host_session_release. */
int32_t glowcap_host_session_transport_closed(GlowcapHostSession *session, const uint8_t *message, size_t message_len);
/* Record the exporter locator to embed in gives whose exporter is session, overriding the session record. Null clears the override; otherwise the Host validates and clones the borrowed locator view. */
int32_t glowcap_host_session_set_exporter_location(GlowcapHostSession *session, const GlowcapLocatorView *locator);
/* Read the typed cause of this session's most recent LOCAL dispatch failure
   into *out (the shared GlowcapLastAbort layout; byte views process-static,
   never freed). Returns GLOWCAP_OK when a failure has been recorded, or
   GLOWCAP_ERR_WOULD_BLOCK when none has. The flat per-feed return code names
   the failure family; this names the member. */
int32_t glowcap_host_session_last_abort(GlowcapHostSession *session, GlowcapLastAbort *out);
/* Read the PARTNER'S retained op:abort: the abort kind's wire name (a
   process-static view, e.g. "ProtocolError") into
   *out_kind_name / *out_kind_name_len, and up to cap bytes of its bounded
   diagnostic into out_msg, with the retained length in *out_len. Returns
   GLOWCAP_ERR_WOULD_BLOCK when no partner abort has arrived. Any out-pointer
   may be NULL to skip that piece. */
int32_t glowcap_host_session_partner_abort(GlowcapHostSession *session, const uint8_t **out_kind_name, size_t *out_kind_name_len, uint8_t *out_msg, size_t cap, size_t *out_len);
/* The partner identity this session's handshake proved: the partner's session
   public key, the location designator it signed, and the verbatim
   <ocapn-peer> record those came from.

   This answers "who am I talking to" without taking the partner's word for
   it. A keyed op:start-session carries an Ed25519 signature over the
   partner's own <my-location> record, and the engine verifies that
   signature before the session opens and before any of these bytes are
   learned. The signed span covers the whole location record, so designator
   is bound to session_key by the same signature. An application can require
   that a locator a caller CLAIMS names the key that caller actually proved,
   and refuse a mismatch.

   Views are session-owned. The bytes are written once when the partner's
   handshake half arrives and are never rewritten, so they stay valid until
   glowcap_host_session_release, or until the host is torn down. */
typedef struct GlowcapPartnerIdentity {
    /* The partner's session public key. Always present on GLOWCAP_OK. */
    const uint8_t *session_key;
    size_t session_key_len;
    /* The designator the partner signed, or NULL when its location carried none. */
    const uint8_t *designator;
    size_t designator_len;
    /* The verbatim location record, or NULL when the apply path captured none. */
    const uint8_t *locator_record;
    size_t locator_record_len;
    /* How the durable identity in designator was authenticated, one of the
GLOWCAP_DURABLE_PROVENANCE_* values. It is derived from the evidence this one
session holds, never from its transport's name, so two sessions on the same
transport can answer differently.

Session identity, durable identity, and this provenance are three separate
facts: a caller that requires a proved durable peer reads this, never a
comparison of designator against session_key. Each session draws its own
signing key, so a session key is not an identity and the two never match. */
    uint32_t provenance;
} GlowcapPartnerIdentity;

/* Borrow this session's verified partner identity into *out: the partner's
   session public key, the location designator it signed, and the verbatim
   location record those came from.

   A GLOWCAP_OK return always means the signature was checked. Before the
   partner's op:start-session has arrived with a key this returns
   GLOWCAP_ERR_WOULD_BLOCK, and a session opened without partner verification
   returns GLOWCAP_ERR_SESSION rather than an identity nothing proved. That
   refusal is the contract: you cannot read an unverified identity through this
   entry point, so you never have to remember to ask whether the bytes were
   checked. */
int32_t glowcap_host_session_partner_identity(GlowcapHostSession *session, GlowcapPartnerIdentity *out);
/* Testify what the code that realized this connection proved about its far
   end: designator is the durable key that proof names, as a locator writes it.
   An iroh listener passes what glowcap_iroh_conn_remote_node_id read off the
   QUIC handshake; a WebRTC peer passes the identity its signaling
   authorized.

   This library realizes nothing at the byte-fed tier. You own the sockets, so
   you are the realizer, and this is the only way that proof reaches a session.
   Without it the session reports unauthenticated durable provenance.

   Call it after opening the session and before feeding the first partner byte.
   GLOWCAP_ERR_SESSION means the partner's op:start-session was already applied,
   so the proof is too late to weigh. GLOWCAP_ERR_INVALID_ARGUMENT means the
   designator does not spell a durable key, or names a different key from one
   this connection's realizer already asserted. Asserting the same key twice is
   the same statement made twice and succeeds. */
int32_t glowcap_host_session_bind_verified_channel_key(GlowcapHostSession *session, const uint8_t *designator, size_t designator_len);
/* Copy the calling thread's last glowcap_host_* error into out_buf, the host
   sibling of glowcap_last_error, reading this archive's own per-thread slot.
   Copies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or cap
   0 queries the length. Returns the full message length, or 0 when none is set. Every status-returning call clears the slot before validation; read it immediately after a failing call, and treat zero length as no additional detail. */
size_t glowcap_host_last_error(uint8_t *out_buf, size_t cap);
/* Clear the calling thread's glowcap_host_* last-error slot. */
void glowcap_host_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* GLOWCAP_HOST_H */
