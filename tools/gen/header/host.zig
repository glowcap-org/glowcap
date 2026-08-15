//! Generates `include/pancake_host.h` from the Zig `c_abi_host` source.
//!
//! The byte-fed host tier's public C ABI is a separate archive from
//! `libpancake_ocapn` (ADR-0059, ADR-0072), so it gets its own header. As with
//! `tools/gen/header/ocapn.zig`, the function signatures are *reflected* from the real
//! `src/c_abi/host/mod.zig` exports, so the header cannot disagree with the
//! implementation, and the prose lives here.
//! `zig build gen-header-host-check` is the staleness gate; `zig build
//! gen-header-host` is the fixer.
//!
//! The shared vocabulary (`PancakeFrame`, `PancakeManagedFrame`,
//! `PancakeContext`, `PancakeArgument`, `PancakeReference`, `PancakeLastAbort`)
//! and the return codes are declared in `pancake_ocapn.h`, which this header
//! includes; the host/session/turn handles, the two behavior callbacks, the
//! action vocabulary, and the `pancake_host_*` prototypes are new here.

const std = @import("std");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/pancake_host.h", .generate = generate },
};
pub const step_name = "gen-header-host";

// Every prototype the header emits, in order. The comptime guard below holds
// this table against the real `c_abi_host` declarations in both directions,
// so a new `pub export fn pancake_host_*` cannot silently miss the header while
// the gate stays green.
const emitted_fn_names = [_][]const u8{
    "pancake_host_new",
    "pancake_host_new_in",
    "pancake_host_diagnostic_id",
    "pancake_host_close",
    "pancake_host_close_progress",
    "pancake_host_close_wait_ms",
    "pancake_host_lifecycle_state",
    "pancake_host_release",
    "pancake_host_designator_from_seed",
    "pancake_host_set_advertised_locator",
    "pancake_host_ensure_advertised_locator",
    "pancake_host_remove_advertised_locator",
    "pancake_host_set_session_limits",
    "pancake_host_session_open_dialed_locator",
    "pancake_host_session_open_accepted",
    "pancake_host_plan_dial",
    "pancake_host_pending_dial",
    "pancake_host_reference_exporter",
    "pancake_host_session_close",
    "pancake_host_session_close_progress",
    "pancake_host_session_lifecycle_state",
    "pancake_host_session_release",
    "pancake_host_session_is_open",
    "pancake_host_session_trace_id",
    "pancake_host_session_feed",
    "pancake_host_session_feed_bytes",
    "pancake_host_session_take_outbound",
    "pancake_host_next_action",
    "pancake_host_pump_drain",
    "pancake_host_dialed",
    "pancake_host_dial_failed",
    "pancake_host_dial_cancelled",
    "pancake_host_provide_gift_id",
    "pancake_host_gift_id_failed",
    "pancake_host_session_publish",
    "pancake_host_session_spawn",
    "pancake_host_publish",
    "pancake_host_unpublish",
    "pancake_host_publish_durable",
    "pancake_host_remove_durable",
    "pancake_host_session_fetch",
    "pancake_host_session_enliven",
    "pancake_host_enliven",
    "pancake_host_set_trace",
    "pancake_host_set_trace_queue",
    "pancake_host_next_trace",
    "pancake_host_resolver_fulfill",
    "pancake_host_resolver_break",
    "pancake_host_session_listen",
    "pancake_host_session_send",
    "pancake_host_session_tell",
    "pancake_host_vow_send",
    "pancake_host_vow_index",
    "pancake_host_vow_untag",
    "pancake_host_vow_get",
    "pancake_host_turn_session",
    "pancake_host_turn_forward",
    "pancake_host_turn_defer",
    "pancake_host_turn_send",
    "pancake_host_turn_tell",
    "pancake_host_turn_spawn",
    "pancake_host_turn_break",
    "pancake_host_ref_release",
    "pancake_host_session_published_ref",
    "pancake_host_session_break_far_vows",
    "pancake_host_session_transport_closed",
    "pancake_host_session_set_exporter_location",
    "pancake_host_session_last_abort",
    "pancake_host_session_partner_abort",
    "pancake_host_session_partner_identity",
    "pancake_host_session_bind_verified_channel_key",
    "pancake_host_last_error",
    "pancake_host_clear_last_error",
};

// Binds the shared reflection machinery to `libpancake_host`. `special` names
// the two function-pointer typedefs the base type spelling has no case for.
const Spec = struct {
    pub const c = @import("c_abi_host");
    pub const emitted_fns: []const []const u8 = &emitted_fn_names;

    pub const const_docs = [_]struct { name: []const u8, doc: []const u8 }{
        .{ .name = "PANCAKE_HOST_ACTION_DIAL", .doc = "PancakeHostAction.kind: dial the exporter named by ticket (borrow the pending view with pancake_host_pending_dial), then report pancake_host_dialed / pancake_host_dial_failed." },
        .{ .name = "PANCAKE_HOST_ACTION_FLUSH", .doc = "PancakeHostAction.kind: drain pancake_host_session_take_outbound on session until WOULD_BLOCK and write the frames." },
        .{ .name = "PANCAKE_HOST_ACTION_NEED_GIFT_ID", .doc = "PancakeHostAction.kind: draw 32 random bytes and feed them to pancake_host_provide_gift_id with the ticket, or report failure through pancake_host_gift_id_failed." },
        .{ .name = "PANCAKE_HOST_ACTION_SETTLE", .doc = "PancakeHostAction.kind: the vow named by ticket settled fulfilled with value; route the outcome to whatever awaits it." },
        .{ .name = "PANCAKE_HOST_ACTION_FAIL", .doc = "PancakeHostAction.kind: the vow named by ticket failed with result and message; route the outcome to whatever awaits it." },
        .{ .name = "PANCAKE_HOST_ACTION_CLOSE", .doc = "PancakeHostAction.kind: the host retired this session; write any queued terminal frame, close its transport, and release the session." },
        .{ .name = "PANCAKE_HOST_ACTION_RESUME", .doc = "PancakeHostAction.kind: the finite host scheduler yielded with internal work remaining; continue draining actions, with no session or I/O payload." },
        .{ .name = "PANCAKE_HOST_ACTION_CANCEL_DIAL", .doc = "PancakeHostAction.kind: interrupt and join the external dial named by ticket, then report pancake_host_dial_cancelled." },
        .{ .name = "PANCAKE_PENDING_CANCEL", .doc = "pancake_host_close pending policy: seal admission, cancel admitted work, and begin terminal session shutdown." },
        .{ .name = "PANCAKE_PENDING_FINISH", .doc = "pancake_host_close pending policy: seal admission and keep driving admitted work before terminal session shutdown." },
        .{ .name = "PANCAKE_CLOSE_OPTIONS_ABI_VERSION", .doc = "PancakeCloseOptions.abi_version." },
        .{ .name = "PANCAKE_CLOSE_MAX_GRACE_MS", .doc = "Largest finite PancakeCloseOptions.grace_ms value." },
        .{ .name = "PANCAKE_CLOSE_GRACE_UNSPECIFIED", .doc = "PancakeCloseOptions.grace_mode: no grace argument was supplied." },
        .{ .name = "PANCAKE_CLOSE_GRACE_FINITE", .doc = "PancakeCloseOptions.grace_mode: grace_ms is a finite budget." },
        .{ .name = "PANCAKE_CLOSE_GRACE_UNBOUNDED", .doc = "PancakeCloseOptions.grace_mode: finish has no deadline." },
        .{ .name = "PANCAKE_LIFECYCLE_ACTIVE", .doc = "The owner still admits application work." },
        .{ .name = "PANCAKE_LIFECYCLE_FINISHING", .doc = "Admission is sealed while admitted work runs." },
        .{ .name = "PANCAKE_LIFECYCLE_TERMINATING", .doc = "Terminal resource shutdown is in progress." },
        .{ .name = "PANCAKE_LIFECYCLE_CLOSED", .doc = "The owner's execution state has reached its close barrier." },
        .{ .name = "PANCAKE_DEFAULT_FRAME_CAP", .doc = "Default maximum admissible frame for pancake_host_new / pancake_host_new_in (bytes): mirrors session.SessionLimits.max_frame_bytes (1 MiB)." },
        .{ .name = "PANCAKE_MAX_LOCAL_FORWARD_HOPS", .doc = "Bound on one turn's synchronous local Forward chase (caretaker over attenuator). Hop N+1 breaks the answer instead of spinning." },
        .{ .name = "PANCAKE_DISCOVERY_DIAL_RETRY_MS", .doc = "Discovery-posture dial retry interval in milliseconds (ADR-0082). Keep lockstep with driver.discovery_retry_ms." },
        .{ .name = "PANCAKE_DISCOVERY_DIAL_MAX_ATTEMPTS", .doc = "Discovery-posture dial attempt budget (ADR-0082). Keep lockstep with driver.discovery_max_attempts." },
        .{ .name = "PANCAKE_DIAL_SHAPE_HOST_PORT", .doc = "PancakeDialPlan.shape: open a TCP socket to host:port (tcp, keyed-tcp)." },
        .{ .name = "PANCAKE_DIAL_SHAPE_PEER_ID", .doc = "PancakeDialPlan.shape: peer-id open (node-id designator + addresses + reach; today from the iroh locator scheme)." },
        .{ .name = "PANCAKE_DIAL_SHAPE_SIGNALING", .doc = "PancakeDialPlan.shape: signaling-mediated open (webrtc); no dialable address, the channel comes up through offer/answer/ICE (ADR-0089 phase 4)." },
        .{ .name = "PANCAKE_DIAL_SHAPE_RENDEZVOUS", .doc = "PancakeDialPlan.shape: rendezvous-bridged open (keyed-relay); no dialable address, the dialer opens the relay rendezvous leg its host is configured for (ADR-0088)." },
        .{ .name = "PANCAKE_DIAL_REACH_DIRECT", .doc = "PancakeDialPlan.reach_kind (peer-id shape): the relay-less direct posture." },
        .{ .name = "PANCAKE_DIAL_REACH_CONFIGURED", .doc = "PancakeDialPlan.reach_kind (peer-id shape): the node's own configured redeem posture." },
        .{ .name = "PANCAKE_DIAL_REACH_EXPLICIT", .doc = "PancakeDialPlan.reach_kind (peer-id shape): the caller posture carried in reach_value." },
        .{ .name = "PANCAKE_DIAL_POSTURE_REDEEM", .doc = "pancake_host_plan_dial posture_policy: a redeem (a DIAL action) — direct when a hint is present, else the node's configured posture." },
        .{ .name = "PANCAKE_DIAL_POSTURE_EXPLICIT", .doc = "pancake_host_plan_dial posture_policy: a connect carrying a posture in posture_value." },
        .{ .name = "PANCAKE_DIAL_POSTURE_EXPLICIT_NONE", .doc = "pancake_host_plan_dial posture_policy: a connect that named no posture; a peer-id dial refuses PANCAKE_ERR_INVALID_ARGUMENT." },
        .{ .name = "PANCAKE_DESIGNATOR_SCHEME_ADDRESS", .doc = "pancake_host_session_open_accepted designator_scheme: the listener designator names a dialable address." },
        .{ .name = "PANCAKE_DESIGNATOR_SCHEME_KEY", .doc = "pancake_host_session_open_accepted designator_scheme: the listener designator names a peer key." },
        .{ .name = "PANCAKE_HOST_OUTBOUND_PREFIX_CAP", .doc = "Minimum out_prefix capacity for pancake_host_session_take_outbound." },
        .{ .name = "PANCAKE_HOST_DURABLE_ENTROPY_LEN", .doc = "Exact caller-supplied entropy length for pancake_host_publish_durable." },
        .{ .name = "PANCAKE_HOST_DURABLE_SWISS_LEN", .doc = "Required output capacity and written length for pancake_host_publish_durable." },
        .{ .name = "PANCAKE_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT", .doc = "PancakePartnerIdentity.provenance: a lower layer proved the partner holds the durable key it claims, and that key names the far end of the byte channel this session runs over, so the partner and the endpoint this session is encrypted to are one node." },
        .{ .name = "PANCAKE_DURABLE_PROVENANCE_UNAUTHENTICATED", .doc = "PancakePartnerIdentity.provenance: nothing proved the name. A partner that claimed no durable identity at all lands here too, having no identity to have authenticated." },
    };

    pub fn special(comptime T: type) ?[]const u8 {
        if (T == c.PancakeHostBehavior) return "PancakeHostBehavior";
        if (T == c.PancakeTraceCallback) return "PancakeTraceCallback";
        if (T == c.PancakeHostCtxFree) return "PancakeHostCtxFree";
        if (T == c.PancakeHostPumpArmFn) return "PancakeHostPumpArmFn";
        return null;
    }
};
const E = header_emit.Emit(Spec);
const Buf = header_emit.Buf;
const emitDoc = header_emit.emitDoc;
const emitFn = E.emitFn;
const emitConst = E.emitConst;

// Coverage guard, both directions: every `pub export fn pancake_host_*` in
// `c_abi_host` must be listed, and every listed name must be real.
comptime {
    E.guardFns("c_abi_host", "pancake_host_");
    // Hold the action-kind #defines emitted below against the Zig source.
    std.debug.assert(Spec.c.PANCAKE_HOST_ACTION_DIAL == 0);
    std.debug.assert(Spec.c.PANCAKE_HOST_ACTION_FLUSH == 1);
    std.debug.assert(Spec.c.PANCAKE_HOST_ACTION_NEED_GIFT_ID == 2);
    std.debug.assert(Spec.c.PANCAKE_HOST_ACTION_SETTLE == 3);
    std.debug.assert(Spec.c.PANCAKE_HOST_ACTION_FAIL == 4);
    std.debug.assert(Spec.c.PANCAKE_HOST_ACTION_CLOSE == 5);
    std.debug.assert(Spec.c.PANCAKE_HOST_ACTION_RESUME == 6);
    std.debug.assert(Spec.c.PANCAKE_HOST_ACTION_CANCEL_DIAL == 7);
    std.debug.assert(Spec.c.PANCAKE_PENDING_CANCEL == 0);
    std.debug.assert(Spec.c.PANCAKE_PENDING_FINISH == 1);
    std.debug.assert(Spec.c.PANCAKE_LIFECYCLE_ACTIVE == 0);
    std.debug.assert(Spec.c.PANCAKE_LIFECYCLE_FINISHING == 1);
    std.debug.assert(Spec.c.PANCAKE_LIFECYCLE_TERMINATING == 2);
    std.debug.assert(Spec.c.PANCAKE_LIFECYCLE_CLOSED == 3);
    std.debug.assert(Spec.c.PANCAKE_MAX_LOCAL_FORWARD_HOPS == 256);
    // Hold the dial/accept planning #defines emitted below against the source.
    std.debug.assert(Spec.c.PANCAKE_DIAL_SHAPE_HOST_PORT == 0);
    std.debug.assert(Spec.c.PANCAKE_DIAL_SHAPE_PEER_ID == 1);
    std.debug.assert(Spec.c.PANCAKE_DIAL_SHAPE_SIGNALING == 2);
    std.debug.assert(Spec.c.PANCAKE_DIAL_SHAPE_RENDEZVOUS == 3);
    std.debug.assert(Spec.c.PANCAKE_DIAL_REACH_DIRECT == 0);
    std.debug.assert(Spec.c.PANCAKE_DIAL_REACH_CONFIGURED == 1);
    std.debug.assert(Spec.c.PANCAKE_DIAL_REACH_EXPLICIT == 2);
    std.debug.assert(Spec.c.PANCAKE_DIAL_POSTURE_REDEEM == 0);
    std.debug.assert(Spec.c.PANCAKE_DIAL_POSTURE_EXPLICIT == 1);
    std.debug.assert(Spec.c.PANCAKE_DIAL_POSTURE_EXPLICIT_NONE == 2);
    std.debug.assert(Spec.c.PANCAKE_DESIGNATOR_SCHEME_ADDRESS == 0);
    std.debug.assert(Spec.c.PANCAKE_DESIGNATOR_SCHEME_KEY == 1);
    std.debug.assert(Spec.c.PANCAKE_HOST_OUTBOUND_PREFIX_CAP == 32);
    std.debug.assert(Spec.c.PANCAKE_HOST_DURABLE_ENTROPY_LEN == 16);
    std.debug.assert(Spec.c.PANCAKE_HOST_DURABLE_SWISS_LEN == 50);
}

/// Build the full header text. Caller owns the returned bytes.
fn generate(gpa: std.mem.Allocator) ![]u8 {
    var b: Buf = .empty;
    errdefer b.deinit(gpa);

    try b.appendSlice(gpa,
        \\/* Generated from src/c_abi/host/mod.zig by tools/gen/header/host.zig.
        \\   Do not edit by hand: run `zig build gen-header-host`.
        \\   Function signatures are reflected from the Zig source, so this header
        \\   cannot drift from the implementation.
        \\
        \\   The byte-fed host tier's public C ABI: a separate archive
        \\   (libpancake_host) from libpancake_ocapn (ADR-0059, ADR-0072). It is a
        \\   companion, not a superset: it exports only the pancake_host_* family and
        \\   shares the value vocabulary (PancakeFrame, PancakeManagedFrame,
        \\   PancakeContext, PancakeArgument, PancakeReference, PancakeLastAbort) and
        \\   the return codes by layout with pancake_ocapn.h (included below), so a
        \\   consumer links BOTH archives and includes BOTH headers. The family has
        \\   its own last-error slot, read through pancake_host_last_error rather
        \\   than pancake_ocapn's pancake_last_error. */
        \\#ifndef PANCAKE_HOST_H
        \\#define PANCAKE_HOST_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "pancake_ocapn.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    try emitDoc(&b, gpa,
        \\A PancakeHost is the multi-session CapTP host for an embedder that
        \\owns its own loop, sockets, and entropy (ADR-0072). The library owns every
        \\decision — routing, three-party redeem, gift origination — and the embedder
        \\moves bytes: feed inbound frames with pancake_host_session_feed, write what
        \\pancake_host_session_take_outbound drains, and honor the action queue.
        \\examples/c/host_embedder_pump.c is a complete embedder built from exactly
        \\these calls, and the host section of docs/consuming-from-c.md is the
        \\guided route; read one before wiring the action queue below.
        \\
        \\A vow is this tier's observation handle for the eventual result of a
        \\send. It is distinct from the passable OCapN promise reference and the
        \\CapTP answer position that names a session slot. A session_send /
        \\session_fetch returns a vow; you pipeline more sends against it
        \\(vow_send / vow_get / …) before it settles, and its outcome
        \\arrives later as a SETTLE or FAIL action naming that vow's ticket.
        \\
        \\THE ONE LOOP RULE. After any top-level pancake_host_* call returns OK,
        \\drain pancake_host_next_action until PANCAKE_ERR_WOULD_BLOCK, honoring each
        \\action: DIAL — borrow the pending view with
        \\pancake_host_pending_dial(ticket), open your own channel from it,
        \\mint the session from the same view
        \\(pancake_host_session_open_dialed_locator), drive
        \\its session open, then report pancake_host_dialed (or
        \\pancake_host_dial_failed); FLUSH — drain
        \\take_outbound on that session until WOULD_BLOCK and write the frames;
        \\NEED_GIFT_ID — draw 32 random bytes and call pancake_host_provide_gift_id,
        \\or call pancake_host_gift_id_failed when entropy cannot be provided;
        \\SETTLE / FAIL — route the outcome to whatever awaits the vow the action's
        \\ticket names. Nothing in the library enforces the drain — honoring it is
        \\the embedder's side of the contract, and an ignored action strands the
        \\dial, flush, handoff, or settlement it carries.
        \\
        \\THREADING AND REENTRANCY. One thread (or one green-thread scheduler)
        \\drives one host; nothing locks. The one callback — a behavior answering
        \\a deliver — fires on the thread executing the enclosing pancake_host_*
        \\call. Inside it the enqueueing verbs are legal — session_send/session_tell,
        \\vow_send/vow_index/vow_untag/vow_get, the turn verbs (with the callback's own turn),
        \\ref_release, session_set_exporter_location, session_is_open, the error
        \\readers — and their effects encode and pump when the enclosing call
        \\unwinds. The host-driving verbs (feed, feed_bytes, take_outbound,
        \\next_action, dialed/dial_failed/provide_gift_id, open_*, publish/spawn,
        \\fetch/enliven, break_far_vows, transport_closed, release) are refused there with
        \\PANCAKE_ERR_INVALID_ARGUMENT.
    );

    try b.appendSlice(gpa,
        \\
        \\/* A byte-fed multi-session CapTP host: one identity, one routing and
        \\   redeem authority, many sessions. Created by pancake_host_new /
        \\   pancake_host_new_in; released by pancake_host_release, always after its
        \\   sessions. */
        \\typedef struct PancakeHost PancakeHost;
        \\
        \\/* One byte-fed CapTP session a host minted. Released by
        \\   pancake_host_session_release, always before the host. */
        \\typedef struct PancakeHostSession PancakeHostSession;
        \\
        \\/* The current turn, passed to a behavior callback so it can forward and
        \\   eventual-send while handling a deliver (pancake_host_turn_*). Valid only
        \\   for the duration of that callback: stashing the pointer and using it
        \\   after the callback returns is undefined behavior. */
        \\typedef struct PancakeHostTurn PancakeHostTurn;
        \\
        \\/* A hosted object's behavior, invoked on each deliver. verb/args are
        \\   borrowed for the call; each PancakeReference leaf is nevertheless
        \\   one application retain and must eventually be returned with
        \\   pancake_host_ref_release. Copying its { id } bytes does not create
        \\   another retain. The vat copies *out_reply's payload the
        \\   instant you return, so its bytes must stay valid across the return
        \\   (point them at your ctx or a buffer you own, not a callback stack
        \\   local). Any non-OK return settles the answer broken
        \\   with a generic reason. */
        \\typedef int32_t (*PancakeHostBehavior)(void *ctx, PancakeHostTurn *turn,
        \\    const uint8_t *verb, size_t verb_len, const PancakeArgument *args,
        \\    size_t args_len, PancakeArgument *out_reply);
        \\
        \\/* Release a hosted object's ctx when the object is torn down. NULL to keep
        \\   ctx. Runs exactly once per registration that took ownership; must call
        \\   no pancake_host_* function. */
        \\typedef void (*PancakeHostCtxFree)(void *ctx);
        \\
    );

    try emitConst(&b, gpa, "PANCAKE_TRACE_SESSION_OPEN");
    try emitConst(&b, gpa, "PANCAKE_TRACE_MESSAGE");
    try emitConst(&b, gpa, "PANCAKE_TRACE_SESSION_CLOSE");
    try emitConst(&b, gpa, "PANCAKE_TRACE_DIGEST_BYTES");
    try b.appendSlice(gpa, "\n");
    try emitDoc(&b, gpa,
        \\One live-trace fact (pancake_host_set_trace). kind selects the live
        \\fields; string views are borrowed for the callback only. SESSION_OPEN
        \\carries session, partner, verified, and the negotiated PANCAKE_CODEC_*,
        \\using PANCAKE_CODEC_UNKNOWN only when this C ABI cannot name it;
        \\MESSAGE carries session, outbound, and the deliver's verb;
        \\SESSION_CLOSE carries session. Unused fields are zeroed.
    );
    try E.emitStruct(&b, gpa, Spec.c.PancakeTraceEvent, "PancakeTraceEvent", &.{
        "A PANCAKE_TRACE_* value.",
        "The session the fact is about, stable for the session's life.",
        "MESSAGE: nonzero when the message left this host.",
        "SESSION_OPEN: whether the realized channel proved the partner's durable name, as a PANCAKE_DURABLE_PROVENANCE_* value.",
        "SESSION_OPEN: the negotiated PANCAKE_CODEC_*, or PANCAKE_CODEC_UNKNOWN when this C ABI cannot name it.",
        "SESSION_OPEN: the negotiated PANCAKE_CAPTP_* profile.",
        "SESSION_OPEN: the partner's OCapN Designator (dialed, or claimed by its hello). Borrowed. Half a name on its own: OCapN requires a designator and a transport together to tell two locations apart.",
        "Length of designator.",
        "SESSION_OPEN: the locator's OCapN Transport, the netlayer symbol this session runs over (tcp, keyed-tcp, keyed-relay, iroh, webrtc, inproc). Borrowed.",
        "Length of transport.",
        "SESSION_OPEN: the OCapN Session ID, 64 lowercase hex digits, which BOTH peers of this session derive to the same value; empty when the partner sent no session key. Borrowed. Not session above, which is this host's own handle and means nothing to anyone else.",
        "Length of session_id.",
        "MESSAGE: the deliver's verb. Borrowed.",
        "Length of verb.",
        "MESSAGE: the message's wire frame, borrowed; both directions carry it (the fact sites sit at the wire boundary).",
        "Length of frame, as readable here.",
        "MESSAGE: how long the frame really was; equal to frame_len on the callback seam, larger when a queued record clipped it to its payload window.",
        "Records the host dropped between the previous record and this one; always zero on the callback seam.",
        "MESSAGE: a tag over the frame's bytes, naming this one message across the two peers that carried it, so a consumer merging two observers of one session folds their sightings into one. Zero on the other kinds.",
    });
    try b.appendSlice(gpa,
        \\/* The trace callback: called synchronously at the fact site, on the host's
        \\   one thread, with event and its views borrowed for the call. Must call no
        \\   host-driving verb; stamp, copy, and return. */
        \\typedef void (*PancakeTraceCallback)(void *ctx, const PancakeTraceEvent *event);
        \\
        \\
    );

    try emitConst(&b, gpa, "PANCAKE_HOST_ACTION_DIAL");
    try emitConst(&b, gpa, "PANCAKE_HOST_ACTION_FLUSH");
    try emitConst(&b, gpa, "PANCAKE_HOST_ACTION_NEED_GIFT_ID");
    try emitConst(&b, gpa, "PANCAKE_HOST_ACTION_SETTLE");
    try emitConst(&b, gpa, "PANCAKE_HOST_ACTION_FAIL");
    try emitConst(&b, gpa, "PANCAKE_HOST_ACTION_CLOSE");
    try emitConst(&b, gpa, "PANCAKE_HOST_ACTION_RESUME");
    try emitConst(&b, gpa, "PANCAKE_HOST_ACTION_CANCEL_DIAL");
    try emitConst(&b, gpa, "PANCAKE_PENDING_CANCEL");
    try emitConst(&b, gpa, "PANCAKE_PENDING_FINISH");
    try emitConst(&b, gpa, "PANCAKE_CLOSE_OPTIONS_ABI_VERSION");
    try emitConst(&b, gpa, "PANCAKE_CLOSE_MAX_GRACE_MS");
    try emitConst(&b, gpa, "PANCAKE_CLOSE_GRACE_UNSPECIFIED");
    try emitConst(&b, gpa, "PANCAKE_CLOSE_GRACE_FINITE");
    try emitConst(&b, gpa, "PANCAKE_CLOSE_GRACE_UNBOUNDED");
    try emitConst(&b, gpa, "PANCAKE_LIFECYCLE_ACTIVE");
    try emitConst(&b, gpa, "PANCAKE_LIFECYCLE_FINISHING");
    try emitConst(&b, gpa, "PANCAKE_LIFECYCLE_TERMINATING");
    try emitConst(&b, gpa, "PANCAKE_LIFECYCLE_CLOSED");
    try emitConst(&b, gpa, "PANCAKE_DEFAULT_FRAME_CAP");
    try emitConst(&b, gpa, "PANCAKE_MAX_LOCAL_FORWARD_HOPS");
    try emitConst(&b, gpa, "PANCAKE_DISCOVERY_DIAL_RETRY_MS");
    try emitConst(&b, gpa, "PANCAKE_DISCOVERY_DIAL_MAX_ATTEMPTS");
    try emitConst(&b, gpa, "PANCAKE_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT");
    try emitConst(&b, gpa, "PANCAKE_DURABLE_PROVENANCE_UNAUTHENTICATED");
    try b.appendSlice(gpa, "\n");
    try E.emitStruct(&b, gpa, Spec.c.PancakeCloseOptions, "PancakeCloseOptions", &.{
        "PANCAKE_CLOSE_OPTIONS_ABI_VERSION.",
        "sizeof(PancakeCloseOptions).",
        "PANCAKE_PENDING_CANCEL or PANCAKE_PENDING_FINISH.",
        "PANCAKE_CLOSE_GRACE_*; CANCEL requires UNSPECIFIED.",
        "Finite finish grace in milliseconds; CANCEL requires zero.",
    });
    try b.appendSlice(gpa, "\n");
    try emitDoc(&b, gpa,
        \\One embedder effect popped from pancake_host_next_action. kind selects the
        \\live fields: DIAL carries only ticket (borrow the pending view with
        \\pancake_host_pending_dial). FLUSH and CLOSE carry session;
        \\NEED_GIFT_ID carries ticket. SETTLE carries the settled vow id in ticket
        \\and the fulfilled value in value; FAIL carries the vow id in ticket and
        \\the typed failure code in result and the reason in message/message_len.
        \\RESUME carries no payload and
        \\means the finite host scheduler yielded with internal work remaining.
        \\Every popped byte view and
        \\value's sub-structure are host-owned and valid until the NEXT
        \\pancake_host_next_action call, which frees them. Unused fields are zeroed.
    );
    try E.emitStruct(&b, gpa, Spec.c.PancakeHostAction, "PancakeHostAction", &.{
        "A PANCAKE_HOST_ACTION_* value.",
        "DIAL: the report-back handle; SETTLE/FAIL: the vow that settled.",
        "FLUSH/CLOSE: the session to drain or condemn; NULL otherwise.",
        "SETTLE: the fulfilled value; zeroed otherwise.",
        "FAIL: the break reason; NULL otherwise.",
        "",
        "CLOSE: PANCAKE_OK or PANCAKE_ERR_TIMEOUT. FAIL: PANCAKE_ERR_BROKEN or PANCAKE_ERR_CLOSED; zero otherwise.",
    });
    try b.appendSlice(gpa, "\n");
    try emitDoc(&b, gpa,
        \\One shared arm callback for PancakeHostPumpHooks (flush, close,
        \\need_gift_id, complete for SETTLE/FAIL, dial). Return PANCAKE_OK or a
        \\real PANCAKE_ERR_*. When out_progressed is non-NULL, set it to 1 if the
        \\arm counts as quiescence progress; leave 0 for a handled notice a
        \\sibling shuttle already covers. action views are host-owned until the
        \\next pancake_host_next_action (pancake_host_pump_drain pops internally).
    );
    try b.appendSlice(gpa,
        \\typedef int32_t (*PancakeHostPumpArmFn)(void *ctx, PancakeHost *host,
        \\    const PancakeHostAction *action, uint32_t *out_progressed);
        \\
    );
    try emitDoc(&b, gpa,
        \\Opt-in embedder hooks for pancake_host_pump_drain (ADR-0072 fifth
        \\amendment). NULL arm pointers skip that kind (no error, no progress).
        \\The pull-queue remains normative — this is a convenience wrapper's
        \\callback surface, not a replacement for pancake_host_next_action.
    );
    try E.emitStruct(&b, gpa, Spec.c.PancakeHostPumpHooks, "PancakeHostPumpHooks", &.{
        "Caller context passed to every arm.",
        "FLUSH arm, or NULL to skip.",
        "CLOSE arm, or NULL to skip.",
        "NEED_GIFT_ID arm, or NULL to skip.",
        "SETTLE and FAIL arm, or NULL to skip.",
        "DIAL arm, or NULL to skip.",
    });
    try b.appendSlice(gpa, "\n");

    try emitFn(&b, gpa, "pancake_host_new", &.{ "seed", "seed_len", "frame_cap", "verify_partner", "codec", "captp_version", "features", "local_turn_budget", "out_host" }, "Create a byte-fed host bound to a caller-drawn 64-byte seed buffer (the host\nnever draws entropy), allocating through the library allocator.\n\nseed_len must be 64. The first 32 bytes are the durable identity and must\nstay stable across restarts, because a keyed locator's designator derives\nfrom them. The next 32 are the session-key root, and they must be FRESH PER\nPROCESS: they are what makes each CapTP session sign with its own key, so an\nold handoff certificate cannot resolve against a session opened after a\nrestart. A durable-only 32-byte seed is refused — CapTP session keys must not\nsilently reuse the identity seed (ADR-0097).\n\nframe_cap sizes every session's maximum admissible frame; a\nnonzero verify_partner keeps partner-signature verification on (the secure\ndefault); codec is PANCAKE_CODEC_SYRUP or PANCAKE_CODEC_CAPNP.\nPANCAKE_CODEC_UNKNOWN is an output sentinel and is refused here.\ncaptp_version is the PANCAKE_CAPTP_* profile this host prefers, and features is\nthe PANCAKE_FEATURE_* bitmask this host offers. The signed hello carries those\npreferences as locator hints; each session settles version and codec with its\npartner, falling back to v1.0/Syrup when needed, and runs only the intersection\nof the two offered feature sets. An absent feature hint means PANCAKE_FEATURE_FULL.\nPANCAKE_CAPTP_V1_0 with PANCAKE_CODEC_SYRUP and PANCAKE_FEATURE_FULL is the\ninterop floor a Goblins vat speaks; a pancake-to-pancake fleet normally names\nPANCAKE_CAPTP_NEXT with PANCAKE_CODEC_CAPNP and PANCAKE_FEATURE_FULL.\nlocal_turn_budget is 0 = unbounded (same default as Zig Host + Bridge);\nnonzero caps local-turn amplification per drive (ADR-0076).\n*out_host receives the handle; release with pancake_host_release.");
    try emitFn(&b, gpa, "pancake_host_new_in", &.{ "context", "seed", "seed_len", "frame_cap", "verify_partner", "codec", "captp_version", "features", "local_turn_budget", "out_host" }, "pancake_host_new allocating every byte the host owns through context's host\nallocator (pancake_context_new_with_allocator).");
    try emitFn(&b, gpa, "pancake_host_diagnostic_id", &.{ "host", "out_id" }, "Return the Host's stable identity in its owning Context's diagnostic namespace. The context-less compatibility constructor reports zero.");
    try emitFn(&b, gpa, "pancake_host_close", &.{ "host", "options", "now_ms" }, "Seal application admission and begin or escalate terminal Host close. now_ms is\na reading from the embedder's monotonic millisecond clock. FINISH keeps\nalready-admitted work running under its finite or explicitly unbounded grace.\nRepeated calls share the first deadline: CANCEL may escalate FINISH and FINISH\nnever weakens or restarts an existing barrier. This closes without releasing\nthe Host handle.");
    try emitFn(&b, gpa, "pancake_host_close_progress", &.{ "host", "now_ms", "out_state" }, "Apply the current monotonic clock reading to a started close and write its\nPANCAKE_LIFECYCLE_* state. Expired FINISH escalates through the shared CANCEL\npath. After teardown reaches CLOSED, a finite grace expiry returns\nPANCAKE_ERR_TIMEOUT together with CLOSED.");
    try emitFn(&b, gpa, "pancake_host_close_wait_ms", &.{ "host", "now_ms", "out_wait_ms" }, "The longest a close driver may wait for new input before calling\npancake_host_close_progress again: milliseconds until the nearest FINISH grace\ndeadline (the Host's own or any session's), clamped at zero. Writes -1 when no\nfinite deadline is pending; only feed, action-drain, settle, or escalation\nactivity can then advance terminal progress, so the embedder may park on\nactivity alone. The value drops straight into a wait primitive's timeout\nargument.");
    try emitFn(&b, gpa, "pancake_host_lifecycle_state", &.{ "host", "out_state" }, "Observe the current PANCAKE_LIFECYCLE_* state without advancing time. The\nordinary byte-feed and action-drain cycle advances terminal work; call\npancake_host_close_progress when the embedder clock advances. CLOSED means every\nsession and queued Host effect has retired. A prior finite grace expiry returns\nPANCAKE_ERR_TIMEOUT together with CLOSED.");
    try emitFn(&b, gpa, "pancake_host_release", &.{"host"}, "Release the host and everything it owns: every still-open session (each\nstill-parked vow breaks inside this call, its undrained completion freed\nwith the rest of the action queue), the vow map, parked actions, the node,\nand the giftable rows (each giftable's free runs exactly once here). NULL is\na no-op. Session (PancakeHostSession) handles this host minted are freed with it —\nnever touch one after its host is gone. Because release is terminal, an embedder\nmay transfer exclusive ownership to a finalizer thread after every Host call has\nreturned; no live Host verb gains cross-thread permission. Refusal from inside a\ncallback sets last error and leaves the handle live. A teardown failure also sets\nlast error but consumes the handle after completing the ownership sweep.");
    try emitFn(&b, gpa, "pancake_host_designator_from_seed", &.{ "seed", "seed_len", "out", "out_len" }, "Derive the canonical key designator (exactly 64 lowercase hex digits) from a\n32-byte Ed25519 durable identity seed — the public half of the first half of\nthe 64-byte buffer pancake_host_new takes. CapTP session signing keys come\nfrom the second half (ADR-0097), not from this designator seed. Writes 64\nbytes into out (out_len must be at least 64). Used by a keyed-tcp listener\nwhose locator designator is this durable identity (ADR-0075).");
    try emitFn(&b, gpa, "pancake_host_set_advertised_locator", &.{ "host", "locator" }, "Retain and select this host's complete acceptable location. The Host validates and deep-copies the borrowed locator view. Later dialed and accepted sessions sign this selection regardless of the transport carrying them.");
    try emitFn(&b, gpa, "pancake_host_ensure_advertised_locator", &.{ "host", "transport", "transport_len" }, "Retain a dial fallback for transport unless one already exists. It becomes the\nacceptable location only when the Host has no selection; it never displaces a\nroute selected for another transport. Key-designator transports use this Host's\npublic key; address transports use the unreachable-client placeholder. A\nreachable adapter must publish its complete locator explicitly.");
    try emitFn(&b, gpa, "pancake_host_remove_advertised_locator", &.{ "host", "transport", "transport_len" }, "Remove the retained locator for transport. Removing the selected route leaves\nno acceptable location until one is set or ensured; another retained route is\nnever chosen implicitly. Existing sessions retain the signed hello snapshot\nthey already sent.");
    try emitFn(&b, gpa, "pancake_host_set_session_limits", &.{ "host", "max_frame_bytes", "queue_cap", "outbound_high_water_bytes" }, "Selective session-limit knobs (ADR-0082): override max_frame_bytes, queue_cap,\nand/or outbound_high_water_bytes on a host before minting sessions. Pass 0 for\na field to leave it unchanged. Already-open peers keep the limits they were\nminted with.");
    try emitFn(&b, gpa, "pancake_host_session_open_dialed_locator", &.{ "host", "locator", "out_session" }, "Mint the dialing half after an embedder has opened the byte channel for\nlocator. The one locator vocabulary is taken whole: the designator keys\nduplicate-dial refusal and, on a key transport, demands the partner's durable\nkey; route hints carry no semantics here because the caller's dial executor\nspent them realizing the channel. A DIAL action carries only ticket: project\nits typed locator with pancake_host_pending_dial, open the channel it names,\nand pass the view back here. The host retains its own dial default for the\nlocator's transport first, never displacing an advertised locator the embedder\nexplicitly selected, so a bare client host dials without publishing anything.\nA sealed session derives its Noise ephemeral from the Host's unique\nper-session seed under a separate KDF domain, so callers do not branch on\ntransport policy or supply per-open entropy. The keyed op:start-session is\nsigned under the host identity and encoded before this returns, so drain\ntake_outbound (a FLUSH action is queued) and drive the handshake byte-fed.\nHost-wide aliases remain lazily discoverable through the new session.\n*out_session is host-owned; release with pancake_host_session_release.");
    try emitFn(&b, gpa, "pancake_host_session_open_accepted", &.{ "host", "transport", "transport_len", "designator_scheme", "server_designator", "server_designator_len", "accepted_local_addr", "accepted_local_addr_len", "out_session" }, "Mint the accepting half of a connection your listener produced.\ndesignator_scheme is the provider's PANCAKE_DESIGNATOR_SCHEME_* declaration;\nserver_designator is the listener's own signing designator (its key for a key\ntransport, unused for an address transport); accepted_local_addr is the route\nthe accept reported (NULL/0 when unavailable). The host retains the locator\nthis accept would sign without displacing an acceptable location the embedder\nalready selected: an explicit pancake_host_set_advertised_locator is deployment\npolicy and wins, and the accept-derived locator becomes the selection only when\nthere is none. The session signs the selected snapshot even when it names\nanother transport. Sealed-channel entropy follows the dialed half's Host-owned\nderivation. Host-wide aliases remain lazily discoverable, with the same flush\nand release contract as the dialed half.");
    try b.appendSlice(gpa, "\n");
    try emitConst(&b, gpa, "PANCAKE_DIAL_SHAPE_HOST_PORT");
    try emitConst(&b, gpa, "PANCAKE_DIAL_SHAPE_PEER_ID");
    try emitConst(&b, gpa, "PANCAKE_DIAL_SHAPE_SIGNALING");
    try emitConst(&b, gpa, "PANCAKE_DIAL_SHAPE_RENDEZVOUS");
    try emitConst(&b, gpa, "PANCAKE_DIAL_REACH_DIRECT");
    try emitConst(&b, gpa, "PANCAKE_DIAL_REACH_CONFIGURED");
    try emitConst(&b, gpa, "PANCAKE_DIAL_REACH_EXPLICIT");
    try emitConst(&b, gpa, "PANCAKE_DIAL_POSTURE_REDEEM");
    try emitConst(&b, gpa, "PANCAKE_DIAL_POSTURE_EXPLICIT");
    try emitConst(&b, gpa, "PANCAKE_DIAL_POSTURE_EXPLICIT_NONE");
    try emitConst(&b, gpa, "PANCAKE_DESIGNATOR_SCHEME_ADDRESS");
    try emitConst(&b, gpa, "PANCAKE_DESIGNATOR_SCHEME_KEY");
    try emitConst(&b, gpa, "PANCAKE_HOST_OUTBOUND_PREFIX_CAP");
    try emitConst(&b, gpa, "PANCAKE_HOST_DURABLE_ENTROPY_LEN");
    try emitConst(&b, gpa, "PANCAKE_HOST_DURABLE_SWISS_LEN");
    try b.appendSlice(gpa, "\n");
    try emitDoc(&b, gpa,
        \\A resolved dial from pancake_host_plan_dial: what byte channel to open and
        \\how. shape (PANCAKE_DIAL_SHAPE_*) selects the live fields — HOST_PORT fills
        \\host/host_len/port, PEER_ID fills addresses/addresses_len and the reachability.
        \\Every view borrows the transport/designator/hint the caller passed in, so
        \\the plan is valid only while those buffers are.
    );
    try E.emitStruct(&b, gpa, Spec.c.PancakeDialPlan, "PancakeDialPlan", &.{
        "A PANCAKE_DIAL_SHAPE_* value.",
        "HOST_PORT: the resolved TCP host (borrows the designator or hint).",
        "",
        "HOST_PORT: the resolved TCP port.",
        "PEER_ID: the direct-addresses to dial (borrows the hint verbatim).",
        "",
        "PEER_ID: a PANCAKE_DIAL_REACH_* value.",
        "PEER_ID: the caller posture when reach_kind is PANCAKE_DIAL_REACH_EXPLICIT.",
    });
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "pancake_host_pending_dial", &.{ "host", "ticket", "hint_storage", "hint_capacity", "out_locator", "out_hint_count" }, "Project the complete in-flight locator for ticket into out_locator, using the\ncaller-owned hint_storage array. On PANCAKE_OK, *out_hint_count is the number\nof initialized hints and the locator plus all nested byte views remain\nHost-owned until pancake_host_dialed / pancake_host_dial_failed consumes the\nticket (or Host teardown); hint_storage remains caller-owned. When\nhint_capacity is too small, returns PANCAKE_ERR_BUFFER_TOO_SMALL, writes the\nrequired capacity to *out_hint_count, and leaves *out_locator untouched. The\nlocator was parsed and retained once when the give was accepted; no URI is\nreparsed and no hint is discarded. Unknown tickets return\nPANCAKE_ERR_INVALID_ARGUMENT.");
    try emitFn(&b, gpa, "pancake_host_reference_exporter", &.{ "host", "reference", "out_session" }, "Write the live session homing remote reference into *out_session, or NULL for\na local, stale, foreign-Host, or closed-session capability. Bindings compare\nthis result with the sending session after a call: the same session is an\nordinary reply, while another session is the exporter reached through handoff.\nThe answer comes from the reference's own Host row, with no dial-completion\ncapture window. The returned handle is Host-owned and lives with that session;\ndo not release it here.");
    try emitFn(&b, gpa, "pancake_host_plan_dial", &.{ "transport", "transport_len", "designator", "designator_len", "direct_addresses_hint", "direct_addresses_hint_len", "posture_policy", "posture_value", "out_plan" }, "Resolve a dial without opening a socket: the transport dispatch, designator\nvalidation, host:port resolution, and peer-id reachability decision every binding\nused to re-express, done once here. transport/designator are the locator's\npieces (from pancake_host_pending_dial or pancake_uri_parse_peer);\ndirect_addresses_hint is the locator's direct-addresses hint (NULL/0 = none);\nposture_policy is a PANCAKE_DIAL_POSTURE_* choosing the peer-id reachability rule,\nwith posture_value the caller's posture under PANCAKE_DIAL_POSTURE_EXPLICIT.\nOn PANCAKE_OK *out_plan is filled with views borrowing the caller's buffers; a\nbad locator returns PANCAKE_ERR_INVALID_ARGUMENT (pancake_host_last_error\ncarries which). Open the channel the plan names, then pass the same\nlocator view to pancake_host_session_open_dialed_locator.");
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "pancake_host_session_close", &.{ "session", "options", "now_ms" }, "Seal one byte-fed session's application admission and begin or escalate its\nterminal close. now_ms is the embedder's monotonic millisecond reading. The\nshared controller retains the first FINISH deadline while the embedder keeps\nfeeding bytes and draining actions. This closes without releasing the handle.");
    try emitFn(&b, gpa, "pancake_host_session_close_progress", &.{ "session", "now_ms", "out_state" }, "Apply the current monotonic clock reading to one started session close and write\nits PANCAKE_LIFECYCLE_* phase. Expired FINISH escalates through CANCEL. CLOSED\nmeans the terminal transport action crossed its retryable delivery boundary; a\ntimed-out close returns PANCAKE_ERR_TIMEOUT together with CLOSED.");
    try emitFn(&b, gpa, "pancake_host_session_lifecycle_state", &.{ "session", "out_state" }, "Observe one session's PANCAKE_LIFECYCLE_* phase without advancing time. CLOSED\nmeans the terminal transport action crossed its retryable delivery boundary while\nthe retained shell remains valid for explicit release. A prior finite grace expiry\nreturns PANCAKE_ERR_TIMEOUT together with CLOSED.");
    try emitFn(&b, gpa, "pancake_host_session_release", &.{"session"}, "Release one session: its still-parked far vows break (their FAIL\ncompletions queue inside this call), the node retires it — stranded\nwithdraws fail closed, so SIBLING sessions' vows may break here too — and\nthe shell is freed. NULL is a no-op; refused (last error set, the session\nkept) from inside a callback.");
    try emitFn(&b, gpa, "pancake_host_session_is_open", &.{"session"}, "Nonzero once the keyed handshake has completed and the session is open.");
    try emitFn(&b, gpa, "pancake_host_session_trace_id", &.{ "session", "out_id" }, "The id the live trace names this session's rows by (PancakeTraceEvent's session), so an embedder can annotate the same session a trace consumer is watching. Stable for the session's life and never reused by this host.");

    try emitFn(&b, gpa, "pancake_host_session_feed", &.{ "session", "frame_in" }, "Feed one inbound frame you read from your own transport (borrowed for the\ncall): behavior callbacks fire and vow completions queue inside, then the\nnode actions the dispatch queued pump and every touched session's outbound\nencodes. PANCAKE_ERR_WOULD_BLOCK is the preflight high-water refusal: the frame\nwas not consumed, so drain actions / outbound frames and retry it. Other\nfailures classify through PANCAKE_ERR_CODEC / _SESSION / _INTERNAL. When\npancake_host_session_last_abort succeeds, the frame was consumed and the\nsession is closing; drain its typed op:abort and release it. PANCAKE_ERR_INTERNAL\nwith no last-abort is allocation failure before frame admission, so the same\nborrowed frame remains retryable.");
    try emitFn(&b, gpa, "pancake_host_session_feed_bytes", &.{ "session", "bytes", "len" }, "Feed a byte-stream chunk you read from your own transport (borrowed for the\ncall). The library owns outer framing and the tail: each bare codec frame is\none canonical Syrup byte string (decimal length, colon, body). Split prefixes\nand bodies stay buffered in the session; coalesced byte strings dispatch in\norder, each body exactly as pancake_host_session_feed. Dispatch pauses at the\nframe that completes the keyed handshake: frames coalesced behind the hello\nwait in the session's tail while you act on the fresh session (publish, fetch),\nand your next call — an empty chunk (len 0, bytes may be NULL) works — feeds\nthem. PANCAKE_ERR_WOULD_BLOCK is the preflight high-water refusal and consumes\nno bytes from this call. Internal pressure after any prefix commits is retained\nin the session tail and returns success; PANCAKE_ERR_INTERNAL with no last-abort\ntherefore means the first direct frame was not admitted and the same chunk is\nretryable. A recorded last-abort means the input was consumed and the session\nis closing; drain the typed abort and release it. A declared body exceeding the\nsession's frame cap is PANCAKE_ERR_FRAME_TOO_LARGE; malformed or non-canonical\nouter syntax is a codec error.");
    try emitFn(&b, gpa, "pancake_host_session_take_outbound", &.{ "session", "out_frame", "out_prefix", "prefix_cap", "out_prefix_len" }, "Drain one transport-ready byte-stream vector. Write\nout_prefix[0..*out_prefix_len] and then the owned out_frame bytes. Clear\nsessions return their canonical outer Syrup prefix; sealed sessions return an\nempty prefix because out_frame is already wire-ready ciphertext. Free out_frame\nthrough pancake_managed_frame_release. prefix_cap must be at least\nPANCAKE_HOST_OUTBOUND_PREFIX_CAP; undersizing is refused before the payload\nleaves the queue. Returns PANCAKE_OK with outputs set, or\nPANCAKE_ERR_WOULD_BLOCK with outputs untouched. Refused inside a callback.");
    try emitFn(&b, gpa, "pancake_host_next_action", &.{ "host", "out_action" }, "Pop the next embedder action into *out_action, or return\nPANCAKE_ERR_WOULD_BLOCK when none is pending. A DIAL carries only ticket\n(borrow the pending view with pancake_host_pending_dial). A SETTLE's value\nand a FAIL's message are host-owned until the NEXT pancake_host_next_action\ncall, which frees them. Deferred work may return PANCAKE_ERR_INTERNAL under\nallocator pressure before an action is popped; no action or authority is lost,\nand the embedder retries this same drain call when pressure subsides. See the\none loop rule in the header preamble. Refused inside a callback.");
    try emitFn(&b, gpa, "pancake_host_pump_drain", &.{ "host", "hooks", "out_acted", "out_yielded" }, "Opt-in convenience drain over pancake_host_next_action (ADR-0072 fifth\namendment). Still pops through the pull-queue internally; does not replace\nit. hooks may be NULL (every action is discarded). *out_acted is 1 when any\narm reported progress (optional, may be NULL). *out_yielded is 1 when the\nfinite Host scheduler requested another embedder turn (optional, may be NULL);\nreturn to the reactor before draining again. See PancakeHostPumpHooks.");
    try emitFn(&b, gpa, "pancake_host_dialed", &.{ "host", "ticket", "session" }, "Report a DIAL action's success: session is an open_dialed_locator against the\npending dial for ticket (pancake_host_pending_dial), driven to an\nopen session. The host withdraws every give waiting on the ticket; the\nwithdraws, their settles, and their flushes pump inside this call. A stale\nticket is a no-op success.");
    try emitFn(&b, gpa, "pancake_host_dial_failed", &.{ "host", "ticket", "reason", "reason_len" }, "Report a DIAL action's failure: every redeem waiting on the ticket breaks\nwith reason, its FAIL completion queued inside this call. A stale ticket is a\nno-op success.");
    try emitFn(&b, gpa, "pancake_host_dial_cancelled", &.{ "host", "ticket" }, "Acknowledge that a CANCEL_DIAL action's physical operation has stopped and its\nexecutor state can be released. Host close remains pending until this report.");
    try emitFn(&b, gpa, "pancake_host_provide_gift_id", &.{ "host", "ticket", "gift_id", "gift_id_len" }, "Answer a NEED_GIFT_ID action with 32 caller-drawn random bytes: the host\noriginates the claimed handoff and this call flushes its legs, exporter\nfirst. A stale ticket is a no-op success.");
    try emitFn(&b, gpa, "pancake_host_gift_id_failed", &.{ "host", "ticket" }, "Report that a NEED_GIFT_ID action could not obtain or provide entropy. The\nclaimed handoff settles broken instead of retaining a ticket the embedder has\nalready consumed. A stale ticket is a no-op success.");

    try emitFn(&b, gpa, "pancake_host_session_publish", &.{ "session", "name", "name_len", "behavior", "ctx", "free", "out_ref" }, "Publish a hosted object a partner on this session can fetch by name (a\nswiss-number). The Host Vat owns the object; this session selects its first\nPort projection. Releasing that session does not run free. On success, free,\nif non-NULL, runs exactly once at Host teardown; a failed construction runs it\nafter this call takes ownership. *out_ref receives the opaque Host-scoped\ncapability. Refused inside a callback (ctx stays yours on a null-pointer or\nreentry refusal).");
    try emitFn(&b, gpa, "pancake_host_session_spawn", &.{ "session", "behavior", "ctx", "free", "out_ref" }, "Spawn a hosted object in the Host Vat and create its first projection on this\nsession, without a fetchable name. It becomes reachable once a reply or\nargument carries the opaque Host-scoped capability written to *out_ref. Same\nfree contract as pancake_host_session_publish.");
    try emitFn(&b, gpa, "pancake_host_publish", &.{ "host", "name", "name_len", "behavior", "ctx", "free" }, "Publish one hosted object in the Vat owned by this Host and bind name as its\nhost-wide alias. Fetch lazily projects the actor onto the requesting Port; a\ndeposited gift retains the exact actor and never consults the alias at\nwithdrawal. The giftable row owns ctx: free, if non-NULL, runs exactly once, at\npancake_host_release on success or before this returns on any non-OK outcome\n(the null-pointer and reentry refusals touch nothing and leave ctx yours).\nAll-or-nothing over this call's own work: registration failure discards the\nfresh actor and frees ctx, so a retry starts with no partial alias or projection.");
    try emitFn(&b, gpa, "pancake_host_unpublish", &.{ "host", "name", "name_len" }, "Remove the host-wide alias name. Discovery-only, alias-only: a later fetch of\nthe name misses on every session, while capabilities already issued, live Port\nprojections, and deposited gifts keep naming the exact actor, which stays in\nthe Host's Vat until pancake_host_release. An absent alias returns\nPANCAKE_ERR_NOT_FOUND, so a typo is loud instead of an idempotent no-op. A name\nin the reserved durable namespace is refused INVALID_ARGUMENT: minted durable\npublications leave through pancake_host_remove_durable.");
    try emitFn(&b, gpa, "pancake_host_publish_durable", &.{ "host", "entropy", "entropy_len", "behavior", "ctx", "free", "out_swiss", "swiss_cap" }, "Publish one hosted object under a freshly minted durable swiss name: a\nreserved-prefix namespace mutable aliases structurally cannot enter,\nunpredictable, never reassigned, and removable only through\npancake_host_remove_durable. entropy supplies exactly 16 caller-drawn random\nbytes (the embedder owns the entropy boundary, as for gift ids). The minted\nswiss is written into out_swiss (swiss_cap of at least 50 bytes, or\nBUFFER_TOO_SMALL and nothing published) and the written length is returned.\nctx/free follow pancake_host_publish's ownership exactly. The core stores no\nregistry across processes: preserve the entropy and republish the actor with\nthe same bytes at startup to reproduce the sturdyref; losing either makes the\nold name miss, fail-closed.");
    try emitFn(&b, gpa, "pancake_host_remove_durable", &.{ "host", "swiss", "swiss_len" }, "Remove a minted durable publication: the old sturdyref misses from now on,\nwhile capabilities already issued and deposited gifts keep the exact actor. A\nswiss outside the durable namespace returns INVALID_ARGUMENT (mutable aliases\nleave through pancake_host_unpublish); an unknown durable name returns\nPANCAKE_ERR_NOT_FOUND.");

    try emitFn(&b, gpa, "pancake_host_session_fetch", &.{ "session", "name", "name_len", "out_vow" }, "Fetch the partner capability published as name, minting a host vow whose id\nlands in *out_vow; the outcome arrives as that vow's SETTLE or FAIL action.\nA fulfilled far capability settles ALREADY enrolled under a node-unique\ntoken — recorded before the completion is queued, so a reply that\nimmediately re-gifts it routes to the right exporter. Refused inside a\ncallback.");
    try emitFn(&b, gpa, "pancake_host_session_enliven", &.{ "session", "sturdyref_uri", "sturdyref_uri_len", "out_vow" }, "Enliven the complete sturdyref URI (ADR-0098), minting a host vow whose id\nlands in *out_vow; the live reference arrives as that vow's SETTLE action.\nThe URI's transport and designator must match the selected session before\nthe swiss namespace is consulted or wire traffic is emitted. A dedup-cache\nhit settles before this returns; a fresh enliven rides bootstrap-fetch.\nRefused inside a callback.");

    try emitFn(&b, gpa, "pancake_host_enliven", &.{ "host", "sturdyref_uri", "sturdyref_uri_len", "out_vow" }, "Select-or-dial enliven of a complete sturdyref URI (ADR-0098): enliven it\nover a live session this host already dialed to that peer, or stage a dial\nand finish when you report it. The host vow id lands in *out_vow and its\noutcome arrives as that vow's SETTLE or FAIL action either way. A staged\ndial surfaces as an ordinary PANCAKE_HOST_ACTION_DIAL — borrow it with\npancake_host_pending_dial and answer it with pancake_host_dialed /\npancake_host_dial_failed exactly as a handoff redeem's — so a parked vow's\nid has no session and no row until it settles. Refused inside a callback.");
    try emitFn(&b, gpa, "pancake_host_session_listen", &.{ "session", "target", "out_vow" }, "Listen on a far capability this session holds (CapTP op:listen), minting a\nhost vow whose id lands in *out_vow; the listen notification arrives as that\nvow's SETTLE or FAIL action. In 1.0, the target may be a far promise or live\nfar object; a live object answers immediately. In pancake-next, the target\nmust be a far promise because shortening and settling are promise-only. A\nre-gifted promise routes to its exporter session transparently, and a give in\nthe settlement auto-redeems exactly as a fetch's would. The vow is plain: a\nlisten makes no claim the result is a capability. Legal inside a callback.");

    try emitFn(&b, gpa, "pancake_host_session_send", &.{ "session", "target", "verb", "verb_len", "args", "args_len", "out_vow" }, "Eventual-send to an opaque Host-scoped target and mint a host vow for the\nanswer; the outcome arrives as that vow's SETTLE or FAIL action. The Host\nchooses local delivery or the owning exporter session. A target or nested\nargument from another Host, or a retired identity, is refused rather than\nbeing interpreted as a wire position. verb/args are borrowed; the host copies\nwhat it queues. An empty verb — including (NULL, 0), which the family's ptr+len\ncontract admits — is a real message, not an error: it delivers positionally,\nthe way Goblins invokes a capability. Legal inside a callback (the send\nencodes when the enclosing call unwinds).");
    try emitFn(&b, gpa, "pancake_host_session_tell", &.{ "session", "target", "verb", "verb_len", "args", "args_len" }, "Fire-and-forget eventual-send: pancake_host_session_send with no answer and no\nvow. Same routing, refusals, and empty-verb contract.");
    try emitFn(&b, gpa, "pancake_host_vow_send", &.{ "host", "vow", "verb", "verb_len", "args", "args_len", "out_vow" }, "Promise pipelining: eventual-send to a host vow before it resolves, minting a\nnew vow for this call's own answer. A local vow (a NEAR send's answer) has no\nwire answer to pipeline against and is refused PANCAKE_ERR_INVALID_ARGUMENT\n(NotPipelineable); an unknown vow reports PANCAKE_ERR_NOT_FOUND. The\nempty-verb contract is pancake_host_session_send's.");
    try emitFn(&b, gpa, "pancake_host_vow_index", &.{ "host", "vow", "index", "out_vow" }, "Pipeline an op:index projection against a far host vow, minting a new vow for\nthe projected element. Same local-vow and unknown-vow refusals as\npancake_host_vow_send; an index above INT64_MAX is refused\nPANCAKE_ERR_INVALID_ARGUMENT (the wire index is a signed integer).");
    try emitFn(&b, gpa, "pancake_host_vow_untag", &.{ "host", "vow", "tag", "tag_len", "out_vow" }, "Pipeline an op:untag projection against a far host vow, minting a new vow for\nthe unwrapped payload (a single-value Tagged unwraps to that value; a\nvariadic one to its value list). tag is borrowed.");
    try emitFn(&b, gpa, "pancake_host_vow_get", &.{ "host", "vow", "field", "field_len", "out_vow" }, "Pipeline an op:get projection against a far host vow, minting a new vow for\nthe named Struct field. Same local-vow and unknown-vow refusals as\npancake_host_vow_send; field is borrowed.");

    try emitFn(&b, gpa, "pancake_host_set_trace", &.{ "host", "callback", "ctx" }, "Install (or clear, with a NULL callback) the live trace: the host reports\nits own session opens, every message's verb in both directions, and session\ncloses through callback, on the host's one thread. Views in the event are\nborrowed for the call. The callback must call no host-driving verb.");
    try emitFn(&b, gpa, "pancake_host_set_trace_queue", &.{ "host", "capacity", "payload_cap" }, "Install (or clear, with a zero capacity) the drained live trace: the host\ncaptures each fact into a fixed ring of capacity records, each holding up to\npayload_cap bytes of that record's strings, and the embedder pops them with\npancake_host_next_trace. This is the seam for an embedder that cannot hand\nthe library a function pointer. Nothing here grows: a full ring drops the\nnewest record and reports the count on the next one it captures, so tracing\nnever makes the protocol wait.");
    try emitFn(&b, gpa, "pancake_host_next_trace", &.{ "host", "out_event" }, "Pop the oldest captured trace record into out_event. Its string views point\ninto the queue and stay valid until the next pancake_host_next_trace call,\nthe same borrow pancake_host_next_action carries. Returns\nPANCAKE_ERR_WOULD_BLOCK when nothing is captured, so an embedder drains in a\nloop until it sees that code.");
    try emitFn(&b, gpa, "pancake_host_resolver_fulfill", &.{ "host", "resolver_id", "value" }, "Settle a resolver vow fulfilled with one capability-free value (a value\nnaming a capability refuses whole; an answer that carries authority uses\nthe turn's forward instead). Top-level: refused inside a callback; the\nsettle runs the deferred answers and pumps the sessions they dirtied. A\nsuccessful settle consumes the resolver; preparation failure is retryable,\nwhile a second successful settle or an unknown id refuses.");
    try emitFn(&b, gpa, "pancake_host_resolver_break", &.{ "host", "resolver_id", "message", "message_len" }, "Settle a resolver vow broken with a diagnostic borrowed for the call. The\nsame top-level, consume-on-success contract as\npancake_host_resolver_fulfill.");
    try emitFn(&b, gpa, "pancake_host_turn_session", &.{ "turn", "out_session" }, "Borrow the session whose Port delivered this callback turn. The handle is\nHost-owned and lives with that session; do not release it. This is how an\nembedder whose driver serves several sessions identifies the arriving\nconnection without reconstructing delivery state outside the core.");
    try emitFn(&b, gpa, "pancake_host_turn_forward", &.{ "turn", "target", "verb", "verb_len", "args", "args_len", "out_reply" }, "From inside a behavior callback, forward this turn's call to an opaque\nHost-scoped target and let this object's own answer settle on the forwarded\nresult — the caretaker/attenuator primitive. The Host resolves the target and\nevery nested capability; a stale or foreign-Host identity is refused. In a\nwire-served turn the real answer rides the forwarded vow and *out_reply gets a\nvoid placeholder; pass your behavior's own out_reply and return PANCAKE_OK.\nThe written reply is BORROWED — valid until the next turn verb or drive on\nthis host. The empty-verb contract is pancake_host_session_send's.");
    try emitFn(&b, gpa, "pancake_host_turn_defer", &.{ "turn", "out_resolver_id" }, "Atomically defer this turn's answer onto a fresh resolver vow (ADR-0102).\n*out_resolver_id receives the one-shot settle authority used by\npancake_host_resolver_fulfill / _break. All rows and the forward listener are\nreserved before publication, so refusal leaves no live resolver and no\nforwarded effect. The behavior returns normally after success; its return\nvalue resolves nothing once the turn is deferred.");
    try emitFn(&b, gpa, "pancake_host_turn_send", &.{ "turn", "target", "verb", "verb_len", "args", "args_len", "out_vow" }, "From inside a behavior callback, eventual-send to target and mint a host vow\nfor the answer — the same routing, refusals, and empty-verb contract as\npancake_host_session_send, on the turn's own session. The send encodes when the\nenclosing top-level call unwinds.");
    try emitFn(&b, gpa, "pancake_host_turn_tell", &.{ "turn", "target", "verb", "verb_len", "args", "args_len" }, "From inside a behavior callback, fire-and-forget eventual-send —\npancake_host_turn_send with no answer and no vow. Same empty-verb contract.");
    try emitFn(&b, gpa, "pancake_host_turn_spawn", &.{ "turn", "behavior", "ctx", "free", "out_ref" }, "From inside a behavior callback, spawn a hosted object in the Host Vat and\ncreate its first projection on the Port that delivered this turn. This is how a\nserved factory mints a capability it replies with (a task board's create, a\ncaretaker wrapping a target), the turn-time form of\npancake_host_session_spawn. Same free contract; *out_ref receives the opaque\nHost-scoped capability, ready to ride this turn's own reply.");
    try emitFn(&b, gpa, "pancake_host_turn_break", &.{ "turn", "message", "message_len" }, "From inside a behavior callback, break this turn's own answer with message —\nhow a behavior refuses with a diagnostic, since a non-OK return settles the\nanswer broken with only a generic reason. The answer resolves broken inside\nthis call (a no-answer tell breaks nothing); leave out_reply untouched and\nreturn PANCAKE_OK from the behavior, whose return value then resolves\nnothing. message is borrowed and copied.");

    try emitFn(&b, gpa, "pancake_host_ref_release", &.{ "host", "ref", "delta" }, "Release delta application retains on one opaque Host capability. The Host\nresolves the owning session and emits any required op:gc-exports itself; the\ncaller never pairs a capability with a session-local wire position. A stale or\nforeign-Host identity is refused. A non-OK return commits no release, so the\nsame (ref, delta) may be retried. OK consumes the release; any later pump\ncleanup failure becomes typed session close and must not invite a duplicate\nrelease. Single-thread affinity applies: never call this from a finalizer\nthread.");
    try emitFn(&b, gpa, "pancake_host_session_published_ref", &.{ "session", "name", "name_len", "out_ref" }, "Write to *out_ref the opaque Host-scoped capability currently published under\nname, or return PANCAKE_ERR_NOT_FOUND when the Host has no such alias. The actor\nin the Host-owned Vat is lazily projected onto session when needed; the\nreturned identity itself carries no export position and retains no name.");
    try emitFn(&b, gpa, "pancake_host_session_break_far_vows", &.{ "session", "message", "message_len" }, "Break every far vow currently parked on session, queueing each vow's FAIL\ncompletion inside this call with the partner's retained abort diagnostic when\none arrived and message otherwise. The session remains open to later work; use\npancake_host_session_transport_closed when the byte channel is gone.");
    try emitFn(&b, gpa, "pancake_host_session_transport_closed", &.{ "session", "message", "message_len" }, "Report that this session's transport is gone. The Host seals session\nadmission, retires its routing authority, and queues each pending far vow's\nFAIL completion inside this call, using the partner's retained abort\ndiagnostic when one arrived and message otherwise. Memory remains owned until\npancake_host_session_release.");
    try emitFn(&b, gpa, "pancake_host_session_set_exporter_location", &.{ "session", "locator" }, "Record the exporter locator to embed in gives whose exporter is session, overriding the session record. Null clears the override; otherwise the Host validates and clones the borrowed locator view.");
    try emitFn(&b, gpa, "pancake_host_session_last_abort", &.{ "session", "out" }, "Read the typed cause of this session's most recent LOCAL dispatch failure\ninto *out (the shared PancakeLastAbort layout; byte views process-static,\nnever freed). Returns PANCAKE_OK when a failure has been recorded, or\nPANCAKE_ERR_WOULD_BLOCK when none has. The flat per-feed return code names\nthe failure family; this names the member.");
    try emitFn(&b, gpa, "pancake_host_session_partner_abort", &.{ "session", "out_kind_name", "out_kind_name_len", "out_msg", "cap", "out_len" }, "Read the PARTNER'S retained op:abort: the abort kind's wire name (a\nprocess-static view, e.g. \"ProtocolError\") into\n*out_kind_name / *out_kind_name_len, and up to cap bytes of its bounded\ndiagnostic into out_msg, with the retained length in *out_len. Returns\nPANCAKE_ERR_WOULD_BLOCK when no partner abort has arrived. Any out-pointer\nmay be NULL to skip that piece.");

    try emitDoc(&b, gpa,
        \\The partner identity this session's handshake proved: the partner's session
        \\public key, the location designator it signed, and the verbatim
        \\<ocapn-peer> record those came from.
        \\
        \\This answers "who am I talking to" without taking the partner's word for
        \\it. A keyed op:start-session carries an Ed25519 signature over the
        \\partner's own <my-location> record, and the engine verifies that
        \\signature before the session opens and before any of these bytes are
        \\learned. The signed span covers the whole location record, so designator
        \\is bound to session_key by the same signature. An application can require
        \\that a locator a caller CLAIMS names the key that caller actually proved,
        \\and refuse a mismatch.
        \\
        \\Views are session-owned. The bytes are written once when the partner's
        \\handshake half arrives and are never rewritten, so they stay valid until
        \\pancake_host_session_release, or until the host is torn down.
    );
    try E.emitStruct(&b, gpa, Spec.c.PancakePartnerIdentity, "PancakePartnerIdentity", &.{
        "The partner's session public key. Always present on PANCAKE_OK.",
        "",
        "The designator the partner signed, or NULL when its location carried none.",
        "",
        "The verbatim location record, or NULL when the apply path captured none.",
        "",
        "How the durable identity in designator was authenticated, one of the\nPANCAKE_DURABLE_PROVENANCE_* values. It is derived from the evidence this one\nsession holds, never from its transport's name, so two sessions on the same\ntransport can answer differently.\n\nSession identity, durable identity, and this provenance are three separate\nfacts: a caller that requires a proved durable peer reads this, never a\ncomparison of designator against session_key. Each session draws its own\nsigning key, so a session key is not an identity and the two never match.",
    });
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "pancake_host_session_partner_identity", &.{ "session", "out" }, "Borrow this session's verified partner identity into *out: the partner's\nsession public key, the location designator it signed, and the verbatim\nlocation record those came from.\n\nA PANCAKE_OK return always means the signature was checked. Before the\npartner's op:start-session has arrived with a key this returns\nPANCAKE_ERR_WOULD_BLOCK, and a session opened without partner verification\nreturns PANCAKE_ERR_SESSION rather than an identity nothing proved. That\nrefusal is the contract: you cannot read an unverified identity through this\nentry point, so you never have to remember to ask whether the bytes were\nchecked.");
    try emitFn(&b, gpa, "pancake_host_session_bind_verified_channel_key", &.{ "session", "designator", "designator_len" }, "Testify what the code that realized this connection proved about its far\nend: designator is the durable key that proof names, as a locator writes it.\nAn iroh listener passes what pancake_iroh_conn_remote_node_id read off the\nQUIC handshake; a WebRTC peer passes the identity its signaling\nauthorized.\n\nThis library realizes nothing at the byte-fed tier. You own the sockets, so\nyou are the realizer, and this is the only way that proof reaches a session.\nWithout it the session reports unauthenticated durable provenance.\n\nCall it after opening the session and before feeding the first partner byte.\nPANCAKE_ERR_SESSION means the partner's op:start-session was already applied,\nso the proof is too late to weigh. PANCAKE_ERR_INVALID_ARGUMENT means the\ndesignator does not spell a durable key, or names a different key from one\nthis connection's realizer already asserted. Asserting the same key twice is\nthe same statement made twice and succeeds.");

    try emitFn(&b, gpa, "pancake_host_last_error", &.{ "out_buf", "cap" }, "Copy the calling thread's last pancake_host_* error into out_buf, the host\nsibling of pancake_last_error, reading this archive's own per-thread slot.\nCopies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or cap\n0 queries the length. Returns the full message length, or 0 when none is set.");
    try emitFn(&b, gpa, "pancake_host_clear_last_error", &.{}, "Clear the calling thread's pancake_host_* last-error slot.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* PANCAKE_HOST_H */
        \\
    );

    try E.assertAllEmitted(&b, "gen-header-host");
    return b.toOwnedSlice(gpa);
}
