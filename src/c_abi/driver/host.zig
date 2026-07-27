//! Host lifecycle and the host-wide surfaces for `libpancake_driver`: create /
//! release, the identity designator helpers, the pure dial / accept planners,
//! the embedder action queue (`pancake_host_next_action` and the DIAL / gift-id
//! completions), the host-wide giftable publish, GC release, and the archive's
//! own last-error slot. The per-session verbs live in `session.zig`, the
//! turn-time verbs in `turn.zig`, and the convenience drain in `pump.zig`; the
//! module root (`mod.zig`) owns the public C types these exports fill.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const driver_core = @import("driver_core");

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");

const crypto = foundation.crypto;

const Instance = common.Instance;
const Host = common.Host;
const instanceFrom = common.instanceFrom;
const connFrom = common.connFrom;
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

// ── Lifecycle ────────────────────────────────────────────────────────────────

fn hostNewIn(
    alloc: std.mem.Allocator,
    seed_ptr: ?[*]const u8,
    seed_len: usize,
    frame_cap: usize,
    verify_partner: u32,
    codec: u32,
    local_turn_budget: u32,
    out_host: ?*?*PancakeHost,
) i32 {
    const slot = out_host orelse return PANCAKE_ERR_NULL_POINTER;
    const seed_nn = seed_ptr orelse return PANCAKE_ERR_NULL_POINTER;
    if (seed_len != crypto.SEED_BYTES) {
        shared.setLastError("host: seed must be {d} bytes", .{crypto.SEED_BYTES});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    const codec_id = shared.codecFromC(codec) orelse {
        shared.setLastError("host: codec must be a PANCAKE_CODEC_* value", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    const inst = alloc.create(Instance) catch |err| return errToCode(err);
    var opts = Host.Options.withFrameCap(frame_cap);
    opts.verify_partner = verify_partner != 0;
    opts.codec = codec_id;
    opts.local_turn_budget = if (local_turn_budget == 0) null else local_turn_budget;
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
/// secure default); `codec` is the `PANCAKE_CODEC_*` wire grammar every
/// session this host mints negotiates in — both ends of a session must
/// carry the same value (`op:start-session` carries no codec operand, so
/// agreement is the embedder's, as on the peer tier's `_negotiated`
/// constructors); `local_turn_budget` is 0 for unbounded (the same default as
/// Zig Host + Bridge) or a nonzero cap on local-turn amplification per drive
/// (ADR-0076). Released with `pancake_host_release`.
pub export fn pancake_host_new(
    seed: ?[*]const u8,
    seed_len: usize,
    frame_cap: usize,
    verify_partner: u32,
    codec: u32,
    local_turn_budget: u32,
    out_host: ?*?*PancakeHost,
) i32 {
    return hostNewIn(shared.library_allocator, seed, seed_len, frame_cap, verify_partner, codec, local_turn_budget, out_host);
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
    local_turn_budget: u32,
    out_host: ?*?*PancakeHost,
) i32 {
    const ctx = shared.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    return hostNewIn(ctx.allocator(), seed, seed_len, frame_cap, verify_partner, codec, local_turn_budget, out_host);
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
    for (inst.giftables.items) |row| {
        if (row.free) |f| f(row.ctx);
        alloc.free(row.name);
    }
    inst.giftables.deinit(alloc);
    inst.arg_scratch.deinit();
    inst.turn_scratch.deinit();
    inst.completion_scratch.deinit();
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

fn setView(slice: []const u8, out_ptr: *?[*]const u8, out_len: *usize) void {
    out_ptr.* = if (slice.len == 0) null else slice.ptr;
    out_len.* = slice.len;
}

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

/// The exporter session a redeemed-handoff reply `reference` routes to, into
/// `*out_session` — or `*out_session = NULL` when the reference names no live
/// redeemed route (an ordinary far reply, or an exporter connection already
/// gone). This is the deterministic answer to "which connection does this
/// handoff capability live on": a `sendRedeeming` resolves the reply it holds
/// to the exact exporter session it should host its back-channel on, with no
/// capture window and no dependence on which dial completed first. The returned
/// handle is host-owned and lives with the exporter session; do not release it
/// here. Returns PANCAKE_ERR_INVALID_ARGUMENT on an unmarshalable reference.
pub export fn pancake_host_reference_exporter(
    host: ?*PancakeHost,
    reference: ?*const shared.PancakeReference,
    out_session: ?*?*PancakeHostSession,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_session orelse return PANCAKE_ERR_NULL_POINTER;
    const ref_ptr = reference orelse return PANCAKE_ERR_NULL_POINTER;
    const ref = shared.referenceFromC(ref_ptr.*) catch |err| return errToCode(err);
    slot.* = if (inst.core.exporterSessionFor(ref)) |session| @ptrCast(session) else null;
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
    }
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
/// flush, handoff, or settlement it carries. Refused inside a callback.
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
                if (shared.argumentToC(inst.completion_scratch.allocator(), s.value)) |c_val| {
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

/// Publish a hosted object host-wide: under `name` on every session now
/// open and every future one, so a gift naming that swissnum resolves against
/// whichever session a recipient withdraws on. The giftable row owns `ctx` —
/// `free`, if non-null, runs exactly once: at `pancake_host_release` on
/// success, or before this returns on any non-OK outcome (except the
/// null-pointer and reentry refusals, which touch nothing and leave ctx the
/// caller's). All-or-nothing over this
/// call's own work: a mid-publish failure restores every session this call
/// had already published (prior name mapping and export row), removes the
/// giftable row, and frees `ctx`, so a retry starts from the pre-call state
/// instead of double-minting exports on the sessions that had succeeded.
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
    const owned_name = inst.allocator.dupe(u8, name_bytes) catch |err| {
        if (free) |f| f(ctx);
        return errToCode(err);
    };
    inst.giftables.append(inst.allocator, .{ .name = owned_name, .behavior = b, .ctx = ctx, .free = free }) catch |err| {
        inst.allocator.free(owned_name);
        if (free) |f| f(ctx);
        return errToCode(err);
    };
    // One undo row per session published by THIS call. `publishHosted` unwinds
    // its own failing session; these rows unwind the ones that had already
    // succeeded. The spawned bridge arms stay on their vats (freed at session
    // teardown), the same slot `publishHosted`'s own unwind concedes.
    const Undo = struct { session: *common.HostSession, prior: ?model.ExportPosition, granted: u64 };
    var undo: std.ArrayList(Undo) = .empty;
    defer undo.deinit(inst.allocator);
    const unwindAll = struct {
        fn run(instance: *Instance, rows: []const Undo, published_name: []const u8, f: ?c.PancakeHostCtxFree, context: ?*anyopaque) void {
            for (rows) |u| {
                u.session.served.peer.session_state.restoreBootstrapMapping(published_name, u.prior);
                u.session.served.peer.session_state.releaseUnsharedExport(.from(u.granted));
            }
            const row = instance.giftables.pop().?;
            instance.allocator.free(row.name);
            if (f) |func| func(context);
        }
    }.run;
    undo.ensureTotalCapacity(inst.allocator, inst.core.sessions.count()) catch |err| {
        unwindAll(inst, undo.items, name_bytes, free, ctx);
        return errToCode(err);
    };
    var it = inst.core.sessions.valueIterator();
    while (it.next()) |session| {
        const prior = session.*.served.peer.session_state.bootstrapLookup(name_bytes);
        const granted = publishHosted(session.*, inst.allocator, name_bytes, b, ctx, null) catch |err| {
            unwindAll(inst, undo.items, name_bytes, free, ctx);
            return errToCode(err);
        };
        undo.appendAssumeCapacity(.{ .session = session.*, .prior = prior, .granted = granted });
    }
    return PANCAKE_OK;
}

// ── GC and diagnostics ───────────────────────────────────────────────────────

/// Release `delta` references on the fetched capability `token` holds: the
/// token resolves through the node to its home connection and real wire
/// import, and the release rides that peer as `op:gc-exports` (a FLUSH action
/// follows). A dead home is a no-op success — the session teardown already
/// reclaimed the counts. An id below the node's token range is refused
/// `PANCAKE_ERR_INVALID_ARGUMENT`. Single-thread affinity applies: never call
/// this from a finalizer thread.
pub export fn pancake_host_gc_release(host: ?*PancakeHost, token: u64, delta: u64) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    inst.core.gcRelease(token, delta) catch |err| return errToCode(err);
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
