/* Generated from src/c_abi/driver/mod.zig by tools/header_gen_driver.zig.
   Do not edit by hand: run `zig build gen-header-driver`.
   Function signatures are reflected from the Zig source, so this header
   cannot drift from the implementation.

   The byte-fed host tier's public C ABI: a separate archive
   (libpancake_driver) from libpancake_ocapn (ADR-0059, ADR-0072). It is a
   companion, not a superset: it exports only the pancake_host_* family and
   shares the value vocabulary (PancakeFrame, PancakeManagedFrame,
   PancakeContext, PancakeArgument, PancakeReference, PancakeLastAbort) and
   the return codes by layout with pancake_ocapn.h (included below), so a
   consumer links BOTH archives and includes BOTH headers. The family has
   its own last-error slot, read through pancake_host_last_error rather
   than pancake_ocapn's pancake_last_error. */
#ifndef PANCAKE_DRIVER_H
#define PANCAKE_DRIVER_H

#include <stddef.h>
#include <stdint.h>
#include "pancake_ocapn.h"

#ifdef __cplusplus
extern "C" {
#endif
/* A PancakeHost is the multi-session CapTP host for an embedder that
   owns its own loop, sockets, and entropy (ADR-0072). The library owns every
   decision — routing, three-party redeem, gift origination — and the embedder
   moves bytes: feed inbound frames with pancake_host_session_feed, write what
   pancake_host_session_take_outbound drains, and honor the action queue.

   THE ONE LOOP RULE. After any top-level pancake_host_* call returns OK,
   drain pancake_host_next_action until PANCAKE_ERR_WOULD_BLOCK, honoring each
   action: DIAL — open your own session with the action's transport and
   designator (pancake_host_session_open_dialed_locator), drive its session open,
   then report
   pancake_host_dialed (or pancake_host_dial_failed); FLUSH — drain
   take_outbound on that session until WOULD_BLOCK and write the frames;
   NEED_GIFT_ID — draw 32 random bytes and call pancake_host_provide_gift_id;
   SETTLE / FAIL — route the outcome to whatever awaits the vow the action's
   ticket names. Nothing in the library enforces the drain — honoring it is
   the embedder's side of the contract, and an ignored action strands the
   dial, flush, handoff, or settlement it carries.

   THREADING AND REENTRANCY. One thread (or one green-thread scheduler)
   drives one host; nothing locks. The one callback — a behavior answering
   a deliver — fires on the thread executing the enclosing pancake_host_*
   call. Inside it the enqueueing verbs are legal — session_send/session_tell,
   vow_send/vow_index/vow_untag, the turn verbs (with the callback's own turn),
   gc_release, session_set_exporter_location, session_session_open, the error
   readers — and their effects encode and pump when the enclosing call
   unwinds. The host-driving verbs (feed, feed_bytes, take_outbound,
   next_action, dialed/dial_failed/provide_gift_id, open_*, publish/spawn,
   fetch/enliven, break_far_vows, release) are refused there with
   PANCAKE_ERR_INVALID_ARGUMENT. */

/* A byte-fed multi-session CapTP host: one identity, one routing and
   redeem authority, many sessions. Created by pancake_host_new /
   pancake_host_new_in; released by pancake_host_release, always after its
   sessions. */
typedef struct PancakeHost PancakeHost;

/* One byte-fed CapTP session a host minted. Released by
   pancake_host_session_release, always before the host. */
typedef struct PancakeHostSession PancakeHostSession;

/* The current turn, passed to a behavior callback so it can forward and
   eventual-send while handling a deliver (pancake_host_turn_*). Valid only
   for the duration of that callback: stashing the pointer and using it
   after the callback returns is undefined behavior. */
typedef struct PancakeHostTurn PancakeHostTurn;

/* A hosted object's behavior, invoked on each deliver. verb/args are
   borrowed for the call, and the vat copies *out_reply's payload the
   instant you return, so its bytes must stay valid across the return
   (point them at your ctx or a buffer you own, not a callback stack
   local). Any non-OK return settles the answer broken
   with a generic reason. */
typedef int32_t (*PancakeHostBehavior)(void *ctx, PancakeHostTurn *turn,
    const uint8_t *verb, size_t verb_len, const PancakeArgument *args,
    size_t args_len, PancakeArgument *out_reply);

/* Release a hosted object's ctx when the object is torn down. NULL to keep
   ctx. Runs exactly once per registration that took ownership; must call
   no pancake_host_* function. */
typedef void (*PancakeHostCtxFree)(void *ctx);
/* PancakeHostAction.kind: dial the exporter at locator, then report pancake_host_dialed / pancake_host_dial_failed with the ticket. */
#define PANCAKE_HOST_ACTION_DIAL 0
/* PancakeHostAction.kind: drain pancake_host_session_take_outbound on session until WOULD_BLOCK and write the frames. */
#define PANCAKE_HOST_ACTION_FLUSH 1
/* PancakeHostAction.kind: draw 32 random bytes and feed them to pancake_host_provide_gift_id with the ticket. */
#define PANCAKE_HOST_ACTION_NEED_GIFT_ID 2
/* PancakeHostAction.kind: the vow named by ticket settled fulfilled with value; route the outcome to whatever awaits it. */
#define PANCAKE_HOST_ACTION_SETTLE 3
/* PancakeHostAction.kind: the vow named by ticket settled broken with message; route the outcome to whatever awaits it. */
#define PANCAKE_HOST_ACTION_FAIL 4
/* PancakeHostAction.kind: the host condemned session mid-pump (local turn budget exceeded); write its queued abort, close its transport, and release the session. */
#define PANCAKE_HOST_ACTION_CLOSE 5
/* Default maximum admissible frame for pancake_host_new / pancake_host_new_in (bytes): mirrors session.SessionLimits.max_frame_bytes (1 MiB). */
#define PANCAKE_DEFAULT_FRAME_CAP 1048576
/* Bound on one turn's synchronous local Forward chase (caretaker over attenuator). Hop N+1 breaks the answer instead of spinning. */
#define PANCAKE_MAX_LOCAL_FORWARD_HOPS 256

/* One embedder effect popped from pancake_host_next_action. kind selects the
   live fields: DIAL carries ticket (its report-back handle), the full
   ocapn:// exporter locator in locator/locator_len, and the locator's parsed
   pieces — transport, designator, and its direct-addresses hint, each empty
   when the locator does not parse as an ocapn URI or when the hint is
   absent — so the dial executor never re-parses the URI. FLUSH carries session;
   NEED_GIFT_ID carries ticket. SETTLE carries the settled vow id in ticket
   and the fulfilled value in value; FAIL carries the vow id in ticket and
   the break reason in message/message_len. Every popped byte view and
   value's sub-structure are host-owned and valid until the NEXT
   pancake_host_next_action call, which frees them. Unused fields are zeroed. */
typedef struct PancakeHostAction {
    /* A PANCAKE_HOST_ACTION_* value. */
    uint32_t kind;
    /* DIAL: the report-back handle; SETTLE/FAIL: the vow that settled. */
    uint64_t ticket;
    PancakeHostSession *session;
    const uint8_t *locator;
    size_t locator_len;
    const uint8_t *transport;
    size_t transport_len;
    const uint8_t *designator;
    size_t designator_len;
    const uint8_t *direct_addresses_hint;
    size_t direct_addresses_hint_len;
    /* SETTLE: the fulfilled value; zeroed otherwise. */
    PancakeArgument value;
    /* FAIL: the break reason; NULL otherwise. */
    const uint8_t *message;
    size_t message_len;
} PancakeHostAction;

/* One shared arm callback for PancakeHostPumpHooks (flush, close,
   need_gift_id, complete for SETTLE/FAIL, dial). Return PANCAKE_OK or a
   real PANCAKE_ERR_*. When out_progressed is non-NULL, set it to 1 if the
   arm counts as quiescence progress; leave 0 for a handled notice a
   sibling shuttle already covers. action views are host-owned until the
   next pancake_host_next_action (pancake_host_pump_drain pops internally). */
typedef int32_t (*PancakeHostPumpArmFn)(void *ctx, PancakeHost *host,
    const PancakeHostAction *action, uint32_t *out_progressed);
/* Opt-in embedder hooks for pancake_host_pump_drain (ADR-0072 fifth
   amendment). NULL arm pointers skip that kind (no error, no progress).
   The pull-queue remains normative — this is a convenience wrapper's
   callback surface, not a replacement for pancake_host_next_action. */
typedef struct PancakeHostPumpHooks {
    /* Caller context passed to every arm. */
    void *ctx;
    /* FLUSH arm, or NULL to skip. */
    PancakeHostPumpArmFn flush;
    /* CLOSE arm, or NULL to skip. */
    PancakeHostPumpArmFn close;
    /* NEED_GIFT_ID arm, or NULL to skip. */
    PancakeHostPumpArmFn need_gift_id;
    /* SETTLE and FAIL arm, or NULL to skip. */
    PancakeHostPumpArmFn complete;
    /* DIAL arm, or NULL to skip. */
    PancakeHostPumpArmFn dial;
} PancakeHostPumpHooks;

/* Create a byte-fed host bound to the caller-drawn 32-byte Ed25519 identity
   seed (the host never draws entropy), allocating through the library
   allocator. frame_cap sizes every session's maximum admissible frame; a
   nonzero verify_partner keeps partner-signature verification on (the secure
   default); codec is the PANCAKE_CODEC_* wire grammar (pancake_ocapn.h) every
   session this host mints negotiates in — both ends of a session must
   carry the same value, as on the peer tier's _negotiated constructors;
   local_turn_budget is 0 = unbounded (same default as Zig Host + Bridge);
   nonzero caps local-turn amplification per drive (ADR-0076).
   *out_host receives the handle; release with pancake_host_release. */
int32_t pancake_host_new(const uint8_t *seed, size_t seed_len, size_t frame_cap, uint32_t verify_partner, uint32_t codec, uint32_t local_turn_budget, PancakeHost **out_host);
/* pancake_host_new allocating every byte the host owns through context's host
   allocator (pancake_context_new_with_allocator). */
int32_t pancake_host_new_in(PancakeContext *context, const uint8_t *seed, size_t seed_len, size_t frame_cap, uint32_t verify_partner, uint32_t codec, uint32_t local_turn_budget, PancakeHost **out_host);
/* Release the host and everything it owns: every still-open session (each
   still-parked vow breaks inside this call, its undrained completion freed
   with the rest of the action queue), the vow map, parked actions, the node,
   and the giftable rows (each giftable's free runs exactly once here). NULL is
   a no-op. Session (PancakeHostSession) handles this host minted are freed with it —
   never touch one after its host is gone. Refused (last error set, nothing freed) from
   inside a callback. */
void pancake_host_release(PancakeHost *host);
/* Derive the canonical key designator (exactly 64 lowercase hex digits) from a
   32-byte Ed25519 identity seed — the public half of the key pancake_host_new
   signs with. Writes 64 bytes into out (out_len must be at least 64). Used by a
   keyed-tcp listener whose Node identity is the locator designator (ADR-0075). */
int32_t pancake_host_designator_from_seed(const uint8_t *seed, size_t seed_len, uint8_t *out, size_t out_len);
/* Record the designator this host's dials sign as their own dialable address (a
   host that also listens). designator is borrowed and copied into the host's
   retained buffer; longer than 64 bytes is refused
   PANCAKE_ERR_INVALID_ARGUMENT, and empty resets to the unreachable-client
   placeholder. */
int32_t pancake_host_set_self_designator(PancakeHost *host, const uint8_t *designator, size_t len);
/* Mint the dialing half from an already-parsed locator (transport +
   designator), the same pieces a DIAL action carries. The keyed op:start-session
   is signed under the host identity and encoded before this returns, so drain
   take_outbound (a FLUSH action is queued) and drive the handshake byte-fed.
   Every host-wide giftable (pancake_host_publish) is published on the new
   session before it is returned. A URI-holding caller parses first
   (pancake_uri_parse_peer) and passes the pieces — there is no parallel
   URI-string mint entry. The dialed hello does not consume a direct-addresses
   hint. *out_session is host-owned; release with pancake_host_session_release. */
int32_t pancake_host_session_open_dialed_locator(PancakeHost *host, const uint8_t *transport, size_t transport_len, const uint8_t *designator, size_t designator_len, PancakeHostSession **out_session);
/* Mint the accepting half of a connection your own listener produced: the keyed
   op:start-session signs the listener's own transport/designator — the key
   designator for keyed-tcp, the address designator for tcp — and the locator a
   give made on this host names as the exporter location. On keyed-tcp,
   direct_addresses_hint is the bound host:port riding the signed locator
   (borrowed; NULL/0 = none, refused for keyed-tcp because TCP has no discovery);
   an address-designator transport ignores it. Same giftable replay, flush, and
   release contract as pancake_host_session_open_dialed_locator. */
int32_t pancake_host_session_open_accepted(PancakeHost *host, const uint8_t *transport, size_t transport_len, const uint8_t *designator, size_t designator_len, const uint8_t *direct_addresses_hint, size_t direct_addresses_hint_len, PancakeHostSession **out_session);

/* PancakeDialPlan.shape: open a TCP socket to host:port (tcp, keyed-tcp). */
#define PANCAKE_DIAL_SHAPE_HOST_PORT 0
/* PancakeDialPlan.shape: dial an iroh endpoint by node id (the designator). */
#define PANCAKE_DIAL_SHAPE_IROH 1
/* PancakeDialPlan.reach_kind (iroh shape): the relay-less direct posture. */
#define PANCAKE_DIAL_REACH_DIRECT 0
/* PancakeDialPlan.reach_kind (iroh shape): the node's own configured redeem posture. */
#define PANCAKE_DIAL_REACH_CONFIGURED 1
/* PancakeDialPlan.reach_kind (iroh shape): the caller posture carried in reach_value. */
#define PANCAKE_DIAL_REACH_EXPLICIT 2
/* pancake_host_plan_dial posture_policy: a redeem (a DIAL action) — direct when a hint is present, else the node's configured posture. */
#define PANCAKE_DIAL_POSTURE_REDEEM 0
/* pancake_host_plan_dial posture_policy: a connect carrying a posture in posture_value. */
#define PANCAKE_DIAL_POSTURE_EXPLICIT 1
/* pancake_host_plan_dial posture_policy: a connect that named no posture; an iroh dial refuses PANCAKE_ERR_INVALID_ARGUMENT. */
#define PANCAKE_DIAL_POSTURE_EXPLICIT_NONE 2

/* A resolved dial from pancake_host_plan_dial: what byte channel to open and
   how. shape (PANCAKE_DIAL_SHAPE_*) selects the live fields — HOST_PORT fills
   host/host_len/port, IROH fills addresses/addresses_len and the reachability.
   Every view borrows the transport/designator/hint the caller passed in, so
   the plan is valid only while those buffers are. */
typedef struct PancakeDialPlan {
    /* A PANCAKE_DIAL_SHAPE_* value. */
    uint32_t shape;
    /* HOST_PORT: the resolved TCP host (borrows the designator or hint). */
    const uint8_t *host;
    size_t host_len;
    /* HOST_PORT: the resolved TCP port. */
    uint16_t port;
    /* IROH: the direct-addresses to dial (borrows the hint verbatim). */
    const uint8_t *addresses;
    size_t addresses_len;
    /* IROH: a PANCAKE_DIAL_REACH_* value. */
    uint32_t reach_kind;
    /* IROH: the caller posture when reach_kind is PANCAKE_DIAL_REACH_EXPLICIT. */
    uint32_t reach_value;
} PancakeDialPlan;

/* A resolved accept from pancake_host_plan_accept: what an accepted
   session signs as its own locator. Views borrow the caller's input,
   except the address-transport empty-address fallback, which is the static
   unreachable-client placeholder. */
typedef struct PancakeAcceptPlan {
    /* The designator a partner names this listener by. */
    const uint8_t *designator;
    size_t designator_len;
    /* The direct-addresses hint a partner dials it at (empty for tcp/iroh). */
    const uint8_t *direct_addresses_hint;
    size_t direct_addresses_hint_len;
} PancakeAcceptPlan;

/* Resolve a dial without opening a socket: the transport dispatch, designator
   validation, host:port resolution, and iroh reachability decision every binding
   used to re-express, done once here. transport/designator are the locator's
   pieces (a DIAL action carries them parsed); direct_addresses_hint is the
   locator's direct-addresses hint (NULL/0 = none); posture_policy is a
   PANCAKE_DIAL_POSTURE_* choosing the iroh reachability rule, with posture_value
   the caller's posture under PANCAKE_DIAL_POSTURE_EXPLICIT. On PANCAKE_OK
   *out_plan is filled with views borrowing the caller's buffers; a bad locator
   returns PANCAKE_ERR_INVALID_ARGUMENT (pancake_host_last_error carries which).
   Open the channel the plan names, then feed it to
   pancake_host_session_open_dialed_locator. */
int32_t pancake_host_plan_dial(const uint8_t *transport, size_t transport_len, const uint8_t *designator, size_t designator_len, const uint8_t *direct_addresses_hint, size_t direct_addresses_hint_len, uint32_t posture_policy, uint32_t posture_value, PancakeDialPlan *out_plan);
/* Resolve what an accepted session signs, without a socket. transport is the
   accepted transport; server_designator is the listener's own signing designator
   (its key for a key transport, unused for an address transport);
   accepted_local_addr is what the accept reported (NULL/0 when unavailable). On
   PANCAKE_OK *out_plan is filled with views borrowing the caller's input, except
   the address-transport empty-address fallback (the static unreachable-client
   placeholder). Feed the result to pancake_host_session_open_accepted. */
int32_t pancake_host_plan_accept(const uint8_t *transport, size_t transport_len, const uint8_t *server_designator, size_t server_designator_len, const uint8_t *accepted_local_addr, size_t accepted_local_addr_len, PancakeAcceptPlan *out_plan);

/* Release one session: its still-parked far vows break (their FAIL
   completions queue inside this call), the node retires it — stranded
   withdraws fail closed, so SIBLING sessions' vows may break here too — and
   the shell is freed. NULL is a no-op; refused (last error set, the session
   kept) from inside a callback. */
void pancake_host_session_release(PancakeHostSession *session);
/* Nonzero once the keyed handshake has completed and the session is open. */
int32_t pancake_host_session_session_open(PancakeHostSession *session);
/* Feed one inbound frame you read from your own transport (borrowed for the
   call): behavior callbacks fire and vow completions queue inside, then the
   node actions the dispatch queued pump and every touched session's
   outbound encodes. A
   failure classifies through the shared taxonomy (PANCAKE_ERR_CODEC / _SESSION
   / _INTERNAL); after any failure still drain take_outbound — the peer
   projected a typed op:abort for the partner — then read
   pancake_host_session_last_abort for the typed cause. */
int32_t pancake_host_session_feed(PancakeHostSession *session, const PancakeFrame *frame_in);
/* Feed a byte-stream chunk you read from your own transport (borrowed for the
   call). The library owns framing: the session's codec delimits each complete
   frame at the front of bytes — both codecs, both frame shapes — and
   dispatches it exactly as pancake_host_session_feed, so you just move bytes and
   keep the tail. *out_consumed receives the count of leading bytes consumed;
   drop them and extend the remainder with your next read (a partial frame is
   not an error — OK with a smaller count, possibly zero). Consumption also
   stops at the frame that completes the keyed handshake: bytes coalesced
   behind the hello stay in the tail while you act on the fresh session
   (publish, fetch), and your next call feeds them. A frame exceeding
   the session's frame cap is refused PANCAKE_ERR_FRAME_TOO_LARGE; any other
   failure classifies as pancake_host_session_feed's do. After any failure
   *out_consumed is zero and the session is closing: drain take_outbound (a
   typed op:abort is queued for the partner) and release the session. */
int32_t pancake_host_session_feed_bytes(PancakeHostSession *session, const uint8_t *bytes, size_t len, size_t *out_consumed);
/* Drain one encoded outbound frame as an *owned* managed frame you write to
   your transport and free through pancake_managed_frame_release. Returns
   PANCAKE_OK with *out_frame set, or PANCAKE_ERR_WOULD_BLOCK (with *out_frame
   untouched) when the queue is empty. Refused inside a callback. */
int32_t pancake_host_session_take_outbound(PancakeHostSession *session, PancakeManagedFrame *out_frame);
/* Pop the next embedder action into *out_action, or return
   PANCAKE_ERR_WOULD_BLOCK when none is pending. A popped action's byte views —
   a DIAL's locator pieces, a SETTLE's value sub-structure, a FAIL's message —
   are host-owned and valid until the NEXT pancake_host_next_action call, which
   frees them. See the one loop rule in the header preamble. Refused inside a
   callback. */
int32_t pancake_host_next_action(PancakeHost *host, PancakeHostAction *out_action);
/* Opt-in convenience drain over pancake_host_next_action (ADR-0072 fifth
   amendment). Still pops through the pull-queue internally; does not replace
   it. hooks may be NULL (every action is discarded). *out_acted is 1 when any
   arm reported progress (optional, may be NULL). See PancakeHostPumpHooks. */
int32_t pancake_host_pump_drain(PancakeHost *host, const PancakeHostPumpHooks *hooks, uint32_t *out_acted);
/* Report a DIAL action's success: session is an open_dialed_locator against that
   action's locator parts, driven to an open session. The host withdraws every
   give waiting on the ticket; the withdraws, their settles, and their flushes
   pump inside this call. A stale ticket is a no-op success. */
int32_t pancake_host_dialed(PancakeHost *host, uint64_t ticket, PancakeHostSession *session);
/* Report a DIAL action's failure: every redeem waiting on the ticket breaks
   with reason, its FAIL completion queued inside this call. A stale ticket is a
   no-op success. */
int32_t pancake_host_dial_failed(PancakeHost *host, uint64_t ticket, const uint8_t *reason, size_t reason_len);
/* Answer a NEED_GIFT_ID action with 32 caller-drawn random bytes: the host
   originates the claimed handoff and this call flushes its legs, exporter
   first. A stale ticket is a no-op success. */
int32_t pancake_host_provide_gift_id(PancakeHost *host, uint64_t ticket, const uint8_t *gift_id, size_t gift_id_len);
/* Publish a hosted object a partner on this one session can fetch by name (a
   swiss-number). The object is behavior/ctx, driven like any native actor;
   free, if non-NULL, runs exactly once when the object is torn down (session
   or host release) or when this call fails after taking ownership.
   *out_export_position receives the bound export. Refused inside a callback
   (ctx stays yours on a null-pointer or reentry refusal). */
int32_t pancake_host_session_publish(PancakeHostSession *session, const uint8_t *name, size_t name_len, PancakeHostBehavior behavior, void *ctx, PancakeHostCtxFree free, uint64_t *out_export_position);
/* Spawn a hosted object at a fresh export position on this session, without
   a fetchable name — reachable once some reply or argument carries its
   reference. Same free contract as pancake_host_session_publish. */
int32_t pancake_host_session_spawn(PancakeHostSession *session, PancakeHostBehavior behavior, void *ctx, PancakeHostCtxFree free, uint64_t *out_export_position);
/* Publish a hosted object host-wide: under name on every session now open
   and every future one, so a gift naming that swissnum resolves against
   whichever session a recipient withdraws on — this is what makes a three-party
   withdraw find the object. The giftable row owns ctx: free, if non-NULL, runs
   exactly once, at pancake_host_release (the per-session bridges never free
   it). A failure after the row is recorded keeps the row and that ownership; a
   null-pointer or reentry refusal leaves ctx yours. */
int32_t pancake_host_publish(PancakeHost *host, const uint8_t *name, size_t name_len, PancakeHostBehavior behavior, void *ctx, PancakeHostCtxFree free);
/* Fetch the partner capability published as name, minting a host vow whose id
   lands in *out_vow; the outcome arrives as that vow's SETTLE or FAIL action.
   A fulfilled far capability settles ALREADY enrolled under a node-unique
   token — recorded before the completion is queued, so a reply that
   immediately re-gifts it routes to the right exporter. Refused inside a
   callback. */
int32_t pancake_host_session_fetch(PancakeHostSession *session, const uint8_t *name, size_t name_len, uint64_t *out_vow);
/* Enliven the sturdyref published behind swissnum (ADR-0012), minting a host
   vow whose id lands in *out_vow; the live reference arrives as that vow's
   SETTLE action. A dedup-cache hit settles before this returns — the
   completion is already queued — and a fresh enliven rides bootstrap-fetch,
   the host recording the enlivenment itself before the completion is queued.
   Refused inside a callback. */
int32_t pancake_host_session_enliven(PancakeHostSession *session, const uint8_t *swissnum, size_t swissnum_len, uint64_t *out_vow);
/* Eventual-send to target and mint a host vow for the answer; the outcome
   arrives as that vow's SETTLE or FAIL action. A NEAR target (an export this host bound) runs
   in-process; a FAR target routes through the host, so a redeemed or fetched
   token rides its exporter session transparently. A far argument foreign to
   the routed session is refused whole (PANCAKE_ERR_INVALID_ARGUMENT) rather
   than mis-encoded; a retired token reports PANCAKE_ERR_NOT_FOUND. verb/args
   are borrowed; the host copies what it queues. Legal inside a callback (the
   send encodes when the enclosing call unwinds). */
int32_t pancake_host_session_send(PancakeHostSession *session, const PancakeReference *target, const uint8_t *verb, size_t verb_len, const PancakeArgument *args, size_t args_len, uint64_t *out_vow);
/* Fire-and-forget eventual-send: pancake_host_session_send with no answer and no
   vow. Same routing and refusals. */
int32_t pancake_host_session_tell(PancakeHostSession *session, const PancakeReference *target, const uint8_t *verb, size_t verb_len, const PancakeArgument *args, size_t args_len);
/* Promise pipelining: eventual-send to a host vow before it resolves, minting a
   new vow for this call's own answer. A local vow (a NEAR send's answer) has no
   wire answer to pipeline against and is refused PANCAKE_ERR_INVALID_ARGUMENT
   (NotPipelineable); an unknown vow reports PANCAKE_ERR_NOT_FOUND. */
int32_t pancake_host_vow_send(PancakeHost *host, uint64_t vow, const uint8_t *verb, size_t verb_len, const PancakeArgument *args, size_t args_len, uint64_t *out_vow);
/* Pipeline an op:index projection against a far host vow, minting a new vow for
   the projected element. Same local-vow and unknown-vow refusals as
   pancake_host_vow_send; an index above INT64_MAX is refused
   PANCAKE_ERR_INVALID_ARGUMENT (the wire index is a signed integer). */
int32_t pancake_host_vow_index(PancakeHost *host, uint64_t vow, uint64_t index, uint64_t *out_vow);
/* Pipeline an op:untag projection against a far host vow, minting a new vow for
   the unwrapped payload (a single-value Tagged unwraps to that value; a
   variadic one to its value list). tag is borrowed. */
int32_t pancake_host_vow_untag(PancakeHost *host, uint64_t vow, const uint8_t *tag, size_t tag_len, uint64_t *out_vow);
/* From inside a behavior callback, forward this turn's call to target and let
   this object's own answer settle on the forwarded result — the
   caretaker/attenuator primitive. target resolves within the turn's own
   session: NEAR to the local object at that export, FAR through the host's
   routing (refused PANCAKE_ERR_INVALID_ARGUMENT when the route or any far
   argument leaves this session). In a wire-served turn the real answer rides
   the forwarded vow and *out_reply gets a void placeholder; pass your
   behavior's own out_reply and return PANCAKE_OK. The written reply is BORROWED
   — valid until the next turn verb or drive on this host. */
int32_t pancake_host_turn_forward(PancakeHostTurn *turn, const PancakeReference *target, const uint8_t *verb, size_t verb_len, const PancakeArgument *args, size_t args_len, PancakeArgument *out_reply);
/* From inside a behavior callback, eventual-send to target and mint a host vow
   for the answer — the same routing and refusals as pancake_host_session_send, on
   the turn's own session. The send encodes when the enclosing top-level call
   unwinds. */
int32_t pancake_host_turn_send(PancakeHostTurn *turn, const PancakeReference *target, const uint8_t *verb, size_t verb_len, const PancakeArgument *args, size_t args_len, uint64_t *out_vow);
/* From inside a behavior callback, fire-and-forget eventual-send —
   pancake_host_turn_send with no answer and no vow. */
int32_t pancake_host_turn_tell(PancakeHostTurn *turn, const PancakeReference *target, const uint8_t *verb, size_t verb_len, const PancakeArgument *args, size_t args_len);
/* From inside a behavior callback, spawn a hosted object at a fresh export
   position on the turn's own session — how a served factory mints the
   capability it replies with (a task board's create, a caretaker wrapping a
   target), the turn-time form of pancake_host_session_spawn. Same free contract;
   *out_export_position receives the bound export, ready to ride this turn's
   own reply as a NEAR reference. */
int32_t pancake_host_turn_spawn(PancakeHostTurn *turn, PancakeHostBehavior behavior, void *ctx, PancakeHostCtxFree free, uint64_t *out_export_position);
/* From inside a behavior callback, break this turn's own answer with message —
   how a behavior refuses with a diagnostic, since a non-OK return settles the
   answer broken with only a generic reason. The answer resolves broken inside
   this call (a no-answer tell breaks nothing); leave out_reply untouched and
   return PANCAKE_OK from the behavior, whose return value then resolves
   nothing. message is borrowed and copied. */
int32_t pancake_host_turn_break(PancakeHostTurn *turn, const uint8_t *message, size_t message_len);
/* Release delta references on the fetched capability token holds: the token
   resolves through the host to its home session and real wire import, and
   the release rides that peer as op:gc-exports (a FLUSH action follows). A dead
   home is a no-op success — the session teardown already reclaimed the counts.
   An id below the token range is refused PANCAKE_ERR_INVALID_ARGUMENT.
   Single-thread affinity applies: never call this from a finalizer thread. */
int32_t pancake_host_gc_release(PancakeHost *host, uint64_t token, uint64_t delta);
/* Break every far vow still parked on session, queueing each vow's FAIL
   completion inside this call — with the partner's retained abort diagnostic
   when one arrived, else message. Call it when your transport reports the
   connection gone. */
int32_t pancake_host_session_break_far_vows(PancakeHostSession *session, const uint8_t *message, size_t message_len);
/* Record the exporter locator to embed in gives whose exporter is
   session, overriding the session record; empty clears the override. locator is
   a borrowed Syrup <ocapn-peer> record (the bytes pancake_encode_peer_locator
   returns); a URI or other non-record spelling fails with
   PANCAKE_ERR_INVALID_ARGUMENT. */
int32_t pancake_host_session_set_exporter_location(PancakeHostSession *session, const uint8_t *locator, size_t locator_len);
/* Read the typed cause of this session's most recent LOCAL dispatch failure
   into *out (the shared PancakeLastAbort layout; byte views process-static,
   never freed). Returns PANCAKE_OK when a failure has been recorded, or
   PANCAKE_ERR_WOULD_BLOCK when none has. The flat per-feed return code names
   the failure family; this names the member. */
int32_t pancake_host_session_last_abort(PancakeHostSession *session, PancakeLastAbort *out);
/* Read the PARTNER'S retained op:abort: the abort kind's wire name (a
   process-static view, e.g. "ProtocolError") into
   *out_kind_name/*out_kind_name_len, and up to cap bytes of its bounded
   diagnostic into out_msg, with the retained length in *out_len. Returns
   PANCAKE_ERR_WOULD_BLOCK when no partner abort has arrived. Any out-pointer
   may be NULL to skip that piece. */
int32_t pancake_host_session_partner_abort(PancakeHostSession *session, const uint8_t **out_kind_name, size_t *out_kind_name_len, uint8_t *out_msg, size_t cap, size_t *out_len);
/* Copy the calling thread's last pancake_host_* error into out_buf, the host
   sibling of pancake_last_error, reading this archive's own per-thread slot.
   Copies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or cap
   0 queries the length. Returns the full message length, or 0 when none is set. */
size_t pancake_host_last_error(uint8_t *out_buf, size_t cap);
/* Clear the calling thread's pancake_host_* last-error slot. */
void pancake_host_clear_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* PANCAKE_DRIVER_H */
