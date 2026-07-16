//! The byte-fed host tier's public C ABI — `libpancake_driver` (ADR-0072).
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
//! divergence `libpancake_net_transport_tcp` → `pancake_tcp_*` carries. A
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

// The shared C-ABI vocabulary leaf — types, codes, allocation, the last-error
// slot — not the ocapn root, so this archive pulls none of the ocapn family's
// exports (ADR-0059 companion split).
const shared = @import("c_abi_shared");

const host = @import("host.zig");
const session = @import("session.zig");
const turn = @import("turn.zig");
const pump = @import("pump.zig");
const common = @import("common.zig");

// ── Shared value vocabulary (by layout, from c_abi_shared) ────────────────────

/// The allocation context (`pancake_host_new_in`), shared with
/// `libpancake_ocapn` by layout.
pub const PancakeContext = shared.PancakeContext;

// ── Handles ──────────────────────────────────────────────────────────────────

/// A byte-fed multi-session CapTP host: one identity, one routing/redeem
/// authority, many sessions. Created with `pancake_host_new`; released with
/// `pancake_host_release`.
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

/// `PancakeHostAction.kind`: dial the exporter at `locator` and report back
/// through `pancake_host_dialed` / `pancake_host_dial_failed`.
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
/// `PancakeHostAction.kind`: the host condemned `session` mid-pump (its local
/// turns amplified past the configured budget). Drain and write its queued
/// outbound — the typed `resource_exhausted` abort — then close its transport
/// and release the connection.
pub const PANCAKE_HOST_ACTION_CLOSE: u32 = 5;

/// Default maximum admissible frame for a host connection, mirroring
/// `session.SessionLimits.max_frame_bytes` (1 MiB). Bindings pass this to
/// `pancake_host_new` / `pancake_host_new_in` unless the embedder overrides.
pub const PANCAKE_DEFAULT_FRAME_CAP: usize = (engine.SessionLimits{}).max_frame_bytes;

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
/// the live fields: DIAL carries `ticket` (its report-back handle), the full
/// `ocapn://…` exporter locator in `locator`/`locator_len`, and the locator's
/// parsed pieces — `transport`, `designator`, and its direct-addresses hint
/// hint, each empty when the locator does not parse as an ocapn URI or when
/// the hint is absent — so the dial executor never re-parses the URI. FLUSH
/// and CLOSE carry `session`; NEED_GIFT_ID carries `ticket`. SETTLE carries the settled
/// vow id in `ticket` and the fulfilled value in `value`; FAIL carries the
/// vow id in `ticket` and the break reason in `message`/`message_len`. Every
/// popped byte view and `value`'s sub-structure are host-owned and valid
/// until the next `pancake_host_next_action` call, which frees them. Unused
/// fields are zeroed.
pub const PancakeHostAction = extern struct {
    kind: u32,
    ticket: u64,
    session: ?*PancakeHostSession,
    locator: ?[*]const u8,
    locator_len: usize,
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    direct_addresses_hint: ?[*]const u8,
    direct_addresses_hint_len: usize,
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
/// borrowed for the call, and the vat copies
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

// ── Dial / accept planning vocabulary ─────────────────────────────────────────

/// PancakeDialPlan.shape: open a TCP socket to host:port (tcp, keyed-tcp).
pub const PANCAKE_DIAL_SHAPE_HOST_PORT: u32 = 0;
/// PancakeDialPlan.shape: dial an iroh endpoint by node id (the designator).
pub const PANCAKE_DIAL_SHAPE_IROH: u32 = 1;

/// PancakeDialPlan.reach_kind (iroh shape): the relay-less direct posture.
pub const PANCAKE_DIAL_REACH_DIRECT: u32 = 0;
/// PancakeDialPlan.reach_kind (iroh shape): the node's own configured redeem posture.
pub const PANCAKE_DIAL_REACH_CONFIGURED: u32 = 1;
/// PancakeDialPlan.reach_kind (iroh shape): the caller posture in reach_value.
pub const PANCAKE_DIAL_REACH_EXPLICIT: u32 = 2;

/// pancake_host_plan_dial posture_policy: a redeem (a DIAL action) — direct when
/// a hint is present, else the node's configured posture. posture_value ignored.
pub const PANCAKE_DIAL_POSTURE_REDEEM: u32 = 0;
/// pancake_host_plan_dial posture_policy: a connect with a posture in posture_value.
pub const PANCAKE_DIAL_POSTURE_EXPLICIT: u32 = 1;
/// pancake_host_plan_dial posture_policy: a connect that named no posture; an
/// iroh dial refuses PANCAKE_ERR_INVALID_ARGUMENT (a posture is required).
pub const PANCAKE_DIAL_POSTURE_EXPLICIT_NONE: u32 = 2;

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
// them as members of the `c_abi_driver` namespace so `tools/header_gen_driver.zig`
// (which reflects over the module root) and the binding mirrors see the full ABI
// from one place.

pub const pancake_host_new = host.pancake_host_new;
pub const pancake_host_new_in = host.pancake_host_new_in;
pub const pancake_host_release = host.pancake_host_release;
pub const pancake_host_designator_from_seed = host.pancake_host_designator_from_seed;
pub const pancake_host_set_self_designator = host.pancake_host_set_self_designator;
pub const pancake_host_set_session_limits = host.pancake_host_set_session_limits;
pub const pancake_host_plan_dial = host.pancake_host_plan_dial;
pub const pancake_host_plan_accept = host.pancake_host_plan_accept;
pub const pancake_host_next_action = host.pancake_host_next_action;
pub const pancake_host_dialed = host.pancake_host_dialed;
pub const pancake_host_dial_failed = host.pancake_host_dial_failed;
pub const pancake_host_provide_gift_id = host.pancake_host_provide_gift_id;
pub const pancake_host_publish = host.pancake_host_publish;
pub const pancake_host_gc_release = host.pancake_host_gc_release;
pub const pancake_host_last_error = host.pancake_host_last_error;
pub const pancake_host_clear_last_error = host.pancake_host_clear_last_error;

pub const pancake_host_session_open_dialed_locator = session.pancake_host_session_open_dialed_locator;
pub const pancake_host_session_open_accepted = session.pancake_host_session_open_accepted;
pub const pancake_host_session_release = session.pancake_host_session_release;
pub const pancake_host_session_session_open = session.pancake_host_session_session_open;
pub const pancake_host_session_feed = session.pancake_host_session_feed;
pub const pancake_host_session_feed_bytes = session.pancake_host_session_feed_bytes;
pub const pancake_host_session_take_outbound = session.pancake_host_session_take_outbound;
pub const pancake_host_session_publish = session.pancake_host_session_publish;
pub const pancake_host_session_spawn = session.pancake_host_session_spawn;
pub const pancake_host_session_fetch = session.pancake_host_session_fetch;
pub const pancake_host_session_enliven = session.pancake_host_session_enliven;
pub const pancake_host_session_send = session.pancake_host_session_send;
pub const pancake_host_session_tell = session.pancake_host_session_tell;
pub const pancake_host_vow_send = session.pancake_host_vow_send;
pub const pancake_host_vow_index = session.pancake_host_vow_index;
pub const pancake_host_vow_untag = session.pancake_host_vow_untag;
pub const pancake_host_session_break_far_vows = session.pancake_host_session_break_far_vows;
pub const pancake_host_session_set_exporter_location = session.pancake_host_session_set_exporter_location;
pub const pancake_host_session_last_abort = session.pancake_host_session_last_abort;
pub const pancake_host_session_partner_abort = session.pancake_host_session_partner_abort;

pub const pancake_host_turn_forward = turn.pancake_host_turn_forward;
pub const pancake_host_turn_send = turn.pancake_host_turn_send;
pub const pancake_host_turn_tell = turn.pancake_host_turn_tell;
pub const pancake_host_turn_spawn = turn.pancake_host_turn_spawn;
pub const pancake_host_turn_break = turn.pancake_host_turn_break;

pub const pancake_host_pump_drain = pump.pancake_host_pump_drain;

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
