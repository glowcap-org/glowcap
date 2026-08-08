//! The byte-fed host tier's public C ABI — `libpancake_host` (ADR-0072).
//!
//! One `PancakeHost` is the multi-session CapTP **host** for an embedder that
//! owns its own loop, sockets, and entropy: it wraps `driver_core.Host`, so
//! everything the node decides — where a token routes, which exporter a give
//! withdraws from, when a served reply becomes a signed give — runs inside the
//! library, and the embedder's whole job is moving bytes and answering the
//! action queue. Inbound frames enter through `pancake_host_session_feed`,
//! outbound frames leave through `pancake_host_session_take_outbound`, and the
//! host's own effects (dial an exporter, draw gift-id entropy, flush a
//! session) surface as `PancakeHostAction`s the embedder drains with
//! `pancake_host_next_action` and answers with `pancake_host_dialed` /
//! `pancake_host_dial_failed` / `pancake_host_provide_gift_id`. Settlements
//! ride the same queue: a vow's outcome pops as a `SETTLE` or `FAIL` action
//! whose `ticket` is the vow id, so one drain routes every outcome and there
//! is no listener to register before the bytes that settle it.
//!
//! One thread (or one green-thread scheduler) drives one host; nothing here
//! locks. The one callback — a behavior answering a deliver — fires on the
//! thread executing the enclosing `pancake_host_*` call. Inside it the
//! enqueueing verbs are legal (send/tell, vow verbs, turn verbs, gc release,
//! exporter location) and are encoded and pumped when the enclosing call
//! unwinds; the host-driving verbs (feed, feed_bytes, take_outbound,
//! next_action, the dial/gift completions, open, publish/spawn,
//! fetch/enliven, break_far_vows, release) are refused with
//! `PANCAKE_ERR_INVALID_ARGUMENT`.
//!
//! This is a *separate archive* from `libpancake_ocapn` (ADR-0059): it imports
//! the shared vocabulary leaf (`c_abi_shared` — frame/argument types, codes,
//! allocation, the per-thread last-error slot) plus the `driver_core` and
//! `actors` layers it bridges, so it exports only the `pancake_host_*` family
//! and shares no core symbol with the ocapn archive. The family reads for its
//! entry type `Host` while the archive is named for its Zig module, the same
//! divergence `libpancake_net_transport_tcp` carries toward `pancake_tcp_*`. A
//! consumer links this alongside `libpancake_ocapn` and reuses the shared
//! value types by layout. The archive carries its own last-error slot, read
//! through `pancake_host_last_error`.
//!
//! This file is the archive root, the way `src/c_abi/ocapn/mod.zig` is: it owns
//! the public C vocabulary (the opaque handles, the action and dial-plan
//! structs, the callback typedefs, and the discriminant constants) and
//! re-exports the `pancake_host_*` exports that live in the handle-family
//! leaves, so the header generator and the binding mirrors see the whole ABI
//! from one place. The exports themselves are split by responsibility:
//! `host.zig` owns host lifecycle, the pure dial/accept planners, the action
//! queue, host-wide publish, GC, and the last-error slot; `session.zig` owns
//! the per-session verbs (open, the byte pump, publish/spawn, fetch/enliven,
//! send/tell/vows, and the abort diagnostics); `turn.zig` owns the turn-time
//! verbs; `pump.zig` owns the optional `pancake_host_pump_drain` convenience;
//! and `common.zig` holds the internal glue those leaves share (the `Instance`
//! state, the behavior bridge, marshalling, and the error projection).

const engine = @import("engine");
const model = @import("model");

// The shared C-ABI vocabulary leaf — types, codes, allocation, the last-error
// slot — not the ocapn root, so this archive pulls none of the ocapn family's
// exports (ADR-0059 companion split).
const shared = @import("c_abi_shared");

const host = @import("host.zig");
const session = @import("session.zig");
const turn = @import("turn.zig");
const pump = @import("pump.zig");
const common = @import("common.zig");

/// Zig-only seams for exercising C-boundary transactions without exporting
/// another ABI symbol. Production consumers cannot name this through a header.
pub const testing = struct {
    pub fn importObject(raw: ?*PancakeHostSession, position: u64) !void {
        const session_ptr = common.connFrom(raw) orelse return error.NullPointer;
        try session_ptr.served.port.peer.importObject(position);
    }

    pub fn projectArgs(
        host_handle: ?*PancakeHost,
        raw: ?*PancakeHostSession,
        allocator: @import("std").mem.Allocator,
        args: []const model.Argument,
    ) !void {
        const inst = common.instanceFrom(host_handle) orelse return error.NullPointer;
        const session_ptr = common.connFrom(raw) orelse return error.NullPointer;
        _ = try common.hostArgsToC(inst, session_ptr, allocator, args);
    }

    pub fn liveCapabilityCount(host_handle: ?*PancakeHost) !usize {
        const inst = common.instanceFrom(host_handle) orelse return error.NullPointer;
        return inst.core.capabilities.liveCount();
    }

    pub fn importRefcount(raw: ?*PancakeHostSession, position: u64) !u64 {
        const session_ptr = common.connFrom(raw) orelse return error.NullPointer;
        return session_ptr.served.port.peer.session_state.importRefcount(.from(position));
    }
};

// ── Shared value vocabulary (by layout, from c_abi_shared) ────────────────────

/// The allocation context (`pancake_host_new_in`), shared with
/// `libpancake_ocapn` by layout.
pub const PancakeContext = shared.PancakeContext;

// ── Handles ──────────────────────────────────────────────────────────────────

/// A byte-fed multi-session CapTP host: one identity, one routing/redeem
/// authority, many sessions. Created with `pancake_host_new`; released with
/// `pancake_host_release`.
/// The structs the wasm32 layout descriptor reports and the TypeScript
/// mirror's `WASM_LAYOUT_STRUCTS` manifest names, in one canonical order.
/// This table is the single authority both consumers read — the wasm
/// module's `pancake_wasm_abi_layout` walks it to emit offsets, and
/// `tools/gen/binding/ts_abi.zig` walks it to emit the manifest — so a
/// struct added to the ABI cannot reach one mirror and miss the other
/// (the drift that once shipped a page demanding a layout the wasm
/// module didn't carry). Append-only: a new struct is one new row at
/// the end; it never renumbers an earlier index a JS decoder holds.
pub const WasmLayoutSpec = struct {
    /// Constant prefix in the mirrors (`<prefix>_SIZE`,
    /// `<prefix>_<FIELD>_OFF`) and the string the descriptor's
    /// name-hash word is computed from.
    prefix: []const u8,
    T: type,
};

pub const wasm_layout_manifest = [_]WasmLayoutSpec{
    .{ .prefix = "MANAGED_FRAME", .T = shared.PancakeManagedFrame },
    .{ .prefix = "REF", .T = shared.PancakeReference },
    .{ .prefix = "ARG", .T = shared.PancakeArgument },
    .{ .prefix = "FRAME", .T = shared.PancakeFrame },
    .{ .prefix = "LAST_ABORT", .T = shared.PancakeLastAbort },
    .{ .prefix = "ALLOCATOR", .T = shared.PancakeAllocator },
    .{ .prefix = "HOST_ACTION", .T = PancakeHostAction },
    .{ .prefix = "HOST_PUMP_HOOKS", .T = PancakeHostPumpHooks },
    .{ .prefix = "DIAL_PLAN", .T = PancakeDialPlan },
    .{ .prefix = "ACCEPT_PLAN", .T = PancakeAcceptPlan },
    .{ .prefix = "PENDING_DIAL", .T = PancakePendingDial },
    .{ .prefix = "PARTNER_IDENTITY", .T = PancakePartnerIdentity },
    .{ .prefix = "TRACE_EVENT", .T = PancakeTraceEvent },
};

pub const PancakeHost = opaque {};

/// One byte-fed CapTP session a host minted (`pancake_host_session_open_dialed_locator` /
/// `pancake_host_session_open_accepted`). Released with
/// `pancake_host_session_release`, always before its host.
pub const PancakeHostSession = opaque {};

/// The current turn, passed to a behavior callback so it can forward and
/// eventual-send while handling a deliver (`pancake_host_turn_*`). Valid only
/// for the duration of that callback: stashing the pointer and using it after
/// the callback returns is undefined behavior.
pub const PancakeHostTurn = opaque {};

// ── Action queue vocabulary ──────────────────────────────────────────────────

/// `PancakeHostAction.kind`: dial the exporter named by `ticket` (borrow the
/// pending view with `pancake_host_pending_dial`) and report back through
/// `pancake_host_dialed` / `pancake_host_dial_failed`.
pub const PANCAKE_HOST_ACTION_DIAL: u32 = 0;
/// `PancakeHostAction.kind`: outbound frames may be ready on `session`; drain
/// `pancake_host_session_take_outbound` until WOULD_BLOCK and write them.
pub const PANCAKE_HOST_ACTION_FLUSH: u32 = 1;
/// `PancakeHostAction.kind`: draw 32 random bytes and feed them back through
/// `pancake_host_provide_gift_id` with this action's `ticket`.
pub const PANCAKE_HOST_ACTION_NEED_GIFT_ID: u32 = 2;
/// `PancakeHostAction.kind`: the vow `ticket` names settled fulfilled with
/// `value`; route the outcome to whatever awaits that vow.
pub const PANCAKE_HOST_ACTION_SETTLE: u32 = 3;
/// `PancakeHostAction.kind`: the vow `ticket` names settled broken with
/// `message`; route the outcome to whatever awaits that vow.
pub const PANCAKE_HOST_ACTION_FAIL: u32 = 4;
/// `PancakeHostAction.kind`: the host retired `session`. Drain and write any
/// queued terminal frame, then close its transport and release the connection.
/// A condemned session carries an abort; redeem-only cleanup closes quietly.
pub const PANCAKE_HOST_ACTION_CLOSE: u32 = 5;

/// Default maximum admissible frame for a host connection, mirroring
/// `session.SessionLimits.max_frame_bytes` (1 MiB). Bindings pass this to
/// `pancake_host_new` / `pancake_host_new_in` unless the embedder overrides.
pub const PANCAKE_DEFAULT_FRAME_CAP: usize = (engine.SessionLimits{}).max_frame_bytes;

/// How long a binding's establish waits for a partner's `op:start-session`
/// before abandoning the half-built connection.
///
/// It lives here because it is one product decision, not four. A peer that
/// opens a byte channel and then says nothing is the case no failure check
/// catches: nothing fails, the handshake simply waits, so unbounded it parks
/// the dialer forever and, on an accepting side, every later connection behind
/// it. Each binding used to carry its own copy of this number, which is a
/// promise about how long a caller waits made in four places at once.
pub const PANCAKE_HANDSHAKE_TIMEOUT_MS: u64 = 10_000;

/// Discovery-posture dial retry interval (ms). Keep lockstep with
/// `driver.discovery_retry_ms` (ADR-0082); `test/driver` pins the pair.
pub const PANCAKE_DISCOVERY_DIAL_RETRY_MS: u64 = 3_000;
/// Discovery-posture dial attempt budget. Keep lockstep with
/// `driver.discovery_max_attempts` (ADR-0082).
pub const PANCAKE_DISCOVERY_DIAL_MAX_ATTEMPTS: u32 = 24;

/// Bound on one turn's synchronous local `Forward` chase (caretaker over
/// attenuator). Hop N+1 breaks the answer instead of spinning; the wire path
/// defers each hop onto a fresh turn so it needs no matching cap. Mirrored by
/// every binding's trampoline / vat.
pub const PANCAKE_MAX_LOCAL_FORWARD_HOPS: usize = 256;

/// One embedder effect popped from `pancake_host_next_action`. `kind` selects
/// the live fields: DIAL carries only `ticket` (borrow the pending view with
/// `pancake_host_pending_dial`). FLUSH and CLOSE carry `session`;
/// NEED_GIFT_ID carries `ticket`. SETTLE carries the settled vow id in
/// `ticket` and the fulfilled value in `value`; FAIL carries the vow id in
/// `ticket` and the break reason in `message`/`message_len`. Every popped byte
/// view and `value`'s sub-structure are host-owned and valid until the next
/// `pancake_host_next_action` call, which frees them. Unused fields are zeroed.
pub const PancakeHostAction = extern struct {
    kind: u32,
    ticket: u64,
    session: ?*PancakeHostSession,
    value: shared.PancakeArgument,
    message: ?[*]const u8,
    message_len: usize,
};

/// One shared arm callback for `PancakeHostPumpHooks`: flush, close,
/// need_gift_id, complete (SETTLE/FAIL), and dial. Return `PANCAKE_OK` or a
/// real `PANCAKE_ERR_*`. When `out_progressed` is non-null, set it to 1 if the
/// arm counts as quiescence progress (gift-id answered, dial parked, settle
/// routed); leave 0 for a handled notice that a sibling shuttle already
/// covers (typical empty FLUSH). `action` views are host-owned until the next
/// `pancake_host_next_action` (this drain pops internally).
pub const PancakeHostPumpArmFn = *const fn (
    ctx: ?*anyopaque,
    host: ?*PancakeHost,
    action: *const PancakeHostAction,
    out_progressed: ?*u32,
) callconv(.c) i32;

/// Opt-in embedder hooks for `pancake_host_pump_drain` (ADR-0072 fifth
/// amendment). NULL arm pointers skip that kind (no error, no progress). The
/// pull-queue remains normative — this struct is a convenience wrapper's
/// callback surface, not a replacement for `pancake_host_next_action`.
pub const PancakeHostPumpHooks = extern struct {
    ctx: ?*anyopaque,
    flush: ?PancakeHostPumpArmFn,
    close: ?PancakeHostPumpArmFn,
    need_gift_id: ?PancakeHostPumpArmFn,
    complete: ?PancakeHostPumpArmFn,
    dial: ?PancakeHostPumpArmFn,
};

// ── Callbacks ────────────────────────────────────────────────────────────────

/// A hosted object's behavior, invoked on each deliver. `verb`/`args` are
/// borrowed for the call; each `PancakeReference` leaf is nevertheless one
/// application retain and must eventually be returned with
/// `pancake_host_ref_release`. Copying its `{ id }` bytes does not create
/// another retain. The vat copies
/// `out_reply`'s payload the instant the callback returns, so its bytes must
/// stay valid across the return (point them at your `ctx` or a buffer you own,
/// not a callback stack local). Any non-OK return settles the answer broken
/// with a generic reason. Inside the callback the enqueueing host verbs and
/// the `pancake_host_turn_*` verbs (with this `turn` only) are legal; the
/// host-driving verbs are refused.
pub const PancakeHostBehavior = *const fn (
    ctx: ?*anyopaque,
    turn: ?*PancakeHostTurn,
    verb: [*]const u8,
    verb_len: usize,
    args: ?[*]const shared.PancakeArgument,
    args_len: usize,
    out_reply: *shared.PancakeArgument,
) callconv(.c) i32;

/// Release a hosted object's `ctx` when the object is torn down. Null when
/// the consumer keeps ownership of `ctx`. Must call no `pancake_host_*`
/// function.
pub const PancakeHostCtxFree = *const fn (ctx: ?*anyopaque) callconv(.c) void;

// ── Live trace vocabulary ─────────────────────────────────────────────────────

/// One reported trace fact (`pancake_host_set_trace`). The kind selects the
/// live fields; string views are borrowed for the callback only.
pub const PANCAKE_TRACE_SESSION_OPEN: u32 = 0;
pub const PANCAKE_TRACE_MESSAGE: u32 = 1;
pub const PANCAKE_TRACE_SESSION_CLOSE: u32 = 2;

pub const PancakeTraceEvent = extern struct {
    /// A `PANCAKE_TRACE_*` value.
    kind: u32,
    /// The session the fact is about, stable for the session's life.
    session: u64,
    /// `PANCAKE_TRACE_MESSAGE`: nonzero when the message left this host.
    outbound: u8,
    /// `PANCAKE_TRACE_SESSION_OPEN`: what proved the partner's durable name,
    /// as a `PANCAKE_DURABLE_PROVENANCE_*` value — the same fact
    /// `pancake_host_session_partner_identity` reports, not a second
    /// spelling of it. A consumer that only asked "was it proved" cannot
    /// tell a partner claiming no durable name from one whose claim nothing
    /// on its path was able to prove.
    provenance: u32,
    /// `PANCAKE_TRACE_SESSION_OPEN`: the negotiated `PANCAKE_CODEC_*`, or
    /// `PANCAKE_CODEC_UNKNOWN` when the session uses a codec this C ABI family
    /// does not name.
    codec: u32,
    /// `PANCAKE_TRACE_SESSION_OPEN`: the negotiated `PANCAKE_CAPTP_*`.
    captp_version: u32,
    /// `PANCAKE_TRACE_SESSION_OPEN`: the partner's OCapN Designator —
    /// dialed, or claimed by its hello. Borrowed.
    ///
    /// Half a name on its own. OCapN requires a designator and a transport
    /// together to tell two locations apart, so the same key reached over
    /// `iroh` and over `keyed-relay` is two locators — and which one
    /// carried the session decides how the name could have been proved.
    designator: ?[*]const u8,
    designator_len: usize,
    /// `PANCAKE_TRACE_SESSION_OPEN`: the netlayer transport symbol this
    /// session runs over (`tcp`, `keyed-tcp`, `keyed-relay`, `iroh`,
    /// `webrtc`, `inproc`). Borrowed.
    transport: ?[*]const u8,
    transport_len: usize,
    /// `PANCAKE_TRACE_SESSION_OPEN`: the OCapN Session ID, 64 lowercase hex
    /// digits, which BOTH peers of this session derive to the same value.
    /// Empty when the partner sent no session key. Borrowed.
    ///
    /// Not `session` above: that is this host's own handle and means
    /// nothing to anyone else, while this is the name the two ends agree
    /// on and the only one that merges two producers' feeds.
    session_id: ?[*]const u8,
    session_id_len: usize,
    /// `PANCAKE_TRACE_MESSAGE`: the deliver's verb. Borrowed.
    verb: ?[*]const u8,
    verb_len: usize,
    /// `PANCAKE_TRACE_MESSAGE`: the message's wire frame, borrowed. Both
    /// directions carry it — the fact sites sit at the wire boundary
    /// (inbound dispatch, the outbound drain).
    frame: ?[*]const u8,
    frame_len: usize,
    /// `PANCAKE_TRACE_MESSAGE`: how long the frame really was. Equal to
    /// `frame_len` on the callback seam, which borrows the frame where it
    /// sits; larger when a queued record clipped the frame to its payload
    /// window (`pancake_host_set_trace_queue`).
    frame_total_len: usize,
    /// Records the host dropped between the previous record and this one.
    /// Always zero on the callback seam, which drops nothing; a queued
    /// record reports the gap its ring could not hold.
    dropped: u64,
    /// `PANCAKE_TRACE_MESSAGE`: a tag over the frame's bytes, naming this one
    /// message across the two peers that carried it. One frame crosses one
    /// wire, so both ends derive the same tag from the bytes they hold,
    /// without coordinating and without either of them retaining anything.
    /// A consumer merging two observers of one session folds their two
    /// sightings of a message into one on this. Zero on the other kinds.
    digest: [PANCAKE_TRACE_DIGEST_BYTES]u8,
};

/// Width of `PancakeTraceEvent.digest`. 128 bits: the tag separates the
/// messages of one session from each other, so the birthday bound that
/// matters is over one session's own traffic rather than over every message
/// a consumer ever sees.
pub const PANCAKE_TRACE_DIGEST_BYTES: usize = 16;

/// The trace callback: called synchronously at the fact site, on the host's
/// one thread, with `event` and its views borrowed for the call. Must call no
/// host-driving verb.
pub const PancakeTraceCallback = *const fn (
    ctx: ?*anyopaque,
    event: *const PancakeTraceEvent,
) callconv(.c) void;

// ── Dial / accept planning vocabulary ─────────────────────────────────────────

/// PancakeDialPlan.shape: open a TCP socket to host:port (tcp, keyed-tcp).
pub const PANCAKE_DIAL_SHAPE_HOST_PORT: u32 = 0;
/// PancakeDialPlan.shape: peer-id open (node-id designator + addresses + reach).
/// Today produced only by the `iroh` locator scheme; the tag names the open
/// shape, not the netlayer archive.
pub const PANCAKE_DIAL_SHAPE_PEER_ID: u32 = 1;
/// PancakeDialPlan.shape: signaling-mediated open (webrtc). No dialable address;
/// the channel comes up through an offer/answer/ICE exchange before the keyed
/// handshake. The signaling reference arrives through the handoff mechanism
/// (ADR-0089 phase 5).
pub const PANCAKE_DIAL_SHAPE_SIGNALING: u32 = 2;
/// PancakeDialPlan.shape: rendezvous-bridged open (keyed-relay). No dialable
/// address; the peer holds an inbound socket at a relay under its key
/// designator, and the dialer opens the relay rendezvous leg its host is
/// configured for (ADR-0088).
pub const PANCAKE_DIAL_SHAPE_RENDEZVOUS: u32 = 3;

/// PancakeDialPlan.reach_kind (peer-id shape): the relay-less direct posture.
pub const PANCAKE_DIAL_REACH_DIRECT: u32 = 0;
/// PancakeDialPlan.reach_kind (peer-id shape): the node's own configured redeem posture.
pub const PANCAKE_DIAL_REACH_CONFIGURED: u32 = 1;
/// PancakeDialPlan.reach_kind (peer-id shape): the caller posture in reach_value.
pub const PANCAKE_DIAL_REACH_EXPLICIT: u32 = 2;

/// pancake_host_plan_dial posture_policy: a redeem (a DIAL action) — direct when
/// a hint is present, else the node's configured posture. posture_value ignored.
pub const PANCAKE_DIAL_POSTURE_REDEEM: u32 = 0;
/// pancake_host_plan_dial posture_policy: a connect with a posture in posture_value.
pub const PANCAKE_DIAL_POSTURE_EXPLICIT: u32 = 1;
/// pancake_host_plan_dial posture_policy: a connect that named no posture; a
/// peer-id dial refuses PANCAKE_ERR_INVALID_ARGUMENT (a posture is required).
pub const PANCAKE_DIAL_POSTURE_EXPLICIT_NONE: u32 = 2;

/// Borrowed in-flight pending dial for one ticket (parsed dial parts).
/// Host-owned views valid until `pancake_host_dialed` / `pancake_host_dial_failed`
/// consumes the row (or host teardown). Empty hint means the give carried none
/// (`hint` is NULL, `hint_len` is 0). Dial authority is transport/designator/hint
/// — no verbatim URI field.
pub const PancakePendingDial = extern struct {
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    hint: ?[*]const u8,
    hint_len: usize,
};

/// A resolved dial: what byte channel to open and how. shape selects the live
/// fields. Every view borrows the caller's transport/designator/hint input, so
/// the plan is valid only while those buffers are.
pub const PancakeDialPlan = extern struct {
    shape: u32,
    host: ?[*]const u8,
    host_len: usize,
    port: u16,
    addresses: ?[*]const u8,
    addresses_len: usize,
    reach_kind: u32,
    reach_value: u32,
};

/// The partner identity this session's handshake proved: the partner's session
/// public key, the location designator it signed, and the verbatim
/// `<ocapn-peer …>` record those came from.
///
/// This answers "who am I talking to" without taking the partner's word for it.
/// A keyed `op:start-session` carries an Ed25519 signature over the partner's
/// own `<my-location …>` record, and the engine verifies that signature before
/// the session opens and before any of these bytes are learned. The signed span
/// covers the whole location record, so `designator` is bound to `session_key`
/// by the same signature. An application can require that a locator a caller
/// *claims* names the key that caller actually proved, and refuse a mismatch.
///
/// Views are session-owned. The bytes live in the session's key arena, are
/// written once when the partner's handshake half arrives, and are never
/// rewritten. They stay valid until `pancake_host_session_release`, or until the
/// host is torn down. `session_key` is always present when the read returns
/// `PANCAKE_OK`. `designator` and `locator_record` are NULL when the partner's
/// signed location carried no designator, or when the apply path captured no
/// verbatim record.
pub const PancakePartnerIdentity = extern struct {
    session_key: ?[*]const u8,
    session_key_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    locator_record: ?[*]const u8,
    locator_record_len: usize,
    /// How the durable identity in `designator` was authenticated, one of the
    /// `PANCAKE_DURABLE_PROVENANCE_*` values. It is derived from the evidence
    /// this one session holds, never from its transport's name (ADR-0105), so
    /// two sessions on the same transport can answer differently.
    ///
    /// Session identity, durable identity, and this provenance are three
    /// separate facts: a caller that requires a proved durable peer reads
    /// this, never a comparison of `designator` against `session_key`. Each
    /// connection draws its own session key, so a session key is not an
    /// identity and the two never match.
    provenance: u32,
};

/// A lower layer proved the partner holds the durable key it claims, and that
/// key names the far end of the byte channel this session runs over, so the
/// partner and the endpoint this session is encrypted to are one node.
pub const PANCAKE_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT: u32 = 0;
/// Nothing proved the name. A partner that claimed no durable identity at all
/// lands here too, having no identity to have authenticated.
pub const PANCAKE_DURABLE_PROVENANCE_UNAUTHENTICATED: u32 = 1;

/// What an accepted session signs as its own locator: the designator a
/// partner names it by, and the direct-addresses hint. Views borrow the caller's
/// server_designator / accepted_local_addr, except the address-transport
/// empty-address fallback, which is the static unreachable-client placeholder.
pub const PancakeAcceptPlan = extern struct {
    designator: ?[*]const u8,
    designator_len: usize,
    direct_addresses_hint: ?[*]const u8,
    direct_addresses_hint_len: usize,
};

// ── Handle-family re-exports ─────────────────────────────────────────────────
//
// The `export fn`s below live in the handle-family leaves; the plain `@import`s
// above already compile them into the library. These re-exports also surface
// them as members of the `c_abi_host` namespace so `tools/gen/header/host.zig`
// (which reflects over the module root) and the binding mirrors see the full ABI
// from one place.

pub const pancake_host_new = host.pancake_host_new;
pub const pancake_host_new_in = host.pancake_host_new_in;
pub const pancake_host_release = host.pancake_host_release;
pub const pancake_host_designator_from_seed = host.pancake_host_designator_from_seed;
pub const pancake_host_set_self_designator = host.pancake_host_set_self_designator;
pub const pancake_host_set_advertised_locator = host.pancake_host_set_advertised_locator;
pub const pancake_host_ensure_advertised_locator = host.pancake_host_ensure_advertised_locator;
pub const pancake_host_remove_advertised_locator = host.pancake_host_remove_advertised_locator;
pub const pancake_host_set_session_limits = host.pancake_host_set_session_limits;
pub const pancake_host_plan_dial = host.pancake_host_plan_dial;
pub const pancake_host_pending_dial = host.pancake_host_pending_dial;
pub const pancake_host_reference_exporter = host.pancake_host_reference_exporter;
pub const pancake_host_plan_accept = host.pancake_host_plan_accept;
pub const pancake_host_next_action = host.pancake_host_next_action;
pub const pancake_host_dialed = host.pancake_host_dialed;
pub const pancake_host_dial_failed = host.pancake_host_dial_failed;
pub const pancake_host_provide_gift_id = host.pancake_host_provide_gift_id;
pub const pancake_host_publish = host.pancake_host_publish;
pub const pancake_host_unpublish = host.pancake_host_unpublish;
pub const pancake_host_publish_durable = host.pancake_host_publish_durable;
pub const pancake_host_remove_durable = host.pancake_host_remove_durable;
pub const pancake_host_ref_release = host.pancake_host_ref_release;
pub const pancake_host_last_error = host.pancake_host_last_error;
pub const pancake_host_clear_last_error = host.pancake_host_clear_last_error;

pub const pancake_host_session_open_dialed_locator = session.pancake_host_session_open_dialed_locator;
pub const pancake_host_session_open_accepted = session.pancake_host_session_open_accepted;
pub const pancake_host_session_release = session.pancake_host_session_release;
pub const pancake_host_session_is_open = session.pancake_host_session_is_open;
pub const pancake_host_session_trace_id = session.pancake_host_session_trace_id;
pub const pancake_host_session_feed = session.pancake_host_session_feed;
pub const pancake_host_session_feed_bytes = session.pancake_host_session_feed_bytes;
pub const pancake_host_session_take_outbound = session.pancake_host_session_take_outbound;
pub const pancake_host_session_publish = session.pancake_host_session_publish;
pub const pancake_host_session_spawn = session.pancake_host_session_spawn;
pub const pancake_host_session_fetch = session.pancake_host_session_fetch;
pub const pancake_host_session_enliven = session.pancake_host_session_enliven;
pub const pancake_host_enliven = host.pancake_host_enliven;
pub const pancake_host_set_trace = host.pancake_host_set_trace;
pub const pancake_host_set_trace_queue = host.pancake_host_set_trace_queue;
pub const pancake_host_next_trace = host.pancake_host_next_trace;
pub const pancake_host_spawn_resolver = host.pancake_host_spawn_resolver;
pub const pancake_host_resolver_fulfill = host.pancake_host_resolver_fulfill;
pub const pancake_host_resolver_break = host.pancake_host_resolver_break;
pub const pancake_host_session_listen = session.pancake_host_session_listen;
pub const pancake_host_session_send = session.pancake_host_session_send;
pub const pancake_host_session_tell = session.pancake_host_session_tell;
pub const pancake_host_vow_send = session.pancake_host_vow_send;
pub const pancake_host_vow_index = session.pancake_host_vow_index;
pub const pancake_host_vow_untag = session.pancake_host_vow_untag;
pub const pancake_host_vow_get = session.pancake_host_vow_get;
pub const pancake_host_session_published_ref = session.pancake_host_session_published_ref;
pub const pancake_host_session_break_far_vows = session.pancake_host_session_break_far_vows;
pub const pancake_host_session_set_exporter_location = session.pancake_host_session_set_exporter_location;
pub const pancake_host_session_last_abort = session.pancake_host_session_last_abort;
pub const pancake_host_session_partner_abort = session.pancake_host_session_partner_abort;
pub const pancake_host_session_partner_identity = session.pancake_host_session_partner_identity;
pub const pancake_host_session_bind_verified_channel_key = session.pancake_host_session_bind_verified_channel_key;

pub const pancake_host_turn_forward = turn.pancake_host_turn_forward;
pub const pancake_host_turn_forward_vow = turn.pancake_host_turn_forward_vow;
pub const pancake_host_turn_send = turn.pancake_host_turn_send;
pub const pancake_host_turn_tell = turn.pancake_host_turn_tell;
pub const pancake_host_turn_spawn = turn.pancake_host_turn_spawn;
pub const pancake_host_turn_break = turn.pancake_host_turn_break;

pub const pancake_host_pump_drain = pump.pancake_host_pump_drain;

/// The annotated symbol inventory (crossing semantics per export) the
/// binding FFI-table generators reflect from — see `symbols.zig`.
pub const symbols = @import("symbols.zig");

/// Zig-facing one-loop drain helpers over `pancake_host_next_action`
/// (ADR-0072 fifth amendment). Not a C export — the pull-queue stays
/// normative; bindings and tests thin onto this instead of hand-rolling
/// the action switch.
pub const embedder_pump = @import("embedder_pump.zig");

comptime {
    // Force the family leaves' `export fn`s into the compilation even if the
    // re-exports above are ever pruned; a plain reference is enough.
    _ = host;
    _ = session;
    _ = turn;
    _ = pump;
    _ = common;
}
