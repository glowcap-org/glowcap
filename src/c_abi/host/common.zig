//! Shared internal glue for the byte-fed host tier's C ABI
//! (`libpancake_host`).
//!
//! This leaf declares no `export fn`: it is not part of the public surface.
//! It owns the host instance state (`Instance`), the C-behavior bridge
//! (`HostedBehavior`), the handle-recovery casts, the host-error to C-code
//! projection (`errToCode`), and the per-call marshalling the send / tell /
//! turn exports share (`valueMessageFromC`, hosted-behavior marshalling).
//! The `host`,
//! `session`, `turn`, and `pump` leaves import it; the module root
//! (`mod.zig`) re-exports their `pancake_host_*` exports and owns the public C
//! types those exports fill.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const actors = @import("actors");
const driver_core = @import("driver_core");

// The shared C-ABI vocabulary leaf — types, codes, allocation, the last-error
// slot — not the ocapn root, so this archive pulls none of the ocapn family's
// exports (ADR-0059 companion split).
const shared = @import("c_abi_shared");
const host_error = @import("error.zig");

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
pub const PancakeHostAction = c.PancakeHostAction;
pub const PancakeHostBehavior = c.PancakeHostBehavior;
pub const PancakeHostCtxFree = c.PancakeHostCtxFree;

pub const PANCAKE_OK = shared.PANCAKE_OK;
pub const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
pub const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;
pub const PANCAKE_ERR_WOULD_BLOCK = shared.PANCAKE_ERR_WOULD_BLOCK;

/// The retained-capacity ceiling for the per-call scratch arenas: capacity a
/// burst grew above this is freed at the next reset, the steady-bytes posture
/// the actor layer holds on its own arenas.
pub const steady_scratch_bytes = 4096;

/// Which adapter owns transport execution and terminal release for this Host.
/// Application verbs remain Host verbs in either state; the distinction owns
/// the I/O/action-drain half and prevents two drivers from driving or freeing
/// the same core.
pub const DriveOwner = enum {
    embedder,
    driver,
};

/// The host handle's owned state: the byte-fed core plus the C-side bridge
/// registries. The `core` field is embedded by value so a `*Host` reached
/// through a session (`HostSession.host`) recovers the instance with one
/// `@fieldParentPtr`.
pub const Instance = struct {
    core: Host,
    allocator: std.mem.Allocator,
    /// Stable identity in the owning Context's diagnostic namespace, or zero
    /// for the context-less convenience constructor, which has no Context
    /// diagnostic namespace to allocate from.
    diagnostic_id: u64,
    drive_owner: DriveOwner = .embedder,
    /// The C trace callback (`pancake_host_set_trace`), bridged onto the
    /// core's sink; null when tracing is off.
    trace_cb: ?c.PancakeTraceCallback = null,
    trace_ctx: ?*anyopaque = null,
    /// The drained trace ring (`pancake_host_set_trace_queue`), for an
    /// embedder that cannot take the callback; null when none is installed.
    /// Host-scope, so a session pays nothing for it.
    trace_queue: ?*trace_queue.TraceQueue = null,
    /// Scratch for one call's inbound argument marshalling,
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

pub const zero_action = PancakeHostAction{
    .kind = 0,
    .ticket = 0,
    .route_index = 0,
    .session = null,
    .value = shared.zero_argument,
    .message = null,
    .message_len = 0,
    .result = PANCAKE_OK,
};

/// Destroy one Host instance after its drive owner has ended all access.
/// Both archive faces call this no-export implementation; neither calls the
/// other archive's public release symbol.
pub fn releaseInstance(inst: *Instance) ?anyerror {
    const alloc = inst.allocator;
    const failure = inst.core.deinitAfterOwnershipTransfer();
    inst.arg_scratch.deinit();
    inst.turn_scratch.deinit();
    inst.completion_scratch.deinit();
    if (inst.trace_queue) |queue| {
        queue.deinit(alloc);
        alloc.destroy(queue);
    }
    alloc.destroy(inst);
    return failure;
}

pub fn releaseFromDriver(handle: *PancakeHost) ?anyerror {
    const inst = instanceFrom(handle).?;
    std.debug.assert(inst.drive_owner == .driver);
    std.debug.assert(!inst.core.withinCallback());
    return releaseInstance(inst);
}

/// Project one settled/failed completion onto the shared C action shape.
/// The caller resets `completion_scratch` once before this operation.
pub fn projectCompletionInto(inst: *Instance, action: driver_core.HostAction, slot: *PancakeHostAction) i32 {
    const projection = inst.core.projectCompletion(
        action,
        inst.completion_scratch.allocator(),
        inst.completion_scratch.allocator(),
        valueToC,
    );
    slot.* = zero_action;
    switch (projection) {
        .settled => |settled| {
            slot.kind = c.PANCAKE_HOST_ACTION_SETTLE;
            slot.ticket = settled.vow_id;
            slot.value = settled.value;
        },
        .failed => |failed| {
            slot.kind = c.PANCAKE_HOST_ACTION_FAIL;
            slot.ticket = failed.vow_id;
            slot.result = switch (failed.failure) {
                .broken => shared.PANCAKE_ERR_BROKEN,
                .closed => shared.PANCAKE_ERR_CLOSED,
            };
            if (failed.message.len != 0) slot.message = failed.message.ptr;
            slot.message_len = failed.message.len;
        },
    }
    return PANCAKE_OK;
}

pub fn instanceFrom(handle: ?*PancakeHost) ?*Instance {
    return @ptrCast(@alignCast(handle orelse return null));
}

/// Whether the byte-fed embedder still owns transport execution for this
/// Host. Application verbs remain valid after driver adoption; action-drain,
/// listener metadata, session mint/release, and byte-pump verbs do not.
pub fn embedderOwnsDrive(inst: *Instance, operation: []const u8) bool {
    if (inst.drive_owner == .embedder) return true;
    shared.setLastError("host: {s} refused because the native driver owns transport execution", .{operation});
    return false;
}

pub fn sessionFrom(handle: ?*PancakeHostSession) ?*HostSession {
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

/// The session a running wire turn arrived through. The Vat is Host-wide;
/// the turn's Port, not its Vat, recovers the session projection.
pub fn sessionOfTurn(t: *actors.Turn) *HostSession {
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
        // These are C marshalling failures, not Host-domain failures.
        error.UnsupportedValue => shared.PANCAKE_ERR_UNSUPPORTED_VALUE,
        error.NullPointer => PANCAKE_ERR_NULL_POINTER,
        else => host_error.fromError(err),
    };
}

/// Write a borrowed byte slice into a C `ptr + len` view pair, spelling an
/// empty slice as NULL. Every host view-struct field goes through this, so
/// "empty" has one representation across the archive rather than one per
/// call site.
pub fn setView(slice: []const u8, out_ptr: *?[*]const u8, out_len: *usize) void {
    out_ptr.* = if (slice.len == 0) null else slice.ptr;
    out_len.* = slice.len;
}

/// Preflight a foreign callback-context transfer before the C bridge takes
/// ownership. The Host remains the admission authority; this early call only
/// preserves the ABI promise that a reentry refusal leaves `ctx` caller-owned.
pub fn preflightHostedTransfer(inst: *Instance) ?i32 {
    inst.core.refuseReentry() catch |err| return errToCode(err);
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
        const session = sessionOfTurn(turn);
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

pub const ValueMessage = struct {
    verb: []const u8,
    args: []const driver_core.Value,
};

/// Decode one C application message without manufacturing wire references.
/// Capability leaves remain opaque; the core operation routes its target and
/// lowers the complete value tree on the session that will actually carry it.
pub fn valueMessageFromC(
    inst: *Instance,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.PancakeArgument,
    args_len: usize,
) !ValueMessage {
    const verb_slice = try shared.sliceFromC(verb, verb_len);
    if (!inst.core.withinCallback())
        _ = inst.arg_scratch.reset(.{ .retain_with_limit = steady_scratch_bytes });
    return .{
        .verb = verb_slice,
        .args = try shared.valuesFromCWith(
            driver_core.Value,
            anyerror,
            inst,
            decodeHostCapability,
            inst.arg_scratch.allocator(),
            args,
            args_len,
            0,
            false,
        ),
    };
}

fn decodeHostCapability(inst: *Instance, ref: shared.PancakeReference) anyerror!driver_core.Capability {
    return inst.core.capabilityFromRaw(ref.id);
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
/// `valueMessageFromC` does at a top-level call.
pub fn plainArgumentFromC(inst: *Instance, arg: shared.PancakeArgument) !model.Argument {
    if (!inst.core.withinCallback())
        _ = inst.arg_scratch.reset(.{ .retain_with_limit = steady_scratch_bytes });
    return shared.argumentFromCWith(anyerror, {}, refusePlainReference, inst.arg_scratch.allocator(), arg, 0, false);
}

fn encodeHostReference(ctx: HostRefContext, ref: model.Reference) anyerror!shared.PancakeReference {
    return .{ .id = (try ctx.inst.core.liftCapability(ctx.session, ref)).raw() };
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

pub fn valueToC(arena: std.mem.Allocator, value: driver_core.Value) anyerror!shared.PancakeArgument {
    var out = shared.zero_argument;
    switch (value) {
        .integer => |v| {
            out.kind = shared.PANCAKE_ARG_INTEGER;
            out.integer = v;
        },
        .float64 => |v| {
            out.kind = shared.PANCAKE_ARG_FLOAT64;
            out.float64 = v;
        },
        .boolean => |v| {
            out.kind = shared.PANCAKE_ARG_BOOLEAN;
            out.boolean = if (v) 1 else 0;
        },
        .bytes => |bytes| {
            out.kind = shared.PANCAKE_ARG_BYTES;
            out.bytes = bytes.ptr;
            out.bytes_len = bytes.len;
        },
        .string => |bytes| {
            out.kind = shared.PANCAKE_ARG_STRING;
            out.bytes = bytes.ptr;
            out.bytes_len = bytes.len;
        },
        .symbol => |bytes| {
            out.kind = shared.PANCAKE_ARG_SYMBOL;
            out.bytes = bytes.ptr;
            out.bytes_len = bytes.len;
        },
        .@"error" => |reason| {
            out.kind = shared.PANCAKE_ARG_ERROR;
            out.bytes = reason.message.ptr;
            out.bytes_len = reason.message.len;
        },
        .void => out.kind = shared.PANCAKE_ARG_VOID,
        .capability => |capability| {
            out.kind = shared.PANCAKE_ARG_REFERENCE;
            out.reference = .{ .id = capability.raw() };
        },
        .list => |items| {
            out.kind = shared.PANCAKE_ARG_LIST;
            const projected = try valuesToC(arena, items);
            out.items = projected.ptr;
            out.items_len = projected.len;
        },
        .set => |items| {
            out.kind = shared.PANCAKE_ARG_SET;
            const projected = try valuesToC(arena, items);
            out.items = projected.ptr;
            out.items_len = projected.len;
        },
        .tagged => |tagged| {
            out.kind = shared.PANCAKE_ARG_TAGGED;
            out.bytes = tagged.tag.ptr;
            out.bytes_len = tagged.tag.len;
            const projected = try valuesToC(arena, tagged.value);
            out.items = projected.ptr;
            out.items_len = projected.len;
        },
        .keyword => |keyword| {
            out.kind = shared.PANCAKE_ARG_KEYWORD;
            out.bytes = keyword.ptr;
            out.bytes_len = keyword.len;
        },
        .big_integer => |big| {
            out.kind = shared.PANCAKE_ARG_BIG_INTEGER;
            out.boolean = if (big.negative) 1 else 0;
            out.bytes = big.digits.ptr;
            out.bytes_len = big.digits.len;
        },
        .@"struct" => |entries| {
            out.kind = shared.PANCAKE_ARG_STRUCT;
            const projected = try arena.alloc(shared.PancakeArgument, entries.len * 2);
            for (entries, 0..) |entry, i| {
                var key = shared.zero_argument;
                key.kind = shared.PANCAKE_ARG_STRING;
                key.bytes = entry.key.ptr;
                key.bytes_len = entry.key.len;
                projected[i * 2] = key;
                projected[i * 2 + 1] = try valueToC(arena, entry.value);
            }
            out.items = projected.ptr;
            out.items_len = projected.len;
        },
    }
    return out;
}

fn valuesToC(arena: std.mem.Allocator, values: []const driver_core.Value) anyerror![]shared.PancakeArgument {
    const out = try arena.alloc(shared.PancakeArgument, values.len);
    for (values, out) |value, *slot| slot.* = try valueToC(arena, value);
    return out;
}

pub fn hostArgsToC(inst: *Instance, session: *HostSession, arena: std.mem.Allocator, args: []const model.Argument) ![]shared.PancakeArgument {
    return inst.core.projectValues(session, arena, args, arena, valuesToC);
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
