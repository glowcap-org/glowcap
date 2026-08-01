//! The per-session verbs for `libpancake_host`: open a dialed or accepted
//! CapTP session, the byte pump (`feed` / `feed_bytes` / `take_outbound`),
//! publish / spawn / fetch / enliven, the send / tell / vow-projection
//! messaging surface, breaking a gone connection's far vows, the exporter
//! location override, and the local / partner abort diagnostics. Host
//! lifecycle lives in `host.zig`, turn-time verbs in `turn.zig`.

const std = @import("std");

const model = @import("model");
const engine = @import("engine");

const shared = @import("c_abi_shared");
const c = @import("mod.zig");
const common = @import("common.zig");

const instanceFrom = common.instanceFrom;
const connFrom = common.connFrom;
const instOf = common.instOf;
const errToCode = common.errToCode;
const setView = common.setView;
const refuseLatched = common.refuseLatched;
const msgFromC = common.msgFromC;
const publishHosted = common.publishHosted;
const reserveHostedCapability = common.reserveHostedCapability;

const PancakeHost = c.PancakeHost;
const PancakeHostSession = c.PancakeHostSession;
const PancakeFrame = shared.PancakeFrame;
const PancakeManagedFrame = shared.PancakeManagedFrame;

const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_WOULD_BLOCK = shared.PANCAKE_ERR_WOULD_BLOCK;

// ── Connection lifecycle ─────────────────────────────────────────────────────

/// Mint the dialing half from an already-parsed locator (`transport` +
/// `designator`). A DIAL action carries only `ticket` — borrow the pending view
/// with `pancake_host_pending_dial` and pass its transport/designator here.
/// The keyed `op:start-session` is signed under the host identity and encoded
/// before this returns, so drain `take_outbound` (a FLUSH action is queued) and
/// drive the handshake byte-fed. Host-wide aliases remain lazily discoverable
/// through the new session. A URI-holding caller parses first
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
    slot.* = @ptrCast(session);
    return PANCAKE_OK;
}

/// Mint the accepting half of a connection the embedder's own listener
/// produced: the keyed `op:start-session` signs the listener's own
/// `transport`/`designator` — the address a partner can actually dial, and
/// the locator a give made on this host names as the exporter location. On a
/// key-designator transport (`keyed-tcp`) `direct_addresses_hint` is required
/// (TCP has no discovery; nullable/zero length is none); an address-designator
/// transport ignores it. Host-wide aliases remain lazily discoverable, with
/// the same flush and release contract as `open_dialed_locator`.
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
    slot.* = @ptrCast(session);
    return PANCAKE_OK;
}

/// Release one session: its still-parked far vows break (their FAIL
/// completions queue inside this call), the node retires it — stranded
/// withdraws fail closed, so *sibling* sessions' vows may break here
/// too — and the shell is freed. Null is a no-op; refused (last error set,
/// the session kept) from inside a callback. Once teardown commits this returns
/// success. Targeted handoff wake work remains queued across allocator pressure;
/// another cleanup failure condemns surviving sessions because retrying this
/// consumed handle would be invalid.
pub export fn pancake_host_session_release(raw: ?*PancakeHostSession) i32 {
    const session = connFrom(raw) orelse return PANCAKE_OK;
    const inst = instOf(session.host);
    inst.core.releaseSession(session) catch |err| {
        shared.setLastError("host: conn_release: {s}", .{@errorName(err)});
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };
    return PANCAKE_OK;
}

/// Nonzero once the keyed handshake has completed and the session is open.
pub export fn pancake_host_session_is_open(raw: ?*PancakeHostSession) i32 {
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
/// (borrowed for the call). The library owns framing *and the tail*: the
/// session's codec delimits each complete frame at the front of `bytes` —
/// both codecs, both frame shapes — and dispatches it exactly as
/// `pancake_host_session_feed`, while a partial frame straddling two reads
/// stays buffered in the session, so on success every byte was consumed and
/// the embedder just reads and feeds. Dispatch also pauses at the frame that
/// completes the keyed handshake: frames coalesced behind the hello wait in
/// the session's tail while the embedder acts on the fresh session (publish,
/// fetch), and the next call — an empty chunk (`len` 0, `bytes` may be NULL)
/// works — feeds them. A frame exceeding the session's frame cap is refused
/// `PANCAKE_ERR_FRAME_TOO_LARGE`; any other failure classifies as
/// `pancake_host_session_feed`'s do. After any failure the session is
/// closing: drain `take_outbound` (a typed `op:abort` is queued for the
/// partner) and release the session.
pub export fn pancake_host_session_feed_bytes(
    raw: ?*PancakeHostSession,
    bytes: ?[*]const u8,
    len: usize,
) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const chunk: []const u8 = if (len == 0) &.{} else blk: {
        const buf = bytes orelse return PANCAKE_ERR_NULL_POINTER;
        break :blk buf[0..len];
    };
    session.host.feedBytes(session, chunk) catch |err| switch (err) {
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
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const b = behavior orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_ref orelse return PANCAKE_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err| return shared.marshalErrorToCode(err);
    const inst = instOf(session.host);
    if (refuseLatched(inst)) |code| return code;
    reserveHostedCapability(inst, session, ctx, free) catch |err| return errToCode(err);
    const position = publishHosted(session, inst.allocator, name_bytes, b, ctx, free) catch |err| return errToCode(err);
    // Reservation plus the freshly spawned actor makes every fallible branch
    // of this local lift impossible after publication became observable.
    slot.* = common.hostRefToC(inst, session, .{ .near = model.NearRef.object(position) }) catch unreachable;
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
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const b = behavior orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_ref orelse return PANCAKE_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    if (refuseLatched(inst)) |code| return code;
    reserveHostedCapability(inst, session, ctx, free) catch |err| return errToCode(err);
    const position = publishHosted(session, inst.allocator, null, b, ctx, free) catch |err| return errToCode(err);
    slot.* = common.hostRefToC(inst, session, .{ .near = model.NearRef.object(position) }) catch unreachable;
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
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    const uri = shared.sliceFromC(sturdyref_uri, sturdyref_uri_len) catch |err| return shared.marshalErrorToCode(err);
    const sturdyref = model.uri.parseSturdyref(inst.allocator, uri) catch |err| return errToCode(err);
    defer model.uri.freeSturdyref(inst.allocator, sturdyref);
    slot.* = inst.core.enliven(session, sturdyref) catch |err| return errToCode(err);
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
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const target_ptr = target orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_vow orelse return PANCAKE_ERR_NULL_POINTER;
    const inst = instOf(session.host);
    const msg = msgFromC(inst, session, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    const reference = common.hostRefFromC(inst, session, target_ptr.*) catch |err| return errToCode(err);
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
    const msg = msgFromC(inst, session, verb, verb_len, args, args_len) catch |err| return errToCode(err);
    const reference = common.hostRefFromC(inst, session, target_ptr.*) catch |err| return errToCode(err);
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
    const session = inst.core.vowSession(vow) catch |err| return errToCode(err);
    const msg = msgFromC(inst, session, verb, verb_len, args, args_len) catch |err| return errToCode(err);
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

/// Pipeline an `op:get` projection against a far host vow, minting a new
/// vow for the named Struct field. Same local-vow and unknown-vow refusals as
/// `pancake_host_vow_send`; `field` is borrowed.
pub export fn pancake_host_vow_get(host: ?*PancakeHost, vow: u64, field: ?[*]const u8, field_len: usize, out_vow: ?*u64) i32 {
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
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_ref orelse return PANCAKE_ERR_NULL_POINTER;
    const name_bytes = shared.sliceFromC(name, name_len) catch |err| return shared.marshalErrorToCode(err);
    const inst = instOf(session.host);
    const position = (inst.core.publishedPosition(session, name_bytes) catch |err| return errToCode(err)) orelse {
        shared.setLastError("host: no capability published under that name", .{});
        return shared.PANCAKE_ERR_NOT_FOUND;
    };
    slot.* = common.hostRefToC(inst, session, .{ .near = model.NearRef.object(position) }) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

pub export fn pancake_host_session_break_far_vows(raw: ?*PancakeHostSession, message: ?[*]const u8, message_len: usize) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const msg = shared.sliceFromC(message, message_len) catch |err| return shared.marshalErrorToCode(err);
    session.host.breakFarVows(session, msg) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Record the exporter locator to embed in gives whose exporter is `session`,
/// overriding the session record; empty clears the override. `locator` is
/// borrowed: it must be a Syrup `<ocapn-peer …>` record (the same bytes
/// `pancake_locator_record_encode` returns). A URI or other non-record spelling
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
    const info = session.served.port.peer.lastAbort() orelse return PANCAKE_ERR_WOULD_BLOCK;
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
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const identity = session.host.partnerIdentity(session) catch |err| return errToCode(err);
    slot.* = .{
        .session_key = identity.session_key.ptr,
        .session_key_len = identity.session_key.len,
        .designator = null,
        .designator_len = 0,
        .locator_record = null,
        .locator_record_len = 0,
    };
    setView(identity.designator, &slot.designator, &slot.designator_len);
    setView(identity.locator_record, &slot.locator_record, &slot.locator_record_len);
    return PANCAKE_OK;
}

/// Nonzero when this session's partner proved it owns the designator it
/// advertised, meaning the designator is exactly its verified session key.
///
/// This is the wrapped form of `driver_core.PartnerIdentity.designatorIsSessionKey`,
/// here so no binding re-derives the canonical-hex comparison. It answers only
/// for a key-designator transport (`keyed-tcp`, `iroh`, `webrtc`,
/// `keyed-relay`); an address transport such as `tcp` names a socket address the
/// key does not determine, so the answer is zero there and zero is correct
/// rather than a failure. Returns the same refusals as
/// `pancake_host_session_partner_identity`, with `*out_matches` untouched.
pub export fn pancake_host_session_partner_designator_is_key(
    raw: ?*PancakeHostSession,
    out_matches: ?*u32,
) i32 {
    const session = connFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_matches orelse return PANCAKE_ERR_NULL_POINTER;
    const identity = session.host.partnerIdentity(session) catch |err| return errToCode(err);
    slot.* = if (identity.designatorIsSessionKey()) 1 else 0;
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
