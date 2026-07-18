//! Shared internal glue for the byte-fed host tier's C ABI
//! (`libpancake_driver`).
//!
//! This leaf declares no `export fn`: it is not part of the public surface.
//! It owns the host instance state (`Instance`), the C-behavior bridge
//! (`HostedBehavior`), the handle-recovery casts, the host-error to C-code
//! projection (`errToCode`), and the per-call marshalling the send / tell /
//! turn exports share (`msgFromC`, `turnTarget`, `publishHosted`). The `host`,
//! `session`, `turn`, and `pump` leaves import it; the module root
//! (`mod.zig`) re-exports their `pancake_host_*` exports and owns the public C
//! types those exports fill.

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

// The module root owns the public C types these helpers fill; import it for the
// opaque handles and the behavior callback typedefs (a lazy cyclic import, the
// same shape `src/c_abi/ocapn` uses between its root and handle-family files).
const c = @import("mod.zig");

pub const crypto = foundation.crypto;
pub const Host = driver_core.Host;
pub const HostSession = driver_core.HostSession;
pub const HostError = driver_core.HostError;

pub const PancakeHost = c.PancakeHost;
pub const PancakeHostSession = c.PancakeHostSession;
pub const PancakeHostTurn = c.PancakeHostTurn;
pub const PancakeHostBehavior = c.PancakeHostBehavior;
pub const PancakeHostCtxFree = c.PancakeHostCtxFree;

pub const PANCAKE_OK = shared.PANCAKE_OK;
pub const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
pub const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;
pub const PANCAKE_ERR_INTERNAL = shared.PANCAKE_ERR_INTERNAL;
pub const PANCAKE_ERR_WOULD_BLOCK = shared.PANCAKE_ERR_WOULD_BLOCK;

/// The retained-capacity ceiling for the per-call scratch arenas: capacity a
/// burst grew above this is freed at the next reset, the steady-bytes posture
/// the actor layer holds on its own arenas.
pub const steady_scratch_bytes = 4096;

/// A host-wide giftable registration (`pancake_host_publish`): one shared
/// behavior/ctx published under `name` on every session now open and every
/// future one. The row owns `name` and `ctx` — the per-session bridges
/// carry a null free so the shared ctx is freed exactly once, here, at host
/// release.
pub const Giftable = struct {
    name: []u8,
    behavior: PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?PancakeHostCtxFree,
};

/// The host handle's owned state: the byte-fed core plus the C-side bridge
/// registries. The `core` field is embedded by value so a `*Host` reached
/// through a connection (`HostSession.host`) recovers the instance with one
/// `@fieldParentPtr`.
pub const Instance = struct {
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

pub fn instanceFrom(handle: ?*PancakeHost) ?*Instance {
    return @ptrCast(@alignCast(handle orelse return null));
}

pub fn connFrom(handle: ?*PancakeHostSession) ?*HostSession {
    return @ptrCast(@alignCast(handle orelse return null));
}

pub fn turnFrom(handle: ?*PancakeHostTurn) ?*actors.Turn {
    return @ptrCast(@alignCast(handle orelse return null));
}

/// The instance a host core is embedded in — `Instance.core` is by value, so
/// this is one field-parent hop.
pub fn instOf(core: *Host) *Instance {
    return @fieldParentPtr("core", core);
}

/// The connection a running turn belongs to: every actor on this surface
/// lives in some connection's serve-core vat, so the turn's vat recovers its
/// `Served` and that its `HostSession` by field parentage.
pub fn connOfTurn(t: *actors.Turn) *HostSession {
    const served: *driver_core.Served = @fieldParentPtr("vat", t.vat);
    return @fieldParentPtr("served", served);
}

/// Map a host-tier error to a C return code, recording the name for
/// `pancake_host_last_error`.
pub fn errToCode(err: anyerror) i32 {
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
        error.SessionPairExists,
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
pub fn refuseLatched(inst: *const Instance) ?i32 {
    if (inst.core.in_callback) {
        shared.setLastError("host: {s}", .{@errorName(HostError.ReenteredHost)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    return null;
}

/// The C behavior bound to one hosted object. Allocated on the host's
/// allocator and freed by its own `freeThunk` when the actor's box drops
/// (connection or host release, or a failed spawn).
pub const HostedBehavior = struct {
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
    pub fn handle(erased: *anyopaque, turn: *actors.Turn, msg: actors.Message) anyerror!model.Argument {
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
    pub fn freeThunk(erased: *anyopaque) void {
        const self: *HostedBehavior = @ptrCast(@alignCast(erased));
        if (self.free) |f| f(self.ctx);
        self.allocator.destroy(self);
    }
};

/// Spawn a hosted object on `served`, wrapping the C callbacks in a `HostedBehavior`. On
/// a spawn failure the free contract is honored here (freeing `ctx` and the
/// bridge), so the caller never double-frees.
pub fn spawnBridge(
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
///
/// Atomic on the session's observable state: a failure past the grant restores
/// the name's prior mapping and releases the never-shared export, so a failed
/// publish (and a caller's retry after one) leaves no dangling name and mints
/// no phantom export row. The spawned-but-unbound bridge arm on the vat is the
/// one slot the unwind cannot reclaim; it dies with the session.
pub fn publishHosted(
    session: *HostSession,
    alloc: std.mem.Allocator,
    name: ?[]const u8,
    behavior: PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?PancakeHostCtxFree,
) !u64 {
    const peer = session.served.peer;
    const prior = if (name) |n| peer.session_state.bootstrapLookup(n) else null;
    const position = (if (name) |n| peer.registerBootstrapCap(n) else peer.exportNextObject()) catch |err| {
        if (free) |f| f(ctx);
        return err;
    };
    errdefer {
        if (name) |n| peer.session_state.restoreBootstrapMapping(n, prior);
        peer.session_state.releaseUnsharedExport(.from(position));
    }
    const ref = try spawnBridge(&session.served, alloc, behavior, ctx, free);
    try session.served.bindExport(ref, position);
    return position;
}

/// Publish every giftable row onto a freshly opened connection, so a gift
/// deposited under the row's swissnum resolves against this session's own
/// bootstrap registry — the replay that makes a three-party withdraw find the
/// exporter's object on whichever connection the recipient dialed.
pub fn replayGiftables(inst: *Instance, session: *HostSession) !void {
    for (inst.giftables.items) |row| {
        _ = try publishHosted(session, inst.allocator, row.name, row.behavior, row.ctx, null);
    }
}

/// Marshal one send-shaped call's `verb` + C `args` into an `actors.Message`
/// whose args live in the instance's per-call scratch — the one prologue every
/// send/tell/turn export shares.
pub fn msgFromC(
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
pub fn turnTarget(session: *HostSession, reference: model.Reference, args: []const model.Argument) !actors.Ref {
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
