//! Host lifecycle and the host-wide surfaces for `libpancake_host`: create /
//! release, the identity designator helpers, the pure dial / accept planners,
//! the embedder action queue (`pancake_host_next_action` and the DIAL / gift-id
//! completions), the host-wide giftable publish, GC release, and the archive's
//! own last-error slot. The per-session verbs live in `session.zig`, the
//! turn-time verbs in `turn.zig`, and the convenience drain in `pump.zig`; the
//! module root (`mod.zig`) owns the public C types these exports fill.

const std = @import("std");
const builtin = @import("builtin");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const driver_core = @import("driver_core");

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");
const trace_queue = @import("trace_queue.zig");

const crypto = foundation.crypto;

const Instance = common.Instance;
const Host = common.Host;
const instanceFrom = common.instanceFrom;
const setView = common.setView;
const connFrom = common.connFrom;
const instOf = common.instOf;
const errToCode = common.errToCode;
const refuseLatched = common.refuseLatched;
const publishHosted = common.publishHosted;
const steady_scratch_bytes = common.steady_scratch_bytes;

const PancakeContext = c.PancakeContext;
const PancakeHost = c.PancakeHost;
const PancakeHostSession = c.PancakeHostSession;
const PancakeHostAction = c.PancakeHostAction;
const PancakePendingDial = c.PancakePendingDial;
const PancakeDialPlan = c.PancakeDialPlan;
const PancakeAcceptPlan = c.PancakeAcceptPlan;

const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_WOULD_BLOCK = shared.PANCAKE_ERR_WOULD_BLOCK;

const first_capability_id: u64 = 1 << 62;
const exhausted_capability_id: u64 = 1 << 63;
var next_capability_id_atomic: std.atomic.Value(u64) = .init(first_capability_id);
var next_capability_id_single: u64 = first_capability_id;
var capability_key_state: std.atomic.Value(u8) = .init(0);
var capability_key_ready_single = false;
var capability_key: [16]u8 = undefined;

fn deriveCapabilityKey(seed: [crypto.SEED_BYTES]u8) [16]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("pancake C capability id permutation\x00");
    hasher.update(&seed);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest[0..16].*;
}

/// Initialize the process-wide permutation once. Host seeds already enter from
/// the adapter's entropy boundary; the first one supplies a process-local key
/// while the monotonic input below supplies collision-free global scope.
fn ensureCapabilityKey(seed: [crypto.SEED_BYTES]u8) void {
    if (comptime builtin.single_threaded) {
        if (!capability_key_ready_single) {
            capability_key = deriveCapabilityKey(seed);
            capability_key_ready_single = true;
        }
        return;
    }

    if (capability_key_state.load(.acquire) == 2) return;
    if (capability_key_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        capability_key = deriveCapabilityKey(seed);
        capability_key_state.store(2, .release);
        return;
    }
    while (capability_key_state.load(.acquire) != 2) std.atomic.spinLoopHint();
}

fn capabilityRound(half: u32, round: u8) u32 {
    const SipHash = std.crypto.auth.siphash.SipHash64(2, 4);
    var input: [5]u8 = undefined;
    std.mem.writeInt(u32, input[0..4], half, .little);
    input[4] = round;
    var tag: [SipHash.mac_length]u8 = undefined;
    SipHash.create(&tag, &input, &capability_key);
    return @truncate(std.mem.readInt(u64, &tag, .little));
}

/// A balanced Feistel network is a permutation over all 64-bit values. Mapping
/// the process-wide monotonic input through it therefore hides adjacency while
/// preserving the counter's collision and non-reuse guarantees exactly.
fn permuteCapabilityId(value: u64) u64 {
    var left: u32 = @truncate(value >> 32);
    var right: u32 = @truncate(value);
    inline for (0..6) |round| {
        const next = left ^ capabilityRound(right, round);
        left = right;
        right = next;
    }
    return (@as(u64, left) << 32) | right;
}

fn issueCapabilityId(_: ?*anyopaque) error{CapabilitySpaceExhausted}!u64 {
    if (comptime builtin.single_threaded) {
        if (next_capability_id_single == exhausted_capability_id) return error.CapabilitySpaceExhausted;
        const current = next_capability_id_single;
        next_capability_id_single += 1;
        return permuteCapabilityId(current);
    }

    var current = next_capability_id_atomic.load(.monotonic);
    while (current != exhausted_capability_id) {
        if (next_capability_id_atomic.cmpxchgStrong(current, current + 1, .monotonic, .monotonic)) |observed| {
            current = observed;
        } else {
            return permuteCapabilityId(current);
        }
    }
    return error.CapabilitySpaceExhausted;
}

// ── Lifecycle ────────────────────────────────────────────────────────────────

fn hostNewIn(
    alloc: std.mem.Allocator,
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
    // One buffer, two independent inputs (ADR-0097). The first 32 bytes are
    // the host's durable identity and must stay stable across restarts — a
    // keyed locator's designator is derived from them. The optional next 32
    // are the session-key root, and they must be *fresh per process*: they are
    // what makes each connection sign with its own key, and what stops a
    // restarted host recreating a prior session's handoff names. Supplying
    // only the durable half is still accepted, and then every session signs
    // with the durable key, which is the weaker posture this ADR removes.
    const session_root_len = crypto.SEED_BYTES * 2;
    if (seed_len != crypto.SEED_BYTES and seed_len != session_root_len) {
        shared.setLastError(
            "host: seed must be {d} bytes, or {d} to supply a session-key root after the durable identity",
            .{ crypto.SEED_BYTES, session_root_len },
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
    ensureCapabilityKey(seed_nn[0..crypto.SEED_BYTES].*);
    const inst = alloc.create(Instance) catch |err| return errToCode(err);
    var opts = Host.Options.withFrameCap(frame_cap);
    opts.verify_partner = verify_partner != 0;
    opts.codec = codec_id;
    opts.captp_version = version_id;
    opts.features = feature_set;
    opts.local_turn_budget = if (local_turn_budget == 0) null else local_turn_budget;
    opts.capability_id_issuer = .{ .next = issueCapabilityId };
    if (seed_len == session_root_len) {
        opts.session_seeds = .{ .rooted = seed_nn[crypto.SEED_BYTES..session_root_len].* };
    }
    inst.* = .{
        .core = Host.init(alloc, seed_nn[0..crypto.SEED_BYTES].*, opts),
        .allocator = alloc,
        .arg_scratch = std.heap.ArenaAllocator.init(alloc),
        .turn_scratch = std.heap.ArenaAllocator.init(alloc),
        .completion_scratch = std.heap.ArenaAllocator.init(alloc),
    };
    slot.* = @ptrCast(inst);
    return PANCAKE_OK;
}

/// Create a byte-fed host bound to the caller-drawn 32-byte Ed25519 identity
/// `seed` (the host never draws entropy), allocating through the library
/// allocator. `frame_cap` sizes every session's maximum admissible frame;
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
    return hostNewIn(shared.library_allocator, seed, seed_len, frame_cap, verify_partner, codec, captp_version, features, local_turn_budget, out_host);
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
    return hostNewIn(ctx.allocator(), seed, seed_len, frame_cap, verify_partner, codec, captp_version, features, local_turn_budget, out_host);
}

/// Release the host and everything it owns: every still-open session
/// (each still-parked vow breaks inside this call, its undrained completion
/// freed with the rest of the action queue), the vow map, parked actions,
/// the node, and the giftable rows (each giftable's `free` runs exactly once
/// here). Null is a no-op. HostSession (`PancakeHostSession`) handles this host minted
/// are freed with it — release the sessions first if you hold them, and never
/// touch one after its host is gone. Refused (with the last error set) from
/// inside a callback.
pub export fn pancake_host_release(host: ?*PancakeHost) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_OK;
    if (inst.core.in_callback) {
        // A code, not a bare return. The refusal frees nothing, so an embedder
        // that dropped the pointer here leaked the whole host — and the only
        // signal was a thread-local nobody was told to read. Its sibling
        // `pancake_host_set_session_limits` reports the identical refusal with
        // exactly this value.
        shared.setLastError("host: release re-entered from a callback", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    const alloc = inst.allocator;
    // Breaks every parked far vow; the completions those breaks queue are
    // freed inside with the rest of the undrained action queue.
    inst.core.deinit();
    inst.arg_scratch.deinit();
    inst.turn_scratch.deinit();
    inst.completion_scratch.deinit();
    if (inst.trace_queue) |queue| {
        queue.deinit(alloc);
        alloc.destroy(queue);
    }
    alloc.destroy(inst);
    return PANCAKE_OK;
}

/// Derive the canonical key designator (exactly 64 lowercase hex digits) from
/// a 32-byte Ed25519 identity seed — the public half of the key
/// `pancake_host_new` signs with. Writes 64 bytes into `out` (`out_len` must
/// be at least 64). A keyed-tcp listener whose Node identity is the locator
/// designator uses this so designator and session key cannot disagree
/// (ADR-0075).
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

/// Record the designator this host's dials sign as their own dialable address
/// (a host that also listens). `designator` is borrowed and copied into the
/// host's retained buffer; longer than 64 bytes is refused
/// `PANCAKE_ERR_INVALID_ARGUMENT`, and empty resets to the unreachable-client
/// placeholder.
pub export fn pancake_host_set_self_designator(host: ?*PancakeHost, designator: ?[*]const u8, len: usize) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes = shared.sliceFromC(designator, len) catch |err| return shared.marshalErrorToCode(err);
    inst.core.setSelfDesignator(bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Retain and select this host's complete acceptable location. `locator` is a
/// Syrup `<ocapn-peer ...>` record and is borrowed for this call; the Host parses
/// and deep-copies it before returning.
pub export fn pancake_host_set_advertised_locator(host: ?*PancakeHost, locator: ?[*]const u8, locator_len: usize) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes = shared.sliceFromC(locator, locator_len) catch |err| return shared.marshalErrorToCode(err);
    var cursor: usize = 0;
    const parsed = engine.readLocatorOwned(inst.allocator, bytes, &cursor) catch {
        shared.setLastError("host: set_advertised_locator expects one Syrup ocapn-peer record", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    defer model.freePeerLocator(inst.allocator, parsed);
    if (cursor != bytes.len) {
        shared.setLastError("host: set_advertised_locator locator record has trailing bytes", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    inst.core.setAdvertisedLocator(parsed) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Retain the deterministic dial fallback for `transport` without displacing
/// an acceptable location already selected for another transport.
pub export fn pancake_host_ensure_advertised_locator(host: ?*PancakeHost, transport: ?[*]const u8, transport_len: usize) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    inst.core.ensureAdvertisedLocator(bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Remove the retained locator for `transport`. Removing the selected route
/// leaves no acceptable location. Existing sessions retain their signed hello.
pub export fn pancake_host_remove_advertised_locator(host: ?*PancakeHost, transport: ?[*]const u8, transport_len: usize) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    inst.core.removeAdvertisedLocator(bytes);
    return PANCAKE_OK;
}

/// Selective session-limit knobs (ADR-0082): override admission and/or
/// `queue_cap` on a host before minting sessions. Pass `0` for a field to leave
/// it unchanged. Peers already open keep the limits they were minted with;
/// later mints see the updated `Host.Options.limits`.
pub export fn pancake_host_set_session_limits(
    host: ?*PancakeHost,
    max_frame_bytes: usize,
    queue_cap: usize,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    if (inst.core.in_callback) {
        shared.setLastError("host: set_session_limits re-entered from a callback", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    inst.core.setSessionLimits(
        if (max_frame_bytes != 0) max_frame_bytes else null,
        if (queue_cap != 0) queue_cap else null,
    );
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

/// Borrow the in-flight pending dial for `ticket` into `*out`
/// (transport/designator/hint). Staged once at acceptGive — no re-parse.
/// A live ticket always has non-empty transport/designator; an empty hint means
/// the give carried none (`hint` is NULL). Unknown ticket returns
/// `PANCAKE_ERR_INVALID_ARGUMENT`. Host-owned views valid until
/// `pancake_host_dialed` / `pancake_host_dial_failed` (or host teardown).
pub export fn pancake_host_pending_dial(
    host: ?*PancakeHost,
    ticket: u64,
    out: ?*PancakePendingDial,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const view = inst.core.pendingDial(ticket) orelse {
        shared.setLastError("host: pending dial: unknown ticket {d}", .{ticket});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    slot.* = .{
        .transport = view.transport.ptr,
        .transport_len = view.transport.len,
        .designator = view.designator.ptr,
        .designator_len = view.designator.len,
        .hint = null,
        .hint_len = 0,
    };
    setView(view.direct_addresses_hint, &slot.hint, &slot.hint_len);
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
    const plan = driver_core.planDial(t, d, h, posture) catch |err| {
        switch (err) {
            error.UnknownTransport => shared.setLastError("dial: unsupported transport \"{s}\"", .{t}),
            error.DesignatorNotHostPort => shared.setLastError("dial: designator \"{s}\" is not host:port", .{d}),
            error.DesignatorNotPeerKey => shared.setLastError("dial: designator \"{s}\" is not a peer key", .{d}),
            error.MissingDirectAddressesHint => shared.setLastError("dial: a keyed-tcp locator requires a direct-addresses hint", .{}),
            error.ReachabilityRequired => shared.setLastError("dial: a peer-id open requires a reachability posture", .{}),
        }
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
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

/// Mint a resolver pair (ADR-0102): *out_vow_id is the read side, whose whole
/// surface is pancake_host_turn_forward_vow; *out_resolver_id is the settle
/// authority for pancake_host_resolver_fulfill / _break. Legal inside a
/// behavior callback — a behavior mints, forwards its answer, hands the
/// resolver id to whatever completes the work, and returns.
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
    inst.trace_cb = callback;
    inst.trace_ctx = ctx;
    if (callback == null and inst.trace_queue == null) {
        inst.core.setTrace(null);
    } else {
        inst.core.setTrace(.{ .ctx = inst, .emit = traceEmit });
    }
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
    if (inst.trace_queue) |queue| {
        queue.deinit(inst.allocator);
        inst.allocator.destroy(queue);
        inst.trace_queue = null;
    }
    if (capacity == 0) {
        if (inst.trace_cb == null) inst.core.setTrace(null);
        return PANCAKE_OK;
    }
    if (payload_cap == 0) {
        shared.setLastError("host: set_trace_queue: payload_cap must be positive", .{});
        return shared.PANCAKE_ERR_INVALID_ARGUMENT;
    }
    const queue = inst.allocator.create(trace_queue.TraceQueue) catch |err| return errToCode(err);
    queue.* = trace_queue.TraceQueue.init(inst.allocator, capacity, payload_cap) catch |err| {
        inst.allocator.destroy(queue);
        return errToCode(err);
    };
    inst.trace_queue = queue;
    inst.core.setTrace(.{ .ctx = inst, .emit = traceEmit });
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

pub export fn pancake_host_spawn_resolver(
    host: ?*PancakeHost,
    out_vow_id: ?*u64,
    out_resolver_id: ?*u64,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const vow_slot = out_vow_id orelse return PANCAKE_ERR_NULL_POINTER;
    const resolver_slot = out_resolver_id orelse return PANCAKE_ERR_NULL_POINTER;
    const pair = inst.core.spawnResolver() catch |err| return errToCode(err);
    vow_slot.* = pair.vow_id;
    resolver_slot.* = pair.resolver_id;
    return PANCAKE_OK;
}

/// Settle a resolver vow fulfilled with one capability-free value (a value
/// naming a capability refuses whole; an answer that carries authority uses
/// the turn's forward-to-send instead). Top-level: refused inside a callback;
/// the settle runs the deferred answers and pumps the sessions they dirtied.
/// One attempt per resolver; a second settle or an unknown id refuses.
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
/// same top-level, one-attempt contract as pancake_host_resolver_fulfill.
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
    const sturdyref = model.uri.parseSturdyrefForProfile(
        inst.allocator,
        inst.core.opts.captp_version,
        uri,
    ) catch |err| return errToCode(err);
    defer model.uri.freeSturdyref(inst.allocator, sturdyref);
    slot.* = inst.core.enlivenSelectOrDial(sturdyref) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Resolve what an accepted session signs as its own locator, without a
/// socket. transport is the accepted transport; server_designator is the
/// listener's own signing designator (its key for a key transport, unused for an
/// address transport); accepted_local_addr is what the accept reported (NULL/0
/// when unavailable). On PANCAKE_OK *out_plan is filled with views borrowing the
/// caller's input, except the address-transport empty-address fallback, which is
/// the static unreachable-client placeholder. Feed the result to
/// pancake_host_session_open_accepted.
pub export fn pancake_host_plan_accept(
    transport: ?[*]const u8,
    transport_len: usize,
    server_designator: ?[*]const u8,
    server_designator_len: usize,
    accepted_local_addr: ?[*]const u8,
    accepted_local_addr_len: usize,
    out_plan: ?*PancakeAcceptPlan,
) i32 {
    const slot = out_plan orelse return PANCAKE_ERR_NULL_POINTER;
    const t = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    const sd = shared.sliceFromC(server_designator, server_designator_len) catch |err| return shared.marshalErrorToCode(err);
    const la = shared.sliceFromC(accepted_local_addr, accepted_local_addr_len) catch |err| return shared.marshalErrorToCode(err);
    const plan = driver_core.planAccept(t, sd, la);
    setView(plan.designator, &slot.designator, &slot.designator_len);
    setView(plan.direct_addresses_hint, &slot.direct_addresses_hint, &slot.direct_addresses_hint_len);
    return PANCAKE_OK;
}

// ── The action queue ─────────────────────────────────────────────────────────

const zero_action = PancakeHostAction{
    .kind = 0,
    .ticket = 0,
    .session = null,
    .value = shared.zero_argument,
    .message = null,
    .message_len = 0,
};

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
                slot.* = zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_DIAL;
                slot.ticket = d.ticket;
                return PANCAKE_OK;
            },
            .flush => |peer_id| {
                // A flush for a connection released meanwhile has nothing to
                // drain; skip to the next action.
                const session = inst.core.sessions.get(peer_id) orelse continue;
                slot.* = zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_FLUSH;
                slot.session = @ptrCast(session);
                return PANCAKE_OK;
            },
            .close => |peer_id| {
                // A close for a connection released meanwhile is already
                // done; skip to the next action.
                const session = inst.core.sessions.get(peer_id) orelse continue;
                slot.* = zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_CLOSE;
                slot.session = @ptrCast(session);
                return PANCAKE_OK;
            },
            .need_gift_id => |n| {
                slot.* = zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_NEED_GIFT_ID;
                slot.ticket = n.ticket;
                return PANCAKE_OK;
            },
            .settled => |s| {
                slot.* = zero_action;
                slot.ticket = s.vow_id;
                // A value that cannot project into C must not surface a void
                // stand-in as SETTLE; it degrades to FAIL with the reason.
                const session = inst.core.sessions.get(s.peer_id) orelse {
                    const reason = "resolution session closed before value projection";
                    slot.kind = c.PANCAKE_HOST_ACTION_FAIL;
                    slot.message = reason.ptr;
                    slot.message_len = reason.len;
                    return PANCAKE_OK;
                };
                if (common.hostArgumentToC(inst, session, inst.completion_scratch.allocator(), s.value)) |c_val| {
                    slot.kind = c.PANCAKE_HOST_ACTION_SETTLE;
                    slot.value = c_val;
                } else |_| {
                    const reason = "resolution value could not be projected into C";
                    slot.kind = c.PANCAKE_HOST_ACTION_FAIL;
                    slot.message = reason.ptr;
                    slot.message_len = reason.len;
                }
                return PANCAKE_OK;
            },
            .failed => |f| {
                slot.* = zero_action;
                slot.kind = c.PANCAKE_HOST_ACTION_FAIL;
                slot.ticket = f.vow_id;
                if (f.message.len != 0) slot.message = f.message.ptr;
                slot.message_len = f.message.len;
                return PANCAKE_OK;
            },
        }
    }
    return PANCAKE_ERR_WOULD_BLOCK;
}

/// Report a DIAL action's success: `session` is an `open_dialed_locator` against
/// the pending dial for that ticket (`pancake_host_pending_dial`), driven to an
/// open session. The node withdraws
/// every give waiting on the ticket; the withdraws, their settles, and their
/// flushes pump inside this call. A stale ticket is a no-op success.
pub export fn pancake_host_dialed(host: ?*PancakeHost, ticket: u64, raw: ?*PancakeHostSession) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
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
    const reason_bytes = shared.sliceFromC(reason, reason_len) catch |err| return shared.marshalErrorToCode(err);
    inst.core.dialFailed(ticket, reason_bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Answer a NEED_GIFT_ID action with 32 caller-drawn random bytes: the node
/// originates the claimed handoff and this call flushes its legs, exporter
/// first. A stale ticket is a no-op success.
pub export fn pancake_host_provide_gift_id(host: ?*PancakeHost, ticket: u64, gift_id: ?[*]const u8, gift_id_len: usize) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes = shared.sliceFromC(gift_id, gift_id_len) catch |err| return shared.marshalErrorToCode(err);
    inst.core.provideGiftId(ticket, bytes) catch |err| return errToCode(err);
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
    if (refuseLatched(inst)) |code| return code;

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
    if (refuseLatched(inst)) |code| return code;
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
    if (refuseLatched(inst)) |code| return code;
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
    if (refuseLatched(inst)) |code| return code;
    inst.core.unpublish(name_bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

// ── GC and diagnostics ───────────────────────────────────────────────────────

/// Release `delta` application retains on one opaque Host capability. The Host
/// resolves the owning session itself; callers never pair a handle with a
/// session-local wire position. Single-thread affinity applies.
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
