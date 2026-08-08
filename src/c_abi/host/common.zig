//! Shared internal glue for the byte-fed host tier's C ABI
//! (`libpancake_host`).
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
pub const trace_queue = @import("trace_queue.zig");

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

/// The host handle's owned state: the byte-fed core plus the C-side bridge
/// registries. The `core` field is embedded by value so a `*Host` reached
/// through a connection (`HostSession.host`) recovers the instance with one
/// `@fieldParentPtr`.
pub const Instance = struct {
    core: Host,
    allocator: std.mem.Allocator,
    /// The C trace callback (`pancake_host_set_trace`), bridged onto the
    /// core's sink; null when tracing is off.
    trace_cb: ?c.PancakeTraceCallback = null,
    trace_ctx: ?*anyopaque = null,
    /// The drained trace ring (`pancake_host_set_trace_queue`), for an
    /// embedder that cannot take the callback; null when none is installed.
    /// Host-scope, so a session pays nothing for it.
    trace_queue: ?*trace_queue.TraceQueue = null,
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

/// The connection a running wire turn arrived through. The Vat is Host-wide;
/// the turn's Port, not its Vat, recovers the session projection.
pub fn connOfTurn(t: *actors.Turn) *HostSession {
    const served: *driver_core.Served = @fieldParentPtr("port", t.port.?);
    return @alignCast(@fieldParentPtr("served", served));
}

/// Map a host-tier error to a C return code, recording the name for
/// `pancake_host_last_error`.
pub fn errToCode(err: anyerror) i32 {
    // The marshal leaf raises `InvalidArgument` only after writing a message
    // naming the value it refused (`shared.refKindFromC`), which is the whole
    // diagnostic; stamping the bare error name over it would throw that away.
    // Every other error names itself and nothing more.
    if (err != error.InvalidArgument) shared.setLastError("host: {s}", .{@errorName(err)});
    return switch (err) {
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
        error.UnsupportedValue => shared.PANCAKE_ERR_UNSUPPORTED_VALUE,
        error.NullPointer => PANCAKE_ERR_NULL_POINTER,
        // A discriminant outside its family, refused by the marshal leaf with
        // its own message; it is caller misuse, like the group below.
        error.InvalidArgument => PANCAKE_ERR_INVALID_ARGUMENT,
        // The node's fail-closed routing: a retired token or a dead vow row is
        // a lookup that found nothing, not a malformed request.
        error.TokenRetired, error.NoSuchVow, error.UnknownCapability, error.UnknownPublication => shared.PANCAKE_ERR_NOT_FOUND,
        // Namespace misuse at the publication surfaces (ADR-0098): a mutable
        // name in the reserved durable namespace, a durable removal aimed at
        // a mutable name, or entropy reuse colliding with a live durable row.
        error.ReservedDurableNamespace, error.NotDurableName, error.DurableNameCollision => PANCAKE_ERR_INVALID_ARGUMENT,
        // A condemned connection (crossed-hellos loser) refuses every verb;
        // the embedder writes its queued abort and releases it.
        error.ConnectionCondemned => shared.PANCAKE_ERR_CLOSED,
        // The partner has not sent its handshake half yet: nothing is wrong,
        // there is just nothing to read, which is what WOULD_BLOCK names.
        error.HandshakeIncomplete => shared.PANCAKE_ERR_WOULD_BLOCK,
        // Asking a session that never verifies its partner for a verified
        // identity is a session-state refusal, not caller misuse of arguments.
        error.PartnerUnverified => shared.PANCAKE_ERR_SESSION,
        error.PeerIdentityUnverified => shared.PANCAKE_ERR_SESSION,
        // A realizer's proof offered after the partner's handshake was applied:
        // the session has moved past the point the proof was evidence for, which
        // is session state rather than a malformed argument.
        error.HandshakeAlreadyApplied => shared.PANCAKE_ERR_SESSION,
        // Caller misuse: re-entering a host-driving verb from a callback, a
        // foreign-homed argument, an enroll that contradicts the kind on an
        // already-enrolled row, a non-callable target, a projection on a local
        // vow, a late or duplicate listener, an unparseable locator.
        error.ReenteredHost,
        error.SettleInTurn,
        error.SessionlessVow,
        error.NotALocalVow,
        error.PeerIdentityMismatch,
        error.ForeignSession,
        error.ForeignArgument,
        error.EnrolledKindConflict,
        error.NoUnliftedImportRetain,
        error.ImportLifted,
        error.NotAToken,
        error.NotAWirePosition,
        error.DesignatorTooLong,
        error.InvalidChannelKey,
        error.ChannelKeyConflict,
        error.UnheldIdentity,
        error.MissingDirectAddressesHint,
        error.MissingAdvertisedLocator,
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
        error.DuplicateHintName,
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
/// Write a borrowed byte slice into a C `ptr + len` view pair, spelling an
/// empty slice as NULL. Every host view-struct field goes through this, so
/// "empty" has one representation across the archive rather than one per
/// call site.
pub fn setView(slice: []const u8, out_ptr: *?[*]const u8, out_len: *usize) void {
    out_ptr.* = if (slice.len == 0) null else slice.ptr;
    out_len.* = slice.len;
}

pub fn refuseLatched(inst: *const Instance) ?i32 {
    if (inst.core.in_callback) {
        shared.setLastError("host: {s}", .{@errorName(HostError.ReenteredHost)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    }
    return null;
}

/// The C behavior bound to one hosted object. Allocated on the host's
/// allocator and freed by its own `freeThunk` when the actor's box drops
/// (Host release, or a failed construction after ownership transfers).
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
        const session = connOfTurn(turn);
        const inst = instOf(session.host);
        const c_args = try hostArgsToC(inst, session, arena, msg.args);
        var reply = shared.zero_argument;
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
        return try hostArgumentFromCOwned(inst, session, arena, reply, 0);
    }

    /// The actor's box `free`: run the consumer's `free` on the foreign `ctx`,
    /// then free the bridge itself. Runs exactly once when the Host Vat drops
    /// the actor.
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
    vat: *actors.Vat,
    alloc: std.mem.Allocator,
    behavior: PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?PancakeHostCtxFree,
) !actors.Ref {
    return vat.spawnHosted(try hostedBridge(alloc, behavior, ctx, free));
}

/// Allocate the C callback bridge and return the actor descriptor a Vat or
/// Host publication consumes. On allocation failure this owns the foreign
/// `ctx` contract and invokes `free`; after return, `HostedActor.free` does.
pub fn hostedBridge(
    alloc: std.mem.Allocator,
    behavior: PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?PancakeHostCtxFree,
) !actors.HostedActor {
    const bridge = alloc.create(HostedBehavior) catch |e| {
        if (free) |f| f(ctx);
        return e;
    };
    bridge.* = .{ .behavior = behavior, .ctx = ctx, .free = free, .allocator = alloc };
    return .{ .ctx = bridge, .handle = HostedBehavior.handle, .free = HostedBehavior.freeThunk };
}

/// Bind a hosted object on one session: allocate its export position (from
/// the session's one export allocator; named publications also register the
/// bootstrap swissnum), spawn the bridge, and bind. Once the position phase
/// passes, the vat owns the bridge — a later failure leaves the object
/// spawned unbound and its `free` runs at teardown, so `free` still runs
/// exactly once on every outcome.
///
/// Atomic on the session's observable state: a failure past the grant restores
/// the name's prior mapping, releases the never-shared export, and discards a
/// freshly spawned actor if its bind fails. A failed publish (and a caller's
/// retry after one) therefore leaves no dangling name, actor, or export row.
pub fn publishHosted(
    session: *HostSession,
    alloc: std.mem.Allocator,
    name: ?[]const u8,
    behavior: PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?PancakeHostCtxFree,
) !u64 {
    const peer = session.served.port.peer;
    const prior = if (name) |n| peer.session_state.bootstrapLookup(n) else null;
    const position = (if (name) |n| peer.registerBootstrapCap(n) else peer.exportNextObject()) catch |err| {
        if (free) |f| f(ctx);
        return err;
    };
    errdefer {
        if (name) |n| peer.session_state.restoreBootstrapMapping(n, prior);
        peer.session_state.releaseUnsharedExport(.from(position));
    }
    const ref = try spawnBridge(&session.host.vat, alloc, behavior, ctx, free);
    errdefer session.served.discardFreshActor(&session.host.vat, ref);
    try session.served.bindExport(&session.host.vat, ref, position);
    // The export binding roots the actor; the spawn root transfers to it
    // (ADR-0101), so a session-hosted object lives exactly as long as some
    // relationship — this binding, a lift, a gift — holds it.
    session.host.vat.releaseActor(switch (ref) {
        .local => |id| id,
        .far => unreachable,
    });
    return position;
}

/// Reserve the opaque Host identity before `publishHosted` makes its actor or
/// name observable. On reservation failure the Host has not taken ownership,
/// so honor the hosted callback's free contract here; later failures are owned
/// by `publishHosted` / the Vat as before.
pub fn reserveHostedCapability(
    inst: *Instance,
    session: *HostSession,
    ctx: ?*anyopaque,
    free: ?PancakeHostCtxFree,
) !void {
    inst.core.reserveFreshCapability(session) catch |err| {
        if (free) |f| f(ctx);
        return err;
    };
}

/// Marshal one send-shaped call's `verb` + C `args` into an `actors.Message`
/// whose args live in the instance's per-call scratch — the one prologue every
/// send/tell/turn export shares.
pub fn msgFromC(
    inst: *Instance,
    session: *HostSession,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.PancakeArgument,
    args_len: usize,
) !actors.Message {
    // `sliceFromC`, not a bare null check: the family's `ptr + len` contract
    // admits `(null, 0)` as the empty view, and the empty verb is a real
    // message — Goblins invokes a capability positionally with verb "" — that
    // a wasm caller legitimately stages as a null pointer.
    const verb_slice = try shared.sliceFromC(verb, verb_len);
    // Reset only at a top-level call: a composed forward runs its target
    // synchronously, so the outer call's marshalled args (the argument arrays
    // in this scratch — byte payloads stay borrowed from the C caller) are
    // live for the whole callback window, and a nested verb must bump the
    // same arena instead of freeing them mid-call.
    if (!inst.core.in_callback)
        _ = inst.arg_scratch.reset(.{ .retain_with_limit = steady_scratch_bytes });
    return .{
        .verb = verb_slice,
        .args = try shared.argsFromCWith(
            anyerror,
            HostRefContext{ .inst = inst, .session = session },
            decodeHostReference,
            inst.arg_scratch.allocator(),
            args,
            args_len,
            0,
            false,
        ),
    };
}

const HostRefContext = struct {
    inst: *Instance,
    session: *HostSession,
};

fn decodeHostReference(ctx: HostRefContext, ref: shared.PancakeReference) anyerror!model.Reference {
    return ctx.inst.core.lowerCapability(ctx.session, ctx.inst.core.capabilityFromRaw(ref.id));
}

/// The plain-data decode behind a resolver settle (ADR-0102): every
/// reference arm refuses, because the settle carries no session to home a
/// capability — an answer that carries authority takes the turn's
/// forward-to-send path instead.
fn refusePlainReference(ctx: void, ref: shared.PancakeReference) anyerror!model.Reference {
    _ = ctx;
    _ = ref;
    return HostError.ForeignArgument;
}

/// Convert one capability-free C argument for a resolver settle, into the
/// instance's argument scratch (borrowed byte payloads; the vat's settle
/// spine clones what a listener may outlive). Resets the scratch exactly as
/// `msgFromC` does at a top-level call.
pub fn plainArgumentFromC(inst: *Instance, arg: shared.PancakeArgument) !model.Argument {
    if (!inst.core.in_callback)
        _ = inst.arg_scratch.reset(.{ .retain_with_limit = steady_scratch_bytes });
    return shared.argumentFromCWith(anyerror, {}, refusePlainReference, inst.arg_scratch.allocator(), arg, 0, false);
}

fn encodeHostReference(ctx: HostRefContext, ref: model.Reference) anyerror!shared.PancakeReference {
    return .{ .id = (try ctx.inst.core.liftCapability(ctx.session, ref)).raw() };
}

const HostRefEncodeContext = struct {
    inst: *Instance,
    session: *HostSession,
    arena: std.mem.Allocator,
    lifts: *LiftReceipts,
};

/// Rollback receipts for one model->C projection. Ordinary values stay on the
/// stack; a reference-heavy value spills into the projection's existing arena,
/// preserving one walk while keeping the common scalar/list path allocation-
/// free beyond the C child arrays it already needs.
const LiftReceipts = struct {
    const inline_capacity = 8;

    inline_items: [inline_capacity]Host.CapabilityLift = undefined,
    len: usize = 0,
    spill: std.ArrayListUnmanaged(Host.CapabilityLift) = .empty,

    fn ensureOne(self: *LiftReceipts, arena: std.mem.Allocator) !void {
        if (self.spill.capacity != 0) {
            try self.spill.ensureUnusedCapacity(arena, 1);
            return;
        }
        if (self.len < inline_capacity) return;
        try self.spill.ensureTotalCapacityPrecise(arena, inline_capacity + 1);
        self.spill.appendSliceAssumeCapacity(self.inline_items[0..self.len]);
    }

    fn appendAssumeCapacity(self: *LiftReceipts, lifted: Host.CapabilityLift) void {
        if (self.spill.capacity != 0) {
            self.spill.appendAssumeCapacity(lifted);
        } else {
            self.inline_items[self.len] = lifted;
        }
        self.len += 1;
    }

    fn items(self: *const LiftReceipts) []const Host.CapabilityLift {
        return if (self.spill.capacity != 0) self.spill.items else self.inline_items[0..self.len];
    }
};

fn encodeHostReferenceTracked(ctx: HostRefEncodeContext, ref: model.Reference) anyerror!shared.PancakeReference {
    // Reserve the rollback receipt before mutating Host identity state. The
    // receipt list lives with the projection scratch and is discarded on
    // success; on failure it makes every completed lift reversible.
    try ctx.lifts.ensureOne(ctx.arena);
    const lifted = try ctx.inst.core.liftCapabilityTracked(ctx.session, ref);
    ctx.lifts.appendAssumeCapacity(lifted);
    return .{ .id = lifted.ref.raw() };
}

fn rollbackEncodedReferences(inst: *Instance, lifts: []const Host.CapabilityLift) void {
    var i = lifts.len;
    while (i != 0) {
        i -= 1;
        inst.core.rollbackCapabilityLift(lifts[i]);
    }
}

fn discardUnprojectedArgumentReferences(inst: *Instance, session: *HostSession, arg: model.Argument, skip: *usize) void {
    switch (arg) {
        .reference => |reference| {
            if (skip.* != 0) {
                skip.* -= 1;
            } else {
                inst.core.discardCapabilityObservation(session, reference);
            }
        },
        .list, .set => |items| discardUnprojectedReferences(inst, session, items, skip),
        .tagged => |tagged| discardUnprojectedReferences(inst, session, tagged.value, skip),
        .@"struct" => |entries| for (entries) |entry|
            discardUnprojectedArgumentReferences(inst, session, entry.value, skip),
        else => {},
    }
}

fn discardUnprojectedReferences(inst: *Instance, session: *HostSession, args: []const model.Argument, skip: *usize) void {
    for (args) |arg| discardUnprojectedArgumentReferences(inst, session, arg, skip);
}

fn failArgumentProjection(inst: *Instance, session: *HostSession, arg: model.Argument, lifts: []const Host.CapabilityLift) void {
    rollbackEncodedReferences(inst, lifts);
    var skip = lifts.len;
    discardUnprojectedArgumentReferences(inst, session, arg, &skip);
    std.debug.assert(skip == 0);
}

fn failArgsProjection(inst: *Instance, session: *HostSession, args: []const model.Argument, lifts: []const Host.CapabilityLift) void {
    rollbackEncodedReferences(inst, lifts);
    var skip = lifts.len;
    discardUnprojectedReferences(inst, session, args, &skip);
    std.debug.assert(skip == 0);
}

pub fn hostRefFromC(inst: *Instance, session: *HostSession, ref: shared.PancakeReference) !model.Reference {
    return decodeHostReference(.{ .inst = inst, .session = session }, ref);
}

pub fn hostRefToC(inst: *Instance, session: *HostSession, ref: model.Reference) !shared.PancakeReference {
    return encodeHostReference(.{ .inst = inst, .session = session }, ref);
}

pub fn hostArgumentFromCOwned(
    inst: *Instance,
    session: *HostSession,
    arena: std.mem.Allocator,
    arg: shared.PancakeArgument,
    depth: usize,
) !model.Argument {
    return shared.argumentFromCWith(anyerror, HostRefContext{ .inst = inst, .session = session }, decodeHostReference, arena, arg, depth, true);
}

pub fn hostArgumentToC(inst: *Instance, session: *HostSession, arena: std.mem.Allocator, arg: model.Argument) !shared.PancakeArgument {
    var lifts = LiftReceipts{};
    const ctx = HostRefEncodeContext{ .inst = inst, .session = session, .arena = arena, .lifts = &lifts };
    return shared.argumentToCWith(anyerror, ctx, encodeHostReferenceTracked, arena, arg) catch |err| {
        failArgumentProjection(inst, session, arg, lifts.items());
        return err;
    };
}

pub fn hostArgsToC(inst: *Instance, session: *HostSession, arena: std.mem.Allocator, args: []const model.Argument) ![]shared.PancakeArgument {
    var lifts = LiftReceipts{};
    const ctx = HostRefEncodeContext{ .inst = inst, .session = session, .arena = arena, .lifts = &lifts };
    return shared.argsToCWith(anyerror, ctx, encodeHostReferenceTracked, arena, args) catch |err| {
        failArgsProjection(inst, session, args, lifts.items());
        return err;
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

/// One `DurableProvenance` in its C spelling.
///
/// Two surfaces report this fact — the partner-identity query and the trace's
/// session-open — and they must agree, so the mapping lives here once rather
/// than being spelled at each of them.
pub fn provenanceToC(provenance: driver_core.DurableProvenance) u32 {
    return switch (provenance) {
        .authenticated_transport => c.PANCAKE_DURABLE_PROVENANCE_AUTHENTICATED_TRANSPORT,
        .unauthenticated => c.PANCAKE_DURABLE_PROVENANCE_UNAUTHENTICATED,
    };
}
