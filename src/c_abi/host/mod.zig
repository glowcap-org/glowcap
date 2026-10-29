//! The byte-fed host tier's public C ABI, `libglowcap_host` (ADR-0022).
//!
//! One `GlowcapHost` is the multi-session CapTP **host** for an embedder that
//! owns its own loop, sockets, and entropy: it wraps `driver_core.Host`, so
//! everything the node decides (where a token routes, which exporter a give
//! withdraws from, when a served reply becomes a signed give) runs inside the
//! library, and the embedder's job is moving bytes and answering the
//! action queue. Inbound transport packets enter through
//! `glowcap_host_session_feed_packet` (or the narrower frame/byte-stream
//! verbs), outbound packets leave through `glowcap_host_session_take_packet`,
//! and the host's own effects (dial an exporter, draw gift-id entropy, flush a
//! session) surface as `GlowcapHostAction`s the embedder drains with
//! `glowcap_host_next_action` and answers with `glowcap_host_dialed` /
//! `glowcap_host_dial_failed` / `glowcap_host_provide_gift_id` /
//! `glowcap_host_gift_id_failed`. Settlements ride the same queue: a vow's
//! outcome pops as a `SETTLE` or `FAIL` action
//! whose `ticket` is the vow id, so one drain routes every outcome and there
//! is no listener to register before the bytes that settle it.
//!
//! One thread (or one green-thread scheduler) drives one host. Nothing here
//! locks. The one callback, a behavior answering a deliver, fires on the
//! thread executing the enclosing `glowcap_host_*` call. Inside it the
//! enqueueing verbs are legal (send/tell, vow verbs, turn verbs, gc release,
//! exporter location) and are encoded and pumped when the enclosing call
//! unwinds. The host-driving verbs (feed, feed_bytes, feed_packet,
//! resume_feed, take_packet, take_outbound, next_action,
//! the dial/gift completions, open, publish/spawn,
//! fetch/enliven, break_far_vows, transport_closed, release) are refused with
//! `GLOWCAP_ERR_INVALID_ARGUMENT`.
//!
//! This is a *separate archive* from `libglowcap_ocapn` (ADR-0022): it imports
//! the shared vocabulary leaf (`c_abi_shared`: frame/argument types, codes,
//! allocation, the per-thread last-error slot) plus the `driver_core` and
//! `actors` layers it bridges, so it exports only the `glowcap_host_*` family
//! and shares no core symbol with the ocapn archive. The family reads for its
//! entry type `Host` while the archive is named for its Zig module, the same
//! divergence `libglowcap_net_transport_tcp` carries toward `glowcap_tcp_*`. A
//! consumer links this alongside `libglowcap_ocapn` and reuses the shared
//! value types by layout. The archive carries its own last-error slot, read
//! through `glowcap_host_last_error`.
//!
//! This file is the archive root, the way `src/c_abi/ocapn/mod.zig` is: it owns
//! the public C vocabulary (the opaque handles, the action and dial-plan
//! structs, the callback typedefs, and the discriminant constants) from
//! focused POD vocabulary leaves and
//! re-exports the `glowcap_host_*` exports that live in the handle-family
//! leaves, so the header generator and the binding mirrors see the whole ABI
//! from one place. The exports themselves are split by responsibility:
//! `host.zig` owns host lifecycle, the pure dial/accept planners, the action
//! queue, GC, and the last-error slot. `publications.zig` owns the host-wide
//! publish verbs. `locators.zig` owns
//! the identity-designator helper and advertised-locator admission. And
//! `embedding.zig` owns the Zig-only driver transfer bridge.
//! `session/lifecycle.zig` owns open/close/release. `session/pump.zig` owns the
//! session byte and packet pump. `session.zig` owns publish/spawn, fetch/enliven,
//! send/tell/vows, and abort diagnostics. `turn.zig` owns the turn-time verbs.
//! `pump.zig` owns the optional `glowcap_host_pump_drain` convenience.
//! And `common.zig` holds the internal glue those leaves share (the `Instance`
//! state, the behavior bridge, marshalling, and the error projection).

pub const std_options = @import("c_abi_shared").library_options;

const std = @import("std");
const builtin = @import("builtin");

const foundation = @import("foundation");
const engine = @import("engine");
const model = @import("model");
const driver_core = @import("driver_core");

// The shared C-ABI vocabulary leaf (types, codes, allocation, the last-error
// slot), not the ocapn root, so this archive pulls none of the ocapn family's
// exports (ADR-0022 companion split).
const shared = @import("c_abi_shared");

const host = @import("host.zig");
const publications = @import("publications.zig");
const locators = @import("locators.zig");
const session_limits = @import("session_limits.zig");
const session = @import("session.zig");
const session_lifecycle = @import("session/lifecycle.zig");
const session_pump = @import("session/pump.zig");
const turn = @import("turn.zig");
const pump = @import("pump.zig");
const common = @import("common.zig");
const trace_abi = @import("trace_abi.zig");
const planning_abi = @import("planning_abi.zig");

pub const GlowcapLocatorHintView = shared.GlowcapLocatorHintView;
pub const GlowcapLocatorView = shared.GlowcapLocatorView;

pub const GLOWCAP_DESIGNATOR_SCHEME_ADDRESS = shared.transport_provider.GLOWCAP_DESIGNATOR_SCHEME_ADDRESS;
pub const GLOWCAP_DESIGNATOR_SCHEME_KEY = shared.transport_provider.GLOWCAP_DESIGNATOR_SCHEME_KEY;
pub const GLOWCAP_HOST_OUTBOUND_PREFIX_CAP: usize = 32;
pub const GLOWCAP_LOCAL_TURN_BUDGET_DEFAULT: u32 = 0;
pub const GLOWCAP_LOCAL_TURN_BUDGET_UNBOUNDED: u32 = std.math.maxInt(u32);
pub const GLOWCAP_HOST_DURABLE_ENTROPY_LEN: usize = engine.durable_swiss_entropy_len;
pub const GLOWCAP_HOST_DURABLE_SWISS_LEN: usize = engine.durable_swiss_len;
comptime {
    std.debug.assert(GLOWCAP_HOST_OUTBOUND_PREFIX_CAP >= foundation.stream_framing.prefix_buffer_bytes);
}

/// Zig-only seams for the sibling driver archive (ADR-0024). Nothing in this
/// namespace exports a C symbol.
pub const embedding = @import("embedding.zig");

/// Zig-only seams for exercising C-boundary transactions without exporting
/// another ABI symbol. Production consumers cannot name this through a header.
pub const testing = if (builtin.is_test) struct {
    pub fn importObject(raw: ?*GlowcapHostSession, position: u64) !void {
        const session_ptr = common.sessionFrom(raw) orelse return error.NullPointer;
        try session_ptr.served.port.peer.importObject(position);
    }

    pub fn projectArgs(
        host_handle: ?*GlowcapHost,
        raw: ?*GlowcapHostSession,
        allocator: @import("std").mem.Allocator,
        args: []const model.Argument,
    ) !void {
        const inst = common.instanceFrom(host_handle) orelse return error.NullPointer;
        const session_ptr = common.sessionFrom(raw) orelse return error.NullPointer;
        _ = try inst.core.projectValues(session_ptr, allocator, .fromOwnedSlice(args), allocator, common.valuesToC);
    }

    pub fn liveCapabilityCount(host_handle: ?*GlowcapHost) !usize {
        const inst = common.instanceFrom(host_handle) orelse return error.NullPointer;
        return inst.core.capabilities.liveCount();
    }

    pub fn configuredSessionLimits(host_handle: ?*GlowcapHost) !engine.SessionLimits {
        const inst = common.instanceFrom(host_handle) orelse return error.NullPointer;
        return inst.core.opts.limits;
    }

    pub fn importRefcount(raw: ?*GlowcapHostSession, position: u64) !u64 {
        const session_ptr = common.sessionFrom(raw) orelse return error.NullPointer;
        return session_ptr.served.port.peer.session_state.importRefcount(.from(position));
    }
} else struct {};

// ── Shared value vocabulary (by layout, from c_abi_shared) ────────────────────

/// The allocation context (`glowcap_host_new_in`), shared with
/// `libglowcap_ocapn` by layout.
pub const GlowcapContext = shared.GlowcapContext;

// ── Handles ──────────────────────────────────────────────────────────────────

/// A byte-fed multi-session CapTP host: one identity, one routing/redeem
/// authority, many sessions. Created with `glowcap_host_new`. Released with
/// `glowcap_host_release`.
/// The structs the wasm32 layout descriptor reports and the TypeScript
/// `WASM_LAYOUT_STRUCTS` manifest names, in one canonical order.
/// This table is the single authority both consumers read: the wasm
/// module's `glowcap_wasm_abi_layout` walks it to emit offsets, and
/// `tools/gen/binding/ts_abi.zig` walks it to emit the manifest, so a
/// struct added to the ABI cannot reach one mirror and miss the other
/// (the drift that once shipped a page demanding a layout the wasm
/// module didn't carry). Append-only: a new struct is one new row at
/// the end. It never renumbers an earlier index a JS decoder holds. status-allow: event or source ordering
pub const WasmLayoutSpec = struct {
    /// Constant prefix in the mirrors (`<prefix>_SIZE`,
    /// `<prefix>_<FIELD>_OFF`) and the string the descriptor's
    /// name-hash word is computed from.
    prefix: []const u8,
    T: type,
    /// Whether TypeScript FFI also reads this struct directly. A false
    /// row is byte-fed wasm embedder vocabulary, not FFI binding policy.
    ffi_mirror: bool = true,
};

pub const wasm_layout_manifest = [_]WasmLayoutSpec{
    .{ .prefix = "MANAGED_FRAME", .T = shared.GlowcapManagedFrame },
    .{ .prefix = "REF", .T = shared.GlowcapReference },
    .{ .prefix = "ARG", .T = shared.GlowcapArgument },
    .{ .prefix = "FRAME", .T = shared.GlowcapFrame },
    .{ .prefix = "LAST_ABORT", .T = shared.GlowcapLastAbort },
    .{ .prefix = "ALLOCATOR", .T = shared.GlowcapAllocator },
    .{ .prefix = "HOST_ACTION", .T = GlowcapHostAction },
    .{ .prefix = "HOST_PUMP_HOOKS", .T = GlowcapHostPumpHooks },
    .{ .prefix = "DIAL_PLAN", .T = GlowcapDialPlan, .ffi_mirror = false },
    .{ .prefix = "PARTNER_IDENTITY", .T = GlowcapPartnerIdentity },
    .{ .prefix = "TRACE_EVENT", .T = GlowcapTraceEvent },
    .{ .prefix = "LOCATOR_HINT_VIEW", .T = shared.GlowcapLocatorHintView },
    .{ .prefix = "LOCATOR_VIEW", .T = shared.GlowcapLocatorView },
    .{ .prefix = "CLOSE_OPTIONS", .T = shared.GlowcapCloseOptions },
    .{ .prefix = "SESSION_LIMIT_OPTIONS", .T = GlowcapSessionLimitOptions },
    .{ .prefix = "FAILURE_REPORT", .T = shared.GlowcapFailureReport },
    .{ .prefix = "FAILURE_EVENT", .T = shared.GlowcapFailureEvent },
};

pub const GlowcapHost = opaque {};

pub const GlowcapCloseOptions = shared.GlowcapCloseOptions;
/// Current layout version for `GlowcapSessionLimitOptions`.
pub const GLOWCAP_SESSION_LIMIT_OPTIONS_ABI_VERSION: u32 = 1;
/// Selective overrides for the limits copied into future sessions. A zero
/// field leaves the Host's current value unchanged.
pub const GlowcapSessionLimitOptions = extern struct {
    abi_version: u32,
    struct_size: usize,
    max_frame_bytes: usize,
    queue_cap: usize,
    outbound_high_water_bytes: usize,
    max_retained_sent_answer_bytes: usize,
    max_sessions: usize,
};
pub const GLOWCAP_PENDING_CANCEL = shared.GLOWCAP_PENDING_CANCEL;
pub const GLOWCAP_PENDING_FINISH = shared.GLOWCAP_PENDING_FINISH;
pub const GLOWCAP_CLOSE_OPTIONS_ABI_VERSION = shared.GLOWCAP_CLOSE_OPTIONS_ABI_VERSION;
pub const GLOWCAP_CLOSE_MAX_GRACE_MS = shared.GLOWCAP_CLOSE_MAX_GRACE_MS;
pub const GLOWCAP_CLOSE_GRACE_UNSPECIFIED = shared.GLOWCAP_CLOSE_GRACE_UNSPECIFIED;
pub const GLOWCAP_CLOSE_GRACE_FINITE = shared.GLOWCAP_CLOSE_GRACE_FINITE;
pub const GLOWCAP_CLOSE_GRACE_UNBOUNDED = shared.GLOWCAP_CLOSE_GRACE_UNBOUNDED;
comptime {
    std.debug.assert(GLOWCAP_CLOSE_MAX_GRACE_MS == driver_core.max_finite_close_grace_ms);
}

pub const CloseOptionsError = error{
    NullPointer,
    UnsupportedLayout,
    InvalidGraceMode,
    InvalidGraceValue,
    InvalidPending,
} || driver_core.PendingWorkInput.Error;

/// Validate the C record layout, map its discriminants, and delegate all
/// pending-work semantics to the shared sans-I/O policy constructor. Archive
/// faces add only their diagnostic prefix.
pub fn parseCloseOptions(options: ?*const GlowcapCloseOptions) CloseOptionsError!driver_core.PendingWork {
    const opts = options orelse return error.NullPointer;
    if (opts.abi_version != GLOWCAP_CLOSE_OPTIONS_ABI_VERSION or
        opts.struct_size < @sizeOf(GlowcapCloseOptions)) return error.UnsupportedLayout;
    const pending: driver_core.PendingWorkInput.Pending = switch (opts.pending) {
        GLOWCAP_PENDING_CANCEL => .cancel,
        GLOWCAP_PENDING_FINISH => .finish,
        else => return error.InvalidPending,
    };
    const grace: driver_core.PendingWorkInput.GraceInput = switch (opts.grace_mode) {
        GLOWCAP_CLOSE_GRACE_UNSPECIFIED => if (opts.grace_ms == 0) .unspecified else return error.InvalidGraceValue,
        GLOWCAP_CLOSE_GRACE_FINITE => .{ .finite_ms = opts.grace_ms },
        GLOWCAP_CLOSE_GRACE_UNBOUNDED => if (opts.grace_ms == 0) .unbounded else return error.InvalidGraceValue,
        else => return error.InvalidGraceMode,
    };
    return (driver_core.PendingWorkInput{ .pending = pending, .grace = grace }).resolve();
}

pub fn closeOptionsErrorCode(scope: []const u8, err: CloseOptionsError) i32 {
    if (err == error.NullPointer) return shared.GLOWCAP_ERR_NULL_POINTER;
    const detail = switch (err) {
        error.NullPointer => unreachable,
        error.UnsupportedLayout => "unsupported GlowcapCloseOptions layout",
        error.CancelGraceSpecified => "cancel close does not accept grace",
        error.FinishGraceRequired => "finish close requires finite or unbounded grace",
        error.InvalidGraceMode => "close grace_mode is not a GLOWCAP_CLOSE_GRACE_* value",
        error.InvalidGraceValue => "unspecified or unbounded close grace requires grace_ms == 0",
        error.InvalidPending => "close pending must be GLOWCAP_PENDING_CANCEL or GLOWCAP_PENDING_FINISH",
    };
    shared.setLastError("{s}: {s}", .{ scope, detail });
    return shared.GLOWCAP_ERR_INVALID_ARGUMENT;
}

/// `glowcap_host_lifecycle_state`: the Host still admits application work.
pub const GLOWCAP_LIFECYCLE_ACTIVE: u32 = 0;
/// `glowcap_host_lifecycle_state`: admission is sealed while admitted work runs.
pub const GLOWCAP_LIFECYCLE_FINISHING: u32 = 1;
/// `glowcap_host_lifecycle_state`: terminal session shutdown is in progress.
pub const GLOWCAP_LIFECYCLE_TERMINATING: u32 = 2;
/// `glowcap_host_lifecycle_state`: every session and queued Host effect retired.
pub const GLOWCAP_LIFECYCLE_CLOSED: u32 = 3;

/// One byte-fed CapTP session a host minted (`glowcap_host_session_open_dialed_locator` /
/// `glowcap_host_session_open_accepted`). Released with
/// `glowcap_host_session_release`, always before its host.
pub const GlowcapHostSession = opaque {};

/// The current turn, passed to a behavior callback so it can forward and
/// eventual-send while handling a deliver (`glowcap_host_turn_*`). Valid only
/// for the duration of that callback: stashing the pointer and using it after
/// the callback returns is undefined behavior.
pub const GlowcapHostTurn = opaque {};

// ── Action queue vocabulary ──────────────────────────────────────────────────

/// `GlowcapHostAction.kind`: dial the exporter named by `ticket` (borrow the
/// pending view with `glowcap_host_pending_dial`) and report back through
/// `glowcap_host_dialed` / `glowcap_host_dial_failed`.
pub const GLOWCAP_HOST_ACTION_DIAL: u32 = 0;
/// `GlowcapHostAction.kind`: outbound transport packets may be ready on
/// `session`. Drain the session's transport output until WOULD_BLOCK and write it.
pub const GLOWCAP_HOST_ACTION_FLUSH: u32 = 1;
/// `GlowcapHostAction.kind`: draw 32 random bytes and feed them back through
/// `glowcap_host_provide_gift_id` with this action's `ticket`.
pub const GLOWCAP_HOST_ACTION_NEED_GIFT_ID: u32 = 2;
/// `GlowcapHostAction.kind`: the vow `ticket` names settled fulfilled with
/// `value`. Route the outcome to whatever awaits that vow.
pub const GLOWCAP_HOST_ACTION_SETTLE: u32 = 3;
/// `GlowcapHostAction.kind`: the vow `ticket` names settled broken with
/// `message`. Route the outcome to whatever awaits that vow.
pub const GLOWCAP_HOST_ACTION_FAIL: u32 = 4;
/// `GlowcapHostAction.kind`: the host retired `session`. Drain and write any
/// queued terminal frame, then close its transport and release the connection.
/// A condemned session carries an abort. Redeem-only cleanup closes quietly.
pub const GLOWCAP_HOST_ACTION_CLOSE: u32 = 5;
/// `GlowcapHostAction.kind`: the finite host scheduler yielded with internal
/// work remaining. Return to the embedder scheduler before continuing
/// `glowcap_host_next_action`. This carries no session, ticket, or I/O request.
pub const GLOWCAP_HOST_ACTION_RESUME: u32 = 6;
/// `GlowcapHostAction.kind`: interrupt and join the external dial named by
/// `ticket`, then acknowledge it through `glowcap_host_dial_cancelled`.
pub const GLOWCAP_HOST_ACTION_CANCEL_DIAL: u32 = 7;

/// Default maximum admissible frame for a host connection, mirroring
/// `session.SessionLimits.max_frame_bytes` (1 MiB). Bindings pass this to
/// `glowcap_host_new` / `glowcap_host_new_in` unless the embedder overrides.
pub const GLOWCAP_DEFAULT_FRAME_CAP: usize = (engine.SessionLimits{}).max_frame_bytes;

/// How long a binding's establish waits for a partner's `op:start-session`
/// before abandoning the half-built connection. The budget is finite so a peer
/// that opens a byte channel and then stays silent cannot pin the caller.
pub const GLOWCAP_HANDSHAKE_TIMEOUT_MS: u64 = @intCast(driver_core.default_handshake_timeout_ms);

/// Default accepted connections held across handshaking plus ready-but-unclaimed
/// sessions by a high-level binding listener. This is capacity, not eager
/// allocation. Callers may tune it for their service.
pub const GLOWCAP_DEFAULT_PENDING_ACCEPTS: usize = 128;

/// Default OCapN handshakes one high-level binding listener drives at once.
pub const GLOWCAP_DEFAULT_HANDSHAKE_CONCURRENCY: usize = 16;

/// Maximum OCapN handshakes one high-level binding listener drives at once.
/// A silent peer therefore occupies one bounded execution seat instead of
/// serializing every connection behind its timeout, while an accept flood
/// cannot mint an unbounded set of half-open Host sessions.
pub const GLOWCAP_MAX_HANDSHAKE_CONCURRENCY: usize = 32;

/// Discovery-posture dial retry interval (ms), projected from the shared
/// `driver_core` default that the HostRuntime dial retry also consumes.
pub const GLOWCAP_DISCOVERY_DIAL_RETRY_MS: u64 = driver_core.discovery_retry_ms;
/// Discovery-posture dial attempt budget, including the first attempt.
pub const GLOWCAP_DISCOVERY_DIAL_MAX_ATTEMPTS: u32 = driver_core.discovery_max_attempts;

/// Bound on one turn's synchronous local `Forward` chase (caretaker over
/// attenuator). Hop N+1 breaks the answer instead of spinning. The wire path
/// defers each hop onto a fresh turn so it needs no matching cap. Mirrored by
/// every binding's trampoline / vat.
pub const GLOWCAP_MAX_LOCAL_FORWARD_HOPS: usize = driver_core.max_local_forward_hops;

/// One embedder effect popped from `glowcap_host_next_action`. `kind` selects
/// the live fields: DIAL and CANCEL_DIAL carry `ticket` and `route_index`
/// (DIAL borrows the pending view with `glowcap_host_pending_dial`). FLUSH and
/// CLOSE carry `session`.
/// NEED_GIFT_ID carries `ticket`. SETTLE carries the settled vow id in
/// `ticket` and the fulfilled value in `value`. FAIL carries the vow id in
/// `ticket`, the typed failure code in `result`, and the failure reason in
/// `message`/`message_len`. Every popped byte
/// view and `value`'s sub-structure are host-owned and valid until the next
/// `glowcap_host_next_action` call, which frees them. Unused fields are zeroed.
pub const GlowcapHostAction = extern struct {
    kind: u32,
    ticket: u64,
    route_index: usize,
    session: ?*GlowcapHostSession,
    value: shared.GlowcapArgument,
    message: ?[*]const u8,
    message_len: usize,
    /// CLOSE: GLOWCAP_OK or GLOWCAP_ERR_TIMEOUT. FAIL: GLOWCAP_ERR_BROKEN or
    /// GLOWCAP_ERR_CLOSED. Zero for every other kind.
    result: i32,
};

/// One shared arm callback for `GlowcapHostPumpHooks`: flush, close,
/// need_gift_id, complete (SETTLE/FAIL), and dial. Return `GLOWCAP_OK` or a
/// real `GLOWCAP_ERR_*`. A non-OK return means the arm committed no externally
/// visible effect. The drain preserves this exact action as the first action of
/// its next call. Return `GLOWCAP_OK` after taking responsibility for the
/// action, even when later asynchronous work may fail. When `out_progressed`
/// is non-null, set it to 1 if the
/// arm counts as quiescence progress (gift-id answered, dial parked, settle
/// routed). Leave 0 for a handled notice that a sibling shuttle already
/// covers (typical empty FLUSH). `action` views are host-owned until the next
/// `glowcap_host_next_action` (this drain pops internally).
pub const GlowcapHostPumpArmFn = *const fn (
    ctx: ?*anyopaque,
    host: ?*GlowcapHost,
    action: *const GlowcapHostAction,
    out_progressed: ?*u32,
) callconv(.c) i32;

/// Opt-in embedder hooks for `glowcap_host_pump_drain` (ADR-0022 fifth
/// amendment). NULL arm pointers skip that kind (no error, no progress). The
/// pull-queue remains normative. This struct is a convenience wrapper's
/// callback surface, not a replacement for `glowcap_host_next_action`.
pub const GlowcapHostPumpHooks = extern struct {
    ctx: ?*anyopaque,
    flush: ?GlowcapHostPumpArmFn,
    close: ?GlowcapHostPumpArmFn,
    need_gift_id: ?GlowcapHostPumpArmFn,
    complete: ?GlowcapHostPumpArmFn,
    dial: ?GlowcapHostPumpArmFn,
};

// ── Callbacks ────────────────────────────────────────────────────────────────

/// A hosted object's behavior, invoked on each deliver. `verb`/`args` are
/// borrowed for the call. Each `GlowcapReference` leaf is nevertheless one
/// application retain and must eventually be returned with
/// `glowcap_host_ref_release`. Copying its `{ id }` bytes does not create
/// another retain. The vat copies
/// `out_reply`'s payload the instant the callback returns, so its bytes must
/// stay valid across the return (point them at your `ctx` or a buffer you own,
/// not a callback stack local). Any non-OK return settles the answer broken
/// with a generic reason. Inside the callback the enqueueing host verbs and
/// the `glowcap_host_turn_*` verbs (with this `turn` only) are legal. The
/// host-driving verbs are refused. A null verb means no leading selector.
/// A non-null verb of length zero is the empty-symbol selector.
pub const GlowcapHostBehavior = *const fn (
    ctx: ?*anyopaque,
    turn: ?*GlowcapHostTurn,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.GlowcapArgument,
    args_len: usize,
    out_reply: *shared.GlowcapArgument,
) callconv(.c) i32;

/// Release a hosted object's `ctx` when the object is torn down. Null when
/// the consumer keeps ownership of `ctx`. Must call no `glowcap_host_*`
/// function.
pub const GlowcapHostCtxFree = *const fn (ctx: ?*anyopaque) callconv(.c) void;

// ── Trace and planning vocabulary ────────────────────────────────────────────

pub const GLOWCAP_TRACE_SESSION_OPEN = trace_abi.GLOWCAP_TRACE_SESSION_OPEN;
pub const GLOWCAP_TRACE_MESSAGE = trace_abi.GLOWCAP_TRACE_MESSAGE;
pub const GLOWCAP_TRACE_SESSION_CLOSE = trace_abi.GLOWCAP_TRACE_SESSION_CLOSE;
pub const GLOWCAP_TRACE_DIGEST_BYTES = trace_abi.GLOWCAP_TRACE_DIGEST_BYTES;
pub const GlowcapTraceEvent = trace_abi.GlowcapTraceEvent;
pub const GlowcapTraceCallback = trace_abi.GlowcapTraceCallback;

pub const GLOWCAP_DIAL_SHAPE_HOST_PORT = planning_abi.GLOWCAP_DIAL_SHAPE_HOST_PORT;
pub const GLOWCAP_DIAL_SHAPE_PEER_ID = planning_abi.GLOWCAP_DIAL_SHAPE_PEER_ID;
pub const GLOWCAP_DIAL_SHAPE_SIGNALING = planning_abi.GLOWCAP_DIAL_SHAPE_SIGNALING;
pub const GLOWCAP_DIAL_SHAPE_RENDEZVOUS = planning_abi.GLOWCAP_DIAL_SHAPE_RENDEZVOUS;
pub const GLOWCAP_DIAL_REACH_DIRECT = planning_abi.GLOWCAP_DIAL_REACH_DIRECT;
pub const GLOWCAP_DIAL_REACH_CONFIGURED = planning_abi.GLOWCAP_DIAL_REACH_CONFIGURED;
pub const GLOWCAP_DIAL_REACH_EXPLICIT = planning_abi.GLOWCAP_DIAL_REACH_EXPLICIT;
pub const GLOWCAP_DIAL_POSTURE_REDEEM = planning_abi.GLOWCAP_DIAL_POSTURE_REDEEM;
pub const GLOWCAP_DIAL_POSTURE_EXPLICIT = planning_abi.GLOWCAP_DIAL_POSTURE_EXPLICIT;
pub const GLOWCAP_DIAL_POSTURE_EXPLICIT_NONE = planning_abi.GLOWCAP_DIAL_POSTURE_EXPLICIT_NONE;
pub const GlowcapDialPlan = planning_abi.GlowcapDialPlan;
pub const GlowcapPartnerIdentity = planning_abi.GlowcapPartnerIdentity;
pub const GLOWCAP_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT = planning_abi.GLOWCAP_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT;
pub const GLOWCAP_DURABLE_PROVENANCE_UNAUTHENTICATED = planning_abi.GLOWCAP_DURABLE_PROVENANCE_UNAUTHENTICATED;

// ── Handle-family re-exports ─────────────────────────────────────────────────
//
// The `export fn`s below live in the handle-family leaves; the plain `@import`s
// above already compile them into the library. These re-exports also surface
// them as members of the `c_abi_host` namespace so `tools/gen/header/host.zig`
// (which reflects over the module root) and the binding mirrors see the full ABI
// from one place.

pub const glowcap_host_new = host.glowcap_host_new;
pub const glowcap_host_new_in = host.glowcap_host_new_in;
pub const glowcap_host_diagnostic_id = host.glowcap_host_diagnostic_id;
pub const glowcap_host_release_on_drop = host.glowcap_host_release_on_drop;
pub const glowcap_host_set_release_on_drop = host.glowcap_host_set_release_on_drop;
pub const glowcap_host_close = host.glowcap_host_close;
pub const glowcap_host_close_progress = host.glowcap_host_close_progress;
pub const glowcap_host_close_wait_ms = host.glowcap_host_close_wait_ms;
pub const glowcap_host_lifecycle_state = host.glowcap_host_lifecycle_state;
pub const glowcap_host_release = host.glowcap_host_release;
pub const glowcap_host_designator_from_seed = locators.glowcap_host_designator_from_seed;
pub const glowcap_host_set_advertised_locator = locators.glowcap_host_set_advertised_locator;
pub const glowcap_host_ensure_advertised_locator = locators.glowcap_host_ensure_advertised_locator;
pub const glowcap_host_remove_advertised_locator = locators.glowcap_host_remove_advertised_locator;
pub const glowcap_host_set_session_limits = session_limits.glowcap_host_set_session_limits;
pub const glowcap_host_set_ingress_limits = session_limits.glowcap_host_set_ingress_limits;
pub const glowcap_host_plan_dial = host.glowcap_host_plan_dial;
pub const glowcap_host_pending_dial = host.glowcap_host_pending_dial;
pub const glowcap_host_pending_dial_introducer = host.glowcap_host_pending_dial_introducer;
pub const glowcap_host_reference_exporter = host.glowcap_host_reference_exporter;
pub const glowcap_host_next_action = host.glowcap_host_next_action;
pub const retryBorrowedAction = host.retryBorrowedAction;
pub const glowcap_host_dialed = host.glowcap_host_dialed;
pub const glowcap_host_dial_failed = host.glowcap_host_dial_failed;
pub const glowcap_host_dial_cancelled = host.glowcap_host_dial_cancelled;
pub const glowcap_host_provide_gift_id = host.glowcap_host_provide_gift_id;
pub const glowcap_host_gift_id_failed = host.glowcap_host_gift_id_failed;
pub const glowcap_host_publish = publications.glowcap_host_publish;
pub const glowcap_host_spawn = publications.glowcap_host_spawn;
pub const glowcap_host_unpublish = publications.glowcap_host_unpublish;
pub const glowcap_host_publish_durable = publications.glowcap_host_publish_durable;
pub const glowcap_host_publish_reference = publications.glowcap_host_publish_reference;
pub const glowcap_host_remove_durable = publications.glowcap_host_remove_durable;
pub const glowcap_host_ref_release = host.glowcap_host_ref_release;
pub const glowcap_host_send = @import("application_delivery.zig").glowcap_host_send;
pub const glowcap_host_tell = @import("application_delivery.zig").glowcap_host_tell;
pub const glowcap_host_last_error = host.glowcap_host_last_error;
pub const glowcap_host_clear_last_error = host.glowcap_host_clear_last_error;

pub const glowcap_host_session_open_dialed_locator = session_lifecycle.glowcap_host_session_open_dialed_locator;
pub const glowcap_host_session_open_accepted = session_lifecycle.glowcap_host_session_open_accepted;
pub const glowcap_host_session_close = session_lifecycle.glowcap_host_session_close;
pub const glowcap_host_session_close_progress = session_lifecycle.glowcap_host_session_close_progress;
pub const glowcap_host_session_lifecycle_state = session_lifecycle.glowcap_host_session_lifecycle_state;
pub const glowcap_host_session_release = session_lifecycle.glowcap_host_session_release;
pub const glowcap_host_session_is_open = session_lifecycle.glowcap_host_session_is_open;
pub const glowcap_host_session_profile = session_lifecycle.glowcap_host_session_profile;
pub const glowcap_host_session_transport_name = session_lifecycle.glowcap_host_session_transport_name;
pub const glowcap_host_session_trace_id = session_lifecycle.glowcap_host_session_trace_id;
pub const glowcap_host_session_feed = session_pump.glowcap_host_session_feed;
pub const glowcap_host_session_feed_bytes = session_pump.glowcap_host_session_feed_bytes;
pub const glowcap_host_session_feed_packet = session_pump.glowcap_host_session_feed_packet;
pub const glowcap_host_session_resume_feed = session_pump.glowcap_host_session_resume_feed;
pub const glowcap_host_session_take_packet = session_pump.glowcap_host_session_take_packet;
pub const glowcap_host_session_take_outbound = session_pump.glowcap_host_session_take_outbound;
pub const glowcap_host_session_publish = session.glowcap_host_session_publish;
pub const glowcap_host_session_spawn = session.glowcap_host_session_spawn;
pub const glowcap_host_session_fetch = session.glowcap_host_session_fetch;
pub const glowcap_host_session_enliven = session.glowcap_host_session_enliven;
pub const glowcap_host_enliven = host.glowcap_host_enliven;
pub const glowcap_host_enliven_for_version = host.glowcap_host_enliven_for_version;
pub const glowcap_host_fetch_at = host.glowcap_host_fetch_at;
pub const glowcap_host_set_trace = host.glowcap_host_set_trace;
pub const glowcap_host_set_trace_queue = host.glowcap_host_set_trace_queue;
pub const glowcap_host_next_trace = host.glowcap_host_next_trace;
pub const glowcap_host_resolver_fulfill = host.glowcap_host_resolver_fulfill;
pub const glowcap_host_resolver_fulfill_value = host.glowcap_host_resolver_fulfill_value;
pub const glowcap_host_resolver_break = host.glowcap_host_resolver_break;
pub const glowcap_host_resolver_abandon = host.glowcap_host_resolver_abandon;
pub const glowcap_host_session_listen = session.glowcap_host_session_listen;
pub const glowcap_host_session_resolve = session.glowcap_host_session_resolve;
pub const glowcap_host_session_send = session.glowcap_host_session_send;
pub const glowcap_host_session_tell = session.glowcap_host_session_tell;
pub const glowcap_host_vow_send = session.glowcap_host_vow_send;
pub const glowcap_host_vow_tell = session.glowcap_host_vow_tell;
pub const glowcap_host_vow_release = session.glowcap_host_vow_release;
pub const glowcap_host_vow_capability = session.glowcap_host_vow_capability;
pub const glowcap_host_vow_index = session.glowcap_host_vow_index;
pub const glowcap_host_vow_untag = session.glowcap_host_vow_untag;
pub const glowcap_host_vow_get = session.glowcap_host_vow_get;
pub const glowcap_host_session_published_ref = session.glowcap_host_session_published_ref;
pub const glowcap_host_session_break_far_vows = session.glowcap_host_session_break_far_vows;
pub const glowcap_host_session_transport_closed = session.glowcap_host_session_transport_closed;
pub const glowcap_host_session_set_exporter_location = session.glowcap_host_session_set_exporter_location;
pub const glowcap_host_session_last_abort = session.glowcap_host_session_last_abort;
pub const glowcap_host_session_partner_abort = session.glowcap_host_session_partner_abort;
pub const glowcap_host_session_partner_identity = session.glowcap_host_session_partner_identity;
pub const glowcap_host_session_bind_verified_channel_key = session.glowcap_host_session_bind_verified_channel_key;

pub const glowcap_host_turn_forward = turn.glowcap_host_turn_forward;
pub const glowcap_host_turn_session = turn.glowcap_host_turn_session;
pub const glowcap_host_turn_defer = turn.glowcap_host_turn_defer;
pub const glowcap_host_turn_defer_if_answer = turn.glowcap_host_turn_defer_if_answer;
pub const glowcap_host_turn_send = turn.glowcap_host_turn_send;
pub const glowcap_host_turn_tell = turn.glowcap_host_turn_tell;
pub const glowcap_host_turn_spawn = turn.glowcap_host_turn_spawn;
pub const glowcap_host_turn_break = turn.glowcap_host_turn_break;

pub const glowcap_host_pump_drain = pump.glowcap_host_pump_drain;

/// The annotated symbol inventory (crossing semantics per export) the
/// binding FFI-table generators reflect from. See `symbols.zig`.
pub const symbols = @import("symbols.zig");

pub const contract_layouts = [_]shared.archive_contract.Layout{
    shared.archive_contract.layout("GLOWCAP_HOST_ACTION", GlowcapHostAction),
    shared.archive_contract.layout("GLOWCAP_HOST_PUMP_HOOKS", GlowcapHostPumpHooks),
    shared.archive_contract.layout("GLOWCAP_SESSION_LIMIT_OPTIONS", GlowcapSessionLimitOptions),
    shared.archive_contract.cOnlyLayout("GLOWCAP_DIAL_PLAN", GlowcapDialPlan),
    shared.archive_contract.layout("GLOWCAP_PARTNER_IDENTITY", GlowcapPartnerIdentity),
    shared.archive_contract.layout("GLOWCAP_TRACE_EVENT", GlowcapTraceEvent),
};

/// Exact reflected callable/layout identity for the byte-fed Host archive.
pub const GLOWCAP_HOST_ARCHIVE_FINGERPRINT = shared.archive_contract.fingerprint(
    "host",
    @This(),
    .{ shared.contract_layouts, contract_layouts },
);

pub fn glowcap_host_archive_fingerprint() callconv(.c) u64 {
    return GLOWCAP_HOST_ARCHIVE_FINGERPRINT;
}

/// Zig-facing one-loop drain helpers over `glowcap_host_next_action`
/// (ADR-0022). Not a C export. The pull-queue stays
/// normative. Bindings and tests thin onto this instead of hand-rolling
/// the action switch.
pub const embedder_pump = @import("embedder_pump.zig");
