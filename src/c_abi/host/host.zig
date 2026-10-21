//! Host lifecycle and the host-wide surfaces for `libglowcap_host`: create /
//! release, the pure dial / accept planners, the embedder action queue
//! (`glowcap_host_next_action` and the DIAL / gift-id completions), GC
//! release, and the archive's own last-error slot. The host-wide publish
//! verbs live in `publications.zig`, the advertised-locator verbs in
//! `locators.zig`, the per-session verbs in `session.zig`, the turn-time verbs
//! in `turn.zig`, and the convenience drain in `pump.zig`. The module root
//! (`mod.zig`) owns the public C types these exports fill.

const std = @import("std");

const foundation = @import("foundation");
const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");
const capability_ids = @import("capability_ids.zig");
const host_actions = @import("actions.zig");
const host_lifecycle = @import("lifecycle.zig");
const host_plan = @import("plan.zig");
const host_trace = @import("trace.zig");
const driver_core = @import("driver_core");

const crypto = foundation.crypto;

const Instance = common.Instance;
const Host = common.Host;
const instanceFrom = common.instanceFrom;
const errToCode = common.errToCode;

const GlowcapContext = c.GlowcapContext;
const GlowcapHost = c.GlowcapHost;
const GlowcapHostSession = c.GlowcapHostSession;
const GlowcapHostAction = c.GlowcapHostAction;
const GlowcapDialPlan = c.GlowcapDialPlan;

const GLOWCAP_OK = shared.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = shared.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = shared.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_INTERNAL = shared.GLOWCAP_ERR_INTERNAL;
const GLOWCAP_ERR_WOULD_BLOCK = shared.GLOWCAP_ERR_WOULD_BLOCK;

// ── Lifecycle ────────────────────────────────────────────────────────────────

pub fn hostNewIn(
    alloc: std.mem.Allocator,
    diagnostic_id: u64,
    seed_ptr: ?[*]const u8,
    seed_len: usize,
    frame_cap: usize,
    verify_partner: u32,
    codec: u32,
    captp_version: u32,
    features: u32,
    local_turn_budget: u32,
    release_on_drop: u32,
    out_host: ?*?*GlowcapHost,
) i32 {
    const slot = out_host orelse return GLOWCAP_ERR_NULL_POINTER;
    const seed_nn = seed_ptr orelse return GLOWCAP_ERR_NULL_POINTER;
    if (frame_cap == 0) {
        shared.setLastError("host: frame_cap must be nonzero", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    // One buffer, two independent inputs (ADR-0028). The first 32 bytes are
    // the host's durable identity and must stay stable across restarts: a
    // keyed locator's designator is derived from them. The next 32 are the
    // session-key root, and they must be *fresh per process*: they are what
    // makes each session sign with its own key, and what stops a restarted
    // host recreating a prior session's handoff names. A durable-only 32-byte
    // seed is refused here so CapTP session keys cannot silently reuse the
    // identity seed (ADR-0039 names that footgun on the bare Zig Host).
    const session_root_len = crypto.seed_bytes * 2;
    if (seed_len != session_root_len) {
        shared.setLastError(
            "host: seed must be {d} bytes (durable identity followed by a fresh session-key root)",
            .{session_root_len},
        );
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    const codec_id = shared.codecFromC(codec) orelse {
        shared.setLastError("host: codec must be a GLOWCAP_CODEC_* value", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    const version_id = shared.captpVersionFromC(captp_version) orelse {
        shared.setLastError("host: captp_version must be a GLOWCAP_CAPTP_* value", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    const feature_set = shared.featureSetFromC(features) orelse {
        shared.setLastError("host: features must be a GLOWCAP_FEATURE_* bitmask", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    const inst = alloc.create(Instance) catch |err| return errToCode(err);
    var opts = Host.Options.withFrameCap(frame_cap);
    opts.verify_partner = verify_partner != 0;
    opts.codec = codec_id;
    opts.captp_version = version_id;
    opts.features = feature_set;
    opts.local_turn_budget = switch (local_turn_budget) {
        c.GLOWCAP_LOCAL_TURN_BUDGET_DEFAULT => driver_core.default_loop_local_turn_budget,
        c.GLOWCAP_LOCAL_TURN_BUDGET_UNBOUNDED => null,
        else => local_turn_budget,
    };
    opts.release_on_drop = release_on_drop != 0;
    opts.capability_id_issuer = capability_ids.issuer(seed_nn[0..crypto.seed_bytes].*);
    const core = Host.init(
        alloc,
        seed_nn[0..crypto.seed_bytes].*,
        seed_nn[crypto.seed_bytes..session_root_len].*,
        opts,
    ) catch |err| {
        alloc.destroy(inst);
        return errToCode(err);
    };
    inst.* = .{
        .core = core,
        .allocator = alloc,
        .diagnostic_id = diagnostic_id,
        .arg_scratch = std.heap.ArenaAllocator.init(alloc),
        .turn_scratch = std.heap.ArenaAllocator.init(alloc),
        .completion_scratch = std.heap.ArenaAllocator.init(alloc),
    };
    slot.* = @ptrCast(inst);
    return GLOWCAP_OK;
}

/// Create a byte-fed host bound to a caller-drawn 64-byte seed buffer: the
/// durable Ed25519 identity in the first 32 bytes, then a fresh per-process
/// session-key root (ADR-0028). The host never draws entropy. `frame_cap`
/// sizes every session's maximum admissible frame.
/// A nonzero `verify_partner` keeps partner-signature verification on (the
/// secure default). `codec`, `captp_version`, and `features` are this host's
/// preferred profile offer. The signed hello carries them as locator hints,
/// and each session settles them with its partner. `local_turn_budget` caps
/// local-turn amplification per session (ADR-0018):
/// `GLOWCAP_LOCAL_TURN_BUDGET_DEFAULT` applies the Zig Host's finite default,
/// `GLOWCAP_LOCAL_TURN_BUDGET_UNBOUNDED` turns the cap off, and any other
/// value is the cap. `release_on_drop` is the Host-wide setting a binding
/// reads when it projects a far capability (ADR-0025); the Host stores it and
/// attaches no behavior. Released with `glowcap_host_release`.
pub fn glowcap_host_new(
    seed: ?[*]const u8,
    seed_len: usize,
    frame_cap: usize,
    verify_partner: u32,
    codec: u32,
    captp_version: u32,
    features: u32,
    local_turn_budget: u32,
    release_on_drop: u32,
    out_host: ?*?*GlowcapHost,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return hostNewIn(shared.library_allocator, 0, seed, seed_len, frame_cap, verify_partner, codec, captp_version, features, local_turn_budget, release_on_drop, out_host);
}

/// `glowcap_host_new` allocating every byte the host owns through `context`'s
/// host allocator.
pub fn glowcap_host_new_in(
    context: ?*GlowcapContext,
    seed: ?[*]const u8,
    seed_len: usize,
    frame_cap: usize,
    verify_partner: u32,
    codec: u32,
    captp_version: u32,
    features: u32,
    local_turn_budget: u32,
    release_on_drop: u32,
    out_host: ?*?*GlowcapHost,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const ctx = shared.ctxFromOpaque(context) orelse return GLOWCAP_ERR_NULL_POINTER;
    const diagnostic_id = ctx.lifecycle_ids.allocate() catch {
        shared.setLastError("host: Context lifecycle identity space exhausted", .{});
        return GLOWCAP_ERR_INTERNAL;
    };
    return hostNewIn(ctx.allocator(), diagnostic_id, seed, seed_len, frame_cap, verify_partner, codec, captp_version, features, local_turn_budget, release_on_drop, out_host);
}

/// Read the Host-wide release-on-drop setting (ADR-0025) into `*out_enabled`
/// as 0 or 1.
pub fn glowcap_host_release_on_drop(host: ?*GlowcapHost, out_enabled: ?*u32) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_enabled orelse return GLOWCAP_ERR_NULL_POINTER;
    slot.* = @intFromBool(inst.core.releaseOnDrop());
    return GLOWCAP_OK;
}

/// Set the Host-wide release-on-drop setting (ADR-0025) for capabilities the
/// Host projects after this call: nonzero turns it on.
pub fn glowcap_host_set_release_on_drop(host: ?*GlowcapHost, enabled: u32) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return GLOWCAP_ERR_NULL_POINTER;
    inst.core.setReleaseOnDrop(enabled != 0) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Return this Host's stable identity in its owning Context's diagnostic
/// namespace. The context-less convenience constructor reports zero because it
/// has no Context diagnostic namespace to allocate from.
pub fn glowcap_host_diagnostic_id(host: ?*GlowcapHost, out_id: ?*u64) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_lifecycle.diagnosticId(host, out_id);
}

/// Seal application admission and begin or escalate terminal Host close. The
/// byte-fed embedder supplies its monotonic clock reading. Shared Zig state
/// retains the first deadline and owns expiry semantics.
pub fn glowcap_host_close(
    host: ?*GlowcapHost,
    options: ?*const c.GlowcapCloseOptions,
    now_ms: i64,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_lifecycle.close(host, options, now_ms);
}

/// Apply the caller's current monotonic time to a byte-fed Host close. This
/// performs no I/O: expiry may only escalate FINISH to the core's CANCEL path.
pub fn glowcap_host_close_progress(host: ?*GlowcapHost, now_ms: i64, out_state: ?*u32) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_lifecycle.closeProgress(host, now_ms, out_state);
}

/// The longest a close driver may wait for new input before calling
/// `glowcap_host_close_progress` again: milliseconds until the nearest FINISH
/// grace deadline, the Host's own or any session's, clamped at zero. Writes -1
/// when no finite deadline is pending, meaning only feed, action-drain,
/// settle, or escalation activity can advance terminal progress, so the
/// embedder may park on activity alone. Poll-shaped: the value
/// drops straight into a wait primitive's timeout argument.
pub fn glowcap_host_close_wait_ms(host: ?*GlowcapHost, now_ms: i64, out_wait_ms: ?*i64) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_lifecycle.closeWaitMs(host, now_ms, out_wait_ms);
}

/// Observe the byte-fed Host lifecycle without advancing it. The embedder
/// advances terminal progress through the ordinary feed/action-drain cycle.
pub fn glowcap_host_lifecycle_state(host: ?*GlowcapHost, out_state: ?*u32) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_lifecycle.state(host, out_state);
}

/// Release the host and everything it owns: every still-open session
/// (each still-parked vow breaks inside this call, its undrained completion
/// freed with the rest of the action queue), the vow map, parked actions,
/// the node, and the publication rows (each publication's `free` runs exactly once
/// here). Null is a no-op. HostSession (`GlowcapHostSession`) handles this host minted
/// are freed with it. Release the sessions first if you hold them, and never
/// touch one after its host is gone. Because release is terminal, an embedder
/// may transfer exclusive ownership to a finalizer thread after every Host call
/// has returned. No live Host verb gains cross-thread permission. Refused (with
/// the last error set) from inside a callback.
pub fn release(host: ?*GlowcapHost) i32 {
    return host_lifecycle.release(host);
}

pub fn glowcap_host_release(host: ?*GlowcapHost) callconv(.c) i32 {
    shared.lastErrorClear();
    return release(host);
}

// ── Dial / accept planning (driver_core.planDial / planAccept) ────────────────
//
// The transport dispatch, designator validation, host:port resolution, and
// peer-id reachability decision that every language binding would otherwise repeat in
// its own connect / dial_exporter / Server.accept. A binding calls the planner,
// opens the byte channel the plan names in its own runtime, then feeds it back
// through glowcap_host_session_open_dialed_locator /
// glowcap_host_session_open_accepted. The plan is pure: no socket, no
// allocation, every view borrowing the caller input.

/// Project the complete in-flight locator for `ticket` through caller-owned
/// hint storage. A null `hint_storage` with zero capacity probes the required
/// hint count. On BUFFER_TOO_SMALL, `out_hint_count` reports the exact capacity
/// and `out_locator` is untouched.
pub fn glowcap_host_pending_dial(
    host: ?*GlowcapHost,
    ticket: u64,
    route_index: usize,
    hint_storage: ?[*]c.GlowcapLocatorHintView,
    hint_capacity: usize,
    out_locator: ?*c.GlowcapLocatorView,
    out_hint_count: ?*usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_plan.pendingDial(host, ticket, route_index, hint_storage, hint_capacity, out_locator, out_hint_count);
}

/// Borrow the session that supplied this pending dial's oldest remaining give.
/// NULL means no live introducer. Unknown attempts leave the output untouched.
pub fn glowcap_host_pending_dial_introducer(
    host: ?*GlowcapHost,
    ticket: u64,
    route_index: usize,
    out_session: ?*?*GlowcapHostSession,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_plan.pendingDialIntroducer(host, ticket, route_index, out_session);
}

/// The live session homing remote `reference`, into `*out_session`, or NULL for
/// a local, stale, foreign-Host, or closed-session capability. Bindings use this
/// after a send to distinguish a capability homed on the sending session from
/// one redeemed onto another exporter session. The result comes from the
/// reference's own Host row, with no dial-completion capture window. The handle
/// is Host-owned and lives with that session. Do not release it here.
pub fn glowcap_host_reference_exporter(
    host: ?*GlowcapHost,
    reference: ?*const shared.GlowcapReference,
    out_session: ?*?*GlowcapHostSession,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_plan.referenceExporter(host, reference, out_session);
}

/// Project one pure Zig dial plan. All output views borrow the caller's input.
pub fn glowcap_host_plan_dial(
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    direct_addresses_hint: ?[*]const u8,
    direct_addresses_hint_len: usize,
    posture_policy: u32,
    posture_value: u32,
    out_plan: ?*GlowcapDialPlan,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_plan.planDial(
        transport,
        transport_len,
        designator,
        designator_len,
        direct_addresses_hint,
        direct_addresses_hint_len,
        posture_policy,
        posture_value,
        out_plan,
    );
}

/// Install or clear the synchronous borrowed trace callback. Installation
/// reports open sessions after publishing the callback and context.
pub fn glowcap_host_set_trace(
    host: ?*GlowcapHost,
    callback: ?c.GlowcapTraceCallback,
    ctx: ?*anyopaque,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_trace.setTrace(host, callback, ctx);
}

/// Install, replace, or clear the bounded pull-based trace queue. A new queue
/// starts with current open-session facts, subject to its capacity.
pub fn glowcap_host_set_trace_queue(
    host: ?*GlowcapHost,
    capacity: usize,
    payload_cap: usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_trace.setTraceQueue(host, capacity, payload_cap);
}

/// Pop one trace record, borrowed until the next pop. WOULD_BLOCK when empty.
pub fn glowcap_host_next_trace(
    host: ?*GlowcapHost,
    out: ?*c.GlowcapTraceEvent,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_trace.nextTrace(host, out);
}

/// Fulfill one resolver with a capability-free value, consuming on success.
pub fn glowcap_host_resolver_fulfill(
    host: ?*GlowcapHost,
    resolver_id: u64,
    value: ?*const shared.GlowcapArgument,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_actions.resolverFulfill(host, resolver_id, value);
}

/// Fulfill a deferred answer with an owning-thread value. Capability projection
/// uses the original caller session and ordinary outbound handoff staging.
pub fn glowcap_host_resolver_fulfill_value(host: ?*GlowcapHost, resolver_id: u64, value: ?*const shared.GlowcapArgument) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_actions.resolverFulfillValue(host, resolver_id, value);
}

/// Settle a resolver vow broken with a diagnostic borrowed for the call. The
/// same top-level, consume-on-success contract as glowcap_host_resolver_fulfill.
pub fn glowcap_host_resolver_break(
    host: ?*GlowcapHost,
    resolver_id: u64,
    message: ?[*]const u8,
    message_len: usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_actions.resolverBreak(host, resolver_id, message, message_len);
}

/// Abandon a deferred answer, top-level. A resolver already consumed by session
/// teardown or settlement is complete cleanup. Unminted ids remain errors.
/// Every other refusal leaves the operation retryable.
pub fn glowcap_host_resolver_abandon(
    host: ?*GlowcapHost,
    resolver_id: u64,
    message: ?[*]const u8,
    message_len: usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_actions.resolverAbandon(host, resolver_id, message, message_len);
}

/// Enliven a sturdyref now or stage its dial. Settlement returns as an action.
pub fn glowcap_host_enliven(
    host: ?*GlowcapHost,
    sturdyref_uri: ?[*]const u8,
    sturdyref_uri_len: usize,
    out_vow: ?*u64,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_actions.enliven(host, sturdyref_uri, sturdyref_uri_len, out_vow);
}

/// Enliven using the CapTP profile that defined the sturdyref's swiss spelling.
pub fn glowcap_host_enliven_for_version(
    host: ?*GlowcapHost,
    captp_version: u32,
    sturdyref_uri: ?[*]const u8,
    sturdyref_uri_len: usize,
    out_vow: ?*u64,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_actions.enlivenForVersion(
        host,
        captp_version,
        sturdyref_uri,
        sturdyref_uri_len,
        out_vow,
    );
}

/// Fetch a named publication at a typed locator through this Host's profile.
pub fn glowcap_host_fetch_at(
    host: ?*GlowcapHost,
    locator: ?*const shared.GlowcapLocatorView,
    name: ?[*]const u8,
    name_len: usize,
    out_vow: ?*u64,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_actions.fetchAt(host, locator, name, name_len, out_vow);
}

// ── The action queue ─────────────────────────────────────────────────────────

/// Pop one borrowed Host action, or WOULD_BLOCK without consuming anything.
/// Before the pop, queued Host work resumes and may synchronously invoke a
/// `GlowcapHostBehavior`. Binding runtimes must install their Host delivery
/// context around every drain call.
pub fn glowcap_host_next_action(host: ?*GlowcapHost, out_action: ?*GlowcapHostAction) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_actions.next(host, out_action);
}

/// Internal half of `glowcap_host_pump_drain`'s transactional callback
/// contract. The public pull queue remains consume-on-pop. Only the convenience
/// pump can reject an arm before commit and ask for the same borrowed action to
/// be projected again.
pub fn retryBorrowedAction(host: ?*GlowcapHost) bool {
    return host_actions.retryBorrowed(host);
}

/// Report a DIAL action's success: `session` is opened by
/// `glowcap_host_session_open_dialed_locator` against the pending dial for that
/// ticket and route (`glowcap_host_pending_dial`), driven to an open session. The node adopts it for every give waiting on the ticket.
/// The bounded Host pump advances resulting work before return, with pressure
/// retained for the next action drain. A stale or non-running attempt is a
/// no-op success with `out_adopted` set to zero.
pub fn glowcap_host_dialed(
    host: ?*GlowcapHost,
    ticket: u64,
    route_index: usize,
    raw: ?*GlowcapHostSession,
    out_adopted: ?*u8,
) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_actions.dialed(host, ticket, route_index, raw, out_adopted);
}

/// Report a DIAL action's failure: every redeem waiting on the ticket breaks
/// with `reason`, its FAIL completion queued inside this call. A stale or
/// non-running attempt is a no-op success.
pub fn glowcap_host_dial_failed(host: ?*GlowcapHost, ticket: u64, route_index: usize, reason: ?[*]const u8, reason_len: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_actions.dialFailed(host, ticket, route_index, reason, reason_len);
}

/// A CANCEL_DIAL action's physical operation has stopped and its executor
/// state can be released. Host close remains pending until this acknowledgement.
pub fn glowcap_host_dial_cancelled(host: ?*GlowcapHost, ticket: u64, route_index: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_actions.dialCancelled(host, ticket, route_index);
}

/// Answer a NEED_GIFT_ID action with 32 caller-drawn random bytes: the node
/// originates the claimed handoff and this call flushes its legs, exporter
/// first. A stale ticket is a no-op success.
pub fn glowcap_host_provide_gift_id(host: ?*GlowcapHost, ticket: u64, gift_id: ?[*]const u8, gift_id_len: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_actions.provideGiftId(host, ticket, gift_id, gift_id_len);
}

/// Report that a NEED_GIFT_ID action could not obtain or provide entropy. The
/// claimed handoff settles broken instead of retaining a ticket the embedder
/// has already consumed. A stale ticket is a no-op success.
pub fn glowcap_host_gift_id_failed(host: ?*GlowcapHost, ticket: u64) callconv(.c) i32 {
    shared.lastErrorClear();
    return host_actions.giftIdFailed(host, ticket);
}

// ── GC and diagnostics ───────────────────────────────────────────────────────

/// Release `delta` application retains on one opaque Host capability. The Host
/// resolves the owning session itself. Callers never pair a handle with a
/// session-local wire position. If that session already closed, its
/// already-issued application units remain releaseable as wire-free success.
/// Every other use is stale. A non-OK return commits no release, so the same
/// `(ref, delta)` may be retried. OK consumes the release. Any later pump
/// cleanup failure is converted into typed session close and must not invite a
/// duplicate release. Single-thread affinity applies.
pub fn glowcap_host_ref_release(host: ?*GlowcapHost, ref: ?*const shared.GlowcapReference, delta: u64) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return GLOWCAP_ERR_NULL_POINTER;
    const raw = ref orelse return GLOWCAP_ERR_NULL_POINTER;
    inst.core.releaseCapability(inst.core.capabilityFromRaw(raw.id), delta) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Read the calling thread's last `glowcap_host_*` error into `out_buf`,
/// NUL-terminated when `cap > 0`. `out_buf == NULL` or `cap == 0` queries the
/// length. Returns the full message length, or 0 when none is set.
pub fn glowcap_host_last_error(out_buf: ?[*]u8, cap: usize) callconv(.c) usize {
    return shared.lastErrorRead(out_buf, cap);
}

/// Clear the calling thread's `glowcap_host_*` last-error slot.
pub fn glowcap_host_clear_last_error() callconv(.c) void {
    shared.lastErrorClear();
}
