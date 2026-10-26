//! Generates `include/glowcap_host.h` from the Zig `c_abi_host` source.
//!
//! The byte-fed host tier's public C ABI is a separate archive from
//! `libglowcap_ocapn` (ADR-0022), so it gets its own header. As with
//! `tools/gen/header/ocapn.zig`, the function signatures are *reflected* from the real
//! `src/c_abi/host/mod.zig` exports, so the header cannot disagree with the
//! implementation, and the prose lives here.
//! `zig build gen-header-host-check` is the staleness gate, `zig build
//! gen-header-host` is the fixer.
//!
//! The shared vocabulary (`GlowcapFrame`, `GlowcapManagedFrame`,
//! `GlowcapContext`, `GlowcapArgument`, `GlowcapReference`, `GlowcapLastAbort`)
//! and the return codes are declared in `glowcap_ocapn.h`, which this header
//! includes. The host/session/turn handles, the two behavior callbacks, the
//! action vocabulary, and the `glowcap_host_*` prototypes are new here.

const std = @import("std");
const header_emit = @import("header_emit.zig");

const Output = @import("output").Output;
pub const outputs = [_]Output{
    .{ .path = "include/glowcap_host.h", .generate = generate },
};
pub const step_name = "gen-header-host";

// The ABI metadata owns the symbol inventory used by every binding. Header
// coverage still checks it against exported declarations and emitted prototypes.
const emitted_fn_names = blk: {
    const symbols = @import("c_abi_host").symbols.symbols;
    var names: [symbols.len][]const u8 = undefined;
    for (symbols, 0..) |symbol, i| names[i] = symbol.name;
    break :blk names;
};

// Binds the shared reflection machinery to `libglowcap_host`. `special` names
// the two function-pointer typedefs the base type spelling has no case for.
const Spec = struct {
    pub const c = @import("c_abi_host");
    pub const emitted_fns: []const []const u8 = &emitted_fn_names;

    pub const const_docs = [_]struct { name: []const u8, doc: []const u8 }{
        .{ .name = "GLOWCAP_HOST_ACTION_DIAL", .doc = "GlowcapHostAction.kind: dial the exporter named by ticket (borrow the pending view with glowcap_host_pending_dial), then report glowcap_host_dialed / glowcap_host_dial_failed." },
        .{ .name = "GLOWCAP_HOST_ACTION_FLUSH", .doc = "GlowcapHostAction.kind: drain the session's transport-ready output until WOULD_BLOCK and write it." },
        .{ .name = "GLOWCAP_HOST_ACTION_NEED_GIFT_ID", .doc = "GlowcapHostAction.kind: draw 32 random bytes and feed them to glowcap_host_provide_gift_id with the ticket, or report failure through glowcap_host_gift_id_failed." },
        .{ .name = "GLOWCAP_HOST_ACTION_SETTLE", .doc = "GlowcapHostAction.kind: the vow named by ticket settled fulfilled with value; route the outcome to whatever awaits it." },
        .{ .name = "GLOWCAP_HOST_ACTION_FAIL", .doc = "GlowcapHostAction.kind: the vow named by ticket failed with result and message; route the outcome to whatever awaits it." },
        .{ .name = "GLOWCAP_HOST_ACTION_CLOSE", .doc = "GlowcapHostAction.kind: the host retired this session; write any queued terminal frame, close its transport, and release the session." },
        .{ .name = "GLOWCAP_HOST_ACTION_RESUME", .doc = "GlowcapHostAction.kind: the finite host scheduler yielded with internal work remaining; continue draining actions, with no session or I/O payload." },
        .{ .name = "GLOWCAP_HOST_ACTION_CANCEL_DIAL", .doc = "GlowcapHostAction.kind: interrupt and join the external dial named by ticket, then report glowcap_host_dial_cancelled." },
        .{ .name = "GLOWCAP_PENDING_CANCEL", .doc = "glowcap_host_close pending policy: seal admission, cancel admitted work, and begin terminal session shutdown." },
        .{ .name = "GLOWCAP_PENDING_FINISH", .doc = "glowcap_host_close pending policy: seal admission and keep driving admitted work before terminal session shutdown." },
        .{ .name = "GLOWCAP_CLOSE_OPTIONS_ABI_VERSION", .doc = "GlowcapCloseOptions.abi_version." },
        .{ .name = "GLOWCAP_CLOSE_MAX_GRACE_MS", .doc = "Largest finite GlowcapCloseOptions.grace_ms value." },
        .{ .name = "GLOWCAP_CLOSE_GRACE_UNSPECIFIED", .doc = "GlowcapCloseOptions.grace_mode: no grace argument was supplied." },
        .{ .name = "GLOWCAP_CLOSE_GRACE_FINITE", .doc = "GlowcapCloseOptions.grace_mode: grace_ms is a finite budget." },
        .{ .name = "GLOWCAP_CLOSE_GRACE_UNBOUNDED", .doc = "GlowcapCloseOptions.grace_mode: finish has no deadline." },
        .{ .name = "GLOWCAP_SESSION_LIMIT_OPTIONS_ABI_VERSION", .doc = "GlowcapSessionLimitOptions.abi_version." },
        .{ .name = "GLOWCAP_LIFECYCLE_ACTIVE", .doc = "The owner still admits application work." },
        .{ .name = "GLOWCAP_LIFECYCLE_FINISHING", .doc = "Admission is sealed while admitted work runs." },
        .{ .name = "GLOWCAP_LIFECYCLE_TERMINATING", .doc = "Terminal resource shutdown is in progress." },
        .{ .name = "GLOWCAP_LIFECYCLE_CLOSED", .doc = "The owner's execution state has reached its close barrier." },
        .{ .name = "GLOWCAP_DEFAULT_FRAME_CAP", .doc = "Default maximum admissible frame for glowcap_host_new / glowcap_host_new_in (bytes): mirrors session.SessionLimits.max_frame_bytes." },
        .{ .name = "GLOWCAP_MAX_LOCAL_FORWARD_HOPS", .doc = "Bound on one turn's synchronous local Forward chase (caretaker over attenuator). Hop N+1 breaks the answer instead of spinning." },
        .{ .name = "GLOWCAP_DISCOVERY_DIAL_RETRY_MS", .doc = "Discovery-posture dial retry interval in milliseconds, projected from the shared driver_core default." },
        .{ .name = "GLOWCAP_DISCOVERY_DIAL_MAX_ATTEMPTS", .doc = "Discovery-posture dial attempt budget, including the first attempt." },
        .{ .name = "GLOWCAP_DIAL_SHAPE_HOST_PORT", .doc = "GlowcapDialPlan.shape: open a TCP socket to host:port (tcp, keyed-tcp)." },
        .{ .name = "GLOWCAP_DIAL_SHAPE_PEER_ID", .doc = "GlowcapDialPlan.shape: peer-id open (node-id designator + addresses + reach, from the iroh locator scheme)." },
        .{ .name = "GLOWCAP_DIAL_SHAPE_SIGNALING", .doc = "GlowcapDialPlan.shape: signaling-mediated open (webrtc); no dialable address, the channel comes up through offer/answer/ICE (ADR-0035)." },
        .{ .name = "GLOWCAP_DIAL_SHAPE_RENDEZVOUS", .doc = "GlowcapDialPlan.shape: rendezvous-bridged open (keyed-relay); no dialable address, the dialer opens the relay rendezvous leg its host is configured for (ADR-0034)." },
        .{ .name = "GLOWCAP_DIAL_REACH_DIRECT", .doc = "GlowcapDialPlan.reach_kind (peer-id shape): the relay-less direct posture." },
        .{ .name = "GLOWCAP_DIAL_REACH_CONFIGURED", .doc = "GlowcapDialPlan.reach_kind (peer-id shape): the node's own configured redeem posture." },
        .{ .name = "GLOWCAP_DIAL_REACH_EXPLICIT", .doc = "GlowcapDialPlan.reach_kind (peer-id shape): the caller posture carried in reach_value." },
        .{ .name = "GLOWCAP_DIAL_POSTURE_REDEEM", .doc = "glowcap_host_plan_dial posture_policy: a redeem (a DIAL action): direct when a hint is present, else the node's configured posture." },
        .{ .name = "GLOWCAP_DIAL_POSTURE_EXPLICIT", .doc = "glowcap_host_plan_dial posture_policy: a connect carrying a posture in posture_value." },
        .{ .name = "GLOWCAP_DIAL_POSTURE_EXPLICIT_NONE", .doc = "glowcap_host_plan_dial posture_policy: a connect that named no posture; a peer-id dial refuses GLOWCAP_ERR_INVALID_ARGUMENT." },
        .{ .name = "GLOWCAP_DESIGNATOR_SCHEME_ADDRESS", .doc = "glowcap_host_session_open_accepted designator_scheme: the listener designator names a dialable address." },
        .{ .name = "GLOWCAP_DESIGNATOR_SCHEME_KEY", .doc = "glowcap_host_session_open_accepted designator_scheme: the listener designator names a peer key." },
        .{ .name = "GLOWCAP_LOCAL_TURN_BUDGET_DEFAULT", .doc = "glowcap_host_new local_turn_budget: the Host's finite default cap, the same one the Zig Host applies." },
        .{ .name = "GLOWCAP_LOCAL_TURN_BUDGET_UNBOUNDED", .doc = "glowcap_host_new local_turn_budget: no cap. Safe only when every partner is trusted." },
        .{ .name = "GLOWCAP_HOST_OUTBOUND_PREFIX_CAP", .doc = "Minimum out_prefix capacity for glowcap_host_session_take_outbound." },
        .{ .name = "GLOWCAP_HOST_DURABLE_ENTROPY_LEN", .doc = "Exact caller-supplied entropy length for glowcap_host_publish_durable." },
        .{ .name = "GLOWCAP_HOST_DURABLE_SWISS_LEN", .doc = "Required output capacity and written length for glowcap_host_publish_durable." },
        .{ .name = "GLOWCAP_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT", .doc = "GlowcapPartnerIdentity.provenance: a lower layer proved the partner holds the durable key it claims, and that key names the far end of the byte channel this session runs over, so the partner and the endpoint this session is encrypted to are one node." },
        .{ .name = "GLOWCAP_DURABLE_PROVENANCE_UNAUTHENTICATED", .doc = "GlowcapPartnerIdentity.provenance: nothing proved the name. A partner that claimed no durable identity at all lands here too, having no identity to have authenticated." },
    };

    pub fn special(comptime T: type) ?[]const u8 {
        if (T == c.GlowcapHostBehavior) return "GlowcapHostBehavior";
        if (T == c.GlowcapTraceCallback) return "GlowcapTraceCallback";
        if (T == c.GlowcapHostCtxFree) return "GlowcapHostCtxFree";
        if (T == c.GlowcapHostPumpArmFn) return "GlowcapHostPumpArmFn";
        return null;
    }
};
const E = header_emit.Emit(Spec);
const Buf = header_emit.Buf;
const emitDoc = header_emit.emitDoc;
const emitFn = E.emitFn;
const emitConst = E.emitConst;

// Coverage guard, both directions: every `pub export fn glowcap_host_*` in
// `c_abi_host` must be listed, and every listed name must be real.
comptime {
    E.guardFns("c_abi_host", "glowcap_host_");
    // Hold the action-kind #defines emitted below against the Zig source.
    std.debug.assert(Spec.c.GLOWCAP_HOST_ACTION_DIAL == 0);
    std.debug.assert(Spec.c.GLOWCAP_HOST_ACTION_FLUSH == 1);
    std.debug.assert(Spec.c.GLOWCAP_HOST_ACTION_NEED_GIFT_ID == 2);
    std.debug.assert(Spec.c.GLOWCAP_HOST_ACTION_SETTLE == 3);
    std.debug.assert(Spec.c.GLOWCAP_HOST_ACTION_FAIL == 4);
    std.debug.assert(Spec.c.GLOWCAP_HOST_ACTION_CLOSE == 5);
    std.debug.assert(Spec.c.GLOWCAP_HOST_ACTION_RESUME == 6);
    std.debug.assert(Spec.c.GLOWCAP_HOST_ACTION_CANCEL_DIAL == 7);
    std.debug.assert(Spec.c.GLOWCAP_PENDING_CANCEL == 0);
    std.debug.assert(Spec.c.GLOWCAP_PENDING_FINISH == 1);
    std.debug.assert(Spec.c.GLOWCAP_LIFECYCLE_ACTIVE == 0);
    std.debug.assert(Spec.c.GLOWCAP_LIFECYCLE_FINISHING == 1);
    std.debug.assert(Spec.c.GLOWCAP_LIFECYCLE_TERMINATING == 2);
    std.debug.assert(Spec.c.GLOWCAP_LIFECYCLE_CLOSED == 3);
    std.debug.assert(Spec.c.GLOWCAP_MAX_LOCAL_FORWARD_HOPS == 256);
    // Hold the dial/accept planning #defines emitted below against the source.
    std.debug.assert(Spec.c.GLOWCAP_DIAL_SHAPE_HOST_PORT == 0);
    std.debug.assert(Spec.c.GLOWCAP_DIAL_SHAPE_PEER_ID == 1);
    std.debug.assert(Spec.c.GLOWCAP_DIAL_SHAPE_SIGNALING == 2);
    std.debug.assert(Spec.c.GLOWCAP_DIAL_SHAPE_RENDEZVOUS == 3);
    std.debug.assert(Spec.c.GLOWCAP_DIAL_REACH_DIRECT == 0);
    std.debug.assert(Spec.c.GLOWCAP_DIAL_REACH_CONFIGURED == 1);
    std.debug.assert(Spec.c.GLOWCAP_DIAL_REACH_EXPLICIT == 2);
    std.debug.assert(Spec.c.GLOWCAP_DIAL_POSTURE_REDEEM == 0);
    std.debug.assert(Spec.c.GLOWCAP_DIAL_POSTURE_EXPLICIT == 1);
    std.debug.assert(Spec.c.GLOWCAP_DIAL_POSTURE_EXPLICIT_NONE == 2);
    std.debug.assert(Spec.c.GLOWCAP_DESIGNATOR_SCHEME_ADDRESS == 0);
    std.debug.assert(Spec.c.GLOWCAP_DESIGNATOR_SCHEME_KEY == 1);
    std.debug.assert(Spec.c.GLOWCAP_HOST_OUTBOUND_PREFIX_CAP == 32);
    std.debug.assert(Spec.c.GLOWCAP_HOST_DURABLE_ENTROPY_LEN == 16);
    std.debug.assert(Spec.c.GLOWCAP_HOST_DURABLE_SWISS_LEN == 50);
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
        \\   (libglowcap_host) from libglowcap_ocapn (ADR-0022). It is a
        \\   companion, not a superset: it exports only the glowcap_host_* family and
        \\   shares the value vocabulary (GlowcapFrame, GlowcapManagedFrame,
        \\   GlowcapContext, GlowcapArgument, GlowcapReference, GlowcapLastAbort) and
        \\   the return codes by layout with glowcap_ocapn.h (included below), so a
        \\   consumer links BOTH archives and includes BOTH headers. The family has
        \\   its own last-error slot, read through glowcap_host_last_error rather
        \\   than glowcap_ocapn's glowcap_last_error. */
        \\#ifndef GLOWCAP_HOST_H
        \\#define GLOWCAP_HOST_H
        \\
        \\#include <stddef.h>
        \\#include <stdint.h>
        \\#include "glowcap_ocapn.h"
        \\
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\
    );

    try emitDoc(&b, gpa,
        \\A GlowcapHost is the multi-session CapTP host for an embedder that
        \\owns its own loop, sockets, and entropy (ADR-0022). The library owns every
        \\decision (routing, three-party redeem, gift origination). The embedder
        \\moves transport packets: feed inbound packets with glowcap_host_session_feed_packet,
        \\write what glowcap_host_session_take_packet drains, and honor the action queue.
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
        \\THE ONE LOOP RULE. After any top-level glowcap_host_* call returns OK,
        \\drain glowcap_host_next_action until GLOWCAP_ERR_WOULD_BLOCK, honoring each
        \\action. DIAL: borrow the pending view with
        \\glowcap_host_pending_dial(ticket, route_index), open your own channel from it,
        \\mint the session from the same view
        \\(glowcap_host_session_open_dialed_locator), drive
        \\its session open, then report glowcap_host_dialed (or
        \\glowcap_host_dial_failed); FLUSH: drain
        \\that session's transport output until WOULD_BLOCK and write it;
        \\NEED_GIFT_ID: draw 32 random bytes and call glowcap_host_provide_gift_id,
        \\or call glowcap_host_gift_id_failed when entropy cannot be provided;
        \\SETTLE / FAIL: route the outcome to whatever awaits the vow the action's
        \\ticket names. Nothing in the library enforces the drain. Honoring it is
        \\the embedder's side of the contract, and an ignored action strands the
        \\dial, flush, handoff, or settlement it carries.
        \\
        \\THREADING AND REENTRANCY. One thread (or one green-thread scheduler)
        \\drives one host; nothing locks. The one callback (a behavior answering
        \\a deliver) fires on the thread executing the enclosing glowcap_host_*
        \\call. Inside it the enqueueing verbs are legal (among them
        \\session_send/session_tell, session_listen, session_resolve,
        \\vow_send/vow_index/vow_untag/vow_get, the turn verbs (with the callback's own turn),
        \\ref_release, session_set_exporter_location, session_is_open, the error
        \\readers) and their effects encode and pump when the enclosing call
        \\unwinds. The host-driving verbs (among them feed, take_outbound,
        \\next_action, pump_drain, the dial reports, open_*, publish/spawn,
        \\fetch/enliven, close and release) are refused there with
        \\GLOWCAP_ERR_INVALID_ARGUMENT. A verb reaching the host from a thread
        \\other than the one driving it is refused the same way before it touches
        \\host state, with glowcap_host_last_error naming WrongThread; two calls
        \\racing each other are still a data race.
    );

    try b.appendSlice(gpa,
        \\
        \\/* A byte-fed multi-session CapTP host: one identity, one routing and
        \\   redeem authority, many sessions. Created by glowcap_host_new /
        \\   glowcap_host_new_in; released by glowcap_host_release, always after its
        \\   sessions. */
        \\typedef struct GlowcapHost GlowcapHost;
        \\
        \\/* One byte-fed CapTP session a host minted. Released by
        \\   glowcap_host_session_release, always before the host. */
        \\typedef struct GlowcapHostSession GlowcapHostSession;
        \\
        \\/* The current turn, passed to a behavior callback so it can forward and
        \\   eventual-send while handling a deliver (glowcap_host_turn_*). Valid only
        \\   for the duration of that callback: stashing the pointer and using it
        \\   after the callback returns is undefined behavior. */
        \\typedef struct GlowcapHostTurn GlowcapHostTurn;
        \\
        \\/* A hosted object's behavior, invoked on each deliver. verb/args are
        \\   borrowed for the call; each GlowcapReference leaf is nevertheless
        \\   one application retain and must eventually be returned with
        \\   glowcap_host_ref_release. Copying its { id } bytes does not create
        \\   another retain. The vat copies *out_reply's payload the
        \\   instant you return, so its bytes must stay valid across the return
        \\   (point them at your ctx or a buffer you own, not a callback stack
        \\   local). Any non-OK return settles the answer broken
        \\   with a generic reason. */
        \\typedef int32_t (*GlowcapHostBehavior)(void *ctx, GlowcapHostTurn *turn,
        \\    const uint8_t *verb, size_t verb_len, const GlowcapArgument *args,
        \\    size_t args_len, GlowcapArgument *out_reply);
        \\
        \\/* Release a hosted object's ctx when the object is torn down. NULL to keep
        \\   ctx. Runs exactly once per registration that took ownership; must call
        \\   no glowcap_host_* function. */
        \\typedef void (*GlowcapHostCtxFree)(void *ctx);
        \\
    );

    try emitConst(&b, gpa, "GLOWCAP_TRACE_SESSION_OPEN");
    try emitConst(&b, gpa, "GLOWCAP_TRACE_MESSAGE");
    try emitConst(&b, gpa, "GLOWCAP_TRACE_SESSION_CLOSE");
    try emitConst(&b, gpa, "GLOWCAP_TRACE_DIGEST_BYTES");
    try b.appendSlice(gpa, "\n");
    try emitDoc(&b, gpa,
        \\One live-trace fact (glowcap_host_set_trace). kind selects the live
        \\fields; string views are borrowed for the callback only. SESSION_OPEN
        \\carries session, partner, verified, and the negotiated GLOWCAP_CODEC_*,
        \\using GLOWCAP_CODEC_UNKNOWN only when this C ABI cannot name it;
        \\MESSAGE carries session, outbound, and the deliver's verb;
        \\SESSION_CLOSE carries session. Unused fields are zeroed.
    );
    try E.emitStruct(&b, gpa, Spec.c.GlowcapTraceEvent, "GlowcapTraceEvent", &.{
        "A GLOWCAP_TRACE_* value.",
        "The session the fact is about, stable for the session's life.",
        "MESSAGE: nonzero when the message left this host.",
        "SESSION_OPEN: whether the realized channel proved the partner's durable name, as a GLOWCAP_DURABLE_PROVENANCE_* value.",
        "SESSION_OPEN: the negotiated GLOWCAP_CODEC_*, or GLOWCAP_CODEC_UNKNOWN when this C ABI cannot name it.",
        "SESSION_OPEN: the negotiated GLOWCAP_CAPTP_* profile.",
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
        "MESSAGE: how long the frame really was; equal to frame_len on the callback path, larger when a queued record clipped it to its payload window.",
        "Records the host dropped between the previous record and this one; always zero on the callback path.",
        "MESSAGE: a tag over the frame's bytes, naming this one message across the two peers that carried it, so a consumer merging two observers of one session folds their sightings into one. Zero on the other kinds.",
    });
    try b.appendSlice(gpa,
        \\/* The trace callback: called synchronously at the fact site, on the host's
        \\   one thread, with event and its views borrowed for the call. Must call no
        \\   host-driving verb; stamp, copy, and return. */
        \\typedef void (*GlowcapTraceCallback)(void *ctx, const GlowcapTraceEvent *event);
        \\
        \\
    );

    try emitConst(&b, gpa, "GLOWCAP_HOST_ACTION_DIAL");
    try emitConst(&b, gpa, "GLOWCAP_HOST_ACTION_FLUSH");
    try emitConst(&b, gpa, "GLOWCAP_HOST_ACTION_NEED_GIFT_ID");
    try emitConst(&b, gpa, "GLOWCAP_HOST_ACTION_SETTLE");
    try emitConst(&b, gpa, "GLOWCAP_HOST_ACTION_FAIL");
    try emitConst(&b, gpa, "GLOWCAP_HOST_ACTION_CLOSE");
    try emitConst(&b, gpa, "GLOWCAP_HOST_ACTION_RESUME");
    try emitConst(&b, gpa, "GLOWCAP_HOST_ACTION_CANCEL_DIAL");
    try emitConst(&b, gpa, "GLOWCAP_PENDING_CANCEL");
    try emitConst(&b, gpa, "GLOWCAP_PENDING_FINISH");
    try emitConst(&b, gpa, "GLOWCAP_CLOSE_OPTIONS_ABI_VERSION");
    try emitConst(&b, gpa, "GLOWCAP_CLOSE_MAX_GRACE_MS");
    try emitConst(&b, gpa, "GLOWCAP_CLOSE_GRACE_UNSPECIFIED");
    try emitConst(&b, gpa, "GLOWCAP_CLOSE_GRACE_FINITE");
    try emitConst(&b, gpa, "GLOWCAP_CLOSE_GRACE_UNBOUNDED");
    try emitConst(&b, gpa, "GLOWCAP_SESSION_LIMIT_OPTIONS_ABI_VERSION");
    try emitConst(&b, gpa, "GLOWCAP_LIFECYCLE_ACTIVE");
    try emitConst(&b, gpa, "GLOWCAP_LIFECYCLE_FINISHING");
    try emitConst(&b, gpa, "GLOWCAP_LIFECYCLE_TERMINATING");
    try emitConst(&b, gpa, "GLOWCAP_LIFECYCLE_CLOSED");
    try emitConst(&b, gpa, "GLOWCAP_DEFAULT_FRAME_CAP");
    try emitConst(&b, gpa, "GLOWCAP_MAX_LOCAL_FORWARD_HOPS");
    try emitConst(&b, gpa, "GLOWCAP_DISCOVERY_DIAL_RETRY_MS");
    try emitConst(&b, gpa, "GLOWCAP_DISCOVERY_DIAL_MAX_ATTEMPTS");
    try emitConst(&b, gpa, "GLOWCAP_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT");
    try emitConst(&b, gpa, "GLOWCAP_DURABLE_PROVENANCE_UNAUTHENTICATED");
    try b.appendSlice(gpa, "\n");
    try E.emitStruct(&b, gpa, Spec.c.GlowcapCloseOptions, "GlowcapCloseOptions", &.{
        "GLOWCAP_CLOSE_OPTIONS_ABI_VERSION.",
        "sizeof(GlowcapCloseOptions).",
        "GLOWCAP_PENDING_CANCEL or GLOWCAP_PENDING_FINISH.",
        "GLOWCAP_CLOSE_GRACE_*; CANCEL requires UNSPECIFIED.",
        "Finite finish grace in milliseconds; CANCEL requires zero.",
    });
    try b.appendSlice(gpa, "\n");
    try E.emitStruct(&b, gpa, Spec.c.GlowcapSessionLimitOptions, "GlowcapSessionLimitOptions", &.{
        "GLOWCAP_SESSION_LIMIT_OPTIONS_ABI_VERSION.",
        "sizeof(GlowcapSessionLimitOptions).",
        "Maximum inbound frame bytes; zero leaves the current value unchanged.",
        "Maximum queued calls per pending answer; zero leaves the current value unchanged.",
        "Transient outbound byte waterline; zero leaves the current value unchanged.",
        "Durable sent-answer bytes retained after transient flow accounting; zero leaves the current value unchanged and values above UINT32_MAX are refused.",
        "Host-wide cap on live sessions; zero leaves the current value unchanged.",
    });
    try b.appendSlice(gpa, "\n");
    try emitDoc(&b, gpa,
        \\One embedder effect popped from glowcap_host_next_action. kind selects the
        \\live fields: DIAL carries ticket and route_index (borrow the pending view with
        \\glowcap_host_pending_dial). DIAL and CANCEL_DIAL also carry route_index.
        \\FLUSH and CLOSE carry session;
        \\NEED_GIFT_ID carries ticket. SETTLE carries the settled vow id in ticket
        \\and the fulfilled value in value; FAIL carries the vow id in ticket and
        \\the typed failure code in result and the reason in message/message_len.
        \\RESUME carries no payload and
        \\means the finite host scheduler yielded with internal work remaining.
        \\Every popped byte view and
        \\value's sub-structure are host-owned and valid until the NEXT
        \\glowcap_host_next_action call, which frees them. Unused fields are zeroed.
    );
    try E.emitStruct(&b, gpa, Spec.c.GlowcapHostAction, "GlowcapHostAction", &.{
        "A GLOWCAP_HOST_ACTION_* value.",
        "DIAL: the report-back handle; SETTLE/FAIL: the vow that settled.",
        "DIAL/CANCEL_DIAL: the concrete route within ticket's logical dial; zero otherwise.",
        "FLUSH/CLOSE: the session to drain or condemn; NULL otherwise.",
        "SETTLE: the fulfilled value; zeroed otherwise.",
        "FAIL: the break reason; NULL otherwise.",
        "",
        "CLOSE: GLOWCAP_OK or GLOWCAP_ERR_TIMEOUT. FAIL: GLOWCAP_ERR_BROKEN or GLOWCAP_ERR_CLOSED; zero otherwise.",
    });
    try b.appendSlice(gpa, "\n");
    try emitDoc(&b, gpa,
        \\One shared arm callback for GlowcapHostPumpHooks (flush, close,
        \\need_gift_id, complete for SETTLE/FAIL, dial). Return GLOWCAP_OK or a
        \\real GLOWCAP_ERR_*. When out_progressed is non-NULL, set it to 1 if the
        \\arm counts as quiescence progress; leave 0 for a handled notice a
        \\sibling shuttle already covers. action views are host-owned until the
        \\next glowcap_host_next_action (glowcap_host_pump_drain pops internally).
    );
    try b.appendSlice(gpa,
        \\typedef int32_t (*GlowcapHostPumpArmFn)(void *ctx, GlowcapHost *host,
        \\    const GlowcapHostAction *action, uint32_t *out_progressed);
        \\
    );
    try emitDoc(&b, gpa,
        \\Opt-in embedder hooks for glowcap_host_pump_drain (ADR-0022).
        \\NULL arm pointers skip that kind (no error, no progress).
        \\The pull-queue remains normative. This is a convenience wrapper's
        \\callback surface, not a replacement for glowcap_host_next_action.
    );
    try E.emitStruct(&b, gpa, Spec.c.GlowcapHostPumpHooks, "GlowcapHostPumpHooks", &.{
        "Caller context passed to every arm.",
        "FLUSH arm, or NULL to skip.",
        "CLOSE arm, or NULL to skip.",
        "NEED_GIFT_ID arm, or NULL to skip.",
        "SETTLE and FAIL arm, or NULL to skip.",
        "DIAL arm, or NULL to skip.",
    });
    try b.appendSlice(gpa, "\n");

    try emitFn(&b, gpa, "glowcap_host_archive_fingerprint", &.{}, "Read the exact reflected callable and layout identity of this Host archive.");
    try emitFn(&b, gpa, "glowcap_host_new", &.{ "seed", "seed_len", "frame_cap", "verify_partner", "codec", "captp_version", "features", "local_turn_budget", "release_on_drop", "out_host" }, "Create a byte-fed host bound to a caller-drawn 64-byte seed buffer (the host\nnever draws entropy), allocating through the library allocator.\n\nseed_len must be 64. The first 32 bytes are the durable identity and must\nstay stable across restarts, because a keyed locator's designator derives\nfrom them. The next 32 are the session-key root, and they must be FRESH PER\nPROCESS: they are what makes each CapTP session sign with its own key, so an\nold handoff certificate cannot resolve against a session opened after a\nrestart. A durable-only 32-byte seed is refused. CapTP session keys must not\nsilently reuse the identity seed (ADR-0028).\n\nframe_cap sizes every session's maximum admissible frame; a\nnonzero verify_partner keeps partner-signature verification on (the secure\ndefault); codec is GLOWCAP_CODEC_SYRUP or GLOWCAP_CODEC_CAPNP.\nGLOWCAP_CODEC_UNKNOWN is an output sentinel and is refused here.\ncaptp_version is the GLOWCAP_CAPTP_* profile this host prefers, and features is\nthe GLOWCAP_FEATURE_* bitmask this host offers. The signed hello carries those\npreferences as locator hints; each session settles version and codec with its\npartner, falling back to v1.0/Syrup when needed, and runs only the intersection\nof the two offered feature sets. An absent feature hint means the baseline set,\nwhich excludes GLOWCAP_FEATURE_UNTAG because Goblins does not implement it.\nGLOWCAP_CAPTP_V1_0 with GLOWCAP_CODEC_SYRUP remains the interop floor; callers\nmay pass GLOWCAP_FEATURE_FULL on that same wire version, and the hello and\nsettled session use only the v1.0-eligible subset.\nlocal_turn_budget caps local-turn amplification per session (ADR-0018):\nGLOWCAP_LOCAL_TURN_BUDGET_DEFAULT applies the Zig Host's finite default,\nGLOWCAP_LOCAL_TURN_BUDGET_UNBOUNDED turns the cap off, and any other value\nis the cap.\nrelease_on_drop is the Host-wide setting a binding reads when it projects a\nfar capability (ADR-0025): nonzero means the capability releases its Host\nretain when the language's scope end for it is observed. A binding whose\nrelease rides a finalizer passes 0 and keeps its per-session opt-in. Read it\nwith glowcap_host_release_on_drop and change it with\nglowcap_host_set_release_on_drop. The Host attaches no behavior to it.\n*out_host receives the handle; release with glowcap_host_release.");
    try emitFn(&b, gpa, "glowcap_host_new_in", &.{ "context", "seed", "seed_len", "frame_cap", "verify_partner", "codec", "captp_version", "features", "local_turn_budget", "release_on_drop", "out_host" }, "glowcap_host_new allocating every byte the host owns through context's host\nallocator (glowcap_context_new_with_allocator).");
    try emitFn(&b, gpa, "glowcap_host_release_on_drop", &.{ "host", "out_enabled" }, "Read the Host-wide release-on-drop setting (ADR-0025) into *out_enabled as 0 or 1.");
    try emitFn(&b, gpa, "glowcap_host_set_release_on_drop", &.{ "host", "enabled" }, "Set the Host-wide release-on-drop setting (ADR-0025) for capabilities the\nHost projects after this call: nonzero turns it on. A binding whose release\nrides a finalizer leaves it off and keeps its per-session opt-in.");
    try emitFn(&b, gpa, "glowcap_host_diagnostic_id", &.{ "host", "out_id" }, "Return the Host's stable identity in its owning Context's diagnostic namespace. The context-less convenience constructor reports zero because it has no Context diagnostic namespace to allocate from.");
    try emitFn(&b, gpa, "glowcap_host_close", &.{ "host", "options", "now_ms" }, "Seal application admission and begin or escalate terminal Host close. now_ms is\na reading from the embedder's monotonic millisecond clock. FINISH keeps\nalready-admitted work running under its finite or explicitly unbounded grace.\nRepeated calls share the first deadline: CANCEL may escalate FINISH and FINISH\nnever weakens or restarts an existing barrier. This closes without releasing\nthe Host handle.");
    try emitFn(&b, gpa, "glowcap_host_close_progress", &.{ "host", "now_ms", "out_state" }, "Apply the current monotonic clock reading to a started close and write its\nGLOWCAP_LIFECYCLE_* state. Expired FINISH escalates through the shared CANCEL\npath. After teardown reaches CLOSED, a finite grace expiry returns\nGLOWCAP_ERR_TIMEOUT together with CLOSED.");
    try emitFn(&b, gpa, "glowcap_host_close_wait_ms", &.{ "host", "now_ms", "out_wait_ms" }, "The longest a close driver may wait for new input before calling\nglowcap_host_close_progress again: milliseconds until the nearest FINISH grace\ndeadline (the Host's own or any session's), clamped at zero. Writes -1 when no\nfinite deadline is pending; only feed, action-drain, settle, or escalation\nactivity can then advance terminal progress, so the embedder may park on\nactivity alone. The value drops straight into a wait primitive's timeout\nargument.");
    try emitFn(&b, gpa, "glowcap_host_lifecycle_state", &.{ "host", "out_state" }, "Observe the current GLOWCAP_LIFECYCLE_* state without advancing time. The\nordinary byte-feed and action-drain cycle advances terminal work; call\nglowcap_host_close_progress when the embedder clock advances. CLOSED means every\nsession and queued Host effect has retired. A prior finite grace expiry returns\nGLOWCAP_ERR_TIMEOUT together with CLOSED.");
    try emitFn(&b, gpa, "glowcap_host_release", &.{"host"}, "Release the host and everything it owns: every still-open session (each\nstill-parked vow breaks inside this call, its undrained completion freed\nwith the rest of the action queue), the vow map, parked actions, the node,\nand the publication rows (each publication's free runs exactly once here). NULL is\na no-op. Session (GlowcapHostSession) handles this host minted are freed with it.\nNever touch one after its host is gone. Because release is terminal, an embedder\nmay transfer exclusive ownership to a finalizer thread after every Host call has\nreturned; no live Host verb gains cross-thread permission. Refusal from inside a\ncallback sets last error and leaves the handle live. A teardown failure also sets\nlast error but consumes the handle after completing the ownership sweep.");
    try emitFn(&b, gpa, "glowcap_host_designator_from_seed", &.{ "seed", "seed_len", "out", "out_len" }, "Derive the canonical key designator (exactly 64 lowercase hex digits) from a\n32-byte Ed25519 durable identity seed, the public half of the first half of\nthe 64-byte buffer glowcap_host_new takes. CapTP session signing keys come\nfrom the second half (ADR-0028), not from this designator seed. Writes 64\nbytes into out (out_len must be at least 64). Used by a keyed-tcp listener\nwhose locator designator is this durable identity (ADR-0028).");
    try emitFn(&b, gpa, "glowcap_host_set_advertised_locator", &.{ "host", "locator" }, "Retain and select this host's complete acceptable location. The Host validates and deep-copies the borrowed locator view. Later dialed and accepted sessions sign this selection regardless of the transport carrying them.");
    try emitFn(&b, gpa, "glowcap_host_ensure_advertised_locator", &.{ "host", "transport", "transport_len" }, "Retain a dial fallback for transport unless one already exists. It becomes the\nacceptable location only when the Host has no selection; it never displaces a\nroute selected for another transport. Key-designator transports use this Host's\npublic key; address transports use the unreachable-client placeholder. A\nreachable adapter must publish its complete locator explicitly.");
    try emitFn(&b, gpa, "glowcap_host_remove_advertised_locator", &.{ "host", "transport", "transport_len" }, "Remove the retained locator for transport. Removing the selected route leaves\nno acceptable location until one is set or ensured; another retained route is\nnever chosen implicitly. Existing sessions retain the signed hello snapshot\nthey already sent.");
    try emitFn(&b, gpa, "glowcap_host_set_session_limits", &.{ "host", "options" }, "Apply versioned selective session-limit overrides before minting sessions.\nZero fields leave the current value unchanged. Already-open peers keep the\nlimits they were minted with. `options` is borrowed and must not be NULL.");
    try emitFn(&b, gpa, "glowcap_host_set_ingress_limits", &.{ "host", "max_pending_turns", "max_pending_bytes", "max_chunk_bytes" }, "Configure independent per-ingress queue bounds before any session or\neventual send. Bytes include spines and queue rows. All limits are positive;\na complete queue chunk must fit the aggregate byte allowance. No eager\npayload allocation occurs. Later reconfiguration is refused.");
    try emitFn(&b, gpa, "glowcap_host_session_open_dialed_locator", &.{ "host", "locator", "out_session" }, "Mint the dialing half after an embedder has opened the byte channel for\nlocator. The one locator vocabulary is taken whole: the designator keys\nduplicate-dial refusal and, on a key transport, demands the partner's durable\nkey; route hints carry no semantics here because the caller's dial executor\nspent them realizing the channel. A DIAL action identifies one admitted\n(ticket, route_index) attempt: project its typed locator with\nglowcap_host_pending_dial, open the channel it names, and report that exact\nattempt. The host retains its own dial default for the locator's transport\nfirst, never displacing an advertised locator the embedder explicitly selected,\nso a bare client host dials without publishing anything. A sealed session\nderives its Noise ephemeral from the Host's unique per-session seed under a\nseparate KDF domain, so callers do not branch on transport policy or supply\nper-open entropy. The keyed op:start-session is signed under the host identity\nand encoded before this returns, so drain take_outbound (a FLUSH action is\nqueued) and drive the handshake byte-fed. Host-wide aliases remain lazily\ndiscoverable through the new session. *out_session is host-owned; release with\nglowcap_host_session_release.");
    try emitFn(&b, gpa, "glowcap_host_session_open_accepted", &.{ "host", "transport", "transport_len", "designator_scheme", "server_designator", "server_designator_len", "accepted_local_addr", "accepted_local_addr_len", "out_session" }, "Mint the accepting half of a connection your listener produced.\ndesignator_scheme is the provider's GLOWCAP_DESIGNATOR_SCHEME_* declaration;\nserver_designator is the listener's own signing designator (its key for a key\ntransport, unused for an address transport); accepted_local_addr is the route\nthe accept reported (NULL/0 when unavailable). The host retains the locator\nthis accept would sign without displacing an acceptable location the embedder\nalready selected: an explicit glowcap_host_set_advertised_locator is deployment\npolicy and wins, and the accept-derived locator becomes the selection only when\nthere is none. The session signs the selected snapshot even when it names\nanother transport. Sealed-channel entropy follows the dialed half's Host-owned\nderivation. Host-wide aliases remain lazily discoverable, with the same flush\nand release contract as the dialed half.");
    try b.appendSlice(gpa, "\n");
    try emitConst(&b, gpa, "GLOWCAP_DIAL_SHAPE_HOST_PORT");
    try emitConst(&b, gpa, "GLOWCAP_DIAL_SHAPE_PEER_ID");
    try emitConst(&b, gpa, "GLOWCAP_DIAL_SHAPE_SIGNALING");
    try emitConst(&b, gpa, "GLOWCAP_DIAL_SHAPE_RENDEZVOUS");
    try emitConst(&b, gpa, "GLOWCAP_DIAL_REACH_DIRECT");
    try emitConst(&b, gpa, "GLOWCAP_DIAL_REACH_CONFIGURED");
    try emitConst(&b, gpa, "GLOWCAP_DIAL_REACH_EXPLICIT");
    try emitConst(&b, gpa, "GLOWCAP_DIAL_POSTURE_REDEEM");
    try emitConst(&b, gpa, "GLOWCAP_DIAL_POSTURE_EXPLICIT");
    try emitConst(&b, gpa, "GLOWCAP_DIAL_POSTURE_EXPLICIT_NONE");
    try emitConst(&b, gpa, "GLOWCAP_DESIGNATOR_SCHEME_ADDRESS");
    try emitConst(&b, gpa, "GLOWCAP_DESIGNATOR_SCHEME_KEY");
    try emitConst(&b, gpa, "GLOWCAP_LOCAL_TURN_BUDGET_DEFAULT");
    try emitConst(&b, gpa, "GLOWCAP_LOCAL_TURN_BUDGET_UNBOUNDED");
    try emitConst(&b, gpa, "GLOWCAP_HOST_OUTBOUND_PREFIX_CAP");
    try emitConst(&b, gpa, "GLOWCAP_HOST_DURABLE_ENTROPY_LEN");
    try emitConst(&b, gpa, "GLOWCAP_HOST_DURABLE_SWISS_LEN");
    try b.appendSlice(gpa, "\n");
    try emitDoc(&b, gpa,
        \\A resolved dial from glowcap_host_plan_dial: what byte channel to open and
        \\how. shape (GLOWCAP_DIAL_SHAPE_*) selects the live fields: HOST_PORT fills
        \\host/host_len/port, PEER_ID fills addresses/addresses_len and the reachability.
        \\Every view borrows the transport/designator/hint the caller passed in, so
        \\the plan is valid only while those buffers are.
    );
    try E.emitStruct(&b, gpa, Spec.c.GlowcapDialPlan, "GlowcapDialPlan", &.{
        "A GLOWCAP_DIAL_SHAPE_* value.",
        "HOST_PORT: the resolved TCP host (borrows the designator or hint).",
        "",
        "HOST_PORT: the resolved TCP port.",
        "PEER_ID: the direct-addresses to dial (borrows the hint verbatim).",
        "",
        "PEER_ID: a GLOWCAP_DIAL_REACH_* value.",
        "PEER_ID: the caller posture when reach_kind is GLOWCAP_DIAL_REACH_EXPLICIT.",
    });
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "glowcap_host_pending_dial", &.{ "host", "ticket", "route_index", "hint_storage", "hint_capacity", "out_locator", "out_hint_count" }, "Project one concrete in-flight route for ticket into out_locator, using the\ncaller-owned hint_storage array. route_index comes from the DIAL action and is\npart of its report-back authority. On GLOWCAP_OK, *out_hint_count is the number\nof initialized hints and the locator plus all nested byte views remain\nHost-owned until glowcap_host_dialed / glowcap_host_dial_failed consumes that\nattempt (or Host teardown); hint_storage remains caller-owned. A null\nhint_storage with hint_capacity 0 is the size probe: when hints exist the call\nreturns GLOWCAP_ERR_BUFFER_TOO_SMALL, writes the exact required capacity to\n*out_hint_count, and leaves *out_locator untouched. The locator was parsed and\nretained once when the give was accepted; no URI is reparsed and no hint is\ndiscarded. Unknown or stale attempts return GLOWCAP_ERR_INVALID_ARGUMENT.");
    try emitFn(&b, gpa, "glowcap_host_pending_dial_introducer", &.{ "host", "ticket", "route_index", "out_session" }, "Borrow the live session that supplied the oldest remaining give for this\npending dial, or write NULL when no live introducer remains (including a\npurely application-owned dial). Unknown or stale attempts return\nGLOWCAP_ERR_INVALID_ARGUMENT and leave the output untouched. A deduplicated\ndial may have several introducing sessions; this projects one source, not\nauthority over the others. Bindings capture it before starting the route effect\nto select application-owned signaling context without a global capture window.\nThe borrowed handle lives with that session; do not release it here. Waiter\nretirement can change a later observation; this call retains no session and\nmints no capability.");
    try emitFn(&b, gpa, "glowcap_host_reference_exporter", &.{ "host", "reference", "out_session" }, "Write the live session homing remote reference into *out_session, or NULL for\na local, stale, foreign-Host, or closed-session capability. Bindings compare\nthis result with the sending session after a call: the same session is an\nordinary reply, while another session is the exporter reached through handoff.\nThe answer comes from the reference's own Host row, with no dial-completion\ncapture window. The returned handle is Host-owned and lives with that session;\ndo not release it here.");
    try emitFn(&b, gpa, "glowcap_host_plan_dial", &.{ "transport", "transport_len", "designator", "designator_len", "direct_addresses_hint", "direct_addresses_hint_len", "posture_policy", "posture_value", "out_plan" }, "Resolve a dial without opening a socket: the transport dispatch, designator\nvalidation, host:port resolution, and peer-id reachability decision, made once here\nfor every binding. transport/designator are the locator's\npieces (from glowcap_host_pending_dial or glowcap_uri_parse_peer);\ndirect_addresses_hint is the locator's direct-addresses hint (NULL/0 = none);\nposture_policy is a GLOWCAP_DIAL_POSTURE_* choosing the peer-id reachability rule,\nwith posture_value the caller's posture under GLOWCAP_DIAL_POSTURE_EXPLICIT.\nOn GLOWCAP_OK *out_plan is filled with views borrowing the caller's buffers; a\nbad locator returns GLOWCAP_ERR_INVALID_ARGUMENT (glowcap_host_last_error\ncarries which). Open the channel the plan names, then pass the same\nlocator view to glowcap_host_session_open_dialed_locator.");
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "glowcap_host_session_close", &.{ "session", "options", "now_ms" }, "Seal one byte-fed session's application admission and begin or escalate its\nterminal close. now_ms is the embedder's monotonic millisecond reading. The\nshared controller retains the first FINISH deadline while the embedder keeps\nfeeding bytes and draining actions. This closes without releasing the handle.");
    try emitFn(&b, gpa, "glowcap_host_session_close_progress", &.{ "session", "now_ms", "out_state" }, "Apply the current monotonic clock reading to one started session close and write\nits GLOWCAP_LIFECYCLE_* phase. Expired FINISH escalates through CANCEL. CLOSED\nmeans the terminal transport action crossed its retryable delivery boundary; a\ntimed-out close returns GLOWCAP_ERR_TIMEOUT together with CLOSED.");
    try emitFn(&b, gpa, "glowcap_host_session_lifecycle_state", &.{ "session", "out_state" }, "Observe one session's GLOWCAP_LIFECYCLE_* phase without advancing time. CLOSED\nmeans the terminal transport action crossed its retryable delivery boundary while\nthe retained shell remains valid for explicit release. A prior finite grace expiry\nreturns GLOWCAP_ERR_TIMEOUT together with CLOSED.");
    try emitFn(&b, gpa, "glowcap_host_session_release", &.{"session"}, "Release one session: its still-parked far vows break (their FAIL\ncompletions queue inside this call), the node retires it (stranded\nwithdraws fail closed, so SIBLING sessions' vows may break here too), and\nthe shell is freed. NULL is a no-op; refused (last error set, the session\nkept) from inside a callback.");
    try emitFn(&b, gpa, "glowcap_host_session_is_open", &.{"session"}, "Nonzero once the keyed handshake has completed and the session is open.");
    try emitFn(&b, gpa, "glowcap_host_session_profile", &.{ "session", "out_captp_version", "out_codec", "out_features" }, "Read the complete profile this session settled with its partner into the three required GLOWCAP_CAPTP_*, GLOWCAP_CODEC_*, and GLOWCAP_FEATURE_* outputs. Before the keyed handshake opens this returns GLOWCAP_ERR_WOULD_BLOCK; after the CapTP session becomes terminal it returns GLOWCAP_ERR_CLOSED. Failure leaves all outputs untouched.");
    try emitFn(&b, gpa, "glowcap_host_session_transport_name", &.{ "session", "out_name", "out_name_len" }, "Borrow the exact netlayer symbol this session was opened through. Both outputs are required and remain valid until session release. This is local connection metadata, not the partner's signed locator claim.");
    try emitFn(&b, gpa, "glowcap_host_session_trace_id", &.{ "session", "out_id" }, "The id the live trace names this session's rows by (GlowcapTraceEvent's session), so an embedder can annotate the same session a trace consumer is watching. Stable for the session's life and never reused by this host.");

    try emitFn(&b, gpa, "glowcap_host_session_feed", &.{ "session", "frame_in" }, "Feed one inbound frame you read from your own transport (borrowed for the\ncall): behavior callbacks fire and vow completions queue inside, then the\nnode actions the dispatch queued pump and every touched session's outbound\nencodes. GLOWCAP_ERR_WOULD_BLOCK is the preflight high-water refusal: the frame\nwas not consumed, so drain actions / outbound frames and retry it. Other\nfailures classify through GLOWCAP_ERR_CODEC / _SESSION / _INTERNAL. When\nglowcap_host_session_last_abort succeeds, the frame was consumed and the\nsession is closing; drain its typed op:abort and release it. GLOWCAP_ERR_INTERNAL\nwith no last-abort is allocation failure before frame admission, so the same\nborrowed frame remains retryable.");
    try emitFn(&b, gpa, "glowcap_host_session_feed_bytes", &.{ "session", "bytes", "len" }, "Feed a byte-stream chunk you read from your own transport (borrowed for the\ncall). The library owns outer framing and the tail: each bare codec frame is\none canonical Syrup byte string (decimal length, colon, body). Split prefixes\nand bodies stay buffered in the session; coalesced byte strings dispatch in\norder, each body exactly as glowcap_host_session_feed. Dispatch pauses at the\nframe that completes the keyed handshake: frames coalesced behind the hello\nwait in the session's tail while you act on the fresh session (publish, fetch),\nand glowcap_host_session_resume_feed feeds them once that post-open authority\nis installed. GLOWCAP_ERR_WOULD_BLOCK is the preflight high-water refusal and\nconsumes no bytes from this call. Internal pressure after any prefix commits is\nretained in the session tail and returns success; GLOWCAP_ERR_INTERNAL with no\nlast-abort therefore means the first direct frame was not admitted and the same\nchunk is retryable. A recorded last-abort means the input was consumed and the\nsession is closing; drain the typed abort and release it. A declared body\nexceeding the session's frame cap is GLOWCAP_ERR_FRAME_TOO_LARGE; malformed or\nnon-canonical outer syntax is a codec error.");
    try emitFn(&b, gpa, "glowcap_host_session_feed_packet", &.{ "session", "bytes", "len" }, "Feed one transport packet (borrowed for the call). Byte-stream transports pass\narbitrary chunks carrying ADR-0012's outer Syrup byte-string envelope;\nmessage-framed transports pass one bare codec frame per packet. The Host\ntransport profile owns that choice, so embedders do not branch on concrete\ntransport names. A real empty message-framed packet is malformed because it is\nnot a codec frame; use glowcap_host_session_resume_feed to resume retained\nbyte-stream input without supplying new transport bytes.");
    try emitFn(&b, gpa, "glowcap_host_session_resume_feed", &.{"session"}, "Resume input retained by an earlier feed, without treating an empty transport\npacket as new input. Byte-stream sessions may dispatch a held tail; message-\nframed sessions have no hidden tail and no-op. Refused inside a callback.");
    try emitFn(&b, gpa, "glowcap_host_session_take_packet", &.{ "session", "out_frame", "out_prefix", "prefix_cap", "out_prefix_len" }, "Drain one transport-ready packet. Write\nout_prefix[0..*out_prefix_len] and then the owned out_frame bytes. Byte-stream\nsessions return their canonical outer Syrup prefix; message-framed sessions\nreturn an empty prefix and one bare codec frame. Free out_frame through\nglowcap_managed_frame_release. prefix_cap must be at least\nGLOWCAP_HOST_OUTBOUND_PREFIX_CAP; undersizing is refused before the payload\nleaves the queue. Returns GLOWCAP_OK with outputs set, or\nGLOWCAP_ERR_WOULD_BLOCK with outputs untouched. Refused inside a callback.");
    try emitFn(&b, gpa, "glowcap_host_session_take_outbound", &.{ "session", "out_frame", "out_prefix", "prefix_cap", "out_prefix_len" }, "Drain one transport-ready byte-stream vector. Write\nout_prefix[0..*out_prefix_len] and then the owned out_frame bytes. Clear\nsessions return their canonical outer Syrup prefix; sealed sessions return an\nempty prefix because out_frame is already wire-ready ciphertext. Free out_frame\nthrough glowcap_managed_frame_release. prefix_cap must be at least\nGLOWCAP_HOST_OUTBOUND_PREFIX_CAP; undersizing is refused before the payload\nleaves the queue. Returns GLOWCAP_OK with outputs set, or\nGLOWCAP_ERR_WOULD_BLOCK with outputs untouched. Refused inside a callback.");
    try emitFn(&b, gpa, "glowcap_host_next_action", &.{ "host", "out_action" }, "Pop the next embedder action into *out_action, or return\nGLOWCAP_ERR_WOULD_BLOCK when none is pending. Before the pop, queued Host work\nresumes and may invoke GlowcapHostBehavior synchronously; binding runtimes must\ninstall their Host delivery context around every drain. A DIAL carries ticket\nand route_index (borrow the exact pending view with glowcap_host_pending_dial).\nA SETTLE's value and a FAIL's message are host-owned until the NEXT\nglowcap_host_next_action call, which frees them. Deferred work may return\nGLOWCAP_ERR_INTERNAL under allocator pressure before an action is popped; no\naction or authority is lost, and the embedder retries this same drain call when\npressure subsides. See the one loop rule in the header preamble. Refused inside\na callback.");
    try emitFn(&b, gpa, "glowcap_host_pump_drain", &.{ "host", "hooks", "out_acted", "out_yielded" }, "Opt-in convenience drain over glowcap_host_next_action (ADR-0022). Still pops through the pull-queue internally; does not replace\nit. hooks may be NULL (every action is discarded). *out_acted is 1 when any\narm reported progress (optional, may be NULL). *out_yielded is 1 when the\nfinite Host scheduler requested another embedder turn (optional, may be NULL);\nreturn to the reactor before draining again. Resuming work may invoke\nGlowcapHostBehavior synchronously before an action hook runs, so binding\nruntimes must install their Host delivery context around this whole call. See\nGlowcapHostPumpHooks.");
    try emitFn(&b, gpa, "glowcap_host_dialed", &.{ "host", "ticket", "route_index", "session", "out_adopted" }, "Report a DIAL attempt's success. session is an open_dialed_locator against the\nexact ticket/route_index view, driven open. *out_adopted is one when this route\nwon the logical dial and zero when another route already won or the attempt was\nnot running; the executor must close and release an unadopted session. A non-OK\nreturn consumes neither attempt nor session.");
    try emitFn(&b, gpa, "glowcap_host_dial_failed", &.{ "host", "ticket", "route_index", "reason", "reason_len" }, "Report one DIAL attempt's failure. Strong identity routes maintain their bounded\nrace before ordered weak fallbacks begin; waiters break only after every eligible\nroute fails. A stale or non-running attempt is a no-op success.");
    try emitFn(&b, gpa, "glowcap_host_dial_cancelled", &.{ "host", "ticket", "route_index" }, "Acknowledge that a CANCEL_DIAL attempt's physical operation has stopped and its\nexecutor state can be released. Host close remains pending until this report.");
    try emitFn(&b, gpa, "glowcap_host_provide_gift_id", &.{ "host", "ticket", "gift_id", "gift_id_len" }, "Answer a NEED_GIFT_ID action with 32 caller-drawn random bytes: the host\noriginates the claimed handoff and this call flushes its legs, exporter\nfirst. A stale ticket is a no-op success.");
    try emitFn(&b, gpa, "glowcap_host_gift_id_failed", &.{ "host", "ticket" }, "Report that a NEED_GIFT_ID action could not obtain or provide entropy. The\nclaimed handoff settles broken instead of retaining a ticket the embedder has\nalready consumed. A stale ticket is a no-op success.");

    try emitFn(&b, gpa, "glowcap_host_session_publish", &.{ "session", "name", "name_len", "behavior", "ctx", "free", "out_ref" }, "Publish a hosted object a partner on this session can fetch by name (a\nswiss-number). The Host Vat owns the object; this session selects its first\nPort projection. Releasing that session does not run free. On success, free,\nif non-NULL, runs exactly once at Host teardown; a failed construction runs it\nafter this call takes ownership. *out_ref receives the opaque Host-scoped\ncapability. Refused inside a callback (ctx stays yours on a null-pointer or\nreentry refusal).");
    try emitFn(&b, gpa, "glowcap_host_session_spawn", &.{ "session", "behavior", "ctx", "free", "out_ref" }, "Spawn a hosted object in the Host Vat and create its first projection on this\nsession, without a fetchable name. It becomes reachable once a reply or\nargument carries the opaque Host-scoped capability written to *out_ref. Same\nfree contract as glowcap_host_session_publish.");
    try emitFn(&b, gpa, "glowcap_host_spawn", &.{ "host", "behavior", "ctx", "free", "out_ref" }, "Spawn a hosted actor and adopt its first root into an owned Host reference.\nNo session, alias or wire export is created. Release the returned reference\nthrough glowcap_host_ref_release. ctx/free follows glowcap_host_publish: null\nand reentry refusals leave ctx yours; after admission free runs exactly once\non failure, final actor collection or Host release.");

    try emitFn(&b, gpa, "glowcap_host_publish", &.{ "host", "name", "name_len", "behavior", "ctx", "free" }, "Publish one hosted object in the Vat owned by this Host and bind name as its\nhost-wide alias. Fetch lazily projects the actor onto the requesting Port; a\ndeposited gift retains the exact actor and never consults the alias at\nwithdrawal. The publication row owns ctx: free, if non-NULL, runs exactly once, at\nglowcap_host_release on success or before this returns on any non-OK outcome\n(the null-pointer and reentry refusals touch nothing and leave ctx yours).\nAll-or-nothing over this call's own work: registration failure discards the\nfresh actor and frees ctx, so a retry starts with no partial alias or projection.");
    try emitFn(&b, gpa, "glowcap_host_unpublish", &.{ "host", "name", "name_len" }, "Remove the host-wide alias name. Discovery-only, alias-only: a later fetch of\nthe name misses on every session, while capabilities already issued, live Port\nprojections, and deposited gifts keep naming the exact actor, which stays in\nthe Host's Vat until glowcap_host_release. An absent alias returns\nGLOWCAP_ERR_NOT_FOUND, so a typo is loud instead of an idempotent no-op. A name\nin the reserved durable namespace is refused INVALID_ARGUMENT: minted durable\npublications leave through glowcap_host_remove_durable.");
    try emitFn(&b, gpa, "glowcap_host_publish_durable", &.{ "host", "entropy", "entropy_len", "behavior", "ctx", "free", "out_swiss", "swiss_cap" }, "Publish one hosted object under a freshly minted durable swiss name: a\nreserved-prefix namespace mutable aliases structurally cannot enter,\nunpredictable, never reassigned, and removable only through\nglowcap_host_remove_durable. entropy supplies exactly GLOWCAP_HOST_DURABLE_ENTROPY_LEN caller-drawn\nrandom bytes (the embedder owns the entropy boundary, as for gift ids). The minted\nswiss is written into out_swiss (swiss_cap of at least GLOWCAP_HOST_DURABLE_SWISS_LEN, or\nBUFFER_TOO_SMALL and nothing published) and the written length is returned.\nctx/free follow glowcap_host_publish's ownership exactly. The core stores no\nregistry across processes: preserve the entropy and republish the actor with\nthe same bytes at startup to reproduce the sturdyref; losing either makes the\nold name miss, fail-closed.");
    try emitFn(&b, gpa, "glowcap_host_publish_reference", &.{ "host", "reference", "entropy", "entropy_len", "out_swiss", "swiss_cap" }, "Publish an already-held local capability under a durable name. The\npublication retains its own root; the caller's reference stays owned by\nthe caller on success and failure. Entropy and output use the same bounds\nas glowcap_host_publish_durable. Foreign capabilities are refused.");
    try emitFn(&b, gpa, "glowcap_host_remove_durable", &.{ "host", "swiss", "swiss_len" }, "Remove a minted durable publication: the old sturdyref misses from now on,\nwhile capabilities already issued and deposited gifts keep the exact actor. A\nswiss outside the durable namespace returns INVALID_ARGUMENT (mutable aliases\nleave through glowcap_host_unpublish); an unknown durable name returns\nGLOWCAP_ERR_NOT_FOUND.");

    try emitFn(&b, gpa, "glowcap_host_session_fetch", &.{ "session", "name", "name_len", "out_vow" }, "Fetch the partner capability published as name, minting a host vow whose id\nlands in *out_vow; the outcome arrives as that vow's SETTLE or FAIL action.\nA fulfilled far capability settles ALREADY enrolled under a node-unique\ntoken, recorded before the completion is queued, so a reply that\nimmediately re-gifts it routes to the right exporter. Refused inside a\ncallback.");
    try emitFn(&b, gpa, "glowcap_host_session_enliven", &.{ "session", "sturdyref_uri", "sturdyref_uri_len", "out_vow" }, "Enliven the complete canonical persistent sturdyref URI (ADR-0007), minting\na host vow whose id lands in *out_vow; the live reference arrives as that\nvow's SETTLE action. The URI form is independent of the selected session's\nnegotiated profile. Its transport and designator must match that session\nbefore the swiss namespace is consulted or wire traffic is emitted. A\ndedup-cache hit settles before this returns; a fresh enliven rides\nbootstrap-fetch. Refused inside a callback.");

    try emitFn(&b, gpa, "glowcap_host_enliven", &.{ "host", "sturdyref_uri", "sturdyref_uri_len", "out_vow" }, "Select-or-dial enliven of a canonical persistent sturdyref URI (ADR-0007):\nenliven it over a live session this host already dialed to that peer, or\nstage a dial and finish when you report it. The host vow id lands in\n*out_vow and its outcome arrives as that vow's SETTLE or FAIL action either\nway. A staged dial surfaces as an ordinary GLOWCAP_HOST_ACTION_DIAL: borrow\nit with glowcap_host_pending_dial and answer it with glowcap_host_dialed /\nglowcap_host_dial_failed exactly as a handoff redeem's, so a parked vow's\nid has no session and no row until it settles. Alternate profile spellings use\nglowcap_host_enliven_for_version. Refused inside a callback.");
    try emitFn(&b, gpa, "glowcap_host_enliven_for_version", &.{ "host", "captp_version", "sturdyref_uri", "sturdyref_uri_len", "out_vow" }, "The same Host-level select-or-dial enliven, parsing the sturdyref's swiss authority under the explicit GLOWCAP_CAPTP_* version that defined its spelling. Use this when the sturdyref arrived over a session whose settled version differs from the Host preference. Invalid versions are refused before any authority or dial state changes.");
    try emitFn(&b, gpa, "glowcap_host_fetch_at", &.{ "host", "locator", "name", "name_len", "out_vow" }, "Fetch a named publication at a typed peer locator through this Host's configured profile. Concrete locators select or open one physical session; an id/via locator is expanded by the Host's Node into its bounded authenticated route schedule. The caller names no CapTP version or codec. The host vow id lands in *out_vow and settles through the ordinary action queue. The locator and name are borrowed for this call; staged work retains its own copy. Refused inside a callback.");
    try emitFn(&b, gpa, "glowcap_host_session_listen", &.{ "session", "target", "out_vow" }, "Listen on a far capability this session holds (CapTP op:listen), minting a\nhost vow whose id lands in *out_vow; the listen notification arrives as that\nvow's SETTLE or FAIL action. In 1.0, the target may be a far promise or live\nfar object; a live object answers immediately. In glowcap-next, the target\nmust be a far promise because shortening and settling are promise-only. A\nre-gifted promise routes to its exporter session transparently, and a give in\nthe settlement auto-redeems exactly as a fetch's would. The vow is plain: a\nlisten makes no claim the result is a capability. Legal inside a callback.");
    try emitFn(&b, gpa, "glowcap_host_session_resolve", &.{ "session", "target", "out_reference", "out_vow" }, "Resolve an opaque capability. An object returns one owned application retain\nin *out_reference and zero in *out_vow, without wire traffic. Release that\nretain with glowcap_host_ref_release. A promise returns a zero reference and\na settlement vow in *out_vow; its SETTLE/FAIL may carry any value. Inline\nhandoffs redeem through the Host. All pointers are required; outputs change\nonly on success. Legal inside a callback.");

    try emitFn(&b, gpa, "glowcap_host_send", &.{ "host", "target", "verb", "verb_len", "args", "args_len", "out_vow" }, "Eventual-send through this Host without borrowing a network session. The\nactual target determines its local or foreign home. Input values borrow\nthis call; the existing queue owns their copies and capability retains.\nThe returned vow is await-only and settles through Host actions. Releasing\nits observer does not cancel admitted work. Refused inside a callback;\nturn_send owns that turn's transactional delivery instead.");
    try emitFn(&b, gpa, "glowcap_host_session_send", &.{ "session", "target", "verb", "verb_len", "args", "args_len", "out_vow" }, "Eventual-send to an opaque Host-scoped target and mint a host vow for the\nanswer; the outcome arrives as that vow's SETTLE or FAIL action. The Host\nchooses local delivery or the owning exporter session. A target or nested\nargument from another Host, or a retired identity, is refused rather than\nbeing interpreted as a wire position. verb/args are borrowed; the host copies\nwhat it queues. An empty verb (including (NULL, 0), which the family's ptr+len\ncontract admits) is a real message, not an error: it delivers positionally,\nthe way Goblins invokes a capability. Legal inside a callback (the send\nencodes when the enclosing call unwinds).");
    try emitFn(&b, gpa, "glowcap_host_tell", &.{ "host", "target", "verb", "verb_len", "args", "args_len" }, "Notification through the target's actual home, with no reply or vow. Input\nvalues borrow this call; the owning queue retains admitted work. Refused\ninside a callback, where turn_tell owns transactional delivery.");
    try emitFn(&b, gpa, "glowcap_host_session_tell", &.{ "session", "target", "verb", "verb_len", "args", "args_len" }, "Fire-and-forget eventual-send: glowcap_host_session_send with no answer and no\nvow. Same routing, refusals, and empty-verb contract.");
    try emitFn(&b, gpa, "glowcap_host_vow_send", &.{ "host", "vow", "verb", "verb_len", "args", "args_len", "out_vow" }, "Promise pipelining: eventual-send to a host vow before it resolves, minting a\nnew vow for this call's own answer. A local vow (a NEAR send's answer) has no\nwire answer to pipeline against and is refused GLOWCAP_ERR_INVALID_ARGUMENT\n(NotPipelineable); an unknown vow reports GLOWCAP_ERR_NOT_FOUND. The\nempty-verb contract is glowcap_host_session_send's.");
    try emitFn(&b, gpa, "glowcap_host_vow_tell", &.{ "host", "vow", "verb", "verb_len", "args", "args_len" }, "Fire-and-forget promise-pipelined send: glowcap_host_vow_send with no answer\nand no returned vow. Same target, argument, and empty-verb contract.");
    try emitFn(&b, gpa, "glowcap_host_vow_release", &.{ "host", "vow" }, "Release one public Host vow. Settlement does not consume the handle: until\nthis call succeeds it remains a valid promise-pipeline target, including after\na fast peer has resolved it. Releasing a far answer emits op:gc-answer; a local\nanswer only drops its Host observer. A row already retired with its session is\na wire-free success. Any other non-OK return consumes nothing and is retryable.\nSingle-thread affinity applies: finalizers park the id for the owning runtime\nloop rather than calling this directly.");
    try emitFn(&b, gpa, "glowcap_host_vow_index", &.{ "host", "vow", "index", "out_vow" }, "Pipeline an op:index projection against a far host vow, minting a new vow for\nthe projected element. Same local-vow and unknown-vow refusals as\nglowcap_host_vow_send; an index above INT64_MAX is refused\nGLOWCAP_ERR_INVALID_ARGUMENT (the wire index is a signed integer).");
    try emitFn(&b, gpa, "glowcap_host_vow_untag", &.{ "host", "vow", "tag", "tag_len", "out_vow" }, "Pipeline an op:untag projection against a far host vow, minting a new vow for\nthe unwrapped payload (a single-value Tagged unwraps to that value; a\nvariadic one to its value list). tag is borrowed.");
    try emitFn(&b, gpa, "glowcap_host_vow_get", &.{ "host", "vow", "field", "field_len", "out_vow" }, "Pipeline an op:get projection against a far host vow, minting a new vow for\nthe named Struct field. Same local-vow and unknown-vow refusals as\nglowcap_host_vow_send; field is borrowed.");

    try emitFn(&b, gpa, "glowcap_host_set_trace", &.{ "host", "callback", "ctx" }, "Install (or clear, with a NULL callback) the live trace: the host reports\nits own session opens, every message's verb in both directions, and session\ncloses through callback, on the host's one thread. Views in the event are\nborrowed for the call. The callback must call no host-driving verb.");
    try emitFn(&b, gpa, "glowcap_host_set_trace_queue", &.{ "host", "capacity", "payload_cap" }, "Install (or clear, with a zero capacity) the drained live trace: the host\ncaptures each fact into a fixed ring of capacity records, each holding up to\npayload_cap bytes of that record's strings, and the embedder pops them with\nglowcap_host_next_trace. This is the route for an embedder that cannot hand\nthe library a function pointer. Nothing here grows: a full ring drops the\nnewest record and reports the count on the next one it captures, so tracing\nnever makes the protocol wait.");
    try emitFn(&b, gpa, "glowcap_host_next_trace", &.{ "host", "out_event" }, "Pop the oldest captured trace record into out_event. Its string views point\ninto the queue and stay valid until the next glowcap_host_next_trace call,\nthe same borrow glowcap_host_next_action carries. Returns\nGLOWCAP_ERR_WOULD_BLOCK when nothing is captured, so an embedder drains in a\nloop until it sees that code.");
    try emitFn(&b, gpa, "glowcap_host_resolver_fulfill", &.{ "host", "resolver_id", "value" }, "Settle a resolver vow fulfilled with one capability-free value (a value\nnaming a capability refuses whole; owning-thread capability values use\nresolver_fulfill_value instead). Top-level: refused inside a callback; the\nsettle runs the deferred answers and pumps the sessions they dirtied. A\nsuccessful settle consumes the resolver; preparation failure is retryable.\nA consumed resolver refuses a second settle as INVALID_ARGUMENT, and an id\nthis host never minted refuses as NOT_FOUND.");
    try emitFn(&b, gpa, "glowcap_host_resolver_fulfill_value", &.{ "host", "resolver_id", "value" }, "Fulfill a deferred answer with an owning-thread application value.\nCapabilities are projected in the original caller session, using ordinary\nhandoff staging for foreign authority. Failed preparation preserves the\nresolver for retry. Top-level and\nconsume-on-success, like resolver_fulfill. Plain worker/mailbox data continues\nto use resolver_fulfill.");
    try emitFn(&b, gpa, "glowcap_host_resolver_break", &.{ "host", "resolver_id", "message", "message_len" }, "Settle a resolver vow broken with a diagnostic borrowed for the call. The\nsame top-level, consume-on-success contract as\nglowcap_host_resolver_fulfill.");
    try emitFn(&b, gpa, "glowcap_host_resolver_abandon", &.{ "host", "resolver_id", "message", "message_len" }, "Abandon a deferred answer, top-level. A resolver already consumed by\nsession teardown or settlement is complete cleanup. Unminted ids refuse\nNOT_FOUND; other failures leave the operation retryable.");
    try emitFn(&b, gpa, "glowcap_host_turn_session", &.{ "turn", "out_session" }, "Borrow the session whose Port delivered this callback turn. Trusted local\nowning delivery succeeds with a null session. A nonnull handle is Host-owned\nand lives with that session; do not release it. This identifies the arriving\nconnection without reconstructing delivery state outside the core.");
    try emitFn(&b, gpa, "glowcap_host_turn_forward", &.{ "turn", "target", "verb", "verb_len", "args", "args_len", "out_reply" }, "From inside a behavior callback, forward this turn's call to an opaque\nHost-scoped target and let this object's own answer settle on the forwarded\nresult. This is the caretaker/attenuator primitive. The Host resolves the target and\nevery nested capability; a stale or foreign-Host identity is refused. In a\nlocal eventual or wire-served turn the real answer rides the forwarded vow and *out_reply gets a\nvoid placeholder; pass your behavior's own out_reply and return GLOWCAP_OK.\nThe written reply is BORROWED and valid until the next turn verb or drive on\nthis host. The empty-verb contract is glowcap_host_session_send's.");
    try emitFn(&b, gpa, "glowcap_host_turn_defer", &.{ "turn", "out_resolver_id" }, "Atomically defer this turn's answer onto a fresh resolver vow (ADR-0014).\n*out_resolver_id receives the one-shot settle authority used by\nglowcap_host_resolver_fulfill / _break. All rows and the forward listener are\nreserved before publication, so refusal leaves no live resolver and no\nforwarded effect. The behavior returns normally after success; its return\nvalue resolves nothing once the turn is deferred.");
    try emitFn(&b, gpa, "glowcap_host_turn_defer_if_answer", &.{ "turn", "out_resolver_id" }, "Defer an answered call; a tell succeeds with zero and creates no resolver.\nNonzero IDs carry the same one-shot authority as glowcap_host_turn_defer.\nRefusal zeros the output and leaves the current turn unchanged.");
    try emitFn(&b, gpa, "glowcap_host_turn_send", &.{ "turn", "target", "verb", "verb_len", "args", "args_len", "out_vow" }, "From inside a behavior callback, eventual-send to target and mint a Host\nvow for the answer. Trusted local callbacks use the target's actual local\nor foreign home; wire callbacks use their Session routing. Local public\nvows settle through Host actions and support release, without a wire\npipeline or raw wire listener. Delivery commits with the enclosing turn.\nThe empty-verb contract is glowcap_host_session_send's.");
    try emitFn(&b, gpa, "glowcap_host_turn_tell", &.{ "turn", "target", "verb", "verb_len", "args", "args_len" }, "From inside a behavior callback, fire-and-forget eventual-send:\nglowcap_host_turn_send with no answer and no vow. Same empty-verb contract.");
    try emitFn(&b, gpa, "glowcap_host_turn_spawn", &.{ "turn", "behavior", "ctx", "free", "out_ref" }, "From inside a behavior callback, spawn a hosted object in the Host Vat and\ncreate its first projection on the Port that delivered this turn. This is how a\nserved factory mints a capability it replies with (a task board's create, a\ncaretaker wrapping a target), the turn-time form of\nglowcap_host_session_spawn. Same free contract; *out_ref receives the opaque\nHost-scoped capability, ready to ride this turn's own reply.");
    try emitFn(&b, gpa, "glowcap_host_turn_break", &.{ "turn", "message", "message_len" }, "From inside a behavior callback, break this turn's own answer with message.\nThis is how a behavior refuses with a diagnostic, since a non-OK return settles the\nanswer broken with only a generic reason. A wire answer breaks inside this\ncall; a local eventual answer breaks when its turn unwinds. A no-answer tell\nbreaks nothing. Leave out_reply untouched and\nreturn GLOWCAP_OK from the behavior, whose return value then resolves\nnothing. message is borrowed and copied.");

    try emitFn(&b, gpa, "glowcap_host_ref_release", &.{ "host", "ref", "delta" }, "Release delta application retains on one opaque Host capability. The Host\nresolves the owning session and emits any required op:gc-exports itself; the\ncaller never pairs a capability with a session-local wire position. If that\nsession already closed, its already-issued application units remain releaseable\nas wire-free success; every other use is stale. A fully released or foreign-Host\nidentity is refused. A non-OK return commits no release, so the same (ref, delta)\nmay be retried. OK consumes the release; any later pump cleanup failure becomes\ntyped session close and must not invite a duplicate release. Single-thread\naffinity applies: never call this from a finalizer thread.");
    try emitFn(&b, gpa, "glowcap_host_session_published_ref", &.{ "session", "name", "name_len", "out_ref" }, "Write to *out_ref the opaque Host-scoped capability currently published under\nname, or return GLOWCAP_ERR_NOT_FOUND when the Host has no such alias. The actor\nin the Host-owned Vat is lazily projected onto session when needed; the\nreturned identity itself carries no export position and retains no name.");
    try emitFn(&b, gpa, "glowcap_host_session_break_far_vows", &.{ "session", "message", "message_len" }, "Break every far vow currently parked on session, queueing each vow's FAIL\ncompletion inside this call with the partner's retained abort diagnostic when\none arrived and message otherwise. The session remains open to later work; use\nglowcap_host_session_transport_closed when the byte channel is gone.");
    try emitFn(&b, gpa, "glowcap_host_session_transport_closed", &.{ "session", "message", "message_len" }, "Report that this session's transport is gone. The Host seals session\nadmission, retires its routing authority, and queues each pending far vow's\nFAIL completion inside this call, using the partner's retained abort\ndiagnostic when one arrived and message otherwise. Memory remains owned until\nglowcap_host_session_release.");
    try emitFn(&b, gpa, "glowcap_host_session_set_exporter_location", &.{ "session", "locator" }, "Record the exporter locator to embed in gives whose exporter is session, overriding the session record. Null clears the override; otherwise the Host validates and clones the borrowed locator view.");
    try emitFn(&b, gpa, "glowcap_host_session_last_abort", &.{ "session", "out" }, "Read the typed cause of this session's most recent LOCAL dispatch failure\ninto *out (the shared GlowcapLastAbort layout; byte views process-static,\nnever freed). Returns GLOWCAP_OK when a failure has been recorded, or\nGLOWCAP_ERR_WOULD_BLOCK when none has. The flat per-feed return code names\nthe failure family; this names the member.");
    try emitFn(&b, gpa, "glowcap_host_session_partner_abort", &.{ "session", "out_kind_name", "out_kind_name_len", "out_msg", "cap", "out_len" }, "Read the PARTNER'S retained op:abort: the abort kind's wire name (a\nprocess-static view, e.g. \"ProtocolError\") into\n*out_kind_name / *out_kind_name_len, and up to cap bytes of its bounded\ndiagnostic into out_msg, with the retained length in *out_len. Returns\nGLOWCAP_ERR_WOULD_BLOCK when no partner abort has arrived. Any out-pointer\nmay be NULL to skip that piece.");

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
        \\glowcap_host_session_release, or until the host is torn down.
    );
    try E.emitStruct(&b, gpa, Spec.c.GlowcapPartnerIdentity, "GlowcapPartnerIdentity", &.{
        "The partner's session public key. Always present on GLOWCAP_OK.",
        "",
        "The designator the partner signed, or NULL when its location carried none.",
        "",
        "The verbatim location record, or NULL when the apply path captured none.",
        "",
        "How the durable identity in designator was authenticated, one of the\nGLOWCAP_DURABLE_PROVENANCE_* values. It is derived from the evidence this one\nsession holds, never from its transport's name, so two sessions on the same\ntransport can answer differently.\n\nSession identity, durable identity, and this provenance are three separate\nfacts: a caller that requires a proved durable peer reads this, never a\ncomparison of designator against session_key. Each session draws its own\nsigning key, so a session key is not an identity and the two never match.",
    });
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "glowcap_host_session_partner_identity", &.{ "session", "out" }, "Borrow this session's verified partner identity into *out: the partner's\nsession public key, the location designator it signed, and the verbatim\nlocation record those came from.\n\nA GLOWCAP_OK return always means the signature was checked. Before the\npartner's op:start-session has arrived with a key this returns\nGLOWCAP_ERR_WOULD_BLOCK, and a session opened without partner verification\nreturns GLOWCAP_ERR_SESSION rather than an identity nothing proved. That\nrefusal is the contract: you cannot read an unverified identity through this\nentry point, so you never have to remember to ask whether the bytes were\nchecked.");
    try emitFn(&b, gpa, "glowcap_host_session_bind_verified_channel_key", &.{ "session", "designator", "designator_len" }, "Testify what the code that realized this connection proved about its far\nend: designator is the durable key that proof names, as a locator writes it.\nAn iroh listener passes what glowcap_iroh_conn_remote_node_id read off the\nQUIC handshake; a WebRTC peer passes the identity its signaling\nauthorized.\n\nThis library realizes nothing at the byte-fed tier. You own the sockets, so\nyou are the realizer, and this is the only way that proof reaches a session.\nWithout it the session reports unauthenticated durable provenance.\n\nCall it after opening the session and before feeding the first partner byte.\nGLOWCAP_ERR_SESSION means the partner's op:start-session was already applied,\nso the proof is too late to weigh. GLOWCAP_ERR_INVALID_ARGUMENT means the\ndesignator does not spell a durable key, or names a different key from one\nthis connection's realizer already asserted. Asserting the same key twice is\nthe same statement made twice and succeeds.");

    try emitFn(&b, gpa, "glowcap_host_last_error", &.{ "out_buf", "cap" }, "Copy the calling thread's last glowcap_host_* error into out_buf, the host\nsibling of glowcap_last_error, reading this archive's own per-thread slot.\nCopies at most cap-1 bytes and NUL-terminates when cap>0; out_buf NULL or cap\n0 queries the length. Returns the full message length, or 0 when none is set." ++ header_emit.last_error_freshness_doc);
    try emitFn(&b, gpa, "glowcap_host_clear_last_error", &.{}, "Clear the calling thread's glowcap_host_* last-error slot.");

    try b.appendSlice(gpa,
        \\
        \\#ifdef __cplusplus
        \\}
        \\#endif
        \\
        \\#endif /* GLOWCAP_HOST_H */
        \\
    );

    try E.assertAllEmitted(&b, "gen-header-host");
    return b.toOwnedSlice(gpa);
}
