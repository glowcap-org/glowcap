//! The `PancakePeer` driving surface: lifecycle, the opaque-frame path
//! (`feed_*` / `recv_stream` / `step` / `take_outbound` / `poll_event`), the
//! keyed `op:start-session` handshake, bootstrap/export/import registration, and
//! the typed OCapN send/poll surface that marshals structured values without a
//! codec.

const std = @import("std");

const foundation = @import("../foundation/mod.zig");
const model = @import("../model/mod.zig");
const engine = @import("../engine/mod.zig");

const c = @import("mod.zig");
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

pub export fn pancake_peer_new(out_peer: ?*?*PancakePeer) i32 {
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    return peerNewIn(ctx.library_allocator, slot, false);
}

/// Create a peer whose every allocation — the peer object, session tables, and
/// the managed frames it later hands out — routes through `context`. The peer is
/// released with the same `pancake_peer_release`; it remembers its context's
/// allocator, so the caller does not name it again.
pub export fn pancake_peer_new_in(context: ?*PancakeContext, out_peer: ?*?*PancakePeer) i32 {
    const c_ctx = ctx.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    return peerNewIn(c_ctx.allocator, slot, false);
}

/// Create a peer that begins in the negotiating state, awaiting the keyed
/// `op:start-session` handshake. This is the peer a binding drives to talk to a
/// peer that requires the handshake (a real Goblins vat): pair it with
/// `pancake_peer_start_session_keyed` to sign and queue the local start-session,
/// then pump the connection until `pancake_peer_session_is_open` reports true.
pub export fn pancake_peer_new_negotiating(out_peer: ?*?*PancakePeer) i32 {
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    return peerNewIn(ctx.library_allocator, slot, true);
}

/// Negotiating counterpart of `pancake_peer_new_in`: a handshake-ready peer whose
/// allocations route through `context`.
pub export fn pancake_peer_new_negotiating_in(context: ?*PancakeContext, out_peer: ?*?*PancakePeer) i32 {
    const c_ctx = ctx.ctxFromOpaque(context) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    return peerNewIn(c_ctx.allocator, slot, true);
}

fn peerNewIn(alloc: std.mem.Allocator, slot: *?*PancakePeer, negotiating: bool) i32 {
    const peer = alloc.create(engine.Peer) catch return PANCAKE_ERR_INTERNAL;
    peer.* = if (negotiating) engine.Peer.initNegotiating(alloc) else engine.Peer.init(alloc);
    slot.* = @ptrCast(peer);
    return PANCAKE_OK;
}

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
    const shape = frame.frameShapeFromC(borrowed.shape) orelse return PANCAKE_ERR_CODEC;

    ptr.recvBorrowed(.{
        .bytes = bytes_ptr[0..borrowed.len],
        .shape = shape,
    }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Adopt an inbound managed frame, transferring ownership to the peer for queued
/// dispatch. On success the caller's `frame` struct is nulled out (bytes/len/
/// release cleared) so it is not released twice; the peer releases it later.
pub export fn pancake_peer_feed_owned(peer: ?*PancakePeer, frame_in: ?*PancakeManagedFrame) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const managed = frame_in orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = managed.bytes orelse return PANCAKE_ERR_NULL_POINTER;
    const shape = frame.frameShapeFromC(managed.shape) orelse return PANCAKE_ERR_CODEC;

    const alloc = ptr.allocator;
    const payload = alloc.create(frame.AdoptedManagedFramePayload) catch return PANCAKE_ERR_INTERNAL;
    var queued = false;
    defer if (!queued) alloc.destroy(payload);
    payload.* = .{ .managed = managed.*, .allocator = alloc };

    const owned = foundation.Frame.initExternal(
        bytes_ptr[0..managed.len],
        shape,
        payload,
        frame.releaseAdoptedManagedFrame,
    ) catch return PANCAKE_ERR_CODEC;

    ptr.feedInbound(owned) catch return PANCAKE_ERR_INTERNAL;
    queued = true;
    managed.bytes = null;
    managed.len = 0;
    managed.release = null;
    managed.private_data = null;
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
    const buf = bytes orelse return PANCAKE_ERR_NULL_POINTER;
    const consumed = out_consumed orelse return PANCAKE_ERR_NULL_POINTER;
    consumed.* = 0;

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
/// when the outbound queue is empty.
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
/// `hints_empty_false` nonzero (an empty hints map encoded as `#f`, the form
/// Goblins re-encodes and checks). `captp_version` is 0 for the canonical v1.0
/// wire or 1 for the pre-spec profile. The seed is the only place key material
/// crosses the boundary; the library never generates entropy.
pub export fn pancake_peer_start_session_keyed(
    peer: ?*PancakePeer,
    captp_version: u32,
    transport: ?[*]const u8,
    transport_len: usize,
    designator: ?[*]const u8,
    designator_len: usize,
    hints_empty_false: u32,
    seed: ?[*]const u8,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const transport_ptr = transport orelse return PANCAKE_ERR_NULL_POINTER;
    const designator_ptr = designator orelse return PANCAKE_ERR_NULL_POINTER;
    const seed_ptr = seed orelse return PANCAKE_ERR_NULL_POINTER;

    const version: model.CaptpVersion = switch (captp_version) {
        0 => .v1_0,
        1 => .pre_spec,
        else => return PANCAKE_ERR_INVALID_ARGUMENT,
    };

    const seed_bytes: [foundation.crypto.SEED_BYTES]u8 = seed_ptr[0..foundation.crypto.SEED_BYTES].*;
    const secret = foundation.crypto.SecretKey.fromSeed(seed_bytes) catch return PANCAKE_ERR_INVALID_ARGUMENT;

    const locator: model.PeerLocator = .{
        .transport = transport_ptr[0..transport_len],
        .designator = designator_ptr[0..designator_len],
        .hints = if (hints_empty_false != 0) model.Hints.emptyFalse() else model.Hints.emptyMap(),
    };

    ptr.sendKeyedStartSession(version, locator, secret) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Whether the peer's session has completed the `op:start-session` handshake and
/// is open for traffic. Returns 1 when open, 0 when not, and a negative
/// `PANCAKE_ERR_*` for a null peer. Pump the connection and poll this after a
/// keyed start-session before sending application messages.
pub export fn pancake_peer_session_is_open(peer: ?*PancakePeer) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    return if (ptr.sessionIsOpen()) 1 else 0;
}

// ── Bootstrap registration ───────────────────────────────────────────────────

/// Expose a local capability behind `swissnum` for inbound bootstrap-fetch
/// (ADR-0006 responder half). Writes the allocated export id into
/// `out_export_id`. The swissnum bytes are borrowed for the call.
pub export fn pancake_peer_register_bootstrap_cap(
    peer: ?*PancakePeer,
    swissnum: ?[*]const u8,
    swissnum_len: usize,
    out_export_id: ?*u64,
) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_export_id orelse return PANCAKE_ERR_NULL_POINTER;
    const swiss_ptr = swissnum orelse return PANCAKE_ERR_NULL_POINTER;
    const export_id = ptr.registerBootstrapCap(swiss_ptr[0..swissnum_len]) catch |err|
        return feedErrorToCode(err);
    slot.* = export_id;
    return PANCAKE_OK;
}

/// Register a local export position so inbound deliveries targeting it surface as
/// events. The bare-position sibling of `register_bootstrap_cap` (no swissnum).
pub export fn pancake_peer_register_export(peer: ?*PancakePeer, export_id: u64) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    ptr.session_state.registerExport(export_id) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Track a partner-hosted import position this peer holds, so a typed
/// `send_deliver` to it as a `_FAR` reference is admitted. Partner-allocated
/// imports normally arrive through a resolution; this names a known one (e.g. the
/// bootstrap import) directly.
pub export fn pancake_peer_register_import(peer: ?*PancakePeer, import_id: u64) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    ptr.session_state.registerImport(import_id) catch |err| return feedErrorToCode(err);
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

const zero_reference: PancakeReference = .{ .kind = c.PANCAKE_REF_BROKEN, .sub_kind = 0, .id = 0 };
const zero_argument: PancakeArgument = .{
    .kind = c.PANCAKE_ARG_VOID,
    .boolean = 0,
    .integer = 0,
    .float64 = 0,
    .bytes = null,
    .bytes_len = 0,
    .reference = zero_reference,
    .items = null,
    .items_len = 0,
};

const MarshalError = error{ UnsupportedValue, NullPointer, OutOfMemory };

fn marshalErrorToCode(err: MarshalError) i32 {
    return switch (err) {
        error.UnsupportedValue => PANCAKE_ERR_UNSUPPORTED_VALUE,
        error.NullPointer => PANCAKE_ERR_NULL_POINTER,
        error.OutOfMemory => PANCAKE_ERR_INTERNAL,
    };
}

fn sliceFromC(ptr: ?[*]const u8, len: usize) MarshalError![]const u8 {
    if (len == 0) return &.{};
    const p = ptr orelse return error.NullPointer;
    return p[0..len];
}

fn referenceFromC(c_ref: PancakeReference) MarshalError!model.Reference {
    const promise_sub = c_ref.sub_kind == c.PANCAKE_REF_PROMISE_KIND;
    return switch (c_ref.kind) {
        c.PANCAKE_REF_NEAR => .{ .near = .{ .export_id = c_ref.id, .kind = if (promise_sub) .promise else .object } },
        c.PANCAKE_REF_FAR => .{ .far = .{ .import_id = c_ref.id, .kind = if (promise_sub) .promise else .object } },
        c.PANCAKE_REF_PROMISE => .{ .promise = .{ .answer_id = c_ref.id } },
        else => error.UnsupportedValue,
    };
}

/// Depth bound on a host-supplied argument tree. A foreign caller could nest
/// `PancakeArgument` lists/sets/tagged values arbitrarily deep and overflow the
/// native stack inside `argumentFromC`, exactly as a hostile wire frame could in
/// the codec (bounded there). This caps the local-call encoder the same way. The
/// value mirrors the session's default `max_nesting_depth` (64) so the C send
/// path admits no deeper tree than an inbound deliver would; the session layer is
/// not importable here, so the constant is restated rather than referenced.
const max_marshal_depth: usize = 64;

fn argumentFromC(arena: std.mem.Allocator, c_arg: PancakeArgument, depth: usize) MarshalError!model.Argument {
    if (depth > max_marshal_depth) return error.UnsupportedValue;
    const next = depth + 1;
    return switch (c_arg.kind) {
        c.PANCAKE_ARG_INTEGER => .{ .integer = c_arg.integer },
        c.PANCAKE_ARG_FLOAT64 => .{ .float64 = c_arg.float64 },
        c.PANCAKE_ARG_BOOLEAN => .{ .boolean = c_arg.boolean != 0 },
        c.PANCAKE_ARG_BYTES => .{ .bytes = try sliceFromC(c_arg.bytes, c_arg.bytes_len) },
        c.PANCAKE_ARG_STRING => .{ .string = try sliceFromC(c_arg.bytes, c_arg.bytes_len) },
        c.PANCAKE_ARG_SYMBOL => .{ .symbol = try sliceFromC(c_arg.bytes, c_arg.bytes_len) },
        c.PANCAKE_ARG_VOID => .{ .void = {} },
        c.PANCAKE_ARG_REFERENCE => .{ .reference = try referenceFromC(c_arg.reference) },
        c.PANCAKE_ARG_LIST => .{ .list = try argsFromC(arena, c_arg.items, c_arg.items_len, next) },
        c.PANCAKE_ARG_SET => .{ .set = try argsFromC(arena, c_arg.items, c_arg.items_len, next) },
        c.PANCAKE_ARG_TAGGED => .{ .tagged = .{
            .tag = try sliceFromC(c_arg.bytes, c_arg.bytes_len),
            .value = try argsFromC(arena, c_arg.items, c_arg.items_len, next),
        } },
        c.PANCAKE_ARG_KEYWORD => .{ .keyword = try sliceFromC(c_arg.bytes, c_arg.bytes_len) },
        else => error.UnsupportedValue,
    };
}

fn argsFromC(arena: std.mem.Allocator, items: ?[*]const PancakeArgument, len: usize, depth: usize) MarshalError![]const model.Argument {
    if (len == 0) return &.{};
    const p = items orelse return error.NullPointer;
    const out = try arena.alloc(model.Argument, len);
    for (0..len) |i| out[i] = try argumentFromC(arena, p[i], depth);
    return out;
}

fn referenceToC(reference: model.Reference) PancakeReference {
    return switch (reference) {
        .near => |near| .{ .kind = c.PANCAKE_REF_NEAR, .sub_kind = if (near.kind == .promise) c.PANCAKE_REF_PROMISE_KIND else c.PANCAKE_REF_OBJECT, .id = near.export_id },
        .far => |far| .{ .kind = c.PANCAKE_REF_FAR, .sub_kind = if (far.kind == .promise) c.PANCAKE_REF_PROMISE_KIND else c.PANCAKE_REF_OBJECT, .id = far.import_id },
        .promise => |promise| .{ .kind = c.PANCAKE_REF_PROMISE, .sub_kind = 0, .id = promise.answer_id },
        .sturdy => .{ .kind = c.PANCAKE_REF_STURDY, .sub_kind = 0, .id = 0 },
        .broken => .{ .kind = c.PANCAKE_REF_BROKEN, .sub_kind = 0, .id = 0 },
    };
}

fn argumentToC(arena: std.mem.Allocator, arg: model.Argument) MarshalError!PancakeArgument {
    var c_arg = zero_argument;
    switch (arg) {
        .integer => |v| {
            c_arg.kind = c.PANCAKE_ARG_INTEGER;
            c_arg.integer = v;
        },
        .float64 => |v| {
            c_arg.kind = c.PANCAKE_ARG_FLOAT64;
            c_arg.float64 = v;
        },
        .boolean => |v| {
            c_arg.kind = c.PANCAKE_ARG_BOOLEAN;
            c_arg.boolean = if (v) 1 else 0;
        },
        .bytes => |b| {
            c_arg.kind = c.PANCAKE_ARG_BYTES;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .string => |b| {
            c_arg.kind = c.PANCAKE_ARG_STRING;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .symbol => |b| {
            c_arg.kind = c.PANCAKE_ARG_SYMBOL;
            c_arg.bytes = b.ptr;
            c_arg.bytes_len = b.len;
        },
        .void => c_arg.kind = c.PANCAKE_ARG_VOID,
        .reference => |r| {
            c_arg.kind = c.PANCAKE_ARG_REFERENCE;
            c_arg.reference = referenceToC(r);
        },
        .list => |items| {
            c_arg.kind = c.PANCAKE_ARG_LIST;
            const arr = try argsToC(arena, items);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .set => |items| {
            c_arg.kind = c.PANCAKE_ARG_SET;
            const arr = try argsToC(arena, items);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .tagged => |tagged| {
            c_arg.kind = c.PANCAKE_ARG_TAGGED;
            c_arg.bytes = tagged.tag.ptr;
            c_arg.bytes_len = tagged.tag.len;
            const arr = try argsToC(arena, tagged.value);
            c_arg.items = arr.ptr;
            c_arg.items_len = arr.len;
        },
        .keyword => |keyword| {
            c_arg.kind = c.PANCAKE_ARG_KEYWORD;
            c_arg.bytes = keyword.ptr;
            c_arg.bytes_len = keyword.len;
        },
        else => return error.UnsupportedValue,
    }
    return c_arg;
}

fn argsToC(arena: std.mem.Allocator, args: []const model.Argument) MarshalError![]PancakeArgument {
    const out = try arena.alloc(PancakeArgument, args.len);
    for (args, 0..) |arg, i| out[i] = try argumentToC(arena, arg);
    return out;
}

/// Allocate a heap-pinned arena (child = the peer's allocator) to own a received
/// projection. `pancake_*_free` deinits and destroys it through that same child.
fn newProjectionArena(alloc: std.mem.Allocator) ?*std.heap.ArenaAllocator {
    const arena = alloc.create(std.heap.ArenaAllocator) catch return null;
    arena.* = std.heap.ArenaAllocator.init(alloc);
    return arena;
}

fn freeProjectionArena(owner: ?*anyopaque) void {
    const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(owner orelse return));
    const child = arena.child_allocator;
    arena.deinit();
    child.destroy(arena);
}

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
/// This surface does not carry a `resolve_me_desc` (the V1.0 inline resolver a
/// deliver may name); the deliver is sent with none. A consumer that needs one
/// is past what the typed C send expresses today.
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
        c.PANCAKE_RESOLUTION_BREAK => .{ .break_ = .{
            .message = sliceFromC(break_message, break_message_len) catch |err| return marshalErrorToCode(err),
        } },
        else => return PANCAKE_ERR_INVALID_ARGUMENT,
    };
    ptr.sendCopying(.{ .resolve = .{ .answer = answer, .resolution = resolution } }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

/// Take the next event as a structured `op:deliver`, writing it into `out`.
/// Returns `_WRONG_EVENT` (event left queued) when the next event is not a
/// deliver, `_WOULD_BLOCK` when none is queued. Release `out` with
/// `pancake_deliver_free`.
pub export fn pancake_peer_poll_event_deliver(peer: ?*PancakePeer, out: ?*PancakeDeliver) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const next = ptr.peekEventKind() orelse return PANCAKE_ERR_WOULD_BLOCK;
    if (next != .deliver) return PANCAKE_ERR_WRONG_EVENT;

    var event = ptr.pollEvent() orelse return PANCAKE_ERR_WOULD_BLOCK;
    defer event.deinit();
    const body = event.view() catch return PANCAKE_ERR_CODEC;

    const arena = newProjectionArena(ptr.allocator) orelse return PANCAKE_ERR_INTERNAL;
    errdefer freeProjectionArena(arena);
    const a = arena.allocator();
    // A malformed or over-nested body is a codec/session fault, not a host
    // internal error; classify it like every other decode failure.
    const owned = body.toOwned(a) catch |err| return feedErrorToCode(err);
    const deliver = owned.deliver;
    const args_c = argsToC(a, deliver.args) catch |err| return marshalErrorToCode(err);

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
/// contract as `poll_event_deliver`. Release `out` with `pancake_resolve_free`.
pub export fn pancake_peer_poll_event_resolve(peer: ?*PancakePeer, out: ?*PancakeResolve) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out orelse return PANCAKE_ERR_NULL_POINTER;
    const next = ptr.peekEventKind() orelse return PANCAKE_ERR_WOULD_BLOCK;
    if (next != .resolve) return PANCAKE_ERR_WRONG_EVENT;

    var event = ptr.pollEvent() orelse return PANCAKE_ERR_WOULD_BLOCK;
    defer event.deinit();
    const body = event.view() catch return PANCAKE_ERR_CODEC;

    const arena = newProjectionArena(ptr.allocator) orelse return PANCAKE_ERR_INTERNAL;
    errdefer freeProjectionArena(arena);
    const a = arena.allocator();
    // A malformed or over-nested body is a codec/session fault, not a host
    // internal error; classify it like every other decode failure.
    const owned = body.toOwned(a) catch |err| return feedErrorToCode(err);
    const resolve = owned.resolve;

    slot.* = .{
        .answer = resolve.answer,
        .resolution_kind = switch (resolve.resolution) {
            .fulfill => c.PANCAKE_RESOLUTION_FULFILL,
            .break_ => c.PANCAKE_RESOLUTION_BREAK,
        },
        .fulfill = switch (resolve.resolution) {
            .fulfill => |arg| argumentToC(a, arg) catch |err| return marshalErrorToCode(err),
            .break_ => zero_argument,
        },
        .break_message = switch (resolve.resolution) {
            .fulfill => null,
            .break_ => |e| e.message.ptr,
        },
        .break_message_len = switch (resolve.resolution) {
            .fulfill => 0,
            .break_ => |e| e.message.len,
        },
        .owner = @ptrCast(arena),
    };
    return PANCAKE_OK;
}

/// Release a `PancakeDeliver` projection exactly once; the descriptor is cleared.
pub export fn pancake_deliver_free(deliver: ?*PancakeDeliver) void {
    const d = deliver orelse return;
    freeProjectionArena(d.owner);
    d.* = .{ .target = zero_reference, .args = null, .args_len = 0, .has_answer = 0, .answer = 0, .owner = null };
}

/// Release a `PancakeResolve` projection exactly once; the descriptor is cleared.
pub export fn pancake_resolve_free(resolve: ?*PancakeResolve) void {
    const r = resolve orelse return;
    freeProjectionArena(r.owner);
    r.* = .{ .answer = 0, .resolution_kind = 0, .fulfill = zero_argument, .break_message = null, .break_message_len = 0, .owner = null };
}
