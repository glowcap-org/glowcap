//! The turn-time verbs for `libpancake_host`: from inside a behavior
//! callback, forward this turn's call (`turn_forward`), eventual-send and
//! fire-and-forget on the turn's own session (`turn_send` / `turn_tell`),
//! spawn a fresh hosted object (`turn_spawn`), and break this turn's own
//! answer with a diagnostic (`turn_break`). These are legal only for the
//! `PancakeHostTurn` the enclosing behavior callback received.

const model = @import("model");
const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");

const turnFrom = common.turnFrom;
const sessionOfTurn = common.sessionOfTurn;
const instOf = common.instOf;
const errToCode = common.errToCode;
const msgFromC = common.msgFromC;
const turnTarget = common.turnTarget;
const publishHosted = common.publishHosted;
const reserveHostedCapability = common.reserveHostedCapability;
const steady_scratch_bytes = common.steady_scratch_bytes;

const PancakeHostTurn = c.PancakeHostTurn;

const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;

/// Atomically defer this turn's answer onto a fresh resolver vow (ADR-0102).
/// `*out_resolver_id` receives the one-shot settle authority used by
/// pancake_host_resolver_fulfill / _break. All rows and the forward listener
/// are reserved before publication, so refusal leaves no live resolver and no
/// forwarded effect. The behavior returns normally after success; its return
/// value resolves nothing once the turn is deferred.
pub export fn pancake_host_turn_defer(
    turn: ?*PancakeHostTurn,
    out_resolver_id: ?*u64,
) i32 {
    const t = turnFrom(turn) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_resolver_id orelse return PANCAKE_ERR_NULL_POINTER;
    const session = sessionOfTurn(t);
    const inst = instOf(session.host);
    slot.* = inst.core.deferTurn(session, t) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// From inside a behavior callback, forward this turn's call to `target` and
/// let this object's own answer settle on the forwarded result — the
/// caretaker/attenuator primitive. `target` is an opaque Host-scoped
/// capability; the Host resolves local and remote delivery itself (and refuses
/// stale or foreign-Host identities rather than reading them as wire names).
/// In a wire-served turn the real answer rides the forwarded vow and
/// `*out_reply` gets a void placeholder; pass your behavior's own `out_reply`
/// and return `PANCAKE_OK`. The written reply is BORROWED — valid until the
/// next turn verb or drive on this host.
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
    const session = sessionOfTurn(t);
    const inst = instOf(session.host);
    const msg = msgFromC(inst, session, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    const reference = common.hostRefFromC(inst, session, target_ptr.*) catch |err| return errToCode(err);
    const vat_target = turnTarget(session, reference, msg.args) catch |err| return errToCode(err);
    const reply = t.forward(vat_target, msg) catch |err| return errToCode(err);
    _ = inst.turn_scratch.reset(.{ .retain_with_limit = steady_scratch_bytes });
    slot.* = common.hostArgumentToC(inst, session, inst.turn_scratch.allocator(), reply) catch |err| return errToCode(err);
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
    const session = sessionOfTurn(t);
    const inst = instOf(session.host);
    const msg = msgFromC(inst, session, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    const reference = common.hostRefFromC(inst, session, target_ptr.*) catch |err| return errToCode(err);
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
    const session = sessionOfTurn(t);
    const inst = instOf(session.host);
    const msg = msgFromC(inst, session, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    const reference = common.hostRefFromC(inst, session, target_ptr.*) catch |err| return errToCode(err);
    inst.core.tell(session, reference, msg) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// From inside a behavior callback, spawn a hosted object in the Host Vat and
/// create its first projection on the Port that delivered this turn. This is
/// how a served factory mints the capability it replies with (a task board's
/// `create`, a caretaker wrapping a target), the turn-time form of
/// `pancake_host_session_spawn`. Same `free` contract; `*out_ref` receives the
/// opaque Host-scoped capability.
pub export fn pancake_host_turn_spawn(
    turn: ?*PancakeHostTurn,
    behavior: ?c.PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?c.PancakeHostCtxFree,
    out_ref: ?*shared.PancakeReference,
) i32 {
    const t = turnFrom(turn) orelse return PANCAKE_ERR_NULL_POINTER;
    const b = behavior orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_ref orelse return PANCAKE_ERR_NULL_POINTER;
    const session = sessionOfTurn(t);
    const inst = instOf(session.host);
    reserveHostedCapability(inst, session, ctx, free) catch |err| return errToCode(err);
    const position = publishHosted(session, inst.allocator, null, b, ctx, free) catch |err| return errToCode(err);
    slot.* = common.hostRefToC(inst, session, .{ .near = model.NearRef.object(position) }) catch unreachable;
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
