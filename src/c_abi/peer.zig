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
const ctx = @import("context.zig");
const frame = @import("frame.zig");
const marshal = @import("marshal.zig");

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

pub fn peerFromOpaque(peer: ?*PancakePeer) ?*engine.Peer {
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
/// same pair — `op:start-session` carries the profile but no codec operand, so
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

/// Create an already-open peer for low-level tests and harnesses that inject
/// frames directly. This is a fixture surface; real OCapN connections should use
/// `pancake_peer_new`.
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
        // fault — storage that does not satisfy the declared shape (a word
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
/// outbound work. No I/O — the caller drains `take_outbound` and `poll_event`
/// afterward.
pub export fn pancake_peer_step(peer: ?*PancakePeer) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    _ = ptr.step() catch |err| return feedErrorToCode(err);
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
/// must be the ones it expects — for a Goblins partner, transport `"tcp"` with
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
    slot.* = prepared.answer_position;
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
    ptr.session_state.registerExport(export_position) catch |err| return feedErrorToCode(err);
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
    ptr.session_state.registerImport(import_position) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

// ── Typed OCapN driving surface ──────────────────────────────────────────────
//
// The opaque-frame path (`feed_*` / `take_outbound` / `poll_event`) shuttles wire
// bytes. This surface lets a C consumer *drive* OCapN: construct a call and read
// a delivery as structured values, without authoring or parsing a codec itself.
//
// Send marshals caller-owned C structs into a `model` message and routes through
// `Peer.sendCopying` — the named boundary copy that owns the clone, so the C
// bytes are borrowed only for the call. Receive materializes the event once into
// a per-event arena and projects C views whose byte pointers alias that arena;
// the matching `*_free` releases it. The struct layouts are frozen ABI (ADR-0031).

const zero_reference = marshal.zero_reference;
const zero_argument = marshal.zero_argument;
const MarshalError = marshal.MarshalError;
const marshalErrorToCode = marshal.marshalErrorToCode;
const sliceFromC = marshal.sliceFromC;
const referenceFromC = marshal.referenceFromC;
const argumentFromC = marshal.argumentFromC;
const argsFromC = marshal.argsFromC;
const referenceToC = marshal.referenceToC;
const argumentToC = marshal.argumentToC;
const argsToC = marshal.argsToC;
const newProjectionArena = marshal.newProjectionArena;
const freeProjectionArena = marshal.freeProjectionArena;

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
        .answer = if (has_answer != 0) answer else null,
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
    ptr.sendCopying(.{ .resolve = .{ .answer = answer, .resolution = resolution } }) catch |err| return feedErrorToCode(err);
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
    // errdefer would never fire — the success flag is what keeps a refused
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

    // Projection succeeded — now consume and release the event.
    var event = ptr.pollEvent().?;
    event.deinit();
    slot.* = .{
        .target = referenceToC(deliver.target),
        .args = args_c.ptr,
        .args_len = args_c.len,
        .has_answer = if (deliver.answer != null) 1 else 0,
        .answer = deliver.answer orelse 0,
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
    // A malformed or over-nested body is a codec/session fault, not a host
    // internal error; classify it like every other decode failure.
    const owned = body.toOwned(a) catch |err| return feedErrorToCode(err);
    const resolve = owned.resolve;
    const fulfill_c: PancakeArgument = switch (resolve.resolution) {
        .fulfill => |arg| argumentToC(a, arg) catch |err| return marshalErrorToCode(err),
        .@"break" => zero_argument,
    };
    projected = true;

    // Projection succeeded — now consume and release the event.
    var event = ptr.pollEvent().?;
    event.deinit();
    slot.* = .{
        .answer = resolve.answer,
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
        .owner = @ptrCast(arena),
    };
    return PANCAKE_OK;
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
    r.* = .{ .answer = 0, .resolution_kind = 0, .fulfill = zero_argument, .break_message = null, .break_message_len = 0, .owner = null };
}
