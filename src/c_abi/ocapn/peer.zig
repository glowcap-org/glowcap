//! The `PancakePeer` driving surface: lifecycle, the opaque-frame path
//! (`feed_*` / `recv_stream` / `step` / `take_outbound` / `poll_event`), the
//! keyed `op:start-session` handshake, bootstrap/export/import registration, and
//! the typed OCapN send/poll surface that marshals structured values without a
//! codec.

const std = @import("std");

const foundation = @import("foundation");
const model = @import("model");
const engine = @import("engine");

const c = @import("mod.zig");
const abi = @import("c_abi_shared");
const ctx = @import("context.zig");
const frame = @import("frame.zig");

const PancakePeer = c.PancakePeer;
const PancakeContext = c.PancakeContext;
const PancakeFrame = c.PancakeFrame;
const PancakeManagedFrame = c.PancakeManagedFrame;
const PancakeEvent = c.PancakeEvent;
const PancakeReference = c.PancakeReference;
const PancakeArgument = c.PancakeArgument;
const PancakeDeliver = c.PancakeDeliver;
const PancakeResolve = c.PancakeResolve;
const PancakeLastAbort = c.PancakeLastAbort;

const feedErrorToCode = c.feedErrorToCode;

const PANCAKE_OK = c.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = c.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = c.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_CODEC = c.PANCAKE_ERR_CODEC;
const PANCAKE_ERR_INTERNAL = c.PANCAKE_ERR_INTERNAL;
const PANCAKE_ERR_WOULD_BLOCK = c.PANCAKE_ERR_WOULD_BLOCK;
const PANCAKE_ERR_MALFORMED = c.PANCAKE_ERR_MALFORMED;
const PANCAKE_ERR_FRAME_TOO_LARGE = c.PANCAKE_ERR_FRAME_TOO_LARGE;
const PANCAKE_ERR_WRONG_EVENT = c.PANCAKE_ERR_WRONG_EVENT;
const PANCAKE_ERR_UNSUPPORTED_VALUE = c.PANCAKE_ERR_UNSUPPORTED_VALUE;

fn peerFromOpaque(peer: ?*PancakePeer) ?*engine.Peer {
    const ptr = peer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn peerFromOpaqueConst(peer: ?*const PancakePeer) ?*const engine.Peer {
    const ptr = peer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

/// Create a peer that begins in the negotiating state and authenticates the
/// partner's `op:start-session` by default. Real OCapN sessions start here:
/// pair it with `pancake_peer_start_session`, pump the connection, and wait
/// for `pancake_peer_session_is_open` before sending application traffic.
pub export fn pancake_peer_new(out_peer: ?*?*PancakePeer) i32 {
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    return peerNewIn(ctx.library_allocator, slot, true, model.WireProfile.v1_0, .syrup);
}

/// Context-backed counterpart of `pancake_peer_new`.
pub export fn pancake_peer_new_in(context: ?*PancakeContext, out_peer: ?*?*PancakePeer) i32 {
    const c_ctx = ctx.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    return peerNewIn(c_ctx.allocator, slot, true, model.WireProfile.v1_0, .syrup);
}

/// Create a negotiating peer carrying an out-of-band negotiated profile and
/// codec: `captp_version` is a `PANCAKE_CAPTP_VERSION_*` value (`_V1_0`, or
/// `_PRE_SPEC` for the upstream OCapN prerelease profile) and `codec` is a
/// `PANCAKE_CODEC_*` value. Both ends of a connection must construct with the
/// same pair, `op:start-session` carries the profile but no codec operand, so
/// codec agreement is the caller's, the same agreement the matching `codec`
/// argument to `pancake_tcp_connect` / `pancake_tcp_accept` records.
/// `pancake_peer_start_session` signs with the profile chosen here.
pub export fn pancake_peer_new_negotiated(captp_version: u32, codec: u32, out_peer: ?*?*PancakePeer) i32 {
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    const profile = profileFromCaptpVersion(captp_version) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    const codec_id = c.codecFromC(codec) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    return peerNewIn(ctx.library_allocator, slot, true, profile, codec_id);
}

/// Context-backed counterpart of `pancake_peer_new_negotiated`.
pub export fn pancake_peer_new_negotiated_in(context: ?*PancakeContext, captp_version: u32, codec: u32, out_peer: ?*?*PancakePeer) i32 {
    const c_ctx = ctx.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    const profile = profileFromCaptpVersion(captp_version) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    const codec_id = c.codecFromC(codec) orelse return PANCAKE_ERR_INVALID_ARGUMENT;
    return peerNewIn(c_ctx.allocator, slot, true, profile, codec_id);
}

/// Create an already-open peer that skips the keyed handshake, the
/// trusted/local direct-frame constructor. It is the entry for hosts that drive
/// the engine from frames they already hold (test harnesses, in-process and
/// local-socket loops across the bindings). It is a distinct named constructor,
/// not a flag on `pancake_peer_new`, precisely because it yields an
/// *unauthenticated* peer: real OCapN connections over an untrusted transport use
/// `pancake_peer_new` and `pancake_peer_start_session` (ADR-0059).
pub export fn pancake_peer_new_raw_open(out_peer: ?*?*PancakePeer) i32 {
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    return peerNewIn(ctx.library_allocator, slot, false, model.WireProfile.v1_0, .syrup);
}

/// Context-backed counterpart of `pancake_peer_new_raw_open`.
pub export fn pancake_peer_new_raw_open_in(context: ?*PancakeContext, out_peer: ?*?*PancakePeer) i32 {
    const c_ctx = ctx.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    return peerNewIn(c_ctx.allocator, slot, false, model.WireProfile.v1_0, .syrup);
}

fn profileFromCaptpVersion(captp_version: u32) ?model.WireProfile {
    return switch (captp_version) {
        c.PANCAKE_CAPTP_VERSION_V1_0 => model.WireProfile.v1_0,
        c.PANCAKE_CAPTP_VERSION_PRE_SPEC => model.WireProfile.pre_spec,
        else => null,
    };
}

fn peerNewIn(alloc: std.mem.Allocator, slot: *?*PancakePeer, negotiating: bool, wire_profile: model.WireProfile, codec: model.CodecId) i32 {
    const peer = alloc.create(engine.Peer) catch return PANCAKE_ERR_INTERNAL;
    peer.* = if (negotiating)
        engine.Peer.initNegotiatingWith(alloc, .{ .wire_profile = wire_profile, .codec = codec })
    else
        engine.Peer.initRawOpenFixture(alloc);
    slot.* = @ptrCast(peer);
    return PANCAKE_OK;
}

/// Release a peer and everything it still owns: queued inbound frames,
/// undrained outbound frames and events, and the session tables. Frames already
/// taken out carry their own release and stay valid. Null is a no-op.
pub export fn pancake_peer_release(peer: ?*PancakePeer) void {
    const ptr = peerFromOpaque(peer) orelse return;
    // The peer holds the allocator it was created with (`pancake_peer_new` or
    // `pancake_peer_new_in`), so release routes back to the same policy.
    const alloc = ptr.allocator;
    ptr.deinit();
    alloc.destroy(ptr);
}

/// Dispatch one inbound frame whose bytes are *borrowed* for this call only. The
/// peer reads and retains nothing; the caller keeps ownership of `frame`'s bytes.
pub export fn pancake_peer_feed_borrowed(peer: ?*PancakePeer, frame_in: ?*const PancakeFrame) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const borrowed = frame_in orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = borrowed.bytes orelse return PANCAKE_ERR_NULL_POINTER;
    const shape = frame.frameShapeFromC(borrowed.shape) orelse return PANCAKE_ERR_INVALID_ARGUMENT;

    ptr.recvBorrowed(.{
        .bytes = bytes_ptr[0..borrowed.len],
        .shape = shape,
    }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Adopt an inbound managed frame, transferring ownership to the peer for queued
/// dispatch. Ownership always transfers once `peer`, `frame`, and `frame->bytes`
/// are non-null: on success or failure alike the frame is released through its
/// own callback when the library is done with it, and the caller's struct is
/// nulled out (bytes/len/release cleared) so a late
/// `pancake_managed_frame_release` is the documented no-op. Only a
/// `PANCAKE_ERR_NULL_POINTER` return leaves the caller owning the frame.
pub export fn pancake_peer_feed_owned(peer: ?*PancakePeer, frame_in: ?*PancakeManagedFrame) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const managed = frame_in orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = managed.bytes orelse return PANCAKE_ERR_NULL_POINTER;
    const storage = bytes_ptr[0..managed.len];

    const shape = frame.frameShapeFromC(managed.shape) orelse {
        frame.pancake_managed_frame_release(managed);
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    const alloc = ptr.allocator;
    const payload = alloc.create(frame.AdoptedManagedFramePayload) catch {
        frame.pancake_managed_frame_release(managed);
        return PANCAKE_ERR_INTERNAL;
    };
    payload.* = .{ .managed = managed.*, .allocator = alloc };
    // The payload owns the descriptor from here; clear the caller's copy so a
    // late release is a no-op.
    managed.bytes = null;
    managed.len = 0;
    managed.release = null;
    managed.private_data = null;

    var owned = foundation.Frame.initExternal(
        storage,
        shape,
        payload,
        frame.releaseAdoptedManagedFrame,
    ) catch {
        // `initExternal` transfers unconditionally: it already disposed the
        // storage through `releaseAdoptedManagedFrame`, which released the
        // managed frame and destroyed `payload`. The refusal names the caller's
        // fault, storage that does not satisfy the declared shape (a word
        // frame needs an 8-aligned pointer and a length divisible by 8).
        return PANCAKE_ERR_INVALID_ARGUMENT;
    };

    ptr.feedInbound(owned) catch {
        owned.deinit();
        return PANCAKE_ERR_INTERNAL;
    };
    return PANCAKE_OK;
}

/// Frame and dispatch one inbound frame from a byte-stream buffer. `bytes[0..len]`
/// is whatever has accumulated from the wire so far; this finds the next complete
/// frame in the negotiated codec, dispatches it synchronously (queuing any reply
/// or abort on the outbound queue and any application event), and writes the
/// number of leading bytes it consumed into `out_consumed` — drop those before
/// the next call, then call again to drain further buffered frames.
///
/// Returns `PANCAKE_OK` with `*out_consumed` set when one frame was consumed;
/// `PANCAKE_ERR_WOULD_BLOCK` with `*out_consumed == 0` when the buffer holds only
/// part of a frame (read more and retry with the extended buffer);
/// `PANCAKE_ERR_MALFORMED` or `PANCAKE_ERR_FRAME_TOO_LARGE` on a fatal framing
/// violation (an `op:abort` is queued and the session closes); other codes on a
/// dispatch failure. This is the sans-I/O stream-input primitive: the caller owns
/// the socket and the buffer, the peer never blocks, and it retains no borrow
/// past the call.
pub export fn pancake_peer_recv_stream(
    peer: ?*PancakePeer,
    bytes: ?[*]const u8,
    len: usize,
    out_consumed: ?*usize,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const consumed = out_consumed orelse return PANCAKE_ERR_NULL_POINTER;
    consumed.* = 0;
    // An empty buffer is semantically an incomplete frame, not a bad pointer:
    // report would-block before the null check so `(NULL, 0)` means "read more".
    if (len == 0) return PANCAKE_ERR_WOULD_BLOCK;
    const buf = bytes orelse return PANCAKE_ERR_NULL_POINTER;

    const outcome = ptr.recvStreamPrefix(buf[0..len]) catch |err| switch (err) {
        error.MalformedFrame => return PANCAKE_ERR_MALFORMED,
        error.FrameTooLarge => return PANCAKE_ERR_FRAME_TOO_LARGE,
        else => return feedErrorToCode(err),
    };
    switch (outcome) {
        .incomplete => return PANCAKE_ERR_WOULD_BLOCK,
        .consumed => |n| {
            consumed.* = n;
            return PANCAKE_OK;
        },
    }
}

/// Advance the peer: validate-and-apply queued inbound frames and encode pending
/// outbound work. No I/O, the caller drains `take_outbound` and `poll_event`
/// afterward.
pub export fn pancake_peer_step(peer: ?*PancakePeer) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    _ = ptr.step() catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Advance the peer to quiescence: `step` until both the inbound and pending
/// outbound queues are empty. A single `step` does one unit of work, so a
/// settlement that cascades — a resolve that drains a projection, whose own
/// resolve fires a listener, which queues a deliver — needs several steps to
/// fully encode; this runs them all so the caller can drain every queued frame
/// in one `take_outbound` sweep. No I/O — the caller drains `take_outbound` and
/// `poll_event` afterward, exactly as for `pancake_peer_step`.
pub export fn pancake_peer_step_to_idle(peer: ?*PancakePeer) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    while ((ptr.step() catch |err| return feedErrorToCode(err)) != .idle) {}
    return PANCAKE_OK;
}

/// Take the next outbound frame, writing an *owned* managed frame into
/// `out_frame` that the caller must `release`. Returns `PANCAKE_ERR_WOULD_BLOCK`
/// when the outbound queue is empty. On `PANCAKE_ERR_INTERNAL` the dequeued
/// frame could not be wrapped for C and was freed; it is not retrievable.
pub export fn pancake_peer_take_outbound(peer: ?*PancakePeer, out_frame: ?*PancakeManagedFrame) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;
    const out = ptr.takeOutbound() orelse return PANCAKE_ERR_WOULD_BLOCK;

    slot.* = frame.tryManagedFrame(ptr.allocator, out) catch {
        var owned = out;
        owned.deinit();
        return PANCAKE_ERR_INTERNAL;
    };
    return PANCAKE_OK;
}

/// Take the next application event, writing it into `out_event`. The event's
/// frame is the originating wire bytes in the negotiated codec (no re-encode),
/// handed over as an *owned* managed frame the caller must `release`. Returns
/// `PANCAKE_ERR_WOULD_BLOCK` when no event is pending.
pub export fn pancake_peer_poll_event(peer: ?*PancakePeer, out_event: ?*PancakeEvent) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_event orelse return PANCAKE_ERR_NULL_POINTER;
    var event = ptr.pollEvent() orelse return PANCAKE_ERR_WOULD_BLOCK;

    // Hand back the originating frame bytes in the session's negotiated codec.
    // The frame moves into the managed payload; no decode and no re-encode.
    slot.* = .{
        .kind = frame.eventKindToC(event.kind()),
        .frame = frame.tryManagedFrame(ptr.allocator, event.frame) catch {
            event.deinit();
            return PANCAKE_ERR_INTERNAL;
        },
    };
    return PANCAKE_OK;
}

/// Sign and queue a keyed `op:start-session` for a negotiating peer. Derives the
/// session key from the 32-byte `seed`, signs the canonical `<my-location …>`
/// bytes for the `(transport, designator)` locator, and enqueues the handshake
/// frame; flush it with `pancake_peer_step` + `pancake_peer_take_outbound`. The
/// signed locator is what the partner verifies, so the designator and transport
/// must be the ones it expects, for a Goblins partner, transport `"tcp"` with
/// `hints` set to `PANCAKE_HINTS_EMPTY_FALSE` (Goblins emits the boolean-false
/// spelling of an empty hints map and re-encodes what it checks).
/// `hints` selects the wire spelling of the locator's empty hints:
/// `PANCAKE_HINTS_EMPTY_MAP` encodes `{}`, `PANCAKE_HINTS_EMPTY_FALSE` encodes
/// `#f`; any other value is refused with `PANCAKE_ERR_INVALID_ARGUMENT`.
/// The handshake speaks the profile the peer was constructed with
/// (`pancake_peer_new` is v1.0, `pancake_peer_new_negotiated` chooses); the
/// peer already knows it, so this call never re-takes it. The seed is the only
/// place key material crosses the boundary; the library never generates
/// entropy. `seed` is borrowed and `seed_len` must be 32; anything else is
/// refused with `PANCAKE_ERR_INVALID_ARGUMENT`.
pub export fn pancake_peer_start_session(
    peer: ?*PancakePeer,
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    hints: u32,
    seed: ?[*]const u8,
    seed_len: usize,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const transport_ptr = transport orelse return PANCAKE_ERR_NULL_POINTER;
    const designator_ptr = designator orelse return PANCAKE_ERR_NULL_POINTER;
    const seed_ptr = seed orelse return PANCAKE_ERR_NULL_POINTER;
    if (seed_len != foundation.crypto.SEED_BYTES) return PANCAKE_ERR_INVALID_ARGUMENT;

    // The peer's session already carries the negotiated profile; signing the
    // handshake with anything else would be a mismatch foot-gun, so the version
    // is read here rather than taken as a parameter.
    const version: model.CaptpVersion = ptr.session_state.wire_profile.captp_version;

    const hint_form: model.Hints = switch (hints) {
        c.PANCAKE_HINTS_EMPTY_MAP => model.Hints.emptyMap(),
        c.PANCAKE_HINTS_EMPTY_FALSE => model.Hints.emptyFalse(),
        else => return PANCAKE_ERR_INVALID_ARGUMENT,
    };

    const seed_bytes: [foundation.crypto.SEED_BYTES]u8 = seed_ptr[0..foundation.crypto.SEED_BYTES].*;
    const secret = foundation.crypto.SecretKey.fromSeed(seed_bytes);

    const locator: model.PeerLocator = .{
        .transport = transport_ptr[0..transport_len],
        .designator = designator_ptr[0..designator_len],
        .hints = hint_form,
    };

    ptr.sendKeyedStartSession(version, locator, secret) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Whether the peer's session has completed the `op:start-session` handshake and
/// is open for traffic. Returns 1 when open and 0 when not; a NULL peer has no
/// open session, so it reports 0. Never negative, so `if (...is_open(peer))`
/// reads correctly in C. Pump the connection and poll this after a keyed
/// start-session before sending application messages.
pub export fn pancake_peer_session_is_open(peer: ?*PancakePeer) i32 {
    const ptr = peerFromOpaque(peer) orelse return 0;
    return if (ptr.sessionIsOpen()) 1 else 0;
}

/// The codec the peer's session speaks, written into `out_codec` as a
/// `PANCAKE_CODEC_*` value. Event frames and `take_outbound` frames are encoded
/// in this codec, so a consumer that falls back to the opaque
/// `pancake_peer_poll_event` (e.g. after a typed poll refused a value the C
/// surface cannot carry) knows how to interpret the raw frame bytes.
pub export fn pancake_peer_codec(peer: ?*const PancakePeer, out_codec: ?*u32) i32 {
    const ptr = peerFromOpaqueConst(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_codec orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = switch (ptr.session_state.codec) {
        .syrup => c.PANCAKE_CODEC_SYRUP,
        .capnp => c.PANCAKE_CODEC_CAPNP,
        // `CodecId` is non-exhaustive for forward compatibility; a session can
        // only ever carry one of the two named codecs.
        _ => return PANCAKE_ERR_INTERNAL,
    };
    return PANCAKE_OK;
}

// ── Bootstrap registration ───────────────────────────────────────────────────

/// Expose a local capability behind `swissnum` for inbound bootstrap-fetch
/// (ADR-0006 responder half). Writes the allocated export position into
/// `out_export_position`. The swissnum bytes are borrowed for the call.
pub export fn pancake_peer_register_bootstrap_cap(
    peer: ?*PancakePeer,
    swissnum: ?[*]const u8,
    swissnum_len: usize,
    out_export_position: ?*u64,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_export_position orelse return PANCAKE_ERR_NULL_POINTER;
    const swiss_ptr = swissnum orelse return PANCAKE_ERR_NULL_POINTER;
    const export_position = ptr.registerBootstrapCap(swiss_ptr[0..swissnum_len]) catch |err|
        return feedErrorToCode(err);
    slot.* = export_position;
    return PANCAKE_OK;
}

/// Ask the partner's bootstrap object for the capability published behind
/// `name` (ADR-0006 requester half): registers the well-known bootstrap import
/// if needed, allocates the answer from the session's one answer allocator, and
/// queues the canonical `fetch` deliver. The question id is written into
/// `out_answer`; the partner's resolution arrives as a
/// `PANCAKE_EVENT_RESOLVE` keyed on it. `name` is borrowed for the call. Flush
/// with `pancake_peer_step` + `pancake_peer_take_outbound`.
pub export fn pancake_peer_send_bootstrap_fetch(
    peer: ?*PancakePeer,
    name: ?[*]const u8,
    name_len: usize,
    out_answer: ?*u64,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_answer orelse return PANCAKE_ERR_NULL_POINTER;
    const name_bytes = sliceFromC(name, name_len) catch |err| return marshalErrorToCode(err);

    ptr.importObject(engine.BOOTSTRAP_POSITION) catch |err| return feedErrorToCode(err);
    // The one definition of the bootstrap-fetch deliver shape lives in the
    // engine; this surface only routes it.
    const prepared = engine.fetch.prepareFetchSwissnum(ptr.allocator, &ptr.session_state, name_bytes) catch |err|
        return feedErrorToCode(err);
    if (prepared.message.deliver.resolve_me_desc != null) {
        // On a V1.0 session the prepared deliver advertises its own resolver
        // export; commit the answer-to-resolver link the engine's encode-time
        // synthesis would have installed, so the partner's resolver-callback
        // deliver projects back as a resolve event keyed on `out_answer`.
        ptr.session_state.installOutboundResolver(prepared.answer_position, prepared.resolver_export) catch |err| {
            model.freeMessage(ptr.allocator, prepared.message);
            return feedErrorToCode(err);
        };
    }
    ptr.send(prepared.message) catch |err| return feedErrorToCode(err);
    slot.* = prepared.answer_position.int();
    return PANCAKE_OK;
}

/// Begin enlivening the sturdyref published behind `swissnum` (ADR-0012): the
/// requester-side seam over bootstrap-fetch with the dedup cache threaded in.
/// `swissnum` is borrowed for the call; the result is written into `out`. On a
/// `PANCAKE_ENLIVEN_FRESH` status this queues the bootstrap-fetch deliver
/// (flush with `pancake_peer_step` + `pancake_peer_take_outbound`); the
/// resolution arrives as a `PANCAKE_EVENT_RESOLVE` keyed on `out.answer`, after
/// which the caller calls `pancake_peer_record_enlivenment` to cache it. A
/// `PANCAKE_ENLIVEN_CACHED` status short-circuits with no wire traffic; a
/// `PANCAKE_ENLIVEN_IN_FLIGHT` status names an enliven already outstanding on
/// `out.answer`. Requires the session to have negotiated the sturdyref feature
/// and be open, or it reports `PANCAKE_ERR_SESSION`.
pub export fn pancake_peer_prepare_enliven(
    peer: ?*PancakePeer,
    swissnum: ?[*]const u8,
    swissnum_len: usize,
    out: ?*c.PancakeEnlivenStart,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const swiss = sliceFromC(swissnum, swissnum_len) catch |err| return marshalErrorToCode(err);

    // Enliven addresses the partner's bootstrap object; track the well-known
    // import exactly as the bootstrap-fetch surface does before a fresh fetch.
    ptr.importObject(engine.BOOTSTRAP_POSITION) catch |err| return feedErrorToCode(err);
    // The core tracks no remote locator and never dials; the peer fields carry
    // no authority for enliven, so the swissnum alone identifies the cache row.
    const sturdy = model.SturdyRef{
        .peer = .{ .transport = "", .designator = "" },
        .swissnum = swiss,
    };
    const start = engine.sturdyref.prepareEnliven(ptr.allocator, &ptr.session_state, sturdy) catch |err|
        return feedErrorToCode(err);
    switch (start) {
        .cached => |reference| slot.* = .{
            .status = c.PANCAKE_ENLIVEN_CACHED,
            .kind = if (reference.far.kind == .promise) c.PANCAKE_REF_SUB_PROMISE else c.PANCAKE_REF_SUB_OBJECT,
            .answer = 0,
            .import_position = reference.far.import_position.int(),
        },
        .in_flight => |answer| slot.* = .{
            .status = c.PANCAKE_ENLIVEN_IN_FLIGHT,
            .kind = 0,
            .answer = answer.int(),
            .import_position = 0,
        },
        .fresh => |prepared| {
            if (prepared.message.deliver.resolve_me_desc != null) {
                // V1.0: commit the answer-to-resolver link the engine's
                // encode-time synthesis would install, so the partner's
                // resolver-callback projects back as a resolve keyed on `answer`.
                ptr.session_state.installOutboundResolver(prepared.answer_position, prepared.resolver_export) catch |err| {
                    model.freeMessage(ptr.allocator, prepared.message);
                    ptr.session_state.finishPendingEnliven(swiss);
                    return feedErrorToCode(err);
                };
            }
            ptr.send(prepared.message) catch |err| {
                ptr.session_state.finishPendingEnliven(swiss);
                return feedErrorToCode(err);
            };
            slot.* = .{
                .status = c.PANCAKE_ENLIVEN_FRESH,
                .kind = 0,
                .answer = prepared.answer_position.int(),
                .import_position = 0,
            };
        },
    }
    return PANCAKE_OK;
}

/// Settle a `PANCAKE_ENLIVEN_FRESH` enliven once its bootstrap-fetch resolution
/// arrives (ADR-0012 dedup cache): on `PANCAKE_ENLIVEN_OUTCOME_FULFILLED` the
/// resolved far reference (`import_position` + `kind`, a `PANCAKE_REF_SUB_*`
/// value read from the resolve event) is cached under `swissnum` so a repeat
/// enliven short-circuits; on `PANCAKE_ENLIVEN_OUTCOME_BROKEN` the in-flight
/// marker is cleared and nothing is cached. `swissnum` is borrowed for the call.
pub export fn pancake_peer_record_enlivenment(
    peer: ?*PancakePeer,
    swissnum: ?[*]const u8,
    swissnum_len: usize,
    outcome: u32,
    import_position: u64,
    kind: u32,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const swiss = sliceFromC(swissnum, swissnum_len) catch |err| return marshalErrorToCode(err);
    switch (outcome) {
        c.PANCAKE_ENLIVEN_OUTCOME_FULFILLED => {
            const ref_kind: model.RefKind = if (kind == c.PANCAKE_REF_SUB_PROMISE) .promise else .object;
            // The far is POD; `recordEnlivenment` caches it and clears the
            // marker. It only errors on a non-far/broken outcome, which a
            // `.far` fulfillment never is.
            _ = engine.sturdyref.recordEnlivenment(ptr.allocator, &ptr.session_state, swiss, .{
                .fulfilled = .{ .far = .{ .import_position = model.ImportId.from(import_position), .kind = ref_kind } },
            }) catch |err| return feedErrorToCode(err);
        },
        c.PANCAKE_ENLIVEN_OUTCOME_BROKEN => ptr.session_state.finishPendingEnliven(swiss),
        else => return PANCAKE_ERR_INVALID_ARGUMENT,
    }
    return PANCAKE_OK;
}

/// Read the typed cause of the peer's most recent local dispatch failure into
/// `out`, the ABI counterpart of `engine.Peer.lastAbort`. Returns `PANCAKE_OK`
/// when a failure has been recorded, or `PANCAKE_ERR_WOULD_BLOCK` when none has.
/// The string views written into `out` are process-static; the caller reads
/// them and never frees them. The flat per-feed return code names the failure
/// family; this names the member (codec-vs-session domain, the abort kind).
pub export fn pancake_peer_last_abort(peer: ?*PancakePeer, out: ?*PancakeLastAbort) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const info = ptr.lastAbort() orelse return PANCAKE_ERR_WOULD_BLOCK;
    slot.* = .{
        .domain = switch (info.domain) {
            .codec => c.PANCAKE_ABORT_DOMAIN_CODEC,
            .session => c.PANCAKE_ABORT_DOMAIN_SESSION,
            .foreign => c.PANCAKE_ABORT_DOMAIN_FOREIGN,
        },
        .has_kind = if (info.kind != null) 1 else 0,
        .kind_name = if (info.kind) |k| k.wireName().ptr else null,
        .kind_name_len = if (info.kind) |k| k.wireName().len else 0,
        .message = info.message.ptr,
        .message_len = info.message.len,
        .error_name = info.error_name.ptr,
        .error_name_len = info.error_name.len,
    };
    return PANCAKE_OK;
}

/// Register a local export position so inbound deliveries targeting it surface as
/// events. The bare-position sibling of `register_bootstrap_cap` (no swissnum).
pub export fn pancake_peer_register_export(peer: ?*PancakePeer, export_position: u64) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    ptr.session_state.registerExport(model.ExportId.from(export_position)) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Allocate the next free export position from the session's one export
/// allocator and *register* it (unlike `pancake_peer_next_answer`, which only
/// allocates), writing the position into `out_export_position`. A binding's
/// `spawn` must take its position here: the same counter mints bootstrap and
/// resolver exports, so a privately-counted position would eventually alias one
/// of them.
pub export fn pancake_peer_next_export(peer: ?*PancakePeer, out_export_position: ?*u64) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_export_position orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = ptr.exportNextObject() catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Allocate the next outbound answer position — the question id for a
/// `send_deliver` that wants a reply — from the session's one answer allocator,
/// writing it into `out_answer`. A binding's eventual-send must take its answer
/// here: the same counter backs every outbound question on the session, so a
/// privately-counted position would eventually alias a live answer and route
/// the partner's `op:resolve` to the wrong caller.
pub export fn pancake_peer_next_answer(peer: ?*PancakePeer, out_answer: ?*u64) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_answer orelse return PANCAKE_ERR_NULL_POINTER;
    slot.* = ptr.allocateAnswer();
    return PANCAKE_OK;
}

/// Track a partner-hosted import position this peer holds, so a typed
/// `send_deliver` to it as a `_FAR` reference is admitted. Partner-allocated
/// imports normally arrive through a resolution; this names a known one (e.g. the
/// bootstrap import) directly.
pub export fn pancake_peer_register_import(peer: ?*PancakePeer, import_position: u64) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    ptr.session_state.registerImport(model.ImportId.from(import_position)) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

// ── Typed OCapN driving surface ──────────────────────────────────────────────
//
// The opaque-frame path (`feed_*` / `take_outbound` / `poll_event`) shuttles wire
// bytes. This surface lets a C consumer *drive* OCapN: construct a call and read
// a delivery as structured values, without authoring or parsing a codec itself.
//
// Send marshals caller-owned C structs into a `model` message and routes through
// `Peer.sendCopying`, the named boundary copy that owns the clone, so the C bytes
// are borrowed only for the call. Receive materializes the event once into a
// per-event arena and projects C views whose byte pointers alias that arena;
// release with the matching `*_release`. The struct layouts are frozen ABI
// (ADR-0031).

const zero_reference = abi.zero_reference;
const zero_argument = abi.zero_argument;
const zero_handoff_give: c.PancakeHandoffGive = .{
    .give = null,
    .give_len = 0,
    .exporter_locator = null,
    .exporter_locator_len = 0,
    .recipient_key = null,
    .recipient_key_len = 0,
};
const marshalErrorToCode = abi.marshalErrorToCode;
const sliceFromC = abi.sliceFromC;
const referenceFromC = abi.referenceFromC;
const argumentFromC = abi.argumentFromC;
const argsFromC = abi.argsFromC;
const referenceToC = abi.referenceToC;
const argumentToC = abi.argumentToC;
const argsToC = abi.argsToC;
const newProjectionArena = abi.newProjectionArena;
const freeProjectionArena = abi.freeProjectionArena;

/// The kind of the next queued event without consuming it: a positive
/// `PANCAKE_EVENT_*`, or `PANCAKE_ERR_WOULD_BLOCK` when the queue is empty. Route
/// to the matching typed `poll_event_*`.
pub export fn pancake_peer_peek_event(peer: ?*PancakePeer) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const kind = ptr.peekEventKind() orelse return PANCAKE_ERR_WOULD_BLOCK;
    return @intCast(frame.eventKindToC(kind));
}

/// Construct and queue an `op:deliver` to `target` carrying `args`. When
/// `has_answer` is nonzero the call expects a reply on `answer`. The C structs
/// are borrowed for the call (the clone owns the copy). `pancake_peer_step`
/// encodes it; drain with `pancake_peer_take_outbound`.
///
/// This surface does not expose `resolve_me_desc`; for V1.0 sessions, the engine
/// synthesizes the resolver-callback descriptor for answered delivers.
pub export fn pancake_peer_send_deliver(
    peer: ?*PancakePeer,
    target: ?*const PancakeReference,
    args: ?[*]const PancakeArgument,
    args_len: usize,
    has_answer: u32,
    answer: u64,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const tref = target orelse return PANCAKE_ERR_NULL_POINTER;

    var arena = std.heap.ArenaAllocator.init(ptr.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const model_target = referenceFromC(tref.*) catch |err| return marshalErrorToCode(err);
    const model_args = argsFromC(a, args, args_len, 0) catch |err| return marshalErrorToCode(err);
    ptr.sendCopying(.{ .deliver = .{
        .target = model_target,
        .args = model_args,
        .answer = if (has_answer != 0) model.AnswerId.from(answer) else null,
    } }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Construct and queue an `op:resolve` settling `answer`. `resolution_kind`
/// selects a `_FULFILL` value (`fulfill`) or a `_BREAK` reason (`break_message`).
pub export fn pancake_peer_send_resolve(
    peer: ?*PancakePeer,
    answer: u64,
    resolution_kind: u32,
    fulfill: ?*const PancakeArgument,
    break_message: ?[*]const u8,
    break_message_len: usize,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;

    var arena = std.heap.ArenaAllocator.init(ptr.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const resolution: model.Resolution = switch (resolution_kind) {
        c.PANCAKE_RESOLUTION_FULFILL => blk: {
            const f = fulfill orelse return PANCAKE_ERR_NULL_POINTER;
            break :blk .{ .fulfill = argumentFromC(a, f.*, 0) catch |err| return marshalErrorToCode(err) };
        },
        c.PANCAKE_RESOLUTION_BREAK => .{ .@"break" = .{
            .message = sliceFromC(break_message, break_message_len) catch |err| return marshalErrorToCode(err),
        } },
        else => return PANCAKE_ERR_INVALID_ARGUMENT,
    };
    ptr.sendCopying(.{ .resolve = .{ .answer = model.AnswerId.from(answer), .resolution = resolution } }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Queue an `op:get` projection (ADR-0050): export a fresh promise at `answer`
/// that resolves to the `field` member of whatever `receiver` resolves to.
/// `receiver` is typically a `_PROMISE` — the answer position a prior
/// `send_deliver` returned — so the projection pipelines ahead of that answer
/// settling; a `_FAR` receiver projects an already-settled capability. The
/// partner's settlement arrives as a `PANCAKE_EVENT_RESOLVE` keyed on `answer`.
/// Allocate `answer` with `pancake_peer_next_answer`; `field` is borrowed for
/// the call. `pancake_peer_step` encodes it.
pub export fn pancake_peer_send_get(
    peer: ?*PancakePeer,
    receiver: ?*const PancakeReference,
    field: ?[*]const u8,
    field_len: usize,
    answer: u64,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const rref = receiver orelse return PANCAKE_ERR_NULL_POINTER;
    const model_receiver = referenceFromC(rref.*) catch |err| return marshalErrorToCode(err);
    const field_bytes = sliceFromC(field, field_len) catch |err| return marshalErrorToCode(err);
    ptr.sendCopying(.{ .get = .{
        .receiver = model_receiver,
        .field = field_bytes,
        .answer = model.AnswerId.from(answer),
    } }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Queue an `op:index` projection (ADR-0050): export a fresh promise at `answer`
/// that resolves to element `index` of whatever `receiver` resolves to. Like
/// `pancake_peer_send_get` but for a List position rather than a Struct field.
/// Allocate `answer` with `pancake_peer_next_answer`. `pancake_peer_step`
/// encodes it.
pub export fn pancake_peer_send_index(
    peer: ?*PancakePeer,
    receiver: ?*const PancakeReference,
    index: i64,
    answer: u64,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const rref = receiver orelse return PANCAKE_ERR_NULL_POINTER;
    const model_receiver = referenceFromC(rref.*) catch |err| return marshalErrorToCode(err);
    ptr.sendCopying(.{ .index = .{
        .receiver = model_receiver,
        .index = index,
        .answer = model.AnswerId.from(answer),
    } }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Queue an `op:untag` projection (ADR-0052): export a fresh promise at `answer`
/// that resolves to the payload of whatever `receiver` resolves to, requiring it
/// to be a Tagged record whose tag equals `tag` (the projection breaks on a
/// mismatched tag or wrong-shape value). Allocate `answer` with
/// `pancake_peer_next_answer`; `tag` is borrowed for the call. `pancake_peer_step`
/// encodes it.
pub export fn pancake_peer_send_untag(
    peer: ?*PancakePeer,
    receiver: ?*const PancakeReference,
    tag: ?[*]const u8,
    tag_len: usize,
    answer: u64,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const rref = receiver orelse return PANCAKE_ERR_NULL_POINTER;
    const model_receiver = referenceFromC(rref.*) catch |err| return marshalErrorToCode(err);
    const tag_bytes = sliceFromC(tag, tag_len) catch |err| return marshalErrorToCode(err);
    ptr.sendCopying(.{ .untag = .{
        .receiver = model_receiver,
        .tag = tag_bytes,
        .answer = model.AnswerId.from(answer),
    } }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Construct and queue an `op:gc-export` releasing wire-delta counts on the
/// partner's exports this peer imported (ADR-0008): `positions[i]` is released
/// by `deltas[i]`, for `len` parallel entries. Both arrays are borrowed for the
/// call; `len == 0` is refused with `PANCAKE_ERR_INVALID_ARGUMENT` (an empty
/// release is a caller bug, not a message). `pancake_peer_step` encodes it.
pub export fn pancake_peer_send_gc_export(
    peer: ?*PancakePeer,
    positions: ?[*]const u64,
    deltas: ?[*]const u64,
    len: usize,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    if (len == 0) return PANCAKE_ERR_INVALID_ARGUMENT;
    const positions_ptr = positions orelse return PANCAKE_ERR_NULL_POINTER;
    const deltas_ptr = deltas orelse return PANCAKE_ERR_NULL_POINTER;
    ptr.sendCopying(.{ .gc_export = .{
        .positions = positions_ptr[0..len],
        .deltas = deltas_ptr[0..len],
    } }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Construct and queue an `op:gc-answer` releasing the answer position `answer`
/// this peer no longer needs (ADR-0008). `pancake_peer_step` encodes it.
pub export fn pancake_peer_send_gc_answer(peer: ?*PancakePeer, answer: u64) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const positions = [_]u64{answer};
    ptr.sendCopying(.{ .gc_answer = .{ .positions = positions[0..] } }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Recipient half of a three-party handoff (ADR-0009/ADR-0056): build a signed
/// `desc:handoff-receive` embedding the verbatim `give` bytes the recipient was
/// handed, and queue a `withdraw-gift` `op:deliver` to the exporter's bootstrap
/// object (far object 0) under answer position `answer`. `pancake_peer_step`
/// encodes it; the withdrawn reference arrives as a `PANCAKE_EVENT_RESOLVE` keyed
/// on `answer`.
///
/// The caller must already hold an open keyed session to the exporter named by
/// the give's `exporter-location`, opened with the same 32-byte `seed` the gift
/// was deposited under — that session key is what the exporter verifies the
/// receive against, so the receive's session and side names are derived from it
/// and the session must be open (`PANCAKE_ERR_SESSION` otherwise). `give` is the
/// verbatim signed `desc:handoff-give` bytes. The monotonic `handoff-count` the
/// exporter requires to increase is minted internally by the peer's gift
/// registry — 0 for the first withdrawal from a given exporter session, rising
/// across reconnects when a shared registry is wired — so the caller never
/// tracks it. `give` and `seed` are borrowed for the call; `seed_len` must be 32.
pub export fn pancake_peer_send_withdraw_gift(
    peer: ?*PancakePeer,
    give: ?[*]const u8,
    give_len: usize,
    seed: ?[*]const u8,
    seed_len: usize,
    answer: u64,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const give_ptr = give orelse return PANCAKE_ERR_NULL_POINTER;
    const seed_ptr = seed orelse return PANCAKE_ERR_NULL_POINTER;
    if (give_len == 0) return PANCAKE_ERR_INVALID_ARGUMENT;
    if (seed_len != foundation.crypto.SEED_BYTES) return PANCAKE_ERR_INVALID_ARGUMENT;

    const seed_bytes: [foundation.crypto.SEED_BYTES]u8 = seed_ptr[0..foundation.crypto.SEED_BYTES].*;
    const secret = foundation.crypto.SecretKey.fromSeed(seed_bytes);

    // `Peer.sendWithdrawGift` owns the withdraw shape — sign the receive (the
    // exporter session must be open, since its key names the receive's session),
    // mint the monotonic `handoff_count` from the vat-scoped gift registry, and
    // queue the `withdraw-gift` deliver — so `engine.Node` and this C export
    // drive one definition rather than each hand-rolling the deliver.
    ptr.sendWithdrawGift(secret, give_ptr[0..give_len], model.AnswerId.from(answer)) catch |err| switch (err) {
        error.NoExporterKey => return c.PANCAKE_ERR_SESSION,
        error.MalformedKey => return PANCAKE_ERR_INVALID_ARGUMENT,
        else => return feedErrorToCode(err),
    };
    return PANCAKE_OK;
}

// ── Gifter (introducer) half of three-party handoff (ADR-0009) ───────────────
//
// The recipient primitives above redeem a give; these author one. A gifter holds
// a reference whose home is the exporter (a different session) and, asked to pass
// it on, deposits the gift with the exporter and returns the recipient a signed
// `desc:handoff-give`. The give's crypto inputs come from the gifter's two
// sessions — the recipient key from the to-recipient session, the exporter
// locator and key from the to-exporter session — surfaced by the accessors below.

/// Borrow the partner's session public key learned from its `op:start-session`
/// into `out_ptr`/`out_len` (a NULL pointer and zero length before the handshake
/// half arrives). A gifter reads it on the to-recipient session for the give's
/// recipient key, and on the to-exporter session to derive the gifter↔exporter
/// session name. The view aliases the session and is valid until the peer is
/// released.
pub export fn pancake_peer_partner_session_key(peer: ?*PancakePeer, out_ptr: ?*?[*]const u8, out_len: ?*usize) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const p = out_ptr orelse return PANCAKE_ERR_NULL_POINTER;
    const l = out_len orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes = ptr.session_state.partnerSessionKey() orelse "";
    p.* = if (bytes.len == 0) null else bytes.ptr;
    l.* = bytes.len;
    return PANCAKE_OK;
}

/// Borrow the partner's verbatim `<ocapn-peer …>` location-record bytes from its
/// `op:start-session` into `out_ptr`/`out_len` (a NULL pointer and zero length
/// when none were captured). A gifter embeds these as the give's exporter
/// location so a peer comparing locations matches byte-for-byte. The view aliases
/// the session and is valid until the peer is released.
pub export fn pancake_peer_partner_locator_raw(peer: ?*PancakePeer, out_ptr: ?*?[*]const u8, out_len: ?*usize) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const p = out_ptr orelse return PANCAKE_ERR_NULL_POINTER;
    const l = out_len orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes = ptr.session_state.partnerLocatorRaw() orelse "";
    p.* = if (bytes.len == 0) null else bytes.ptr;
    l.* = bytes.len;
    return PANCAKE_OK;
}

/// Build the signed `desc:handoff-give` a gifter returns to a recipient, writing
/// owned bytes into `out_give`/`out_give_len` (release with
/// `pancake_handoff_give_bytes_release`). `seed` is the gifter's 32-byte identity
/// seed (the key it presents on the to-exporter session, which signs the give and
/// must equal the deposit's provenance). `recipient_key` is the recipient's
/// session public key; `exporter_locator_raw` the exporter's verbatim location
/// bytes; `exporter_session_key` the exporter's session public key; `gift_id` the
/// deposited gift's id. The gifter's side and the gifter↔exporter session name
/// are derived from the keys. All inputs are borrowed; `seed_len` must be 32.
pub export fn pancake_build_handoff_give(
    seed: ?[*]const u8,
    seed_len: usize,
    recipient_key: ?[*]const u8,
    recipient_key_len: usize,
    exporter_locator_raw: ?[*]const u8,
    exporter_locator_raw_len: usize,
    exporter_session_key: ?[*]const u8,
    exporter_session_key_len: usize,
    gift_id: ?[*]const u8,
    gift_id_len: usize,
    out_give: ?*?[*]u8,
    out_give_len: ?*usize,
) i32 {
    const seed_ptr = seed orelse return PANCAKE_ERR_NULL_POINTER;
    const give_slot = out_give orelse return PANCAKE_ERR_NULL_POINTER;
    const give_len_slot = out_give_len orelse return PANCAKE_ERR_NULL_POINTER;
    if (seed_len != foundation.crypto.SEED_BYTES) return PANCAKE_ERR_INVALID_ARGUMENT;

    const recipient = sliceFromC(recipient_key, recipient_key_len) catch |err| return marshalErrorToCode(err);
    const exporter_loc = sliceFromC(exporter_locator_raw, exporter_locator_raw_len) catch |err| return marshalErrorToCode(err);
    const exporter_key = sliceFromC(exporter_session_key, exporter_session_key_len) catch |err| return marshalErrorToCode(err);
    const gift = sliceFromC(gift_id, gift_id_len) catch |err| return marshalErrorToCode(err);

    const seed_bytes: [foundation.crypto.SEED_BYTES]u8 = seed_ptr[0..foundation.crypto.SEED_BYTES].*;
    const secret = foundation.crypto.SecretKey.fromSeed(seed_bytes);
    const our_pubkey = secret.publicKey();

    const gifter_side = engine.handoff_gifter.sideName(our_pubkey.asBytes()) catch return PANCAKE_ERR_INVALID_ARGUMENT;
    const exporter_side = engine.handoff_gifter.sideName(exporter_key) catch return PANCAKE_ERR_INVALID_ARGUMENT;
    const session = engine.handoff_gifter.sessionName(gifter_side, exporter_side);

    const give_bytes = engine.handoff_gifter.buildSignedGive(
        ctx.library_allocator,
        secret,
        recipient,
        exporter_loc,
        &session,
        &gifter_side,
        gift,
    ) catch |err| switch (err) {
        error.OutOfMemory => return PANCAKE_ERR_INTERNAL,
        else => return PANCAKE_ERR_CODEC,
    };
    give_slot.* = give_bytes.ptr;
    give_len_slot.* = give_bytes.len;
    return PANCAKE_OK;
}

/// Release give bytes returned by `pancake_build_handoff_give`. NULL is a no-op.
pub export fn pancake_handoff_give_bytes_release(give: ?[*]u8, give_len: usize) void {
    const ptr = give orelse return;
    ctx.library_allocator.free(ptr[0..give_len]);
}

/// Build the verbatim exporter location-record bytes a give names, writing owned
/// bytes into `out`/`out_len` (release with `pancake_peer_locator_bytes_release`)
/// — the construct-it-yourself counterpart of `pancake_peer_partner_locator_raw`,
/// for an exporter whose own session record carries no dial hint.
/// `transport`/`designator` name the exporter; `direct_addresses`, when
/// non-empty, adds the exporter's comma-separated socket addresses as a
/// `direct-addresses` hint, so a cross-process recipient dials the exporter
/// directly with no discovery service (an iroh exporter reachable only by
/// address). A NULL or empty `direct_addresses` yields a hint-less location
/// identical to the exporter's own session record, so a discovery-reachable or
/// TCP exporter keeps using `partner_locator_raw` instead. The bytes are encoded
/// in the handoff codec (Syrup, as `desc:handoff-give` is — see
/// `handoff_gifter.buildSignedGive`); the result feeds
/// `pancake_build_handoff_give` as `exporter_locator_raw`. All inputs are
/// borrowed.
pub export fn pancake_encode_peer_locator(
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    direct_addresses: ?[*]const u8,
    direct_addresses_len: usize,
    out: ?*?[*]u8,
    out_len: ?*usize,
) i32 {
    const out_slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const out_len_slot = out_len orelse return PANCAKE_ERR_NULL_POINTER;
    const transport_slice = sliceFromC(transport, transport_len) catch |err| return marshalErrorToCode(err);
    const designator_slice = sliceFromC(designator, designator_len) catch |err| return marshalErrorToCode(err);

    var entries_buf: [1]model.HintEntry = undefined;
    var hints: model.Hints = model.Hints.emptyFalse();
    if (direct_addresses) |addrs_ptr| {
        if (direct_addresses_len != 0) {
            entries_buf[0] = .{ .name = "direct-addresses", .value = .{ .string = addrs_ptr[0..direct_addresses_len] } };
            hints = .{ .entries = entries_buf[0..1], .wire_form = .map };
        }
    }

    const bytes = engine.encodePeerLocatorRecord(ctx.library_allocator, .{
        .transport = transport_slice,
        .designator = designator_slice,
        .hints = hints,
    }) catch |err| switch (err) {
        error.OutOfMemory => return PANCAKE_ERR_INTERNAL,
        else => return PANCAKE_ERR_CODEC,
    };
    out_slot.* = bytes.ptr;
    out_len_slot.* = bytes.len;
    return PANCAKE_OK;
}

/// Release locator bytes returned by `pancake_encode_peer_locator`. NULL is a
/// no-op.
pub export fn pancake_peer_locator_bytes_release(locator: ?[*]u8, locator_len: usize) void {
    const ptr = locator orelse return;
    ctx.library_allocator.free(ptr[0..locator_len]);
}

/// Deposit a gift with this (exporter) session: queue a `deposit-gift`
/// `op:deliver` to the exporter's bootstrap object (far object 0) carrying the
/// gift id and the gifted reference. Fire-and-forget (no answer): the exporter
/// records the gift, and parks any `withdraw-gift` that arrives first until this
/// deposit lands. `gift_id` is borrowed; `gifted_ref` is borrowed and cloned by
/// the send. `pancake_peer_step` encodes it.
pub export fn pancake_peer_send_deposit_gift(
    peer: ?*PancakePeer,
    gift_id: ?[*]const u8,
    gift_id_len: usize,
    gifted_ref: ?*const PancakeReference,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const gref = gifted_ref orelse return PANCAKE_ERR_NULL_POINTER;
    const gift = sliceFromC(gift_id, gift_id_len) catch |err| return marshalErrorToCode(err);
    const model_gifted = referenceFromC(gref.*) catch |err| return marshalErrorToCode(err);
    ptr.sendDepositGift(gift, model_gifted) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Resolve `answer` (a question the recipient asked this gifter) with a signed
/// `desc:handoff-give`: queue an `op:resolve` whose fulfill carries `give`
/// verbatim, so the encoder emits the exact bytes the gifter signed and the
/// recipient redeems them transparently. `give` is borrowed for the call.
pub export fn pancake_peer_send_resolve_handoff_give(
    peer: ?*PancakePeer,
    answer: u64,
    give: ?[*]const u8,
    give_len: usize,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const give_ptr = give orelse return PANCAKE_ERR_NULL_POINTER;
    if (give_len == 0) return PANCAKE_ERR_INVALID_ARGUMENT;

    ptr.sendResolveHandoffGive(model.AnswerId.from(answer), give_ptr[0..give_len]) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Take the next event as a structured `op:deliver`, writing it into `out`.
/// Returns `_WRONG_EVENT` (event left queued) when the next event is not a
/// deliver, `_WOULD_BLOCK` when none is queued. `_UNSUPPORTED_VALUE` and decode
/// failures also leave the event queued; drain it with the opaque
/// `pancake_peer_poll_event` (interpreting the raw frame via
/// `pancake_peer_codec`) or the queue never advances. Release `out` with
/// `pancake_deliver_release`.
pub export fn pancake_peer_poll_event_deliver(peer: ?*PancakePeer, out: ?*PancakeDeliver) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const next = ptr.peekEventKind() orelse return PANCAKE_ERR_WOULD_BLOCK;
    if (next != .deliver) return PANCAKE_ERR_WRONG_EVENT;

    // Marshal from a borrowed peek first; consume the event only once the whole
    // projection succeeds. An argument the C surface cannot represent (a handoff
    // or error value) then leaves the deliver queued for the opaque `poll_event`
    // fallback instead of dequeuing it into the void.
    const peeked = ptr.peekEvent() orelse return PANCAKE_ERR_WOULD_BLOCK;
    const body = peeked.view() catch return PANCAKE_ERR_CODEC;

    const arena = newProjectionArena(ptr.allocator) orelse return PANCAKE_ERR_INTERNAL;
    // The failure paths below return error *codes*, not Zig errors, so an
    // errdefer would never fire, the success flag is what keeps a refused
    // projection (e.g. a handoff argument routed to the opaque fallback) from
    // leaking one arena per retry.
    var projected = false;
    defer if (!projected) freeProjectionArena(arena);
    const a = arena.allocator();
    // A malformed or over-nested body is a codec/session fault, not a host
    // internal error; classify it like every other decode failure.
    const owned = body.toOwned(a) catch |err| return feedErrorToCode(err);
    const deliver = owned.deliver;
    const args_c = argsToC(a, deliver.args) catch |err| return marshalErrorToCode(err);
    projected = true;

    // Projection succeeded, now consume and release the event.
    var event = ptr.pollEvent().?;
    event.deinit();
    slot.* = .{
        .target = referenceToC(deliver.target),
        .args = args_c.ptr,
        .args_len = args_c.len,
        .has_answer = if (deliver.answer != null) 1 else 0,
        .answer = if (deliver.answer) |ans| ans.int() else 0,
        .owner = @ptrCast(arena),
    };
    return PANCAKE_OK;
}

/// Take the next event as a structured `op:resolve`. Same routing/return
/// contract as `poll_event_deliver`: `_UNSUPPORTED_VALUE` and decode failures
/// leave the event queued for the opaque `pancake_peer_poll_event`. Release
/// `out` with `pancake_resolve_release`.
pub export fn pancake_peer_poll_event_resolve(peer: ?*PancakePeer, out: ?*PancakeResolve) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const next = ptr.peekEventKind() orelse return PANCAKE_ERR_WOULD_BLOCK;
    if (next != .resolve) return PANCAKE_ERR_WRONG_EVENT;

    // Marshal from a borrowed peek; consume only on full success, so a fulfill
    // value the C surface cannot represent leaves the resolve queued for the
    // opaque `poll_event` fallback rather than being dequeued and lost.
    const peeked = ptr.peekEvent() orelse return PANCAKE_ERR_WOULD_BLOCK;
    const body = peeked.view() catch return PANCAKE_ERR_CODEC;

    const arena = newProjectionArena(ptr.allocator) orelse return PANCAKE_ERR_INTERNAL;
    // Same success-flag discipline as `poll_event_deliver`: the error-code
    // returns below are not Zig errors, so only this defer reclaims the arena
    // on a refused projection.
    var projected = false;
    defer if (!projected) freeProjectionArena(arena);
    const a = arena.allocator();

    // A handoff fulfilled as the resolution is projected straight from the
    // borrowed view: it carries a `desc:handoff-give` the binding redeems, not a
    // value `argumentToC` can render, and `body.toOwned` would flatten the
    // parsed exporter locator back to raw bytes the binding cannot dial.
    if (resolveHandoffGive(a, peeked, body)) |projection| {
        projected = true;
        var event = ptr.pollEvent().?;
        event.deinit();
        slot.* = .{
            .answer = projection.answer,
            .resolution_kind = c.PANCAKE_RESOLUTION_HANDOFF,
            .fulfill = zero_argument,
            .break_message = null,
            .break_message_len = 0,
            .handoff = projection.give,
            .owner = @ptrCast(arena),
        };
        return PANCAKE_OK;
    } else |err| switch (err) {
        // Not a handoff give, fall through to the ordinary value path.
        error.NotHandoff => {},
        error.OutOfMemory => return PANCAKE_ERR_INTERNAL,
    }

    // A malformed or over-nested body is a codec/session fault, not a host
    // internal error; classify it like every other decode failure.
    const owned = body.toOwned(a) catch |err| return feedErrorToCode(err);
    const resolve = owned.resolve;
    const fulfill_c: PancakeArgument = switch (resolve.resolution) {
        .fulfill => |arg| argumentToC(a, arg) catch |err| return marshalErrorToCode(err),
        .@"break" => zero_argument,
    };
    projected = true;

    // Projection succeeded, now consume and release the event.
    var event = ptr.pollEvent().?;
    event.deinit();
    slot.* = .{
        .answer = resolve.answer.int(),
        .resolution_kind = switch (resolve.resolution) {
            .fulfill => c.PANCAKE_RESOLUTION_FULFILL,
            .@"break" => c.PANCAKE_RESOLUTION_BREAK,
        },
        .fulfill = fulfill_c,
        .break_message = switch (resolve.resolution) {
            .fulfill => null,
            .@"break" => |e| e.message.ptr,
        },
        .break_message_len = switch (resolve.resolution) {
            .fulfill => 0,
            .@"break" => |e| e.message.len,
        },
        .handoff = zero_handoff_give,
        .owner = @ptrCast(arena),
    };
    return PANCAKE_OK;
}

const HandoffGiveProjection = struct {
    answer: u64,
    give: c.PancakeHandoffGive,
};

/// Project a resolution that fulfills to a `desc:handoff-give` into the C-facing
/// `PancakeHandoffGive`, copying the verbatim give span and the exporter's
/// dialable `ocapn://…` locator into `a`. Returns `error.NotHandoff` (the caller
/// then takes the ordinary value path) unless the resolution is exactly a
/// fulfilled give. Reads from the borrowed `view`/`event` so the parsed exporter
/// locator survives, `body.toOwned` would flatten it to raw bytes.
fn resolveHandoffGive(
    a: std.mem.Allocator,
    event: *const engine.Event,
    body: model.view.Body,
) error{ NotHandoff, OutOfMemory }!HandoffGiveProjection {
    if (body != .resolve) return error.NotHandoff;
    const resolve = body.resolve;
    if (resolve.resolution != .fulfill) return error.NotHandoff;
    const arg = resolve.resolution.fulfill;
    if (arg != .handoff or arg.handoff != .give) return error.NotHandoff;
    const give = arg.handoff.give;

    // The verbatim signed envelope the recipient relays unaltered to the
    // exporter; without it there is nothing to redeem, so treat its absence as
    // "not a (redeemable) handoff" and fall back to the opaque event.
    const span = engine.spanSignedHandoffGive(event.bytes()) orelse return error.NotHandoff;
    const give_bytes = try a.dupe(u8, span);

    // A flat transport locator becomes a dialable `ocapn://…` URI through the one
    // core grammar — the binding parses it with the same `pancake_uri_*` surface,
    // so the percent-encoding must round-trip (a hand-rolled format with a raw
    // `:` in the designator does not). Any other exporter location leaves the
    // locator empty (the binding cannot dial it) but still surfaces the give
    // bytes and recipient key.
    const locator: []const u8 = switch (give.exporter_location) {
        .locator => |loc| blk: {
            // Recover the exporter's dial hints (e.g. an iroh exporter's
            // direct-address list) from the verbatim location record — the
            // borrowed session reader drops hint entries, so the flat
            // transport/designator above carries none. The arena `a` frees the
            // parsed hints wholesale, so they are not freed individually.
            if (loc.record.len > 0) {
                var cursor: usize = 0;
                const parsed = engine.readLocatorOwned(a, loc.record, &cursor) catch return error.OutOfMemory;
                break :blk model.uri.writePeer(a, parsed) catch return error.OutOfMemory;
            }
            break :blk model.uri.writePeer(a, .{
                .transport = loc.transport,
                .designator = loc.designator,
                .hints = model.Hints.emptyFalse(),
            }) catch return error.OutOfMemory;
        },
        .raw => &.{},
    };
    const recipient_key = try a.dupe(u8, give.recipient_key);

    return .{
        .answer = resolve.answer.int(),
        .give = .{
            .give = give_bytes.ptr,
            .give_len = give_bytes.len,
            .exporter_locator = if (locator.len == 0) null else locator.ptr,
            .exporter_locator_len = locator.len,
            .recipient_key = recipient_key.ptr,
            .recipient_key_len = recipient_key.len,
        },
    };
}

/// Release a `PancakeDeliver` projection; the `args` views aliasing its arena
/// die with it. Idempotent: the struct is cleared, so releasing again (or a
/// zero-initialized struct) is a no-op.
pub export fn pancake_deliver_release(deliver: ?*PancakeDeliver) void {
    const d = deliver orelse return;
    freeProjectionArena(d.owner);
    d.* = .{ .target = zero_reference, .args = null, .args_len = 0, .has_answer = 0, .answer = 0, .owner = null };
}

/// Release a `PancakeResolve` projection; the `fulfill` and `break_message`
/// views aliasing its arena die with it. Idempotent: the struct is cleared, so
/// releasing again (or a zero-initialized struct) is a no-op.
pub export fn pancake_resolve_release(resolve: ?*PancakeResolve) void {
    const r = resolve orelse return;
    freeProjectionArena(r.owner);
    r.* = .{ .answer = 0, .resolution_kind = 0, .fulfill = zero_argument, .break_message = null, .break_message_len = 0, .handoff = zero_handoff_give, .owner = null };
}
