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

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");
const actors = @import("actors");
const driver_core = @import("driver_core");

// The shared C-ABI vocabulary leaf — types, codes, allocation, the last-error
// slot — not the ocapn root, so this archive pulls none of the ocapn family's
// exports (ADR-0059 companion split).
const shared = @import("c_abi_shared");

const crypto = foundation.crypto;
const Host = driver_core.Host;
const HostSession = driver_core.HostSession;
const HostError = driver_core.HostError;

const PancakeFrame = shared.PancakeFrame;
const PancakeManagedFrame = shared.PancakeManagedFrame;
const PancakeContext = shared.PancakeContext;
const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_INTERNAL = shared.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_WOULD_BLOCK = shared.PANCAKE_ERR_WOULD_BLOCK;

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

const zero_action = PancakeHostAction{
    .kind = 0,
    .ticket = 0,
    .session = null,
    .locator = null,
    .locator_len = 0,
    .transport = null,
    .transport_len = 0,
    .designator = null,
    .designator_len = 0,
    .direct_addresses_hint = null,
    .direct_addresses_hint_len = 0,
    .value = shared.zero_argument,
    .message = null,
    .message_len = 0,
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

// ── Instance ─────────────────────────────────────────────────────────────────

/// The retained-capacity ceiling for the per-call scratch arenas: capacity a
/// burst grew above this is freed at the next reset, the steady-bytes posture
/// the actor layer holds on its own arenas.
const steady_scratch_bytes = 4096;

/// A host-wide giftable registration (`pancake_host_publish`): one shared
/// behavior/ctx published under `name` on every session now open and every
/// future one. The row owns `name` and `ctx` — the per-session bridges
/// carry a null free so the shared ctx is freed exactly once, here, at host
/// release.
const Giftable = struct {
    name: []u8,
    behavior: PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?PancakeHostCtxFree,
};

/// The host handle's owned state: the byte-fed core plus the C-side bridge
/// registries. The `core` field is embedded by value so a `*Host` reached
/// through a connection (`HostSession.host`) recovers the instance with one
/// `@fieldParentPtr`.
const Instance = struct {
    core: Host,
    allocator: std.mem.Allocator,
    /// The host-wide giftable rows, replayed onto every newly opened
    /// connection so a swissnum-named gift resolves against the withdraw
    /// session's own bootstrap registry.
    giftables: std.ArrayListUnmanaged(Giftable) = .empty,
    /// Scratch for one call's inbound argument marshalling (`argsFromC`),
    /// reset at the head of each *top-level* send-shaped call. A nested
    /// (in-callback) verb bumps without resetting: a composed `turn_forward`
    /// runs its target synchronously on the outer call's marshalled argument
    /// arrays (byte payloads stay borrowed from the C caller), so the reset
    /// waits for the next top-level call to reclaim the lot.
    arg_scratch: std.heap.ArenaAllocator,
    /// Scratch owning a turn verb's projected reply (`turn_forward`), reset at
    /// the head of each projection — the reply is borrowed until the next
    /// turn verb or drive, the same lifetime the underlying near reply has.
    turn_scratch: std.heap.ArenaAllocator,
    /// Scratch owning a SETTLE action's projected `value` sub-structure
    /// (`argumentToC`'s child arrays), reset at the head of each
    /// `pancake_host_next_action` — the C children and the model value in the
    /// popped action row both die at the next `next_action` call, one
    /// lifetime sentence, the one DIAL already carries.
    completion_scratch: std.heap.ArenaAllocator,
};

fn instanceFrom(handle: ?*PancakeHost) ?*Instance {
    return @ptrCast(@alignCast(handle orelse return null));
}

fn connFrom(handle: ?*PancakeHostSession) ?*HostSession {
    return @ptrCast(@alignCast(handle orelse return null));
}

fn turnFrom(handle: ?*PancakeHostTurn) ?*actors.Turn {
    return @ptrCast(@alignCast(handle orelse return null));
}

/// The instance a host core is embedded in — `Instance.core` is by value, so
/// this is one field-parent hop.
fn instOf(core: *Host) *Instance {
    return @fieldParentPtr("core", core);
}

/// The connection a running turn belongs to: every actor on this surface
/// lives in some connection's serve-core vat, so the turn's vat recovers its
/// `Served` and that its `HostSession` by field parentage.
fn connOfTurn(t: *actors.Turn) *HostSession {
    const served: *driver_core.Served = @fieldParentPtr("vat", t.vat);
    return @fieldParentPtr("served", served);
}

/// Map a host-tier error to a C return code, recording the name for
/// `pancake_host_last_error`.
fn errToCode(err: anyerror) i32 {
    shared.setLastError("host: {s}", .{@errorName(err)});
    return switch (err) {
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        error.UnsupportedValue => shared.PANCAKE_ERR_UNSUPPORTED_VALUE,
        error.NullPointer => PANCAKE_ERR_NULL_POINTER,
        // The node's fail-closed routing: a retired token or a dead vow row is
        // a lookup that found nothing, not a malformed request.
        error.TokenRetired, error.NoSuchVow => shared.PANCAKE_ERR_NOT_FOUND,
        // A condemned connection (crossed-hellos loser) refuses every verb;
        // the embedder writes its queued abort and releases it.
        error.ConnectionCondemned => shared.PANCAKE_ERR_CLOSED,
        // Caller misuse: re-entering a host-driving verb from a callback, a
        // foreign-homed argument, a non-callable target, a projection on a
        // local vow, a late or duplicate listener, an unparseable locator.
        error.ReenteredHost,
        error.ForeignArgument,
        error.NotAToken,
        error.DesignatorTooLong,
        error.MissingDirectAddressesHint,
        error.UncallableTarget,
        error.NotPipelineable,
        error.NoSuchActor,
        error.AlreadyListening,
        error.AlreadySettled,
        error.NotLocal,
        error.NotConnected,
        error.AlreadyPublished,
        error.NotNearCallable,
        error.NearCallTooDeep,
        error.NotOcapnUri,
        error.MissingTransport,
        error.EmptyComponent,
        error.MalformedPath,
        error.MalformedHint,
        error.UnsupportedHintValue,
        error.UriParseError,
        error.InvalidHostPort,
        => PANCAKE_ERR_INVALID_ARGUMENT,
        // The bound peer refused an outbound send for a session or protocol
        // reason: a session-domain refusal, per the shared taxonomy.
        error.SendRejected => shared.PANCAKE_ERR_SESSION,
        // Everything else is an inbound-dispatch failure, classified through
        // the one shared taxonomy (codec / session / internal).
        else => shared.feedErrorToCode(err),
    };
}

/// Refuse a host-driving verb that has no core verb to carry the refusal —
/// the registration surfaces this archive owns (`conn_publish`, `conn_spawn`,
/// the host-wide `publish`). It reads the same latch the core's own top-level
/// verbs refuse `ReenteredHost` under, so the two tiers cannot disagree on
/// what a callback may do: enqueue only.
fn refuseLatched(inst: *const Instance) ?i32 {
    if (inst.core.in_callback) {
        shared.setLastError("host: {s}", .{@errorName(HostError.ReenteredHost)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    return null;
}

// ── Bridges ──────────────────────────────────────────────────────────────────

/// The C behavior bound to one hosted object. Allocated on the host's
/// allocator and freed by its own `freeThunk` when the actor's box drops
/// (connection or host release, or a failed spawn).
const HostedBehavior = struct {
    behavior: PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?PancakeHostCtxFree,
    allocator: std.mem.Allocator,

    /// The vat calls this on each deliver. It marshals the message into C,
    /// invokes the consumer's callback with the turn, and materializes the
    /// reply *owned* into `turn.arena` before returning — the consumer's
    /// `out_reply` storage is only valid until the callback returns, and the
    /// reply must own its bytes for the turn window, exactly like a native
    /// reply.
    fn handle(erased: *anyopaque, turn: *actors.Turn, msg: actors.Message) anyerror!model.Argument {
        const self: *HostedBehavior = @ptrCast(@alignCast(erased));
        const arena = turn.arena;
        const c_args = try shared.argsToC(arena, msg.args);
        var reply: shared.PancakeArgument = shared.zero_argument;
        const code = self.behavior(
            self.ctx,
            @ptrCast(turn),
            msg.verb.ptr,
            msg.verb.len,
            if (c_args.len > 0) c_args.ptr else null,
            c_args.len,
            &reply,
        );
        if (code != PANCAKE_OK) return error.ForeignBehaviorBroke;
        return try shared.argumentFromCOwned(arena, reply, 0);
    }

    /// The actor's box `free`: run the consumer's `free` on the foreign `ctx`
    /// (null for a giftable's per-session bridge — the giftable row owns
    /// the shared ctx), then free the bridge itself. Runs exactly once when
    /// the box drops.
    fn freeThunk(erased: *anyopaque) void {
        const self: *HostedBehavior = @ptrCast(@alignCast(erased));
        if (self.free) |f| f(self.ctx);
        self.allocator.destroy(self);
    }
};

/// Spawn a hosted object on `served`, wrapping the C callbacks in a `HostedBehavior`. On
/// a spawn failure the free contract is honored here (freeing `ctx` and the
/// bridge), so the caller never double-frees.
fn spawnBridge(
    served: *driver_core.Served,
    alloc: std.mem.Allocator,
    behavior: PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?PancakeHostCtxFree,
) !actors.Ref {
    const bridge = alloc.create(HostedBehavior) catch |e| {
        if (free) |f| f(ctx);
        return e;
    };
    bridge.* = .{ .behavior = behavior, .ctx = ctx, .free = free, .allocator = alloc };
    return try served.spawnHosted(.{ .ctx = bridge, .handle = HostedBehavior.handle, .free = HostedBehavior.freeThunk });
}

/// Bind a hosted object on one session: allocate its export position (from
/// the session's one export allocator; named publications also register the
/// bootstrap swissnum), spawn the bridge, and bind. Once the position phase
/// passes, the vat owns the bridge — a later failure leaves the object
/// spawned unbound and its `free` runs at teardown, so `free` still runs
/// exactly once on every outcome.
fn publishHosted(
    session: *HostSession,
    alloc: std.mem.Allocator,
    name: ?[]const u8,
    behavior: PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?PancakeHostCtxFree,
) !u64 {
    const peer = session.served.peer;
    const position = (if (name) |n| peer.registerBootstrapCap(n) else peer.exportNextObject()) catch |err| {
        if (free) |f| f(ctx);
        return err;
    };
    const ref = try spawnBridge(&session.served, alloc, behavior, ctx, free);
    try session.served.bindExport(ref, position);
    return position;
}

/// Publish every giftable row onto a freshly opened connection, so a gift
/// deposited under the row's swissnum resolves against this session's own
/// bootstrap registry — the replay that makes a three-party withdraw find the
/// exporter's object on whichever connection the recipient dialed.
fn replayGiftables(inst: *Instance, session: *HostSession) !void {
    for (inst.giftables.items) |row| {
        _ = try publishHosted(session, inst.allocator, row.name, row.behavior, row.ctx, null);
    }
}

/// Marshal one send-shaped call's `verb` + C `args` into an `actors.Message`
/// whose args live in the instance's per-call scratch — the one prologue every
/// send/tell/turn export shares.
fn msgFromC(
    inst: *Instance,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.PancakeArgument,
    args_len: usize,
) shared.MarshalError!actors.Message {
    const verb_ptr = verb orelse return error.NullPointer;
    // Reset only at a top-level call: a composed forward runs its target
    // synchronously, so the outer call's marshalled args (the argument arrays
    // in this scratch — byte payloads stay borrowed from the C caller) are
    // live for the whole callback window, and a nested verb must bump the
    // same arena instead of freeing them mid-call.
    if (!inst.core.in_callback)
        _ = inst.arg_scratch.reset(.{ .retain_with_limit = steady_scratch_bytes });
    return .{
        .verb = verb_ptr[0..verb_len],
        .args = try shared.argsFromC(inst.arg_scratch.allocator(), args, args_len, 0),
    };
}

/// Resolve a turn verb's C target within the turn's own session: a NEAR
/// reference to the vat-local actor bound at that export, a FAR reference
/// through the node's routing — refused whole when the route (or any far
/// argument) leaves this session, since a turn cannot ride another
/// session's peer.
fn turnTarget(session: *HostSession, reference: model.Reference, args: []const model.Argument) !actors.Ref {
    switch (reference) {
        .near => |near| {
            return session.served.refForExport(near.export_position.int()) orelse actors.Error.NoSuchActor;
        },
        .far => {
            const routed = session.host.node.routeReference(session.peer_id, reference) orelse return HostError.TokenRetired;
            if (routed.peer_id != session.peer_id) return HostError.ForeignArgument;
            for (args) |argument| {
                if (session.host.argIsForeignDeep(session.peer_id, argument)) return HostError.ForeignArgument;
            }
            return .{ .far = routed.target.far };
        },
        else => return driver_core.Error.UncallableTarget,
    }
}

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
    const inst = alloc.create(Instance) catch return PANCAKE_ERR_INTERNAL;
    inst.* = .{
        .core = Host.init(alloc, seed_nn[0..crypto.SEED_BYTES].*, .{
            .frame_cap = frame_cap,
            .verify_partner = verify_partner != 0,
            .codec = codec_id,
            .local_turn_budget = if (local_turn_budget == 0) null else local_turn_budget,
        }),
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
pub export fn pancake_host_release(host: ?*PancakeHost) void {
    const inst = instanceFrom(host) orelse return;
    if (inst.core.in_callback) {
        shared.setLastError("host: release re-entered from a callback", .{});
        return;
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

// ── Connection lifecycle ─────────────────────────────────────────────────────

/// Mint the dialing half from an already-parsed locator (`transport` +
/// `designator`), the same pieces a DIAL action carries. The keyed
/// `op:start-session` is signed under the host identity and encoded before
/// this returns, so drain `take_outbound` (a FLUSH action is queued) and drive
/// the handshake byte-fed. Every host-wide giftable is published on the new
/// session before it is returned. A URI-holding caller parses first
/// (`pancake_uri_parse_peer`) and passes the pieces — there is no parallel
/// URI-string mint entry. The dialed hello does not consume a direct-addresses
/// hint (that hint is the connect-side dial executor's concern, and
/// accept-side signing's). `*out_session` is host-owned; release with
/// `pancake_host_session_release`.
pub export fn pancake_host_session_open_dialed_locator(
    host: ?*PancakeHost,
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    out_session: ?*?*PancakeHostSession,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_session orelse return PANCAKE_ERR_NULL_POINTER;
    const transport_bytes = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    const designator_bytes = shared.sliceFromC(designator, designator_len) catch |err| return shared.marshalErrorToCode(err);
    const locator: model.PeerLocator = .{
        .transport = transport_bytes,
        .designator = designator_bytes,
        .hints = model.Hints.emptyFalse(),
    };
    const session = inst.core.openDialedLocator(locator) catch |err| return errToCode(err);
    replayGiftables(inst, session) catch |err| {
        inst.core.releaseSession(session) catch {};
        return errToCode(err);
    };
    slot.* = @ptrCast(session);
    return PANCAKE_OK;
}

/// Mint the accepting half of a connection the embedder's own listener
/// produced: the keyed `op:start-session` signs the listener's own
/// `transport`/`designator` — the address a partner can actually dial, and
/// the locator a give made on this host names as the exporter location. On a
/// key-designator transport (`keyed-tcp`) `direct_addresses_hint` is required
/// (TCP has no discovery; nullable/zero length is none); an address-designator
/// transport ignores it. Same giftable replay, flush, and release contract as
/// `open_dialed_locator`.
pub export fn pancake_host_session_open_accepted(
    host: ?*PancakeHost,
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    direct_addresses_hint: ?[*]const u8,
    direct_addresses_hint_len: usize,
    out_session: ?*?*PancakeHostSession,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_session orelse return PANCAKE_ERR_NULL_POINTER;
    const transport_bytes = shared.sliceFromC(transport, transport_len) catch |err| return shared.marshalErrorToCode(err);
    const designator_bytes = shared.sliceFromC(designator, designator_len) catch |err| return shared.marshalErrorToCode(err);
    const hint_bytes = shared.sliceFromC(direct_addresses_hint, direct_addresses_hint_len) catch |err| return shared.marshalErrorToCode(err);
    const session = inst.core.openAccepted(transport_bytes, designator_bytes, hint_bytes) catch |err| return errToCode(err);
    replayGiftables(inst, session) catch |err| {
        inst.core.releaseSession(session) catch {};
        return errToCode(err);
    };
    slot.* = @ptrCast(session);
    return PANCAKE_OK;
}

// ── Dial / accept planning (driver_core.planDial / planAccept) ────────────────
//
// The transport dispatch, designator validation, host:port resolution, and iroh
// reachability decision every language binding used to re-express in its own
// connect / dial_exporter / Server.accept. A binding calls the planner, opens
// the byte channel the plan names in its own runtime, then feeds it back through
// pancake_host_session_open_dialed_locator / pancake_host_session_open_accepted. The
// plan is pure: no socket, no allocation, every view borrowing the caller input.

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

fn setView(slice: []const u8, out_ptr: *?[*]const u8, out_len: *usize) void {
    out_ptr.* = if (slice.len == 0) null else slice.ptr;
    out_len.* = slice.len;
}

/// Resolve a dial without opening a socket. transport/designator are the
/// locator's pieces (a DIAL action carries them parsed); direct_addresses_hint
/// is the locator's direct-addresses hint (NULL/0 = none); posture_policy is a
/// PANCAKE_DIAL_POSTURE_* selecting the iroh reachability rule, with posture_value
/// the caller's posture under PANCAKE_DIAL_POSTURE_EXPLICIT. On PANCAKE_OK
/// *out_plan is filled with views borrowing the caller's buffers; on a bad
/// locator it returns PANCAKE_ERR_INVALID_ARGUMENT (see pancake_host_last_error).
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
        PANCAKE_DIAL_POSTURE_REDEEM => .redeem,
        PANCAKE_DIAL_POSTURE_EXPLICIT => .{ .explicit = posture_value },
        PANCAKE_DIAL_POSTURE_EXPLICIT_NONE => .{ .explicit = null },
        else => {
            shared.setLastError("host: plan_dial: unknown posture policy {d}", .{posture_policy});
            return PANCAKE_ERR_INVALID_ARGUMENT;
        },
    };
    const plan = driver_core.planDial(t, d, h, posture) catch |err| {
        switch (err) {
            error.UnknownTransport => shared.setLastError("dial: unsupported transport \"{s}\"", .{t}),
            error.DesignatorNotHostPort => shared.setLastError("dial: designator \"{s}\" is not host:port", .{d}),
            error.MissingDirectAddressesHint => shared.setLastError("dial: a keyed-tcp locator requires a direct-addresses hint", .{}),
            error.ReachabilityRequired => shared.setLastError("dial: an iroh locator requires a reachability posture", .{}),
        }
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    slot.shape = switch (plan.shape) {
        .host_port => PANCAKE_DIAL_SHAPE_HOST_PORT,
        .iroh => PANCAKE_DIAL_SHAPE_IROH,
    };
    setView(plan.host, &slot.host, &slot.host_len);
    slot.port = plan.port;
    setView(plan.addresses, &slot.addresses, &slot.addresses_len);
    slot.reach_value = 0;
    slot.reach_kind = if (plan.reach) |reach| switch (reach) {
        .direct => PANCAKE_DIAL_REACH_DIRECT,
        .configured => PANCAKE_DIAL_REACH_CONFIGURED,
        .explicit => |v| blk: {
            slot.reach_value = v;
            break :blk PANCAKE_DIAL_REACH_EXPLICIT;
        },
    } else PANCAKE_DIAL_REACH_DIRECT; // host_port shape: reach fields unused
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

/// Release one session: its still-parked far vows break (their FAIL
/// completions queue inside this call), the node retires it — stranded
/// withdraws fail closed, so *sibling* sessions' vows may break here
/// too — and the shell is freed. Null is a no-op; refused (last error set,
/// the session kept) from inside a callback.
pub export fn pancake_host_session_release(raw: ?*PancakeHostSession) void {
    const session = connFrom(raw) orelse return;
    const inst = instOf(session.host);
    inst.core.releaseSession(session) catch |err| {
        shared.setLastError("host: conn_release: {s}", .{@errorName(err)});
    };
}

/// Nonzero once the keyed handshake has completed and the session is open.
pub export fn pancake_host_session_session_open(raw: ?*PancakeHostSession) i32 {
    const session = connFrom(raw) orelse return 0;
    return if (session.sessionOpen()) 1 else 0;
}

// ── The byte pump ────────────────────────────────────────────────────────────

/// Feed one inbound frame the embedder read from its own transport (borrowed
/// for the call): behavior callbacks fire and vow completions queue inside,
/// then the node actions the dispatch queued pump and every touched
/// connection's outbound encodes. A failure classifies through the shared taxonomy
/// (`PANCAKE_ERR_CODEC` / `_SESSION` / `_INTERNAL`); after any failure still
/// drain `take_outbound` — the peer projected a typed `op:abort` for the
/// partner — then read `pancake_host_session_last_abort` for the typed cause.
pub export fn pancake_host_session_feed(raw: ?*PancakeHostSession, frame_in: ?*const PancakeFrame) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const borrowed = frame_in orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = borrowed.bytes orelse return PANCAKE_ERR_NULL_POINTER;
    const shape = shared.frameShapeFromC(borrowed.shape) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    session.host.feed(session, .{ .bytes = bytes_ptr[0..borrowed.len], .shape = shape }) catch |err| {
        return errToCode(err);
    };
    return PANCAKE_OK;
}

/// Feed a byte-stream chunk the embedder read from its own transport
/// (borrowed for the call). The library owns framing: the session's codec
/// delimits each complete frame at the front of `bytes` — both codecs, both
/// frame shapes — and dispatches it exactly as `pancake_host_session_feed`, so
/// the embedder just moves bytes and keeps the tail. `*out_consumed` receives
/// the count of leading bytes consumed; drop them and extend the remainder
/// with the next read (a partial frame is not an error — OK with a smaller
/// count, possibly zero). Consumption also stops at the frame that completes
/// the keyed handshake: bytes coalesced behind the hello stay in the tail
/// while the embedder acts on the fresh session (publish, fetch), and the
/// next call feeds them. A frame exceeding the connection's frame cap is
/// refused `PANCAKE_ERR_FRAME_TOO_LARGE`; any other failure classifies as
/// `pancake_host_session_feed`'s do. After any failure `*out_consumed` is zero
/// and the session is closing: drain `take_outbound` (a typed `op:abort` is
/// queued for the partner) and release the connection.
pub export fn pancake_host_session_feed_bytes(
    raw: ?*PancakeHostSession,
    bytes: ?[*]const u8,
    len: usize,
    out_consumed: ?*usize,
) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_consumed orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = 0;
    if (len == 0) return PANCAKE_OK;
    const buf = bytes orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = session.host.feedBytes(session, buf[0..len]) catch |err| switch (err) {
        error.FrameTooLarge => {
            shared.setLastError("host: {s}", .{@errorName(err)});
            return shared.PANCAKE_ERR_FRAME_TOO_LARGE;
        },
        else => return errToCode(err),
    };
    return PANCAKE_OK;
}

/// Drain one encoded outbound frame as an *owned* managed frame the caller
/// writes to its transport and frees through `pancake_managed_frame_release`.
/// Returns `PANCAKE_OK` with `out_frame` set, or `PANCAKE_ERR_WOULD_BLOCK`
/// (with `out_frame` untouched) when the queue is empty. Refused inside a
/// callback.
pub export fn pancake_host_session_take_outbound(raw: ?*PancakeHostSession, out_frame: ?*PancakeManagedFrame) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    // The core drain carries the reentry refusal (`ReenteredHost` maps to
    // INVALID_ARGUMENT), so the two tiers cannot disagree on the latch.
    const popped = session.takeOutbound() catch |err| return errToCode(err);
    const frame = popped orelse return PANCAKE_ERR_WOULD_BLOCK;
    return shared.wrapManagedInto(inst.allocator, frame, slot, "take_outbound");
}

/// Pop the next embedder action into `*out_action`, or return
/// `PANCAKE_ERR_WOULD_BLOCK` when none is pending. A popped action's byte
/// views — a DIAL's locator pieces, a SETTLE's `value` sub-structure, a
/// FAIL's `message` — are host-owned and valid until the *next*
/// `pancake_host_next_action` call, which frees them. After any top-level
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
                slot.kind = PANCAKE_HOST_ACTION_DIAL;
                slot.ticket = d.ticket;
                slot.locator = d.locator.ptr;
                slot.locator_len = d.locator.len;
                if (d.transport.len != 0) slot.transport = d.transport.ptr;
                slot.transport_len = d.transport.len;
                if (d.designator.len != 0) slot.designator = d.designator.ptr;
                slot.designator_len = d.designator.len;
                if (d.direct_addresses_hint.len != 0) slot.direct_addresses_hint = d.direct_addresses_hint.ptr;
                slot.direct_addresses_hint_len = d.direct_addresses_hint.len;
                return PANCAKE_OK;
            },
            .flush => |peer_id| {
                // A flush for a connection released meanwhile has nothing to
                // drain; skip to the next action.
                const session = inst.core.sessions.get(peer_id) orelse continue;
                slot.* = zero_action;
                slot.kind = PANCAKE_HOST_ACTION_FLUSH;
                slot.session = @ptrCast(session);
                return PANCAKE_OK;
            },
            .close => |peer_id| {
                // A close for a connection released meanwhile is already
                // done; skip to the next action.
                const session = inst.core.sessions.get(peer_id) orelse continue;
                slot.* = zero_action;
                slot.kind = PANCAKE_HOST_ACTION_CLOSE;
                slot.session = @ptrCast(session);
                return PANCAKE_OK;
            },
            .need_gift_id => |n| {
                slot.* = zero_action;
                slot.kind = PANCAKE_HOST_ACTION_NEED_GIFT_ID;
                slot.ticket = n.ticket;
                return PANCAKE_OK;
            },
            .settled => |s| {
                slot.* = zero_action;
                slot.ticket = s.vow_id;
                // A value that cannot project into C must not surface a void
                // stand-in as SETTLE; it degrades to FAIL with the reason.
                if (shared.argumentToC(inst.completion_scratch.allocator(), s.value)) |c_val| {
                    slot.kind = PANCAKE_HOST_ACTION_SETTLE;
                    slot.value = c_val;
                } else |_| {
                    const reason = "resolution value could not be projected into C";
                    slot.kind = PANCAKE_HOST_ACTION_FAIL;
                    slot.message = reason.ptr;
                    slot.message_len = reason.len;
                }
                return PANCAKE_OK;
            },
            .failed => |f| {
                slot.* = zero_action;
                slot.kind = PANCAKE_HOST_ACTION_FAIL;
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
/// that action's locator parts, driven to an open session. The node withdraws
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

// ── Publish and spawn ────────────────────────────────────────────────────────

/// Publish a hosted object a partner on this one session can `fetch` by
/// `name` (a swiss-number). The object is `behavior`/`ctx`, driven like any
/// native actor; `free`, if non-null, runs exactly once when the object is
/// torn down (session or host release) or when this call fails after
/// taking ownership. `*out_export_position` receives the bound export.
/// Refused inside a callback (ctx stays the caller's on a null-pointer or
/// reentry refusal).
pub export fn pancake_host_session_publish(
    raw: ?*PancakeHostSession,
    name: ?[*]const u8,
    name_len: usize,
    behavior: ?PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?PancakeHostCtxFree,
    out_export_position: ?*u64,
) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const b = behavior orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_export_position orelse return PANCAKE_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err| return shared.marshalErrorToCode(err);
    const inst = instOf(session.host);
    if (refuseLatched(inst)) |code| return code;
    slot.* = publishHosted(session, inst.allocator, name_bytes, b, ctx, free) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Spawn a hosted object at a fresh export position on this session,
/// without a fetchable name — reachable once some reply or argument carries
/// its reference. Same `free` contract as `pancake_host_session_publish`.
pub export fn pancake_host_session_spawn(
    raw: ?*PancakeHostSession,
    behavior: ?PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?PancakeHostCtxFree,
    out_export_position: ?*u64,
) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const b = behavior orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_export_position orelse return PANCAKE_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    if (refuseLatched(inst)) |code| return code;
    slot.* = publishHosted(session, inst.allocator, null, b, ctx, free) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Publish a hosted object host-wide: under `name` on every session now
/// open and every future one, so a gift naming that swissnum resolves against
/// whichever session a recipient withdraws on. The giftable row owns `ctx` —
/// `free`, if non-null, runs exactly once, at `pancake_host_release` (the
/// per-session bridges never free it). A failure after the row is
/// recorded keeps the row (and that ownership); a null-pointer or reentry
/// refusal leaves ctx the caller's.
pub export fn pancake_host_publish(
    host: ?*PancakeHost,
    name: ?[*]const u8,
    name_len: usize,
    behavior: ?PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?PancakeHostCtxFree,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const b = behavior orelse return PANCAKE_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err| return shared.marshalErrorToCode(err);
    if (refuseLatched(inst)) |code| return code;
    const owned_name = inst.allocator.dupe(u8, name_bytes) catch {
        if (free) |f| f(ctx);
        return PANCAKE_ERR_INTERNAL;
    };
    inst.giftables.append(inst.allocator, .{ .name = owned_name, .behavior = b, .ctx = ctx, .free = free }) catch {
        inst.allocator.free(owned_name);
        if (free) |f| f(ctx);
        return PANCAKE_ERR_INTERNAL;
    };
    var it = inst.core.sessions.valueIterator();
    while (it.next()) |session| {
        _ = publishHosted(session.*, inst.allocator, name_bytes, b, ctx, null) catch |err| return errToCode(err);
    }
    return PANCAKE_OK;
}

// ── Fetch and enliven ────────────────────────────────────────────────────────

/// Fetch the partner capability published as `name`, minting a host vow
/// whose id lands in `*out_vow`; the outcome arrives as that vow's SETTLE or
/// FAIL action. A fulfilled far capability settles *already enrolled* under
/// a node-unique token — recorded before the completion is queued, so a
/// reply that immediately re-gifts it routes to the right exporter. Refused
/// inside a callback.
pub export fn pancake_host_session_fetch(
    raw: ?*PancakeHostSession,
    name: ?[*]const u8,
    name_len: usize,
    out_vow: ?*u64,
) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err| return shared.marshalErrorToCode(err);
    const inst = instOf(session.host);
    slot.* = inst.core.fetch(session, name_bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Enliven the sturdyref published behind `swissnum` (ADR-0012), minting a
/// host vow whose id lands in `*out_vow`; the live reference arrives as that
/// vow's SETTLE action. A dedup-cache hit settles before this returns — the
/// completion is already queued — and a fresh enliven rides bootstrap-fetch,
/// the host recording the enlivenment itself before the completion is
/// queued. Refused inside a callback.
pub export fn pancake_host_session_enliven(
    raw: ?*PancakeHostSession,
    swissnum: ?[*]const u8,
    swissnum_len: usize,
    out_vow: ?*u64,
) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const swiss = shared.sliceFromC(swissnum, swissnum_len) catch |err| return shared.marshalErrorToCode(err);
    const inst = instOf(session.host);
    slot.* = inst.core.enliven(session, swiss) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

// ── Send, tell, vows, projections ────────────────────────────────────────────

/// Eventual-send to `target` and mint a host vow for the answer; the outcome
/// arrives as that vow's SETTLE or FAIL action. A NEAR target (an export
/// this host bound) runs in-process; a FAR target routes through the node,
/// so a redeemed or fetched token rides its exporter connection
/// transparently. A far argument foreign to the routed connection is refused
/// whole (`PANCAKE_ERR_INVALID_ARGUMENT`) rather than mis-encoded; a retired
/// token reports `PANCAKE_ERR_NOT_FOUND`. `verb`/`args` are borrowed; the
/// host copies what it queues. Legal inside a callback (the send encodes
/// when the enclosing call unwinds).
pub export fn pancake_host_session_send(
    raw: ?*PancakeHostSession,
    target: ?*const shared.PancakeReference,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.PancakeArgument,
    args_len: usize,
    out_vow: ?*u64,
) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const target_ptr = target orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    const msg = msgFromC(inst, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    const reference = shared.referenceFromC(target_ptr.*) catch |err| return errToCode(err);
    slot.* = inst.core.send(session, reference, msg) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Fire-and-forget eventual-send: `pancake_host_session_send` with no answer and
/// no vow. Same routing and refusals.
pub export fn pancake_host_session_tell(
    raw: ?*PancakeHostSession,
    target: ?*const shared.PancakeReference,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.PancakeArgument,
    args_len: usize,
) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const target_ptr = target orelse return PANCAKE_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    const msg = msgFromC(inst, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    const reference = shared.referenceFromC(target_ptr.*) catch |err| return errToCode(err);
    inst.core.tell(session, reference, msg) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Promise pipelining: eventual-send to a host vow before it resolves,
/// minting a new vow for this call's own answer. A local vow (a NEAR send's
/// answer) has no wire answer to pipeline against and is refused
/// `PANCAKE_ERR_INVALID_ARGUMENT` (NotPipelineable).
pub export fn pancake_host_vow_send(
    host: ?*PancakeHost,
    vow: u64,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.PancakeArgument,
    args_len: usize,
    out_vow: ?*u64,
) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const msg = msgFromC(inst, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    slot.* = inst.core.vowSend(vow, msg) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Pipeline an `op:index` projection against a far host vow, minting a new
/// vow for the projected element. Same local-vow and unknown-vow refusals as
/// `pancake_host_vow_send`; an index above INT64_MAX is refused
/// `PANCAKE_ERR_INVALID_ARGUMENT` (the wire index is a signed integer).
pub export fn pancake_host_vow_index(host: ?*PancakeHost, vow: u64, index: u64, out_vow: ?*u64) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    if (index > std.math.maxInt(i64)) {
        shared.setLastError("host: vow_index index out of range", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    slot.* = inst.core.vowIndex(vow, @intCast(index)) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Pipeline an `op:untag` projection against a far host vow, minting a new
/// vow for the unwrapped payload (a single-value Tagged unwraps to that
/// value; a variadic one to its value list). `tag` is borrowed.
pub export fn pancake_host_vow_untag(host: ?*PancakeHost, vow: u64, tag: ?[*]const u8, tag_len: usize, out_vow: ?*u64) i32 {
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const tag_bytes = shared.sliceFromC(tag, tag_len) catch |err| return shared.marshalErrorToCode(err);
    slot.* = inst.core.vowUntag(vow, tag_bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

// ── Turn verbs ───────────────────────────────────────────────────────────────

/// From inside a behavior callback, forward this turn's call to `target` and
/// let this object's own answer settle on the forwarded result — the
/// caretaker/attenuator primitive. `target` resolves within the turn's own
/// session: NEAR to the local object at that export, FAR through the
/// node's routing (refused `PANCAKE_ERR_INVALID_ARGUMENT` when the route or
/// any far argument leaves this session). In a wire-served turn the real
/// answer rides the forwarded vow and `*out_reply` gets a void placeholder;
/// pass your behavior's own `out_reply` and return `PANCAKE_OK`. The written
/// reply is BORROWED — valid until the next turn verb or drive on this host.
pub export fn pancake_host_turn_forward(
    turn: ?*PancakeHostTurn,
    target: ?*const shared.PancakeReference,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.PancakeArgument,
    args_len: usize,
    out_reply: ?*shared.PancakeArgument,
) i32 {
    const t = turnFrom(turn) orelse return PANCAKE_ERR_NULL_POINTER;
    const target_ptr = target orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_reply orelse return PANCAKE_ERR_NULL_POINTER;
    const session = connOfTurn(t);
    const inst = instOf(session.host);
    const msg = msgFromC(inst, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    const reference = shared.referenceFromC(target_ptr.*) catch |err| return errToCode(err);
    const vat_target = turnTarget(session, reference, msg.args) catch |err| return errToCode(err);
    const reply = t.forward(vat_target, msg) catch |err| return errToCode(err);
    _ = inst.turn_scratch.reset(.{ .retain_with_limit = steady_scratch_bytes });
    slot.* = shared.argumentToC(inst.turn_scratch.allocator(), reply) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// From inside a behavior callback, eventual-send to `target` and mint a host
/// vow for the answer — the same routing and refusals as
/// `pancake_host_session_send`, on the turn's own session. The send encodes
/// when the enclosing top-level call unwinds.
pub export fn pancake_host_turn_send(
    turn: ?*PancakeHostTurn,
    target: ?*const shared.PancakeReference,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.PancakeArgument,
    args_len: usize,
    out_vow: ?*u64,
) i32 {
    const t = turnFrom(turn) orelse return PANCAKE_ERR_NULL_POINTER;
    const target_ptr = target orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const session = connOfTurn(t);
    const inst = instOf(session.host);
    const msg = msgFromC(inst, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    const reference = shared.referenceFromC(target_ptr.*) catch |err| return errToCode(err);
    slot.* = inst.core.send(session, reference, msg) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// From inside a behavior callback, fire-and-forget eventual-send —
/// `pancake_host_turn_send` with no answer and no vow.
pub export fn pancake_host_turn_tell(
    turn: ?*PancakeHostTurn,
    target: ?*const shared.PancakeReference,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.PancakeArgument,
    args_len: usize,
) i32 {
    const t = turnFrom(turn) orelse return PANCAKE_ERR_NULL_POINTER;
    const target_ptr = target orelse return PANCAKE_ERR_NULL_POINTER;
    const session = connOfTurn(t);
    const inst = instOf(session.host);
    const msg = msgFromC(inst, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    const reference = shared.referenceFromC(target_ptr.*) catch |err| return errToCode(err);
    inst.core.tell(session, reference, msg) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// From inside a behavior callback, spawn a hosted object at a fresh export
/// position on the turn's own session — how a served factory mints the
/// capability it replies with (a task board's `create`, a caretaker wrapping
/// a target), the turn-time form of `pancake_host_session_spawn`. Same `free`
/// contract; `*out_export_position` receives the bound export, ready to ride
/// this turn's own reply as a NEAR reference.
pub export fn pancake_host_turn_spawn(
    turn: ?*PancakeHostTurn,
    behavior: ?PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?PancakeHostCtxFree,
    out_export_position: ?*u64,
) i32 {
    const t = turnFrom(turn) orelse return PANCAKE_ERR_NULL_POINTER;
    const b = behavior orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_export_position orelse return PANCAKE_ERR_NULL_POINTER;
    const session = connOfTurn(t);
    const inst = instOf(session.host);
    slot.* = publishHosted(session, inst.allocator, null, b, ctx, free) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// From inside a behavior callback, break this turn's own answer with
/// `message` — how a behavior refuses with a diagnostic, since a non-OK
/// return settles the answer broken with only a generic reason. The answer
/// resolves broken inside this call (a no-answer tell breaks nothing); leave
/// `out_reply` untouched and return `PANCAKE_OK` from the behavior, whose
/// return value then resolves nothing. `message` is borrowed and copied.
pub export fn pancake_host_turn_break(turn: ?*PancakeHostTurn, message: ?[*]const u8, message_len: usize) i32 {
    const t = turnFrom(turn) orelse return PANCAKE_ERR_NULL_POINTER;
    const msg = shared.sliceFromC(message, message_len) catch |err| return shared.marshalErrorToCode(err);
    t.breakWith(msg) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

// ── GC, teardown, diagnostics ────────────────────────────────────────────────

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

/// Break every far vow still parked on `session`, queueing each vow's FAIL
/// completion inside this call — with the partner's retained abort
/// diagnostic when one arrived, else `message`. Call it when your transport
/// reports the connection gone.
pub export fn pancake_host_session_break_far_vows(raw: ?*PancakeHostSession, message: ?[*]const u8, message_len: usize) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const msg = shared.sliceFromC(message, message_len) catch |err| return shared.marshalErrorToCode(err);
    session.host.breakFarVows(session, msg) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Record the exporter locator to embed in gives whose exporter is `session`,
/// overriding the session record; empty clears the override. `locator` is
/// borrowed: it must be a Syrup `<ocapn-peer …>` record (the same bytes
/// `pancake_encode_peer_locator` returns). A URI or other non-record spelling
/// fails with `PANCAKE_ERR_INVALID_ARGUMENT` — the node encodes the parsed
/// locator to canonical record bytes, so misuse cannot reach a signed give.
pub export fn pancake_host_session_set_exporter_location(raw: ?*PancakeHostSession, locator: ?[*]const u8, locator_len: usize) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes = shared.sliceFromC(locator, locator_len) catch |err| return shared.marshalErrorToCode(err);
    if (bytes.len == 0) {
        session.host.setExporterLocation(session, null) catch |err| return errToCode(err);
        return PANCAKE_OK;
    }
    var cursor: usize = 0;
    const parsed = engine.readLocatorOwned(session.host.allocator, bytes, &cursor) catch {
        shared.setLastError("host: set_exporter_location expects a Syrup ocapn-peer record, not a URI or other bytes", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    defer model.freePeerLocator(session.host.allocator, parsed);
    if (cursor != bytes.len) {
        shared.setLastError("host: set_exporter_location locator record has trailing bytes", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    session.host.setExporterLocation(session, parsed) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Read the typed cause of this connection's most recent *local* dispatch
/// failure into `out` (the shared `PancakeLastAbort` layout, byte views
/// process-static). Returns `PANCAKE_OK` when a failure has been recorded, or
/// `PANCAKE_ERR_WOULD_BLOCK` when none has. The flat per-feed return code
/// names the failure family; this names the member.
pub export fn pancake_host_session_last_abort(raw: ?*PancakeHostSession, out: ?*shared.PancakeLastAbort) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const info = session.served.peer.lastAbort() orelse return PANCAKE_ERR_WOULD_BLOCK;
    slot.* = shared.lastAbortToC(info);
    return PANCAKE_OK;
}

/// Read the *partner's* retained `op:abort`: the abort kind's wire name (a
/// process-static view, e.g. "ProtocolError") into
/// `*out_kind_name`/`*out_kind_name_len`, and up to `cap` bytes of its
/// bounded diagnostic into `out_msg`, with the retained length in
/// `*out_len`. Returns `PANCAKE_ERR_WOULD_BLOCK` when no partner abort has
/// arrived. Any out-pointer may be null to skip that piece.
pub export fn pancake_host_session_partner_abort(
    raw: ?*PancakeHostSession,
    out_kind_name: ?*?[*]const u8,
    out_kind_name_len: ?*usize,
    out_msg: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const served = &session.served;
    const info = if (served.last_abort) |*retained| retained else return PANCAKE_ERR_WOULD_BLOCK;
    const kind_name = info.kind.wireName();
    if (out_kind_name) |slot| slot.* = kind_name.ptr;
    if (out_kind_name_len) |slot| slot.* = kind_name.len;
    const message = info.message_buf[0..info.message_len];
    if (out_msg) |dest| {
        const n = @min(message.len, cap);
        @memcpy(dest[0..n], message[0..n]);
    }
    if (out_len) |slot| slot.* = message.len;
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

/// Opt-in convenience drain over `pancake_host_next_action` (ADR-0072 fifth
/// amendment). Still pops through the pull-queue internally; does not replace
/// it. NULL `hooks` discards every action (rarely useful). `*out_acted` is 1
/// when any arm reported progress (optional).
pub export fn pancake_host_pump_drain(
    host: ?*PancakeHost,
    hooks: ?*const PancakeHostPumpHooks,
    out_acted: ?*u32,
) i32 {
    if (host == null) {
        shared.setLastError("null host", .{});
        return PANCAKE_ERR_NULL_POINTER;
    }
    const Exec = struct {
        hooks: ?*const PancakeHostPumpHooks,
        err: i32 = PANCAKE_OK,

        fn callArm(self: *@This(), arm: ?PancakeHostPumpArmFn, h: ?*PancakeHost, action: *const PancakeHostAction) !bool {
            const hooks_ptr = self.hooks orelse return false;
            const cb = arm orelse return false;
            var progressed: u32 = 0;
            const rc = cb(hooks_ptr.ctx, h, action, &progressed);
            if (rc != PANCAKE_OK) {
                self.err = rc;
                return error.ArmFailed;
            }
            return progressed != 0;
        }
        pub fn flush(self: *@This(), h: ?*PancakeHost, action: *const PancakeHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.flush else null, h, action);
        }
        pub fn close(self: *@This(), h: ?*PancakeHost, action: *const PancakeHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.close else null, h, action);
        }
        pub fn needGiftId(self: *@This(), h: ?*PancakeHost, action: *const PancakeHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.need_gift_id else null, h, action);
        }
        pub fn complete(self: *@This(), h: ?*PancakeHost, action: *const PancakeHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.complete else null, h, action);
        }
        pub fn dial(self: *@This(), h: ?*PancakeHost, action: *const PancakeHostAction) !bool {
            return self.callArm(if (self.hooks) |hk| hk.dial else null, h, action);
        }
    };
    var exec = Exec{ .hooks = hooks };
    const acted = embedder_pump.drainHost(@This(), shared, host, &exec) catch {
        if (exec.err != PANCAKE_OK) return exec.err;
        shared.setLastError("host action drain failed", .{});
        return PANCAKE_ERR_INTERNAL;
    };
    if (out_acted) |slot| slot.* = if (acted) 1 else 0;
    return PANCAKE_OK;
}

/// Zig-facing one-loop drain helpers over `pancake_host_next_action`
/// (ADR-0072 fifth amendment). Not a C export — the pull-queue stays
/// normative; bindings and tests thin onto this instead of hand-rolling
/// the action switch.
pub const embedder_pump = @import("embedder_pump.zig");
