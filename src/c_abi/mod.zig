const std = @import("std");

const foundation = @import("../foundation/mod.zig");
const runtime = @import("../runtime/mod.zig");

pub const PANCAKE_OK: i32 = 0;
pub const PANCAKE_ERR_NULL_POINTER: i32 = -1;
pub const PANCAKE_ERR_INVALID_HANDLE: i32 = -2;
pub const PANCAKE_ERR_SESSION: i32 = -4;
pub const PANCAKE_ERR_CODEC: i32 = -5;
pub const PANCAKE_ERR_INTERNAL: i32 = -6;
pub const PANCAKE_ERR_WOULD_BLOCK: i32 = -7;

pub const PANCAKE_FRAME_SHAPE_BYTE: u32 = 0;
pub const PANCAKE_FRAME_SHAPE_WORD: u32 = 1;
pub const PANCAKE_EVENT_DELIVER: u32 = 1;
pub const PANCAKE_EVENT_RESOLVE: u32 = 2;
pub const PANCAKE_EVENT_GC_EXPORT: u32 = 3;
pub const PANCAKE_EVENT_GC_ANSWER: u32 = 4;
pub const PANCAKE_EVENT_HANDOFF: u32 = 5;
pub const PANCAKE_EVENT_START_SESSION: u32 = 6;
pub const PANCAKE_EVENT_ABORT: u32 = 7;
pub const PANCAKE_EVENT_LISTEN: u32 = 8;
pub const PANCAKE_EVENT_GET: u32 = 9;
pub const PANCAKE_EVENT_INDEX: u32 = 10;

pub const PancakeFrame = extern struct {
    bytes: ?[*]const u8,
    len: usize,
    shape: u32,
};

pub const ReleaseFn = *const fn (*PancakeManagedFrame) callconv(.c) void;

pub const PancakeManagedFrame = extern struct {
    bytes: ?[*]u8,
    len: usize,
    shape: u32,
    release: ?ReleaseFn,
    private_data: ?*anyopaque,
};

pub const PancakeEvent = extern struct {
    kind: u32,
    frame: PancakeManagedFrame,
};

pub const PancakePeer = opaque {};

const allocator = std.heap.page_allocator;

const ManagedFramePayload = struct {
    frame: foundation.Frame,
};

const AdoptedManagedFramePayload = struct {
    managed: PancakeManagedFrame,
};

/// Classify an inbound-dispatch error into a C ABI return code. Codec/decode
/// malformations report `CODEC`; session state-machine refusals (a partner
/// protocol violation — e.g. `op:gc-answers` against an answer the table never
/// held) report `SESSION`; allocation and anything else report `INTERNAL`.
/// Mirrors the codec-vs-session split [`abort_projection`] keys aborts on, so a
/// C consumer can tell a malformed frame from a protocol refusal.
fn feedErrorToCode(err: anyerror) i32 {
    return switch (err) {
        // codec decode failures (codec.syrup.Error)
        error.InvalidFrameShape,
        error.MalformedFrame,
        error.UnsupportedArgument,
        error.UnsupportedMessage,
        error.UnsupportedReference,
        => PANCAKE_ERR_CODEC,
        // session protocol violations (session.Error)
        error.MalformedMessage,
        error.InvalidReference,
        error.FeatureNotNegotiated,
        error.SessionClosed,
        error.InvalidGift,
        error.HandoffReplay,
        error.GcUnderflow,
        error.UnexpectedMessage,
        error.DuplicateStartSession,
        error.CaptpVersionMismatch,
        error.QueueCapExceeded,
        error.ResolutionCycle,
        error.HostMismatch,
        error.InboundAnswerCapExceeded,
        error.ListenerCapExceeded,
        error.ImportCapExceeded,
        error.HandoffCountCapExceeded,
        error.DepositedGiftCapExceeded,
        => PANCAKE_ERR_SESSION,
        else => PANCAKE_ERR_INTERNAL,
    };
}

pub export fn pancake_managed_frame_release(frame: ?*PancakeManagedFrame) void {
    const managed = frame orelse return;
    const release = managed.release orelse return;

    managed.release = null;
    // The callback owns payload cleanup and any remaining descriptor
    // normalization. Do not touch `managed` after this call; a producer may
    // allocate descriptors whose release reclaims the whole object.
    release(managed);
}

pub export fn pancake_frame_release(frame: ?*PancakeManagedFrame) void {
    pancake_managed_frame_release(frame);
}

pub export fn pancake_event_release(event: ?*PancakeEvent) void {
    const managed = event orelse return;
    pancake_managed_frame_release(&managed.frame);
    managed.kind = 0;
}

pub export fn pancake_peer_new(out_peer: ?*?*PancakePeer) i32 {
    const slot = out_peer orelse return PANCAKE_ERR_NULL_POINTER;
    const peer = allocator.create(runtime.Peer) catch return PANCAKE_ERR_INTERNAL;
    peer.* = runtime.Peer.init(allocator);
    slot.* = @ptrCast(peer);
    return PANCAKE_OK;
}

pub export fn pancake_peer_release(peer: ?*PancakePeer) void {
    const ptr = peerFromOpaque(peer) orelse return;
    ptr.deinit();
    allocator.destroy(ptr);
}

pub export fn pancake_peer_feed_borrowed(peer: ?*PancakePeer, frame: ?*const PancakeFrame) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const borrowed = frame orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = borrowed.bytes orelse return PANCAKE_ERR_NULL_POINTER;
    const shape = frameShapeFromC(borrowed.shape) orelse return PANCAKE_ERR_CODEC;

    ptr.recvBorrowed(.{
        .bytes = bytes_ptr[0..borrowed.len],
        .shape = shape,
    }) catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

pub export fn pancake_peer_feed_owned(peer: ?*PancakePeer, frame: ?*PancakeManagedFrame) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const managed = frame orelse return PANCAKE_ERR_NULL_POINTER;
    const bytes_ptr = managed.bytes orelse return PANCAKE_ERR_NULL_POINTER;
    const shape = frameShapeFromC(managed.shape) orelse return PANCAKE_ERR_CODEC;

    const payload = allocator.create(AdoptedManagedFramePayload) catch return PANCAKE_ERR_INTERNAL;
    errdefer allocator.destroy(payload);
    payload.* = .{ .managed = managed.* };

    const owned = foundation.Frame.initExternal(
        bytes_ptr[0..managed.len],
        shape,
        payload,
        releaseAdoptedManagedFrame,
    ) catch return PANCAKE_ERR_CODEC;

    ptr.feedInbound(owned) catch return PANCAKE_ERR_INTERNAL;
    managed.bytes = null;
    managed.len = 0;
    managed.release = null;
    managed.private_data = null;
    return PANCAKE_OK;
}

pub export fn pancake_peer_step(peer: ?*PancakePeer) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    _ = ptr.step() catch |err| return feedErrorToCode(err);
    return PANCAKE_OK;
}

pub export fn pancake_peer_take_outbound(peer: ?*PancakePeer, out_frame: ?*PancakeManagedFrame) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_frame orelse return PANCAKE_ERR_NULL_POINTER;
    const frame = ptr.takeOutbound() orelse return PANCAKE_ERR_WOULD_BLOCK;

    const payload = allocator.create(ManagedFramePayload) catch {
        var owned = frame;
        owned.deinit();
        return PANCAKE_ERR_INTERNAL;
    };
    payload.* = .{ .frame = frame };
    slot.* = .{
        .bytes = @constCast(payload.frame.bytes().ptr),
        .len = payload.frame.bytes().len,
        .shape = frameShapeToC(payload.frame.view().shape),
        .release = releaseOwnedFrame,
        .private_data = payload,
    };
    return PANCAKE_OK;
}

pub export fn pancake_peer_poll_event(peer: ?*PancakePeer, out_event: ?*PancakeEvent) i32 {
    const ptr = peerFromOpaque(peer) orelse return PANCAKE_ERR_NULL_POINTER;
    const slot = out_event orelse return PANCAKE_ERR_NULL_POINTER;
    var event = ptr.pollEvent() orelse return PANCAKE_ERR_WOULD_BLOCK;

    // Hand back the originating frame bytes in the session's negotiated codec.
    // The frame moves into the managed payload; no decode and no re-encode.
    slot.* = .{
        .kind = eventKindToC(event.kind()),
        .frame = tryManagedFrame(event.frame) catch {
            event.deinit();
            return PANCAKE_ERR_INTERNAL;
        },
    };
    return PANCAKE_OK;
}

fn tryManagedFrame(frame: foundation.Frame) !PancakeManagedFrame {
    const payload = try allocator.create(ManagedFramePayload);
    payload.* = .{ .frame = frame };
    return .{
        .bytes = @constCast(payload.frame.bytes().ptr),
        .len = payload.frame.bytes().len,
        .shape = frameShapeToC(payload.frame.view().shape),
        .release = releaseOwnedFrame,
        .private_data = payload,
    };
}

fn eventKindToC(kind: runtime.EventKind) u32 {
    return switch (kind) {
        .deliver => PANCAKE_EVENT_DELIVER,
        .resolve => PANCAKE_EVENT_RESOLVE,
        .gc_export => PANCAKE_EVENT_GC_EXPORT,
        .gc_answer => PANCAKE_EVENT_GC_ANSWER,
        .handoff => PANCAKE_EVENT_HANDOFF,
        .start_session => PANCAKE_EVENT_START_SESSION,
        .abort => PANCAKE_EVENT_ABORT,
        .listen => PANCAKE_EVENT_LISTEN,
        .get => PANCAKE_EVENT_GET,
        .index => PANCAKE_EVENT_INDEX,
    };
}

fn releaseOwnedFrame(frame: *PancakeManagedFrame) callconv(.c) void {
    const payload_ptr = frame.private_data orelse return;
    const payload: *ManagedFramePayload = @ptrCast(@alignCast(payload_ptr));
    payload.frame.deinit();
    allocator.destroy(payload);
    frame.bytes = null;
    frame.len = 0;
    frame.release = null;
    frame.private_data = null;
}

fn releaseAdoptedManagedFrame(context: *anyopaque) void {
    const payload: *AdoptedManagedFramePayload = @ptrCast(@alignCast(context));
    pancake_managed_frame_release(&payload.managed);
    allocator.destroy(payload);
}

fn peerFromOpaque(peer: ?*PancakePeer) ?*runtime.Peer {
    const ptr = peer orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn frameShapeFromC(shape: u32) ?foundation.FrameShape {
    return switch (shape) {
        PANCAKE_FRAME_SHAPE_BYTE => .byte,
        PANCAKE_FRAME_SHAPE_WORD => .word,
        else => null,
    };
}

fn frameShapeToC(shape: foundation.FrameShape) u32 {
    return switch (shape) {
        .byte => PANCAKE_FRAME_SHAPE_BYTE,
        .word => PANCAKE_FRAME_SHAPE_WORD,
    };
}
