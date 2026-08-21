//! Borrowed and owned frame layouts at the C waist.
//!
//! Managed frames transfer their existing allocation into one preallocated
//! release cell; no frame-byte copy is introduced at the ABI boundary.

const std = @import("std");
const foundation = @import("foundation");
const last_error = @import("last_error.zig");
const result = @import("result.zig");

pub const PANCAKE_FRAME_SHAPE_BYTE: u32 = 0;
pub const PANCAKE_FRAME_SHAPE_WORD: u32 = 1;

pub fn shapeFromC(shape: u32) ?foundation.FrameShape {
    return switch (shape) {
        PANCAKE_FRAME_SHAPE_BYTE => .byte,
        PANCAKE_FRAME_SHAPE_WORD => .word,
        else => null,
    };
}

fn shapeToC(shape: foundation.FrameShape) u32 {
    return switch (shape) {
        .byte => PANCAKE_FRAME_SHAPE_BYTE,
        .word => PANCAKE_FRAME_SHAPE_WORD,
    };
}

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

const ManagedFramePayload = struct {
    frame: foundation.Frame,
    allocator: std.mem.Allocator,
};

/// Reserve before removing a frame from its source queue; commit after dequeue,
/// or cancel on an empty queue/refusal.
pub const ManagedFrameReservation = struct {
    payload: *ManagedFramePayload,

    pub fn cancel(self: ManagedFrameReservation) void {
        self.payload.allocator.destroy(self.payload);
    }

    pub fn commit(self: ManagedFrameReservation, owned: foundation.Frame) PancakeManagedFrame {
        self.payload.frame = owned;
        return .{
            .bytes = @constCast(self.payload.frame.bytes().ptr),
            .len = self.payload.frame.bytes().len,
            .shape = shapeToC(self.payload.frame.view().shape),
            .release = releaseOwned,
            .private_data = self.payload,
        };
    }
};

pub fn reserveManaged(allocator: std.mem.Allocator) !ManagedFrameReservation {
    const payload = try allocator.create(ManagedFramePayload);
    payload.allocator = allocator;
    return .{ .payload = payload };
}

pub fn tryManaged(allocator: std.mem.Allocator, owned: foundation.Frame) !PancakeManagedFrame {
    const reservation = try reserveManaged(allocator);
    return reservation.commit(owned);
}

pub fn wrapManagedInto(
    allocator: std.mem.Allocator,
    owned: foundation.Frame,
    slot: *PancakeManagedFrame,
    comptime operation: []const u8,
) i32 {
    slot.* = tryManaged(allocator, owned) catch {
        var abandoned = owned;
        abandoned.deinit();
        last_error.set(operation ++ ": frame wrap allocation failed", .{});
        return result.PANCAKE_ERR_INTERNAL;
    };
    return result.PANCAKE_OK;
}

fn releaseOwned(frame: *PancakeManagedFrame) callconv(.c) void {
    const payload_ptr = frame.private_data orelse return;
    const payload: *ManagedFramePayload = @ptrCast(@alignCast(payload_ptr));
    const allocator = payload.allocator;
    payload.frame.deinit();
    allocator.destroy(payload);
    frame.bytes = null;
    frame.len = 0;
    frame.release = null;
    frame.private_data = null;
}
