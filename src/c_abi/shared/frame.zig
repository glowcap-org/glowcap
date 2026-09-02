//! Borrowed and owned frame layouts at the C waist.
//!
//! Managed frames transfer their existing allocation into opaque storage in
//! the caller-owned descriptor; no allocation or frame-byte copy is introduced
//! at the ABI boundary.

const std = @import("std");
const foundation = @import("foundation");

pub const GLOWCAP_FRAME_SHAPE_BYTE: u32 = 0;
pub const GLOWCAP_FRAME_SHAPE_WORD: u32 = 1;

pub fn shapeFromC(shape: u32) ?foundation.FrameShape {
    return switch (shape) {
        GLOWCAP_FRAME_SHAPE_BYTE => .byte,
        GLOWCAP_FRAME_SHAPE_WORD => .word,
        else => null,
    };
}

fn shapeToC(shape: foundation.FrameShape) u32 {
    return switch (shape) {
        .byte => GLOWCAP_FRAME_SHAPE_BYTE,
        .word => GLOWCAP_FRAME_SHAPE_WORD,
    };
}

pub const GlowcapFrame = extern struct {
    bytes: ?[*]const u8,
    len: usize,
    shape: u32,
};

pub const ReleaseFn = *const fn (*GlowcapManagedFrame) callconv(.c) void;

/// Private descriptor words reserved for glowcap's owned-frame metadata. The
/// count is target-independent so the public C declaration has one shape;
/// comptime assertions below prove that the native `foundation.Frame` fits on
/// each compiled target.
pub const managed_frame_private_word_count = 8;

pub const GlowcapManagedFrame = extern struct {
    bytes: ?[*]u8,
    len: usize,
    shape: u32,
    release: ?ReleaseFn,
    private_words: [managed_frame_private_word_count]usize,
};

comptime {
    std.debug.assert(@sizeOf(foundation.Frame) <=
        managed_frame_private_word_count * @sizeOf(usize));
    std.debug.assert(@alignOf(foundation.Frame) <= @alignOf(usize));
}

fn ownedFrame(frame: *GlowcapManagedFrame) *foundation.Frame {
    return @ptrCast(@alignCast(&frame.private_words));
}

/// Move one owned frame into a self-releasing C descriptor. The caller supplies
/// the descriptor storage; wrapping is allocation-free and infallible.
pub fn managed(owned: foundation.Frame) GlowcapManagedFrame {
    var result = std.mem.zeroes(GlowcapManagedFrame);
    const stored = ownedFrame(&result);
    stored.* = owned;
    result.bytes = @constCast(stored.bytes().ptr);
    result.len = stored.bytes().len;
    result.shape = shapeToC(stored.view().shape);
    result.release = releaseOwned;
    return result;
}

fn releaseOwned(frame: *GlowcapManagedFrame) callconv(.c) void {
    ownedFrame(frame).deinit();
    frame.* = std.mem.zeroes(GlowcapManagedFrame);
}
