//! Managed-frame ownership helpers for the shared C vocabulary.
//!
//! The frame *vocabulary* and the owned-frame builder (`managedFrame`, the
//! shape conversions) live in the shared leaf (`src/c_abi/shared/`) so the iroh transport
//! ABI can reuse them without this file's `export fn`s; they are re-exported
//! here so the peer/endpoint families keep calling them as `frame.*`.

const std = @import("std");

const c = @import("mod.zig");
const abi = @import("c_abi_shared");

const PancakeManagedFrame = c.PancakeManagedFrame;

/// Wrap an owned `foundation.Frame` as a self-releasing managed frame. Lives in
/// the shared leaf; re-exported for the peer/endpoint families.
pub const managedFrame = abi.managedFrame;
/// Decode a `PANCAKE_FRAME_SHAPE_*` value. Lives in the shared leaf.
pub const frameShapeFromC = abi.frameShapeFromC;

pub export fn pancake_managed_frame_release(frame: ?*PancakeManagedFrame) void {
    const managed = frame orelse return;
    const release = managed.release orelse return;

    managed.release = null;
    // The callback owns payload cleanup and any remaining descriptor
    // normalization. Do not touch `managed` after this call; a producer may
    // allocate descriptors whose release reclaims the whole object.
    release(managed);
}
