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
//! `pancake_host_dial_failed` / `pancake_host_provide_gift_id` /
//! `pancake_host_gift_id_failed`. Settlements
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
//! fetch/enliven, break_far_vows, transport_closed, release) are refused with
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
//! structs, the callback typedefs, and the discriminant constants) from
//! focused POD vocabulary leaves and
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

const std = @import("std");
const builtin = @import("builtin");

const foundation = @import("foundation");
const engine = @import("engine");
const model = @import("model");
const driver_core = @import("driver_core");

// The shared C-ABI vocabulary leaf — types, codes, allocation, the last-error
// slot — not the ocapn root, so this archive pulls none of the ocapn family's
// exports (ADR-0059 companion split).
const shared = @import("c_abi_shared");

const host = @import("host.zig");
const session = @import("session.zig");
const session_lifecycle = @import("session_lifecycle.zig");
const turn = @import("turn.zig");
const pump = @import("pump.zig");
const common = @import("common.zig");
const trace_abi = @import("trace_abi.zig");
const planning_abi = @import("planning_abi.zig");

pub const PancakeLocatorHintView = shared.PancakeLocatorHintView;
pub const PancakeLocatorView = shared.PancakeLocatorView;

pub const PANCAKE_DESIGNATOR_SCHEME_ADDRESS = shared.transport_provider.PANCAKE_DESIGNATOR_SCHEME_ADDRESS;
pub const PANCAKE_DESIGNATOR_SCHEME_KEY = shared.transport_provider.PANCAKE_DESIGNATOR_SCHEME_KEY;
pub const PANCAKE_HOST_OUTBOUND_PREFIX_CAP: usize = 32;
pub const PANCAKE_HOST_DURABLE_ENTROPY_LEN: usize = engine.durable_swiss_entropy_len;
pub const PANCAKE_HOST_DURABLE_SWISS_LEN: usize = engine.durable_swiss_len;
comptime {
    std.debug.assert(PANCAKE_HOST_OUTBOUND_PREFIX_CAP >= foundation.stream_framing.prefix_buffer_bytes);
}

/// Zig-only seams for the sibling driver archive (ADR-0112): `libpancake_driver`
/// creates hosts through this family's own constructors, then reaches the
/// embedded core and the completion projection here. Nothing in this
/// namespace exports a symbol; a C consumer cannot name it.
pub const embedding = struct {
    pub const DriverClaim = struct {
        inst: *common.Instance,

        pub fn allocator(self: DriverClaim) std.mem.Allocator {
            return self.inst.allocator;
        }

        pub fn core(self: DriverClaim) *driver_core.Host {
            return &self.inst.core;
        }

        /// Roll back a failed driver construction. No driver-owned operation
        /// may have escaped while construction was fallible.
        pub fn rollback(self: DriverClaim) void {
            std.debug.assert(self.inst.drive_owner == .driver);
            self.inst.drive_owner = .embedder;
        }
    };

    pub const ClaimError = error{HostAlreadyOwned};

    /// Claim the C handle's transport/action-drain ownership for a native
    /// driver construction. `HostRuntime.initWithCore` validates whether the
    /// core itself can transfer; rollback restores this token if it cannot.
    pub fn claimForDriver(handle: ?*PancakeHost) ClaimError!?DriverClaim {
        const inst = common.instanceFrom(handle) orelse return null;
        if (inst.drive_owner != .embedder) return error.HostAlreadyOwned;
        inst.drive_owner = .driver;
        return .{ .inst = inst };
    }

    pub fn releaseFromDriver(handle: *PancakeHost) ?anyerror {
        return common.releaseFromDriver(handle);
    }

    /// The C handle a core session projects as; the driver archive's events
    /// carry sessions in the same handle vocabulary every `pancake_host_*`
    /// verb takes.
    pub fn sessionHandle(hs: *driver_core.HostSession) *PancakeHostSession {
        return @ptrCast(hs);
    }

    pub fn sessionFrom(raw: ?*PancakeHostSession) ?*driver_core.HostSession {
        return common.sessionFrom(raw);
    }

    /// Project one taken settled/failed completion onto the C action shape,
    /// with the byte-fed queue's exact lifetime sentence: one scratch reset
    /// per pop, then the projection allocates its views there. The caller
    /// serializes this with `pancake_host_next_action` on the one driving
    /// thread (a loop-tier consumer does not drain the byte-fed queue).
    pub fn projectCompletion(
        handle: ?*PancakeHost,
        action: driver_core.HostAction,
        slot: *PancakeHostAction,
    ) i32 {
        const inst = common.instanceFrom(handle) orelse return shared.PANCAKE_ERR_NULL_POINTER;
        _ = inst.completion_scratch.reset(.{ .retain_with_limit = common.steady_scratch_bytes });
        return common.projectCompletionInto(inst, action, slot);
    }
};

/// Zig-only seams for exercising C-boundary transactions without exporting
/// another ABI symbol. Production consumers cannot name this through a header.
pub const testing = if (builtin.is_test) struct {
    pub fn importObject(raw: ?*PancakeHostSession, position: u64) !void {
        const session_ptr = common.sessionFrom(raw) orelse return error.NullPointer;
        try session_ptr.served.port.peer.importObject(position);
    }

    pub fn projectArgs(
        host_handle: ?*PancakeHost,
        raw: ?*PancakeHostSession,
        allocator: @import("std").mem.Allocator,
        args: []const model.Argument,
    ) !void {
        const inst = common.instanceFrom(host_handle) orelse return error.NullPointer;
        const session_ptr = common.sessionFrom(raw) orelse return error.NullPointer;
        _ = try common.hostArgsToC(inst, session_ptr, allocator, args);
    }

    pub fn liveCapabilityCount(host_handle: ?*PancakeHost) !usize {
        const inst = common.instanceFrom(host_handle) orelse return error.NullPointer;
        return inst.core.capabilities.liveCount();
    }

    pub fn importRefcount(raw: ?*PancakeHostSession, position: u64) !u64 {
        const session_ptr = common.sessionFrom(raw) orelse return error.NullPointer;
        return session_ptr.served.port.peer.session_state.importRefcount(.from(position));
    }
} else struct {};

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
    .{ .prefix = "PARTNER_IDENTITY", .T = PancakePartnerIdentity },
    .{ .prefix = "TRACE_EVENT", .T = PancakeTraceEvent },
    .{ .prefix = "LOCATOR_HINT_VIEW", .T = shared.PancakeLocatorHintView },
    .{ .prefix = "LOCATOR_VIEW", .T = shared.PancakeLocatorView },
    .{ .prefix = "CLOSE_OPTIONS", .T = shared.PancakeCloseOptions },
    .{ .prefix = "FAILURE_REPORT", .T = shared.PancakeFailureReport },
    .{ .prefix = "FAILURE_EVENT", .T = shared.PancakeFailureEvent },
};

pub const PancakeHost = opaque {};

pub const PancakeCloseOptions = shared.PancakeCloseOptions;
pub const PANCAKE_PENDING_CANCEL = shared.PANCAKE_PENDING_CANCEL;
pub const PANCAKE_PENDING_FINISH = shared.PANCAKE_PENDING_FINISH;
pub const PANCAKE_CLOSE_OPTIONS_ABI_VERSION = shared.PANCAKE_CLOSE_OPTIONS_ABI_VERSION;
pub const PANCAKE_CLOSE_MAX_GRACE_MS = shared.PANCAKE_CLOSE_MAX_GRACE_MS;
pub const PANCAKE_CLOSE_GRACE_UNSPECIFIED = shared.PANCAKE_CLOSE_GRACE_UNSPECIFIED;
pub const PANCAKE_CLOSE_GRACE_FINITE = shared.PANCAKE_CLOSE_GRACE_FINITE;
pub const PANCAKE_CLOSE_GRACE_UNBOUNDED = shared.PANCAKE_CLOSE_GRACE_UNBOUNDED;
comptime {
    std.debug.assert(PANCAKE_CLOSE_MAX_GRACE_MS == driver_core.max_finite_close_grace_ms);
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
pub fn parseCloseOptions(options: ?*const PancakeCloseOptions) CloseOptionsError!driver_core.PendingWork {
    const opts = options orelse return error.NullPointer;
    if (opts.abi_version != PANCAKE_CLOSE_OPTIONS_ABI_VERSION or
        opts.struct_size < @sizeOf(PancakeCloseOptions)) return error.UnsupportedLayout;
    const pending: driver_core.PendingWorkInput.Pending = switch (opts.pending) {
        PANCAKE_PENDING_CANCEL => .cancel,
        PANCAKE_PENDING_FINISH => .finish,
        else => return error.InvalidPending,
    };
    const grace: driver_core.PendingWorkInput.GraceInput = switch (opts.grace_mode) {
        PANCAKE_CLOSE_GRACE_UNSPECIFIED => if (opts.grace_ms == 0) .unspecified else return error.InvalidGraceValue,
        PANCAKE_CLOSE_GRACE_FINITE => .{ .finite_ms = opts.grace_ms },
        PANCAKE_CLOSE_GRACE_UNBOUNDED => if (opts.grace_ms == 0) .unbounded else return error.InvalidGraceValue,
        else => return error.InvalidGraceMode,
    };
    return (driver_core.PendingWorkInput{ .pending = pending, .grace = grace }).resolve();
}

pub fn closeOptionsErrorCode(scope: []const u8, err: CloseOptionsError) i32 {
    if (err == error.NullPointer) return shared.PANCAKE_ERR_NULL_POINTER;
    const detail = switch (err) {
        error.NullPointer => unreachable,
        error.UnsupportedLayout => "unsupported PancakeCloseOptions layout",
        error.CancelGraceSpecified => "cancel close does not accept grace",
        error.FinishGraceRequired => "finish close requires finite or unbounded grace",
        error.InvalidGraceMode => "close grace_mode is not a PANCAKE_CLOSE_GRACE_* value",
        error.InvalidGraceValue => "unspecified or unbounded close grace requires grace_ms == 0",
        error.InvalidPending => "close pending must be PANCAKE_PENDING_CANCEL or PANCAKE_PENDING_FINISH",
    };
    shared.setLastError("{s}: {s}", .{ scope, detail });
    return shared.PANCAKE_ERR_INVALID_ARGUMENT;
}

/// `pancake_host_lifecycle_state`: the Host still admits application work.
pub const PANCAKE_LIFECYCLE_ACTIVE: u32 = 0;
/// `pancake_host_lifecycle_state`: admission is sealed while admitted work runs.
pub const PANCAKE_LIFECYCLE_FINISHING: u32 = 1;
/// `pancake_host_lifecycle_state`: terminal session shutdown is in progress.
pub const PANCAKE_LIFECYCLE_TERMINATING: u32 = 2;
/// `pancake_host_lifecycle_state`: every session and queued Host effect retired.
pub const PANCAKE_LIFECYCLE_CLOSED: u32 = 3;

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
/// `PancakeHostAction.kind`: the finite host scheduler yielded with internal
/// work remaining. Return to the embedder scheduler before continuing
/// `pancake_host_next_action`; this carries no session, ticket, or I/O request.
pub const PANCAKE_HOST_ACTION_RESUME: u32 = 6;
/// `PancakeHostAction.kind`: interrupt and join the external dial named by
/// `ticket`, then acknowledge it through `pancake_host_dial_cancelled`.
pub const PANCAKE_HOST_ACTION_CANCEL_DIAL: u32 = 7;

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

/// Default accepted connections held across handshaking plus ready-but-unclaimed
/// sessions by a high-level binding listener. This is capacity, not eager
/// allocation; callers may tune it for their service.
pub const PANCAKE_DEFAULT_PENDING_ACCEPTS: usize = 128;

/// Default OCapN handshakes one high-level binding listener drives at once.
pub const PANCAKE_DEFAULT_HANDSHAKE_CONCURRENCY: usize = 16;

/// Maximum OCapN handshakes one high-level binding listener drives at once.
/// A silent peer therefore occupies one bounded execution seat instead of
/// serializing every connection behind its timeout, while an accept flood
/// cannot mint an unbounded set of half-open Host sessions.
pub const PANCAKE_MAX_HANDSHAKE_CONCURRENCY: usize = 32;

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
/// the live fields: DIAL and CANCEL_DIAL carry only `ticket` (DIAL borrows the
/// pending view with `pancake_host_pending_dial`). FLUSH and CLOSE carry `session`;
/// NEED_GIFT_ID carries `ticket`. SETTLE carries the settled vow id in
/// `ticket` and the fulfilled value in `value`; FAIL carries the vow id in
/// `ticket`, the typed failure code in `result`, and the failure reason in
/// `message`/`message_len`. Every popped byte
/// view and `value`'s sub-structure are host-owned and valid until the next
/// `pancake_host_next_action` call, which frees them. Unused fields are zeroed.
pub const PancakeHostAction = extern struct {
    kind: u32,
    ticket: u64,
    session: ?*PancakeHostSession,
    value: shared.PancakeArgument,
    message: ?[*]const u8,
    message_len: usize,
    /// CLOSE: PANCAKE_OK or PANCAKE_ERR_TIMEOUT. FAIL: PANCAKE_ERR_BROKEN or
    /// PANCAKE_ERR_CLOSED. Zero for every other kind.
    result: i32,
};

/// One shared arm callback for `PancakeHostPumpHooks`: flush, close,
/// need_gift_id, complete (SETTLE/FAIL), and dial. Return `PANCAKE_OK` or a
/// real `PANCAKE_ERR_*`. A non-OK return means the arm committed no externally
/// visible effect; the drain preserves this exact action as the first action of
/// its next call. Return `PANCAKE_OK` after taking responsibility for the
/// action, even when later asynchronous work may fail. When `out_progressed`
/// is non-null, set it to 1 if the
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

// ── Trace and planning vocabulary ────────────────────────────────────────────

pub const PANCAKE_TRACE_SESSION_OPEN = trace_abi.PANCAKE_TRACE_SESSION_OPEN;
pub const PANCAKE_TRACE_MESSAGE = trace_abi.PANCAKE_TRACE_MESSAGE;
pub const PANCAKE_TRACE_SESSION_CLOSE = trace_abi.PANCAKE_TRACE_SESSION_CLOSE;
pub const PANCAKE_TRACE_DIGEST_BYTES = trace_abi.PANCAKE_TRACE_DIGEST_BYTES;
pub const PancakeTraceEvent = trace_abi.PancakeTraceEvent;
pub const PancakeTraceCallback = trace_abi.PancakeTraceCallback;

pub const PANCAKE_DIAL_SHAPE_HOST_PORT = planning_abi.PANCAKE_DIAL_SHAPE_HOST_PORT;
pub const PANCAKE_DIAL_SHAPE_PEER_ID = planning_abi.PANCAKE_DIAL_SHAPE_PEER_ID;
pub const PANCAKE_DIAL_SHAPE_SIGNALING = planning_abi.PANCAKE_DIAL_SHAPE_SIGNALING;
pub const PANCAKE_DIAL_SHAPE_RENDEZVOUS = planning_abi.PANCAKE_DIAL_SHAPE_RENDEZVOUS;
pub const PANCAKE_DIAL_REACH_DIRECT = planning_abi.PANCAKE_DIAL_REACH_DIRECT;
pub const PANCAKE_DIAL_REACH_CONFIGURED = planning_abi.PANCAKE_DIAL_REACH_CONFIGURED;
pub const PANCAKE_DIAL_REACH_EXPLICIT = planning_abi.PANCAKE_DIAL_REACH_EXPLICIT;
pub const PANCAKE_DIAL_POSTURE_REDEEM = planning_abi.PANCAKE_DIAL_POSTURE_REDEEM;
pub const PANCAKE_DIAL_POSTURE_EXPLICIT = planning_abi.PANCAKE_DIAL_POSTURE_EXPLICIT;
pub const PANCAKE_DIAL_POSTURE_EXPLICIT_NONE = planning_abi.PANCAKE_DIAL_POSTURE_EXPLICIT_NONE;
pub const PancakeDialPlan = planning_abi.PancakeDialPlan;
pub const PancakePartnerIdentity = planning_abi.PancakePartnerIdentity;
pub const PANCAKE_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT = planning_abi.PANCAKE_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT;
pub const PANCAKE_DURABLE_PROVENANCE_UNAUTHENTICATED = planning_abi.PANCAKE_DURABLE_PROVENANCE_UNAUTHENTICATED;

// ── Handle-family re-exports ─────────────────────────────────────────────────
//
// The `export fn`s below live in the handle-family leaves; the plain `@import`s
// above already compile them into the library. These re-exports also surface
// them as members of the `c_abi_host` namespace so `tools/gen/header/host.zig`
// (which reflects over the module root) and the binding mirrors see the full ABI
// from one place.

pub const pancake_host_new = host.pancake_host_new;
pub const pancake_host_new_in = host.pancake_host_new_in;
pub const pancake_host_diagnostic_id = host.pancake_host_diagnostic_id;
pub const pancake_host_close = host.pancake_host_close;
pub const pancake_host_close_progress = host.pancake_host_close_progress;
pub const pancake_host_close_wait_ms = host.pancake_host_close_wait_ms;
pub const pancake_host_lifecycle_state = host.pancake_host_lifecycle_state;
pub const pancake_host_release = host.pancake_host_release;
pub const pancake_host_designator_from_seed = host.pancake_host_designator_from_seed;
pub const pancake_host_set_advertised_locator = host.pancake_host_set_advertised_locator;
pub const pancake_host_ensure_advertised_locator = host.pancake_host_ensure_advertised_locator;
pub const pancake_host_remove_advertised_locator = host.pancake_host_remove_advertised_locator;
pub const pancake_host_set_session_limits = host.pancake_host_set_session_limits;
pub const pancake_host_plan_dial = host.pancake_host_plan_dial;
pub const pancake_host_pending_dial = host.pancake_host_pending_dial;
pub const pancake_host_reference_exporter = host.pancake_host_reference_exporter;
pub const pancake_host_next_action = host.pancake_host_next_action;
pub const retryBorrowedAction = host.retryBorrowedAction;
pub const pancake_host_dialed = host.pancake_host_dialed;
pub const pancake_host_dial_failed = host.pancake_host_dial_failed;
pub const pancake_host_dial_cancelled = host.pancake_host_dial_cancelled;
pub const pancake_host_provide_gift_id = host.pancake_host_provide_gift_id;
pub const pancake_host_gift_id_failed = host.pancake_host_gift_id_failed;
pub const pancake_host_publish = host.pancake_host_publish;
pub const pancake_host_unpublish = host.pancake_host_unpublish;
pub const pancake_host_publish_durable = host.pancake_host_publish_durable;
pub const pancake_host_remove_durable = host.pancake_host_remove_durable;
pub const pancake_host_ref_release = host.pancake_host_ref_release;
pub const pancake_host_last_error = host.pancake_host_last_error;
pub const pancake_host_clear_last_error = host.pancake_host_clear_last_error;

pub const pancake_host_session_open_dialed_locator = session_lifecycle.pancake_host_session_open_dialed_locator;
pub const pancake_host_session_open_accepted = session_lifecycle.pancake_host_session_open_accepted;
pub const pancake_host_session_close = session_lifecycle.pancake_host_session_close;
pub const pancake_host_session_close_progress = session_lifecycle.pancake_host_session_close_progress;
pub const pancake_host_session_lifecycle_state = session_lifecycle.pancake_host_session_lifecycle_state;
pub const pancake_host_session_release = session_lifecycle.pancake_host_session_release;
pub const pancake_host_session_is_open = session_lifecycle.pancake_host_session_is_open;
pub const pancake_host_session_trace_id = session_lifecycle.pancake_host_session_trace_id;
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
pub const pancake_host_session_transport_closed = session.pancake_host_session_transport_closed;
pub const pancake_host_session_set_exporter_location = session.pancake_host_session_set_exporter_location;
pub const pancake_host_session_last_abort = session.pancake_host_session_last_abort;
pub const pancake_host_session_partner_abort = session.pancake_host_session_partner_abort;
pub const pancake_host_session_partner_identity = session.pancake_host_session_partner_identity;
pub const pancake_host_session_bind_verified_channel_key = session.pancake_host_session_bind_verified_channel_key;

pub const pancake_host_turn_forward = turn.pancake_host_turn_forward;
pub const pancake_host_turn_session = turn.pancake_host_turn_session;
pub const pancake_host_turn_defer = turn.pancake_host_turn_defer;
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
