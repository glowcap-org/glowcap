//! The per-session verbs for `libpancake_host`: open a dialed or accepted
//! CapTP session, the byte pump (`feed` / `feed_bytes` / `take_outbound`),
//! publish / spawn / fetch / enliven, the send / tell / vow-projection
//! messaging surface, breaking a gone session's far vows, the exporter
//! location override, and the local / partner abort diagnostics. Host
//! lifecycle lives in `host.zig`, turn-time verbs in `turn.zig`.

const std = @import("std");

const crypto = @import("foundation").crypto;
const model = @import("model");
const engine = @import("engine");

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
const PancakeFrame = shared.PancakeFrame;
const PancakeManagedFrame = shared.PancakeManagedFrame;

const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_INTERNAL = shared.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_WOULD_BLOCK = shared.PANCAKE_ERR_WOULD_BLOCK;

// ── The byte pump ────────────────────────────────────────────────────────────

/// Feed one inbound frame the embedder read from its own transport (borrowed
/// for the call): behavior callbacks fire and vow completions queue inside,
/// then the node actions the dispatch queued pump and every touched
/// session's outbound encodes. `PANCAKE_ERR_WOULD_BLOCK` is the preflight
/// high-water refusal: the frame was not consumed, so drain `take_outbound`,
/// write those frames, and retry it. A non-WOULD_BLOCK failure classifies
/// through the shared taxonomy (`PANCAKE_ERR_CODEC` / `_SESSION` /
/// `_INTERNAL`). When `pancake_host_session_last_abort` succeeds, the frame was
/// consumed and the session is closing; drain its typed `op:abort` and release
/// it. `PANCAKE_ERR_INTERNAL` with no last-abort is allocation failure before
/// frame admission, so the same borrowed frame remains retryable.
pub export fn pancake_host_session_feed(raw: ?*PancakeHostSession, frame_in: ?*const PancakeFrame) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_feed")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const borrowed = frame_in orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = borrowed.bytes orelse return PANCAKE_ERR_NULL_POINTER;
    const shape = shared.frameShapeFromC(borrowed.shape) orelse {
        shared.setLastError("host: session_feed frame shape is not a PANCAKE_FRAME_* value", .{});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    session.host.feed(session, .{ .bytes = bytes_ptr[0..borrowed.len], .shape = shape }) catch |err| {
        return errToCode(err);
    };
    return PANCAKE_OK;
}

/// Feed a byte-stream chunk the embedder read from its own transport
/// (borrowed for the call). The library owns outer framing and the tail: each
/// bare codec frame is one canonical Syrup byte string (`length:body`). Split
/// prefixes and bodies stay buffered in the session; coalesced byte strings
/// dispatch in order, each body exactly as `pancake_host_session_feed`.
/// Dispatch pauses at the frame that
/// completes the keyed handshake: frames coalesced behind the hello wait in
/// the session's tail while the embedder acts on the fresh session (publish,
/// fetch), and the next call — an empty chunk (`len` 0, `bytes` may be NULL)
/// works — feeds them. A declared body exceeding the session's frame cap is
/// refused `PANCAKE_ERR_FRAME_TOO_LARGE`; malformed or non-canonical outer
/// syntax is refused as a codec error; any other failure follows
/// `pancake_host_session_feed`'s classification. `PANCAKE_ERR_WOULD_BLOCK` is
/// the preflight high-water refusal and consumes no bytes from this call.
/// Pressure after any prefix commits is retained in the session tail. The core
/// issues a FLUSH wake and resumes that tail when outbound drains, so embedders
/// never replay the chunk or manufacture an empty-feed retry. An internal
/// failure before the first frame commits leaves the same borrowed chunk
/// retryable. While resuming retained input, pre-commit allocation or outbound
/// pressure preserves the owned tail and surfaces from the outbound drain;
/// a post-commit failure records `last_abort` and condemns the session.
pub export fn pancake_host_session_feed_bytes(
    raw: ?*PancakeHostSession,
    bytes: ?[*]const u8,
    len: usize,
) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_feed_bytes")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const chunk: []const u8 = if (len == 0) &.{} else blk: {
        const buf = bytes orelse return PANCAKE_ERR_NULL_POINTER;
        break :blk buf[0..len];
    };
    session.host.feedBytes(session, chunk) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Drain one transport-ready byte-stream vector. Write `out_prefix[0..out_prefix_len]`
/// and then the owned `out_frame` bytes. Clear sessions return their canonical
/// outer Syrup prefix; sealed sessions return an empty prefix because their
/// payload is already wire-ready ciphertext. Free `out_frame` through
/// `pancake_managed_frame_release`.
/// Returns `PANCAKE_OK` with `out_frame` set, or `PANCAKE_ERR_WOULD_BLOCK`
/// (with outputs untouched) when the queue is empty. `prefix_cap` must be at
/// least `PANCAKE_HOST_OUTBOUND_PREFIX_CAP`; undersizing is refused before the
/// payload leaves the queue. Refused inside a callback.
pub export fn pancake_host_session_take_outbound(
    raw: ?*PancakeHostSession,
    out_frame: ?*PancakeManagedFrame,
    out_prefix: ?[*]u8,
    prefix_cap: usize,
    out_prefix_len: ?*usize,
) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_take_outbound")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;
    const prefix = out_prefix orelse return PANCAKE_ERR_NULL_POINTER;
    const prefix_len = out_prefix_len orelse return PANCAKE_ERR_NULL_POINTER;
    if (prefix_cap < c.PANCAKE_HOST_OUTBOUND_PREFIX_CAP) {
        prefix_len.* = c.PANCAKE_HOST_OUTBOUND_PREFIX_CAP;
        return shared.PANCAKE_ERR_BUFFER_TOO_SMALL;
    }
    const inst = instOf(session.host);
    const reservation = shared.reserveManagedFrame(inst.allocator) catch {
        shared.setLastError("take_outbound: frame wrap allocation failed", .{});
        return shared.PANCAKE_ERR_INTERNAL;
    };
    // The core drain carries the reentry refusal (`ReenteredHost` maps to
    // INVALID_ARGUMENT), so the two tiers cannot disagree on the latch.
    const popped = session.takeStreamOutbound() catch |err| {
        reservation.cancel();
        return errToCode(err);
    };
    const outbound = popped orelse {
        reservation.cancel();
        return PANCAKE_ERR_WOULD_BLOCK;
    };
    @memcpy(prefix[0..outbound.prefix_len], outbound.prefixBytes());
    prefix_len.* = outbound.prefix_len;
    slot.* = reservation.commit(outbound.payload);
    return PANCAKE_OK;
}

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

/// Enliven the complete sturdyref URI (ADR-0098), minting a
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
