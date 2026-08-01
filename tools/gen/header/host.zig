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
    "pancake_host_release",
    "pancake_host_designator_from_seed",
    "pancake_host_set_self_designator",
    "pancake_host_set_session_limits",
    "pancake_host_session_open_dialed_locator",
    "pancake_host_session_open_accepted",
    "pancake_host_plan_dial",
    "pancake_host_pending_dial",
    "pancake_host_reference_exporter",
    "pancake_host_plan_accept",
    "pancake_host_session_release",
    "pancake_host_session_is_open",
    "pancake_host_session_feed",
    "pancake_host_session_feed_bytes",
    "pancake_host_session_take_outbound",
    "pancake_host_next_action",
    "pancake_host_pump_drain",
    "pancake_host_dialed",
    "pancake_host_dial_failed",
    "pancake_host_provide_gift_id",
    "pancake_host_session_publish",
    "pancake_host_session_spawn",
    "pancake_host_publish",
    "pancake_host_session_fetch",
    "pancake_host_session_enliven",
    "pancake_host_session_send",
    "pancake_host_session_tell",
    "pancake_host_vow_send",
    "pancake_host_vow_index",
    "pancake_host_vow_untag",
    "pancake_host_vow_get",
    "pancake_host_turn_forward",
    "pancake_host_turn_send",
    "pancake_host_turn_tell",
    "pancake_host_turn_spawn",
    "pancake_host_turn_break",
    "pancake_host_ref_release",
    "pancake_host_session_published_ref",
    "pancake_host_session_break_far_vows",
    "pancake_host_session_set_exporter_location",
    "pancake_host_session_last_abort",
    "pancake_host_session_partner_abort",
    "pancake_host_session_partner_identity",
    "pancake_host_session_partner_designator_is_key",
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
        .{ .name = "PANCAKE_HOST_ACTION_NEED_GIFT_ID", .doc = "PancakeHostAction.kind: draw 32 random bytes and feed them to pancake_host_provide_gift_id with the ticket." },
        .{ .name = "PANCAKE_HOST_ACTION_SETTLE", .doc = "PancakeHostAction.kind: the vow named by ticket settled fulfilled with value; route the outcome to whatever awaits it." },
        .{ .name = "PANCAKE_HOST_ACTION_FAIL", .doc = "PancakeHostAction.kind: the vow named by ticket settled broken with message; route the outcome to whatever awaits it." },
        .{ .name = "PANCAKE_HOST_ACTION_CLOSE", .doc = "PancakeHostAction.kind: the host condemned session mid-pump (local turn budget exceeded); write its queued abort, close its transport, and release the session." },
        .{ .name = "PANCAKE_DEFAULT_FRAME_CAP", .doc = "Default maximum admissible frame for pancake_host_new / pancake_host_new_in (bytes): mirrors session.SessionLimits.max_frame_bytes (1 MiB)." },
        .{ .name = "PANCAKE_MAX_LOCAL_FORWARD_HOPS", .doc = "Bound on one turn's synchronous local Forward chase (caretaker over attenuator). Hop N+1 breaks the answer instead of spinning." },
        .{ .name = "PANCAKE_DISCOVERY_DIAL_RETRY_MS", .doc = "Discovery-posture dial retry interval in milliseconds (ADR-0082). Keep lockstep with driver.discovery_retry_ms." },
        .{ .name = "PANCAKE_DISCOVERY_DIAL_MAX_ATTEMPTS", .doc = "Discovery-posture dial attempt budget (ADR-0082). Keep lockstep with driver.discovery_max_attempts." },
        .{ .name = "PANCAKE_DIAL_SHAPE_HOST_PORT", .doc = "PancakeDialPlan.shape: open a TCP socket to host:port (tcp, keyed-tcp)." },
        .{ .name = "PANCAKE_DIAL_SHAPE_PEER_ID", .doc = "PancakeDialPlan.shape: peer-id open (node-id designator + addresses + reach; today from the iroh locator scheme)." },
        .{ .name = "PANCAKE_DIAL_SHAPE_SIGNALING", .doc = "PancakeDialPlan.shape: signaling-mediated open (webrtc); no dialable address, the channel comes up through offer/answer/ICE (ADR-0089 phase 4)." },
        .{ .name = "PANCAKE_DIAL_REACH_DIRECT", .doc = "PancakeDialPlan.reach_kind (peer-id shape): the relay-less direct posture." },
        .{ .name = "PANCAKE_DIAL_REACH_CONFIGURED", .doc = "PancakeDialPlan.reach_kind (peer-id shape): the node's own configured redeem posture." },
        .{ .name = "PANCAKE_DIAL_REACH_EXPLICIT", .doc = "PancakeDialPlan.reach_kind (peer-id shape): the caller posture carried in reach_value." },
        .{ .name = "PANCAKE_DIAL_POSTURE_REDEEM", .doc = "pancake_host_plan_dial posture_policy: a redeem (a DIAL action) — direct when a hint is present, else the node's configured posture." },
        .{ .name = "PANCAKE_DIAL_POSTURE_EXPLICIT", .doc = "pancake_host_plan_dial posture_policy: a connect carrying a posture in posture_value." },
        .{ .name = "PANCAKE_DIAL_POSTURE_EXPLICIT_NONE", .doc = "pancake_host_plan_dial posture_policy: a connect that named no posture; a peer-id dial refuses PANCAKE_ERR_INVALID_ARGUMENT." },
    };

    pub fn special(comptime T: type) ?[]const u8 {
        if (T == c.PancakeHostBehavior) return "PancakeHostBehavior";
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
    std.debug.assert(Spec.c.PANCAKE_MAX_LOCAL_FORWARD_HOPS == 256);
    // Hold the dial/accept planning #defines emitted below against the source.
    std.debug.assert(Spec.c.PANCAKE_DIAL_SHAPE_HOST_PORT == 0);
    std.debug.assert(Spec.c.PANCAKE_DIAL_SHAPE_PEER_ID == 1);
    std.debug.assert(Spec.c.PANCAKE_DIAL_SHAPE_SIGNALING == 2);
    std.debug.assert(Spec.c.PANCAKE_DIAL_REACH_DIRECT == 0);
    std.debug.assert(Spec.c.PANCAKE_DIAL_REACH_CONFIGURED == 1);
    std.debug.assert(Spec.c.PANCAKE_DIAL_REACH_EXPLICIT == 2);
    std.debug.assert(Spec.c.PANCAKE_DIAL_POSTURE_REDEEM == 0);
    std.debug.assert(Spec.c.PANCAKE_DIAL_POSTURE_EXPLICIT == 1);
    std.debug.assert(Spec.c.PANCAKE_DIAL_POSTURE_EXPLICIT_NONE == 2);
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
        \\A vow is this tier's name for the eventual result of a send: the same
        \\thing pancake_ocapn.h calls a promise and the CapTP wire calls an answer.
        \\A session_send / session_fetch returns a vow; you pipeline more sends
        \\against it (vow_send / vow_get / …) before it settles, and its outcome
        \\arrives later as a SETTLE or FAIL action naming that vow's ticket.
        \\
        \\THE ONE LOOP RULE. After any top-level pancake_host_* call returns OK,
        \\drain pancake_host_next_action until PANCAKE_ERR_WOULD_BLOCK, honoring each
        \\action: DIAL — borrow the pending view with
        \\pancake_host_pending_dial(ticket), open your own session from its
        \\transport/designator (pancake_host_session_open_dialed_locator), drive
        \\its session open, then report pancake_host_dialed (or
        \\pancake_host_dial_failed); FLUSH — drain
        \\take_outbound on that session until WOULD_BLOCK and write the frames;
        \\NEED_GIFT_ID — draw 32 random bytes and call pancake_host_provide_gift_id;
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
        \\fetch/enliven, break_far_vows, release) are refused there with
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

    try emitConst(&b, gpa, "PANCAKE_HOST_ACTION_DIAL");
    try emitConst(&b, gpa, "PANCAKE_HOST_ACTION_FLUSH");
    try emitConst(&b, gpa, "PANCAKE_HOST_ACTION_NEED_GIFT_ID");
    try emitConst(&b, gpa, "PANCAKE_HOST_ACTION_SETTLE");
    try emitConst(&b, gpa, "PANCAKE_HOST_ACTION_FAIL");
    try emitConst(&b, gpa, "PANCAKE_HOST_ACTION_CLOSE");
    try emitConst(&b, gpa, "PANCAKE_DEFAULT_FRAME_CAP");
    try emitConst(&b, gpa, "PANCAKE_MAX_LOCAL_FORWARD_HOPS");
    try emitConst(&b, gpa, "PANCAKE_DISCOVERY_DIAL_RETRY_MS");
    try emitConst(&b, gpa, "PANCAKE_DISCOVERY_DIAL_MAX_ATTEMPTS");
    try b.appendSlice(gpa, "\n");
    try emitDoc(&b, gpa,
        \\One embedder effect popped from pancake_host_next_action. kind selects the
        \\live fields: DIAL carries only ticket (borrow the pending view with
        \\pancake_host_pending_dial). FLUSH and CLOSE carry session;
        \\NEED_GIFT_ID carries ticket. SETTLE carries the settled vow id in ticket
        \\and the fulfilled value in value; FAIL carries the vow id in ticket and
        \\the break reason in message/message_len. Every popped byte view and
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

    try emitFn(&b, gpa, "pancake_host_new", &.{ "seed", "seed_len", "frame_cap", "verify_partner", "codec", "local_turn_budget", "out_host" }, "Create a byte-fed host bound to the caller-drawn 32-byte Ed25519 identity\nseed (the host never draws entropy), allocating through the library\nallocator. frame_cap sizes every session's maximum admissible frame; a\nnonzero verify_partner keeps partner-signature verification on (the secure\ndefault); codec is the PANCAKE_CODEC_* wire grammar (pancake_ocapn.h) every\nsession this host mints negotiates in — both ends of a session must\ncarry the same value, as on the peer tier's _negotiated constructors;\nlocal_turn_budget is 0 = unbounded (same default as Zig Host + Bridge);\nnonzero caps local-turn amplification per drive (ADR-0076).\n*out_host receives the handle; release with pancake_host_release.");
    try emitFn(&b, gpa, "pancake_host_new_in", &.{ "context", "seed", "seed_len", "frame_cap", "verify_partner", "codec", "local_turn_budget", "out_host" }, "pancake_host_new allocating every byte the host owns through context's host\nallocator (pancake_context_new_with_allocator).");
    try emitFn(&b, gpa, "pancake_host_release", &.{"host"}, "Release the host and everything it owns: every still-open session (each\nstill-parked vow breaks inside this call, its undrained completion freed\nwith the rest of the action queue), the vow map, parked actions, the node,\nand the giftable rows (each giftable's free runs exactly once here). NULL is\na no-op. Session (PancakeHostSession) handles this host minted are freed with it —\nnever touch one after its host is gone. Refused (last error set, nothing freed) from\ninside a callback.");
    try emitFn(&b, gpa, "pancake_host_designator_from_seed", &.{ "seed", "seed_len", "out", "out_len" }, "Derive the canonical key designator (exactly 64 lowercase hex digits) from a\n32-byte Ed25519 identity seed — the public half of the key pancake_host_new\nsigns with. Writes 64 bytes into out (out_len must be at least 64). Used by a\nkeyed-tcp listener whose Node identity is the locator designator (ADR-0075).");
    try emitFn(&b, gpa, "pancake_host_set_self_designator", &.{ "host", "designator", "len" }, "Record the designator this host's dials sign as their own dialable address (a\nhost that also listens). designator is borrowed and copied into the host's\nretained buffer; longer than 64 bytes is refused\nPANCAKE_ERR_INVALID_ARGUMENT, and empty resets to the unreachable-client\nplaceholder.");
    try emitFn(&b, gpa, "pancake_host_set_session_limits", &.{ "host", "max_frame_bytes", "queue_cap" }, "Selective session-limit knobs (ADR-0082): override max_frame_bytes and/or\nqueue_cap on a host before minting sessions. Pass 0 for a field to leave it\nunchanged. Already-open peers keep the limits they were minted with.");
    try emitFn(&b, gpa, "pancake_host_session_open_dialed_locator", &.{ "host", "transport", "transport_len", "designator", "designator_len", "out_session" }, "Mint the dialing half from an already-parsed locator (transport +\ndesignator). A DIAL action carries only ticket — borrow the pending view with\npancake_host_pending_dial and pass its transport/designator here. The keyed\nop:start-session is signed under the host identity and encoded before this\nreturns, so drain take_outbound (a FLUSH action is queued) and drive the\nhandshake byte-fed. Host-wide aliases remain lazily discoverable through the\nnew session. A URI-holding caller parses first (pancake_uri_parse_peer) and\npasses the pieces — there is no parallel URI-string mint entry. The dialed\nhello does not consume a direct-addresses hint. *out_session is host-owned;\nrelease with pancake_host_session_release.");
    try emitFn(&b, gpa, "pancake_host_session_open_accepted", &.{ "host", "transport", "transport_len", "designator", "designator_len", "direct_addresses_hint", "direct_addresses_hint_len", "out_session" }, "Mint the accepting half of a connection your own listener produced: the keyed\nop:start-session signs the listener's own transport/designator — the key\ndesignator for keyed-tcp, the address designator for tcp — and the locator a\ngive made on this host names as the exporter location. On keyed-tcp,\ndirect_addresses_hint is the bound host:port riding the signed locator\n(borrowed; NULL/0 = none, refused for keyed-tcp because TCP has no discovery);\nan address-designator transport ignores it. Host-wide aliases remain lazily\ndiscoverable, with the same flush and release contract as\npancake_host_session_open_dialed_locator.");
    try b.appendSlice(gpa, "\n");
    try emitConst(&b, gpa, "PANCAKE_DIAL_SHAPE_HOST_PORT");
    try emitConst(&b, gpa, "PANCAKE_DIAL_SHAPE_PEER_ID");
    try emitConst(&b, gpa, "PANCAKE_DIAL_SHAPE_SIGNALING");
    try emitConst(&b, gpa, "PANCAKE_DIAL_REACH_DIRECT");
    try emitConst(&b, gpa, "PANCAKE_DIAL_REACH_CONFIGURED");
    try emitConst(&b, gpa, "PANCAKE_DIAL_REACH_EXPLICIT");
    try emitConst(&b, gpa, "PANCAKE_DIAL_POSTURE_REDEEM");
    try emitConst(&b, gpa, "PANCAKE_DIAL_POSTURE_EXPLICIT");
    try emitConst(&b, gpa, "PANCAKE_DIAL_POSTURE_EXPLICIT_NONE");
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
    try emitDoc(&b, gpa,
        \\A resolved accept from pancake_host_plan_accept: what an accepted
        \\session signs as its own locator. Views borrow the caller's input,
        \\except the address-transport empty-address fallback, which is the static
        \\unreachable-client placeholder.
    );
    try E.emitStruct(&b, gpa, Spec.c.PancakeAcceptPlan, "PancakeAcceptPlan", &.{
        "The designator a partner names this listener by.",
        "",
        "The direct-addresses hint a partner dials it at (empty for tcp/iroh).",
        "",
    });
    try b.appendSlice(gpa, "\n");
    try emitDoc(&b, gpa,
        \\Borrowed in-flight pending dial for one ticket (parsed dial parts).
        \\Host-owned views valid until pancake_host_dialed / pancake_host_dial_failed
        \\consumes the row (or host teardown). Empty hint means the give carried none
        \\(hint is NULL, hint_len is 0). Dial authority is transport/designator/hint —
        \\no verbatim URI field.
    );
    try E.emitStruct(&b, gpa, Spec.c.PancakePendingDial, "PancakePendingDial", &.{
        "Parsed transport (always non-empty on a live ticket).",
        "",
        "Parsed designator (always non-empty on a live ticket).",
        "",
        "Direct-addresses hint, or NULL when the give carried none.",
        "",
    });
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "pancake_host_pending_dial", &.{ "host", "ticket", "out" }, "Borrow the in-flight pending dial for ticket into *out\n(transport/designator/hint). Staged once when the give was accepted —\nno re-parse. A live ticket always has non-empty transport/designator\n(unparseable gives never become pending rows); an empty hint means the give\ncarried none (hint is NULL). Unknown ticket returns\nPANCAKE_ERR_INVALID_ARGUMENT. Host-owned views valid until pancake_host_dialed\n/ pancake_host_dial_failed (or host teardown).");
    try emitFn(&b, gpa, "pancake_host_reference_exporter", &.{ "host", "reference", "out_session" }, "Write the live session homing remote reference into *out_session, or NULL for\na local, stale, foreign-Host, or closed-session capability. Bindings compare\nthis result with the sending session after a call: the same session is an\nordinary reply, while another session is the exporter reached through handoff.\nThe answer comes from the reference's own Host row, with no dial-completion\ncapture window. The returned handle is Host-owned and lives with that session;\ndo not release it here.");
    try emitFn(&b, gpa, "pancake_host_plan_dial", &.{ "transport", "transport_len", "designator", "designator_len", "direct_addresses_hint", "direct_addresses_hint_len", "posture_policy", "posture_value", "out_plan" }, "Resolve a dial without opening a socket: the transport dispatch, designator\nvalidation, host:port resolution, and peer-id reachability decision every binding\nused to re-express, done once here. transport/designator are the locator's\npieces (from pancake_host_pending_dial or pancake_uri_parse_peer);\ndirect_addresses_hint is the locator's direct-addresses hint (NULL/0 = none);\nposture_policy is a PANCAKE_DIAL_POSTURE_* choosing the peer-id reachability rule,\nwith posture_value the caller's posture under PANCAKE_DIAL_POSTURE_EXPLICIT.\nOn PANCAKE_OK *out_plan is filled with views borrowing the caller's buffers; a\nbad locator returns PANCAKE_ERR_INVALID_ARGUMENT (pancake_host_last_error\ncarries which). Open the channel the plan names, then feed it to\npancake_host_session_open_dialed_locator.");
    try emitFn(&b, gpa, "pancake_host_plan_accept", &.{ "transport", "transport_len", "server_designator", "server_designator_len", "accepted_local_addr", "accepted_local_addr_len", "out_plan" }, "Resolve what an accepted session signs, without a socket. transport is the\naccepted transport; server_designator is the listener's own signing designator\n(its key for a key transport, unused for an address transport);\naccepted_local_addr is what the accept reported (NULL/0 when unavailable). On\nPANCAKE_OK *out_plan is filled with views borrowing the caller's input, except\nthe address-transport empty-address fallback (the static unreachable-client\nplaceholder). Feed the result to pancake_host_session_open_accepted.");
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "pancake_host_session_release", &.{"session"}, "Release one session: its still-parked far vows break (their FAIL\ncompletions queue inside this call), the node retires it — stranded\nwithdraws fail closed, so SIBLING sessions' vows may break here too — and\nthe shell is freed. NULL is a no-op; refused (last error set, the session\nkept) from inside a callback.");
    try emitFn(&b, gpa, "pancake_host_session_is_open", &.{"session"}, "Nonzero once the keyed handshake has completed and the session is open.");

    try emitFn(&b, gpa, "pancake_host_session_feed", &.{ "session", "frame_in" }, "Feed one inbound frame you read from your own transport (borrowed for the\ncall): behavior callbacks fire and vow completions queue inside, then the\nnode actions the dispatch queued pump and every touched session's\noutbound encodes. A\nfailure classifies through the shared taxonomy (PANCAKE_ERR_CODEC / _SESSION\n/ _INTERNAL); after any failure still drain take_outbound — the peer\nprojected a typed op:abort for the partner — then read\npancake_host_session_last_abort for the typed cause.");
    try emitFn(&b, gpa, "pancake_host_session_feed_bytes", &.{ "session", "bytes", "len" }, "Feed a byte-stream chunk you read from your own transport (borrowed for the\ncall). The library owns framing and the tail: the session's codec delimits\neach complete frame at the front of bytes — both codecs, both frame shapes\n— and dispatches it exactly as pancake_host_session_feed, while a partial\nframe straddling two reads stays buffered in the session, so on success\nevery byte was consumed and you just read and feed. Dispatch also pauses at\nthe frame that completes the keyed handshake: frames coalesced behind the\nhello wait in the session's tail while you act on the fresh session\n(publish, fetch), and your next call — an empty chunk (len 0, bytes may be\nNULL) works — feeds them. A frame exceeding the session's frame cap is\nrefused PANCAKE_ERR_FRAME_TOO_LARGE; any other failure classifies as\npancake_host_session_feed's do. After any failure the session is closing:\ndrain take_outbound (a typed op:abort is queued for the partner) and\nrelease the session.");
    try emitFn(&b, gpa, "pancake_host_session_take_outbound", &.{ "session", "out_frame" }, "Drain one encoded outbound frame as an *owned* managed frame you write to\nyour transport and free through pancake_managed_frame_release. Returns\nPANCAKE_OK with *out_frame set, or PANCAKE_ERR_WOULD_BLOCK (with *out_frame\nuntouched) when the queue is empty. Refused inside a callback.");
    try emitFn(&b, gpa, "pancake_host_next_action", &.{ "host", "out_action" }, "Pop the next embedder action into *out_action, or return\nPANCAKE_ERR_WOULD_BLOCK when none is pending. A DIAL carries only ticket\n(borrow the pending view with pancake_host_pending_dial). A SETTLE's value\nand a FAIL's message are host-owned until the NEXT pancake_host_next_action\ncall, which frees them. Deferred work may return PANCAKE_ERR_INTERNAL under\nallocator pressure before an action is popped; no action or authority is lost,\nand the embedder retries this same drain call when pressure subsides. See the\none loop rule in the header preamble. Refused inside a callback.");
    try emitFn(&b, gpa, "pancake_host_pump_drain", &.{ "host", "hooks", "out_acted" }, "Opt-in convenience drain over pancake_host_next_action (ADR-0072 fifth\namendment). Still pops through the pull-queue internally; does not replace\nit. hooks may be NULL (every action is discarded). *out_acted is 1 when any\narm reported progress (optional, may be NULL). See PancakeHostPumpHooks.");
    try emitFn(&b, gpa, "pancake_host_dialed", &.{ "host", "ticket", "session" }, "Report a DIAL action's success: session is an open_dialed_locator against the\npending dial for ticket (pancake_host_pending_dial), driven to an\nopen session. The host withdraws every give waiting on the ticket; the\nwithdraws, their settles, and their flushes pump inside this call. A stale\nticket is a no-op success.");
    try emitFn(&b, gpa, "pancake_host_dial_failed", &.{ "host", "ticket", "reason", "reason_len" }, "Report a DIAL action's failure: every redeem waiting on the ticket breaks\nwith reason, its FAIL completion queued inside this call. A stale ticket is a\nno-op success.");
    try emitFn(&b, gpa, "pancake_host_provide_gift_id", &.{ "host", "ticket", "gift_id", "gift_id_len" }, "Answer a NEED_GIFT_ID action with 32 caller-drawn random bytes: the host\noriginates the claimed handoff and this call flushes its legs, exporter\nfirst. A stale ticket is a no-op success.");

    try emitFn(&b, gpa, "pancake_host_session_publish", &.{ "session", "name", "name_len", "behavior", "ctx", "free", "out_ref" }, "Publish a hosted object a partner on this session can fetch by name (a\nswiss-number). The Host Vat owns the object; this session selects its first\nPort projection. Releasing that session does not run free. On success, free,\nif non-NULL, runs exactly once at Host teardown; a failed construction runs it\nafter this call takes ownership. *out_ref receives the opaque Host-scoped\ncapability. Refused inside a callback (ctx stays yours on a null-pointer or\nreentry refusal).");
    try emitFn(&b, gpa, "pancake_host_session_spawn", &.{ "session", "behavior", "ctx", "free", "out_ref" }, "Spawn a hosted object in the Host Vat and create its first projection on this\nsession, without a fetchable name. It becomes reachable once a reply or\nargument carries the opaque Host-scoped capability written to *out_ref. Same\nfree contract as pancake_host_session_publish.");
    try emitFn(&b, gpa, "pancake_host_publish", &.{ "host", "name", "name_len", "behavior", "ctx", "free" }, "Publish one hosted object in the Vat owned by this Host and bind name as its\nhost-wide alias. Fetch lazily projects the actor onto the requesting Port; a\ndeposited gift retains the exact actor and never consults the alias at\nwithdrawal. The giftable row owns ctx: free, if non-NULL, runs exactly once, at\npancake_host_release on success or before this returns on any non-OK outcome\n(the null-pointer and reentry refusals touch nothing and leave ctx yours).\nAll-or-nothing over this call's own work: registration failure discards the\nfresh actor and frees ctx, so a retry starts with no partial alias or projection.");

    try emitFn(&b, gpa, "pancake_host_session_fetch", &.{ "session", "name", "name_len", "out_vow" }, "Fetch the partner capability published as name, minting a host vow whose id\nlands in *out_vow; the outcome arrives as that vow's SETTLE or FAIL action.\nA fulfilled far capability settles ALREADY enrolled under a node-unique\ntoken — recorded before the completion is queued, so a reply that\nimmediately re-gifts it routes to the right exporter. Refused inside a\ncallback.");
    try emitFn(&b, gpa, "pancake_host_session_enliven", &.{ "session", "sturdyref_uri", "sturdyref_uri_len", "out_vow" }, "Enliven the complete sturdyref URI (ADR-0098), minting a host vow whose id\nlands in *out_vow; the live reference arrives as that vow's SETTLE action.\nThe URI's transport and designator must match the selected session before\nthe swiss namespace is consulted or wire traffic is emitted. A dedup-cache\nhit settles before this returns; a fresh enliven rides bootstrap-fetch.\nRefused inside a callback.");

    try emitFn(&b, gpa, "pancake_host_session_send", &.{ "session", "target", "verb", "verb_len", "args", "args_len", "out_vow" }, "Eventual-send to an opaque Host-scoped target and mint a host vow for the\nanswer; the outcome arrives as that vow's SETTLE or FAIL action. The Host\nchooses local delivery or the owning exporter session. A target or nested\nargument from another Host, or a retired identity, is refused rather than\nbeing interpreted as a wire position. verb/args are borrowed; the host copies\nwhat it queues. An empty verb — including (NULL, 0), which the family's ptr+len\ncontract admits — is a real message, not an error: it delivers positionally,\nthe way Goblins invokes a capability. Legal inside a callback (the send\nencodes when the enclosing call unwinds).");
    try emitFn(&b, gpa, "pancake_host_session_tell", &.{ "session", "target", "verb", "verb_len", "args", "args_len" }, "Fire-and-forget eventual-send: pancake_host_session_send with no answer and no\nvow. Same routing, refusals, and empty-verb contract.");
    try emitFn(&b, gpa, "pancake_host_vow_send", &.{ "host", "vow", "verb", "verb_len", "args", "args_len", "out_vow" }, "Promise pipelining: eventual-send to a host vow before it resolves, minting a\nnew vow for this call's own answer. A local vow (a NEAR send's answer) has no\nwire answer to pipeline against and is refused PANCAKE_ERR_INVALID_ARGUMENT\n(NotPipelineable); an unknown vow reports PANCAKE_ERR_NOT_FOUND. The\nempty-verb contract is pancake_host_session_send's.");
    try emitFn(&b, gpa, "pancake_host_vow_index", &.{ "host", "vow", "index", "out_vow" }, "Pipeline an op:index projection against a far host vow, minting a new vow for\nthe projected element. Same local-vow and unknown-vow refusals as\npancake_host_vow_send; an index above INT64_MAX is refused\nPANCAKE_ERR_INVALID_ARGUMENT (the wire index is a signed integer).");
    try emitFn(&b, gpa, "pancake_host_vow_untag", &.{ "host", "vow", "tag", "tag_len", "out_vow" }, "Pipeline an op:untag projection against a far host vow, minting a new vow for\nthe unwrapped payload (a single-value Tagged unwraps to that value; a\nvariadic one to its value list). tag is borrowed.");
    try emitFn(&b, gpa, "pancake_host_vow_get", &.{ "host", "vow", "field", "field_len", "out_vow" }, "Pipeline an op:get projection against a far host vow, minting a new vow for\nthe named Struct field. Same local-vow and unknown-vow refusals as\npancake_host_vow_send; field is borrowed.");

    try emitFn(&b, gpa, "pancake_host_turn_forward", &.{ "turn", "target", "verb", "verb_len", "args", "args_len", "out_reply" }, "From inside a behavior callback, forward this turn's call to an opaque\nHost-scoped target and let this object's own answer settle on the forwarded\nresult — the caretaker/attenuator primitive. The Host resolves the target and\nevery nested capability; a stale or foreign-Host identity is refused. In a\nwire-served turn the real answer rides the forwarded vow and *out_reply gets a\nvoid placeholder; pass your behavior's own out_reply and return PANCAKE_OK.\nThe written reply is BORROWED — valid until the next turn verb or drive on\nthis host. The empty-verb contract is pancake_host_session_send's.");
    try emitFn(&b, gpa, "pancake_host_turn_send", &.{ "turn", "target", "verb", "verb_len", "args", "args_len", "out_vow" }, "From inside a behavior callback, eventual-send to target and mint a host vow\nfor the answer — the same routing, refusals, and empty-verb contract as\npancake_host_session_send, on the turn's own session. The send encodes when the\nenclosing top-level call unwinds.");
    try emitFn(&b, gpa, "pancake_host_turn_tell", &.{ "turn", "target", "verb", "verb_len", "args", "args_len" }, "From inside a behavior callback, fire-and-forget eventual-send —\npancake_host_turn_send with no answer and no vow. Same empty-verb contract.");
    try emitFn(&b, gpa, "pancake_host_turn_spawn", &.{ "turn", "behavior", "ctx", "free", "out_ref" }, "From inside a behavior callback, spawn a hosted object in the Host Vat and\ncreate its first projection on the Port that delivered this turn. This is how a\nserved factory mints a capability it replies with (a task board's create, a\ncaretaker wrapping a target), the turn-time form of\npancake_host_session_spawn. Same free contract; *out_ref receives the opaque\nHost-scoped capability, ready to ride this turn's own reply.");
    try emitFn(&b, gpa, "pancake_host_turn_break", &.{ "turn", "message", "message_len" }, "From inside a behavior callback, break this turn's own answer with message —\nhow a behavior refuses with a diagnostic, since a non-OK return settles the\nanswer broken with only a generic reason. The answer resolves broken inside\nthis call (a no-answer tell breaks nothing); leave out_reply untouched and\nreturn PANCAKE_OK from the behavior, whose return value then resolves\nnothing. message is borrowed and copied.");

    try emitFn(&b, gpa, "pancake_host_ref_release", &.{ "host", "ref", "delta" }, "Release delta application retains on one opaque Host capability. The Host\nresolves the owning session and emits any required op:gc-exports itself; the\ncaller never pairs a capability with a session-local wire position. A stale or\nforeign-Host identity is refused. Single-thread affinity applies: never call\nthis from a finalizer thread.");
    try emitFn(&b, gpa, "pancake_host_session_published_ref", &.{ "session", "name", "name_len", "out_ref" }, "Write to *out_ref the opaque Host-scoped capability currently published under\nname, or return PANCAKE_ERR_NOT_FOUND when the Host has no such alias. The actor\nin the Host-owned Vat is lazily projected onto session when needed; the\nreturned identity itself carries no export position and retains no name.");
    try emitFn(&b, gpa, "pancake_host_session_break_far_vows", &.{ "session", "message", "message_len" }, "Break every far vow still parked on session, queueing each vow's FAIL\ncompletion inside this call — with the partner's retained abort diagnostic\nwhen one arrived, else message. Call it when your transport reports the\nconnection gone.");
    try emitFn(&b, gpa, "pancake_host_session_set_exporter_location", &.{ "session", "locator", "locator_len" }, "Record the exporter locator to embed in gives whose exporter is\nsession, overriding the session record; empty clears the override. locator is\na borrowed Syrup <ocapn-peer> record (the bytes\npancake_locator_record_encode returns); a URI or other non-record spelling\nfails with PANCAKE_ERR_INVALID_ARGUMENT.");
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
    });
    try b.appendSlice(gpa, "\n");
    try emitFn(&b, gpa, "pancake_host_session_partner_identity", &.{ "session", "out" }, "Borrow this session's verified partner identity into *out: the partner's\nsession public key, the location designator it signed, and the verbatim\nlocation record those came from.\n\nA PANCAKE_OK return always means the signature was checked. Before the\npartner's op:start-session has arrived with a key this returns\nPANCAKE_ERR_WOULD_BLOCK, and a session opened without partner verification\nreturns PANCAKE_ERR_SESSION rather than an identity nothing proved. That\nrefusal is the contract: you cannot read an unverified identity through this\nentry point, so you never have to remember to ask whether the bytes were\nchecked.");
    try emitFn(&b, gpa, "pancake_host_session_partner_designator_is_key", &.{ "session", "out_matches" }, "Nonzero into *out_matches when this session's partner proved it owns the\ndesignator it advertised, meaning the designator is exactly its verified\nsession key in canonical hex.\n\nThis is here so no binding re-derives that comparison. It answers only for a\nkey-designator transport (keyed-tcp, iroh, webrtc, keyed-relay); an address\ntransport such as tcp names a socket address the key does not determine, so\nthe answer is zero there, and zero is correct rather than a failure. The\nrefusals are pancake_host_session_partner_identity's, and *out_matches is\nleft untouched on any of them.");

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
