//! C ABI session pump verbs: inbound frame/byte/packet admission, retained
//! input resumption, and outbound transport drains. The Host core owns the
//! semantics; this file owns only the C pointer, layout, and error projection.

const shared = @import("c_abi_shared");

const c = @import("../mod.zig");
const common = @import("../common.zig");

const sessionFrom = common.sessionFrom;
const instOf = common.instOf;
const errToCode = common.errToCode;

const PancakeHostSession = c.PancakeHostSession;
const PancakeFrame = shared.PancakeFrame;
const PancakeManagedFrame = shared.PancakeManagedFrame;

const PANCAKE_OK = shared.PANCAKE_OK;
const PANCAKE_ERR_NULL_POINTER = shared.PANCAKE_ERR_NULL_POINTER;
const PANCAKE_ERR_INVALID_ARGUMENT = shared.PANCAKE_ERR_INVALID_ARGUMENT;
const PANCAKE_ERR_WOULD_BLOCK = shared.PANCAKE_ERR_WOULD_BLOCK;

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
/// Dispatch pauses at the frame that completes the keyed handshake: frames
/// coalesced behind the hello wait in the session's tail while the embedder
/// acts on the fresh session (publish, fetch), and
/// `pancake_host_session_resume_feed` feeds them once the embedder has
/// installed that post-open authority.
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

/// Feed one packet from the transport this session was opened over. Byte-stream
/// transports pass arbitrary chunks carrying ADR-0110's outer envelope;
/// message-framed transports pass one bare codec frame per packet. The Host's
/// transport profile owns that choice. Borrowed for the call.
pub export fn pancake_host_session_feed_packet(
    raw: ?*PancakeHostSession,
    bytes: ?[*]const u8,
    len: usize,
) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_feed_packet")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const packet: []const u8 = if (len == 0) &.{} else blk: {
        const buf = bytes orelse return PANCAKE_ERR_NULL_POINTER;
        break :blk buf[0..len];
    };
    session.host.feedTransportPacket(session, packet) catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Resume input retained by a previous feed. Byte-stream sessions may
/// dispatch their held tail; message-framed sessions have no hidden tail and
/// no-op. Refused inside a callback.
pub export fn pancake_host_session_resume_feed(raw: ?*PancakeHostSession) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_resume_feed")) return PANCAKE_ERR_INVALID_ARGUMENT;
    session.resumeFeed() catch |err| return errToCode(err);
    return PANCAKE_OK;
}

/// Drain one transport-ready packet. Write `out_prefix[0..out_prefix_len]` and
/// then the owned `out_frame` bytes. Byte-stream sessions return their
/// canonical outer prefix; message-framed sessions return an empty prefix and
/// one bare frame. Free `out_frame` through `pancake_managed_frame_release`.
/// Refused inside a callback.
pub export fn pancake_host_session_take_packet(
    raw: ?*PancakeHostSession,
    out_frame: ?*PancakeManagedFrame,
    out_prefix: ?[*]u8,
    prefix_cap: usize,
    out_prefix_len: ?*usize,
) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return PANCAKE_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_take_packet")) return PANCAKE_ERR_INVALID_ARGUMENT;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;
    const prefix = out_prefix orelse return PANCAKE_ERR_NULL_POINTER;
    const prefix_len = out_prefix_len orelse return PANCAKE_ERR_NULL_POINTER;
    if (prefix_cap < c.PANCAKE_HOST_OUTBOUND_PREFIX_CAP) {
        prefix_len.* = c.PANCAKE_HOST_OUTBOUND_PREFIX_CAP;
        return shared.PANCAKE_ERR_BUFFER_TOO_SMALL;
    }
    const inst = instOf(session.host);
    const reservation = shared.reserveManagedFrame(inst.allocator) catch {
        shared.setLastError("take_packet: frame wrap allocation failed", .{});
        return shared.PANCAKE_ERR_INTERNAL;
    };
    const popped = session.takeTransportOutbound() catch |err| {
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

/// Drain one transport-ready byte-stream vector. Write
/// `out_prefix[0..out_prefix_len]` and then the owned `out_frame` bytes. Clear
/// sessions return their canonical outer Syrup prefix; sealed sessions return
/// an empty prefix because their payload is already wire-ready ciphertext.
/// Free `out_frame` through `pancake_managed_frame_release`.
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
