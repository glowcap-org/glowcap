//! Host lifecycle and the host-wide surfaces for `libpancake_host`: create /
//! release, the identity designator helpers, the pure dial / accept planners,
//! the embedder action queue (`pancake_host_next_action` and the DIAL / gift-id
//! completions), the host-wide giftable publish, GC release, and the archive's
//! own last-error slot. The per-session verbs live in `session.zig`, the
//! turn-time verbs in `turn.zig`, and the convenience drain in `pump.zig`; the
//! module root (`mod.zig`) owns the public C types these exports fill.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const driver_core = @import("driver_core");

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");
const capability_ids = @import("capability_ids.zig");
const trace_queue = @import("trace_queue.zig");

const crypto = foundation.crypto;

const Instance = common.Instance;
const Host = common.Host;
const instanceFrom = common.instanceFrom;
const setView = common.setView;
const sessionFrom = common.sessionFrom;
const instOf = common.instOf;
const errToCode = common.errToCode;
const preflightHostedTransfer = common.preflightHostedTransfer;
const steady_scratch_bytes = common.steady_scratch_bytes;

const PancakeContext = c.PancakeContext;
const PancakeHost = c.PancakeHost;
const PancakeHostSession = c.PancakeHostSession;
const PancakeHostAction = c.PancakeHostAction;
const PancakeDialPlan = c.PancakeDialPlan;
const PancakeAcceptPlan = c.PancakeAcceptPlan;

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
    const ctx = shared.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const diagnostic_id = ctx.lifecycle_ids.allocate() catch {
        shared.setLastError("host: Context lifecycle identity space exhausted", .{});
        return PANCAKE_ERR_INTERNAL;
    };
    return hostNewIn(ctx.allocator(), diagnostic_id, seed, seed_len, frame_cap, verify_partner, codec, captp_version, features, local_turn_budget, out_host);
}

/// Return this Host's stable identity in its owning Context's diagnostic
/// namespace. The context-less compatibility constructor reports zero.
pub export fn pancake_host_diagnostic_id(host: ?*PancakeHost, out_id: ?*u64) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_id orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = inst.diagnostic_id;
    return PANCAKE_OK;
}

fn progressHostClose(inst: *common.Instance, now_ms: i64) i32 {
    inst.core.progressClose(now_ms) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

fn projectHostLifecycle(inst: *const common.Instance) u32 {
    return switch (inst.core.lifecyclePhase()) {
        .active => c.PANCAKE_LIFECYCLE_ACTIVE,
        .finishing => c.PANCAKE_LIFECYCLE_FINISHING,
        .terminating => c.PANCAKE_LIFECYCLE_TERMINATING,
        .closed => c.PANCAKE_LIFECYCLE_CLOSED,
    };
}

fn hostCloseOutcomeCode(inst: *const common.Instance) i32 {
    return if (inst.core.closeOutcome(inst.core.lifecyclePhase() == .closed) == .timed_out)
        shared.PANCAKE_ERR_TIMEOUT
    else
        PANCAKE_OK;
}

/// Seal application admission and begin or escalate terminal Host close. The
/// byte-fed embedder supplies its monotonic clock reading; shared Zig state
/// retains the first deadline and owns expiry semantics.
pub export fn pancake_host_close(
    host: ?*PancakeHost,
    options: ?*const c.PancakeCloseOptions,
    now_ms: i64,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "close")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const policy = c.parseCloseOptions(options) catch |err| return c.closeOptionsErrorCode("host", err);
    inst.core.beginClose(policy, now_ms);
    return PANCAKE_OK;
}

/// Apply the caller's current monotonic time to a byte-fed Host close. This
/// performs no I/O: expiry may only escalate FINISH to the core's CANCEL path.
pub export fn pancake_host_close_progress(host: ?*PancakeHost, now_ms: i64, out_state: ?*u32) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "close_progress")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const slot = out_state orelse return PANCAKE_ERR_NULL_POINTER;
    const rc = progressHostClose(inst, now_ms);
    if (rc != PANCAKE_OK) return rc;
    slot.* = projectHostLifecycle(inst);
    return hostCloseOutcomeCode(inst);
}

/// The longest a close driver may wait for new input before calling
/// `pancake_host_close_progress` again: milliseconds until the nearest FINISH
/// grace deadline, the Host's own or any session's, clamped at zero. Writes -1
/// when no finite deadline is pending, meaning only feed, action-drain,
/// settle, or escalation activity can advance terminal progress, so the
/// embedder may park on activity alone. Poll-shaped on purpose: the value
/// drops straight into a wait primitive's timeout argument.
pub export fn pancake_host_close_wait_ms(host: ?*PancakeHost, now_ms: i64, out_wait_ms: ?*i64) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "close_wait_ms")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const slot = out_wait_ms orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = inst.core.closeWaitMs(now_ms);
    return PANCAKE_OK;
}

/// Observe the byte-fed Host lifecycle without advancing it. The embedder
/// advances terminal progress through the ordinary feed/action-drain cycle.
pub export fn pancake_host_lifecycle_state(host: ?*PancakeHost, out_state: ?*u32) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "lifecycle_state")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const slot = out_state orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = projectHostLifecycle(inst);
    return hostCloseOutcomeCode(inst);
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
    const inst = instanceFrom(host) orelse return PANCAKE_OK;
    if (inst.drive_owner == .driver) {
        shared.setLastError("host: release refused because the driver owns this host", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    inst.core.checkReleaseOwnershipTransfer() catch |err| return errToCode(err);
    if (common.releaseInstance(inst)) |failure| return errToCode(failure);
    return PANCAKE_OK;
}

pub export fn pancake_host_release(host: ?*PancakeHost) i32 {
    return release(host);
}

/// Derive the canonical key designator (exactly 64 lowercase hex digits) from
/// a 32-byte Ed25519 durable-identity seed — the public half represented by
/// the first half of `pancake_host_new`'s 64-byte input. Session signing keys
/// derive from that input's fresh second half instead. Writes 64 bytes into
/// `out` (`out_len` must be at least 64). A keyed-tcp listener uses this so its
/// locator designator names the Host's durable identity (ADR-0075, ADR-0097).
pub export fn pancake_host_designator_from_seed(
    seed: ?[*]const u8,
    seed_len: usize,
    out: ?[*]u8,
    out_len: usize,
) i32 {
    if (seed_len != foundation.crypto.SEED_BYTES) {
        shared.setLastError("host: designator_from_seed: seed_len must be 32", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    const seed_bytes = shared.sliceFromC(seed, seed_len) catch |err| return shared.marshalErrorToCode(err);
    const out_buf = out orelse return PANCAKE_ERR_NULL_POINTER;
    if (out_len < foundation.crypto.PeerKey.designator_len) {
        shared.setLastError("host: designator_from_seed: out_len must be at least 64", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    var seed_arr: [foundation.crypto.SEED_BYTES]u8 = undefined;
    @memcpy(&seed_arr, seed_bytes);
    const designator = foundation.crypto.SecretKey.fromSeed(seed_arr).publicKey().toDesignator();
    @memcpy(out_buf[0..designator.len], &designator);
    return PANCAKE_OK;
}

/// Retain and select this host's complete acceptable location. The Host
/// validates and deep-copies the borrowed locator view before returning.
pub export fn pancake_host_set_advertised_locator(host: ?*PancakeHost, locator: ?*const shared.PancakeLocatorView) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "set_advertised_locator")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const view = locator orelse return PANCAKE_ERR_NULL_POINTER;
    var hint_stack: [shared.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = shared.locator_adapter.BorrowedLocator.init(inst.allocator, view, &hint_stack) catch |err| {
        if (err == error.OutOfMemory) return errToCode(err);
        shared.setLastError("host: set_advertised_locator received an invalid locator view", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    defer borrowed.deinit(inst.allocator);
    inst.core.setAdvertisedLocator(borrowed.value) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Retain the deterministic dial fallback for `transport` without displacing
/// an acceptable location already selected for another transport.
pub export fn pancake_host_ensure_advertised_locator(host: ?*PancakeHost, transport: ?[*]const u8, transport_len: usize) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "ensure_advertised_locator")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const bytes = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    inst.core.ensureAdvertisedLocator(bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Remove the retained locator for `transport`. Removing the selected route
/// leaves no acceptable location. Existing sessions retain their signed hello.
pub export fn pancake_host_remove_advertised_locator(host: ?*PancakeHost, transport: ?[*]const u8, transport_len: usize) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "remove_advertised_locator")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const bytes = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    inst.core.removeAdvertisedLocator(bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Selective session-limit knobs (ADR-0082): override admission, `queue_cap`,
/// and/or outbound high-water on a host before minting sessions. Pass `0` for a
/// field to leave it unchanged. Peers already open keep the limits they were
/// minted with; later mints see the updated `Host.Options`.
pub export fn pancake_host_set_session_limits(
    host: ?*PancakeHost,
    max_frame_bytes: usize,
    queue_cap: usize,
    outbound_high_water_bytes: usize,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "set_session_limits")) return PANCAKE_ERR_INVALID_ARGUMENT;
    inst.core.setSessionLimits(
        if (max_frame_bytes != 0) max_frame_bytes else null,
        if (queue_cap != 0) queue_cap else null,
        if (outbound_high_water_bytes != 0) outbound_high_water_bytes else null,
    ) catch |err| return errToCode(err);
    return PANCAKE_OK;
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
/// hint storage. On BUFFER_TOO_SMALL, `out_hint_count` reports the required
/// capacity and `out_locator` is untouched.
pub export fn pancake_host_pending_dial(
    host: ?*PancakeHost,
    ticket: u64,
    hint_storage: ?[*]c.PancakeLocatorHintView,
    hint_capacity: usize,
    out_locator: ?*c.PancakeLocatorView,
    out_hint_count: ?*usize,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "pending_dial")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const locator_slot = out_locator orelse return PANCAKE_ERR_NULL_POINTER;
    const count_slot = out_hint_count orelse return PANCAKE_ERR_NULL_POINTER;
    const view = inst.core.pendingDial(ticket) orelse {
        shared.setLastError("host: pending dial: unknown ticket {d}", .{ticket});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    count_slot.* = view.hints.entries.len;
    if (hint_capacity < view.hints.entries.len) return shared.PANCAKE_ERR_BUFFER_TOO_SMALL;
    if (view.hints.entries.len == 0) {
        var no_hints: [0]c.PancakeLocatorHintView = .{};
        locator_slot.* = shared.locator_adapter.project(view, &no_hints) catch
            return PANCAKE_ERR_INVALID_ARGUMENT;
    } else {
        const hints = (hint_storage orelse return PANCAKE_ERR_NULL_POINTER)[0..view.hints.entries.len];
        locator_slot.* = shared.locator_adapter.project(view, hints) catch
            return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    return PANCAKE_OK;
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
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_session orelse return PANCAKE_ERR_NULL_POINTER;
    const ref_ptr = reference orelse return PANCAKE_ERR_NULL_POINTER;
    const ref = inst.core.capabilityFromRaw(ref_ptr.id);
    slot.* = if (inst.core.capabilitySession(ref)) |session| @ptrCast(session) else null;
    return PANCAKE_OK;
}

/// Resolve a dial without opening a socket. transport/designator are the
/// locator's pieces (from `pancake_uri_parse_peer` on a pending dial locator);
/// direct_addresses_hint is the locator's direct-addresses hint (NULL/0 = none);
/// posture_policy is a PANCAKE_DIAL_POSTURE_* selecting the peer-id reachability
/// rule, with posture_value the caller's posture under
/// PANCAKE_DIAL_POSTURE_EXPLICIT. On PANCAKE_OK *out_plan is filled with views
/// borrowing the caller's buffers; on a bad locator it returns
/// PANCAKE_ERR_INVALID_ARGUMENT (see pancake_host_last_error).
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
    const slot = out_plan orelse return PANCAKE_ERR_NULL_POINTER;
    const t = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    const d = shared.sliceFromC(designator, designator_len) catch |err| return shared.marshalErrorToCode(err);
    const h = shared.sliceFromC(direct_addresses_hint, direct_addresses_hint_len) catch |err| return shared.marshalErrorToCode(err);
    const posture: driver_core.DialPosture = switch (posture_policy) {
        c.PANCAKE_DIAL_POSTURE_REDEEM => .redeem,
        c.PANCAKE_DIAL_POSTURE_EXPLICIT => .{ .explicit = posture_value },
        c.PANCAKE_DIAL_POSTURE_EXPLICIT_NONE => .explicit_none,
        else => {
            shared.setLastError("host: plan_dial: unknown posture policy {d}", .{posture_policy});
            return PANCAKE_ERR_INVALID_ARGUMENT;
        },
    };
    const plan = driver_core.planDial(t, d, h, posture) catch |err| return errToCode(err);
    slot.reach_value = 0;
    switch (plan) {
        .host_port => |hp| {
            slot.shape = c.PANCAKE_DIAL_SHAPE_HOST_PORT;
            setView(hp.host, &slot.host, &slot.host_len);
            slot.port = hp.port;
            setView(&.{}, &slot.addresses, &slot.addresses_len);
            slot.reach_kind = c.PANCAKE_DIAL_REACH_DIRECT; // unused on host_port
        },
        .peer_id => |peer| {
            slot.shape = c.PANCAKE_DIAL_SHAPE_PEER_ID;
            setView(&.{}, &slot.host, &slot.host_len);
            slot.port = 0;
            setView(peer.addresses, &slot.addresses, &slot.addresses_len);
            slot.reach_kind = switch (peer.reach) {
                .direct => c.PANCAKE_DIAL_REACH_DIRECT,
                .configured => c.PANCAKE_DIAL_REACH_CONFIGURED,
                .explicit => |v| blk: {
                    slot.reach_value = v;
                    break :blk c.PANCAKE_DIAL_REACH_EXPLICIT;
                },
            };
        },
        .signaling => {
            slot.shape = c.PANCAKE_DIAL_SHAPE_SIGNALING;
            setView(&.{}, &slot.host, &slot.host_len);
            slot.port = 0;
            setView(&.{}, &slot.addresses, &slot.addresses_len);
            slot.reach_kind = c.PANCAKE_DIAL_REACH_DIRECT;
        },
        .rendezvous => {
            slot.shape = c.PANCAKE_DIAL_SHAPE_RENDEZVOUS;
            setView(&.{}, &slot.host, &slot.host_len);
            slot.port = 0;
            setView(&.{}, &slot.addresses, &slot.addresses_len);
            slot.reach_kind = c.PANCAKE_DIAL_REACH_DIRECT;
        },
    }
    return PANCAKE_OK;
}

/// Install (or clear, with a null callback) the live trace: the host reports
/// its own session opens (partner designator, negotiated codec, whether a
/// durable identity verified the name), every message's verb in both
/// directions, and session closes, through `callback` on the host's one
/// thread. Views in the event are borrowed for the call. The callback must
/// call no host-driving verb; stamp, copy, and return.
pub export fn pancake_host_set_trace(
    host: ?*PancakeHost,
    callback: ?c.PancakeTraceCallback,
    ctx: ?*anyopaque,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (callback == null and inst.trace_queue == null) {
        inst.core.setTrace(null) catch |err| return errToCode(err);
    } else {
        inst.core.setTrace(.{ .ctx = inst, .emit = traceEmit }) catch |err| return errToCode(err);
    }
    inst.trace_cb = callback;
    inst.trace_ctx = ctx;
    return PANCAKE_OK;
}

/// Install (or clear, with a zero `capacity`) the drained live trace: instead
/// of calling back, the host captures each fact into a fixed ring the embedder
/// pops with `pancake_host_next_trace`. This is the seam for an embedder that
/// cannot hand the library a C function pointer — a browser, where the wasm
/// module's import set is pinned to the one behavior trampoline.
///
/// `capacity` records are held, each with `payload_cap` bytes for that
/// record's borrowed strings (the partner designator and wire name of an open;
/// the verb and as much of the frame as fits, for a message). Nothing here
/// grows: a full ring drops the newest record and reports the count on the
/// next one it does capture, so tracing can never make the protocol wait.
///
/// Installing replaces any prior queue, dropping whatever it still held. A
/// zero `capacity` clears the queue; the callback seam, if one is installed,
/// keeps running either way.
pub export fn pancake_host_set_trace_queue(
    host: ?*PancakeHost,
    capacity: usize,
    payload_cap: usize,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (capacity == 0) {
        if (inst.trace_cb == null)
            inst.core.setTrace(null) catch |err| return errToCode(err);
        if (inst.trace_queue) |queue| {
            queue.deinit(inst.allocator);
            inst.allocator.destroy(queue);
            inst.trace_queue = null;
        }
        return PANCAKE_OK;
    }
    if (payload_cap == 0) {
        shared.setLastError("host: set_trace_queue: payload_cap must be positive", .{});
        return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    }
    const queue = inst.allocator.create(trace_queue.TraceQueue) catch |err| return errToCode(err);
    queue.* = trace_queue.TraceQueue.init(inst.allocator, capacity, payload_cap) catch |err| {
        inst.allocator.destroy(queue);
        if (err == error.SizeOverflow) {
            shared.setLastError("host: set_trace_queue: capacity times payload_cap overflows", .{});
            return shared.PANCAKE_ERR_INVALID_ARGUMENT;
        }
        return errToCode(err);
    };
    inst.core.setTrace(.{ .ctx = inst, .emit = traceEmit }) catch |err| {
        queue.deinit(inst.allocator);
        inst.allocator.destroy(queue);
        return errToCode(err);
    };
    const previous = inst.trace_queue;
    inst.trace_queue = queue;
    if (previous) |old| {
        old.deinit(inst.allocator);
        inst.allocator.destroy(old);
    }
    return PANCAKE_OK;
}

/// Pop the oldest captured trace record into `out`. Its byte views point into
/// the queue and stay valid until the next `pancake_host_next_trace` call,
/// the same borrow `pancake_host_next_action` carries. Returns
/// `PANCAKE_ERR_WOULD_BLOCK` when nothing is captured, so an embedder drains
/// in a loop until it sees that code.
pub export fn pancake_host_next_trace(
    host: ?*PancakeHost,
    out: ?*c.PancakeTraceEvent,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const queue = inst.trace_queue orelse return shared.PANCAKE_ERR_WOULD_BLOCK;
    if (!queue.pop(slot)) return shared.PANCAKE_ERR_WOULD_BLOCK;
    return PANCAKE_OK;
}

/// The core-sink half of the trace bridge: project the typed fact onto the C
/// event and call the installed callback.
fn traceEmit(ctx: ?*anyopaque, event: driver_core.trace.Event) void {
    const inst: *common.Instance = @ptrCast(@alignCast(ctx.?));
    if (inst.trace_queue) |queue| queue.push(event);
    const cb = inst.trace_cb orelse return;
    var out = c.PancakeTraceEvent{
        .kind = 0,
        .session = 0,
        .outbound = 0,
        .provenance = c.PANCAKE_DURABLE_PROVENANCE_UNAUTHENTICATED,
        .codec = shared.PANCAKE_CODEC_UNKNOWN,
        .captp_version = shared.PANCAKE_CAPTP_V1_0,
        .designator = null,
        .designator_len = 0,
        .transport = null,
        .transport_len = 0,
        .session_id = null,
        .session_id_len = 0,
        .verb = null,
        .verb_len = 0,
        .frame = null,
        .frame_len = 0,
        .frame_total_len = 0,
        .dropped = 0,
        .digest = @splat(0),
    };
    switch (event) {
        .session_open => |open| {
            out.kind = c.PANCAKE_TRACE_SESSION_OPEN;
            out.session = open.session.int();
            out.provenance = common.provenanceToC(open.provenance);
            out.codec = shared.codecToC(open.codec);
            out.captp_version = shared.captpVersionToC(open.captp_version);
            out.designator = open.designator.ptr;
            out.designator_len = open.designator.len;
            out.transport = open.transport.ptr;
            out.transport_len = open.transport.len;
            if (open.session_id.len > 0) {
                out.session_id = open.session_id.ptr;
                out.session_id_len = open.session_id.len;
            }
        },
        .message => |msg| {
            out.kind = c.PANCAKE_TRACE_MESSAGE;
            out.session = msg.session.int();
            out.outbound = @intFromBool(msg.outbound);
            out.verb = msg.verb.ptr;
            out.verb_len = msg.verb.len;
            out.digest = msg.digest;
            if (msg.frame.len > 0) {
                out.frame = msg.frame.ptr;
                out.frame_len = msg.frame.len;
                out.frame_total_len = msg.frame.len;
            }
        },
        .session_close => |close| {
            out.kind = c.PANCAKE_TRACE_SESSION_CLOSE;
            out.session = close.session.int();
        },
    }
    cb(inst.trace_ctx, &out);
}

/// Settle a resolver vow fulfilled with one capability-free value (a value
/// naming a capability refuses whole; an answer that carries authority uses
/// the turn's forward-to-send instead). Top-level: refused inside a callback;
/// the settle runs the deferred answers and pumps the sessions they dirtied.
/// A successful settle consumes the resolver; preparation failure is retryable,
/// while a second successful settle or an unknown id refuses.
pub export fn pancake_host_resolver_fulfill(
    host: ?*PancakeHost,
    resolver_id: u64,
    value: ?*const shared.PancakeArgument,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const c_value = value orelse return PANCAKE_ERR_NULL_POINTER;
    const converted = common.plainArgumentFromC(inst, c_value.*) catch |err| return errToCode(err);
    inst.core.resolverFulfill(resolver_id, converted) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Settle a resolver vow broken with a diagnostic borrowed for the call. The
/// same top-level, consume-on-success contract as pancake_host_resolver_fulfill.
pub export fn pancake_host_resolver_break(
    host: ?*PancakeHost,
    resolver_id: u64,
    message: ?[*]const u8,
    message_len: usize,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const reason = shared.sliceFromC(message, message_len) catch |err| return shared.marshalErrorToCode(err);
    inst.core.resolverBreak(resolver_id, reason) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Select-or-dial enliven (ADR-0098): enliven the complete sturdyref URI over
/// a live session this host already dialed to its peer, or stage a dial and
/// finish when the embedder reports it. The host vow id lands in *out_vow and
/// its outcome arrives as that vow's SETTLE or FAIL action, whether the
/// enliven rode a selected session or waited for a dial. A staged dial
/// surfaces as an ordinary PANCAKE_HOST_ACTION_DIAL: borrow it with
/// pancake_host_pending_dial and report it with pancake_host_dialed /
/// pancake_host_dial_failed exactly as a handoff redeem's dial. Refused
/// inside a callback.
pub export fn pancake_host_enliven(
    host: ?*PancakeHost,
    sturdyref_uri: ?[*]const u8,
    sturdyref_uri_len: usize,
    out_vow: ?*u64,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const uri = shared.sliceFromC(sturdyref_uri, sturdyref_uri_len) catch |err| return shared.marshalErrorToCode(err);
    slot.* = inst.core.enlivenUri(uri) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

// ── The action queue ─────────────────────────────────────────────────────────

/// Pop the next embedder action into `*out_action`, or return
/// `PANCAKE_ERR_WOULD_BLOCK` when none is pending. A popped action's byte
/// views — a SETTLE's `value` sub-structure, a FAIL's `message` — are
/// host-owned and valid until the *next* `pancake_host_next_action` call,
/// which frees them. A DIAL carries only `ticket`; borrow the pending view
/// with `pancake_host_pending_dial`. After any top-level
/// `pancake_host_*` call returns OK, drain this until WOULD_BLOCK, honoring
/// each action — that one loop rule is the whole embedder contract, and
/// nothing in the library enforces it: an ignored action strands the dial,
/// flush, handoff, or settlement it carries. Deferred encode work can return
/// `PANCAKE_ERR_INTERNAL` under allocator pressure before an action is popped;
/// no action or authority is lost, and the embedder retries this same drain
/// call when pressure subsides. Refused inside a callback.
pub export fn pancake_host_next_action(host: ?*PancakeHost, out_action: ?*PancakeHostAction) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "next_action")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const slot = out_action orelse return PANCAKE_ERR_NULL_POINTER;
    // The core pop carries the reentry refusal (`ReenteredHost` maps to
    // INVALID_ARGUMENT) and it runs before anything is freed, so a refused
    // call keeps the previous action's views intact.
    var popped = inst.core.nextAction() catch |err| return errToCode(err);
    // The previous SETTLE's projected C children die with the previous model
    // value (freed by the pop above): one reset, one lifetime sentence.
    _ = inst.completion_scratch.reset(.{ .retain_with_limit = steady_scratch_bytes });
    while (popped) |action| : (popped = inst.core.nextAction() catch |err| return errToCode(err)) {
        switch (action) {
            .dial => |d| {
                slot.* = common.zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_DIAL;
                slot.ticket = d.ticket;
                return PANCAKE_OK;
            },
            .cancel_dial => |d| {
                slot.* = common.zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_CANCEL_DIAL;
                slot.ticket = d.ticket;
                return PANCAKE_OK;
            },
            .flush => |peer_id| {
                // A flush for a session released meanwhile has nothing to
                // drain; skip to the next action.
                const session = inst.core.sessionForPeer(peer_id) orelse continue;
                slot.* = common.zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_FLUSH;
                slot.session = @ptrCast(session);
                return PANCAKE_OK;
            },
            .close => |peer_id| {
                // A close for a session released meanwhile is already
                // done; skip to the next action.
                const session = inst.core.sessionForPeer(peer_id) orelse continue;
                slot.* = common.zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_CLOSE;
                slot.session = @ptrCast(session);
                if (inst.core.sessionCloseOutcome(session, true) == .timed_out)
                    slot.result = shared.PANCAKE_ERR_TIMEOUT;
                return PANCAKE_OK;
            },
            .resume_work => {
                slot.* = common.zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_RESUME;
                return PANCAKE_OK;
            },
            .need_gift_id => |n| {
                slot.* = common.zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_NEED_GIFT_ID;
                slot.ticket = n.ticket;
                return PANCAKE_OK;
            },
            .settled, .failed => return common.projectCompletionInto(inst, action, slot),
        }
    }
    return PANCAKE_ERR_WOULD_BLOCK;
}

/// Internal half of `pancake_host_pump_drain`'s transactional callback
/// contract. The public pull queue remains consume-on-pop; only the convenience
/// pump can reject an arm before commit and ask for the same borrowed action to
/// be projected again.
pub fn retryBorrowedAction(host: ?*PancakeHost) bool {
    const inst = instanceFrom(host) orelse return false;
    return inst.core.retryBorrowedAction();
}

/// Report a DIAL action's success: `session` is an `open_dialed_locator` against
/// the pending dial for that ticket (`pancake_host_pending_dial`), driven to an
/// open session. The node withdraws
/// every give waiting on the ticket; the withdraws, their settles, and their
/// flushes pump inside this call. A stale ticket is a no-op success.
pub export fn pancake_host_dialed(host: ?*PancakeHost, ticket: u64, raw: ?*PancakeHostSession) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "dialed")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    // The ticket is registered against the session's `peer_id`, which indexes
    // that session's own host's node: a session from another host would name a
    // different connection here, or none.
    if (instOf(session.host) != inst) {
        shared.setLastError("host: dialed: session belongs to another host", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    inst.core.exporterDialed(ticket, session) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Report a DIAL action's failure: every redeem waiting on the ticket breaks
/// with `reason`, its FAIL completion queued inside this call. A stale ticket
/// is a no-op success.
pub export fn pancake_host_dial_failed(host: ?*PancakeHost, ticket: u64, reason: ?[*]const u8, reason_len: usize) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "dial_failed")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const reason_bytes = shared.sliceFromC(reason, reason_len) catch |err| return shared.marshalErrorToCode(err);
    inst.core.dialFailed(ticket, reason_bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// A CANCEL_DIAL action's physical operation has stopped and its executor
/// state can be released. Host close remains pending until this acknowledgement.
pub export fn pancake_host_dial_cancelled(host: ?*PancakeHost, ticket: u64) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "dial_cancelled")) return PANCAKE_ERR_INVALID_ARGUMENT;
    inst.core.dialCancelled(ticket) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Answer a NEED_GIFT_ID action with 32 caller-drawn random bytes: the node
/// originates the claimed handoff and this call flushes its legs, exporter
/// first. A stale ticket is a no-op success.
pub export fn pancake_host_provide_gift_id(host: ?*PancakeHost, ticket: u64, gift_id: ?[*]const u8, gift_id_len: usize) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "provide_gift_id")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const bytes = shared.sliceFromC(gift_id, gift_id_len) catch |err| return shared.marshalErrorToCode(err);
    inst.core.provideGiftId(ticket, bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Report that a NEED_GIFT_ID action could not obtain or provide entropy. The
/// claimed handoff settles broken instead of retaining a ticket the embedder
/// has already consumed. A stale ticket is a no-op success.
pub export fn pancake_host_gift_id_failed(host: ?*PancakeHost, ticket: u64) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(inst, "gift_id_failed")) return PANCAKE_ERR_INVALID_ARGUMENT;
    inst.core.giftIdFailed(ticket) catch |err| return errToCode(err);
    return PANCAKE_OK;
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
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const b = behavior orelse return PANCAKE_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err| return shared.marshalErrorToCode(err);
    if (preflightHostedTransfer(inst)) |code| return code;

    const hosted = common.hostedBridge(inst.allocator, b, ctx, free) catch |err| return errToCode(err);
    _ = inst.core.publishHostedGiftable(name_bytes, hosted) catch |err| return errToCode(err);
    return PANCAKE_OK;
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
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const b = behavior orelse return PANCAKE_ERR_NULL_POINTER;
    const out = out_swiss orelse return PANCAKE_ERR_NULL_POINTER;
    const entropy_bytes = shared.sliceFromC(entropy, entropy_len) catch |err| return shared.marshalErrorToCode(err);
    if (entropy_bytes.len != engine.durable_swiss_entropy_len) {
        shared.setLastError("host: durable entropy must be exactly {d} bytes", .{engine.durable_swiss_entropy_len});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    if (swiss_cap < engine.durable_swiss_len) {
        shared.setLastError("host: durable swiss buffer needs {d} bytes", .{engine.durable_swiss_len});
        return shared.PANCAKE_ERR_BUFFER_TOO_SMALL;
    }
    if (preflightHostedTransfer(inst)) |code| return code;
    const hosted = common.hostedBridge(inst.allocator, b, ctx, free) catch |err| return errToCode(err);
    var entropy_fixed: [engine.durable_swiss_entropy_len]u8 = undefined;
    @memcpy(&entropy_fixed, entropy_bytes);
    const minted = inst.core.publishHostedDurable(entropy_fixed, hosted) catch |err| return errToCode(err);
    @memcpy(out[0..engine.durable_swiss_len], minted.slice());
    return @intCast(engine.durable_swiss_len);
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
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const swiss_bytes = shared.sliceFromC(swiss, swiss_len) catch |err| return shared.marshalErrorToCode(err);
    inst.core.removeDurable(swiss_bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
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
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err| return shared.marshalErrorToCode(err);
    inst.core.unpublish(name_bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

// ── GC and diagnostics ───────────────────────────────────────────────────────

/// Release `delta` application retains on one opaque Host capability. The Host
/// resolves the owning session itself; callers never pair a handle with a
/// session-local wire position. A non-OK return commits no release, so the same
/// `(ref, delta)` may be retried. OK consumes the release; any later pump
/// cleanup failure is converted into typed session close and must not invite a
/// duplicate release. Single-thread affinity applies.
pub export fn pancake_host_ref_release(host: ?*PancakeHost, ref: ?*const shared.PancakeReference, delta: u64) i32 {
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
