//! The per-session capability verbs for `libglowcap_host`: publish / spawn,
//! fetch / enliven, send / tell, vow projection, teardown, and diagnostics.
//! Transport pumping lives in `session/pump.zig`. Lifecycle lives in
//! `session/lifecycle.zig`. Turn-time verbs live in `turn.zig`.

const std = @import("std");
const driver_core = @import("driver_core");

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

const GlowcapHost = c.GlowcapHost;
const GlowcapHostSession = c.GlowcapHostSession;

const GLOWCAP_OK = shared.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = shared.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = shared.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_WOULD_BLOCK = shared.GLOWCAP_ERR_WOULD_BLOCK;

// ── Publish and spawn ────────────────────────────────────────────────────────

/// Publish a hosted object a partner on this session can `fetch` by `name` (a
/// swiss-number). The Host Vat owns the object. This session selects its first
/// Port projection. Releasing that session does not run `free`. On success,
/// `free`, if non-null, runs exactly once at Host teardown. A failed
/// construction runs it after this call takes ownership. `*out_ref` receives
/// the opaque Host-scoped capability.
/// Refused inside a callback (ctx stays the caller's on a null-pointer or
/// reentry refusal).
pub fn glowcap_host_session_publish(
    raw: ?*GlowcapHostSession,
    name: ?[*]const u8,
    name_len: usize,
    behavior: ?c.GlowcapHostBehavior,
    ctx: ?*anyopaque,
    free: ?c.GlowcapHostCtxFree,
    out_ref: ?*shared.GlowcapReference,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const b = behavior orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_ref orelse return GLOWCAP_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err| return shared.marshalErrorToCode(err);
    const inst = instOf(session.host);
    if (preflightHostedTransfer(inst)) |code| return code;
    const hosted = common.hostedBridge(inst.allocator, b, ctx, free) catch |err| return errToCode(err);
    const reference = inst.core.sessionPublishHosted(session, name_bytes, hosted) catch |err| return errToCode(err);
    slot.* = .{ .id = reference.raw() };
    return GLOWCAP_OK;
}

/// Spawn a hosted object in the Host Vat and create its first projection on
/// this session, without a fetchable name. It becomes reachable once a reply or
/// argument carries its reference. Same `free` contract as
/// `glowcap_host_session_publish`.
pub fn glowcap_host_session_spawn(
    raw: ?*GlowcapHostSession,
    behavior: ?c.GlowcapHostBehavior,
    ctx: ?*anyopaque,
    free: ?c.GlowcapHostCtxFree,
    out_ref: ?*shared.GlowcapReference,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const b = behavior orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_ref orelse return GLOWCAP_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    if (preflightHostedTransfer(inst)) |code| return code;
    const hosted = common.hostedBridge(inst.allocator, b, ctx, free) catch |err| return errToCode(err);
    const reference = inst.core.spawnHosted(session, hosted) catch |err| return errToCode(err);
    slot.* = .{ .id = reference.raw() };
    return GLOWCAP_OK;
}

// ── Fetch and enliven ────────────────────────────────────────────────────────

/// Fetch the partner capability published as `name`, minting a host vow
/// whose id lands in `*out_vow`. The outcome arrives as that vow's SETTLE or
/// FAIL action. A fulfilled far capability settles *already enrolled* under
/// a node-unique token, recorded before the completion is queued, so a
/// reply that immediately re-gifts it routes to the right exporter. Refused
/// inside a callback.
pub fn glowcap_host_session_fetch(
    raw: ?*GlowcapHostSession,
    name: ?[*]const u8,
    name_len: usize,
    out_vow: ?*u64,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_vow orelse return GLOWCAP_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err| return shared.marshalErrorToCode(err);
    const inst = instOf(session.host);
    slot.* = inst.core.fetch(session, name_bytes) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Enliven the complete canonical persistent sturdyref URI (ADR-0098), minting a
/// host vow whose id lands in `*out_vow`. The live reference arrives as that
/// vow's SETTLE action. The URI's transport and designator must match the
/// selected session before the swiss namespace is consulted or wire traffic
/// is emitted. A dedup-cache hit settles before this returns. A fresh enliven
/// rides bootstrap-fetch. Refused inside a callback.
pub fn glowcap_host_session_enliven(
    raw: ?*GlowcapHostSession,
    sturdyref_uri: ?[*]const u8,
    sturdyref_uri_len: usize,
    out_vow: ?*u64,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_vow orelse return GLOWCAP_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    const uri = shared.sliceFromC(sturdyref_uri, sturdyref_uri_len) catch |err| return shared.marshalErrorToCode(err);
    slot.* = inst.core.enlivenSessionUri(session, uri) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Listen on a far capability this session holds (CapTP `op:listen`, ADR-0095)
/// and mint a host vow that settles with the listen notification. The outcome
/// arrives as that vow's SETTLE or FAIL action. In 1.0, the target may be a
/// far promise or live far object. A live object answers immediately. In
/// glowcap-next, the target must be a far promise because shortening and
/// settling are promise-only. A re-gifted promise routes to its exporter
/// session transparently, and a give in the settlement auto-redeems exactly
/// as a fetch's would. The vow is plain: a listen makes no claim the result
/// is a capability. Legal inside a callback.
pub fn glowcap_host_session_listen(
    raw: ?*GlowcapHostSession,
    target: ?*const shared.GlowcapReference,
    out_vow: ?*u64,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const target_ptr = target orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_vow orelse return GLOWCAP_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    slot.* = inst.core.listenToCapability(
        session,
        inst.core.capabilityFromRaw(target_ptr.id),
    ) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Resolve an opaque capability without requiring the caller to classify it.
/// An object returns one owned retain in out_reference and zero in out_vow.
/// A promise returns zero in out_reference and a settlement vow in out_vow.
/// All pointers are required. Outputs change only on success.
pub fn glowcap_host_session_resolve(
    raw: ?*GlowcapHostSession,
    target: ?*const shared.GlowcapReference,
    out_reference: ?*shared.GlowcapReference,
    out_vow: ?*u64,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const target_ptr = target orelse return GLOWCAP_ERR_NULL_POINTER;
    const reference_slot = out_reference orelse return GLOWCAP_ERR_NULL_POINTER;
    const vow_slot = out_vow orelse return GLOWCAP_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    const resolution = inst.core.resolveCapability(
        session,
        inst.core.capabilityFromRaw(target_ptr.id),
    ) catch |err| return errToCode(err);
    switch (resolution) {
        .resolved => |reference| {
            reference_slot.* = .{ .id = reference.raw() };
            vow_slot.* = 0;
        },
        .pending => |vow| {
            reference_slot.* = .{ .id = 0 };
            vow_slot.* = vow;
        },
    }
    return GLOWCAP_OK;
}

// ── Send, tell, vows, projections ────────────────────────────────────────────

/// Eventual-send to `target` and mint a host vow for the answer. The outcome
/// arrives as that vow's SETTLE or FAIL action. A NEAR target (an export
/// this host bound) runs in-process. A FAR target routes through the node,
/// so a redeemed or fetched token rides its exporter session
/// transparently. A far argument foreign to the routed session is refused
/// whole (`GLOWCAP_ERR_INVALID_ARGUMENT`) rather than mis-encoded. A retired
/// token reports `GLOWCAP_ERR_NOT_FOUND`. `verb`/`args` are borrowed. The
/// host copies what it queues. An empty verb (including `(NULL, 0)`, which
/// the family's ptr+len contract admits) is a real message, not an error: it
/// delivers positionally, the way Goblins invokes a capability. Legal inside
/// a callback (the send encodes when the enclosing call unwinds).
pub fn glowcap_host_session_send(
    raw: ?*GlowcapHostSession,
    target: ?*const shared.GlowcapReference,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.GlowcapArgument,
    args_len: usize,
    out_vow: ?*u64,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const slot = out_vow orelse return GLOWCAP_ERR_NULL_POINTER;
    const call = sessionCall(raw, target, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    slot.* = call.inst.core.sendValues(call.session, call.target, call.msg.verb, call.msg.args, call.inst.arg_scratch.allocator()) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Fire-and-forget eventual-send: `glowcap_host_session_send` with no answer and
/// no vow. Same routing and refusals.
pub fn glowcap_host_session_tell(
    raw: ?*GlowcapHostSession,
    target: ?*const shared.GlowcapReference,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.GlowcapArgument,
    args_len: usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const call = sessionCall(raw, target, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    call.inst.core.tellValues(call.session, call.target, call.msg.verb, call.msg.args, call.inst.arg_scratch.allocator()) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// What every session message verb resolves before it acts: the session
/// behind the handle, its instance, the target capability, and the decoded
/// message. A null handle or target is `NullPointer`.
const SessionCall = struct {
    session: *common.HostSession,
    inst: *common.Instance,
    target: driver_core.Capability,
    msg: common.ValueMessage,
};

fn sessionCall(
    raw: ?*GlowcapHostSession,
    target: ?*const shared.GlowcapReference,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.GlowcapArgument,
    args_len: usize,
) !SessionCall {
    const session = sessionFrom(raw) orelse return error.NullPointer;
    const target_ptr = target orelse return error.NullPointer;
    const inst = instOf(session.host);
    const msg = try valueMessageFromC(inst, verb, verb_len, args, args_len);
    return .{ .session = session, .inst = inst, .target = inst.core.capabilityFromRaw(target_ptr.id), .msg = msg };
}

/// Promise pipelining: eventual-send to a host vow before it resolves,
/// minting a new vow for this call's own answer. A local vow (a NEAR send's
/// answer) has no wire answer to pipeline against and is refused
/// `GLOWCAP_ERR_INVALID_ARGUMENT` (NotPipelineable).
pub fn glowcap_host_vow_send(
    host: ?*GlowcapHost,
    vow: u64,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.GlowcapArgument,
    args_len: usize,
    out_vow: ?*u64,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_vow orelse return GLOWCAP_ERR_NULL_POINTER;
    _ = inst.core.vowSession(vow) catch |err| return errToCode(err);
    const msg = valueMessageFromC(inst, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    slot.* = inst.core.vowSendValues(vow, msg.verb, msg.args, inst.arg_scratch.allocator()) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Fire-and-forget promise-pipelined send. The target rules and argument
/// lowering match `glowcap_host_vow_send`, but no answer or Host vow is minted.
pub fn glowcap_host_vow_tell(
    host: ?*GlowcapHost,
    vow: u64,
    verb: ?[*]const u8,
    verb_len: usize,
    args: ?[*]const shared.GlowcapArgument,
    args_len: usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return GLOWCAP_ERR_NULL_POINTER;
    _ = inst.core.vowSession(vow) catch |err| return errToCode(err);
    const msg = valueMessageFromC(inst, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    inst.core.vowTellValues(vow, msg.verb, msg.args, inst.arg_scratch.allocator()) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Release one public Host vow. The handle remains a valid promise-pipeline
/// target after settlement until this call succeeds. A far answer publishes
/// its `op:gc-answer`. A non-OK return consumes nothing and is retryable.
pub fn glowcap_host_vow_release(host: ?*GlowcapHost, vow: u64) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return GLOWCAP_ERR_NULL_POINTER;
    inst.core.vowRelease(vow) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Pipeline an `op:index` projection against a far host vow, minting a new
/// vow for the projected element. Same local-vow and unknown-vow refusals as
/// `glowcap_host_vow_send`. An index above INT64_MAX is refused
/// `GLOWCAP_ERR_INVALID_ARGUMENT` (the wire index is a signed integer).
pub fn glowcap_host_vow_index(host: ?*GlowcapHost, vow: u64, index: u64, out_vow: ?*u64) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_vow orelse return GLOWCAP_ERR_NULL_POINTER;
    if (index > std.math.maxInt(i64)) {
        shared.setLastError("host: vow_index index out of range", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    }
    slot.* = inst.core.vowIndex(vow, @intCast(index)) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Pipeline an `op:untag` projection against a far host vow, minting a new
/// vow for the unwrapped payload (a single-value Tagged unwraps to that
/// value. A variadic one to its value list). `tag` is borrowed.
pub fn glowcap_host_vow_untag(host: ?*GlowcapHost, vow: u64, tag: ?[*]const u8, tag_len: usize, out_vow: ?*u64) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_vow orelse return GLOWCAP_ERR_NULL_POINTER;
    const tag_bytes = shared.sliceFromC(tag, tag_len) catch |err| return shared.marshalErrorToCode(err);
    slot.* = inst.core.vowUntag(vow, tag_bytes) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Pipeline an `op:get` projection against a far host vow, minting a new
/// vow for the named Struct field. Same local-vow and unknown-vow refusals as
/// `glowcap_host_vow_send`. `field` is borrowed.
pub fn glowcap_host_vow_get(host: ?*GlowcapHost, vow: u64, field: ?[*]const u8, field_len: usize, out_vow: ?*u64) callconv(.c) i32 {
    shared.lastErrorClear();
    const inst = instanceFrom(host) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_vow orelse return GLOWCAP_ERR_NULL_POINTER;
    const field_bytes = shared.sliceFromC(field, field_len) catch |err| return shared.marshalErrorToCode(err);
    slot.* = inst.core.vowGet(vow, field_bytes) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

// ── GC, teardown, diagnostics ────────────────────────────────────────────────

/// Return the opaque Host capability currently published under `name`, lazily
/// projecting its actor from the Host-owned Vat onto `session` when needed. The returned
/// identity itself is Host-scoped and carries no export position.
pub fn glowcap_host_session_published_ref(
    raw: ?*GlowcapHostSession,
    name: ?[*]const u8,
    name_len: usize,
    out_ref: ?*shared.GlowcapReference,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out_ref orelse return GLOWCAP_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err| return shared.marshalErrorToCode(err);
    const inst = instOf(session.host);
    const reference = (inst.core.publishedCapability(session, name_bytes) catch |err| return errToCode(err)) orelse {
        shared.setLastError("host: no capability published under that name", .{});
        return shared.GLOWCAP_ERR_NOT_FOUND;
    };
    slot.* = .{ .id = reference.raw() };
    return GLOWCAP_OK;
}

pub fn glowcap_host_session_break_far_vows(raw: ?*GlowcapHostSession, message: ?[*]const u8, message_len: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_break_far_vows"))
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    const msg = shared.sliceFromC(message, message_len) catch |err| return shared.marshalErrorToCode(err);
    session.host.breakFarVows(session, msg) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

pub fn glowcap_host_session_transport_closed(raw: ?*GlowcapHostSession, message: ?[*]const u8, message_len: usize) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_transport_closed"))
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    const msg = shared.sliceFromC(message, message_len) catch |err| return shared.marshalErrorToCode(err);
    session.host.transportClosed(session, msg) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Record the exporter locator to embed in gives whose exporter is `session`,
/// overriding the session record. Null clears the override. The node owns a
/// validated clone, so the borrowed C view may die when this call returns.
pub fn glowcap_host_session_set_exporter_location(raw: ?*GlowcapHostSession, locator: ?*const shared.GlowcapLocatorView) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const view = locator orelse {
        session.host.setExporterLocation(session, null) catch |err| return errToCode(err);
        return GLOWCAP_OK;
    };
    var hint_stack: [shared.locator_adapter.inline_hint_capacity]model.HintEntry = undefined;
    var borrowed = shared.locator_adapter.BorrowedLocator.init(session.host.allocator, view, &hint_stack) catch |err| {
        if (err == error.OutOfMemory) return errToCode(err);
        shared.setLastError("host: set_exporter_location received an invalid locator view", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    defer borrowed.deinit(session.host.allocator);
    session.host.setExporterLocation(session, borrowed.value) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Read the typed cause of this session's most recent *local* dispatch
/// failure into `out` (the shared `GlowcapLastAbort` layout, byte views
/// process-static). Returns `GLOWCAP_OK` when a failure has been recorded, or
/// `GLOWCAP_ERR_WOULD_BLOCK` when none has. The flat per-feed return code
/// names the failure family. This names the member.
pub fn glowcap_host_session_last_abort(raw: ?*GlowcapHostSession, out: ?*shared.GlowcapLastAbort) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out orelse return GLOWCAP_ERR_NULL_POINTER;
    const info = session.lastAbort() orelse return GLOWCAP_ERR_WOULD_BLOCK;
    slot.* = shared.lastAbortToC(info);
    return GLOWCAP_OK;
}

/// Borrow this session's verified partner identity into `*out`: the partner's
/// session public key, the location designator it signed, and the verbatim
/// location record those came from.
///
/// A `GLOWCAP_OK` return always means the signature was checked. Before the
/// partner's `op:start-session` has arrived with a key this returns
/// `GLOWCAP_ERR_WOULD_BLOCK`, and a session opened without partner verification
/// returns `GLOWCAP_ERR_SESSION` rather than an identity nothing proved. That
/// refusal is the contract: a caller cannot read an unverified identity through
/// this entry point, so it never has to remember to ask whether the bytes were
/// checked.
///
/// See `GlowcapPartnerIdentity` for what the signature covers and how long the
/// borrowed views stay valid.
pub fn glowcap_host_session_partner_identity(
    raw: ?*GlowcapHostSession,
    out: ?*c.GlowcapPartnerIdentity,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const slot = out orelse return GLOWCAP_ERR_NULL_POINTER;
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
    return GLOWCAP_OK;
}

/// Testify what this connection's realizer proved about its far end (ADR-0105):
/// `designator` is the durable key that proof names, as a locator writes it. An
/// iroh listener passes what `glowcap_iroh_conn_remote_node_id` read off the
/// QUIC handshake. A WebRTC peer passes the identity its signaling authorized.
///
/// This library realizes nothing at the byte-fed tier: the embedder owns the
/// sockets, so the embedder is the realizer, and this is the only way that
/// proof reaches a session. Without it the session reports unauthenticated
/// durable provenance.
///
/// Call it after opening the session and before feeding the first partner byte.
/// `GLOWCAP_ERR_SESSION` means the partner's `op:start-session` was already
/// applied, so the proof is too late to weigh. `GLOWCAP_ERR_INVALID_ARGUMENT`
/// means the designator does not spell a durable key, or names a different key
/// from one this connection's realizer already asserted. Asserting the same key
/// twice is the same statement made twice and succeeds.
pub fn glowcap_host_session_bind_verified_channel_key(
    raw: ?*GlowcapHostSession,
    designator: ?[*]const u8,
    designator_len: usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_bind_verified_channel_key")) return GLOWCAP_ERR_INVALID_ARGUMENT;
    const designator_bytes = shared.sliceFromC(designator, designator_len) catch |err| return shared.marshalErrorToCode(err);
    session.host.bindVerifiedChannelKey(session, designator_bytes) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Read the *partner's* retained `op:abort`: the abort kind's wire name (a
/// process-static view, e.g. "ProtocolError") into
/// `*out_kind_name`/`*out_kind_name_len`, and up to `cap` bytes of its
/// bounded diagnostic into `out_msg`, with the retained length in
/// `*out_len`. Returns `GLOWCAP_ERR_WOULD_BLOCK` when no partner abort has
/// arrived. Any out-pointer may be null to skip that piece.
pub fn glowcap_host_session_partner_abort(
    raw: ?*GlowcapHostSession,
    out_kind_name: ?*?[*]const u8,
    out_kind_name_len: ?*usize,
    out_msg: ?[*]u8,
    cap: usize,
    out_len: ?*usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    const served = &session.served;
    const info = if (served.last_abort) |*retained| retained else return GLOWCAP_ERR_WOULD_BLOCK;
    const kind_name = info.kind.wireName();
    if (out_kind_name) |slot| slot.* = kind_name.ptr;
    if (out_kind_name_len) |slot| slot.* = kind_name.len;
    const message = info.message_buf[0..info.message_len];
    if (out_msg) |dest| {
        const n = @min(message.len, cap);
        @memcpy(dest[0..n], message[0..n]);
    }
    if (out_len) |slot| slot.* = message.len;
    return GLOWCAP_OK;
}
