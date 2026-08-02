/* Generated from src/c_abi/host/mod.zig by tools/gen/header/host.zig.
   Do not edit by hand: run `zig build gen-header-host`.
   Function signatures are reflected from the Zig source, so this header
   cannot drift from the implementation.

   The byte-fed host tier's public C ABI: a separate archive
   (libpancake_host) from libpancake_ocapn (ADR-0059, ADR-0072). It is a
   companion, not a superset: it exports only the pancake_host_* family and
   shares the value vocabulary (PancakeFrame, PancakeManagedFrame,
   PancakeContext, PancakeArgument, PancakeReference, PancakeLastAbort) and
   the return codes by layout with pancake_ocapn.h (included below), so a
   consumer links BOTH archives and includes BOTH headers. The family has
   its own last-error slot, read through pancake_host_last_error rather
   than pancake_ocapn's pancake_last_error. */
#ifndef PANCAKE_HOST_H
#define PANCAKE_HOST_H

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
   examples/c/host_embedder_pump.c is a complete embedder built from exactly
   these calls, and the host section of docs/consuming-from-c.md is the
   guided route; read one before wiring the action queue below.

   A vow is this tier's name for the eventual result of a send: the same
   thing pancake_ocapn.h calls a promise and the CapTP wire calls an answer.
   A session_send / session_fetch returns a vow; you pipeline more sends
   against it (vow_send / vow_get / …) before it settles, and its outcome
   arrives later as a SETTLE or FAIL action naming that vow's ticket.

   THE ONE LOOP RULE. After any top-level pancake_host_* call returns OK,
   drain pancake_host_next_action until PANCAKE_ERR_WOULD_BLOCK, honoring each
   action: DIAL — borrow the pending view with
   pancake_host_pending_dial(ticket), open your own session from its
   transport/designator (pancake_host_session_open_dialed_locator), drive
   its session open, then report pancake_host_dialed (or
   pancake_host_dial_failed); FLUSH — drain
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
   vow_send/vow_index/vow_untag/vow_get, the turn verbs (with the callback's own turn),
   ref_release, session_set_exporter_location, session_is_open, the error
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
   borrowed for the call; each PancakeReference leaf is nevertheless
   one application retain and must eventually be returned with
   pancake_host_ref_release. Copying its { id } bytes does not create
   another retain. The vat copies *out_reply's payload the
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
/* PancakeHostAction.kind: dial the exporter named by ticket (borrow the pending view with pancake_host_pending_dial), then report pancake_host_dialed / pancake_host_dial_failed. */
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
/* Discovery-posture dial retry interval in milliseconds (ADR-0082). Keep lockstep with driver.discovery_retry_ms. */
#define PANCAKE_DISCOVERY_DIAL_RETRY_MS 3000
/* Discovery-posture dial attempt budget (ADR-0082). Keep lockstep with driver.discovery_max_attempts. */
#define PANCAKE_DISCOVERY_DIAL_MAX_ATTEMPTS 24
/* PancakePartnerIdentity.provenance: the transport layer proved the partner's durable key (iroh's QUIC handshake, or WebRTC's DTLS binding under capability-authorized signaling). */
#define PANCAKE_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT 0
/* PancakePartnerIdentity.provenance: the hello carried a session-key-attestation signed by the durable key its designator names, and it verified (keyed-tcp, keyed-relay). Static authorization, not proof the signer is live on this connection. */
#define PANCAKE_DURABLE_PROVENANCE_DURABLE_KEY_ATTESTATION 1
/* PancakePartnerIdentity.provenance: no durable identity was proved. An address transport designates a socket address rather than a key, and a partner that advertised an address on a key transport claimed no durable identity to authenticate. */
#define PANCAKE_DURABLE_PROVENANCE_UNAUTHENTICATED 2

/* One embedder effect popped from pancake_host_next_action. kind selects the
   live fields: DIAL carries only ticket (borrow the pending view with
   pancake_host_pending_dial). FLUSH and CLOSE carry session;
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
    /* FLUSH/CLOSE: the session to drain or condemn; NULL otherwise. */
    PancakeHostSession *session;
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

/* Create a byte-fed host bound to the caller-drawn Ed25519 identity seed (the
   host never draws entropy), allocating through the library allocator.

   seed_len is 32 or 64. The first 32 bytes are the durable identity and must
   stay stable across restarts, because a keyed locator's designator derives
   from them. The optional next 32 are the session-key root, and they must be
   FRESH PER PROCESS: they are what makes each CapTP session sign with its own
   key, so an old handoff certificate cannot resolve against a session opened
   after a restart. Passing only 32 leaves every session signing with the
   durable key, which is the weaker posture.

   frame_cap sizes every session's maximum admissible frame; a
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
int32_t pancake_host_release(PancakeHost *host);
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
/* Selective session-limit knobs (ADR-0082): override max_frame_bytes and/or
   queue_cap on a host before minting sessions. Pass 0 for a field to leave it
   unchanged. Already-open peers keep the limits they were minted with. */
int32_t pancake_host_set_session_limits(PancakeHost *host, size_t max_frame_bytes, size_t queue_cap);
/* Mint the dialing half from an already-parsed locator (transport +
   designator). A DIAL action carries only ticket — borrow the pending view with
   pancake_host_pending_dial and pass its transport/designator here. The keyed
   op:start-session is signed under the host identity and encoded before this
   returns, so drain take_outbound (a FLUSH action is queued) and drive the
   handshake byte-fed. Host-wide aliases remain lazily discoverable through the
   new session. A URI-holding caller parses first (pancake_uri_parse_peer) and
   passes the pieces — there is no parallel URI-string mint entry. The dialed
   hello does not consume a direct-addresses hint. *out_session is host-owned;
   release with pancake_host_session_release. */
int32_t pancake_host_session_open_dialed_locator(PancakeHost *host, const uint8_t *transport, size_t transport_len, const uint8_t *designator, size_t designator_len, PancakeHostSession **out_session);
/* Mint the accepting half of a connection your own listener produced: the keyed
   op:start-session signs the listener's own transport/designator — the key
   designator for keyed-tcp, the address designator for tcp — and the locator a
   give made on this host names as the exporter location. On keyed-tcp,
   direct_addresses_hint is the bound host:port riding the signed locator
   (borrowed; NULL/0 = none, refused for keyed-tcp because TCP has no discovery);
   an address-designator transport ignores it. Host-wide aliases remain lazily
   discoverable, with the same flush and release contract as
   pancake_host_session_open_dialed_locator. */
int32_t pancake_host_session_open_accepted(PancakeHost *host, const uint8_t *transport, size_t transport_len, const uint8_t *designator, size_t designator_len, const uint8_t *direct_addresses_hint, size_t direct_addresses_hint_len, PancakeHostSession **out_session);

/* PancakeDialPlan.shape: open a TCP socket to host:port (tcp, keyed-tcp). */
#define PANCAKE_DIAL_SHAPE_HOST_PORT 0
/* PancakeDialPlan.shape: peer-id open (node-id designator + addresses + reach; today from the iroh locator scheme). */
#define PANCAKE_DIAL_SHAPE_PEER_ID 1
/* PancakeDialPlan.shape: signaling-mediated open (webrtc); no dialable address, the channel comes up through offer/answer/ICE (ADR-0089 phase 4). */
#define PANCAKE_DIAL_SHAPE_SIGNALING 2
/* PancakeDialPlan.shape: rendezvous-bridged open (keyed-relay); no dialable address, the dialer opens the relay rendezvous leg its host is configured for (ADR-0088). */
#define PANCAKE_DIAL_SHAPE_RENDEZVOUS 3
/* PancakeDialPlan.reach_kind (peer-id shape): the relay-less direct posture. */
#define PANCAKE_DIAL_REACH_DIRECT 0
/* PancakeDialPlan.reach_kind (peer-id shape): the node's own configured redeem posture. */
#define PANCAKE_DIAL_REACH_CONFIGURED 1
/* PancakeDialPlan.reach_kind (peer-id shape): the caller posture carried in reach_value. */
#define PANCAKE_DIAL_REACH_EXPLICIT 2
/* pancake_host_plan_dial posture_policy: a redeem (a DIAL action) — direct when a hint is present, else the node's configured posture. */
#define PANCAKE_DIAL_POSTURE_REDEEM 0
/* pancake_host_plan_dial posture_policy: a connect carrying a posture in posture_value. */
#define PANCAKE_DIAL_POSTURE_EXPLICIT 1
/* pancake_host_plan_dial posture_policy: a connect that named no posture; a peer-id dial refuses PANCAKE_ERR_INVALID_ARGUMENT. */
#define PANCAKE_DIAL_POSTURE_EXPLICIT_NONE 2

/* A resolved dial from pancake_host_plan_dial: what byte channel to open and
   how. shape (PANCAKE_DIAL_SHAPE_*) selects the live fields — HOST_PORT fills
   host/host_len/port, PEER_ID fills addresses/addresses_len and the reachability.
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
    /* PEER_ID: the direct-addresses to dial (borrows the hint verbatim). */
    const uint8_t *addresses;
    size_t addresses_len;
    /* PEER_ID: a PANCAKE_DIAL_REACH_* value. */
    uint32_t reach_kind;
    /* PEER_ID: the caller posture when reach_kind is PANCAKE_DIAL_REACH_EXPLICIT. */
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

/* Borrowed in-flight pending dial for one ticket (parsed dial parts).
   Host-owned views valid until pancake_host_dialed / pancake_host_dial_failed
   consumes the row (or host teardown). Empty hint means the give carried none
   (hint is NULL, hint_len is 0). Dial authority is transport/designator/hint —
   no verbatim URI field. */
typedef struct PancakePendingDial {
    /* Parsed transport (always non-empty on a live ticket). */
    const uint8_t *transport;
    size_t transport_len;
    /* Parsed designator (always non-empty on a live ticket). */
    const uint8_t *designator;
    size_t designator_len;
    /* Direct-addresses hint, or NULL when the give carried none. */
    const uint8_t *hint;
    size_t hint_len;
} PancakePendingDial;

/* Borrow the in-flight pending dial for ticket into *out
   (transport/designator/hint). Staged once when the give was accepted —
   no re-parse. A live ticket always has non-empty transport/designator
   (unparseable gives never become pending rows); an empty hint means the give
   carried none (hint is NULL). Unknown ticket returns
   PANCAKE_ERR_INVALID_ARGUMENT. Host-owned views valid until pancake_host_dialed
   / pancake_host_dial_failed (or host teardown). */
int32_t pancake_host_pending_dial(PancakeHost *host, uint64_t ticket, PancakePendingDial *out);
/* Write the live session homing remote reference into *out_session, or NULL for
   a local, stale, foreign-Host, or closed-session capability. Bindings compare
   this result with the sending session after a call: the same session is an
   ordinary reply, while another session is the exporter reached through handoff.
   The answer comes from the reference's own Host row, with no dial-completion
   capture window. The returned handle is Host-owned and lives with that session;
   do not release it here. */
int32_t pancake_host_reference_exporter(PancakeHost *host, const PancakeReference *reference, PancakeHostSession **out_session);
/* Resolve a dial without opening a socket: the transport dispatch, designator
   validation, host:port resolution, and peer-id reachability decision every binding
   used to re-express, done once here. transport/designator are the locator's
   pieces (from pancake_host_pending_dial or pancake_uri_parse_peer);
   direct_addresses_hint is the locator's direct-addresses hint (NULL/0 = none);
   posture_policy is a PANCAKE_DIAL_POSTURE_* choosing the peer-id reachability rule,
   with posture_value the caller's posture under PANCAKE_DIAL_POSTURE_EXPLICIT.
   On PANCAKE_OK *out_plan is filled with views borrowing the caller's buffers; a
   bad locator returns PANCAKE_ERR_INVALID_ARGUMENT (pancake_host_last_error
   carries which). Open the channel the plan names, then feed it to
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
int32_t pancake_host_session_release(PancakeHostSession *session);
/* Nonzero once the keyed handshake has completed and the session is open. */
int32_t pancake_host_session_is_open(PancakeHostSession *session);
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
   call). The library owns framing and the tail: the session's codec delimits
   each complete frame at the front of bytes — both codecs, both frame shapes
   — and dispatches it exactly as pancake_host_session_feed, while a partial
   frame straddling two reads stays buffered in the session, so on success
   every byte was consumed and you just read and feed. Dispatch also pauses at
   the frame that completes the keyed handshake: frames coalesced behind the
   hello wait in the session's tail while you act on the fresh session
   (publish, fetch), and your next call — an empty chunk (len 0, bytes may be
   NULL) works — feeds them. A frame exceeding the session's frame cap is
   refused PANCAKE_ERR_FRAME_TOO_LARGE; any other failure classifies as
   pancake_host_session_feed's do. After any failure the session is closing:
   drain take_outbound (a typed op:abort is queued for the partner) and
   release the session. */
int32_t pancake_host_session_feed_bytes(PancakeHostSession *session, const uint8_t *bytes, size_t len);
/* Drain one encoded outbound frame as an *owned* managed frame you write to
   your transport and free through pancake_managed_frame_release. Returns
   PANCAKE_OK with *out_frame set, or PANCAKE_ERR_WOULD_BLOCK (with *out_frame
   untouched) when the queue is empty. Refused inside a callback. */
int32_t pancake_host_session_take_outbound(PancakeHostSession *session, PancakeManagedFrame *out_frame);
/* Pop the next embedder action into *out_action, or return
   PANCAKE_ERR_WOULD_BLOCK when none is pending. A DIAL carries only ticket
   (borrow the pending view with pancake_host_pending_dial). A SETTLE's value
   and a FAIL's message are host-owned until the NEXT pancake_host_next_action
   call, which frees them. Deferred work may return PANCAKE_ERR_INTERNAL under
   allocator pressure before an action is popped; no action or authority is lost,
   and the embedder retries this same drain call when pressure subsides. See the
   one loop rule in the header preamble. Refused inside a callback. */
int32_t pancake_host_next_action(PancakeHost *host, PancakeHostAction *out_action);
/* Opt-in convenience drain over pancake_host_next_action (ADR-0072 fifth
   amendment). Still pops through the pull-queue internally; does not replace
   it. hooks may be NULL (every action is discarded). *out_acted is 1 when any
   arm reported progress (optional, may be NULL). See PancakeHostPumpHooks. */
int32_t pancake_host_pump_drain(PancakeHost *host, const PancakeHostPumpHooks *hooks, uint32_t *out_acted);
/* Report a DIAL action's success: session is an open_dialed_locator against the
   pending dial for ticket (pancake_host_pending_dial), driven to an
   open session. The host withdraws every give waiting on the ticket; the
   withdraws, their settles, and their flushes pump inside this call. A stale
   ticket is a no-op success. */
int32_t pancake_host_dialed(PancakeHost *host, uint64_t ticket, PancakeHostSession *session);
/* Report a DIAL action's failure: every redeem waiting on the ticket breaks
   with reason, its FAIL completion queued inside this call. A stale ticket is a
   no-op success. */
int32_t pancake_host_dial_failed(PancakeHost *host, uint64_t ticket, const uint8_t *reason, size_t reason_len);
/* Answer a NEED_GIFT_ID action with 32 caller-drawn random bytes: the host
   originates the claimed handoff and this call flushes its legs, exporter
   first. A stale ticket is a no-op success. */
int32_t pancake_host_provide_gift_id(PancakeHost *host, uint64_t ticket, const uint8_t *gift_id, size_t gift_id_len);
/* Publish a hosted object a partner on this session can fetch by name (a
   swiss-number). The Host Vat owns the object; this session selects its first
   Port projection. Releasing that session does not run free. On success, free,
   if non-NULL, runs exactly once at Host teardown; a failed construction runs it
   after this call takes ownership. *out_ref receives the opaque Host-scoped
   capability. Refused inside a callback (ctx stays yours on a null-pointer or
   reentry refusal). */
int32_t pancake_host_session_publish(PancakeHostSession *session, const uint8_t *name, size_t name_len, PancakeHostBehavior behavior, void *ctx, PancakeHostCtxFree free, PancakeReference *out_ref);
/* Spawn a hosted object in the Host Vat and create its first projection on this
   session, without a fetchable name. It becomes reachable once a reply or
   argument carries the opaque Host-scoped capability written to *out_ref. Same
   free contract as pancake_host_session_publish. */
int32_t pancake_host_session_spawn(PancakeHostSession *session, PancakeHostBehavior behavior, void *ctx, PancakeHostCtxFree free, PancakeReference *out_ref);
/* Publish one hosted object in the Vat owned by this Host and bind name as its
   host-wide alias. Fetch lazily projects the actor onto the requesting Port; a
   deposited gift retains the exact actor and never consults the alias at
   withdrawal. The giftable row owns ctx: free, if non-NULL, runs exactly once, at
   pancake_host_release on success or before this returns on any non-OK outcome
   (the null-pointer and reentry refusals touch nothing and leave ctx yours).
   All-or-nothing over this call's own work: registration failure discards the
   fresh actor and frees ctx, so a retry starts with no partial alias or projection. */
int32_t pancake_host_publish(PancakeHost *host, const uint8_t *name, size_t name_len, PancakeHostBehavior behavior, void *ctx, PancakeHostCtxFree free);
/* Remove the host-wide alias name. Discovery-only, alias-only: a later fetch of
   the name misses on every session, while capabilities already issued, live Port
   projections, and deposited gifts keep naming the exact actor, which stays in
   the Host's Vat until pancake_host_release. An absent alias returns
   PANCAKE_ERR_NOT_FOUND, so a typo is loud instead of an idempotent no-op. A name
   in the reserved durable namespace is refused INVALID_ARGUMENT: minted durable
   publications leave through pancake_host_remove_durable. */
int32_t pancake_host_unpublish(PancakeHost *host, const uint8_t *name, size_t name_len);
/* Publish one hosted object under a freshly minted durable swiss name: a
   reserved-prefix namespace mutable aliases structurally cannot enter,
   unpredictable, never reassigned, and removable only through
   pancake_host_remove_durable. entropy supplies exactly 16 caller-drawn random
   bytes (the embedder owns the entropy boundary, as for gift ids). The minted
   swiss is written into out_swiss (swiss_cap of at least 50 bytes, or
   BUFFER_TOO_SMALL and nothing published) and the written length is returned.
   ctx/free follow pancake_host_publish's ownership exactly. Durability across
   process restart requires durable registry storage, which does not exist yet:
   a restart makes the old sturdyref miss, fail-closed. */
int32_t pancake_host_publish_durable(PancakeHost *host, const uint8_t *entropy, size_t entropy_len, PancakeHostBehavior behavior, void *ctx, PancakeHostCtxFree free, uint8_t *out_swiss, size_t swiss_cap);
/* Remove a minted durable publication: the old sturdyref misses from now on,
   while capabilities already issued and deposited gifts keep the exact actor. A
   swiss outside the durable namespace returns INVALID_ARGUMENT (mutable aliases
   leave through pancake_host_unpublish); an unknown durable name returns
   PANCAKE_ERR_NOT_FOUND. */
int32_t pancake_host_remove_durable(PancakeHost *host, const uint8_t *swiss, size_t swiss_len);
/* Fetch the partner capability published as name, minting a host vow whose id
   lands in *out_vow; the outcome arrives as that vow's SETTLE or FAIL action.
   A fulfilled far capability settles ALREADY enrolled under a node-unique
   token — recorded before the completion is queued, so a reply that
   immediately re-gifts it routes to the right exporter. Refused inside a
   callback. */
int32_t pancake_host_session_fetch(PancakeHostSession *session, const uint8_t *name, size_t name_len, uint64_t *out_vow);
/* Enliven the complete sturdyref URI (ADR-0098), minting a host vow whose id
   lands in *out_vow; the live reference arrives as that vow's SETTLE action.
   The URI's transport and designator must match the selected session before
   the swiss namespace is consulted or wire traffic is emitted. A dedup-cache
   hit settles before this returns; a fresh enliven rides bootstrap-fetch.
   Refused inside a callback. */
int32_t pancake_host_session_enliven(PancakeHostSession *session, const uint8_t *sturdyref_uri, size_t sturdyref_uri_len, uint64_t *out_vow);
/* Select-or-dial enliven of a complete sturdyref URI (ADR-0098): enliven it
   over a live session this host already dialed to that peer, or stage a dial
   and finish when you report it. The host vow id lands in *out_vow and its
   outcome arrives as that vow's SETTLE or FAIL action either way. A staged
   dial surfaces as an ordinary PANCAKE_HOST_ACTION_DIAL — borrow it with
   pancake_host_pending_dial and answer it with pancake_host_dialed /
   pancake_host_dial_failed exactly as a handoff redeem's — so a parked vow's
   id has no session and no row until it settles. Refused inside a callback. */
int32_t pancake_host_enliven(PancakeHost *host, const uint8_t *sturdyref_uri, size_t sturdyref_uri_len, uint64_t *out_vow);
/* Listen on a promise capability this session holds (CapTP op:listen), minting
   a host vow whose id lands in *out_vow; the promise's resolution arrives as
   that vow's SETTLE or FAIL action. The target must be a far promise; a
   non-promise far is refused. A re-gifted promise routes to its exporter
   session transparently, and a give in the settlement auto-redeems exactly as
   a fetch's would. The vow is plain: a listen makes no claim the result is a
   capability. Legal inside a callback. */
int32_t pancake_host_session_listen(PancakeHostSession *session, const PancakeReference *target, uint64_t *out_vow);
/* Eventual-send to an opaque Host-scoped target and mint a host vow for the
   answer; the outcome arrives as that vow's SETTLE or FAIL action. The Host
   chooses local delivery or the owning exporter session. A target or nested
   argument from another Host, or a retired identity, is refused rather than
   being interpreted as a wire position. verb/args are borrowed; the host copies
   what it queues. An empty verb — including (NULL, 0), which the family's ptr+len
   contract admits — is a real message, not an error: it delivers positionally,
   the way Goblins invokes a capability. Legal inside a callback (the send
   encodes when the enclosing call unwinds). */
int32_t pancake_host_session_send(PancakeHostSession *session, const PancakeReference *target, const uint8_t *verb, size_t verb_len, const PancakeArgument *args, size_t args_len, uint64_t *out_vow);
/* Fire-and-forget eventual-send: pancake_host_session_send with no answer and no
   vow. Same routing, refusals, and empty-verb contract. */
int32_t pancake_host_session_tell(PancakeHostSession *session, const PancakeReference *target, const uint8_t *verb, size_t verb_len, const PancakeArgument *args, size_t args_len);
/* Promise pipelining: eventual-send to a host vow before it resolves, minting a
   new vow for this call's own answer. A local vow (a NEAR send's answer) has no
   wire answer to pipeline against and is refused PANCAKE_ERR_INVALID_ARGUMENT
   (NotPipelineable); an unknown vow reports PANCAKE_ERR_NOT_FOUND. The
   empty-verb contract is pancake_host_session_send's. */
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
/* Pipeline an op:get projection against a far host vow, minting a new vow for
   the named Struct field. Same local-vow and unknown-vow refusals as
   pancake_host_vow_send; field is borrowed. */
int32_t pancake_host_vow_get(PancakeHost *host, uint64_t vow, const uint8_t *field, size_t field_len, uint64_t *out_vow);
/* Mint a resolver pair (ADR-0102): *out_vow_id is the read side, whose whole
   surface is pancake_host_turn_forward_vow; *out_resolver_id is the settle
   authority for pancake_host_resolver_fulfill / _break. Legal inside a
   behavior callback — a behavior mints, defers its answer onto the vow, hands
   the resolver id to whatever completes the work, and returns. */
int32_t pancake_host_spawn_resolver(PancakeHost *host, uint64_t *out_vow_id, uint64_t *out_resolver_id);
/* Settle a resolver vow fulfilled with one capability-free value (a value
   naming a capability refuses whole; an answer that carries authority uses
   the turn's forward instead). Top-level: refused inside a callback; the
   settle runs the deferred answers and pumps the sessions they dirtied. One
   attempt per resolver; a second settle or an unknown id refuses. */
int32_t pancake_host_resolver_fulfill(PancakeHost *host, uint64_t resolver_id, const PancakeArgument *value);
/* Settle a resolver vow broken with a diagnostic borrowed for the call. The
   same top-level, one-attempt contract as pancake_host_resolver_fulfill. */
int32_t pancake_host_resolver_break(PancakeHost *host, uint64_t resolver_id, const uint8_t *message, size_t message_len);
/* From inside a behavior callback, forward this turn's call to an opaque
   Host-scoped target and let this object's own answer settle on the forwarded
   result — the caretaker/attenuator primitive. The Host resolves the target and
   every nested capability; a stale or foreign-Host identity is refused. In a
   wire-served turn the real answer rides the forwarded vow and *out_reply gets a
   void placeholder; pass your behavior's own out_reply and return PANCAKE_OK.
   The written reply is BORROWED — valid until the next turn verb or drive on
   this host. The empty-verb contract is pancake_host_session_send's. */
int32_t pancake_host_turn_forward(PancakeHostTurn *turn, const PancakeReference *target, const uint8_t *verb, size_t verb_len, const PancakeArgument *args, size_t args_len, PancakeArgument *out_reply);
/* From inside a behavior callback, defer this turn's answer onto a resolver
   vow (ADR-0102): the answer settles when pancake_host_resolver_fulfill /
   _break fires later, as its own top-level event. vow_id must be the read side
   of pancake_host_spawn_resolver's pair — a wire vow's answer belongs to its
   session and refuses here. The behavior still returns normally; its return
   value resolves nothing once the turn is forwarded. */
int32_t pancake_host_turn_forward_vow(PancakeHostTurn *turn, uint64_t vow_id);
/* From inside a behavior callback, eventual-send to target and mint a host vow
   for the answer — the same routing, refusals, and empty-verb contract as
   pancake_host_session_send, on the turn's own session. The send encodes when the
   enclosing top-level call unwinds. */
int32_t pancake_host_turn_send(PancakeHostTurn *turn, const PancakeReference *target, const uint8_t *verb, size_t verb_len, const PancakeArgument *args, size_t args_len, uint64_t *out_vow);
/* From inside a behavior callback, fire-and-forget eventual-send —
   pancake_host_turn_send with no answer and no vow. Same empty-verb contract. */
int32_t pancake_host_turn_tell(PancakeHostTurn *turn, const PancakeReference *target, const uint8_t *verb, size_t verb_len, const PancakeArgument *args, size_t args_len);
/* From inside a behavior callback, spawn a hosted object in the Host Vat and
   create its first projection on the Port that delivered this turn. This is how a
   served factory mints a capability it replies with (a task board's create, a
   caretaker wrapping a target), the turn-time form of
   pancake_host_session_spawn. Same free contract; *out_ref receives the opaque
   Host-scoped capability, ready to ride this turn's own reply. */
int32_t pancake_host_turn_spawn(PancakeHostTurn *turn, PancakeHostBehavior behavior, void *ctx, PancakeHostCtxFree free, PancakeReference *out_ref);
/* From inside a behavior callback, break this turn's own answer with message —
   how a behavior refuses with a diagnostic, since a non-OK return settles the
   answer broken with only a generic reason. The answer resolves broken inside
   this call (a no-answer tell breaks nothing); leave out_reply untouched and
   return PANCAKE_OK from the behavior, whose return value then resolves
   nothing. message is borrowed and copied. */
int32_t pancake_host_turn_break(PancakeHostTurn *turn, const uint8_t *message, size_t message_len);
/* Release delta application retains on one opaque Host capability. The Host
   resolves the owning session and emits any required op:gc-exports itself; the
   caller never pairs a capability with a session-local wire position. A stale or
   foreign-Host identity is refused. Single-thread affinity applies: never call
   this from a finalizer thread. */
int32_t pancake_host_ref_release(PancakeHost *host, const PancakeReference *ref, uint64_t delta);
/* Write to *out_ref the opaque Host-scoped capability currently published under
   name, or return PANCAKE_ERR_NOT_FOUND when the Host has no such alias. The actor
   in the Host-owned Vat is lazily projected onto session when needed; the
   returned identity itself carries no export position and retains no name. */
int32_t pancake_host_session_published_ref(PancakeHostSession *session, const uint8_t *name, size_t name_len, PancakeReference *out_ref);
/* Break every far vow still parked on session, queueing each vow's FAIL
   completion inside this call — with the partner's retained abort diagnostic
   when one arrived, else message. Call it when your transport reports the
   connection gone. */
int32_t pancake_host_session_break_far_vows(PancakeHostSession *session, const uint8_t *message, size_t message_len);
/* Record the exporter locator to embed in gives whose exporter is
   session, overriding the session record; empty clears the override. locator is
   a borrowed Syrup <ocapn-peer> record (the bytes
   pancake_locator_record_encode returns); a URI or other non-record spelling
   fails with PANCAKE_ERR_INVALID_ARGUMENT. */
int32_t pancake_host_session_set_exporter_location(PancakeHostSession *session, const uint8_t *locator, size_t locator_len);
/* Read the typed cause of this session's most recent LOCAL dispatch failure
   into *out (the shared PancakeLastAbort layout; byte views process-static,
   never freed). Returns PANCAKE_OK when a failure has been recorded, or
   PANCAKE_ERR_WOULD_BLOCK when none has. The flat per-feed return code names
   the failure family; this names the member. */
int32_t pancake_host_session_last_abort(PancakeHostSession *session, PancakeLastAbort *out);
/* Read the PARTNER'S retained op:abort: the abort kind's wire name (a
   process-static view, e.g. "ProtocolError") into
   *out_kind_name / *out_kind_name_len, and up to cap bytes of its bounded
   diagnostic into out_msg, with the retained length in *out_len. Returns
   PANCAKE_ERR_WOULD_BLOCK when no partner abort has arrived. Any out-pointer
   may be NULL to skip that piece. */
int32_t pancake_host_session_partner_abort(PancakeHostSession *session, const uint8_t **out_kind_name, size_t *out_kind_name_len, uint8_t *out_msg, size_t cap, size_t *out_len);
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
   pancake_host_session_release, or until the host is torn down. */
typedef struct PancakePartnerIdentity {
    /* The partner's session public key. Always present on PANCAKE_OK. */
    const uint8_t *session_key;
    size_t session_key_len;
    /* The designator the partner signed, or NULL when its location carried none. */
    const uint8_t *designator;
    size_t designator_len;
    /* The verbatim location record, or NULL when the apply path captured none. */
    const uint8_t *locator_record;
    size_t locator_record_len;
    /* How the durable identity in designator was authenticated, one of the
PANCAKE_DURABLE_PROVENANCE_* values. Session identity, durable identity, and
this provenance are three separate facts: a caller that requires a proved
durable peer reads this, never a comparison of designator against
session_key, which is a coincidence of today's key reuse and stops holding
when each connection draws a fresh session key. */
    uint32_t provenance;
} PancakePartnerIdentity;

/* Borrow this session's verified partner identity into *out: the partner's
   session public key, the location designator it signed, and the verbatim
   location record those came from.

   A PANCAKE_OK return always means the signature was checked. Before the
   partner's op:start-session has arrived with a key this returns
   PANCAKE_ERR_WOULD_BLOCK, and a session opened without partner verification
   returns PANCAKE_ERR_SESSION rather than an identity nothing proved. That
   refusal is the contract: you cannot read an unverified identity through this
   entry point, so you never have to remember to ask whether the bytes were
   checked. */
int32_t pancake_host_session_partner_identity(PancakeHostSession *session, PancakePartnerIdentity *out);
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

#endif /* PANCAKE_HOST_H */
