//! Managed-frame machinery: wrapping an owned `foundation.Frame` as a
//! self-releasing `PancakeManagedFrame`, adopting an inbound managed frame, and
//! the codec/shape/event-kind conversions shared by the peer and endpoint
//! surfaces.

const std = @import("std");

const foundation = @import("foundation");
const engine = @import("engine");

const c = @import("mod.zig");

const PancakeManagedFrame = c.PancakeManagedFrame;
const PancakeEvent = c.PancakeEvent;

const ManagedFramePayload = struct {
    frame: foundation.Frame,
    allocator: std.mem.Allocator,
};

pub const AdoptedManagedFramePayload = struct {
    managed: PancakeManagedFrame,
    allocator: std.mem.Allocator,
};

pub export fn pancake_managed_frame_release(frame: ?*PancakeManagedFrame) void {
    const managed = frame orelse return;
    const release = managed.release orelse return;

    managed.release = null;
    // The callback owns payload cleanup and any remaining descriptor
    // normalization. Do not touch `managed` after this call; a producer may
    // allocate descriptors whose release reclaims the whole object.
    release(managed);
}

pub export fn pancake_event_release(event: ?*PancakeEvent) void {
    const managed = event orelse return;
    pancake_managed_frame_release(&managed.frame);
    managed.kind = 0;
}

/// Wrap an owned `foundation.Frame` as a self-releasing managed frame. The frame
/// moves into a heap payload; the descriptor's `release` frees the payload and
/// the frame through `alloc`.
pub fn tryManagedFrame(alloc: std.mem.Allocator, frame: foundation.Frame) !PancakeManagedFrame {
    const payload = try alloc.create(ManagedFramePayload);
    payload.* = .{ .frame = frame, .allocator = alloc };
    return .{
        .bytes = @constCast(payload.frame.bytes().ptr),
        .len = payload.frame.bytes().len,
        .shape = frameShapeToC(payload.frame.view().shape),
        .release = releaseOwnedFrame,
        .private_data = payload,
    };
}

pub fn eventKindToC(kind: engine.EventKind) u32 {
    return switch (kind) {
        .deliver => c.PANCAKE_EVENT_DELIVER,
        .resolve => c.PANCAKE_EVENT_RESOLVE,
        .gc_export => c.PANCAKE_EVENT_GC_EXPORT,
        .gc_answer => c.PANCAKE_EVENT_GC_ANSWER,
        .handoff => c.PANCAKE_EVENT_HANDOFF,
        .start_session => c.PANCAKE_EVENT_START_SESSION,
        .abort => c.PANCAKE_EVENT_ABORT,
        .listen => c.PANCAKE_EVENT_LISTEN,
        .get => c.PANCAKE_EVENT_GET,
        .index => c.PANCAKE_EVENT_INDEX,
        .untag => c.PANCAKE_EVENT_UNTAG,
    };
}

fn releaseOwnedFrame(frame: *PancakeManagedFrame) callconv(.c) void {
    const payload_ptr = frame.private_data orelse return;
    const payload: *ManagedFramePayload = @ptrCast(@alignCast(payload_ptr));
    const alloc = payload.allocator;
    payload.frame.deinit();
    alloc.destroy(payload);
    frame.bytes = null;
    frame.len = 0;
    frame.release = null;
    frame.private_data = null;
}

pub fn releaseAdoptedManagedFrame(context: *anyopaque) void {
    const payload: *AdoptedManagedFramePayload = @ptrCast(@alignCast(context));
    const alloc = payload.allocator;
    pancake_managed_frame_release(&payload.managed);
    alloc.destroy(payload);
}

pub fn frameShapeFromC(shape: u32) ?foundation.FrameShape {
    return switch (shape) {
        c.PANCAKE_FRAME_SHAPE_BYTE => .byte,
        c.PANCAKE_FRAME_SHAPE_WORD => .word,
        else => null,
    };
}

pub fn frameShapeToC(shape: foundation.FrameShape) u32 {
    return switch (shape) {
        .byte => c.PANCAKE_FRAME_SHAPE_BYTE,
        .word => c.PANCAKE_FRAME_SHAPE_WORD,
    };
}
