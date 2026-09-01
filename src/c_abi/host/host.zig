//! Host lifecycle and the host-wide surfaces for `libpancake_host`: create /
//! release, the pure dial / accept planners, the embedder action queue
//! (`pancake_host_next_action` and the DIAL / gift-id completions), the
//! host-wide giftable publish, GC release, and the archive's own last-error
//! slot. The advertised-locator verbs live in `locators.zig`, the per-session
//! verbs in `session.zig`, the turn-time verbs in `turn.zig`, and the
//! convenience drain in `pump.zig`; the module root (`mod.zig`) owns the
//! public C types these exports fill.

const std = @import("std");

const foundation = @import("foundation");
const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");
const capability_ids = @import("capability_ids.zig");
const host_actions = @import("actions.zig");
const host_lifecycle = @import("lifecycle.zig");
const host_plan = @import("plan.zig");
const host_publications = @import("publications.zig");
const host_trace = @import("trace.zig");

const crypto = foundation.crypto;

const Instance = common.Instance;
const Host = common.Host;
const instanceFrom = common.instanceFrom;
const errToCode = common.errToCode;

const PancakeContext = c.PancakeContext;
const PancakeHost = c.PancakeHost;
const PancakeHostSession = c.PancakeHostSession;
const PancakeHostAction = c.PancakeHostAction;
const PancakeDialPlan = c.PancakeDialPlan;

const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_INTERNAL = shared.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_WOULD_BLOCK = shared.PANCAKE_ERR_WOULD_BLOCK;

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
    out_host: ?*?*PancakeHost,
) i32 {
    const slot = out_host orelse return PANCAKE_ERR_NULL_POINTER;
    const seed_nn = seed_ptr orelse return PANCAKE_ERR_NULL_POINTER;
    if (frame_cap == 0) {
        shared.setLastError("host: frame_cap must be nonzero", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    // One buffer, two independent inputs (ADR-0097). The first 32 bytes are
    // the host's durable identity and must stay stable across restarts — a
    // keyed locator's designator is derived from them. The next 32 are the
    // session-key root, and they must be *fresh per process*: they are what
    // makes each session sign with its own key, and what stops a restarted
    // host recreating a prior session's handoff names. A durable-only 32-byte
    // seed is refused here so CapTP session keys cannot silently reuse the
    // identity seed (ADR-0100 names that footgun on the bare Zig Host).
    const session_root_len = crypto.SEED_BYTES * 2;
    if (seed_len != session_root_len) {
        shared.setLastError(
            "host: seed must be {d} bytes (durable identity followed by a fresh session-key root)",
            .{session_root_len},
        );
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    const codec_id = shared.codecFromC(codec) orelse {
        shared.setLastError("host: codec must be a PANCAKE_CODEC_* value", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    const version_id = shared.captpVersionFromC(captp_version) orelse {
        shared.setLastError("host: captp_version must be a PANCAKE_CAPTP_* value", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    const feature_set = shared.featureSetFromC(features) orelse {
        shared.setLastError("host: features must be a PANCAKE_FEATURE_* bitmask", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    const inst = alloc.create(Instance) catch |err| return errToCode(err);
    var opts = Host.Options.withFrameCap(frame_cap);
    opts.verify_partner = verify_partner != 0;
    opts.codec = codec_id;
    opts.captp_version = version_id;
    opts.features = feature_set;
    opts.local_turn_budget = if (local_turn_budget == 0) null else local_turn_budget;
    opts.capability_id_issuer = capability_ids.issuer(seed_nn[0..crypto.SEED_BYTES].*);
    const core = Host.init(
        alloc,
        seed_nn[0..crypto.SEED_BYTES].*,
        seed_nn[crypto.SEED_BYTES..session_root_len].*,
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
    return PANCAKE_OK;
}

/// Create a byte-fed host bound to a caller-drawn 64-byte seed buffer: the
/// durable Ed25519 identity in the first 32 bytes, then a fresh per-process
/// session-key root (ADR-0097). The host never draws entropy. `frame_cap`
/// sizes every session's maximum admissible frame;
/// a nonzero `verify_partner` keeps partner-signature verification on (the
/// secure default); `codec`, `captp_version`, and `features` are this host's
/// preferred profile offer. The signed hello carries them as locator hints,
/// and each session settles them with its partner. `local_turn_budget` is 0
/// for unbounded (the same default as Zig Host + Bridge) or a nonzero cap on
/// local-turn amplification per drive (ADR-0076). Released with
/// `pancake_host_release`.
pub export fn pancake_host_new(
    seed: ?[*]const u8,
    seed_len: usize,
    frame_cap: usize,
    verify_partner: u32,
    codec: u32,
    captp_version: u32,
    features: u32,
    local_turn_budget: u32,
    out_host: ?*?*PancakeHost,
) i32 {
    shared.lastErrorClear();
    return hostNewIn(shared.library_allocator, 0, seed, seed_len, frame_cap, verify_partner, codec, captp_version, features, local_turn_budget, out_host);
}

/// `pancake_host_new` allocating every byte the host owns through `context`'s
/// host allocator.
pub export fn pancake_host_new_in(
    context: ?*PancakeContext,
    seed: ?[*]const u8,
    seed_len: usize,
    frame_cap: usize,
    verify_partner: u32,
    codec: u32,
    captp_version: u32,
    features: u32,
    local_turn_budget: u32,
    out_host: ?*?*PancakeHost,
) i32 {
    shared.lastErrorClear();
    const ctx = shared.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const diagnostic_id = ctx.lifecycle_ids.allocate() catch {
        shared.setLastError("host: Context lifecycle identity space exhausted", .{});
        return PANCAKE_ERR_INTERNAL;
    };
    return hostNewIn(ctx.allocator(), diagnostic_id, seed, seed_len, frame_cap, verify_partner, codec, captp_version, features, local_turn_budget, out_host);
}

/// Return this Host's stable identity in its owning Context's diagnostic
/// namespace. The context-less convenience constructor reports zero because it
/// has no Context diagnostic namespace to allocate from.
pub export fn pancake_host_diagnostic_id(host: ?*PancakeHost, out_id: ?*u64) i32 {
    shared.lastErrorClear();
    return host_lifecycle.diagnosticId(host, out_id);
}

/// Seal application admission and begin or escalate terminal Host close. The
/// byte-fed embedder supplies its monotonic clock reading; shared Zig state
/// retains the first deadline and owns expiry semantics.
pub export fn pancake_host_close(
    host: ?*PancakeHost,
    options: ?*const c.PancakeCloseOptions,
    now_ms: i64,
) i32 {
    shared.lastErrorClear();
    return host_lifecycle.close(host, options, now_ms);
}

/// Apply the caller's current monotonic time to a byte-fed Host close. This
/// performs no I/O: expiry may only escalate FINISH to the core's CANCEL path.
pub export fn pancake_host_close_progress(host: ?*PancakeHost, now_ms: i64, out_state: ?*u32) i32 {
    shared.lastErrorClear();
    return host_lifecycle.closeProgress(host, now_ms, out_state);
}

/// The longest a close driver may wait for new input before calling
/// `pancake_host_close_progress` again: milliseconds until the nearest FINISH
/// grace deadline, the Host's own or any session's, clamped at zero. Writes -1
/// when no finite deadline is pending, meaning only feed, action-drain,
/// settle, or escalation activity can advance terminal progress, so the
/// embedder may park on activity alone. Poll-shaped on purpose: the value
/// drops straight into a wait primitive's timeout argument.
pub export fn pancake_host_close_wait_ms(host: ?*PancakeHost, now_ms: i64, out_wait_ms: ?*i64) i32 {
    shared.lastErrorClear();
    return host_lifecycle.closeWaitMs(host, now_ms, out_wait_ms);
}

/// Observe the byte-fed Host lifecycle without advancing it. The embedder
/// advances terminal progress through the ordinary feed/action-drain cycle.
pub export fn pancake_host_lifecycle_state(host: ?*PancakeHost, out_state: ?*u32) i32 {
    shared.lastErrorClear();
    return host_lifecycle.state(host, out_state);
}

/// Release the host and everything it owns: every still-open session
/// (each still-parked vow breaks inside this call, its undrained completion
/// freed with the rest of the action queue), the vow map, parked actions,
/// the node, and the giftable rows (each giftable's `free` runs exactly once
/// here). Null is a no-op. HostSession (`PancakeHostSession`) handles this host minted
/// are freed with it — release the sessions first if you hold them, and never
/// touch one after its host is gone. Because release is terminal, an embedder
/// may transfer exclusive ownership to a finalizer thread after every Host call
/// has returned; no live Host verb gains cross-thread permission. Refused (with
/// the last error set) from inside a callback.
pub fn release(host: ?*PancakeHost) i32 {
    return host_lifecycle.release(host);
}

pub export fn pancake_host_release(host: ?*PancakeHost) i32 {
    shared.lastErrorClear();
    return release(host);
}

// ── Dial / accept planning (driver_core.planDial / planAccept) ────────────────
//
// The transport dispatch, designator validation, host:port resolution, and
// peer-id reachability decision every language binding used to re-express in
// its own connect / dial_exporter / Server.accept. A binding calls the planner,
// opens the byte channel the plan names in its own runtime, then feeds it back
// through pancake_host_session_open_dialed_locator /
// pancake_host_session_open_accepted. The plan is pure: no socket, no
// allocation, every view borrowing the caller input.

/// Project the complete in-flight locator for `ticket` through caller-owned
/// hint storage. A null `hint_storage` with zero capacity probes the required
/// hint count. On BUFFER_TOO_SMALL, `out_hint_count` reports the exact capacity
/// and `out_locator` is untouched.
pub export fn pancake_host_pending_dial(
    host: ?*PancakeHost,
    ticket: u64,
    route_index: usize,
    hint_storage: ?[*]c.PancakeLocatorHintView,
    hint_capacity: usize,
    out_locator: ?*c.PancakeLocatorView,
    out_hint_count: ?*usize,
) i32 {
    shared.lastErrorClear();
    return host_plan.pendingDial(host, ticket, route_index, hint_storage, hint_capacity, out_locator, out_hint_count);
}

/// The live session homing remote `reference`, into `*out_session`, or NULL for
/// a local, stale, foreign-Host, or closed-session capability. Bindings use this
/// after a send to distinguish a capability homed on the sending session from
/// one redeemed onto another exporter session. The result comes from the
/// reference's own Host row, with no dial-completion capture window. The handle
/// is Host-owned and lives with that session; do not release it here.
pub export fn pancake_host_reference_exporter(
    host: ?*PancakeHost,
    reference: ?*const shared.PancakeReference,
    out_session: ?*?*PancakeHostSession,
) i32 {
    shared.lastErrorClear();
    return host_plan.referenceExporter(host, reference, out_session);
}

/// Project one pure Zig dial plan; all output views borrow the caller's input.
pub export fn pancake_host_plan_dial(
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    direct_addresses_hint: ?[*]const u8,
    direct_addresses_hint_len: usize,
    posture_policy: u32,
    posture_value: u32,
    out_plan: ?*PancakeDialPlan,
) i32 {
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

/// Install or clear the synchronous borrowed trace callback.
pub export fn pancake_host_set_trace(
    host: ?*PancakeHost,
    callback: ?c.PancakeTraceCallback,
    ctx: ?*anyopaque,
) i32 {
    shared.lastErrorClear();
    return host_trace.setTrace(host, callback, ctx);
}

/// Install, replace, or clear the bounded pull-based trace queue.
pub export fn pancake_host_set_trace_queue(
    host: ?*PancakeHost,
    capacity: usize,
    payload_cap: usize,
) i32 {
    shared.lastErrorClear();
    return host_trace.setTraceQueue(host, capacity, payload_cap);
}

/// Pop one trace record, borrowed until the next pop; WOULD_BLOCK when empty.
pub export fn pancake_host_next_trace(
    host: ?*PancakeHost,
    out: ?*c.PancakeTraceEvent,
) i32 {
    shared.lastErrorClear();
    return host_trace.nextTrace(host, out);
}

/// Fulfill one resolver with a capability-free value, consuming on success.
pub export fn pancake_host_resolver_fulfill(
    host: ?*PancakeHost,
    resolver_id: u64,
    value: ?*const shared.PancakeArgument,
) i32 {
    shared.lastErrorClear();
    return host_actions.resolverFulfill(host, resolver_id, value);
}

/// Settle a resolver vow broken with a diagnostic borrowed for the call. The
/// same top-level, consume-on-success contract as pancake_host_resolver_fulfill.
pub export fn pancake_host_resolver_break(
    host: ?*PancakeHost,
    resolver_id: u64,
    message: ?[*]const u8,
    message_len: usize,
) i32 {
    shared.lastErrorClear();
    return host_actions.resolverBreak(host, resolver_id, message, message_len);
}

/// Enliven a sturdyref now or stage its dial; settlement returns as an action.
pub export fn pancake_host_enliven(
    host: ?*PancakeHost,
    sturdyref_uri: ?[*]const u8,
    sturdyref_uri_len: usize,
    out_vow: ?*u64,
) i32 {
    shared.lastErrorClear();
    return host_actions.enliven(host, sturdyref_uri, sturdyref_uri_len, out_vow);
}

/// Enliven using the CapTP profile that defined the sturdyref's swiss spelling.
pub export fn pancake_host_enliven_for_version(
    host: ?*PancakeHost,
    captp_version: u32,
    sturdyref_uri: ?[*]const u8,
    sturdyref_uri_len: usize,
    out_vow: ?*u64,
) i32 {
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
pub export fn pancake_host_fetch_at(
    host: ?*PancakeHost,
    locator: ?*const shared.PancakeLocatorView,
    name: ?[*]const u8,
    name_len: usize,
    out_vow: ?*u64,
) i32 {
    shared.lastErrorClear();
    return host_actions.fetchAt(host, locator, name, name_len, out_vow);
}

// ── The action queue ─────────────────────────────────────────────────────────

/// Pop one borrowed Host action, or WOULD_BLOCK without consuming anything.
/// Before the pop, queued Host work resumes and may synchronously invoke a
/// `PancakeHostBehavior`; binding runtimes must install their Host delivery
/// context around every drain call.
pub export fn pancake_host_next_action(host: ?*PancakeHost, out_action: ?*PancakeHostAction) i32 {
    shared.lastErrorClear();
    return host_actions.next(host, out_action);
}

/// Internal half of `pancake_host_pump_drain`'s transactional callback
/// contract. The public pull queue remains consume-on-pop; only the convenience
/// pump can reject an arm before commit and ask for the same borrowed action to
/// be projected again.
pub fn retryBorrowedAction(host: ?*PancakeHost) bool {
    return host_actions.retryBorrowed(host);
}

/// Report a DIAL action's success: `session` is an `open_dialed_locator` against
/// the pending dial for that ticket and route (`pancake_host_pending_dial`), driven to an
/// open session. The node adopts it for every give waiting on the ticket;
/// the bounded Host pump advances resulting work before return, with pressure
/// retained for the next action drain. A stale or non-running attempt is a
/// no-op success with `out_adopted` set to zero.
pub export fn pancake_host_dialed(
    host: ?*PancakeHost,
    ticket: u64,
    route_index: usize,
    raw: ?*PancakeHostSession,
    out_adopted: ?*u8,
) i32 {
    shared.lastErrorClear();
    return host_actions.dialed(host, ticket, route_index, raw, out_adopted);
}

/// Report a DIAL action's failure: every redeem waiting on the ticket breaks
/// with `reason`, its FAIL completion queued inside this call. A stale or
/// non-running attempt is a no-op success.
pub export fn pancake_host_dial_failed(host: ?*PancakeHost, ticket: u64, route_index: usize, reason: ?[*]const u8, reason_len: usize) i32 {
    shared.lastErrorClear();
    return host_actions.dialFailed(host, ticket, route_index, reason, reason_len);
}

/// A CANCEL_DIAL action's physical operation has stopped and its executor
/// state can be released. Host close remains pending until this acknowledgement.
pub export fn pancake_host_dial_cancelled(host: ?*PancakeHost, ticket: u64, route_index: usize) i32 {
    shared.lastErrorClear();
    return host_actions.dialCancelled(host, ticket, route_index);
}

/// Answer a NEED_GIFT_ID action with 32 caller-drawn random bytes: the node
/// originates the claimed handoff and this call flushes its legs, exporter
/// first. A stale ticket is a no-op success.
pub export fn pancake_host_provide_gift_id(host: ?*PancakeHost, ticket: u64, gift_id: ?[*]const u8, gift_id_len: usize) i32 {
    shared.lastErrorClear();
    return host_actions.provideGiftId(host, ticket, gift_id, gift_id_len);
}

/// Report that a NEED_GIFT_ID action could not obtain or provide entropy. The
/// claimed handoff settles broken instead of retaining a ticket the embedder
/// has already consumed. A stale ticket is a no-op success.
pub export fn pancake_host_gift_id_failed(host: ?*PancakeHost, ticket: u64) i32 {
    shared.lastErrorClear();
    return host_actions.giftIdFailed(host, ticket);
}

// ── Host-wide publish ────────────────────────────────────────────────────────

/// Publish one hosted object in the Vat owned by this Host and bind `name` as its host-wide
/// alias. Fetch lazily projects the actor onto the requesting Port; a deposited
/// gift retains the exact actor and never consults the alias at withdrawal. The
/// giftable row owns `ctx` —
/// `free`, if non-null, runs exactly once: at `pancake_host_release` on
/// success, or before this returns on any non-OK outcome (except the
/// null-pointer and reentry refusals, which touch nothing and leave ctx the
/// caller's). All-or-nothing over this call's own work: registration failure
/// discards the fresh actor and frees `ctx`, so a retry starts with no partial
/// alias or projection.
pub export fn pancake_host_publish(
    host: ?*PancakeHost,
    name: ?[*]const u8,
    name_len: usize,
    behavior: ?c.PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?c.PancakeHostCtxFree,
) i32 {
    shared.lastErrorClear();
    return host_publications.publish(host, name, name_len, behavior, ctx, free);
}

/// Publish one hosted object under a freshly minted durable swiss name
/// (ADR-0098): the reserved-prefix namespace, unpredictable, never
/// reassigned, removable only through `pancake_host_remove_durable`, and
/// structurally disjoint from every mutable alias. `entropy` supplies
/// exactly PANCAKE_HOST_DURABLE_ENTROPY_LEN caller-drawn random bytes — the
/// embedder owns the entropy boundary, as it does for gift ids. The minted
/// swiss (the name to place in a sturdyref beside this host's own locator)
/// is written into `out_swiss`; `swiss_cap` must be at least
/// PANCAKE_HOST_DURABLE_SWISS_LEN or the call refuses BUFFER_TOO_SMALL and
/// publishes nothing. Returns the written length. `ctx`/`free` follow
/// `pancake_host_publish`'s ownership exactly.
pub export fn pancake_host_publish_durable(
    host: ?*PancakeHost,
    entropy: ?[*]const u8,
    entropy_len: usize,
    behavior: ?c.PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?c.PancakeHostCtxFree,
    out_swiss: ?[*]u8,
    swiss_cap: usize,
) i32 {
    shared.lastErrorClear();
    return host_publications.publishDurable(
        host,
        entropy,
        entropy_len,
        behavior,
        ctx,
        free,
        out_swiss,
        swiss_cap,
    );
}

/// Remove a minted durable publication (ADR-0098): the old sturdyref misses
/// from now on, while capabilities already issued and deposited gifts keep
/// the exact actor. A swiss outside the reserved durable namespace returns
/// PANCAKE_ERR_INVALID_ARGUMENT (mutable aliases leave through
/// `pancake_host_unpublish`); an unknown durable name returns
/// PANCAKE_ERR_NOT_FOUND.
pub export fn pancake_host_remove_durable(
    host: ?*PancakeHost,
    swiss: ?[*]const u8,
    swiss_len: usize,
) i32 {
    shared.lastErrorClear();
    return host_publications.removeDurable(host, swiss, swiss_len);
}

/// Remove the host-wide alias `name`. Discovery-only, alias-only (ADR-0096): a
/// later fetch of the name misses on every session, while capabilities already
/// issued, live Port projections, and deposited gifts keep naming the exact
/// actor, which stays in the Host's Vat until `pancake_host_release`. An
/// absent alias returns PANCAKE_ERR_NOT_FOUND, so a typo is loud instead of an
/// idempotent no-op.
pub export fn pancake_host_unpublish(
    host: ?*PancakeHost,
    name: ?[*]const u8,
    name_len: usize,
) i32 {
    shared.lastErrorClear();
    return host_publications.unpublish(host, name, name_len);
}

// ── GC and diagnostics ───────────────────────────────────────────────────────

/// Release `delta` application retains on one opaque Host capability. The Host
/// resolves the owning session itself; callers never pair a handle with a
/// session-local wire position. If that session already closed, its
/// already-issued application units remain releaseable as wire-free success;
/// every other use is stale. A non-OK return commits no release, so the same
/// `(ref, delta)` may be retried. OK consumes the release; any later pump
/// cleanup failure is converted into typed session close and must not invite a
/// duplicate release. Single-thread affinity applies.
pub export fn pancake_host_ref_release(host: ?*PancakeHost, ref: ?*const shared.PancakeReference, delta: u64) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const raw = ref orelse return PANCAKE_ERR_NULL_POINTER;
    inst.core.releaseCapability(inst.core.capabilityFromRaw(raw.id), delta) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Read the calling thread's last `pancake_host_*` error into `out_buf`,
/// NUL-terminated when `cap > 0`. `out_buf == NULL` or `cap == 0` queries the
/// length. Returns the full message length, or 0 when none is set.
pub export fn pancake_host_last_error(out_buf: ?[*]u8, cap: usize) usize {
    return shared.lastErrorRead(out_buf, cap);
}

/// Clear the calling thread's `pancake_host_*` last-error slot.
pub export fn pancake_host_clear_last_error() void {
    shared.lastErrorClear();
}
