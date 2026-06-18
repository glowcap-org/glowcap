//! Managed-frame `export fn`s and the event-kind conversion: releasing a
//! self-releasing `PancakeManagedFrame`, adopting an inbound managed frame, and
//! mapping engine event kinds to their C discriminants.
//!
//! The frame *vocabulary* and the owned-frame builder (`tryManagedFrame`, the
//! shape conversions) live in the shared leaf (`src/c_abi/shared/`) so the iroh transport
//! ABI can reuse them without this file's `export fn`s; they are re-exported
//! here so the peer/endpoint families keep calling them as `frame.*`.

const std = @import("std");

const engine = @import("engine");

const c = @import("mod.zig");
const abi = @import("c_abi_shared");

const PancakeManagedFrame = c.PancakeManagedFrame;
const PancakeEvent = c.PancakeEvent;

/// Wrap an owned `foundation.Frame` as a self-releasing managed frame. Lives in
/// the shared leaf; re-exported for the peer/endpoint families.
pub const tryManagedFrame = abi.tryManagedFrame;
/// Decode a `PANCAKE_FRAME_SHAPE_*` value. Lives in the shared leaf.
pub const frameShapeFromC = abi.frameShapeFromC;

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

pub fn releaseAdoptedManagedFrame(context: *anyopaque) void {
    const payload: *AdoptedManagedFramePayload = @ptrCast(@alignCast(context));
    const alloc = payload.allocator;
    pancake_managed_frame_release(&payload.managed);
    alloc.destroy(payload);
}
