//! C ABI session pump verbs: inbound frame/byte/packet admission, retained
//! input resumption, and outbound transport drains. The Host core owns the
//! semantics. This file owns only the C pointer, layout, and error projection.

const shared = @import("c_abi_shared");

const c = @import("../mod.zig");
const common = @import("../common.zig");

const sessionFrom = common.sessionFrom;
const instOf = common.instOf;
const errToCode = common.errToCode;

const GlowcapHostSession = c.GlowcapHostSession;
const GlowcapFrame = shared.GlowcapFrame;
const GlowcapManagedFrame = shared.GlowcapManagedFrame;

const GLOWCAP_OK = shared.GLOWCAP_OK;
const GLOWCAP_ERR_NULL_POINTER = shared.GLOWCAP_ERR_NULL_POINTER;
const GLOWCAP_ERR_INVALID_ARGUMENT = shared.GLOWCAP_ERR_INVALID_ARGUMENT;
const GLOWCAP_ERR_WOULD_BLOCK = shared.GLOWCAP_ERR_WOULD_BLOCK;

/// Feed one inbound frame the embedder read from its own transport (borrowed
/// for the call): behavior callbacks fire and vow completions queue inside,
/// then the node actions the dispatch queued pump and every touched
/// session's outbound encodes. `GLOWCAP_ERR_WOULD_BLOCK` is the preflight
/// high-water refusal: the frame was not consumed, so drain `take_outbound`,
/// write those frames, and retry it. A non-WOULD_BLOCK failure classifies
/// through the shared taxonomy (`GLOWCAP_ERR_CODEC` / `_SESSION` /
/// `_INTERNAL`). When `glowcap_host_session_last_abort` succeeds, the frame was
/// consumed and the session is closing. Drain its typed `op:abort` and release
/// it. `GLOWCAP_ERR_INTERNAL` with no last-abort is allocation failure before
/// frame admission, so the same borrowed frame remains retryable.
pub fn glowcap_host_session_feed(raw: ?*GlowcapHostSession, frame_in: ?*const GlowcapFrame) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_feed")) return GLOWCAP_ERR_INVALID_ARGUMENT;
    const borrowed = frame_in orelse return GLOWCAP_ERR_NULL_POINTER;
    const bytes_ptr = borrowed.bytes orelse return GLOWCAP_ERR_NULL_POINTER;
    const shape = shared.frameShapeFromC(borrowed.shape) orelse {
        shared.setLastError("host: session_feed frame shape is not a GLOWCAP_FRAME_* value", .{});
        return GLOWCAP_ERR_INVALID_ARGUMENT;
    };
    session.host.feed(session, .{ .bytes = bytes_ptr[0..borrowed.len], .shape = shape }) catch |err| {
        return errToCode(err);
    };
    return GLOWCAP_OK;
}

/// Feed a byte-stream chunk the embedder read from its own transport
/// (borrowed for the call). The library owns outer framing and the tail: each
/// bare codec frame is one canonical Syrup byte string (`length:body`). Split
/// prefixes and bodies stay buffered in the session. Coalesced byte strings
/// dispatch in order, each body exactly as `glowcap_host_session_feed`.
/// Dispatch pauses at the frame that completes the keyed handshake: frames
/// coalesced behind the hello wait in the session's tail while the embedder
/// acts on the fresh session (publish, fetch), and
/// `glowcap_host_session_resume_feed` feeds them once the embedder has
/// installed that post-open authority.
pub fn glowcap_host_session_feed_bytes(
    raw: ?*GlowcapHostSession,
    bytes: ?[*]const u8,
    len: usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_feed_bytes")) return GLOWCAP_ERR_INVALID_ARGUMENT;
    const chunk: []const u8 = if (len == 0) &.{} else blk: {
        const buf = bytes orelse return GLOWCAP_ERR_NULL_POINTER;
        break :blk buf[0..len];
    };
    session.host.feedBytes(session, chunk) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Feed one packet from the transport this session was opened over. Byte-stream
/// transports pass arbitrary chunks carrying ADR-0110's outer envelope.
/// Message-framed transports pass one bare codec frame per packet. The Host's
/// transport profile owns that choice. Borrowed for the call.
pub fn glowcap_host_session_feed_packet(
    raw: ?*GlowcapHostSession,
    bytes: ?[*]const u8,
    len: usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_feed_packet")) return GLOWCAP_ERR_INVALID_ARGUMENT;
    const packet: []const u8 = if (len == 0) &.{} else blk: {
        const buf = bytes orelse return GLOWCAP_ERR_NULL_POINTER;
        break :blk buf[0..len];
    };
    session.host.feedTransportPacket(session, packet) catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Resume input retained by a previous feed. Byte-stream sessions may
/// dispatch their held tail. Message-framed sessions have no hidden tail and
/// no-op. Refused inside a callback.
pub fn glowcap_host_session_resume_feed(raw: ?*GlowcapHostSession) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_resume_feed")) return GLOWCAP_ERR_INVALID_ARGUMENT;
    session.resumeFeed() catch |err| return errToCode(err);
    return GLOWCAP_OK;
}

/// Drain one transport-ready packet. Write `out_prefix[0..out_prefix_len]` and
/// then the owned `out_frame` bytes. Byte-stream sessions return their
/// canonical outer prefix. Message-framed sessions return an empty prefix and
/// one bare frame. Free `out_frame` through `glowcap_managed_frame_release`.
/// Refused inside a callback.
pub fn glowcap_host_session_take_packet(
    raw: ?*GlowcapHostSession,
    out_frame: ?*GlowcapManagedFrame,
    out_prefix: ?[*]u8,
    prefix_cap: usize,
    out_prefix_len: ?*usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_take_packet")) return GLOWCAP_ERR_INVALID_ARGUMENT;
    const slot = out_frame orelse return GLOWCAP_ERR_NULL_POINTER;
    const prefix = out_prefix orelse return GLOWCAP_ERR_NULL_POINTER;
    const prefix_len = out_prefix_len orelse return GLOWCAP_ERR_NULL_POINTER;
    if (prefix_cap < c.GLOWCAP_HOST_OUTBOUND_PREFIX_CAP) {
        prefix_len.* = c.GLOWCAP_HOST_OUTBOUND_PREFIX_CAP;
        return shared.GLOWCAP_ERR_BUFFER_TOO_SMALL;
    }
    const popped = session.takeTransportOutbound() catch |err| return errToCode(err);
    const outbound = popped orelse return GLOWCAP_ERR_WOULD_BLOCK;
    @memcpy(prefix[0..outbound.prefix_len], outbound.prefixBytes());
    prefix_len.* = outbound.prefix_len;
    slot.* = shared.managedFrame(outbound.payload);
    return GLOWCAP_OK;
}

/// Drain one transport-ready byte-stream vector. Write
/// `out_prefix[0..out_prefix_len]` and then the owned `out_frame` bytes. Clear
/// sessions return their canonical outer Syrup prefix. Sealed sessions return
/// an empty prefix because their payload is already wire-ready ciphertext.
/// Free `out_frame` through `glowcap_managed_frame_release`.
pub fn glowcap_host_session_take_outbound(
    raw: ?*GlowcapHostSession,
    out_frame: ?*GlowcapManagedFrame,
    out_prefix: ?[*]u8,
    prefix_cap: usize,
    out_prefix_len: ?*usize,
) callconv(.c) i32 {
    shared.lastErrorClear();
    const session = sessionFrom(raw) orelse return GLOWCAP_ERR_NULL_POINTER;
    if (!common.embedderOwnsDrive(instOf(session.host), "session_take_outbound")) return GLOWCAP_ERR_INVALID_ARGUMENT;
    const slot = out_frame orelse return GLOWCAP_ERR_NULL_POINTER;
    const prefix = out_prefix orelse return GLOWCAP_ERR_NULL_POINTER;
    const prefix_len = out_prefix_len orelse return GLOWCAP_ERR_NULL_POINTER;
    if (prefix_cap < c.GLOWCAP_HOST_OUTBOUND_PREFIX_CAP) {
        prefix_len.* = c.GLOWCAP_HOST_OUTBOUND_PREFIX_CAP;
        return shared.GLOWCAP_ERR_BUFFER_TOO_SMALL;
    }
    const popped = session.takeStreamOutbound() catch |err| return errToCode(err);
    const outbound = popped orelse return GLOWCAP_ERR_WOULD_BLOCK;
    @memcpy(prefix[0..outbound.prefix_len], outbound.prefixBytes());
    prefix_len.* = outbound.prefix_len;
    slot.* = shared.managedFrame(outbound.payload);
    return GLOWCAP_OK;
}
