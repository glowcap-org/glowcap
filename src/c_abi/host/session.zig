//! The per-session capability verbs for `libpancake_host`: publish / spawn,
//! fetch / enliven, send / tell, vow projection, teardown, and diagnostics.
//! Transport pumping lives in `session/pump.zig`; lifecycle lives in
//! `session/lifecycle.zig`; turn-time verbs live in `turn.zig`.

const std = @import("std");

const model = @import("model");

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");

const instanceFrom = common.instanceFrom;
const sessionFrom = common.sessionFrom;
const instOf = common.instOf;
const errToCode = common.errToCode;
const setView = common.setView;
const preflightHostedTransfer = common.preflightHostedTransfer;
const valueMessageFromC = common.valueMessageFromC;

const PancakeHost = c.PancakeHost;
const PancakeHostSession = c.PancakeHostSession;

const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_WOULD_BLOCK = shared.PANCAKE_ERR_WOULD_BLOCK;

// ── Publish and spawn ────────────────────────────────────────────────────────

/// Publish a hosted object a partner on this session can `fetch` by `name` (a
/// swiss-number). The Host Vat owns the object; this session selects its first
/// Port projection. Releasing that session does not run `free`. On success,
/// `free`, if non-null, runs exactly once at Host teardown; a failed
/// construction runs it after this call takes ownership. `*out_ref` receives
/// the opaque Host-scoped capability.
/// Refused inside a callback (ctx stays the caller's on a null-pointer or
/// reentry refusal).
pub export fn pancake_host_session_publish(
    raw: ?*PancakeHostSession,
    name: ?[*]const u8,
    name_len: usize,
    behavior: ?c.PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?c.PancakeHostCtxFree,
    out_ref: ?*shared.PancakeReference,
) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const b = behavior orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_ref orelse return PANCAKE_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err| return shared.marshalErrorToCode(err);
    const inst = instOf(session.host);
    if (preflightHostedTransfer(inst)) |code| return code;
    const hosted = common.hostedBridge(inst.allocator, b, ctx, free) catch |err| return errToCode(err);
    const reference = inst.core.publishHosted(session, name_bytes, hosted) catch |err| return errToCode(err);
    slot.* = .{ .id = reference.raw() };
    return PANCAKE_OK;
}

/// Spawn a hosted object in the Host Vat and create its first projection on
/// this session, without a fetchable name. It becomes reachable once a reply or
/// argument carries its reference. Same `free` contract as
/// `pancake_host_session_publish`.
pub export fn pancake_host_session_spawn(
    raw: ?*PancakeHostSession,
    behavior: ?c.PancakeHostBehavior,
    ctx: ?*anyopaque,
    free: ?c.PancakeHostCtxFree,
    out_ref: ?*shared.PancakeReference,
) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const b = behavior orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_ref orelse return PANCAKE_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    if (preflightHostedTransfer(inst)) |code| return code;
    const hosted = common.hostedBridge(inst.allocator, b, ctx, free) catch |err| return errToCode(err);
    const reference = inst.core.spawnHosted(session, hosted) catch |err| return errToCode(err);
    slot.* = .{ .id = reference.raw() };
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
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err| return shared.marshalErrorToCode(err);
    const inst = instOf(session.host);
    slot.* = inst.core.fetch(session, name_bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Enliven the complete canonical persistent sturdyref URI (ADR-0098), minting a
/// host vow whose id lands in `*out_vow`; the live reference arrives as that
/// vow's SETTLE action. The URI's transport and designator must match the
/// selected session before the swiss namespace is consulted or wire traffic
/// is emitted. A dedup-cache hit settles before this returns; a fresh enliven
/// rides bootstrap-fetch. Refused inside a callback.
pub export fn pancake_host_session_enliven(
    raw: ?*PancakeHostSession,
    sturdyref_uri: ?[*]const u8,
    sturdyref_uri_len: usize,
    out_vow: ?*u64,
) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    const uri = shared.sliceFromC(sturdyref_uri, sturdyref_uri_len) catch |err| return shared.marshalErrorToCode(err);
    slot.* = inst.core.enlivenSessionUri(session, uri) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Listen on a far capability this session holds (CapTP `op:listen`, ADR-0095)
/// and mint a host vow that settles with the listen notification; the outcome
/// arrives as that vow's SETTLE or FAIL action. In 1.0, the target may be a
/// far promise or live far object; a live object answers immediately. In
/// pancake-next, the target must be a far promise because shortening and
/// settling are promise-only. A re-gifted promise routes to its exporter
/// session transparently, and a give in the settlement auto-redeems exactly
/// as a fetch's would. The vow is plain — a listen makes no claim the result
/// is a capability. Legal inside a callback.
pub export fn pancake_host_session_listen(
    raw: ?*PancakeHostSession,
    target: ?*const shared.PancakeReference,
    out_vow: ?*u64,
) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const target_ptr = target orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    slot.* = inst.core.listenToCapability(
        session,
        inst.core.capabilityFromRaw(target_ptr.id),
    ) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

// ── Send, tell, vows, projections ────────────────────────────────────────────

/// Eventual-send to `target` and mint a host vow for the answer; the outcome
/// arrives as that vow's SETTLE or FAIL action. A NEAR target (an export
/// this host bound) runs in-process; a FAR target routes through the node,
/// so a redeemed or fetched token rides its exporter session
/// transparently. A far argument foreign to the routed session is refused
/// whole (`PANCAKE_ERR_INVALID_ARGUMENT`) rather than mis-encoded; a retired
/// token reports `PANCAKE_ERR_NOT_FOUND`. `verb`/`args` are borrowed; the
/// host copies what it queues. An empty verb — including `(NULL, 0)`, which
/// the family's ptr+len contract admits — is a real message, not an error: it
/// delivers positionally, the way Goblins invokes a capability. Legal inside
/// a callback (the send encodes when the enclosing call unwinds).
pub export fn pancake_host_session_send(
    raw: ?*PancakeHostSession,
    target: ?*const shared.PancakeReference,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.PancakeArgument,
    args_len: usize,
    out_vow: ?*u64,
) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const target_ptr = target orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    const msg = valueMessageFromC(inst, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    slot.* = inst.core.sendValues(
        session,
        inst.core.capabilityFromRaw(target_ptr.id),
        msg.verb,
        msg.args,
        inst.arg_scratch.allocator(),
    ) catch |err| return errToCode(err);
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
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const target_ptr = target orelse return PANCAKE_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    const msg = valueMessageFromC(inst, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    inst.core.tellValues(
        session,
        inst.core.capabilityFromRaw(target_ptr.id),
        msg.verb,
        msg.args,
        inst.arg_scratch.allocator(),
    ) catch |err| return errToCode(err);
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
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    _ = inst.core.vowSession(vow) catch |err| return errToCode(err);
    const msg = valueMessageFromC(inst, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    slot.* = inst.core.vowSendValues(vow, msg.verb, msg.args, inst.arg_scratch.allocator()) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Fire-and-forget promise-pipelined send. The target rules and argument
/// lowering match `pancake_host_vow_send`, but no answer or Host vow is minted.
pub export fn pancake_host_vow_tell(
    host: ?*PancakeHost,
    vow: u64,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.PancakeArgument,
    args_len: usize,
) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    _ = inst.core.vowSession(vow) catch |err| return errToCode(err);
    const msg = valueMessageFromC(inst, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    inst.core.vowTellValues(vow, msg.verb, msg.args, inst.arg_scratch.allocator()) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Release one public Host vow. The handle remains a valid promise-pipeline
/// target after settlement until this call succeeds. A far answer publishes
/// its `op:gc-answer`; a non-OK return consumes nothing and is retryable.
pub export fn pancake_host_vow_release(host: ?*PancakeHost, vow: u64) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    inst.core.vowRelease(vow) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Pipeline an `op:index` projection against a far host vow, minting a new
/// vow for the projected element. Same local-vow and unknown-vow refusals as
/// `pancake_host_vow_send`; an index above INT64_MAX is refused
/// `PANCAKE_ERR_INVALID_ARGUMENT` (the wire index is a signed integer).
pub export fn pancake_host_vow_index(host: ?*PancakeHost, vow: u64, index: u64, out_vow: ?*u64) i32 {
    shared.lastErrorClear();
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
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const tag_bytes = shared.sliceFromC(tag, tag_len) catch |err| return shared.marshalErrorToCode(err);
    slot.* = inst.core.vowUntag(vow, tag_bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Pipeline an `op:get` projection against a far host vow, minting a new
/// vow for the named Struct field. Same local-vow and unknown-vow refusals as
/// `pancake_host_vow_send`; `field` is borrowed.
pub export fn pancake_host_vow_get(host: ?*PancakeHost, vow: u64, field: ?[*]const u8, field_len: usize, out_vow: ?*u64) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const field_bytes = shared.sliceFromC(field, field_len) catch |err| return shared.marshalErrorToCode(err);
    slot.* = inst.core.vowGet(vow, field_bytes) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

// ── GC, teardown, diagnostics ────────────────────────────────────────────────

/// Return the opaque Host capability currently published under `name`, lazily
/// projecting its actor from the Host-owned Vat onto `session` when needed. The returned
/// identity itself is Host-scoped and carries no export position.
pub export fn pancake_host_session_published_ref(
    raw: ?*PancakeHostSession,
    name: ?[*]const u8,
    name_len: usize,
    out_ref: ?*shared.PancakeReference,
) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_ref orelse return PANCAKE_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err| return shared.marshalErrorToCode(err);
    const inst = instOf(session.host);
    const reference = (inst.core.publishedCapability(session, name_bytes) catch |err| return errToCode(err)) orelse {
        shared.setLastError("host: no capability published under that name", .{});
        return shared.PANCAKE_ERR_NOT_FOUND;
    };
    slot.* = .{ .id = reference.raw() };
    return PANCAKE_OK;
}

pub export fn pancake_host_session_break_far_vows(raw: ?*PancakeHostSession, message: ?[*]const u8, message_len: usize) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_break_far_vows"))
        return PANCAKE_ERR_INVALID_ARGUMENT;
    const msg = shared.sliceFromC(message, message_len) catch |err| return shared.marshalErrorToCode(err);
    session.host.breakFarVows(session, msg) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

pub export fn pancake_host_session_transport_closed(raw: ?*PancakeHostSession, message: ?[*]const u8, message_len: usize) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_transport_closed"))
        return PANCAKE_ERR_INVALID_ARGUMENT;
    const msg = shared.sliceFromC(message, message_len) catch |err| return shared.marshalErrorToCode(err);
    session.host.transportClosed(session, msg) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Record the exporter locator to embed in gives whose exporter is `session`,
/// overriding the session record. Null clears the override. The node owns a
/// validated clone, so the borrowed C view may die when this call returns.
pub export fn pancake_host_session_set_exporter_location(raw: ?*PancakeHostSession, locator: ?*const shared.PancakeLocatorView) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const view = locator orelse {
        session.host.setExporterLocation(session, null) catch |err| return errToCode(err);
        return PANCAKE_OK;
    };
    var hint_stack: [shared.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = shared.locator_adapter.BorrowedLocator.init(session.host.allocator, view, &hint_stack) catch |err| {
        if (err == error.OutOfMemory) return errToCode(err);
        shared.setLastError("host: set_exporter_location received an invalid locator view", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    defer borrowed.deinit(session.host.allocator);
    session.host.setExporterLocation(session, borrowed.value) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Read the typed cause of this session's most recent *local* dispatch
/// failure into `out` (the shared `PancakeLastAbort` layout, byte views
/// process-static). Returns `PANCAKE_OK` when a failure has been recorded, or
/// `PANCAKE_ERR_WOULD_BLOCK` when none has. The flat per-feed return code
/// names the failure family; this names the member.
pub export fn pancake_host_session_last_abort(raw: ?*PancakeHostSession, out: ?*shared.PancakeLastAbort) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const info = session.lastAbort() orelse return PANCAKE_ERR_WOULD_BLOCK;
    slot.* = shared.lastAbortToC(info);
    return PANCAKE_OK;
}

/// Borrow this session's verified partner identity into `*out`: the partner's
/// session public key, the location designator it signed, and the verbatim
/// location record those came from.
///
/// A `PANCAKE_OK` return always means the signature was checked. Before the
/// partner's `op:start-session` has arrived with a key this returns
/// `PANCAKE_ERR_WOULD_BLOCK`, and a session opened without partner verification
/// returns `PANCAKE_ERR_SESSION` rather than an identity nothing proved. That
/// refusal is the contract: a caller cannot read an unverified identity through
/// this entry point, so it never has to remember to ask whether the bytes were
/// checked.
///
/// See `PancakePartnerIdentity` for what the signature covers and how long the
/// borrowed views stay valid.
pub export fn pancake_host_session_partner_identity(
    raw: ?*PancakeHostSession,
    out: ?*c.PancakePartnerIdentity,
) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const identity = session.host.partnerIdentity(session) catch |err| return errToCode(err);
    slot.* = .{
        .session_key = identity.session_key.ptr,
        .session_key_len = identity.session_key.len,
        .designator = null,
        .designator_len = 0,
        .locator_record = null,
        .locator_record_len = 0,
        .provenance = common.provenanceToC(identity.provenance),
    };
    setView(identity.designator, &slot.designator, &slot.designator_len);
    setView(identity.locator_record, &slot.locator_record, &slot.locator_record_len);
    return PANCAKE_OK;
}

/// Testify what this connection's realizer proved about its far end (ADR-0105):
/// `designator` is the durable key that proof names, as a locator writes it. An
/// iroh listener passes what `pancake_iroh_conn_remote_node_id` read off the
/// QUIC handshake; a WebRTC peer passes the identity its signaling authorized.
///
/// This library realizes nothing at the byte-fed tier — the embedder owns the
/// sockets, so the embedder is the realizer, and this is the only way that
/// proof reaches a session. Without it the session reports unauthenticated
/// durable provenance.
///
/// Call it after opening the session and before feeding the first partner byte.
/// `PANCAKE_ERR_SESSION` means the partner's `op:start-session` was already
/// applied, so the proof is too late to weigh. `PANCAKE_ERR_INVALID_ARGUMENT`
/// means the designator does not spell a durable key, or names a different key
/// from one this connection's realizer already asserted. Asserting the same key
/// twice is the same statement made twice and succeeds.
pub export fn pancake_host_session_bind_verified_channel_key(
    raw: ?*PancakeHostSession,
    designator: ?[*]const u8,
    designator_len: usize,
) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_bind_verified_channel_key")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const designator_bytes = shared.sliceFromC(designator, designator_len) catch |err| return shared.marshalErrorToCode(err);
    session.host.bindVerifiedChannelKey(session, designator_bytes) catch |err| return errToCode(err);
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
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
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
